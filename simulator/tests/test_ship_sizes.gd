extends "res://tests/test_case.gd"
## ShipSizes: cache round-trip, SDE zip extraction and status plumbing. Instances are kept out
## of the scene tree so `_ready` never loads the real `sde/` cache; network paths aren't covered.

const SDE_META := '{"_key":"sde","buildNumber":3000000,"releaseDate":"2026-09-01T11:00:00Z"}'
const GROUPS := [
	'{"_key":25,"categoryID":6,"name":{"en":"Frigate"}}',
	'{"_key":29,"categoryID":6,"name":{"en":"Capsule"}}',
	'{"_key":18,"categoryID":4,"name":{"en":"Mineral"}}',
]
const TYPES := [
	'{"_key":587,"groupID":25,"name":{"de":"Rifter","en":"Rifter"},"published":true,"radius":31.0}',
	'{"_key":670,"groupID":29,"name":"Capsule","published":true,"radius":7.5}',
	'{"_key":34,"groupID":18,"name":{"en":"Tritanium"},"published":true,"radius":1.0}',
	'{"_key":999,"groupID":25,"name":{"en":"Unreleased Frigate"},"published":false,"radius":40.0}',
	'{"_key":1,"name":{"en":"No Group"}}',
]


func _sizes(dir := "") -> ShipSizes:
	var s: ShipSizes = own(ShipSizes.new())
	s._dir = dir if dir else temp_dir()
	return s


func _rifter() -> Dictionary:
	return {"name": "Rifter", "type_id": 587, "group_id": 25, "radius_m": 31.0}


func _zip(files: Dictionary) -> String:
	var path := temp_dir().path_join("sde.zip")
	var zip := ZIPPacker.new()
	assert_eq(zip.open(path), OK)
	for name in files:
		zip.start_file(name)
		zip.write_file(files[name].to_utf8_buffer())
		zip.close_file()
	zip.close()
	return path


# --- lookups / status --------------------------------------------------------

func test_parse_jsonl_keeps_only_objects() -> void:
	var out := ShipSizes._parse_jsonl('{"a":1}\n\n[1,2]\n{"b":2}\n')
	assert_eq(out, [{"a": 1.0}, {"b": 2.0}])


func test_lookups_are_case_insensitive() -> void:
	var s := _sizes()
	s.ships = {"rifter": _rifter()}
	assert_eq(s.radius_m("RIFTER"), 31.0)
	assert_eq(s.radius_m("Merlin"), 0.0)
	assert_eq(s.radii(), {"rifter": 31.0})


func test_summary_reflects_loaded_state() -> void:
	var s := _sizes()
	assert_false(s.is_loaded())
	assert_eq(s._summary(), "No SDE data — ships use a default size")
	s.build = 42
	s.release_date = "2026-09-01T11:00:00Z"
	s.ships = {"rifter": _rifter()}
	assert_true(s.is_loaded())
	assert_eq(s._summary(), "SDE build 42 (2026-09-01), 1 ships")


func test_status_signal_only_on_change() -> void:
	var s := _sizes()
	var seen := []
	s.status_changed.connect(func(text): seen.append(text))
	s._set_status("a")
	s._set_status("a")
	s._set_status("b")
	assert_eq(seen, ["a", "b"])
	assert_eq(s.status, "b")


func test_start_without_cache_asks_for_download() -> void:
	var s := _sizes()
	var reasons := []
	s.needs_download.connect(func(reason): reasons.append(reason))
	s.start(true)
	assert_eq(reasons.size(), 1)


func test_start_without_auto_update_shows_summary() -> void:
	var s := _sizes()
	s.build = 7
	s.ships = {"rifter": _rifter()}
	var reasons := []
	s.needs_download.connect(func(reason): reasons.append(reason))
	s.start(false)
	assert_eq(reasons, [])
	assert_false(s.busy)
	assert_eq(s.status, s._summary())


# --- cache ---------------------------------------------------------------------

func test_cache_round_trip() -> void:
	var dir := temp_dir()
	var a := _sizes(dir)
	a.build = 3000000
	a.release_date = "2026-09-01T11:00:00Z"
	a.ship_groups = {25: true}
	a.ships = {"rifter": _rifter()}
	a._save_cache()

	var b := _sizes(dir)
	b._load_cache()
	assert_eq(b.build, 3000000)
	assert_eq(b.release_date, "2026-09-01T11:00:00Z")
	assert_eq(b.ship_groups.keys(), [25])
	assert_eq(b.ships.keys(), ["rifter"])
	var r: Dictionary = b.ships["rifter"]
	assert_eq(r.name, "Rifter")
	assert_eq(r.type_id, 587)
	assert_eq(r.group_id, 25)
	assert_eq(r.radius_m, 31.0)
	assert_eq(b.status, b._summary())


func test_missing_cache_leaves_sizes_unloaded() -> void:
	var s := _sizes()
	s._load_cache()
	assert_false(s.is_loaded())
	assert_eq(s.status, s._summary())


func test_unreadable_cache_is_ignored() -> void:
	var s := _sizes()
	var f := FileAccess.open(s._cache_path(), FileAccess.WRITE)
	f.store_string("not json")
	f.close()
	s._load_cache()
	assert_false(s.is_loaded())
	assert_eq(s.ships, {})


# --- SDE zip -------------------------------------------------------------------

func test_extract_ships_from_sde_zip() -> void:
	var out := ShipSizes._extract_ships(_zip({
		"_sde.jsonl": SDE_META,
		"groups.jsonl": "\n".join(GROUPS),
		"types.jsonl": "\n".join(TYPES) + "\n",
	}))
	assert_eq(out.error, "")
	assert_eq(out.build, 3000000)
	assert_eq(out.release_date, "2026-09-01T11:00:00Z")
	assert_eq(out.groups, {25: true, 29: true})
	var names: Array = out.ships.keys()
	names.sort()
	assert_eq(names, ["capsule", "rifter"], "only published ships")
	assert_eq(out.ships["rifter"], {"name": "Rifter", "type_id": 587, "group_id": 25, "radius_m": 31.0})
	assert_eq(out.ships["capsule"].radius_m, 7.5)


func test_extract_ships_missing_zip() -> void:
	var out := ShipSizes._extract_ships(temp_dir().path_join("missing.zip"))
	assert_true(out.error.begins_with("Cannot open"), out.error)


func test_extract_ships_without_ships_is_an_error() -> void:
	var out := ShipSizes._extract_ships(_zip({
		"_sde.jsonl": SDE_META,
		"groups.jsonl": GROUPS[2],
		"types.jsonl": TYPES[2],
	}))
	assert_eq(out.error, "SDE zip has no ship types")
