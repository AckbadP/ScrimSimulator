extends Node3D
## Replays a `scrim-positions` CSV: one sphere per pilot moving through the observers' 100 km cube.
## Load a CSV with `godot --path simulator -- --csv <file>`, the Open button, or drag-and-drop.

## 1 scene unit = 1 km.
const M_TO_UNITS := 0.001
const CUBE := 100.0
const SPEEDS := [0.5, 1.0, 2.0, 5.0, 10.0, 30.0]
const SEEK_STEP_S := 10.0
const BOUNDARY_KM := MatchData.BOUNDARY_RADIUS_M * M_TO_UNITS
const BOUNDARY_COLOR := Color(1.0, 0.45, 0.15)
const TEAM_COLORS := {
	MatchData.Team.BLUE: Color(0.25, 0.5, 1.0),
	MatchData.Team.RED: Color(1.0, 0.25, 0.2),
	MatchData.Team.UNKNOWN: Color(0.6, 0.6, 0.6),
}

var data: MatchData
var time := 0.0
var playing := false
var speed := 1.0

var ships := {}  # pilot -> { node, mesh, label, ship_type, dead, color, death_t, death_marker }
var ships_root: Node3D
var boundary: Node3D
var sphere_mesh := SphereMesh.new()

var open_dialog: FileDialog
var play_button: Button
var timeline: HSlider
var time_label: Label
var boundary_toggle: CheckButton
var file_label: Label
var _scrubbing := false


func _ready() -> void:
	sphere_mesh.radius = 1.5
	sphere_mesh.height = 3.0
	_build_environment()
	_build_markers()
	_build_boundary()
	ships_root = Node3D.new()
	add_child(ships_root)
	_build_ui()
	get_window().files_dropped.connect(_on_files_dropped)

	var args := OS.get_cmdline_user_args()
	var i := args.find("--csv")
	if i >= 0 and i + 1 < args.size():
		load_match(args[i + 1])


func load_match(path: String) -> void:
	var d := MatchData.load_csv(path)
	if d == null:
		file_label.text = "Failed to load %s" % path.get_file()
		return
	data = d
	for c in ships_root.get_children():
		c.queue_free()
	ships.clear()
	for pilot in data.tracks:
		_add_ship(pilot)
	timeline.max_value = data.duration
	var counts := {MatchData.Team.BLUE: 0, MatchData.Team.RED: 0, MatchData.Team.UNKNOWN: 0}
	for pilot in data.teams:
		counts[data.teams[pilot]] += 1
	file_label.text = "%s — %d pilots (blue %d / red %d / unknown %d), %d out of bounds" % [
		path.get_file(), ships.size(),
		counts[MatchData.Team.BLUE], counts[MatchData.Team.RED], counts[MatchData.Team.UNKNOWN],
		data.deaths.size(),
	]
	print("Loaded %s: %d pilots, %.0f s" % [path, ships.size(), data.duration])
	for pilot in data.teams:
		print("  %s: %s" % [pilot, MatchData.Team.find_key(data.teams[pilot])])
	for pilot in data.deaths:
		print("  %s: out of bounds at %s" % [pilot, _fmt_time(data.deaths[pilot].t)])
	_seek(0.0)
	_set_playing(true)


func _process(delta: float) -> void:
	if data == null:
		return
	if playing and not _scrubbing:
		time += delta * speed
		if time >= data.duration:
			time = data.duration
			_set_playing(false)
	_update_ships()
	if not _scrubbing:
		timeline.set_value_no_signal(time)
	time_label.text = "%s / %s" % [_fmt_time(time), _fmt_time(data.duration)]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	if event.keycode == KEY_B:
		boundary_toggle.button_pressed = not boundary_toggle.button_pressed
		return
	if data == null:
		return
	match event.keycode:
		KEY_SPACE:
			_toggle_play()
		KEY_LEFT:
			_seek(time - SEEK_STEP_S)
		KEY_RIGHT:
			_seek(time + SEEK_STEP_S)


# --- ships -------------------------------------------------------------------

func _add_ship(pilot: String) -> void:
	var node := Node3D.new()
	node.name = pilot.validate_node_name()
	var color: Color = TEAM_COLORS[data.teams.get(pilot, MatchData.Team.UNKNOWN)]

	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere_mesh
	mesh.material_override = _material(color, true)
	node.add_child(mesh)

	var label := _label(color)
	node.add_child(label)

	node.visible = false
	ships_root.add_child(node)
	ships[pilot] = {
		"node": node, "mesh": mesh, "label": label, "ship_type": "", "dead": false, "color": color,
		"death_t": INF, "death_marker": null,
	}
	if data.deaths.has(pilot):
		var death: Dictionary = data.deaths[pilot]
		ships[pilot].death_t = death.t
		ships[pilot].death_marker = _death_marker(pilot, death, color)


## An X where `pilot` crossed the boundary, labelled with the time.
func _death_marker(pilot: String, death: Dictionary, color: Color) -> Node3D:
	var marker := Node3D.new()
	marker.position = death.pos * M_TO_UNITS
	var bar := BoxMesh.new()
	bar.size = Vector3(4.0, 0.4, 0.4)
	var mat := _material(color, false)
	for angle in [45.0, -45.0]:
		var m := MeshInstance3D.new()
		m.mesh = bar
		m.material_override = mat
		m.rotation_degrees.z = angle
		marker.add_child(m)
	var label := _label(color)
	label.text = "%s ✕ %s" % [pilot, _fmt_time(death.t)]
	marker.add_child(label)
	marker.visible = false
	ships_root.add_child(marker)
	return marker


static func _label(color: Color) -> Label3D:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = 0.0008
	label.font_size = 24
	label.outline_size = 6
	label.no_depth_test = true
	label.modulate = color
	label.position = Vector3(0, 2.5, 0)
	return label


func _update_ships() -> void:
	for pilot in ships:
		var ship: Dictionary = ships[pilot]
		var dead: bool = time >= ship.death_t
		if ship.death_marker:
			ship.death_marker.visible = dead
		var s := data.sample(pilot, time)
		var node: Node3D = ship.node
		if s.is_empty():
			node.visible = false
			continue
		node.visible = true
		node.position = s.pos * M_TO_UNITS
		if s.ship_type != ship.ship_type or dead != ship.dead:
			ship.ship_type = s.ship_type
			ship.dead = dead
			ship.label.text = "%s\n%s%s" % [pilot, s.ship_type, "\nDEAD (out of bounds)" if dead else ""]
			var pod: bool = s.ship_type == "Capsule"
			ship.mesh.scale = Vector3.ONE * (0.5 if pod else 1.0)
			var color: Color = ship.color.darkened(0.5) if pod else ship.color
			if dead:
				color = color.lerp(Color(0.5, 0.5, 0.5), 0.6)
				color.a = 0.4
			ship.mesh.material_override = _material(color, true)
			ship.label.modulate = color if not dead else Color(color, 0.7)


# --- playback ----------------------------------------------------------------

func _seek(t: float) -> void:
	if data == null:
		return
	time = clampf(t, 0.0, data.duration)
	timeline.set_value_no_signal(time)


func _toggle_play() -> void:
	if data == null:
		return
	if not playing and time >= data.duration:
		time = 0.0
	_set_playing(not playing)


func _set_playing(p: bool) -> void:
	playing = p
	play_button.text = "Pause" if p else "Play"


static func _fmt_time(t: float) -> String:
	var s := int(t)
	return "%02d:%02d" % [s / 60, s % 60]


# --- scene -------------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.035, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)

	var cam := Camera3D.new()
	cam.set_script(preload("res://scripts/orbit_camera.gd"))
	cam.target = Vector3.ONE * CUBE / 2.0
	add_child(cam)


func _build_markers() -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 2.0
	var corner_mat := _material(Color(0.3, 0.7, 1.0), false)
	for i in 8:
		var m := MeshInstance3D.new()
		m.mesh = box
		m.material_override = corner_mat
		m.position = Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1) * CUBE
		add_child(m)

	var centre := MeshInstance3D.new()
	centre.mesh = box
	centre.material_override = _material(Color(1.0, 0.8, 0.2), false)
	centre.position = Vector3.ONE * CUBE / 2.0
	add_child(centre)

	# Cube edges, for orientation.
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for a in 8:
		for axis in 3:
			var b := a | (1 << axis)
			if b != a:
				lines.surface_add_vertex(Vector3(a & 1, (a >> 1) & 1, (a >> 2) & 1) * CUBE)
				lines.surface_add_vertex(Vector3(b & 1, (b >> 1) & 1, (b >> 2) & 1) * CUBE)
	lines.surface_end()
	var edges := MeshInstance3D.new()
	edges.mesh = lines
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.albedo_color = Color(0.3, 0.5, 0.7, 0.5)
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edges.material_override = line_mat
	add_child(edges)


## Arena boundary: a wireframe sphere plus a faint shell, centred on the cube.
func _build_boundary() -> void:
	boundary = Node3D.new()
	boundary.position = Vector3.ONE * CUBE / 2.0
	add_child(boundary)

	const SEGMENTS := 96
	const MERIDIANS := 8
	const PARALLELS := 5
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	for k in MERIDIANS:
		var lon := PI * k / MERIDIANS
		for j in SEGMENTS:
			for a in [TAU * j / SEGMENTS, TAU * (j + 1) / SEGMENTS]:
				lines.surface_add_vertex(Vector3(cos(a) * cos(lon), sin(a), cos(a) * sin(lon)) * BOUNDARY_KM)
	for k in PARALLELS:
		var lat := PI * (k + 1) / (PARALLELS + 1) - PI / 2.0
		for j in SEGMENTS:
			for a in [TAU * j / SEGMENTS, TAU * (j + 1) / SEGMENTS]:
				lines.surface_add_vertex(Vector3(cos(a) * cos(lat), sin(lat), sin(a) * cos(lat)) * BOUNDARY_KM)
	lines.surface_end()
	var wire := MeshInstance3D.new()
	wire.mesh = lines
	wire.material_override = _material(Color(BOUNDARY_COLOR, 0.25), false)
	boundary.add_child(wire)

	var sphere := SphereMesh.new()
	sphere.radius = BOUNDARY_KM
	sphere.height = BOUNDARY_KM * 2.0
	sphere.radial_segments = 64
	sphere.rings = 32
	var shell_mat := _material(Color(BOUNDARY_COLOR, 0.04), false)
	shell_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var shell := MeshInstance3D.new()
	shell.mesh = sphere
	shell.material_override = shell_mat
	boundary.add_child(shell)


static func _material(color: Color, shaded: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if not shaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


# --- UI ----------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(panel)

	var box := VBoxContainer.new()
	panel.add_child(box)

	var row := HBoxContainer.new()
	box.add_child(row)

	var open_button := Button.new()
	open_button.text = "Open CSV…"
	open_button.pressed.connect(func(): open_dialog.popup_centered_ratio(0.6))
	row.add_child(open_button)

	play_button = Button.new()
	play_button.text = "Play"
	play_button.custom_minimum_size.x = 70
	play_button.pressed.connect(_toggle_play)
	row.add_child(play_button)

	var speed_option := OptionButton.new()
	for s in SPEEDS:
		speed_option.add_item("%sx" % s)
	speed_option.select(SPEEDS.find(1.0))
	speed_option.item_selected.connect(func(idx): speed = SPEEDS[idx])
	row.add_child(speed_option)

	boundary_toggle = CheckButton.new()
	boundary_toggle.text = "125 km boundary (B)"
	boundary_toggle.button_pressed = true
	boundary_toggle.focus_mode = Control.FOCUS_NONE
	boundary_toggle.toggled.connect(func(on): boundary.visible = on)
	row.add_child(boundary_toggle)

	time_label = Label.new()
	time_label.text = "--:-- / --:--"
	row.add_child(time_label)

	file_label = Label.new()
	file_label.text = "No match loaded — open or drop a *.positions.csv"
	file_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(file_label)

	timeline = HSlider.new()
	timeline.step = 0.0
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.value_changed.connect(_seek)
	timeline.drag_started.connect(func(): _scrubbing = true)
	timeline.drag_ended.connect(func(_changed): _scrubbing = false)
	box.add_child(timeline)

	open_dialog = FileDialog.new()
	open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	open_dialog.filters = PackedStringArray(["*.csv ; CSV files"])
	open_dialog.use_native_dialog = true
	open_dialog.file_selected.connect(load_match)
	layer.add_child(open_dialog)


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.get_extension().to_lower() == "csv":
			load_match(f)
			return
