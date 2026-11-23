class_name TribeGroup
extends RefCounted
## The people of one camp or base, working together: where they sleep, cook and store food, what the camp
## has gathered, who goes hunting today, and how fighters share a target (attack slots around it, one or two
## at a time, the rest circle and feint). Members are HumanNPC; the group never moves anyone itself.

const MAX_ATTACKERS := 2
const SLOT_RADIUS := 3.0

var id := ""
var faction: StringName
var home := Vector3.ZERO      # the fire
var storage := Vector3.ZERO   # store / drying rack
var beds: Array[Vector3] = []
var members: Array = []       # Array[HumanNPC]
var guards := false           # a regional garrison: they keep watch in shifts instead of all sleeping
var stock: Dictionary = {}    # item id -> count brought back to camp
var hunt_day := -1            # in-game day of the last hunting party
var hunters: Array = []       # members out hunting
var _tokens: Dictionary = {}  # foe instance id -> Array of attackers holding an attack token


func _init(p_id: String, p_faction: StringName, p_home: Vector3, p_storage: Vector3) -> void:
	id = p_id
	faction = p_faction
	home = p_home
	storage = p_storage


func living() -> Array:
	return members.filter(func(n: HumanNPC) -> bool: return is_instance_valid(n) and not n.is_dead())


## A sleeping spot by the fire for member i (people slept around the hearth).
func bed_for(n: HumanNPC) -> Vector3:
	var i := members.find(n)
	if i >= 0 and i < beds.size():
		return beds[i]
	var a := TAU * maxi(i, 0) / maxf(1.0, members.size()) + 0.4
	return home + Vector3(cos(a), 0.0, sin(a)) * 3.0


func deposit(item: StringName, count: int) -> void:
	if item == &"" or count <= 0:
		return
	stock[item] = int(stock.get(item, 0)) + count


## Night watch: in a garrison every other guard stays awake; in a camp the first armed member does.
func on_watch(n: HumanNPC) -> bool:
	var i := members.find(n)
	if guards:
		return i % 2 == 0
	for m: HumanNPC in living():
		if m.armed:
			return m == n
	return false


## Starts today's hunting party (two armed members) if none went out yet. Returns the chosen members.
func plan_hunt(day: int) -> Array:
	if hunt_day == day or guards:
		return []
	var armed := living().filter(func(n: HumanNPC) -> bool:
		return n.armed and n.is_idle_for_work())
	if armed.size() < 2:
		return []
	hunt_day = day
	hunters = armed.slice(0, 2)
	return hunters


func end_hunt(n: HumanNPC) -> void:
	hunters.erase(n)


# ---------------------------------------------------------------- fighting together

## Fighters sharing `foe`: each gets a slot around it, spread evenly from where they stand.
func slot_for(n: HumanNPC, foe: Node3D) -> Vector3:
	var fighters := fighters_on(foe)
	if fighters.size() <= 1:
		return foe.global_position + (n.global_position - foe.global_position).normalized() * SLOT_RADIUS
	fighters.sort_custom(func(a: HumanNPC, b: HumanNPC) -> bool: return a.npc_id < b.npc_id)
	var lead: HumanNPC = fighters[0]
	var base := lead.global_position - foe.global_position
	var a0 := atan2(base.x, base.z)
	var k := fighters.find(n)
	var spread := TAU / float(fighters.size())
	var a := a0 + spread * k
	return foe.global_position + Vector3(sin(a), 0.0, cos(a)) * SLOT_RADIUS


func fighters_on(foe: Node3D) -> Array:
	return living().filter(func(m: HumanNPC) -> bool: return m.state == HumanNPC.State.COMBAT and m.foe == foe)


## Only MAX_ATTACKERS close in at once; the rest hold their slot. Tokens are released after an attack.
func request_attack(n: HumanNPC, foe: Node3D) -> bool:
	var key := foe.get_instance_id()
	var holders: Array = (_tokens.get(key, []) as Array).filter(func(m: Variant) -> bool:
		return is_instance_valid(m) and m.state == HumanNPC.State.COMBAT and m.foe == foe and not m.is_dead())
	if n in holders:
		_tokens[key] = holders
		return true
	if holders.size() >= MAX_ATTACKERS:
		_tokens[key] = holders
		return false
	holders.append(n)
	_tokens[key] = holders
	return true


func release_attack(n: HumanNPC) -> void:
	for key in _tokens.keys():
		(_tokens[key] as Array).erase(n)


## Pull back when half of the fighters on this foe are badly hurt or dead.
func should_retreat(foe: Node3D) -> bool:
	var total := 0
	var hurt := 0
	for m: HumanNPC in members:
		if not is_instance_valid(m) or m.foe != foe:
			continue
		total += 1
		if m.is_dead() or m.health < m.max_health * 0.4:
			hurt += 1
	return total >= 2 and hurt * 2 >= total


## The closest living member needing care (bleeding or below 60 %) back at camp.
func wounded_near(pos: Vector3, radius: float) -> HumanNPC:
	var best: HumanNPC = null
	var best_d := radius
	for m: HumanNPC in living():
		if (m.health < m.max_health * 0.6 or m.bleeding > 0.0) and m.state in [HumanNPC.State.RECOVER, HumanNPC.State.SIT, HumanNPC.State.IDLE]:
			var d := m.global_position.distance_to(pos)
			if d < best_d and not m.being_tended:
				best = m
				best_d = d
	return best
