class_name HealthRegenerator
extends Node
## HealthRegenerator
## ------------------
## Drives passive health regeneration on a sibling/assigned HealthComponent.
## Kept separate from HealthComponent itself so regen is opt-in and fully
## swappable (e.g. a "no regen" enemy vs a "fast regen" boss vs a player
## with a regen power-up that adds/removes this node at runtime).
##
## Regen rate can be a flat amount/sec, a percent-of-max-health/sec, or
## both combined. Damage can optionally interrupt regen for a cooldown
## period before it resumes. A regen cap lets you stop healing short of
## full (e.g. only regen to 50%); leave the cap at 0 (or >= max_health)
## to always regen all the way to full.


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Fired the moment regen transitions from idle/paused to actively healing.
signal regen_started()

## Fired when regen stops (cap reached, health component died, disabled, etc).
signal regen_stopped()

## Fired every time regen actually adds health. `new_health` is post-tick.
signal regen_tick(amount: float, new_health: float)

## Fired when damage interrupts regen and the delay countdown begins.
signal regen_interrupted(delay: float)


# ---------------------------------------------------------------------------
# Exported configuration
# ---------------------------------------------------------------------------

@export var enabled: bool = true

## The HealthComponent this regenerator acts on. If left unset, _ready()
## will use the parent node if it's a HealthComponent itself, otherwise it
## will look for a HealthComponent sibling under the same parent.
@export var health_component: HealthComponent

# --- Rate ---

@export_group("Rate")
@export var use_flat_rate: bool = true
## Health points healed per second (when use_flat_rate is true).
@export var flat_rate: float = 5.0

@export var use_percent_rate: bool = false
## Fraction of max_health healed per second (when use_percent_rate is true).
## e.g. 0.02 = 2% of max health per second.
@export var percent_rate: float = 0.02

## 0 = apply continuously every frame. >0 = apply in discrete chunks every
## N seconds instead (e.g. "5 HP every 1.0s" rather than a smooth ramp).
@export var tick_interval: float = 0.0

# --- Interruption ---

@export_group("Interruption")
@export var interrupt_on_damage: bool = true
## Seconds to wait after taking damage before regen resumes.
@export var regen_delay: float = 2.0

# --- Cap ---

@export_group("Cap")
## Health value regen will stop at. Set to 0 (or anything >= max_health)
## to always regen all the way to full.
@export var regen_cap: float = 0.0


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

var _delay_timer: Timer = null
var _tick_accumulator: float = 0.0
var _is_regenerating: bool = false


func _ready() -> void:
	_delay_timer = Timer.new()
	_delay_timer.one_shot = true
	add_child(_delay_timer)

	if health_component == null:
		health_component = _find_parent_health_component()
	if health_component == null:
		health_component = _find_sibling_health_component()

	if health_component != null:
		health_component.damaged.connect(_on_health_component_damaged)
		health_component.died.connect(_on_health_component_died)
		health_component.revived.connect(_on_health_component_revived)
	else:
		push_warning("HealthRegenerator: no HealthComponent assigned or found; regen disabled.")


func _process(delta: float) -> void:
	if not _can_regen():
		_set_regenerating(false)
		return

	var cap := _effective_cap()
	if health_component.get_health() >= cap:
		_set_regenerating(false)
		return

	var amount := _compute_rate() * delta
	if amount <= 0.0:
		_set_regenerating(false)
		return

	if tick_interval > 0.0:
		_tick_accumulator += delta
		if _tick_accumulator < tick_interval:
			_set_regenerating(true)
			return
		amount = _compute_rate() * tick_interval
		_tick_accumulator = 0.0

	_apply_regen(amount, cap)


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------

func _can_regen() -> bool:
	if not enabled or health_component == null:
		return false
	if health_component.is_dead():
		return false
	if interrupt_on_damage and _delay_timer.time_left > 0.0:
		return false
	return true

func _effective_cap() -> float:
	var max_h := health_component.get_max_health()
	if regen_cap <= 0.0 or regen_cap >= max_h:
		return max_h
	return regen_cap

func _compute_rate() -> float:
	var rate := 0.0
	if use_flat_rate:
		rate += flat_rate
	if use_percent_rate:
		rate += percent_rate * health_component.get_max_health()
	return rate

func _apply_regen(amount: float, cap: float) -> void:
	var target_health: float = min(health_component.get_health() + amount, cap)
	var actual: float = target_health - health_component.get_health()
	if actual <= 0.0:
		_set_regenerating(false)
		return
	health_component.heal(actual, self)
	_set_regenerating(true)
	regen_tick.emit(actual, health_component.get_health())

func _set_regenerating(value: bool) -> void:
	if _is_regenerating == value:
		return
	_is_regenerating = value
	if value:
		regen_started.emit()
	else:
		regen_stopped.emit()


# ---------------------------------------------------------------------------
# HealthComponent event handlers
# ---------------------------------------------------------------------------

func _on_health_component_damaged(_amount: float, _source: Node, _damage_type: String) -> void:
	if not interrupt_on_damage:
		return
	_delay_timer.start(regen_delay)
	_tick_accumulator = 0.0
	_set_regenerating(false)
	regen_interrupted.emit(regen_delay)

func _on_health_component_died(_source: Node, _damage_type: String) -> void:
	_set_regenerating(false)

func _on_health_component_revived(_new_health: float) -> void:
	_tick_accumulator = 0.0


# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------

## Immediately interrupts regen for `regen_delay` seconds (or a custom duration),
## without requiring an actual damage event.
func interrupt(duration: float = -1.0) -> void:
	var d: float = regen_delay if duration < 0.0 else duration
	_delay_timer.start(d)
	_tick_accumulator = 0.0
	_set_regenerating(false)
	regen_interrupted.emit(d)

## Clears any active interruption delay so regen can resume immediately.
func clear_interrupt() -> void:
	_delay_timer.stop()

func is_regenerating() -> bool:
	return _is_regenerating

func get_delay_time_left() -> float:
	return _delay_timer.time_left if _delay_timer != null else 0.0

func _find_parent_health_component() -> HealthComponent:
	var parent := get_parent()
	if parent is HealthComponent:
		return parent
	return null

func _find_sibling_health_component() -> HealthComponent:
	var parent := get_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child is HealthComponent:
			return child
	return null
