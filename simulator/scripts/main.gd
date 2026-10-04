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
## With smooth motion, heading is the average velocity over this many seconds either side of
## now (evens out tracking noise), and models turn toward it with this time constant (match s).
const HEADING_WINDOW_S := 2.0
const TURN_TIME_S := 0.6
## A playback step longer than this (a seek) snaps models to their heading instead of turning.
const MAX_TURN_STEP_S := 2.0
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
const TEAM_NAMES := {
	MatchData.Team.BLUE: "Blue",
	MatchData.Team.RED: "Red",
	MatchData.Team.UNKNOWN: "Unknown",
}
## A click lands on a ship within this many pixels of its centre (or anywhere on its hull).
const PICK_PX := 14.0
## A left press released within this many pixels is a click; further is a camera drag.
const CLICK_SLOP_PX := 4.0
## The selection bracket is this many times the size of the overview icon.
const SELECT_SCALE := 1.8
const SELECT_COLOR := Color(1, 1, 1, 0.9)
const MJD_COLOR := Color(0.3, 0.9, 0.9)
## Timeline tick colour and legend name per `MatchData.Event`.
const EVENT_COLORS := {
	MatchData.Event.DEATH: Color(1.0, 0.3, 0.55),
	MatchData.Event.BOUNDARY: BOUNDARY_COLOR,
	MatchData.Event.MJD: MJD_COLOR,
}
const EVENT_NAMES := {
	MatchData.Event.DEATH: "Podded",
	MatchData.Event.BOUNDARY: "Out of bounds",
	MatchData.Event.MJD: "MJD",
}
## Jumping to an event lands this many seconds before it, to see the lead-up.
const EVENT_LEAD_S := 2.0
## A micro jump's take-off -> landing line stays up this long (match s) after the jump.
const MJD_TRAIL_S := 5.0

var data: MatchData
var match_path := ""
var time := 0.0
var playing := false
var speed := 1.0
## Pilot the camera stays centred on ("" = free camera).
var tracked := ""
## Pilot picked by clicking it in space ("" = none); shown in the info panel.
var selected := ""
## pilot -> Team picked with the roster's swap button; kept when the same match reloads.
var team_overrides := {}

## pilot -> { node, visual, model_id, icon, select_icon, label, ship_type, radius, dead, color, tint, death_t,
## death_marker, heading, heading_t }; `heading` is the model's rotation as of match time
## `heading_t`; `radius` is the true hull radius in scene units (0 if unknown), `visual` the
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
## Smooth ship paths between samples (setting `display/smooth_motion`).
var smooth_on := true
## Corner/centre markers: plain boxes, or MJU models + icons.
var markers_box: Node3D
var markers_model: Node3D

var open_dialog: FileDialog
var play_button: Button
var timeline: HSlider
var event_strip: EventStrip
## { t: float, node: Node3D } per micro jump: a line from take-off to landing.
var mjd_trails: Array = []
var time_label: Label
var boundary_toggle: CheckButton
var models_toggle: CheckButton
var models_setting: CheckBox
## Match-start jitter settings: on/off and threshold (metres).
var jitter_setting: CheckBox
var jitter_spin: SpinBox
var file_label: Label
var sde_label: Label
var settings_popup: PopupPanel
var download_dialog: ConfirmationDialog
var assets_dialog: ConfirmationDialog
var bottom_panel: PanelContainer
var roster_panel: PanelContainer
var roster_table: RosterTable
var info_panel: PanelContainer
var info_label: Label
var select_texture: Texture2D
## pilot -> its toggle Button in the roster.
var roster_buttons := {}
var _scrubbing := false
var _press_pos := Vector2.INF


func _ready() -> void:
	sphere_mesh.radius = 1.0
	sphere_mesh.height = 2.0
	sizes = ShipSizes.new()
	add_child(sizes)
	assets = ShipAssets.new()
	add_child(assets)
	models_on = Settings.get_value("display/ship_models")
	smooth_on = Settings.get_value("display/smooth_motion")
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
	var d := MatchData.load_csv(path, sizes.radii(), _move_threshold_m())
	if d == null:
		file_label.text = "Failed to load %s" % path.get_file()
		return
	data = d
	data.smooth = smooth_on
	if path != match_path:
		team_overrides.clear()
	for pilot in team_overrides:
		if data.teams.has(pilot):
			data.teams[pilot] = team_overrides[pilot]
	match_path = path
	for c in ships_root.get_children():
		c.queue_free()
	ships.clear()
	for pilot in data.tracks:
		_add_ship(pilot)
	_fetch_models()
	timeline.max_value = data.duration
	_build_events()
	if not ships.has(tracked):
		tracked = ""
	if not ships.has(selected):
		selected = ""
	_update_file_label()
	_refresh_roster()
	_select(selected)
	print("Loaded %s: %d pilots, %.0f s" % [path, ships.size(), data.duration])
	for pilot in data.teams:
		print("  %s: %s" % [pilot, MatchData.Team.find_key(data.teams[pilot])])
	for pilot in data.deaths:
		print("  %s: out of bounds at %s" % [pilot, _fmt_time(data.deaths[pilot].t)])
	_seek(0.0)
	_set_playing(true)


func _update_file_label() -> void:
	var counts := {MatchData.Team.BLUE: 0, MatchData.Team.RED: 0, MatchData.Team.UNKNOWN: 0}
	for pilot in data.teams:
		counts[data.teams[pilot]] += 1
	file_label.text = "%s — %d pilots (blue %d / red %d / unknown %d), %d out of bounds" % [
		match_path.get_file(), ships.size(),
		counts[MatchData.Team.BLUE], counts[MatchData.Team.RED], counts[MatchData.Team.UNKNOWN],
		data.deaths.size(),
	]


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


func _set_smooth_on(on: bool) -> void:
	smooth_on = on
	Settings.set_value("display/smooth_motion", on)
	if data != null:
		data.smooth = on


## Movement needed to start the match (`MatchData.load_csv`): the jitter threshold when that
## setting is on, else any change of position.
static func _move_threshold_m() -> float:
	if not Settings.get_value("match/ignore_jitter"):
		return 0.0
	return Settings.get_value("match/jitter_threshold_m")


## Saves a match-start setting and reloads the open match, whose start (time 0) may move.
func _set_match_setting(key: String, value: Variant) -> void:
	Settings.set_value(key, value)
	if data != null:
		load_match(match_path)


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
	_update_mjd_trails()
	if tracked != "" and ships[tracked].node.visible:
		camera.set_target(ships[tracked].node.position)
	if not _scrubbing:
		timeline.set_value_no_signal(time)
	_update_info()
	_update_roster_cells()
	time_label.text = "%s / %s" % [_fmt_time(time), _fmt_time(data.duration)]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_on_left_click(event)
		return
	if not (event is InputEventKey and event.pressed):
		return
	if event.keycode == KEY_ESCAPE:
		_select("")
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
		KEY_BRACKETLEFT:
			_jump_event(-1)
		KEY_BRACKETRIGHT:
			_jump_event(1)


# --- ships -------------------------------------------------------------------

func _add_ship(pilot: String) -> void:
	var node := Node3D.new()
	node.name = pilot.validate_node_name()
	var color: Color = TEAM_COLORS[data.teams.get(pilot, MatchData.Team.UNKNOWN)]

	var visual := _sphere()
	node.add_child(visual)

	var icon := _icon()
	node.add_child(icon)

	var select_icon := _icon()
	node.add_child(select_icon)

	var label := _label(color)
	node.add_child(label)

	node.visible = false
	ships_root.add_child(node)
	ships[pilot] = {
		"node": node, "visual": visual, "model_id": 0, "icon": icon, "select_icon": select_icon, "label": label,
		"ship_type": "", "radius": 0.0, "dead": false, "color": color, "tint": color,
		"death_t": INF, "death_marker": null, "heading": Quaternion.IDENTITY, "heading_t": -INF,
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


# --- events ------------------------------------------------------------------

## Fills the timeline strip with the match's events and draws a line for each micro jump.
func _build_events() -> void:
	var marks := []
	for e in data.events:
		marks.append({"t": e.t, "color": EVENT_COLORS[e.kind], "text": _event_text(e)})
	event_strip.set_marks(marks, data.duration)
	mjd_trails.clear()
	for e in data.events:
		if e.kind == MatchData.Event.MJD:
			mjd_trails.append({"t": e.t, "node": _mjd_trail(e)})


## "03:42 Pilot — Podded (Venture)".
static func _event_text(e: Dictionary) -> String:
	var what: String = EVENT_NAMES[e.kind]
	if e.kind == MatchData.Event.MJD:
		what += " %.0f km" % (e.pos.distance_to(e.to_pos) * M_TO_UNITS)
	return "%s %s — %s (%s)" % [_fmt_time(e.t), e.pilot, what, e.ship_type]


## A line from where a micro jump took off to where it landed; hidden until shown by time.
func _mjd_trail(e: Dictionary) -> Node3D:
	var lines := ImmediateMesh.new()
	lines.surface_begin(Mesh.PRIMITIVE_LINES)
	lines.surface_add_vertex(e.pos * M_TO_UNITS)
	lines.surface_add_vertex(e.to_pos * M_TO_UNITS)
	lines.surface_end()
	var mesh := MeshInstance3D.new()
	mesh.mesh = lines
	mesh.material_override = _material(Color(MJD_COLOR, 0.8), false)
	mesh.visible = false
	ships_root.add_child(mesh)
	return mesh


func _update_mjd_trails() -> void:
	for trail in mjd_trails:
		trail.node.visible = time >= trail.t and time - trail.t <= MJD_TRAIL_S


## Seeks to the lead-up of the next (`dir` 1) or previous (-1) event from now.
func _jump_event(dir: int) -> void:
	var targets := data.events.map(func(e): return maxf(e.t - EVENT_LEAD_S, 0.0))
	if dir < 0:
		targets.reverse()
	for t in targets:
		if (t > time + 0.05) if dir > 0 else (t < time - 0.05):
			_seek(t)
			return


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
		_face_heading(ship, pilot)
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


## Turns model ships to face along their movement. Smooth motion averages the velocity over
## `HEADING_WINDOW_S` either side and eases the turn; otherwise half a second of track, snapped.
func _face_heading(ship: Dictionary, pilot: String) -> void:
	if ship.model_id == 0:
		return
	var window := HEADING_WINDOW_S if smooth_on else 0.5
	var prev := data.sample(pilot, time - window)
	var next := data.sample(pilot, time + window) if smooth_on else {}
	var now := data.sample(pilot, time)
	var a: Dictionary = prev if not prev.is_empty() else now
	var b: Dictionary = next if not next.is_empty() else now
	var target: Quaternion = ship.heading
	if b.t > a.t:
		var v: Vector3 = (b.pos - a.pos) / (b.t - a.t)
		if v.length() >= MIN_HEADING_SPEED:
			var up := Vector3.UP if absf(v.normalized().y) < 0.99 else Vector3.RIGHT
			target = (Basis.looking_at(v, up) * MODEL_FORWARD).get_rotation_quaternion()
	var dt: float = time - ship.heading_t
	ship.heading_t = time
	if smooth_on and dt > 0.0 and dt <= MAX_TURN_STEP_S:
		ship.heading = ship.heading.slerp(target, 1.0 - exp(-dt / TURN_TIME_S))
	elif smooth_on and dt == 0.0:
		pass  # Paused: hold the current turn.
	else:
		ship.heading = target
	ship.visual.basis = Basis(ship.heading)


## Scene units from the node's centre to just above an `ICON_PX` icon at the camera's distance.
func _icon_clearance(node: Node3D) -> float:
	return _units_per_px(camera.global_position.distance_to(node.global_position)) * ICON_PX * 0.75


# --- selection ---------------------------------------------------------------

## Left click selects the ship under the cursor (empty space clears it); a double click also
## follows it. A press that turns into a camera drag selects nothing.
func _on_left_click(event: InputEventMouseButton) -> void:
	if event.pressed:
		_press_pos = event.position
		if event.double_click:
			# The camera jumps to the ship, so the release would miss it: ignore that release.
			_press_pos = Vector2.INF
			var pilot := _pick_ship(event.position)
			if pilot != "":
				_select(pilot)
				_follow(pilot)
		return
	if event.position.distance_to(_press_pos) <= CLICK_SLOP_PX:
		_select(_pick_ship(event.position))
	_press_pos = Vector2.INF


## The visible ship drawn nearest `screen_pos` within `PICK_PX` (or its on-screen hull), or "".
func _pick_ship(screen_pos: Vector2) -> String:
	var best := ""
	var best_d := INF
	for pilot in ships:
		var node: Node3D = ships[pilot].node
		if not node.visible or camera.is_position_behind(node.global_position):
			continue
		var d := camera.unproject_position(node.global_position).distance_to(screen_pos)
		var dist := camera.global_position.distance_to(node.global_position)
		var hull_px: float = ships[pilot].visual.scale.x / _units_per_px(dist)
		if d <= maxf(PICK_PX, hull_px) and d < best_d:
			best = pilot
			best_d = d
	return best


## Selects `pilot` ("" clears): brackets it in space, highlights its roster row and fills the
## info panel.
func _select(pilot: String) -> void:
	selected = pilot
	for p in ships:
		var ship: Dictionary = ships[p]
		var on: bool = p == selected
		_set_icon(ship.select_icon, _select_texture() if on else null, SELECT_COLOR)
		if on:
			ship.select_icon.pixel_size *= SELECT_SCALE
		ship.label.font_size = 30 if on else 24
	for p in roster_buttons:
		_style_roster_button(p)
	if selected != "" and roster_buttons.has(selected):
		roster_table.scroll.ensure_control_visible(roster_buttons[selected])
	_update_info()


## White corner brackets drawn around the selected ship's icon.
func _select_texture() -> Texture2D:
	if select_texture:
		return select_texture
	const N := 64
	const ARM := 18
	const W := 4
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	for corner in [Vector2i(0, 0), Vector2i(N - ARM, 0), Vector2i(0, N - W), Vector2i(N - ARM, N - W)]:
		img.fill_rect(Rect2i(corner, Vector2i(ARM, W)), Color.WHITE)
	for corner in [Vector2i(0, 0), Vector2i(N - W, 0), Vector2i(0, N - ARM), Vector2i(N - W, N - ARM)]:
		img.fill_rect(Rect2i(corner, Vector2i(W, ARM)), Color.WHITE)
	select_texture = ImageTexture.create_from_image(img)
	return select_texture


## Gives the selected pilot's roster row a tinted background.
func _style_roster_button(pilot: String) -> void:
	var button: Button = roster_buttons[pilot]
	if pilot != selected:
		button.flat = true
		button.remove_theme_stylebox_override("normal")
		button.remove_theme_stylebox_override("hover")
		return
	var box := StyleBoxFlat.new()
	box.bg_color = Color(ships[pilot].color, 0.25)
	box.set_corner_radius_all(3)
	button.flat = false
	button.add_theme_stylebox_override("normal", box)
	button.add_theme_stylebox_override("hover", box)


## Shows the selected pilot's ship, team, speed and position in the info panel.
func _update_info() -> void:
	info_panel.visible = selected != "" and data != null
	if not info_panel.visible:
		return
	var team: int = data.teams.get(selected, MatchData.Team.UNKNOWN)
	var lines := PackedStringArray()
	lines.append("%s — %s" % [selected, TEAM_NAMES[team]])
	var now := data.sample(selected, time)
	if now.is_empty():
		lines.append("Not on grid")
	else:
		lines.append(now.ship_type)
		var motion := _motion(selected)
		if not is_nan(motion.speed):
			lines.append("Speed: %s" % _fmt_speed(motion.speed))
		var d: float = motion.dist_km
		lines.append("From centre: %.1f km (boundary %.1f km)" % [d, BOUNDARY_KM - d])
	var ship: Dictionary = ships[selected]
	for e in data.events:
		if e.pilot == selected and e.kind == MatchData.Event.DEATH and time >= e.t:
			lines.append("Podded at %s (lost %s)" % [_fmt_time(e.t), e.ship_type])
	if time >= ship.death_t:
		lines.append("DEAD (out of bounds at %s)" % _fmt_time(ship.death_t))
	lines.append("Following" if tracked == selected else "Double-click to follow")
	info_label.text = "\n".join(lines)
	info_label.modulate = TEAM_COLORS[team].lerp(Color.WHITE, 0.5)


## `pilot`'s ship type, speed (m/s from the CSV's latest sample; NAN if unknown) and distance
## from the centre (km) at the current time, or {} when it isn't on grid.
func _motion(pilot: String) -> Dictionary:
	var now := data.sample(pilot, time)
	if now.is_empty():
		return {}
	return {
		"ship_type": now.ship_type,
		"speed": now.speed,
		"dist_km": now.pos.distance_to(MatchData.CENTRE_M) * M_TO_UNITS,
	}


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


## Speed (m/s) for display: whole m/s below 1 km/s, else km/s to 1 decimal. Rounds first so
## 999.5 shows as 1.0 km/s, never 1000 m/s.
static func _fmt_speed(mps: float) -> String:
	if roundf(mps) >= 1000.0:
		return "%.1f km/s" % (mps / 1000.0)
	return "%.0f m/s" % mps


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
	camera.panned.connect(func(): _set_tracked(""))


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

	bottom_panel = PanelContainer.new()
	bottom_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(bottom_panel)

	var box := VBoxContainer.new()
	bottom_panel.add_child(box)

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

	for kind in EVENT_COLORS:
		var key := Label.new()
		key.text = "▮ %s" % EVENT_NAMES[kind]
		key.modulate = EVENT_COLORS[kind]
		key.tooltip_text = "Timeline marker colour ([ / ] jump between events)"
		key.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(key)

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

	event_strip = EventStrip.new()
	event_strip.mark_pressed.connect(func(i): _seek(event_strip.marks[i].t - EVENT_LEAD_S))
	box.add_child(event_strip)

	timeline = HSlider.new()
	timeline.step = 0.0
	timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	timeline.value_changed.connect(_seek)
	timeline.drag_started.connect(func(): _scrubbing = true)
	timeline.drag_ended.connect(func(_changed): _scrubbing = false)
	box.add_child(timeline)
	event_strip.slider = timeline

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

	info_panel = PanelContainer.new()
	info_panel.position = Vector2(12, 12)
	info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.visible = false
	layer.add_child(info_panel)
	info_label = Label.new()
	info_panel.add_child(info_label)

	_build_settings(layer)
	_build_roster(layer)


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

	var smooth_setting := CheckBox.new()
	smooth_setting.text = "Smooth ship movement between position samples (instead of straight lines)"
	smooth_setting.button_pressed = smooth_on
	smooth_setting.toggled.connect(_set_smooth_on)
	box.add_child(smooth_setting)

	var jitter := HBoxContainer.new()
	box.add_child(jitter)
	jitter_setting = CheckBox.new()
	jitter_setting.text = "Ignore position jitter when finding the match start: movement under"
	jitter_setting.button_pressed = Settings.get_value("match/ignore_jitter")
	jitter.add_child(jitter_setting)
	jitter_spin = SpinBox.new()
	jitter_spin.min_value = 0.0
	jitter_spin.max_value = 50000.0
	jitter_spin.step = 50.0
	jitter_spin.suffix = "m"
	jitter_spin.value = Settings.get_value("match/jitter_threshold_m")
	jitter_spin.editable = jitter_setting.button_pressed
	jitter.add_child(jitter_spin)
	jitter_setting.toggled.connect(func(on):
		jitter_spin.editable = on
		_set_match_setting("match/ignore_jitter", on))
	jitter_spin.value_changed.connect(func(v): _set_match_setting("match/jitter_threshold_m", v))

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


## Right-hand table of each team's pilots (ship, pilot, speed, distance from centre): click one to
## follow it, ⇄ to change its team.
func _build_roster(layer: CanvasLayer) -> void:
	roster_panel = PanelContainer.new()
	roster_panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	roster_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	roster_panel.visible = false
	layer.add_child(roster_panel)
	var keep_above_bar := func(): roster_panel.offset_bottom = -bottom_panel.size.y
	bottom_panel.resized.connect(keep_above_bar)
	keep_above_bar.call()

	roster_table = RosterTable.new()
	roster_table.row_pressed.connect(_set_tracked)
	roster_table.swap_pressed.connect(_swap_team)
	roster_table.layout_changed.connect(_fit_roster)
	roster_panel.add_child(roster_table)
	_fit_roster()


## Sizes the roster panel to its columns, plus room for the scroll bar.
func _fit_roster() -> void:
	var bar := roster_table.scroll.get_v_scroll_bar().get_combined_minimum_size().x
	var panel := roster_panel.get_theme_stylebox("panel")
	var width := roster_table.header.get_combined_minimum_size().x + bar + panel.get_minimum_size().x
	roster_panel.offset_left = -width
	roster_panel.offset_right = 0.0


## Rebuilds the roster from the loaded match's teams.
func _refresh_roster() -> void:
	roster_table.clear()
	roster_buttons.clear()
	roster_panel.visible = data != null
	if data == null:
		return
	var pilots := ships.keys()
	# By ship type, then pilot.
	var key := func(p: String) -> String: return "%s\n%s" % [data.tracks[p][0].ship_type, p]
	pilots.sort_custom(func(a, b): return key.call(a).naturalnocasecmp_to(key.call(b)) < 0)
	for team in [MatchData.Team.BLUE, MatchData.Team.RED, MatchData.Team.UNKNOWN]:
		var members := pilots.filter(func(p): return data.teams.get(p, MatchData.Team.UNKNOWN) == team)
		if team == MatchData.Team.UNKNOWN and members.is_empty():
			continue
		var color: Color = TEAM_COLORS[team]
		roster_table.add_group("%s (%d)" % [TEAM_NAMES[team], members.size()], color)
		var other: int = MatchData.Team.BLUE if team != MatchData.Team.BLUE else MatchData.Team.RED
		for pilot in members:
			var button := roster_table.add_row(pilot, color, "Move to %s" % TEAM_NAMES[other])
			button.tooltip_text = "Centre the camera on %s" % pilot
			button.set_pressed_no_signal(pilot == tracked)
			roster_buttons[pilot] = button
			_style_roster_button(pilot)
			roster_table.set_cell(pilot, "ship", data.tracks[pilot][0].ship_type)
			roster_table.set_cell(pilot, "pilot", _short_name(pilot))
	_update_roster_cells()


## Refreshes each roster row's live columns: current hull, speed and distance from centre.
## Pilots off grid show dashes; dead ones are dimmed.
func _update_roster_cells() -> void:
	if data == null:
		return
	for pilot in roster_buttons:
		var motion := _motion(pilot)
		if motion.is_empty():
			roster_table.set_cell(pilot, "speed", "—")
			roster_table.set_cell(pilot, "distance", "—")
		else:
			roster_table.set_cell(pilot, "ship", motion.ship_type)
			roster_table.set_cell(pilot, "speed", "—" if is_nan(motion.speed) else _fmt_speed(motion.speed))
			roster_table.set_cell(pilot, "distance", "%.1f km" % motion.dist_km)
		roster_buttons[pilot].modulate.a = 0.5 if time >= ships[pilot].death_t else 1.0


## Roster abbreviation of a pilot name: the first word, then initials ("Ackbad Some Name" ->
## "Ackbad S. N.").
static func _short_name(pilot: String) -> String:
	var words := pilot.split(" ", false)
	if words.is_empty():
		return pilot
	var out := words[0]
	for i in range(1, words.size()):
		out += " %s." % words[i].left(1)
	return out


## Follows `pilot` with the camera; picking the followed pilot again (or "") frees it.
func _set_tracked(pilot: String) -> void:
	_follow("" if pilot == tracked else pilot)


## Follows `pilot` with the camera ("" frees it).
func _follow(pilot: String) -> void:
	tracked = pilot
	for p in roster_buttons:
		roster_buttons[p].set_pressed_no_signal(p == tracked)
	if tracked != "" and ships[tracked].node.visible:
		camera.set_target(ships[tracked].node.position)


## Moves `pilot` to the other team (unknown pilots go to blue) and recolours it.
func _swap_team(pilot: String) -> void:
	var team: int = MatchData.Team.RED if data.teams.get(pilot) == MatchData.Team.BLUE else MatchData.Team.BLUE
	data.teams[pilot] = team
	team_overrides[pilot] = team
	var ship: Dictionary = ships[pilot]
	ship.color = TEAM_COLORS[team]
	ship.ship_type = ""  # Forces `_update_ships` to re-tint the visual, icon and label.
	if ship.death_marker:
		var was_visible: bool = ship.death_marker.visible
		ship.death_marker.queue_free()
		ship.death_marker = _death_marker(pilot, data.deaths[pilot], ship.color)
		ship.death_marker.visible = was_visible
	_update_file_label()
	_refresh_roster()


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		if f.get_extension().to_lower() == "csv":
			load_match(f)
			return
