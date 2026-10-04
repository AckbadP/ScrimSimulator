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


func _ready() -> void:
	far = 5000.0
	_update_transform()


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
