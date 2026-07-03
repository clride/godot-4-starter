class_name CharacterController2D
extends CharacterBody2D
## CharacterController2D
## ----------------------
## A 2D platformer character controller: single walk_speed, jump with
## coyote time and optional jump buffering, smooth acceleration/
## deceleration, and configurable sprite-facing behavior. Owns the physics
## loop (calls move_and_slide itself). Input is read directly from Godot's
## Input singleton using configurable action names. Make sure matching
## actions exist in Project > Input Map (defaults below assume
## "move_left"/"move_right"/"jump").
##
## Rigidbody pushing: applies a continuous, mass-scaled force to any
## RigidBody2D the character slides into, using only the horizontal
## component of the collision normal. Collisions with a mostly-vertical
## normal (standing on top of a body, or being pushed from below) are
## skipped, since those aren't "walking into" contacts and are the main
## cause of edge/corner launching from my experience. Multiple contacts
## against the same RigidBody2D in one frame are merged into a single
## averaged push instead of stacking.
##
## Wall bounce: optional alternative to the default "slide to a stop"
## behavior against walls. When enabled, a wall-like contact (mostly
## horizontal collision normal) that the character was actively moving
## into reverses horizontal velocity, scaled by wall_bounce_factor,
## instead of just zeroing it out.

# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

enum FacingMode {
	STATIC,                 ## Character sprite never flips on its own.
	FACE_MOVE_DIRECTION,  ## Flips to face the direction it's currently moving (left/right).
}

enum AirControlMode {
	FULL,     ## Full directional control while airborne, same as being grounded.
	PARTIAL,  ## Reduced control while airborne, scaled by separate acceleration/deceleration control amounts. NOTE: Is ignored if 'Instant Movement' is true.
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
signal moved(direction: float, speed: float)
signal bounced_off_wall(previous_velocity_x: float, new_velocity_x: float)


# ---------------------------------------------------------------------------
# Exported configuration
# ---------------------------------------------------------------------------

@export_group("Speed")
## Global multiplier applied to walk_speed, acceleration, deceleration, and
## the partial air control rates. 1.0 = no change, 2.0 = double speed.
@export var speed_multiplier: float = 1.0

@export_group("Movement")
@export var walk_speed: float = 300.0
@export var acceleration: float = 1500.0
@export var deceleration: float = 1500.0
## If true, horizontal velocity snaps directly to the target speed each
## frame instead of easing via acceleration/deceleration. Applies to
## grounded movement and both air control modes.
@export var instant_movement: bool = false

@export_group("Air Control")
@export var air_control_mode: AirControlMode = AirControlMode.FULL
## Acceleration rate used while airborne under AirControlMode.PARTIAL, in
## the same units as the grounded acceleration value.
@export var partial_air_acceleration: float = 900.0
## Deceleration rate used while airborne under AirControlMode.PARTIAL, in
## the same units as the grounded deceleration value.
@export var partial_air_deceleration: float = 900.0

@export_group("Gravity")
## If true, gravity_value is ignored and ProjectSettings'
## physics/2d/default_gravity is used instead (re-read every frame, so
## changing it at runtime is picked up automatically).
@export var use_project_gravity: bool = true
## Custom gravity magnitude (px/sec^2), used when use_project_gravity is false.
@export var gravity_value: float = 980.0
## Multiplier applied on top of whichever gravity source is active.
@export var gravity_scale: float = 1.0
## Max downward fall speed. 0 (or negative) = uncapped.
@export var terminal_velocity: float = 0.0
## Multiplier applied to gravity while moving upward but the jump button
## has been released - the classic "short hop" cut for tighter jump feel.
## 1.0 = no change, disabled entirely when jump_velocity is reached via
## a released jump; only used when can_jump is true.
@export var jump_cut_gravity_multiplier: float = 1.0

@export_group("Jump")
@export var can_jump: bool = true
@export var jump_velocity: float = -400.0
## Optional grace period (seconds) after leaving a ledge where jump still works.
@export var coyote_time: float = 0.0
## Optional grace period (seconds) before landing during which a jump
## press is remembered and fired the instant the character touches ground.
## Set to 0 to disable (jump presses while airborne are simply ignored).
@export var jump_buffer_time: float = 0.0
## When true, holding the jump button will auto-jump on every landing
## frame (no need to re-press). Works with coyote_time as usual.
@export var auto_jump: bool = false

@export_group("Facing")
@export var facing_mode: FacingMode = FacingMode.FACE_MOVE_DIRECTION
## Node whose horizontal facing is flipped. Works automatically with
## Sprite2D / AnimatedSprite2D (via flip_h) or any other Node2D (via
## mirroring scale.x). Leave unset to flip this character node itself.
@export var facing_node: Node2D

@export_group("Input Actions")
@export var input_left_action: String = "move_left"
@export var input_right_action: String = "move_right"
@export var jump_action: String = "jump"

@export_group("Rigidbody Push")
## If false, the character will slide against RigidBody2D obstacles as if
## they were static (no push force applied).
@export var push_enabled: bool = true
## Continuous push force applied per kg of the rigidbody being pushed.
## Tune this rather than treating it like the old impulse magnitude - this
## is a force (integrated over the physics step by the engine), not a kick.
@export var push_force_per_kg: float = 300.0
## Hard cap on push force regardless of mass, so very light bodies can't be
## launched by a single frame of contact.
@export var max_push_force: float = 2000.0
## Collision normals with an absolute Y component above this are treated
## as "standing on top of" / "pushed from below" contacts and are excluded
## from pushing. This is what prevents edge/corner launching.
@export var push_vertical_normal_cutoff: float = 0.7

@export_group("Wall Bounce")
## If true, hitting a wall-like surface while moving into it reverses
## horizontal velocity instead of the default "slide to a stop" behavior.
@export var wall_bounce_enabled: bool = false
## Multiplier applied to horizontal speed on bounce. 1.0 = perfectly
## elastic (same speed, reversed direction), 0.5 = half speed retained,
## 0.0 = no rebound (character just stops, same as a normal wall slide).
@export_range(0.0, 2.0, 0.01) var wall_bounce_factor: float = 1.0
## Minimum horizontal speed required to trigger a bounce. Contacts below
## this speed are left alone (normal slide-to-stop) to avoid jittery
## micro-bounces when barely brushing a wall.
@export var wall_bounce_min_speed: float = 20.0
## Collision normals with an absolute Y component at or below this are
## treated as "wall" contacts eligible for bouncing (mirrors
## push_vertical_normal_cutoff, but selecting mostly-horizontal normals
## instead of mostly-vertical ones).
@export var wall_bounce_normal_max_y: float = 0.3
## Optional window (seconds) after a bounce during which horizontal input
## is ignored and velocity.x is left untouched. Without this, held
## movement input toward the wall would immediately re-accelerate through
## _handle_horizontal_movement on the very next frame and cancel the
## bounce before it's visible. Set to 0 to disable (input regains control
## immediately, which is fine for high acceleration/instant_movement
## setups where a visible bounce isn't the goal).
@export var wall_bounce_lockout_time: float = 0.1

## If false, wall bouncing will be possible without being in the air
@export var wall_bounce_in_air_only: bool = true


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _state: CharacterState = CharacterState.IDLE
var _coyote_timer: float = 0.0
var _jump_buffer_timer: float = 0.0
var _last_move_direction: float = 0.0
var _was_on_floor: bool = true
var _has_emitted_terminal: bool = false
var _jumped_this_frame: bool = false
var _wall_bounce_lockout_timer: float = 0.0


func _physics_process(delta: float) -> void:
	_jumped_this_frame = false
	_wall_bounce_lockout_timer = max(0.0, _wall_bounce_lockout_timer - delta)

	var input_dir := _get_input_direction()

	_apply_gravity(delta)
	_handle_jump(delta, input_dir)
	_handle_horizontal_movement(input_dir, delta)
	_handle_facing(input_dir)

	var pre_slide_velocity_x := velocity.x
	move_and_slide()
	_handle_wall_bounce(pre_slide_velocity_x)
	_check_floor_transition()
	_update_state(input_dir)
	_apply_rigidbody_push()

	if input_dir != 0.0:
		_last_move_direction = input_dir
		moved.emit(input_dir, absf(velocity.x))


# ---------------------------------------------------------------------------
# Gravity
# ---------------------------------------------------------------------------

func _apply_gravity(delta: float) -> void:
	if is_on_floor():
		_has_emitted_terminal = false
		return

	var g: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0) if use_project_gravity else gravity_value
	var scale := gravity_scale

	# Short-hop cut: if rising and the jump button has been released,
	# apply extra gravity for a snappier, more controllable jump arc.
	if can_jump and velocity.y < 0.0 and not Input.is_action_pressed(jump_action):
		scale *= jump_cut_gravity_multiplier

	velocity.y += g * scale * delta

	if terminal_velocity > 0.0 and velocity.y > terminal_velocity:
		velocity.y = terminal_velocity
		_has_emitted_terminal = true

func _check_floor_transition() -> void:
	var on_floor := is_on_floor()
	if on_floor and not _was_on_floor:
		landed.emit(absf(velocity.y))
	elif not on_floor and _was_on_floor:
		left_ground.emit()
	_was_on_floor = on_floor


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _get_input_direction() -> float:
	return Input.get_action_strength(input_right_action) - Input.get_action_strength(input_left_action)


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

func _handle_horizontal_movement(input_dir: float, delta: float) -> void:
	# While locked out after a wall bounce, leave velocity.x alone so the
	# rebound is actually visible instead of being instantly overridden by
	# acceleration/deceleration toward the input-driven target speed.
	if _wall_bounce_lockout_timer > 0.0:
		return

	var grounded := is_on_floor() and not _jumped_this_frame
	if grounded or air_control_mode == AirControlMode.FULL:
		_handle_grounded_movement(input_dir, delta)
	else:
		_handle_partial_air_movement(input_dir, delta)

func _handle_grounded_movement(input_dir: float, delta: float) -> void:
	var target_velocity := input_dir * get_effective_walk_speed()

	if instant_movement:
		velocity.x = target_velocity
	else:
		var rate: float = get_effective_acceleration() if input_dir != 0.0 else get_effective_deceleration()
		velocity.x = move_toward(velocity.x, target_velocity, rate * delta)

func _handle_partial_air_movement(input_dir: float, delta: float) -> void:
	var target_velocity := input_dir * get_effective_walk_speed()

	if instant_movement:
		velocity.x = target_velocity
	else:
		var rate: float = get_effective_partial_air_acceleration() if input_dir != 0.0 else get_effective_partial_air_deceleration()
		velocity.x = move_toward(velocity.x, target_velocity, rate * delta)


func _handle_facing(input_dir: float) -> void:
	if facing_mode == FacingMode.STATIC:
		return
	if input_dir == 0.0:
		return

	var target: Node2D = facing_node if facing_node != null else self
	var facing_right: bool = input_dir > 0.0

	if target is Sprite2D or target is AnimatedSprite2D:
		target.flip_h = not facing_right
	elif target is CollisionObject2D:
		# Never mirror scale on a physics body (self included) - it mirrors
		# the CollisionShape2D's transform too and fights with
		# move_and_slide, causing jitter against floors/walls. Assign a
		# Sprite2D/AnimatedSprite2D (or a plain visual-only Node2D) to
		# facing_node instead.
		push_warning("CharacterController2D: facing_node resolved to a CollisionObject2D (%s) - skipping scale-flip to avoid physics jitter. Assign a Sprite2D/AnimatedSprite2D or non-physics Node2D instead." % target.name)
	else:
		var s := target.scale
		s.x = absf(s.x) * (1.0 if facing_right else -1.0)
		target.scale = s


# ---------------------------------------------------------------------------
# Jump
# ---------------------------------------------------------------------------

func _handle_jump(delta: float, input_dir: float) -> void:
	if is_on_floor():
		_coyote_timer = coyote_time
	else:
		_coyote_timer = max(0.0, _coyote_timer - delta)

	if not can_jump:
		return

	var jump_pressed: bool
	if auto_jump:
		jump_pressed = Input.is_action_pressed(jump_action)
	else:
		jump_pressed = Input.is_action_just_pressed(jump_action)

	if jump_pressed and not (is_on_floor() or _coyote_timer > 0.0):
		# Not currently able to jump - remember the press for the buffer
		# window so it still fires the instant the character lands.
		_jump_buffer_timer = jump_buffer_time
	else:
		_jump_buffer_timer = max(0.0, _jump_buffer_timer - delta)

	var can_fire := is_on_floor() or _coyote_timer > 0.0
	var wants_jump := jump_pressed or (_jump_buffer_timer > 0.0 and is_on_floor())

	if not (can_fire and wants_jump):
		return

	velocity.y = jump_velocity
	_coyote_timer = 0.0
	_jump_buffer_timer = 0.0
	_jumped_this_frame = true
	jumped.emit()


# ---------------------------------------------------------------------------
# Rigidbody pushing
# ---------------------------------------------------------------------------

## Applies a continuous, mass-scaled push force to any RigidBody2D the
## character is in slide contact with this frame. Only the horizontal
## component of each collision normal is used, and contacts with a mostly
## vertical normal (standing on top, or pushed from below) are excluded -
## that's what stops edge/corner contacts from launching the body. Multiple
## contacts against the same body in one frame are merged into a single
## averaged direction instead of applying force once per contact.
func _apply_rigidbody_push() -> void:
	if not push_enabled:
		return

	# collider -> accumulated horizontal push direction (not yet normalized)
	var accumulated: Dictionary = {}

	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider := collision.get_collider()
		if not (collider is RigidBody2D):
			continue

		var normal := collision.get_normal()
		if absf(normal.y) > push_vertical_normal_cutoff:
			continue

		normal.y = 0.0
		if normal.length() < 0.0001:
			continue
		normal = normal.normalized()

		if accumulated.has(collider):
			accumulated[collider] += normal
		else:
			accumulated[collider] = normal

	for collider in accumulated.keys():
		var dir: Vector2 = accumulated[collider]
		if dir.length() < 0.0001:
			continue
		dir = dir.normalized()

		var rb := collider as RigidBody2D
		var force_mag: float = min(rb.mass * push_force_per_kg, max_push_force)
		rb.apply_central_force(-dir * force_mag)


# ---------------------------------------------------------------------------
# Wall bounce
# ---------------------------------------------------------------------------

## Checks this frame's slide collisions for a wall-like contact (mostly
## horizontal normal, per wall_bounce_normal_max_y) that the character was
## actively moving into, and if found, reverses horizontal velocity scaled
## by wall_bounce_factor instead of leaving it at the slide-stopped value.
## pre_slide_velocity_x is the horizontal velocity the character *intended*
## to move at this frame, captured right before move_and_slide() resolved
## collisions - that's what gets reflected, not whatever move_and_slide
## left behind.
func _handle_wall_bounce(pre_slide_velocity_x: float) -> void:
	if not wall_bounce_enabled:
		return
	if is_on_floor() and wall_bounce_in_air_only:
		return
	if absf(pre_slide_velocity_x) < wall_bounce_min_speed:
		return

	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var normal := collision.get_normal()

		# Skip floor/ceiling-ish contacts - only mostly-horizontal normals
		# count as "walls" here.
		if absf(normal.y) > wall_bounce_normal_max_y:
			continue
		if absf(normal.x) < 0.0001:
			continue

		# Only bounce if we were actually moving into this surface (not,
		# say, a wall behind us we're moving away from in the same frame).
		if sign(pre_slide_velocity_x) != sign(-normal.x):
			continue

		var new_velocity_x := -pre_slide_velocity_x * wall_bounce_factor
		velocity.x = new_velocity_x

		if wall_bounce_lockout_time > 0.0:
			_wall_bounce_lockout_timer = wall_bounce_lockout_time

		bounced_off_wall.emit(pre_slide_velocity_x, new_velocity_x)
		return  # One bounce per frame, even if multiple contacts qualify.


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

func _update_state(input_dir: float) -> void:
	var new_state: CharacterState
	if not is_on_floor():
		new_state = CharacterState.JUMPING if velocity.y < 0.0 else CharacterState.FALLING
	elif input_dir != 0.0:
		new_state = CharacterState.WALKING
	else:
		new_state = CharacterState.IDLE

	if new_state != _state:
		var old_state := _state
		_state = new_state
		state_changed.emit(old_state, new_state)

func get_state() -> CharacterState:
	return _state

func get_last_move_direction() -> float:
	return _last_move_direction
