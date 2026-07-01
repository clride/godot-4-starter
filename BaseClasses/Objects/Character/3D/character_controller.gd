class_name CharacterController3D
extends CharacterBody3D
## CharacterController3D
## ----------------------
## A 3D character controller: single walk_speed,
## simple jump, smooth acceleration/deceleration, and configurable facing
## behavior. Owns the physics loop (calls move_and_slide itself) and applies
## gravity inline rather than depending on GravityComponent. move_and_slide()
## resolves the whole velocity vector in one pass, so anything contributing
## to velocity needs to live in the same _physics_process/move_and_slide
## call, not a separately-ticking component. GravityComponent is still
## useful on its own for non-controller bodies (props, ragdolls, etc).
##
## Input is read directly from Godot's Input singleton using configurable
## action names. Make sure matching actions exist in Project > Input Map
## (defaults below assume "move_left"/"move_right"/"move_forward"/
## "move_back"/"jump").


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

enum RotationMode {
	NONE,                 ## Character never rotates on its own.
	FACE_MOVE_DIRECTION,  ## Rotates to face the direction it's currently moving.
	FACE_REFERENCE,       ## Rotates to match the yaw of `rotation_reference` (e.g. a camera rig).
}

enum AirControlMode {
	FULL,     ## Full directional control while airborne, same as being grounded.
	PARTIAL,  ## Reduced control while airborne, scaled by separate acceleration/deceleration control amounts.
}

enum CharacterState {
	IDLE,
	WALKING,
	JUMPING,
	FALLING,
}


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal jumped()
signal landed(impact_velocity: float)
signal left_ground()
signal state_changed(old_state: CharacterState, new_state: CharacterState)
signal moved(direction: Vector3, speed: float)


# ---------------------------------------------------------------------------
# Exported configuration
# ---------------------------------------------------------------------------

@export_group("Speed")
## Global multiplier applied to walk_speed, acceleration, deceleration, and
## the partial air control rates. 1.0 = no change, 2.0 = double speed.
@export var speed_multiplier: float = 1.0

@export_group("Movement")
@export var walk_speed: float = 5.0
@export var acceleration: float = 10.0
@export var deceleration: float = 10.0
## If true, horizontal velocity snaps directly to the target speed each
## frame instead of easing via acceleration/deceleration. Applies to
## grounded movement and both air control modes.
@export var instant_movement: bool = false

@export_group("Air Control")
@export var air_control_mode: AirControlMode = AirControlMode.FULL
## Acceleration rate used while airborne under AirControlMode.PARTIAL,
## in the same units as the grounded acceleration value.
@export var partial_air_acceleration: float = 10.0
## Deceleration rate used while airborne under AirControlMode.PARTIAL,
## in the same units as the grounded deceleration value.
@export var partial_air_deceleration: float = 10.0

@export_group("Gravity")
## If true, gravity_value is ignored and ProjectSettings'
## physics/3d/default_gravity is used instead (re-read every frame, so
## changing it at runtime is picked up automatically).
@export var use_project_gravity: bool = true
## Custom gravity magnitude (units/sec^2), used when use_project_gravity is false.
@export var gravity_value: float = 9.8
## Multiplier applied on top of whichever gravity source is active.
@export var gravity_scale: float = 1.0
## Max downward fall speed. 0 (or negative) = uncapped.
@export var terminal_velocity: float = 0.0

@export_group("Jump")
@export var can_jump: bool = true
@export var jump_velocity: float = 4.5
## Optional grace period (seconds) after leaving a ledge where jump still works.
@export var coyote_time: float = 0.0

@export_group("Slope")
## Steepest slope, in degrees, the character can walk up. Drives
## CharacterBody3D's built-in floor_max_angle; anything steeper is treated
## as a wall instead of floor.
@export var max_slope_angle: float = 45.0:
	set(value):
		max_slope_angle = value
		floor_max_angle = deg_to_rad(value)

@export_group("Rotation")
@export var rotation_mode: RotationMode = RotationMode.FACE_MOVE_DIRECTION
## Used when rotation_mode == FACE_REFERENCE; the character matches this
## node's horizontal (yaw) facing, typically a camera rig.
@export var rotation_reference: Node3D
## Degrees/sec for smooth turning. 0 = snap instantly.
@export var rotation_speed: float = 720.0
## Optional. When assigned and this camera is in first-person mode, the
## character always faces the camera's yaw, overriding rotation_mode.
@export var camera_controller: CameraController

@export_group("Movement Basis")
## Optional node whose horizontal orientation input directions are relative
## to (e.g. a camera rig, for camera-relative movement). Leave unset to
## move relative to this character's own/world axes.
@export var movement_basis_node: Node3D

@export_group("Input Actions")
@export var input_left_action: String = "move_left"
@export var input_right_action: String = "move_right"
@export var input_forward_action: String = "move_forward"
@export var input_back_action: String = "move_back"
@export var jump_action: String = "jump"


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _state: CharacterState = CharacterState.IDLE
var _coyote_timer: float = 0.0
var _last_move_direction: Vector3 = Vector3.ZERO
var _was_on_floor: bool = true
var _has_emitted_terminal: bool = false
var _jumped_this_frame: bool = false


func _physics_process(delta: float) -> void:
	_jumped_this_frame = false

	var input_dir := _get_input_direction()
	var world_move_dir := _input_to_world_direction(input_dir)

	_apply_gravity(delta)
	_handle_jump(delta)
	_handle_horizontal_movement(world_move_dir, delta)
	_handle_rotation(world_move_dir, delta)

	move_and_slide()
	_check_floor_transition()
	_update_state(world_move_dir)

	if world_move_dir != Vector3.ZERO:
		_last_move_direction = world_move_dir
		moved.emit(world_move_dir, Vector2(velocity.x, velocity.z).length())


# ---------------------------------------------------------------------------
# Gravity
# ---------------------------------------------------------------------------

func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		# Keep a small downward velocity so is_on_floor() stays true on
		# slopes/stairs instead of flickering, without accumulating fall speed.
		if velocity.y < 0.0:
			velocity.y = -0.1
		_has_emitted_terminal = false
		return

	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) if use_project_gravity else gravity_value
	velocity.y -= g * gravity_scale * delta

	if terminal_velocity > 0.0 and velocity.y < -terminal_velocity:
		velocity.y = -terminal_velocity
		_has_emitted_terminal = true

func _check_floor_transition() -> void:
	var on_floor := is_on_floor()
	if on_floor and not _was_on_floor:
		landed.emit(abs(velocity.y))
	elif not on_floor and _was_on_floor:
		left_ground.emit()
	_was_on_floor = on_floor


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _get_input_direction() -> Vector2:
	var x := Input.get_action_strength(input_right_action) - Input.get_action_strength(input_left_action)
	var y := Input.get_action_strength(input_back_action) - Input.get_action_strength(input_forward_action)
	var dir := Vector2(x, y)
	if dir.length() > 1.0:
		dir = dir.normalized()
	return dir

## Converts 2D input (x = strafe, y = forward/back) into a world-space,
## horizontal-only direction vector, relative to movement_basis_node if set.
func _input_to_world_direction(input_dir: Vector2) -> Vector3:
	if input_dir == Vector2.ZERO:
		return Vector3.ZERO

	var basis: Basis = movement_basis_node.global_transform.basis if movement_basis_node != null else global_transform.basis
	var forward := -basis.z
	var right := basis.x
	forward.y = 0.0
	right.y = 0.0
	forward = forward.normalized() if forward.length() > 0.0001 else Vector3.FORWARD
	right = right.normalized() if right.length() > 0.0001 else Vector3.RIGHT

	var dir := (right * input_dir.x) + (forward * -input_dir.y)
	if dir.length() > 1.0:
		dir = dir.normalized()
	return dir


# ---------------------------------------------------------------------------
# Speed
# ---------------------------------------------------------------------------

func get_effective_walk_speed() -> float:
	return walk_speed * speed_multiplier

func get_effective_acceleration() -> float:
	return acceleration * speed_multiplier

func get_effective_deceleration() -> float:
	return deceleration * speed_multiplier

func get_effective_partial_air_acceleration() -> float:
	return partial_air_acceleration * speed_multiplier

func get_effective_partial_air_deceleration() -> float:
	return partial_air_deceleration * speed_multiplier


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

func _handle_horizontal_movement(world_move_dir: Vector3, delta: float) -> void:
	var grounded := is_on_floor() and not _jumped_this_frame
	if grounded or air_control_mode == AirControlMode.FULL:
		_handle_grounded_movement(world_move_dir, delta)
	else:
		_handle_partial_air_movement(world_move_dir, delta)

func _handle_grounded_movement(world_move_dir: Vector3, delta: float) -> void:
	var target_velocity := world_move_dir * get_effective_walk_speed()
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)

	if instant_movement:
		horizontal = target_velocity
	else:
		var rate: float = get_effective_acceleration() if world_move_dir != Vector3.ZERO else get_effective_deceleration()
		horizontal = horizontal.move_toward(target_velocity, rate * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z

func _handle_partial_air_movement(world_move_dir: Vector3, delta: float) -> void:
	var target_velocity := world_move_dir * get_effective_walk_speed()
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)

	if instant_movement:
		horizontal = target_velocity
	else:
		var rate: float = get_effective_partial_air_acceleration() if world_move_dir != Vector3.ZERO else get_effective_partial_air_deceleration()
		horizontal = horizontal.move_toward(target_velocity, rate * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z


func _handle_rotation(world_move_dir: Vector3, delta: float) -> void:
	var target_dir := Vector3.ZERO

	if camera_controller != null and camera_controller.get_mode() == CameraController.CameraMode.FIRST_PERSON:
		var cam_forward := -camera_controller.global_transform.basis.z
		cam_forward.y = 0.0
		target_dir = cam_forward
	else:
		match rotation_mode:
			RotationMode.NONE:
				return
			RotationMode.FACE_MOVE_DIRECTION:
				target_dir = world_move_dir if world_move_dir != Vector3.ZERO else Vector3.ZERO
			RotationMode.FACE_REFERENCE:
				if rotation_reference != null:
					var ref_forward := -rotation_reference.global_transform.basis.z
					ref_forward.y = 0.0
					target_dir = ref_forward

	if target_dir == Vector3.ZERO or target_dir.length() < 0.0001:
		return

	var target_yaw := atan2(target_dir.x, target_dir.z)
	if rotation_speed <= 0.0:
		rotation.y = target_yaw
		return

	rotation.y = lerp_angle(rotation.y, target_yaw, 1.0 - exp(-deg_to_rad(rotation_speed) * delta))


# ---------------------------------------------------------------------------
# Jump
# ---------------------------------------------------------------------------

func _handle_jump(delta: float) -> void:
	if is_on_floor():
		_coyote_timer = coyote_time
	else:
		_coyote_timer = max(0.0, _coyote_timer - delta)

	if not can_jump:
		return
	if not Input.is_action_just_pressed(jump_action):
		return
	if not (is_on_floor() or _coyote_timer > 0.0):
		return

	velocity.y = jump_velocity
	_coyote_timer = 0.0
	_jumped_this_frame = true
	jumped.emit()


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

func _update_state(world_move_dir: Vector3) -> void:
	var new_state: CharacterState
	if not is_on_floor():
		new_state = CharacterState.JUMPING if velocity.y > 0.0 else CharacterState.FALLING
	elif world_move_dir != Vector3.ZERO:
		new_state = CharacterState.WALKING
	else:
		new_state = CharacterState.IDLE

	if new_state != _state:
		var old_state := _state
		_state = new_state
		state_changed.emit(old_state, new_state)

func get_state() -> CharacterState:
	return _state

func get_last_move_direction() -> Vector3:
	return _last_move_direction
