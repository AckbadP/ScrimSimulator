extends Node3D
## Replays a `scrim-positions` CSV: one hull model (or sphere) per pilot moving through the
## observers' 100 km cube.
## Load a CSV with `godot --path simulator -- --csv <file>`, the Open button, or drag-and-drop.

## 1 scene unit = 1 km.
const M_TO_UNITS := 0.001
const CUBE := 100.0
const SPEEDS := [0.5, 1.0, 2.0, 5.0, 10.0, 30.0]
const SEEK_STEP_S := 10.0
## Ships are drawn at their real hull radius, but never smaller than this angle (radians) as
## seen from the camera, so frigates stay visible from across the arena.
const MIN_VISIBLE_ANGLE := 0.005
## Ship models are drawn at their true size; their overview bracket icon keeps them visible.
const ICON_PX := 20.0
## Corner and centre MJUs are drawn this big (the SDE radius of deployables is meaningless).
const MJU_RADIUS_KM := 1.0
## Below this speed (m/s) a model keeps its last heading.
const MIN_HEADING_SPEED := 5.0
## Hull models point their nose along +Z; `Basis.looking_at` aims -Z, so turn them around.
const MODEL_FORWARD := Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1))
const CORNER_COLOR := Color(0.3, 0.7, 1.0)
const CENTRE_COLOR := Color(1.0, 0.8, 0.2)
const BOUNDARY_KM := MatchData.BOUNDARY_RADIUS_M * M_TO_UNITS
const BOUNDARY_COLOR := Color(1.0, 0.45, 0.15)
const TEAM_COLORS := {
	MatchData.Team.BLUE: Color(0.25, 0.5, 1.0),
	MatchData.Team.RED: Color(1.0, 0.25, 0.2),
	MatchData.Team.UNKNOWN: Color(0.6, 0.6, 0.6),
}

var data: MatchData
var match_path := ""
var time := 0.0
var playing := false
var speed := 1.0

## pilot -> { node, visual, model_id, icon, label, ship_type, radius, dead, color, tint, death_t,
## death_marker }; `radius` is the true hull radius in scene units (0 if unknown), `visual` the
## sphere or model under `node`, `model_id` the type ID it shows (0 = sphere), `tint` the colour
## the ship is currently drawn in.
var ships := {}
var ships_root: Node3D
var boundary: Node3D
var camera: Camera3D
var sphere_mesh := SphereMesh.new()
var sizes: ShipSizes
var assets: ShipAssets
## Draw hull models + bracket icons instead of spheres (setting `display/ship_models`).
var models_on := true
## Corner/centre markers: plain boxes, or MJU models + icons.
var markers_box: Node3D
var markers_model: Node3D

var open_dialog: FileDialog
var play_button: Button
var timeline: HSlider
var time_label: Label
var boundary_toggle: CheckButton
var models_toggle: CheckButton
var models_setting: CheckBox
var file_label: Label
var sde_label: Label
var settings_popup: PopupPanel
var download_dialog: ConfirmationDialog
var assets_dialog: ConfirmationDialog
var _scrubbing := false


func _ready() -> void:
	sphere_mesh.radius = 1.0
	sphere_mesh.height = 2.0
	sizes = ShipSizes.new()
	add_child(sizes)
	assets = ShipAssets.new()
	add_child(assets)
	models_on = Settings.get_value("display/ship_models")
	_build_environment()
	_build_markers()
	_build_boundary()
	ships_root = Node3D.new()
	add_child(ships_root)
	_build_ui()
	get_window().files_dropped.connect(_on_files_dropped)

	sde_label.text = sizes.status
	sizes.status_changed.connect(func(text): sde_label.text = text)
	sizes.needs_download.connect(_prompt_download)
	sizes.sizes_changed.connect(_on_sizes_changed)
	sizes.start(Settings.get_value("sde/auto_update"))
	assets.status_changed.connect(func(text): sde_label.text = text)
	assets.needs_download.connect(_prompt_assets)
	assets.assets_changed.connect(_on_assets_changed)
	assets.start(models_on, Settings.get_value("sde/auto_update"))
	_apply_visual_mode()

	var args := OS.get_cmdline_user_args()
	var i := args.find("--csv")
	if i >= 0 and i + 1 < args.size():
		load_match(args[i + 1])


func load_match(path: String) -> void:
	var d := MatchData.load_csv(path, sizes.radii())
	if d == null:
		file_label.text = "Failed to load %s" % path.get_file()
		return
	data = d
	match_path = path
	for c in ships_root.get_children():
		c.queue_free()
	ships.clear()
	for pilot in data.tracks:
		_add_ship(pilot)
	_fetch_models()
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


## New SDE data: reload the match so sizes and boundary deaths use it, keeping playback state.
func _on_sizes_changed() -> void:
	if data == null:
		return
	var t := time
	var was_playing := playing
	load_match(match_path)
	_seek(t)
	_set_playing(was_playing)


func _prompt_download(reason: String) -> void:
	download_dialog.dialog_text = "%s\n\nDownload it now (~100 MB) so ships are sized by their real hull radius?" % reason
	if assets_dialog.visible:
		await assets_dialog.visibility_changed
	download_dialog.popup_centered()


func _prompt_assets(reason: String) -> void:
	assets_dialog.dialog_text = "%s\n\nDownload the overview icons now (~18 MB)? Hull models (~1–2 MB each) are then fetched as matches need them." % reason
	if download_dialog.visible:
		await download_dialog.visibility_changed
	assets_dialog.popup_centered()


## New models or icons on disk: redraw ships and markers with them.
func _on_assets_changed() -> void:
	for pilot in ships:
		ships[pilot].ship_type = ""  # Forces `_update_ships` to rebuild the visual.
	_fetch_models()
	_build_mju_markers()


## Queues downloads of the hulls in the loaded match, plus the MJU for the markers.
func _fetch_models() -> void:
	if not models_on:
		return
	var ids := [ShipAssets.MJU_TYPE_ID]
	if data != null:
		for pilot in data.tracks:
			for s in data.tracks[pilot]:
				var id: int = sizes.ship(s.ship_type).get("type_id", 0)
				if id > 0 and not ids.has(id):
					ids.append(id)
	assets.ensure_models(ids)


func _set_models_on(on: bool) -> void:
	if on == models_on:
		return
	models_on = on
	Settings.set_value("display/ship_models", on)
	models_toggle.set_pressed_no_signal(on)
	models_setting.set_pressed_no_signal(on)
	if on:
		assets.start(true, false)
	_apply_visual_mode()


## Switches ships and markers between models + icons and spheres + boxes.
func _apply_visual_mode() -> void:
	markers_box.visible = not models_on
	markers_model.visible = models_on
	if models_on:
		_fetch_models()
		_build_mju_markers()
	for pilot in ships:
		ships[pilot].ship_type = ""


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
	if event.keycode == KEY_M:
		_set_models_on(not models_on)
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

	var visual := _sphere()
	node.add_child(visual)

	var icon := _icon()
	node.add_child(icon)

	var label := _label(color)
	node.add_child(label)

	node.visible = false
	ships_root.add_child(node)
	ships[pilot] = {
		"node": node, "visual": visual, "model_id": 0, "icon": icon, "label": label,
		"ship_type": "", "radius": 0.0, "dead": false, "color": color, "tint": color,
		"death_t": INF, "death_marker": null,
	}
	if data.deaths.has(pilot):
		var death: Dictionary = data.deaths[pilot]
		ships[pilot].death_t = death.t
		ships[pilot].death_marker = _death_marker(pilot, death, color)


func _sphere() -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = sphere_mesh
	return mesh


## Overview bracket overlay: constant on-screen size, drawn over everything.
static func _icon() -> Sprite3D:
	var icon := Sprite3D.new()
	icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	icon.fixed_size = true
	icon.no_depth_test = true
	icon.shaded = false
	icon.render_priority = 1
	icon.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	icon.visible = false
	return icon


## Points the icon at `tex`, sized to `ICON_PX` on screen, or hides it.
func _set_icon(icon: Sprite3D, tex: Texture2D, color: Color) -> void:
	icon.texture = tex
	icon.visible = tex != null
	if tex:
		# A fixed_size sprite is drawn as if it were 1 unit from the camera.
		icon.pixel_size = _units_per_px(1.0) * ICON_PX / tex.get_height()
		icon.modulate = color


## Scene units spanned by one screen pixel at distance `d` from the camera.
func _units_per_px(d: float) -> float:
	return d * 2.0 * tan(deg_to_rad(camera.fov) / 2.0) / get_viewport().get_visible_rect().size.y


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
		var pos: Vector3 = s.pos * M_TO_UNITS
		_face_heading(ship, pilot, pos)
		node.position = pos
		if s.ship_type != ship.ship_type or dead != ship.dead:
			ship.ship_type = s.ship_type
			ship.radius = data.radius_m(s.ship_type) * M_TO_UNITS
			ship.dead = dead
			ship.label.text = "%s\n%s%s" % [pilot, s.ship_type, "\nDEAD (out of bounds)" if dead else ""]
			var pod: bool = s.ship_type == "Capsule"
			var color: Color = ship.color.darkened(0.5) if pod else ship.color
			if dead:
				color = color.lerp(Color(0.5, 0.5, 0.5), 0.6)
				color.a = 0.4
			ship.tint = color
			_refresh_visual(ship)
			ship.label.modulate = color if not dead else Color(color, 0.7)
		var r: float = ship.radius
		if ship.model_id == 0 or r <= 0.0:
			r = maxf(r, camera.global_position.distance_to(node.position) * MIN_VISIBLE_ANGLE)
		ship.visual.scale = Vector3.ONE * r
		ship.label.position.y = r * 1.6 if not ship.icon.visible else maxf(r * 1.6, _icon_clearance(node))


## Swaps `ship.visual` to the hull model (models on and cached) or the sphere, and tints it.
func _refresh_visual(ship: Dictionary) -> void:
	var info := sizes.ship(ship.ship_type)
	var type_id: int = info.get("type_id", 0) if models_on else 0
	var want := type_id if assets.has_model(type_id) else 0
	if want != ship.model_id or ship.visual == null:
		var visual: Node3D = assets.instance_model(want) if want else null
		if visual == null:
			want = 0
			visual = _sphere()
		if ship.visual:
			ship.visual.queue_free()
		ship.node.add_child(visual)
		ship.visual = visual
		ship.model_id = want
	var color: Color = ship.tint
	if ship.model_id == 0:
		ship.visual.material_override = _material(color, true)
	else:
		for m in ship.visual.find_children("*", "GeometryInstance3D", true, false):
			m.transparency = 0.6 if ship.dead else 0.0
	var tex: Texture2D = null
	if models_on and info:
		tex = assets.bracket(info.group_id, sizes.ship_groups.get(info.group_id, ""))
	_set_icon(ship.icon, tex, Color(color, maxf(color.a, 0.7)))


## Turns model ships to face along their movement (half a second of track).
func _face_heading(ship: Dictionary, pilot: String, pos: Vector3) -> void:
	if ship.model_id == 0:
		return
	var prev := data.sample(pilot, time - 0.5)
	if prev.is_empty():
		return
	var v: Vector3 = (pos - prev.pos * M_TO_UNITS) / 0.5 / M_TO_UNITS
	if v.length() < MIN_HEADING_SPEED:
		return
	var up := Vector3.UP if absf(v.normalized().y) < 0.99 else Vector3.RIGHT
	ship.visual.basis = Basis.looking_at(v, up) * MODEL_FORWARD


## Scene units from the node's centre to just above an `ICON_PX` icon at the camera's distance.
func _icon_clearance(node: Node3D) -> float:
	return _units_per_px(camera.global_position.distance_to(node.global_position)) * ICON_PX * 0.75


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

	camera = Camera3D.new()
	camera.set_script(preload("res://scripts/orbit_camera.gd"))
	camera.target = Vector3.ONE * CUBE / 2.0
	add_child(camera)


## Positions of the 8 corner markers, then the centre one.
static func _marker_positions() -> Array:
	var out := []
	for i in 8:
		out.append(Vector3(i & 1, (i >> 1) & 1, (i >> 2) & 1) * CUBE)
	out.append(Vector3.ONE * CUBE / 2.0)
	return out


func _build_markers() -> void:
	markers_box = Node3D.new()
	add_child(markers_box)
	markers_model = Node3D.new()
	add_child(markers_model)
	var box := BoxMesh.new()
	box.size = Vector3.ONE * 2.0
	var corner_mat := _material(CORNER_COLOR, false)
	var centre_mat := _material(CENTRE_COLOR, false)
	var positions := _marker_positions()
	for i in positions.size():
		var m := MeshInstance3D.new()
		m.mesh = box
		m.material_override = corner_mat if i < 8 else centre_mat
		m.position = positions[i]
		markers_box.add_child(m)

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


## (Re)builds the MJU marker set from whatever model and icon are cached; boxes stand in for a
## missing model.
func _build_mju_markers() -> void:
	if not models_on:
		return
	for c in markers_model.get_children():
		c.queue_free()
	var tex := assets.bracket_texture(ShipAssets.MJU_BRACKET)
	var positions := _marker_positions()
	for i in positions.size():
		var color := CORNER_COLOR if i < 8 else CENTRE_COLOR
		var marker := Node3D.new()
		marker.position = positions[i]
		var model: Node3D = assets.instance_model(ShipAssets.MJU_TYPE_ID)
		if model:
			model.scale = Vector3.ONE * MJU_RADIUS_KM
		else:
			model = markers_box.get_child(i).duplicate()
		marker.add_child(model)
		var icon := _icon()
		marker.add_child(icon)
		_set_icon(icon, tex, color)
		markers_model.add_child(marker)


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

	models_toggle = CheckButton.new()
	models_toggle.text = "Ship models (M)"
	models_toggle.button_pressed = models_on
	models_toggle.focus_mode = Control.FOCUS_NONE
	models_toggle.toggled.connect(_set_models_on)
	row.add_child(models_toggle)

	time_label = Label.new()
	time_label.text = "--:-- / --:--"
	row.add_child(time_label)

	var settings_button := Button.new()
	settings_button.text = "Settings…"
	settings_button.pressed.connect(func(): settings_popup.popup_centered())
	row.add_child(settings_button)

	sde_label = Label.new()
	sde_label.modulate = Color(1, 1, 1, 0.6)
	row.add_child(sde_label)

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

	download_dialog = ConfirmationDialog.new()
	download_dialog.title = "EVE Static Data Export"
	download_dialog.ok_button_text = "Download"
	download_dialog.cancel_button_text = "Not now"
	download_dialog.confirmed.connect(sizes.full_download)
	layer.add_child(download_dialog)

	assets_dialog = ConfirmationDialog.new()
	assets_dialog.title = "EVE ship models"
	assets_dialog.ok_button_text = "Download"
	assets_dialog.cancel_button_text = "Not now"
	assets_dialog.confirmed.connect(assets.full_download)
	layer.add_child(assets_dialog)

	_build_settings(layer)


func _build_settings(layer: CanvasLayer) -> void:
	settings_popup = PopupPanel.new()
	layer.add_child(settings_popup)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	settings_popup.add_child(box)

	var title := Label.new()
	title.text = "Settings"
	box.add_child(title)

	var auto_update := CheckBox.new()
	auto_update.text = "Check for EVE static data (SDE) and ship model updates on startup"
	auto_update.button_pressed = Settings.get_value("sde/auto_update")
	auto_update.toggled.connect(func(on): Settings.set_value("sde/auto_update", on))
	box.add_child(auto_update)

	models_setting = CheckBox.new()
	models_setting.text = "Draw ships as hull models with overview icons (instead of spheres)"
	models_setting.button_pressed = models_on
	models_setting.toggled.connect(_set_models_on)
	box.add_child(models_setting)

	var status := Label.new()
	status.text = sizes.status
	sizes.status_changed.connect(func(text): status.text = text)
	box.add_child(status)

	var assets_status := Label.new()
	assets_status.text = assets.status
	assets.status_changed.connect(func(text): assets_status.text = text)
	box.add_child(assets_status)

	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	var check := Button.new()
	check.text = "Check for updates now"
	check.pressed.connect(func():
		sizes.check_update()
		assets.check_update())
	buttons.add_child(check)
	var redownload := Button.new()
	redownload.text = "Re-download SDE"
	redownload.pressed.connect(sizes.full_download)
	buttons.add_child(redownload)
	var models_download := Button.new()
	models_download.text = "Download ship icons"
	models_download.pressed.connect(assets.full_download)
	buttons.add_child(models_download)


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.get_extension().to_lower() == "csv":
			load_match(f)
			return
