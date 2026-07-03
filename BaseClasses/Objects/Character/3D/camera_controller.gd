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
##
## Free look (see `require_hold_to_look_in_third_person`): when the camera
## is in third person and `target` is a CharacterController3D whose
## rotation_mode is FACE_MOVE_DIRECTION, the character's facing isn't tied
## to camera yaw at all - so there's no need to force-capture the mouse
## just to look around. In that specific combination, the cursor is shown
## and camera rotation only happens while the right mouse button is held.
## The cursor stays visible even while turning, and is pinned to the exact
## screen position where the right mouse button was pressed, so it never
## drifts or hits a screen edge while dragging. This does not affect
## controller stick look, which still free-looks regardless of
## mouse/right-click state.


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

## When true, `visibility_target` is hidden in first person and shown in
## third person (prevents the character mesh from clipping into the camera).
@export var hide_target_in_first_person: bool = false
## The node hidden/shown when switching camera modes. Typically the
## character's visual root (e.g. a MeshInstance3D or an armature/Skeleton3D).
## Defaults to `target` if left unset.
@export var visibility_target: Node3D

@export_group("Look")
@export var mouse_sensitivity: float = 0.0035
@export var controller_sensitivity: float = 2.5 # radians/sec at full stick deflection
@export var invert_y: bool = false
@export var pitch_min_deg: float = -80.0
@export var pitch_max_deg: float = 80.0
@export var capture_mouse_on_ready: bool = true

@export_group("Free Look (Third Person)")
## When true: if the camera is in third person AND `target` is a
## CharacterController3D with rotation_mode == FACE_MOVE_DIRECTION, the
## mouse cursor is shown instead of captured, and camera yaw/pitch only
## respond to mouse motion while the right mouse button is held. Outside
## that specific combination (first person, or any other rotation_mode),
## behavior is unchanged - mouse look works as normal, cursor captured per
## capture_mouse_on_ready. Useful for action-camera-style third person
## where the character shouldn't be forced to face wherever the camera
## happens to be pointed.
@export var require_hold_to_look_in_third_person: bool = false

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
var _right_click_held: bool = false
## Tracks whether hold-to-look was active last frame, so we only touch the
## mouse capture state on the frame it actually changes (rather than
## fighting the user's own set_mouse_captured() calls every frame).
var _hold_to_look_was_active: bool = false
## True while the cursor is visible and pinned in place during a
## right-click drag in hold-to-look mode.
var _free_look_dragging: bool = false
## Screen position the cursor is pinned to while _free_look_dragging is true.
var _free_look_lock_position: Vector2 = Vector2.ZERO


func _ready() -> void:
	_build_rig()

	_target_distance = default_distance
	_current_distance = default_distance
	_mode = CameraMode.FIRST_PERSON if default_distance <= first_person_threshold else CameraMode.THIRD_PERSON
	_update_visibility()

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

	# In case hold-to-look conditions are already true on ready (e.g. mode
	# and target are both preconfigured in the editor), correct the initial
	# capture state immediately instead of waiting for the first _process.
	_hold_to_look_was_active = _is_hold_to_look_active()
	if _hold_to_look_was_active:
		_set_free_look_dragging(_right_click_held)


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

	_update_look_capture_state()
	_apply_controller_look(delta)
	_apply_free_look_drag()
	_update_distance(delta)
	_update_mode()
	_apply_transform()


# ---------------------------------------------------------------------------
# Look input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_look_input_enabled():
		_add_look_delta(event.relative.x * mouse_sensitivity, event.relative.y * mouse_sensitivity)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_right_click_held = event.pressed
			# Only hold-to-look manages the cursor off of right click;
			# outside that mode, right click is left free for other uses
			# (e.g. context actions) without touching the cursor.
			if _is_hold_to_look_active():
				_set_free_look_dragging(_right_click_held)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom(-zoom_step)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom(zoom_step)

## True while mouse motion events should drive camera look via their
## relative field. Only applies to normal full capture (first person, or
## third person outside hold-to-look); the pinned-cursor drag used in
## hold-to-look is driven separately by _apply_free_look_drag().
func _mouse_look_input_enabled() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

## While dragging in hold-to-look mode, reads how far the cursor has moved
## from its pinned position, feeds that into the look delta, then warps the
## cursor back so it appears stationary on screen. Runs once per frame
## instead of per input event so the correction never has to fight event
## batching.
func _apply_free_look_drag() -> void:
	if not _free_look_dragging:
		return
	var current_position := get_viewport().get_mouse_position()
	var motion := current_position - _free_look_lock_position
	if motion == Vector2.ZERO:
		return
	_add_look_delta(motion.x * mouse_sensitivity, motion.y * mouse_sensitivity)
	get_viewport().warp_mouse(_free_look_lock_position)

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
# Free look / mouse capture management
# ---------------------------------------------------------------------------

## True when the mouse should be shown-by-default and gated behind a
## right-click hold: third person, feature enabled, and the target's own
## rotation_mode is FACE_MOVE_DIRECTION (i.e. the character's facing isn't
## driven by camera yaw, so there's nothing lost by not always capturing).
func _is_hold_to_look_active() -> bool:
	if not require_hold_to_look_in_third_person:
		return false
	if _mode != CameraMode.THIRD_PERSON:
		return false
	if not (target is CharacterController3D):
		return false
	return (target as CharacterController3D).rotation_mode == CharacterController3D.RotationMode.FACE_MOVE_DIRECTION

## Reacts to hold-to-look turning on/off (via camera mode changes, or the
## target's rotation_mode changing externally at runtime) by correcting the
## cursor state on the transition frame only.
func _update_look_capture_state() -> void:
	if not require_hold_to_look_in_third_person:
		return

	var active := _is_hold_to_look_active()
	if active == _hold_to_look_was_active:
		return

	if active:
		# Entering hold-to-look: cursor visible unless right click already
		# happens to be held down at the moment conditions became true.
		_set_free_look_dragging(_right_click_held)
	else:
		# Leaving hold-to-look (switched to first person, or rotation_mode
		# changed away from FACE_MOVE_DIRECTION): go back to fully captured,
		# matching this rig's normal default behavior.
		_free_look_dragging = false
		set_mouse_captured(true)

	_hold_to_look_was_active = active

## Cursor state used specifically for hold-to-look. The cursor is always
## visible in this mode. `dragging = true` pins it to the screen position
## it was at the moment the drag started (recorded here), so it never
## visibly moves while the camera turns; `dragging = false` releases the
## pin and lets it move freely again.
func _set_free_look_dragging(dragging: bool) -> void:
	_free_look_dragging = dragging
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if dragging:
		_free_look_lock_position = get_viewport().get_mouse_position()


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
		_update_visibility()


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

func _update_visibility() -> void:
	if not hide_target_in_first_person:
		return
	var node := visibility_target if visibility_target != null else target
	if node == null:
		return
	node.visible = _mode != CameraMode.FIRST_PERSON

func set_mouse_captured(captured: bool) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

func is_mouse_captured() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
