class_name MatchLibrary
extends RefCounted
## Matches added through the main menu: copies of their CSVs in `user://matches/`, so they keep
## working if the original file moves. Each may have a JSON sidecar (`meta_path`) holding edits
## made while viewing it (team swaps, team names), an audio file (`audio_path`) that starts
## with the CSV's first sample, and EVE gamelogs (`logs_dir`) of pilots in the match (see
## `CombatLog`).

## Overridable so tests never touch the real library.
static var dir := "user://matches"
## Where the release bundle keeps the demo match (`demo/` next to the executable, see
## `demo_source`). Overridable so tests never touch the real one.
static var demo_dir := ""
## Audio formats Godot can load at runtime.
const AUDIO_EXTENSIONS := ["ogg", "mp3", "wav"]


## `[{ path, name, modified, audio }]` for every CSV in the library, newest first; `name` drops
## the `.positions.csv` / `.csv` extension, `modified` is a Unix time and `audio` whether the
## match has an audio file.
static func list() -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for file in DirAccess.get_files_at(dir):
		if file.get_extension().to_lower() != "csv":
			continue
		var path := dir.path_join(file)
		out.append({
			"path": path, "name": display_name(file), "modified": FileAccess.get_modified_time(path),
			"audio": audio_path(path) != "",
		})
	out.sort_custom(func(a, b):
		return a.modified > b.modified if a.modified != b.modified else a.name.naturalnocasecmp_to(b.name) < 0)
	return out


## "match_03.positions.csv" -> "match_03".
static func display_name(file: String) -> String:
	for ext in [".positions.csv", ".csv"]:
		if file.to_lower().ends_with(ext):
			return file.left(file.length() - ext.length())
	return file


## The demo match's CSV shipped with the release (in `demo_dir`, else `demo/` next to the
## executable), or "" if there is none. Never found when run from source.
static func demo_source() -> String:
	var d := demo_dir
	if d == "":
		if OS.has_feature("editor"):
			return ""
		d = OS.get_executable_path().get_base_dir().path_join("demo")
	if not DirAccess.dir_exists_absolute(d):
		return ""
	for file in DirAccess.get_files_at(d):
		if file.get_extension().to_lower() == "csv":
			return d.path_join(file)
	return ""


## Adds the demo match (and its gamelogs) to the library the first time it is found; once added,
## it is never added again, so removing it sticks.
static func add_demo() -> void:
	if Settings.get_value("library/demo_added"):
		return
	var src := demo_source()
	if src == "" or add(src) == "":
		return
	Settings.set_value("library/demo_added", true)


## Copies `src` into the library and returns the copy's path ("" on failure). A file already
## there with the same name and contents is reused; a different file with the same name gets a
## " (2)", " (3)", … suffix. Gamelogs in the CSV's own `logs_dir` come along.
static func add(src: String) -> String:
	if not FileAccess.file_exists(src):
		push_error("Cannot add %s: no such file" % src)
		return ""
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if err != OK:
		push_error("Cannot create %s: %s" % [dir, error_string(err)])
		return ""
	var file := src.get_file()
	var stem := display_name(file)
	var dest := _copy_unique(src, dir, stem, file.substr(stem.length()))
	var gamelogs := log_paths(src)
	if dest != "" and not gamelogs.is_empty():
		var data := MatchData.load_csv(dest, {}, 0.0, true)
		for gamelog in gamelogs:
			add_log(dest, gamelog, data)
	return dest


## Copies `src` into `to_dir` as `<stem><ext>`, reusing an identical file there and otherwise
## adding a " (2)", " (3)", … suffix; the copy's path, or "" on failure.
static func _copy_unique(src: String, to_dir: String, stem: String, ext: String) -> String:
	var src_hash := FileAccess.get_sha256(src)
	var n := 1
	while true:
		var dest := to_dir.path_join(stem + ext if n == 1 else "%s (%d)%s" % [stem, n, ext])
		if not FileAccess.file_exists(dest):
			var err := DirAccess.copy_absolute(ProjectSettings.globalize_path(src), ProjectSettings.globalize_path(dest))
			if err != OK:
				push_error("Cannot copy %s to %s: %s" % [src, dest, error_string(err)])
				return ""
			return dest
		if FileAccess.get_sha256(dest) == src_hash:
			return dest
		n += 1
	return ""


## Renames library match `path` to display name `new_name` (its extension is kept) and returns
## the new path, or "" if the name is empty or another match already shows it. The sidecar,
## audio and logs move with it.
static func rename(path: String, new_name: String) -> String:
	new_name = new_name.strip_edges().validate_filename()
	if new_name.is_empty():
		return ""
	var file := path.get_file()
	var dest := path.get_base_dir().path_join(new_name + file.substr(display_name(file).length()))
	if dest == path:
		return path
	# Case-only renames are allowed (on case-insensitive file systems the target "exists").
	for e in list():
		if e.path != path and e.name.to_lower() == new_name.to_lower():
			return ""
	if FileAccess.file_exists(dest) and dest.to_lower() != path.to_lower():
		return ""
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(dest))
	if err != OK:
		push_error("Cannot rename %s to %s: %s" % [path, dest, error_string(err)])
		return ""
	for companion: String in _companions(path):
		var to: String = dest.get_basename() + "." + companion.get_extension()
		err = DirAccess.rename_absolute(ProjectSettings.globalize_path(companion), ProjectSettings.globalize_path(to))
		if err != OK:
			push_error("Cannot rename %s: %s" % [companion, error_string(err)])
	return dest


## Deletes a library match, its sidecar, its audio and its logs.
static func remove(path: String) -> void:
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("Cannot remove %s: %s" % [path, error_string(err)])
	remove_logs(path)
	for companion: String in _companions(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(companion))


## The existing files that belong to library match `path`: its sidecar, audio and logs dir.
static func _companions(path: String) -> Array:
	var out := []
	if FileAccess.file_exists(meta_path(path)):
		out.append(meta_path(path))
	if audio_path(path) != "":
		out.append(audio_path(path))
	if DirAccess.dir_exists_absolute(logs_dir(path)):
		out.append(logs_dir(path))
	return out


## Whether `path` is a match in the library (only those keep a sidecar).
static func contains(path: String) -> bool:
	return path != "" and path.get_base_dir().simplify_path() == dir.simplify_path()


## "…/match_03.positions.csv" -> "…/match_03.positions.json".
static func meta_path(path: String) -> String:
	return path.get_basename() + ".json"


## Match `path`'s audio file ("…/match_03.positions.ogg"), or "" if it has none.
static func audio_path(path: String) -> String:
	for ext in AUDIO_EXTENSIONS:
		var file: String = path.get_basename() + "." + ext
		if FileAccess.file_exists(file):
			return file
	return ""


## Copies audio file `src` into the library as match `path`'s audio, replacing any it had, and
## returns the copy's path ("" if `src` isn't a supported format or can't be copied).
static func set_audio(path: String, src: String) -> String:
	var ext := src.get_extension().to_lower()
	if not AUDIO_EXTENSIONS.has(ext):
		push_error("Cannot add %s: not one of %s" % [src, ", ".join(AUDIO_EXTENSIONS)])
		return ""
	if not FileAccess.file_exists(src):
		push_error("Cannot add %s: no such file" % src)
		return ""
	var dest := path.get_basename() + "." + ext
	if ProjectSettings.globalize_path(src).simplify_path() == ProjectSettings.globalize_path(dest).simplify_path():
		return dest
	remove_audio(path)
	var err := DirAccess.copy_absolute(ProjectSettings.globalize_path(src), ProjectSettings.globalize_path(dest))
	if err != OK:
		push_error("Cannot copy %s to %s: %s" % [src, dest, error_string(err)])
		return ""
	return dest


## Directory holding match `path`'s gamelogs: "…/match_03.positions.csv" ->
## "…/match_03.positions.logs". Also read next to CSVs outside the library.
static func logs_dir(path: String) -> String:
	return path.get_basename() + ".logs"


## Match `path`'s gamelogs (`*.txt` in `logs_dir`), sorted by file name.
static func log_paths(path: String) -> Array:
	var out := []
	var d := logs_dir(path)
	if not DirAccess.dir_exists_absolute(d):
		return out
	for file in DirAccess.get_files_at(d):
		if file.get_extension().to_lower() == "txt":
			out.append(d.path_join(file))
	out.sort_custom(func(a, b): return a.naturalnocasecmp_to(b) < 0)
	return out


## Saves the part of gamelog `src` logged during match `path` (`CombatLog.trim` to
## `MatchData.eve_window`) in its `logs_dir`, and returns the saved file's path. "" (and nothing
## saved) if `src` isn't a gamelog, the match has no EVE times or the log has no combat during
## it. An identical log already there is reused; a different one with the same name gets a
## " (2)", … suffix. `data` is the match loaded from `path`, if the caller has it.
static func add_log(path: String, src: String, data: MatchData = null) -> String:
	if not FileAccess.file_exists(src):
		push_error("Cannot add %s: no such file" % src)
		return ""
	if data == null:
		data = MatchData.load_csv(path, {}, 0.0, true)
	if data == null or not data.has_eve_time():
		push_error("Cannot add %s: %s has no EVE times to line it up with" % [src, path])
		return ""
	var window := data.eve_window()
	var text := CombatLog.trim(FileAccess.get_file_as_string(src), window[0], window[1])
	if text.is_empty():
		push_error("Cannot add %s: not an EVE gamelog" % src)
		return ""
	if CombatLog.parse(text).entries.is_empty():
		push_error("Cannot add %s: no combat during %s" % [src, path.get_file()])
		return ""
	var d := logs_dir(path)
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))
	if err != OK:
		push_error("Cannot create %s: %s" % [d, error_string(err)])
		return ""
	var file := src.get_file()
	var stem := file.get_basename()
	var n := 1
	while true:
		var dest := d.path_join("%s%s.%s" % [stem, "" if n == 1 else " (%d)" % n, file.get_extension()])
		if not FileAccess.file_exists(dest):
			var f := FileAccess.open(dest, FileAccess.WRITE)
			if f == null:
				push_error("Cannot save %s: %s" % [dest, error_string(FileAccess.get_open_error())])
				return ""
			f.store_string(text)
			return dest
		if FileAccess.get_file_as_string(dest) == text:
			return dest
		n += 1
	return ""


## Deletes gamelog `gamelog` (a path from `log_paths`) of match `path`.
static func remove_log(path: String, gamelog: String) -> void:
	if gamelog.get_base_dir().simplify_path() != logs_dir(path).simplify_path():
		push_error("%s is not a log of %s" % [gamelog, path])
		return
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(gamelog))
	if err != OK:
		push_error("Cannot remove %s: %s" % [gamelog, error_string(err)])


## Deletes all of match `path`'s gamelogs and, if then empty, their directory.
static func remove_logs(path: String) -> void:
	for gamelog in log_paths(path):
		remove_log(path, gamelog)
	var d := logs_dir(path)
	if DirAccess.dir_exists_absolute(d) and DirAccess.get_files_at(d).is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(d))


## Deletes match `path`'s audio file, if any.
static func remove_audio(path: String) -> void:
	var file := audio_path(path)
	if file != "":
		var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
		if err != OK:
			push_error("Cannot remove %s: %s" % [file, error_string(err)])


## Match `path`'s audio, ready to play, or null if it has none (or it can't be decoded).
static func load_audio(path: String) -> AudioStream:
	var file := audio_path(path)
	var stream: AudioStream = null
	match file.get_extension():
		"ogg":
			stream = AudioStreamOggVorbis.load_from_file(file)
		"mp3":
			stream = AudioStreamMP3.load_from_file(file)
		"wav":
			stream = AudioStreamWAV.load_from_file(file)
	if stream == null and file != "":
		push_error("Cannot decode %s" % file)
	return stream


## The match's saved edits: `{ teams: { pilot -> Team }, team_names: { Team -> String },
## log_pilots: { gamelog file name -> pilot } }` (the last overrides who a gamelog is attributed
## to), each present only if saved. {} when there is no (readable) sidecar.
static func load_meta(path: String) -> Dictionary:
	var file := meta_path(path)
	if not FileAccess.file_exists(file):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	if not parsed is Dictionary:
		push_error("Ignoring unreadable %s" % file)
		return {}
	# JSON has string keys and float numbers: turn teams back into ints.
	var out := {}
	if parsed.get("teams") is Dictionary:
		out.teams = {}
		for pilot in parsed.teams:
			out.teams[pilot] = int(parsed.teams[pilot])
	if parsed.get("team_names") is Dictionary:
		out.team_names = {}
		for team in parsed.team_names:
			out.team_names[int(team)] = str(parsed.team_names[team])
	if parsed.get("log_pilots") is Dictionary:
		out.log_pilots = {}
		for log_file in parsed.log_pilots:
			out.log_pilots[log_file] = str(parsed.log_pilots[log_file])
	return out


## Writes the sidecar of library match `path` (see `load_meta`).
static func save_meta(path: String, meta: Dictionary) -> void:
	var file := meta_path(path)
	var f := FileAccess.open(file, FileAccess.WRITE)
	if f == null:
		push_error("Cannot save %s: %s" % [file, error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(meta, "\t"))
