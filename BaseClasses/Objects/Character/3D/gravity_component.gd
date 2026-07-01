class_name GravityComponent
extends Node
## GravityComponent
## -----------------
## Applies gravity to a sibling/parent CharacterBody3D each physics frame.
## Designed to be one piece of a modular character-controller stack. Pairs
## with a future MovementComponent/CameraController without owning movement
## itself; it only ever touches velocity.y.
##
## Usage: add as a child of (or sibling under the same parent as) a
## CharacterBody3D. Call apply(delta) from that body's _physics_process,
## or just rely on this node's own _physics_process if `auto_apply` is true.


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal landed(impact_velocity: float)
signal left_ground()
signal terminal_velocity_reached(velocity: float)


# ---------------------------------------------------------------------------
# Exported configuration
# ---------------------------------------------------------------------------

## The body this component applies gravity to. If left unset, _ready() will
## use the parent node if it's a CharacterBody3D, otherwise it looks for a
## CharacterBody3D sibling under the same parent.
@export var body: CharacterBody3D

@export_group("Gravity")
## If true, gravity_value is ignored and ProjectSettings'
## physics/3d/default_gravity is used instead (re-read every frame, so
## changing it at runtime is picked up automatically).
@export var use_project_gravity: bool = true
## Custom gravity magnitude (units/sec^2), used when use_project_gravity is false.
@export var gravity_value: float = 9.8
## Multiplier applied on top of whichever gravity source is active.
@export var gravity_scale: float = 1.0

@export_group("Terminal Velocity")
## Max downward fall speed. 0 (or negative) = uncapped.
@export var terminal_velocity: float = 0.0

@export_group("Behavior")
## If true, this node runs its own _physics_process and applies gravity
## automatically. If false, an external controller is expected to call
## apply(delta) manually (e.g. from its own _physics_process, before
## calling move_and_slide()).
@export var auto_apply: bool = true
## If true and auto_apply is true, this component also calls
## body.move_and_slide() itself after applying gravity. Turn this off if
## another component (movement controller) is responsible for that call.
@export var auto_move_and_slide: bool = false


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _was_on_floor: bool = true
var _has_emitted_terminal: bool = false


func _ready() -> void:
	if body == null:
		body = _find_parent_body()
	if body == null:
		body = _find_sibling_body()
	if body == null:
		push_warning("GravityComponent: no CharacterBody3D assigned or found; gravity disabled.")

	if body != null:
		_was_on_floor = body.is_on_floor()


func _physics_process(delta: float) -> void:
	if not auto_apply or body == null:
		return
	apply(delta)
	if auto_move_and_slide:
		body.move_and_slide()
	check_floor_transition()


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------

## Adds one physics step of gravity to body.velocity.y. Call this yourself
## (before move_and_slide) if auto_apply is false.
func apply(delta: float) -> void:
	if body == null:
		return

	if body.is_on_floor():
		# Keep a small downward velocity so is_on_floor() stays true on
		# slopes/stairs instead of flickering, without accumulating fall speed.
		if body.velocity.y < 0.0:
			body.velocity.y = -0.1
		_has_emitted_terminal = false
		return

	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) if use_project_gravity else gravity_value
	body.velocity.y -= g * gravity_scale * delta

	if terminal_velocity > 0.0 and body.velocity.y < -terminal_velocity:
		body.velocity.y = -terminal_velocity
		if not _has_emitted_terminal:
			_has_emitted_terminal = true
			terminal_velocity_reached.emit(body.velocity.y)

## Useful when auto_move_and_slide is false and an external controller calls
## apply() then move_and_slide() itself. Call this right after that, once
## per physics frame, to keep landed/left_ground signals firing correctly.
## Re-evaluates grounded state and fires landed/left_ground if it changed.
## Called automatically each physics frame when auto_apply is true; call this
## yourself once per physics frame (after move_and_slide) when auto_apply is
## false and an external controller owns the physics loop.
func check_floor_transition() -> void:
	if body == null:
		return
	var on_floor := body.is_on_floor()
	if on_floor and not _was_on_floor:
		landed.emit(abs(body.velocity.y))
	elif not on_floor and _was_on_floor:
		left_ground.emit()
	_was_on_floor = on_floor


# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------

func is_falling() -> bool:
	return body != null and not body.is_on_floor() and body.velocity.y < 0.0

func is_rising() -> bool:
	return body != null and not body.is_on_floor() and body.velocity.y > 0.0

func get_current_gravity() -> float:
	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8) if use_project_gravity else gravity_value
	return g * gravity_scale

## Instantly zeroes vertical velocity (e.g. when entering a no-gravity zone,
## or right before a controller wants to set a custom jump velocity).
func reset_vertical_velocity() -> void:
	if body != null:
		body.velocity.y = 0.0


# ---------------------------------------------------------------------------
# Auto-resolution helpers
# ---------------------------------------------------------------------------

func _find_parent_body() -> CharacterBody3D:
	var parent := get_parent()
	if parent is CharacterBody3D:
		return parent
	return null

func _find_sibling_body() -> CharacterBody3D:
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child is CharacterBody3D:
			return child
	return null
