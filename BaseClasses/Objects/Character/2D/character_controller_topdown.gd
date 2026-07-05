class_name CharacterControllerTopDown2D
extends CharacterBody2D
## CharacterController2DRPG
## -------------------------
## A top-down RPG character controller: 8-directional movement (no
## gravity, no jump), single walk_speed, smooth acceleration/deceleration,
## and configurable sprite-facing behavior. Owns the physics loop (calls
## move_and_slide itself). Input is read directly from Godot's Input
## singleton using configurable action names. Make sure matching actions
## exist in Project > Input Map (defaults below assume
## "move_left"/"move_right"/"move_up"/"move_down").
##
## Rigidbody pushing: applies a continuous, mass-scaled force to any
## RigidBody2D the character slides into. Unlike a platformer, there's no
## "floor" concept here - top-down movement has no vertical axis to
## exclude - so every slide contact against a RigidBody2D contributes to
## the push, using the full collision normal. Multiple contacts against
## the same RigidBody2D in one frame are merged into a single averaged
## push instead of stacking.

# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

enum FacingMode {
	STATIC,                   ## Character sprite never updates facing on its own.
	FACE_MOVE_DIRECTION_4,  ## Snaps facing to up/down/left/right.
	FACE_MOVE_DIRECTION_8,  ## Snaps facing to up/down/left/right + diagonals.
}

enum CharacterState {
	IDLE,
	WALKING,
}


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal state_changed(old_state: CharacterState, new_state: CharacterState)
signal moved(direction: Vector2, speed: float)
signal facing_changed(old_direction: String, new_direction: String)


# ---------------------------------------------------------------------------
# Exported configuration
# ---------------------------------------------------------------------------

@export_group("Speed")
## Global multiplier applied to walk_speed, acceleration, and
## deceleration. 1.0 = no change, 2.0 = double speed.
@export var speed_multiplier: float = 1.0

@export_group("Movement")
@export var walk_speed: float = 200.0
@export var acceleration: float = 1200.0
@export var deceleration: float = 1200.0
## If true, velocity snaps directly to the target velocity each frame
## instead of easing via acceleration/deceleration.
@export var instant_movement: bool = false

@export_group("Facing")
@export var facing_mode: FacingMode = FacingMode.FACE_MOVE_DIRECTION_4
## Node whose facing is updated. Works automatically with Sprite2D /
## AnimatedSprite2D (via flip_h, left/right only). Leave unset to flip
## this character node itself.
@export var facing_node: Node2D
## Direction retained on spawn / before any input.
@export var default_facing: String = "down"

@export_group("Input Actions")
@export var input_left_action: String = "move_left"
@export var input_right_action: String = "move_right"
@export var input_up_action: String = "move_forward"
@export var input_down_action: String = "move_back"

@export_group("Rigidbody Push")
## If false, the character will slide against RigidBody2D obstacles as if
## they were static (no push force applied).
@export var push_enabled: bool = true
## Continuous push force applied per kg of the rigidbody being pushed.
## Tune this rather than treating it like an impulse - this is a force
## (integrated over the physics step by the engine), not a kick.
@export var push_force_per_kg: float = 300.0
## Hard cap on push force regardless of mass, so very light bodies can't
## be launched by a single frame of contact.
@export var max_push_force: float = 2000.0


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _state: CharacterState = CharacterState.IDLE
var _last_move_direction: Vector2 = Vector2.ZERO
var _facing_direction: String = ""

# 8-directional buckets, in angle order starting at "right" and going
# clockwise (screen space, +y is down). Used by both the 4-way (which just
# collapses diagonals to the nearer cardinal) and 8-way snapping.
const _DIRECTION_ORDER_8 := [
	"right", "down_right", "down", "down_left",
	"left", "up_left", "up", "up_right",
]


func _ready() -> void:
	_facing_direction = default_facing


func _physics_process(delta: float) -> void:
	var input_dir := _get_input_vector()

	_handle_movement(input_dir, delta)
	move_and_slide()
	_handle_facing(input_dir)
	_update_state(input_dir)
	_apply_rigidbody_push()

	if input_dir != Vector2.ZERO:
		_last_move_direction = input_dir
		moved.emit(input_dir, velocity.length())


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _get_input_vector() -> Vector2:
	# get_vector clamps diagonals to length 1 instead of letting them add
	# up to sqrt(2), so diagonal movement isn't faster than cardinal.
	return Input.get_vector(input_left_action, input_right_action, input_up_action, input_down_action)


# ---------------------------------------------------------------------------
# Speed
# ---------------------------------------------------------------------------

func get_effective_walk_speed() -> float:
	return walk_speed * speed_multiplier

func get_effective_acceleration() -> float:
	return acceleration * speed_multiplier

func get_effective_deceleration() -> float:
	return deceleration * speed_multiplier


# ---------------------------------------------------------------------------
# Movement
# ---------------------------------------------------------------------------

func _handle_movement(input_dir: Vector2, delta: float) -> void:
	var target_velocity: Vector2 = input_dir * get_effective_walk_speed()

	if instant_movement:
		velocity = target_velocity
		return

	var rate: float = get_effective_acceleration() if input_dir != Vector2.ZERO else get_effective_deceleration()
	velocity = velocity.move_toward(target_velocity, rate * delta)


# ---------------------------------------------------------------------------
# Facing
# ---------------------------------------------------------------------------

func get_facing_direction() -> String:
	return _facing_direction

func _handle_facing(input_dir: Vector2) -> void:
	if facing_mode == FacingMode.STATIC:
		return
	if input_dir == Vector2.ZERO:
		return

	var new_direction := _snap_direction(input_dir)
	if new_direction == _facing_direction:
		return

	var old_direction := _facing_direction
	_facing_direction = new_direction
	facing_changed.emit(old_direction, new_direction)

	var target: Node2D = facing_node if facing_node != null else self
	if target is Sprite2D or target is AnimatedSprite2D:
		if new_direction.ends_with("left"):
			target.flip_h = true
		elif new_direction.ends_with("right"):
			target.flip_h = false
	elif target is CollisionObject2D:
		# Never mirror scale on a physics body (self included) - it mirrors
		# the CollisionShape2D's transform too and fights with
		# move_and_slide, causing jitter. Assign a Sprite2D/AnimatedSprite2D
		# (or a plain visual-only Node2D) to facing_node instead.
		push_warning("CharacterController2DRPG: facing_node resolved to a CollisionObject2D (%s) - skipping scale-flip to avoid physics jitter. Assign a Sprite2D/AnimatedSprite2D or non-physics Node2D instead." % target.name)

func _snap_direction(v: Vector2) -> String:
	if facing_mode == FacingMode.FACE_MOVE_DIRECTION_4:
		# Whichever axis dominates wins; ties go to horizontal.
		if absf(v.x) >= absf(v.y):
			return "right" if v.x >= 0.0 else "left"
		return "down" if v.y >= 0.0 else "up"

	# 8-directional: bucket the angle into 8 slices of 45 degrees, offset
	# by half a slice so each named direction is centered on its slice
	# rather than starting at its edge.
	var angle := v.angle()  # radians, 0 = right, increases clockwise (screen space)
	var slice := TAU / 8.0
	var index := int(round(angle / slice)) % 8
	if index < 0:
		index += 8
	return _DIRECTION_ORDER_8[index]


# ---------------------------------------------------------------------------
# Rigidbody pushing
# ---------------------------------------------------------------------------

## Applies a continuous, mass-scaled push force to any RigidBody2D the
## character is in slide contact with this frame. There's no floor/ceiling
## concept in a top-down controller, so (unlike a platformer) every
## contact's full normal counts - nothing is excluded. Multiple contacts
## against the same body in one frame are merged into a single averaged
## direction instead of applying force once per contact.
func _apply_rigidbody_push() -> void:
	if not push_enabled:
		return

	var accumulated: Dictionary = {}

	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider := collision.get_collider()
		if not (collider is RigidBody2D):
			continue

		var normal := collision.get_normal()
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
# State
# ---------------------------------------------------------------------------

func _update_state(input_dir: Vector2) -> void:
	var new_state: CharacterState = CharacterState.WALKING if input_dir != Vector2.ZERO else CharacterState.IDLE

	if new_state != _state:
		var old_state := _state
		_state = new_state
		state_changed.emit(old_state, new_state)

func get_state() -> CharacterState:
	return _state

func get_last_move_direction() -> Vector2:
	return _last_move_direction
