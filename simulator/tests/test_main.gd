extends "res://tests/test_case.gd"
## main.gd integration: load a match into the real viewer node and drive playback by hand.
## Methods are called directly (no frames awaited after loading) so `_process` never advances
## time behind the test's back.

const Main := preload("res://scripts/main.gd")
const C := MatchData.CENTRE_M
const X := Vector3.RIGHT

var _saved_path: String


func before_each() -> void:
	# Keep the real settings untouched and skip the SDE update check (network).
	_saved_path = Settings.path
	Settings.path = temp_dir().path_join("settings.cfg")
	Settings._cfg = null
	Settings.set_value("sde/auto_update", false)


func after_each() -> void:
	Settings.path = _saved_path
	Settings._cfg = null


func _main() -> Main:
	var m: Main = Main.new()
	add_node(m)
	return m


## blue (corner 0), red (corner 7, one 20 s gap), late (centre, from 5 s), and runner, who
## leaves the arena at 2 s. Ship types are made up so real SDE sizes don't apply.
func _match_csv() -> String:
	var rows := [
		row(0, "blue", "Test Hull", on_line(0, 0.5)),
		row(4, "blue", "Test Hull", on_line(0, 0.4)),
		row(0, "red", "Test Hull", on_line(7, 0.5)),
		row(20, "red", "Test Hull", on_line(7, 0.5)),
		row(0, "runner", "Test Hull", C + X * 100000.0),
		row(4, "runner", "Test Hull", C + X * 150000.0),
	]
	for t in [5, 10, 15, 20]:
		rows.append(row(t, "late", "Test Hull", C))
	for t in [8, 12, 16, 20]:
		rows.append(row(t, "blue", "Test Hull", on_line(0, 0.4)))
		rows.append(row(t, "runner", "Test Hull", C + X * 150000.0))
	return write_csv(rows)


func test_fmt_time() -> void:
	assert_eq(Main._fmt_time(0.0), "00:00")
	assert_eq(Main._fmt_time(59.9), "00:59")
	assert_eq(Main._fmt_time(61.0), "01:01")
	assert_eq(Main._fmt_time(3600.0), "60:00")


func test_material() -> void:
	var m := Main._material(Color(1, 0, 0, 0.5), false)
	assert_eq(m.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA)
	assert_eq(m.shading_mode, BaseMaterial3D.SHADING_MODE_UNSHADED)
	m = Main._material(Color(1, 0, 0), true)
	assert_eq(m.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED)
	assert_eq(m.shading_mode, BaseMaterial3D.SHADING_MODE_PER_PIXEL)


func test_starts_empty() -> void:
	var m := _main()
	assert_null(m.data)
	assert_true(m.file_label.text.begins_with("No match loaded"))


func test_load_bad_file() -> void:
	var m := _main()
	m.load_match(temp_dir().path_join("missing.positions.csv"))
	assert_null(m.data)
	assert_eq(m.file_label.text, "Failed to load missing.positions.csv")


func test_load_match() -> void:
	var m := _main()
	m.load_match(_match_csv())
	assert_not_null(m.data)
	assert_eq(m.ships.size(), 4)
	assert_eq(m.ships_root.get_child_count(), 5, "4 ships + 1 death marker")
	assert_eq(m.timeline.max_value, 20.0)
	assert_eq(m.file_label.text,
		"match.positions.csv — 4 pilots (blue 1 / red 1 / unknown 2), 1 out of bounds")
	assert_true(m.playing)
	assert_eq(m.time, 0.0)


func test_reload_replaces_ships() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m.load_match(write_csv([row(0, "solo", "Test Hull", C), row(1, "solo", "Test Hull", C)]))
	assert_eq(m.ships.keys(), ["solo"])


func test_seek_clamps() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(-5.0)
	assert_eq(m.time, 0.0)
	m._seek(100.0)
	assert_eq(m.time, 20.0)
	m._seek(7.5)
	assert_eq(m.time, 7.5)
	assert_eq(m.timeline.value, 7.5)


func test_playback_stops_at_end_and_restarts() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(18.0)
	m._process(1.0)
	assert_almost(m.time, 19.0)
	assert_true(m.playing)
	m.speed = 10.0
	m._process(1.0)
	assert_eq(m.time, 20.0)
	assert_false(m.playing)
	assert_eq(m.play_button.text, "Play")
	m._toggle_play()
	assert_eq(m.time, 0.0, "play at the end restarts")
	assert_true(m.playing)
	assert_eq(m.play_button.text, "Pause")


func test_ship_visibility_and_position() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(0.0)
	m._update_ships()
	assert_true(m.ships["blue"].node.visible)
	assert_almost(m.ships["blue"].node.position, on_line(0, 0.5) * Main.M_TO_UNITS)
	assert_true(m.ships["red"].node.visible)
	assert_false(m.ships["late"].node.visible, "before first sample")

	m._seek(2.0)
	m._update_ships()
	assert_true(m.ships["blue"].node.visible)
	assert_almost(m.ships["blue"].node.position, on_line(0, 0.45) * Main.M_TO_UNITS)
	assert_false(m.ships["red"].node.visible, "20 s gap hides the ship")

	m._seek(5.0)
	m._update_ships()
	assert_true(m.ships["late"].node.visible)
	assert_almost(m.ships["late"].node.position, C * Main.M_TO_UNITS)


func test_death_marks_ship() -> void:
	var m := _main()
	m.load_match(_match_csv())
	var runner: Dictionary = m.ships["runner"]
	assert_almost(runner.death_t, 2.0)
	m._seek(1.0)
	m._update_ships()
	assert_false(runner.death_marker.visible)
	assert_false(runner.dead)
	assert_false("DEAD" in runner.label.text)

	m._seek(3.0)
	m._update_ships()
	assert_true(runner.death_marker.visible)
	assert_true(runner.dead)
	assert_true("DEAD" in runner.label.text)
	assert_almost(runner.death_marker.position, (C + X * MatchData.BOUNDARY_RADIUS_M) * Main.M_TO_UNITS, 1e-2)


func test_boundary_toggle() -> void:
	var m := _main()
	assert_true(m.boundary.visible)
	m.boundary_toggle.button_pressed = false
	assert_false(m.boundary.visible)
