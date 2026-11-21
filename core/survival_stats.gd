class_name SurvivalStats
extends RefCounted
## Health, stamina, hunger (satiety), thirst (hydration), body temperature, rest + conditions.
## Pure logic: the owner calls tick(delta, env) every physics frame or in bulk for time skips.
## All rates are per simulated second at difficulty 1.0.

signal died(cause: StringName)
signal condition_added(id: StringName)
signal condition_removed(id: StringName)

const MAX := 100.0
const NORMAL_TEMP := 37.0
const HYPOTHERMIA_TEMP := 35.0
const HYPOTHERMIA_RECOVER := 35.5
const OVERHEAT_TEMP := 38.6
const COMFORT_MIN := 12.0  # effective °C (ambient + warmth + insulation)
const COMFORT_MAX := 30.0

# Tunables (difficulty scales the drains).
var hunger_rate := MAX / 2400.0
var thirst_rate := MAX / 1500.0
var rest_rate := MAX / 2160.0
var rest_regen_sleeping := MAX / 420.0
var stamina_regen := 14.0
var sprint_cost := 13.0
var difficulty := 1.0

var health := MAX
var stamina := MAX
var hunger := MAX
var thirst := MAX
var rest := MAX
var body_temp := NORMAL_TEMP
## id -> remaining seconds; INF = until cured.
var conditions: Dictionary = {}
var dead := false
var death_cause: StringName = &""
var last_effective_temp := 18.0

var _stamina_delay := 0.0


func max_stamina() -> float:
	var m := MAX
	if rest <= 0.0:
		m = 50.0
	elif rest < 20.0:
		m = 75.0
	if hunger <= 10.0:
		m = minf(m, 70.0)
	return m


func can_sprint() -> bool:
	return stamina > 5.0 and not has_condition(&"fracture")


func has_condition(id: StringName) -> bool:
	return conditions.has(id)


func add_condition(id: StringName, duration: float = INF) -> void:
	var is_new := not conditions.has(id)
	conditions[id] = maxf(float(conditions.get(id, 0.0)), duration)
	if is_new:
		condition_added.emit(id)


func remove_condition(id: StringName) -> void:
	if conditions.erase(id):
		condition_removed.emit(id)


func use_stamina(amount: float) -> bool:
	if stamina < amount:
		return false
	stamina -= amount
	_stamina_delay = 1.0
	return true


func damage(amount: float, cause: StringName = &"injury") -> void:
	if dead or amount <= 0.0:
		return
	health = maxf(health - amount, 0.0)
	if health <= 0.0:
		dead = true
		death_cause = cause
		died.emit(cause)


## Applies a consumable's effects. Returns true if the item caused sickness.
func consume(item: ItemData, rng_roll: float = randf()) -> bool:
	hunger = minf(hunger + item.food, MAX)
	thirst = minf(thirst + item.water, MAX)
	health = minf(health + item.health, MAX)
	for c: String in item.cures:
		remove_condition(StringName(c))
	if item.sickness_chance > 0.0 and rng_roll < item.sickness_chance:
		add_condition(&"food_poisoning", 120.0)
		return true
	return false


## env keys: ambient_temp (°C), warmth (°C from fires), insulation (°C), sleeping, sprinting.
func tick(delta: float, env: Dictionary) -> void:
	if dead or delta <= 0.0:
		return
	var sleeping: bool = env.get("sleeping", false)
	var sprinting: bool = env.get("sprinting", false)
	last_effective_temp = float(env.get("ambient_temp", 18.0)) + float(env.get("warmth", 0.0)) \
		+ float(env.get("insulation", 4.0))

	# Needs.
	var need_mult := difficulty * (0.5 if sleeping else 1.0)
	var hunger_mult := 1.4 if body_temp < 36.0 else 1.0
	var thirst_mult := 1.0
	if body_temp > OVERHEAT_TEMP:
		thirst_mult += 1.0
	if sprinting:
		thirst_mult += 0.6
	if has_condition(&"food_poisoning"):
		thirst_mult += 1.0
	hunger = maxf(hunger - hunger_rate * need_mult * hunger_mult * delta, 0.0)
	thirst = maxf(thirst - thirst_rate * need_mult * thirst_mult * delta, 0.0)
	if sleeping:
		rest = minf(rest + rest_regen_sleeping * delta, MAX)
	else:
		rest = maxf(rest - rest_rate * difficulty * delta, 0.0)

	_tick_temperature(delta, last_effective_temp)
	_tick_stamina(delta, sprinting)
	_tick_conditions(delta)
	_tick_health(delta, sleeping)


func _tick_temperature(delta: float, eff: float) -> void:
	var target := NORMAL_TEMP
	if eff < COMFORT_MIN:
		target = NORMAL_TEMP - (COMFORT_MIN - eff) * 0.22
	elif eff > COMFORT_MAX:
		target = NORMAL_TEMP + (eff - COMFORT_MAX) * 0.15
	var rate := 0.012 if target < body_temp else 0.03
	body_temp = move_toward(body_temp, target, rate * delta)

	if body_temp < HYPOTHERMIA_TEMP:
		add_condition(&"hypothermia")
	elif body_temp > HYPOTHERMIA_RECOVER and has_condition(&"hypothermia"):
		remove_condition(&"hypothermia")
	if body_temp > OVERHEAT_TEMP:
		add_condition(&"overheat")
	elif body_temp < OVERHEAT_TEMP - 0.4 and has_condition(&"overheat"):
		remove_condition(&"overheat")


func _tick_stamina(delta: float, sprinting: bool) -> void:
	if sprinting:
		stamina = maxf(stamina - sprint_cost * delta, 0.0)
		_stamina_delay = 1.0
	else:
		_stamina_delay -= delta
		if _stamina_delay <= 0.0:
			var regen := stamina_regen
			if hunger < 20.0 or has_condition(&"hypothermia"):
				regen *= 0.5
			stamina = minf(stamina + regen * delta, max_stamina())
	stamina = minf(stamina, max_stamina())


func _tick_conditions(delta: float) -> void:
	for id: StringName in conditions.keys():
		var t: float = conditions[id]
		if is_inf(t):
			continue
		t -= delta
		if t <= 0.0:
			remove_condition(id)
		else:
			conditions[id] = t


func _tick_health(delta: float, sleeping: bool) -> void:
	var dmg := 0.0
	var cause: StringName = &""
	if thirst <= 0.0:
		dmg += 0.55
		cause = &"dehydration"
	if hunger <= 0.0:
		dmg += 0.35
		if cause == &"":
			cause = &"starvation"
	if has_condition(&"hypothermia"):
		dmg += 0.4 * clampf(HYPOTHERMIA_TEMP - body_temp + 0.5, 0.5, 3.0)
		cause = &"hypothermia"
	if has_condition(&"bleeding"):
		dmg += 0.5
		cause = &"bleeding"
	if has_condition(&"food_poisoning"):
		dmg += 0.12
		if cause == &"":
			cause = &"food_poisoning"
	if dmg > 0.0:
		damage(dmg * delta, cause)
	elif hunger > 40.0 and thirst > 40.0:
		health = minf(health + (0.25 if sleeping else 0.12) * delta, MAX)


func to_dict() -> Dictionary:
	var conds := {}
	for id: StringName in conditions.keys():
		var t: float = conditions[id]
		conds[String(id)] = -1.0 if is_inf(t) else t
	return {
		"health": health, "stamina": stamina, "hunger": hunger, "thirst": thirst,
		"rest": rest, "body_temp": body_temp, "conditions": conds,
	}


func from_dict(d: Dictionary) -> void:
	health = float(d.get("health", MAX))
	stamina = float(d.get("stamina", MAX))
	hunger = float(d.get("hunger", MAX))
	thirst = float(d.get("thirst", MAX))
	rest = float(d.get("rest", MAX))
	body_temp = float(d.get("body_temp", NORMAL_TEMP))
	conditions.clear()
	var conds: Dictionary = d.get("conditions", {})
	for k: String in conds.keys():
		var t := float(conds[k])
		conditions[StringName(k)] = INF if t < 0.0 else t
	dead = health <= 0.0
