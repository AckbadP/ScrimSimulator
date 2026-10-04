extends Camera3D
## Orbit camera: left drag rotates, wheel zooms, right drag pans. (Left clicks that
## don't drag select ships; `main.gd` handles those.)

## Right-drag pan: the user moved the target by hand.
signal panned

@export var target := Vector3(50, 50, 50)
@export var distance := 320.0
@export var yaw := deg_to_rad(35.0)
@export var pitch := deg_to_rad(25.0)

const ROTATE_SPEED := 0.006
const ZOOM_STEP := 1.12
const MIN_DISTANCE := 2.0
const MAX_DISTANCE := 2000.0
## Vertical FOV at `REF_HEIGHT` (Godot's default window height). Taller viewports widen the FOV so
## the scene keeps its on-screen scale and more of it is visible, up to `MAX_FOV`.
const BASE_FOV := 75.0
const REF_HEIGHT := 648.0
const MAX_FOV := 100.0


func _ready() -> void:
	far = 5000.0
	fit_viewport()
	get_viewport().size_changed.connect(fit_viewport)
	_update_transform()


## Vertical FOV (degrees) for a viewport `h` UI pixels tall.
static func fov_for_height(h: float) -> float:
	var half := atan(tan(deg_to_rad(BASE_FOV) / 2.0) * h / REF_HEIGHT)
	return minf(MAX_FOV, rad_to_deg(2.0 * half))


## Matches the FOV to the viewport's height in UI pixels (window pixels / UI scale).
func fit_viewport() -> void:
	fov = fov_for_height(get_viewport().get_visible_rect().size.y)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				distance = maxf(MIN_DISTANCE, distance / ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				distance = minf(MAX_DISTANCE, distance * ZOOM_STEP)
		_update_transform()
	elif event is InputEventMouseMotion:
		var m: int = event.button_mask
		if m & MOUSE_BUTTON_MASK_LEFT:
			yaw -= event.relative.x * ROTATE_SPEED
			pitch = clampf(pitch + event.relative.y * ROTATE_SPEED, -1.55, 1.55)
			_update_transform()
		elif m & MOUSE_BUTTON_MASK_RIGHT:
			var pan := distance * 0.0015
			target += (-global_basis.x * event.relative.x + global_basis.y * event.relative.y) * pan
			_update_transform()
			panned.emit()


## Re-centres the orbit on `p`, keeping distance and angles.
func set_target(p: Vector3) -> void:
	target = p
	_update_transform()


func _update_transform() -> void:
	var offset := Vector3(
		cos(pitch) * sin(yaw),
		sin(pitch),
		cos(pitch) * cos(yaw),
	) * distance
	look_at_from_position(target + offset, target, Vector3.UP)
