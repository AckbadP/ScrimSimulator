extends "res://tests/test_case.gd"
## MatchLibrary: adding, listing and removing matches, in a temp dir instead of user://matches.

var _saved_dir: String


func before_each() -> void:
	_saved_dir = MatchLibrary.dir
	MatchLibrary.dir = temp_dir().path_join("matches")


func after_each() -> void:
	MatchLibrary.dir = _saved_dir


## A CSV named `name` in its own temp dir, holding `body`.
func _file(name: String, body: String) -> String:
	var path := temp_dir().path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(body)
	f.close()
	return path


func test_missing_dir_lists_nothing() -> void:
	assert_eq(MatchLibrary.list(), [])


func test_add_copies_and_lists() -> void:
	var src := _file("match_03.positions.csv", "a")
	var path := MatchLibrary.add(src)
	assert_eq(path, MatchLibrary.dir.path_join("match_03.positions.csv"))
	assert_eq(FileAccess.get_file_as_string(path), "a")
	var entries := MatchLibrary.list()
	assert_eq(entries.size(), 1)
	assert_eq(entries[0].path, path)
	assert_eq(entries[0].name, "match_03")
	DirAccess.remove_absolute(src)
	assert_true(FileAccess.file_exists(path), "copy outlives the original")


func test_readd_identical_is_not_duplicated() -> void:
	var first := MatchLibrary.add(_file("m.positions.csv", "same"))
	var second := MatchLibrary.add(_file("m.positions.csv", "same"))
	assert_eq(second, first)
	assert_eq(MatchLibrary.list().size(), 1)
	assert_eq(MatchLibrary.add(first), first, "adding a library file returns it")


func test_name_clash_gets_suffix() -> void:
	MatchLibrary.add(_file("m.positions.csv", "one"))
	var second := MatchLibrary.add(_file("m.positions.csv", "two"))
	var third := MatchLibrary.add(_file("m.positions.csv", "three"))
	assert_eq(second.get_file(), "m (2).positions.csv")
	assert_eq(third.get_file(), "m (3).positions.csv")
	assert_eq(FileAccess.get_file_as_string(second), "two")
	assert_eq(MatchLibrary.list().size(), 3)


func test_list_newest_first() -> void:
	if OS.get_name() == "Windows":
		return  # Ages the file with `touch`.
	var old := MatchLibrary.add(_file("old.csv", "1"))
	MatchLibrary.add(_file("new.csv", "2"))
	# Modification times have 1 s resolution: age the first file instead of sleeping.
	OS.execute("touch", ["-d", "2020-01-01", ProjectSettings.globalize_path(old)])
	assert_eq(MatchLibrary.list().map(func(e): return e.name), ["new", "old"])


func test_list_ignores_other_files() -> void:
	MatchLibrary.add(_file("m.csv", "1"))
	var f := FileAccess.open(MatchLibrary.dir.path_join("notes.txt"), FileAccess.WRITE)
	f.close()
	assert_eq(MatchLibrary.list().size(), 1)


func test_remove_deletes() -> void:
	var path := MatchLibrary.add(_file("m.csv", "1"))
	MatchLibrary.remove(path)
	assert_false(FileAccess.file_exists(path))
	assert_eq(MatchLibrary.list(), [])


func test_add_missing_source_fails() -> void:
	assert_eq(MatchLibrary.add(temp_dir().path_join("nope.csv")), "")
	assert_eq(MatchLibrary.list(), [])


func test_display_name() -> void:
	assert_eq(MatchLibrary.display_name("match_03.positions.csv"), "match_03")
	assert_eq(MatchLibrary.display_name("x.CSV"), "x")
	assert_eq(MatchLibrary.display_name("plain"), "plain")


func test_rename_keeps_extension_and_moves_meta() -> void:
	var path := MatchLibrary.add(_file("m.positions.csv", "1"))
	MatchLibrary.save_meta(path, {"teams": {"a": 1}})
	var renamed := MatchLibrary.rename(path, "  Final vs Them ")
	assert_eq(renamed, MatchLibrary.dir.path_join("Final vs Them.positions.csv"))
	assert_false(FileAccess.file_exists(path))
	assert_false(FileAccess.file_exists(MatchLibrary.meta_path(path)))
	assert_eq(MatchLibrary.load_meta(renamed), {"teams": {"a": 1}})
	assert_eq(MatchLibrary.list().map(func(e): return e.name), ["Final vs Them"])
	assert_eq(MatchLibrary.rename(renamed, "Final vs Them"), renamed, "same name is a no-op")


func test_rename_to_taken_or_empty_name_fails() -> void:
	var a := MatchLibrary.add(_file("a.csv", "1"))
	MatchLibrary.add(_file("b.csv", "2"))
	assert_eq(MatchLibrary.rename(a, "b"), "")
	assert_eq(MatchLibrary.rename(a, "   "), "")
	assert_true(FileAccess.file_exists(a))


func test_meta_round_trip() -> void:
	var path := MatchLibrary.add(_file("m.csv", "1"))
	assert_eq(MatchLibrary.load_meta(path), {}, "no sidecar yet")
	MatchLibrary.save_meta(path, {"teams": {"x y": MatchData.Team.RED}, "team_names": {MatchData.Team.BLUE: "Us"}})
	var meta := MatchLibrary.load_meta(path)
	assert_eq(meta.teams, {"x y": MatchData.Team.RED})
	assert_eq(meta.team_names, {MatchData.Team.BLUE: "Us"})
	assert_eq(typeof(meta.teams["x y"]), TYPE_INT)
	assert_eq(MatchLibrary.list().size(), 1, "sidecar isn't listed")


func test_remove_deletes_meta() -> void:
	var path := MatchLibrary.add(_file("m.csv", "1"))
	MatchLibrary.save_meta(path, {"teams": {}})
	MatchLibrary.remove(path)
	assert_false(FileAccess.file_exists(MatchLibrary.meta_path(path)))


func test_contains() -> void:
	var path := MatchLibrary.add(_file("m.csv", "1"))
	assert_true(MatchLibrary.contains(path))
	assert_false(MatchLibrary.contains(temp_dir().path_join("m.csv")))
	assert_false(MatchLibrary.contains(""))
