extends "res://tests/test_case.gd"
## Orbit camera: placement, zoom limits and drag-to-rotate.

const OrbitCamera := preload("res://scripts/orbit_camera.gd")


func _camera() -> OrbitCamera:
	var cam: OrbitCamera = OrbitCamera.new()
	add_node(cam)
	return cam


func _wheel(cam: OrbitCamera, button: MouseButton) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	cam._unhandled_input(ev)


func _drag(cam: OrbitCamera, relative: Vector2, mask: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.relative = relative
	ev.button_mask = mask
	cam._unhandled_input(ev)


func _assert_orbiting(cam: OrbitCamera) -> void:
	assert_almost(cam.global_position.distance_to(cam.target), cam.distance, 1e-2, "distance")
	var to_target: Vector3 = (cam.target - cam.global_position).normalized()
	assert_almost(-cam.global_basis.z, to_target, 1e-4, "looks at target")


func test_starts_orbiting_target() -> void:
	var cam := _camera()
	_assert_orbiting(cam)


func test_wheel_zooms_within_limits() -> void:
	var cam := _camera()
	var d: float = cam.distance
	_wheel(cam, MOUSE_BUTTON_WHEEL_UP)
	assert_almost(cam.distance, d / OrbitCamera.ZOOM_STEP)
	_wheel(cam, MOUSE_BUTTON_WHEEL_DOWN)
	assert_almost(cam.distance, d)
	_assert_orbiting(cam)

	cam.distance = OrbitCamera.MIN_DISTANCE * 1.01
	_wheel(cam, MOUSE_BUTTON_WHEEL_UP)
	assert_eq(cam.distance, OrbitCamera.MIN_DISTANCE)
	cam.distance = OrbitCamera.MAX_DISTANCE * 0.99
	_wheel(cam, MOUSE_BUTTON_WHEEL_DOWN)
	assert_eq(cam.distance, OrbitCamera.MAX_DISTANCE)


func test_drag_rotates_and_clamps_pitch() -> void:
	var cam := _camera()
	var yaw: float = cam.yaw
	_drag(cam, Vector2(100, 0), MOUSE_BUTTON_MASK_LEFT)
	assert_almost(cam.yaw, yaw - 100 * OrbitCamera.ROTATE_SPEED)
	_drag(cam, Vector2(0, 10000), MOUSE_BUTTON_MASK_RIGHT)
	assert_eq(cam.pitch, 1.55)
	_drag(cam, Vector2(0, -20000), MOUSE_BUTTON_MASK_LEFT)
	assert_eq(cam.pitch, -1.55)
	_assert_orbiting(cam)


func test_middle_drag_pans_target() -> void:
	var cam := _camera()
	var target: Vector3 = cam.target
	_drag(cam, Vector2(50, 0), MOUSE_BUTTON_MASK_MIDDLE)
	assert_ne(cam.target, target)
	_assert_orbiting(cam)


func test_middle_drag_emits_panned() -> void:
	var cam := _camera()
	var panned := [false]
	cam.panned.connect(func(): panned[0] = true)
	_drag(cam, Vector2(50, 0), MOUSE_BUTTON_MASK_LEFT)
	assert_false(panned[0], "rotate is not a pan")
	_drag(cam, Vector2(50, 0), MOUSE_BUTTON_MASK_MIDDLE)
	assert_true(panned[0])


func test_set_target_recentres() -> void:
	var cam := _camera()
	var d: float = cam.distance
	cam.set_target(Vector3(10, 20, 30))
	assert_eq(cam.target, Vector3(10, 20, 30))
	assert_eq(cam.distance, d)
	_assert_orbiting(cam)
