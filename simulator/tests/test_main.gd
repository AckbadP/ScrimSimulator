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
	Settings.set_value("display/ship_models", false)


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
	m._set_smooth_on(false)  # Linear, so mid-segment positions are easy to state.
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


# --- roster ----------------------------------------------------------------------

## Team header labels and the pilots of the buttons in roster order, e.g. ["Blue (1)", "blue", ...].
func _roster(m: Main) -> Array:
	var out := []
	for c in m.roster_box.get_children():
		if c is Label:
			out.append(c.text)
		else:
			out.append(m.roster_buttons.find_key(c.get_child(0)))
	return out


func test_short_name() -> void:
	assert_eq(Main._short_name("Tormund"), "Tormund")
	assert_eq(Main._short_name("Amarr Citizen 0220922"), "Amarr C. 0.")
	assert_eq(Main._short_name("  Two  Spaces "), "Two S.")


func test_roster_lists_teams() -> void:
	var m := _main()
	assert_false(m.roster_panel.visible, "hidden until a match loads")
	m.load_match(_match_csv())
	assert_true(m.roster_panel.visible)
	assert_eq(_roster(m), ["Blue (1)", "blue", "Red (1)", "red", "Unknown (2)", "late", "runner"])
	assert_eq(m.roster_buttons["blue"].text, "Test Hull — blue")


func test_roster_sorts_by_ship_type_and_abbreviates() -> void:
	var m := _main()
	m.load_match(write_csv([
		row(0, "Zed Pilot", "Atron", C), row(1, "Zed Pilot", "Atron", C),
		row(0, "Amy Pilot", "Rifter", C), row(1, "Amy Pilot", "Rifter", C),
		row(0, "Bob Pilot", "Atron", C), row(1, "Bob Pilot", "Atron", C),
	]))
	assert_eq(_roster(m), ["Blue (0)", "Red (0)", "Unknown (3)", "Bob Pilot", "Zed Pilot", "Amy Pilot"])
	assert_eq(m.roster_buttons["Bob Pilot"].text, "Atron — Bob P.")
	assert_eq(m.roster_buttons["Bob Pilot"].tooltip_text, "Centre the camera on Bob Pilot")


func test_roster_hides_empty_unknown_group() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._swap_team("late")
	m._swap_team("runner")
	assert_eq(_roster(m), ["Blue (3)", "blue", "late", "runner", "Red (1)", "red"])


func test_track_centres_camera() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(2.0)
	m._set_tracked("blue")
	assert_eq(m.tracked, "blue")
	assert_true(m.roster_buttons["blue"].button_pressed)
	m._process(1.0)
	assert_almost(m.camera.target, m.ships["blue"].node.position)
	m._process(1.0)
	assert_almost(m.camera.target, m.ships["blue"].node.position, 1e-4, "keeps following")

	m._set_tracked("blue")
	assert_eq(m.tracked, "", "picking it again frees the camera")
	assert_false(m.roster_buttons["blue"].button_pressed)


func test_track_holds_target_while_hidden() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(0.0)
	m._set_tracked("red")
	m._process(0.0)
	var target: Vector3 = m.camera.target
	m._seek(10.0)  # In red's 20 s gap.
	m._process(0.0)
	assert_false(m.ships["red"].node.visible)
	assert_eq(m.camera.target, target)


func test_pan_stops_tracking() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._set_tracked("blue")
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(50, 0)
	ev.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	m.camera._unhandled_input(ev)
	assert_eq(m.tracked, "")


func test_new_match_drops_missing_tracked_pilot() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._set_tracked("blue")
	m.load_match(write_csv([row(0, "solo", "Test Hull", C), row(1, "solo", "Test Hull", C)]))
	assert_eq(m.tracked, "")


func test_swap_team() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._swap_team("blue")
	assert_eq(m.data.teams["blue"], MatchData.Team.RED)
	assert_eq(m.ships["blue"].color, Main.TEAM_COLORS[MatchData.Team.RED])
	assert_eq(_roster(m), ["Blue (0)", "Red (2)", "blue", "red", "Unknown (2)", "late", "runner"])
	assert_true(m.file_label.text.contains("blue 0 / red 2 / unknown 2"))
	m._seek(0.0)
	m._update_ships()
	assert_eq(m.ships["blue"].tint, Main.TEAM_COLORS[MatchData.Team.RED])
	assert_eq(m.ships["blue"].label.modulate, Main.TEAM_COLORS[MatchData.Team.RED])
	m._swap_team("blue")
	assert_eq(m.data.teams["blue"], MatchData.Team.BLUE)


func test_swap_recolours_death_marker() -> void:
	var m := _main()
	m.load_match(_match_csv())
	m._swap_team("runner")
	var label: Label3D = m.ships["runner"].death_marker.get_child(2)
	assert_eq(label.modulate, Main.TEAM_COLORS[MatchData.Team.BLUE])


func test_swap_survives_reload_of_same_match() -> void:
	var m := _main()
	var path := _match_csv()
	m.load_match(path)
	m._swap_team("blue")
	m._on_sizes_changed()
	assert_eq(m.data.teams["blue"], MatchData.Team.RED)
	m.load_match(write_csv([row(0, "blue", "Test Hull", on_line(0, 0.5))]))
	assert_true(m.team_overrides.is_empty(), "a different match starts fresh")


# --- selection -------------------------------------------------------------------

## A viewer at 2 s with ships placed: blue and runner on grid, red (in its gap) and late not.
func _select_main() -> Main:
	var m := _main()
	m.load_match(_match_csv())
	m._seek(2.0)
	m._process(0.0)
	return m


func _screen(m: Main, pilot: String) -> Vector2:
	return m.camera.unproject_position(m.ships[pilot].node.global_position)


func _mouse(m: Main, pos: Vector2, pressed: bool, double := false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.position = pos
	ev.pressed = pressed
	ev.double_click = double
	m._unhandled_input(ev)


func _click(m: Main, pos: Vector2, double := false) -> void:
	_mouse(m, pos, true, double)
	_mouse(m, pos, false)


## Somewhere on screen far from every ship.
func _empty_spot(m: Main) -> Vector2:
	for p in [Vector2(5, 5), Vector2(1000, 5), Vector2(5, 600)]:
		if m._pick_ship(p) == "":
			return p
	fail("no empty spot")
	return Vector2.ZERO


func test_pick_ship_hits_nearest_and_misses_empty_space() -> void:
	var m := _select_main()
	for pilot in ["blue", "runner"]:
		assert_eq(m._pick_ship(_screen(m, pilot)), pilot)
		assert_eq(m._pick_ship(_screen(m, pilot) + Vector2(Main.PICK_PX - 2, 0)), pilot, "near miss still hits")
	assert_eq(m._pick_ship(_empty_spot(m)), "")


func test_pick_ignores_hidden_and_behind_camera() -> void:
	var m := _select_main()
	assert_false(m.ships["late"].node.visible)
	assert_ne(m._pick_ship(_screen(m, "late")), "late", "not on grid yet")
	# Stand just in front of blue, looking straight away from it.
	var blue: Vector3 = m.ships["blue"].node.global_position
	m.camera.look_at_from_position(blue + Vector3(0, 0, 1), blue + Vector3(0, 0, 10))
	assert_true(m.camera.is_position_behind(blue))
	assert_ne(m._pick_ship(_screen(m, "blue")), "blue", "behind the camera")
	assert_ne(m._pick_ship(m.get_viewport().get_visible_rect().size / 2.0), "blue")


func test_click_selects_and_shows_info() -> void:
	var m := _select_main()
	assert_false(m.info_panel.visible)
	_click(m, _screen(m, "blue"))
	assert_eq(m.selected, "blue")
	assert_true(m.info_panel.visible)
	assert_true(m.info_label.text.contains("blue"))
	assert_true(m.info_label.text.contains("Test Hull"))
	assert_true(m.info_label.text.contains("Speed"))
	assert_true(m.ships["blue"].select_icon.visible)
	assert_false(m.ships["red"].select_icon.visible)
	assert_false(m.roster_buttons["blue"].flat, "roster row highlighted")
	assert_true(m.roster_buttons["red"].flat)
	assert_eq(m.tracked, "", "a single click doesn't follow")

	_click(m, _screen(m, "runner"))
	assert_eq(m.selected, "runner")
	assert_false(m.ships["blue"].select_icon.visible)
	assert_true(m.roster_buttons["blue"].flat)


func test_click_empty_space_deselects() -> void:
	var m := _select_main()
	_click(m, _screen(m, "blue"))
	_click(m, _empty_spot(m))
	assert_eq(m.selected, "")
	assert_false(m.info_panel.visible)
	assert_false(m.ships["blue"].select_icon.visible)


func test_escape_deselects() -> void:
	var m := _select_main()
	_click(m, _screen(m, "blue"))
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	m._unhandled_input(ev)
	assert_eq(m.selected, "")


func test_drag_does_not_select() -> void:
	var m := _select_main()
	var pos := _screen(m, "blue")
	_mouse(m, pos + Vector2(80, 0), true)
	_mouse(m, pos, false)
	assert_eq(m.selected, "", "drag ending on a ship")
	_click(m, pos)
	_mouse(m, _empty_spot(m), true)
	_mouse(m, _empty_spot(m) + Vector2(50, 50), false)
	assert_eq(m.selected, "blue", "drag from empty space keeps the selection")


func test_double_click_follows() -> void:
	var m := _select_main()
	_click(m, _screen(m, "blue"))
	_click(m, _screen(m, "blue"), true)
	assert_eq(m.selected, "blue")
	assert_eq(m.tracked, "blue")
	assert_true(m.roster_buttons["blue"].button_pressed)
	m._process(1.0)
	assert_almost(m.camera.target, m.ships["blue"].node.position)
	assert_true(m.info_label.text.contains("Following"))

	_click(m, _screen(m, "blue"), true)
	assert_eq(m.tracked, "blue", "double-clicking the followed ship keeps following")
	_click(m, _empty_spot(m), true)
	assert_eq(m.tracked, "blue", "double-clicking empty space doesn't drop the follow")


func test_info_shows_death() -> void:
	var m := _select_main()
	_click(m, _screen(m, "runner"))
	m._seek(10.0)
	m._process(0.0)
	assert_true(m.info_label.text.contains("DEAD"))


func test_reload_drops_missing_selection() -> void:
	var m := _select_main()
	_click(m, _screen(m, "blue"))
	m.load_match(_match_csv())
	assert_eq(m.selected, "blue", "same pilots: kept")
	assert_true(m.ships["blue"].select_icon.visible)
	m.load_match(write_csv([row(0, "red", "Test Hull", on_line(7, 0.5))]))
	assert_eq(m.selected, "")
	assert_false(m.info_panel.visible)


func test_boundary_toggle() -> void:
	var m := _main()
	assert_true(m.boundary.visible)
	m.boundary_toggle.button_pressed = false
	assert_false(m.boundary.visible)


# --- ship models -----------------------------------------------------------------

## A viewer whose asset cache is a temp dir holding the MJU model (standing in for "Test Hull",
## a 50 m frigate) and a couple of brackets, so model mode never touches the network.
func _model_main(cache_model := true) -> Main:
	var m := _main()
	m.sizes.ships = {"test hull": {"name": "Test Hull", "type_id": 33591, "group_id": 25, "radius_m": 50.0}}
	var dir := temp_dir()
	DirAccess.make_dir_recursive_absolute(dir.path_join("models"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("brackets"))
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/fixtures/mobile-micro-jump-unit.glb"),
		dir.path_join("models/33591.glb"))
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	img.save_png(dir.path_join("brackets/frigate_32.png"))
	img.save_png(dir.path_join("brackets/mobilemicrojumpunit.png"))
	var a := m.assets
	a._dir = dir
	a.has_brackets = true
	# Without the model, an empty index keeps `ensure_models` from downloading it.
	a.index = {33591: "extra_models/33591_lite.glb"} if cache_model else {}
	a.models = {33591: ""} if cache_model else {}
	a._scenes.clear()
	a._textures.clear()
	m.load_match(_match_csv())
	return m


func test_models_off_draws_spheres() -> void:
	var m := _model_main()
	assert_false(m.models_on)
	m._seek(0.0)
	m._update_ships()
	var blue: Dictionary = m.ships["blue"]
	assert_eq(blue.model_id, 0)
	assert_eq(blue.visual.mesh, m.sphere_mesh)
	assert_false(blue.icon.visible)
	assert_true(m.markers_box.visible)
	assert_false(m.markers_model.visible)


func test_models_on_draws_model_and_icon() -> void:
	var m := _model_main()
	m._set_models_on(true)
	assert_true(Settings.get_value("display/ship_models"))
	assert_true(m.models_toggle.button_pressed)
	assert_true(m.models_setting.button_pressed)
	m._seek(0.0)
	m._update_ships()
	var blue: Dictionary = m.ships["blue"]
	assert_eq(blue.model_id, 33591)
	assert_false(blue.visual is MeshInstance3D, "model, not the sphere")
	assert_almost(blue.visual.scale, Vector3.ONE * 0.05, 1e-4, "true 50 m radius, no min-size clamp")
	assert_true(blue.icon.visible)
	assert_true(blue.icon.fixed_size)
	assert_not_null(blue.icon.texture)
	assert_false(m.markers_box.visible)
	assert_true(m.markers_model.visible)
	assert_eq(m.markers_model.get_child_count(), 9)

	m._set_models_on(false)
	m._update_ships()
	assert_eq(blue.model_id, 0)
	assert_eq(blue.visual.mesh, m.sphere_mesh)
	assert_false(blue.icon.visible)
	assert_false(Settings.get_value("display/ship_models"))


func test_uncached_model_falls_back_to_sphere_with_icon() -> void:
	var m := _model_main(false)
	m._set_models_on(true)
	m._seek(0.0)
	m._update_ships()
	var blue: Dictionary = m.ships["blue"]
	assert_eq(blue.model_id, 0)
	assert_eq(blue.visual.mesh, m.sphere_mesh)
	assert_true(blue.icon.visible)


func test_model_key_toggles() -> void:
	var m := _model_main()
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_M
	m._unhandled_input(key)
	assert_true(m.models_on)
	m._unhandled_input(key)
	assert_false(m.models_on)


func test_smooth_motion_setting() -> void:
	var m := _main()
	assert_true(m.smooth_on, "on by default")
	m.load_match(_match_csv())
	assert_true(m.data.smooth)
	m._set_smooth_on(false)
	assert_false(m.data.smooth)
	assert_eq(Settings.get_value("display/smooth_motion"), false)
	m.load_match(_match_csv())
	assert_false(m.data.smooth, "new match picks up the setting")


## "p" flies +X at 1 km/s for 10 s, then turns to +Y. Its ship is flagged as a model so
## `_face_heading` rotates it (tests run with models off).
func _turning_ship(m: Main) -> Dictionary:
	var rows := []
	for t in 21:
		var p := C + (X * t if t <= 10 else X * 10.0 + Vector3.UP * (t - 10)) * 1000.0
		rows.append(row(t, "p", "Test Hull", p))
	m.load_match(write_csv(rows))
	var ship: Dictionary = m.ships["p"]
	ship.model_id = 1
	return ship


func _nose(ship: Dictionary) -> Vector3:
	return ship.visual.basis.z.normalized()


func test_smooth_heading_turns_gradually() -> void:
	var m := _main()
	var ship := _turning_ship(m)
	m.time = 5.0
	m._face_heading(ship, "p")
	assert_almost(_nose(ship), X, 1e-3, "first update snaps to the heading")
	var last := _nose(ship)
	var max_step := 0.0
	for i in 100:
		m.time = 5.0 + (i + 1) * 0.1
		m._face_heading(ship, "p")
		max_step = maxf(max_step, last.angle_to(_nose(ship)))
		last = _nose(ship)
	assert_true(max_step < 0.1, "no sudden turn (max %.3f rad per 0.1 s)" % max_step)
	assert_true(_nose(ship).angle_to(Vector3.UP) < 0.1, "ends up facing the new course")


func test_smooth_heading_snaps_on_seek() -> void:
	var m := _main()
	var ship := _turning_ship(m)
	m.time = 5.0
	m._face_heading(ship, "p")
	m.time = 15.0
	m._face_heading(ship, "p")
	assert_almost(_nose(ship), Vector3.UP, 1e-3)


func test_heading_without_smoothing_snaps() -> void:
	var m := _main()
	m._set_smooth_on(false)
	var ship := _turning_ship(m)
	m.time = 9.0
	m._face_heading(ship, "p")
	assert_almost(_nose(ship), X, 1e-3)
	m.time = 10.6
	m._face_heading(ship, "p")
	assert_almost(_nose(ship), Vector3.UP, 1e-3, "faces the new course right away")
