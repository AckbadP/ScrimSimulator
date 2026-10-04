extends "res://tests/test_case.gd"
## RosterTable: column resize / reorder / show-hide, row cells following the layout, and
## persistence through Settings.

var _saved_path: String


func before_each() -> void:
	_saved_path = Settings.path
	Settings.path = temp_dir().path_join("settings.cfg")
	Settings._cfg = null


func after_each() -> void:
	Settings.path = _saved_path
	Settings._cfg = null


func _table() -> RosterTable:
	var t := RosterTable.new()
	add_node(t)
	return t


## Header titles in display order.
func _titles(t: RosterTable) -> Array:
	return t.header.get_children().filter(func(c): return c is Label).map(func(c): return c.text)


## The ids of a row's shown cells, in order.
func _row_ids(t: RosterTable, pilot: String) -> Array:
	var row: Dictionary = t.rows[pilot]
	return row.cells.get_children().filter(func(c): return c.visible).map(func(c): return row.labels.find_key(c))


func test_default_columns() -> void:
	var t := _table()
	assert_eq(t.visible_ids(), ["ship", "pilot", "speed", "distance"])
	assert_eq(_titles(t), ["Ship", "Pilot", "Speed", "Centre"])


func test_row_cells() -> void:
	var t := _table()
	t.add_group("Blue (1)", Color.BLUE)
	var button := t.add_row("p", Color.BLUE, "swap")
	t.set_cell("p", "speed", "12 m/s")
	assert_eq(t.cell_text("p", "speed"), "12 m/s")
	assert_eq(_row_ids(t, "p"), ["ship", "pilot", "speed", "distance"])
	var want := RosterTable.HANDLE_W
	for id in RosterTable.COLUMNS:
		want += RosterTable.COLUMNS[id].width + RosterTable.HANDLE_W
	assert_almost(button.custom_minimum_size.x, want)


func test_signals() -> void:
	var t := _table()
	t.add_row("p", Color.WHITE, "swap")
	var got := []
	t.row_pressed.connect(func(p): got.append("row " + p))
	t.swap_pressed.connect(func(p): got.append("swap " + p))
	t.rows["p"].button.pressed.emit()
	t.rows["p"].button.get_parent().get_child(1).pressed.emit()
	assert_eq(got, ["row p", "swap p"])


func test_divider_moves_boundary() -> void:
	var t := _table()
	t.add_row("p", Color.WHITE, "swap")
	var total := t.total_width()
	var ship: float = t._column("ship").width
	var pilot: float = t._column("pilot").width
	t.move_divider("ship", 20.0)
	assert_almost(t._column("ship").width, ship + 20.0)
	assert_almost(t._column("pilot").width, pilot - 20.0)
	assert_almost(t.total_width(), total, 1e-3, "total unchanged")
	assert_almost(t.rows["p"].labels["ship"].custom_minimum_size.x, ship + 20.0)
	assert_almost(t.header_cells["pilot"].custom_minimum_size.x, pilot - 20.0)
	t.move_divider("ship", 1000.0)
	assert_almost(t._column("pilot").width, RosterTable.MIN_WIDTH)
	assert_almost(t.total_width(), total, 1e-3)


func test_divider_skips_hidden_columns() -> void:
	var t := _table()
	t.set_column_visible("pilot", false)
	var speed: float = t._column("speed").width
	t.move_divider("ship", 10.0)
	assert_almost(t._column("speed").width, speed - 10.0)


func test_edge_scales_columns() -> void:
	var t := _table()
	var widths := t.columns.map(func(c): return c.width)
	t.set_total_width(t.total_width() * 1.5)
	for i in widths.size():
		assert_almost(t.columns[i].width, widths[i] * 1.5)
	t.set_total_width(1.0)
	for c in t.columns:
		assert_almost(c.width, RosterTable.MIN_WIDTH)


func test_autosize_fits_longest_text() -> void:
	var t := _table()
	t.add_row("a", Color.WHITE, "swap")
	t.add_row("b", Color.WHITE, "swap")
	var long := "Very Long Ship Type Name Indeed"
	t.set_cell("a", "ship", long)
	t.set_cell("b", "ship", "Atron")
	t.autosize("ship")
	var label: Label = t.header_cells["ship"]
	var font := label.get_theme_font("font")
	var want := font.get_string_size(long, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
	assert_true(t._column("ship").width >= want, "fits the longest cell")
	t.set_cell("a", "ship", "Atron")
	t.autosize("ship")
	assert_true(t._column("ship").width < want, "shrinks to shorter text")


func _press(x: float, double := false, pressed := true) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.double_click = double
	e.global_position = Vector2(x, 0)
	return e


func _motion(x: float) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.global_position = Vector2(x, 0)
	return e


func test_handle_input_divider_drag() -> void:
	var t := _table()
	var ship: float = t._column("ship").width
	var pilot: float = t._column("pilot").width
	t._on_handle_input(_press(100.0), "divider", "ship")
	t._on_handle_input(_motion(110.0), "divider", "ship")
	t._on_handle_input(_motion(115.0), "divider", "ship")
	assert_almost(t._column("ship").width, ship + 15.0, 1e-3, "relative to the press, not cumulative")
	assert_almost(t._column("pilot").width, pilot - 15.0)
	t._on_handle_input(_press(115.0, false, false), "divider", "ship")
	Settings._cfg = null
	assert_almost(RosterTable._load_columns(Settings.get_value("roster/columns"))[0].width, ship + 15.0)


func test_handle_input_edge_drag() -> void:
	var t := _table()
	var total := t.total_width()
	t._on_handle_input(_press(500.0), "edge", "")
	t._on_handle_input(_motion(500.0 - total / 2.0), "edge", "")
	assert_almost(t.total_width(), total * 1.5, 1e-2, "dragging left widens")
	t._on_handle_input(_motion(500.0 + total / 2.0), "edge", "")
	assert_almost(t.total_width(), total * 0.5, 1e-2, "dragging right narrows")


func test_last_grip_not_draggable_but_autosizes() -> void:
	var t := _table()
	var widths := t.columns.map(func(c): return c.width)
	t._on_handle_input(_press(100.0), "last", "distance")
	t._on_handle_input(_motion(150.0), "last", "distance")
	assert_eq(t.columns.map(func(c): return c.width), widths)
	t._on_handle_input(_press(100.0, true), "last", "distance")
	assert_ne(t._column("distance").width, widths[3], "double-click fits the header")


func test_move_column() -> void:
	var t := _table()
	t.add_row("p", Color.WHITE, "swap")
	t.move_column("distance", 0)
	assert_eq(t.visible_ids(), ["distance", "ship", "pilot", "speed"])
	assert_eq(_titles(t), ["Centre", "Ship", "Pilot", "Speed"])
	assert_eq(_row_ids(t, "p"), ["distance", "ship", "pilot", "speed"])


func test_drop_column_by_half() -> void:
	var t := _table()
	var pilot_label: Label = t.header_cells["pilot"]
	pilot_label.size = Vector2(100, 20)
	t._drop_column(Vector2(80, 5), {"roster_column": "ship"}, "pilot", pilot_label)
	assert_eq(t.visible_ids(), ["pilot", "ship", "speed", "distance"], "right half: after")
	var speed_label: Label = t.header_cells["speed"]
	speed_label.size = Vector2(100, 20)
	t._drop_column(Vector2(10, 5), {"roster_column": "distance"}, "speed", speed_label)
	assert_eq(t.visible_ids(), ["pilot", "ship", "distance", "speed"], "left half: before")


func test_hide_and_show() -> void:
	var t := _table()
	t.add_row("p", Color.WHITE, "swap")
	t.set_column_visible("pilot", false)
	assert_eq(_titles(t), ["Ship", "Speed", "Centre"])
	assert_eq(_row_ids(t, "p"), ["ship", "speed", "distance"])
	assert_false(t.menu.is_item_checked(1))
	t.menu.index_pressed.emit(1)
	assert_eq(t.visible_ids(), ["ship", "pilot", "speed", "distance"], "menu toggles it back")


func test_last_column_cannot_be_hidden() -> void:
	var t := _table()
	for id in ["ship", "pilot", "speed"]:
		t.set_column_visible(id, false)
	assert_true(t.menu.is_item_disabled(3))
	t.set_column_visible("distance", false)
	assert_eq(t.visible_ids(), ["distance"])


func test_layout_persists() -> void:
	var t := _table()
	t.move_column("speed", 0)
	t.set_column_width("pilot", 150.0)
	t.set_column_visible("ship", false)
	Settings._cfg = null  # Force a reload from disk.
	var t2 := _table()
	assert_eq(t2.visible_ids(), ["speed", "pilot", "distance"])
	assert_almost(t2._column("pilot").width, 150.0)


func test_load_repairs_saved_layout() -> void:
	var cols := RosterTable._load_columns([
		{"id": "bogus", "width": 50},
		{"id": "speed", "width": 1, "visible": false},
		{"id": "speed", "width": 90},
		"junk",
	])
	assert_eq(cols.map(func(c): return c.id), ["speed", "ship", "pilot", "distance"])
	assert_almost(cols[0].width, RosterTable.MIN_WIDTH)
	assert_false(cols[0].visible)
	var hidden := RosterTable._load_columns(RosterTable.COLUMNS.keys().map(
			func(id): return {"id": id, "visible": false}))
	assert_true(hidden[0].visible, "never all hidden")
