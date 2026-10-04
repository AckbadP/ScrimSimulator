extends SceneTree
## Scripted scenes for the README GIFs, rendered with Godot's Movie Maker by
## `scripts/readme_gifs.sh`:
##
##   godot --path simulator --write-movie out/f.png --fixed-fps 30 -s tools/readme_gif.gd \
##       -- --csv <match.positions.csv> --scene playback|measure|orbit
##
## Runs the real `main.tscn` and drives it per frame: playback state and camera directly, the
## measuring tool through synthetic mouse events so it goes through `main.gd`'s input handling.

const FPS := 30

var main: Node
var scene := ""
var frame := 0
## Measure scene: the pilot the drag starts on, the one it ends on, and the last cursor position.
var _from := ""
var _to := ""
var _last := Vector2.ZERO
## Orbit scene: the point the camera circles.
var _orbit_centre := Vector3.ZERO


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--scene")
	scene = args[i + 1] if i >= 0 and i + 1 < args.size() else "playback"
	main = load("res://main.tscn").instantiate()
	root.add_child(main)


func _process(_delta: float) -> bool:
	frame += 1
	if frame == 1:
		if main.data == null:
			push_error("readme_gif: no match loaded (pass --csv)")
			return true
		return false
	match scene:
		"playback":
			return _playback()
		"orbit":
			return _orbit()
		"measure":
			return _measure()
	push_error("readme_gif: unknown scene %s" % scene)
	return true


## A few seconds of the fight around the first podding.
func _playback() -> bool:
	if frame == 2:
		main._seek(300.0)
		_set_speed(5.0)
		main._set_playing(true)
		main.camera.target = _centroid()
		main.camera.distance = 30.0
		_centre_on_view()
	return frame >= 2 + 7 * FPS


## The camera circles the fight while the match plays.
func _orbit() -> bool:
	var cam: Camera3D = main.camera
	if frame == 2:
		main._seek(180.0)
		_set_speed(5.0)
		main._set_playing(true)
		_orbit_centre = _centroid()
		cam.distance = 40.0
		cam.pitch = deg_to_rad(20.0)
	# Re-centred every frame so the fight stays at the view centre, clear of the roster.
	cam.yaw += TAU / (10.0 * FPS)
	cam.target = _orbit_centre
	_centre_on_view()
	return frame >= 2 + 6 * FPS


## Paused; a left drag from one ship grows the measuring sphere, then snaps onto another.
func _measure() -> bool:
	var cam: Camera3D = main.camera
	if frame == 2:
		main._seek(300.0)
		main._set_playing(true)
		main._set_playing(false)
		cam.target = _centroid()
		cam.distance = 30.0
		_centre_on_view()
		return false
	if frame < 4:
		return false
	if frame == 4:
		_pick_pair()
		if _to == "":
			push_error("readme_gif: no pair of ships to measure between")
			return true
		print("measure: %s -> %s" % [_from, _to])
	var a := _screen(_from)
	var b := _screen(_to)
	# Past the target first, so the sphere visibly brackets ships on the way, then back onto it.
	var over := a + (b - a) * 1.4
	const PRESS := 15
	const OUT := 60
	const BACK := 25
	const HOLD := 60
	var f := frame - PRESS
	if frame == PRESS:
		_button(a, true)
	elif f > 0 and f <= OUT:
		_move(a.lerp(over, _ease(float(f) / OUT)))
	elif f > OUT and f <= OUT + BACK:
		_move(over.lerp(b, _ease(float(f - OUT) / BACK)))
	elif f == OUT + BACK + HOLD:
		_button(b, false)
	return f >= OUT + BACK + HOLD + 20


## Sets the playback speed through the speed dropdown, so it shows the new value.
func _set_speed(s: float) -> void:
	for option: OptionButton in main.find_children("*", "OptionButton", true, false):
		if option.item_count == main.SPEEDS.size() and option.get_item_text(0) == "0.5x":
			option.select(main.SPEEDS.find(s))
	main._set_speed(s)


## Per-axis median of the ships on grid (stragglers don't pull it off the fight).
func _centroid() -> Vector3:
	main._update_ships()
	var axes := [[], [], []]
	for p in main.ships:
		if main.ships[p].node.visible:
			for k in 3:
				axes[k].append(main.ships[p].node.position[k])
	var c := Vector3.ZERO
	for k in 3:
		axes[k].sort()
		c[k] = axes[k][axes[k].size() / 2] if axes[k].size() > 0 else 0.0
	return c


## Middle of the 3D view left of the roster.
func _view_centre() -> Vector2:
	var size: Vector2 = root.get_visible_rect().size
	return Vector2(main.roster_panel.get_global_rect().position.x / 2.0, size.y / 2.0)


## Pans the camera so `cam.target` is drawn at `_view_centre()` rather than behind the roster.
func _centre_on_view() -> void:
	var cam: Camera3D = main.camera
	cam._update_transform()
	var dx: float = cam.unproject_position(cam.target).x - _view_centre().x
	cam.target += cam.global_basis.x * dx * main._units_per_px(cam.distance)
	cam._update_transform()


## The visible ship nearest the view centre to drag from, and one about 250 px from it, with no
## other ship drawn close by (so its distance label reads clearly), to drop on.
func _pick_pair() -> void:
	var centre := _view_centre()
	var shown: Array = main.ships.keys().filter(func(p): return main.ships[p].node.visible)
	var best := INF
	for p in shown:
		var d := _screen(p).distance_to(centre)
		if d < best:
			best = d
			_from = p
	best = INF
	for p in shown:
		var s := _screen(p)
		if p == _from or absf(s.x - centre.x) > centre.x * 0.7 or absf(s.y - centre.y) > centre.y * 0.7:
			continue
		var crowd := INF
		for q in shown:
			if q != p:
				crowd = minf(crowd, _screen(q).distance_to(s))
		if crowd < 80.0:
			continue
		var d := absf(s.distance_to(_screen(_from)) - 250.0)
		if d < best:
			best = d
			_to = p


func _screen(pilot: String) -> Vector2:
	return main.camera.unproject_position(main.ships[pilot].node.global_position)


static func _ease(x: float) -> float:
	return x * x * (3.0 - 2.0 * x)


func _button(pos: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(e)
	_last = pos


func _move(pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.global_position = pos
	e.relative = pos - _last
	e.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(e)
	_last = pos
