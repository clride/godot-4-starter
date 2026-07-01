class_name CameraController
extends Node3D
## CameraController
## ------------------
## A first/third-person camera rig that follows a target and orbits via
## mouse look (and optional controller stick look). Built on SpringArm3D
## for automatic wall/obstacle avoidance in third person. Scrolling the
## camera distance all the way down to `first_person_threshold` switches
## into first person automatically.
##
## This node IS the yaw pivot: its own Y rotation tracks horizontal look,
## while a child node handles pitch. That makes this node itself a clean
## `rotation_reference` / `movement_basis_node` target for a
## CharacterController3D, since its global basis represents look direction
## with pitch excluded.
##
## Builds its own rig (pitch pivot, SpringArm3D, Camera3D) as children at
## runtime. Just add this node to the scene and assign `target`.


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

enum CameraMode {
	THIRD_PERSON,
	FIRST_PERSON,
}


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal mode_changed(new_mode: CameraMode)
signal distance_changed(distance: float)


# ---------------------------------------------------------------------------
# Exported configuration
# ---------------------------------------------------------------------------

@export_group("Target")
## The node this rig follows (typically a CharacterController3D).
@export var target: Node3D
## Pivot position offset from target.global_position while in third person.
@export var third_person_pivot_offset: Vector3 = Vector3(0.0, 1.6, 0.0)
## Eye position offset from target.global_position while in first person.
## Defaults to the same height as third_person_pivot_offset (actual head
## height) rather than sitting above it. Adjust independently as needed.
@export var first_person_eye_offset: Vector3 = Vector3(0.0, 1.6, 0.0)
## When true, third_person_pivot_offset rotates with the camera's yaw so
## the offset stays relative to the camera's facing direction (useful for
## over-the-shoulder cameras that orbit the target).
@export var shoulder_offset_rotates_with_yaw: bool = false
## How fast the rig's position eases between the third-person and
## first-person offsets when switching modes (higher = snappier, avoids
## an instant camera pop on the switch).
@export var offset_smoothing: float = 10.0

@export_group("Look")
@export var mouse_sensitivity: float = 0.0035
@export var controller_sensitivity: float = 2.5 # radians/sec at full stick deflection
@export var invert_y: bool = false
@export var pitch_min_deg: float = -80.0
@export var pitch_max_deg: float = 80.0
@export var capture_mouse_on_ready: bool = true

@export_group("Controller Look Actions")
@export var look_left_action: String = "look_left"
@export var look_right_action: String = "look_right"
@export var look_up_action: String = "look_up"
@export var look_down_action: String = "look_down"

@export_group("Zoom / Distance")
@export var min_distance: float = 0.0
@export var max_distance: float = 8.0
@export var default_distance: float = 4.0
@export var zoom_step: float = 0.5
## How fast current_distance eases toward the target distance (higher = snappier).
@export var zoom_smoothing: float = 10.0
## Distance at/below which the rig switches into first person automatically.
@export var first_person_threshold: float = 1.0

@export_group("Collision")
@export var collision_mask: int = 1
@export var collision_margin: float = 0.2
@export var collision_shape_radius: float = 0.3

@export_group("Camera")
@export var fov: float = 75.0
@export var make_current_on_ready: bool = true


# ---------------------------------------------------------------------------
# Rig nodes (built at runtime)
# ---------------------------------------------------------------------------

var pitch_pivot: Node3D
var spring_arm: SpringArm3D
var camera: Camera3D


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _yaw: float = 0.0
var _pitch: float = 0.0
var _target_distance: float = 0.0
var _current_distance: float = 0.0
var _mode: CameraMode = CameraMode.THIRD_PERSON
var _controller_look_available: bool = false


func _ready() -> void:
	_build_rig()

	_target_distance = default_distance
	_current_distance = default_distance
	_mode = CameraMode.FIRST_PERSON if default_distance <= first_person_threshold else CameraMode.THIRD_PERSON

	if capture_mouse_on_ready:
		set_mouse_captured(true)

	set_process_unhandled_input(true)

	_controller_look_available = (
		InputMap.has_action(look_left_action)
		and InputMap.has_action(look_right_action)
		and InputMap.has_action(look_up_action)
		and InputMap.has_action(look_down_action)
	)
	if not _controller_look_available:
		push_warning("CameraController: one or more look_* actions are missing from the Input Map; controller look is disabled. Mouse look still works.")


func _build_rig() -> void:
	pitch_pivot = Node3D.new()
	pitch_pivot.name = "PitchPivot"
	add_child(pitch_pivot)

	spring_arm = SpringArm3D.new()
	spring_arm.name = "SpringArm3D"
	spring_arm.collision_mask = collision_mask
	spring_arm.margin = collision_margin
	var shape := SphereShape3D.new()
	shape.radius = collision_shape_radius
	spring_arm.shape = shape
	pitch_pivot.add_child(spring_arm)

	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = fov
	spring_arm.add_child(camera)

	if make_current_on_ready:
		camera.current = true


func _process(delta: float) -> void:
	if target == null:
		return

	_apply_controller_look(delta)
	_update_distance(delta)
	_update_mode()
	_apply_transform()


# ---------------------------------------------------------------------------
# Look input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_add_look_delta(event.relative.x * mouse_sensitivity, event.relative.y * mouse_sensitivity)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom(-zoom_step)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom(zoom_step)

func _apply_controller_look(delta: float) -> void:
	if not _controller_look_available:
		return
	var look_vec := Input.get_vector(look_left_action, look_right_action, look_up_action, look_down_action)
	if look_vec == Vector2.ZERO:
		return
	_add_look_delta(look_vec.x * controller_sensitivity * delta, look_vec.y * controller_sensitivity * delta)

func _add_look_delta(yaw_delta: float, pitch_delta: float) -> void:
	_yaw -= yaw_delta
	var pitch_dir := -1.0 if invert_y else 1.0
	_pitch = clamp(_pitch - pitch_delta * pitch_dir, deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg))


# ---------------------------------------------------------------------------
# Zoom / distance / mode
# ---------------------------------------------------------------------------

## Adds `amount` to the target distance (positive = zoom out, negative = zoom in).
func zoom(amount: float) -> void:
	_target_distance = clamp(_target_distance + amount, min_distance, max_distance)

func set_distance(value: float) -> void:
	_target_distance = clamp(value, min_distance, max_distance)

func get_distance() -> float:
	return _current_distance

func get_mode() -> CameraMode:
	return _mode

func _update_distance(delta: float) -> void:
	if is_equal_approx(_current_distance, _target_distance):
		return
	var t: float = 1.0 - exp(-zoom_smoothing * delta)
	var new_distance: float = lerp(_current_distance, _target_distance, t)
	if not is_equal_approx(new_distance, _current_distance):
		_current_distance = new_distance
		distance_changed.emit(_current_distance)

func _update_mode() -> void:
	var new_mode: CameraMode = CameraMode.FIRST_PERSON if _current_distance <= first_person_threshold else CameraMode.THIRD_PERSON
	if new_mode != _mode:
		_mode = new_mode
		mode_changed.emit(_mode)


# ---------------------------------------------------------------------------
# Transform application
# ---------------------------------------------------------------------------

func _apply_transform() -> void:
	var offset := first_person_eye_offset if _mode == CameraMode.FIRST_PERSON else third_person_pivot_offset
	if _mode == CameraMode.THIRD_PERSON and shoulder_offset_rotates_with_yaw:
		offset = offset.rotated(Vector3.UP, _yaw)
	global_position = target.global_position + offset

	rotation.y = _yaw
	pitch_pivot.rotation.x = _pitch

	spring_arm.spring_length = _current_distance


# ---------------------------------------------------------------------------
# Mouse capture
# ---------------------------------------------------------------------------

func set_mouse_captured(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

func is_mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
