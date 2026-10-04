class_name DamageBreakdown
extends Window
## Incoming damage on one pilot, per attacker: a movable, closable window (several can be open at
## once). `main.gd` owns the data and calls `show_rows` every frame; closing frees the window.

const COLUMNS := ["Pilot", "Ship", "DPS"]

## Pilot whose incoming damage this shows.
var pilot: String
var total_label: Label
var empty_label: Label
var grid: GridContainer
## Labels of the attacker rows, three per row, reused while the row count stays the same.
var _cells: Array[Label] = []


func _init(target := "") -> void:
	pilot = target
	transient = false
	exclusive = false
	wrap_controls = true
	min_size = Vector2i(280, 160)
	size = Vector2i(320, 220)
	close_requested.connect(queue_free)

	var panel := PanelContainer.new()
	var style := panel.get_theme_stylebox("panel").duplicate()
	if style is StyleBoxFlat:
		style.bg_color.a = 1.0
	panel.add_theme_stylebox_override("panel", style)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	total_label = Label.new()
	box.add_child(total_label)
	box.add_child(HSeparator.new())
	empty_label = Label.new()
	empty_label.text = "No incoming damage"
	empty_label.modulate.a = 0.6
	box.add_child(empty_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	grid = GridContainer.new()
	grid.columns = COLUMNS.size()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	scroll.add_child(grid)
	for title in COLUMNS:
		var header := _cell(title == "DPS")
		header.text = title
		header.modulate.a = 0.6
		grid.add_child(header)


## Fills the window: `title`, the `total` DPS and one line per attacker in `rows`
## ({ name, ship, color, dps }), in order.
func show_rows(title_text: String, total: float, rows: Array) -> void:
	title = title_text
	total_label.text = "Total: %d DPS" % roundi(total)
	empty_label.visible = rows.is_empty()
	if _cells.size() != rows.size() * COLUMNS.size():
		for c in _cells:
			grid.remove_child(c)
			c.queue_free()
		_cells.clear()
		for i in rows.size() * COLUMNS.size():
			var c := _cell(i % COLUMNS.size() == 2)
			grid.add_child(c)
			_cells.append(c)
	for i in rows.size():
		var row: Dictionary = rows[i]
		var name_label := _cells[i * 3]
		name_label.text = row.name
		name_label.add_theme_color_override("font_color", row.color)
		_cells[i * 3 + 1].text = row.ship
		_cells[i * 3 + 2].text = "%d" % roundi(row.dps)


static func _cell(right: bool) -> Label:
	var label := Label.new()
	if right:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	else:
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label
