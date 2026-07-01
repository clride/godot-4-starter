class_name HealthComponent
extends Node
## HealthComponent
## ----------------
## A self-contained, dimension-independent health system (works the same
## whether attached to a Node2D, Node3D, or pure-logic Node. It never
## touches position/transform). Attach as a child node to anything that
## needs health: players, enemies, destructible props, turrets, etc.
##
## Features:
##   - Current / max health with clamping
##   - Damage with source + damage-type tracking
##   - Per-damage-type resistance multipliers
##   - Healing
##   - Death / revive lifecycle
##   - Temporary invulnerability (i-frames), timed or manual toggle


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Fired whenever current health changes, for any reason.
signal health_changed(new_health: float, old_health: float)

## Fired whenever max health changes.
signal max_health_changed(new_max: float, old_max: float)

## Fired when damage is successfully applied (post-resistance, post-invuln check).
## `source` is whatever Node dealt the damage (can be null). `damage_type` is a
## free-form string tag (e.g. "fire", "physical", "fall").
signal damaged(amount: float, source: Node, damage_type: String)

## Fired when damage was attempted but fully blocked (invulnerable or dead).
signal damage_blocked(amount: float, source: Node, damage_type: String)

## Fired when healing is applied.
signal healed(amount: float, source: Node)

## Fired once, the moment health reaches 0.
signal died(source: Node, damage_type: String)

## Fired when revive() brings the component back from a dead state.
signal revived(new_health: float)

## Fired when invulnerability turns on / off.
signal invulnerability_started(duration: float)
signal invulnerability_ended()


# ---------------------------------------------------------------------------
# Exported configuration
# ---------------------------------------------------------------------------

@export var max_health: float = 100.0:
	set = set_max_health

@export var health: float = 100.0:
	set = set_health

## If true, take_damage() always does nothing, regardless of timer state.
@export var invulnerable: bool = false

## Used by grant_invulnerability() when no explicit duration is passed.
@export var default_invulnerability_duration: float = 0.5

## damage_type -> multiplier. 0.0 = full immunity, 1.0 = normal, >1.0 = weakness.
## Unlisted damage types default to a multiplier of 1.0.
@export var damage_resistances: Dictionary = {}


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _is_dead: bool = false
var _last_damage_source: Node = null
var _last_damage_type: String = ""
var _invuln_timer: Timer = null


func _ready() -> void:
	_invuln_timer = Timer.new()
	_invuln_timer.one_shot = true
	_invuln_timer.timeout.connect(_on_invulnerability_timeout)
	add_child(_invuln_timer)


# ---------------------------------------------------------------------------
# Health getters / setters
# ---------------------------------------------------------------------------

func set_max_health(value: float) -> void:
	var old_max := max_health
	max_health = max(0.0, value)
	if max_health != old_max:
		max_health_changed.emit(max_health, old_max)
	# Re-clamp current health if the ceiling dropped below it.
	if health > max_health:
		set_health(max_health)

func set_health(value: float) -> void:
	var old_health := health
	var clamped: float = clamp(value, 0.0, max_health)
	if clamped == old_health:
		return
	health = clamped
	health_changed.emit(health, old_health)
	if health <= 0.0 and not _is_dead:
		_handle_death()

func get_health() -> float:
	return health

func get_max_health() -> float:
	return max_health

func get_health_percent() -> float:
	if max_health <= 0.0:
		return 0.0
	return health / max_health

func is_dead() -> bool:
	return _is_dead

func is_full_health() -> bool:
	return health >= max_health


# ---------------------------------------------------------------------------
# Damage
# ---------------------------------------------------------------------------

## Applies damage, honoring invulnerability and per-type resistance.
## Returns the actual amount of damage applied (0.0 if blocked).
func take_damage(amount: float, source: Node = null, damage_type: String = "generic") -> float:
	if amount <= 0.0:
		return 0.0

	if _is_dead or invulnerable or is_invulnerable():
		damage_blocked.emit(amount, source, damage_type)
		return 0.0

	var resistance: float = damage_resistances.get(damage_type, 1.0)
	var final_amount: float = amount * resistance
	if final_amount <= 0.0:
		damage_blocked.emit(amount, source, damage_type)
		return 0.0

	_last_damage_source = source
	_last_damage_type = damage_type

	set_health(health - final_amount)
	damaged.emit(final_amount, source, damage_type)
	return final_amount

func get_last_damage_source() -> Node:
	return _last_damage_source

func get_last_damage_type() -> String:
	return _last_damage_type

func set_resistance(damage_type: String, multiplier: float) -> void:
	damage_resistances[damage_type] = multiplier

func get_resistance(damage_type: String) -> float:
	return damage_resistances.get(damage_type, 1.0)

func clear_resistance(damage_type: String) -> void:
	damage_resistances.erase(damage_type)


# ---------------------------------------------------------------------------
# Healing
# ---------------------------------------------------------------------------

## Applies healing. Returns the actual amount healed (0.0 if dead or already full).
func heal(amount: float, source: Node = null) -> float:
	if amount <= 0.0 or _is_dead:
		return 0.0
	var old_health := health
	set_health(health + amount)
	var actual := health - old_health
	if actual > 0.0:
		healed.emit(actual, source)
	return actual


# ---------------------------------------------------------------------------
# Death / revive
# ---------------------------------------------------------------------------

func _handle_death() -> void:
	_is_dead = true
	died.emit(_last_damage_source, _last_damage_type)

## Forces death immediately, bypassing damage calculation entirely.
func kill(source: Node = null, damage_type: String = "") -> void:
	if _is_dead:
		return
	_last_damage_source = source
	_last_damage_type = damage_type
	set_health(0.0)

## Brings the component back to life. Pass a negative value to revive at full health.
func revive(revive_health: float = -1.0) -> void:
	if not _is_dead:
		return
	_is_dead = false
	var new_health: float = max_health if revive_health < 0.0 else clamp(revive_health, 0.0, max_health)
	health = new_health
	revived.emit(new_health)
	health_changed.emit(new_health, 0.0)


# ---------------------------------------------------------------------------
# Invulnerability
# ---------------------------------------------------------------------------

## Grants timed invulnerability (i-frames). Pass duration <= 0 to use the default.
func grant_invulnerability(duration: float = -1.0) -> void:
	var d: float = default_invulnerability_duration if duration <= 0.0 else duration
	_invuln_timer.start(d)
	invulnerability_started.emit(d)

## Manual on/off toggle, independent of the timer (e.g. for "god mode").
func set_invulnerable(value: bool) -> void:
	if invulnerable == value:
		return
	invulnerable = value
	if invulnerable:
		invulnerability_started.emit(-1.0) # -1 signals "indefinite"
	else:
		invulnerability_ended.emit()

## True if either the manual flag or the timer-based i-frames are active.
func is_invulnerable() -> bool:
	return invulnerable or (_invuln_timer != null and _invuln_timer.time_left > 0.0)

func get_invulnerability_time_left() -> float:
	return _invuln_timer.time_left if _invuln_timer != null else 0.0

func _on_invulnerability_timeout() -> void:
	if not invulnerable: # only emit "ended" if manual flag isn't also holding it on
		invulnerability_ended.emit()
