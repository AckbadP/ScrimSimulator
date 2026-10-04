class_name MatchLibrary
extends RefCounted
## Matches added through the main menu: copies of their CSVs in `user://matches/`, so they keep
## working if the original file moves. Each may have a JSON sidecar (`meta_path`) holding edits
## made while viewing it (team swaps, team names).

## Overridable so tests never touch the real library.
static var dir := "user://matches"


## `[{ path, name, modified }]` for every CSV in the library, newest first; `name` drops the
## `.positions.csv` / `.csv` extension and `modified` is a Unix time.
static func list() -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for file in DirAccess.get_files_at(dir):
		if file.get_extension().to_lower() != "csv":
			continue
		var path := dir.path_join(file)
		out.append({"path": path, "name": display_name(file), "modified": FileAccess.get_modified_time(path)})
	out.sort_custom(func(a, b):
		return a.modified > b.modified if a.modified != b.modified else a.name.naturalnocasecmp_to(b.name) < 0)
	return out


## "match_03.positions.csv" -> "match_03".
static func display_name(file: String) -> String:
	for ext in [".positions.csv", ".csv"]:
		if file.to_lower().ends_with(ext):
			return file.left(file.length() - ext.length())
	return file


## Copies `src` into the library and returns the copy's path ("" on failure). A file already
## there with the same name and contents is reused; a different file with the same name gets a
## " (2)", " (3)", … suffix.
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
	var ext := file.substr(stem.length())
	var src_hash := FileAccess.get_sha256(src)
	var n := 1
	while true:
		var dest := dir.path_join(file if n == 1 else "%s (%d)%s" % [stem, n, ext])
		if not FileAccess.file_exists(dest):
			err = DirAccess.copy_absolute(ProjectSettings.globalize_path(src), ProjectSettings.globalize_path(dest))
			if err != OK:
				push_error("Cannot copy %s to %s: %s" % [src, dest, error_string(err)])
				return ""
			return dest
		if FileAccess.get_sha256(dest) == src_hash:
			return dest
		n += 1
	return ""


## Renames library match `path` to display name `new_name` (its extension is kept) and returns
## the new path, or "" if the name is empty or another match already shows it. The sidecar moves
## with it.
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
	if FileAccess.file_exists(meta_path(path)):
		err = DirAccess.rename_absolute(ProjectSettings.globalize_path(meta_path(path)),
				ProjectSettings.globalize_path(meta_path(dest)))
		if err != OK:
			push_error("Cannot rename %s: %s" % [meta_path(path), error_string(err)])
	return dest


## Deletes a library match and its sidecar.
static func remove(path: String) -> void:
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("Cannot remove %s: %s" % [path, error_string(err)])
	if FileAccess.file_exists(meta_path(path)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(meta_path(path)))


## Whether `path` is a match in the library (only those keep a sidecar).
static func contains(path: String) -> bool:
	return path != "" and path.get_base_dir().simplify_path() == dir.simplify_path()


## "…/match_03.positions.csv" -> "…/match_03.positions.json".
static func meta_path(path: String) -> String:
	return path.get_basename() + ".json"


## The match's saved edits: `{ teams: { pilot -> Team }, team_names: { Team -> String } }`, each
## present only if saved. {} when there is no (readable) sidecar.
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
	return out


## Writes the sidecar of library match `path` (see `load_meta`).
static func save_meta(path: String, meta: Dictionary) -> void:
	var file := meta_path(path)
	var f := FileAccess.open(file, FileAccess.WRITE)
	if f == null:
		push_error("Cannot save %s: %s" % [file, error_string(FileAccess.get_open_error())])
		return
	f.store_string(JSON.stringify(meta, "\t"))
