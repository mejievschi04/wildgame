class_name AnimalBehavior
extends RefCounted
## Species habits on top of the shared state machine (Animal) and its mind (AnimalMind). Switched on per species
## by data/animals.json "behavior": {...}; a species without one behaves exactly like the shared machine.
##
##   freeze: s        deer — on noticing something it freezes, head up, then bolts or goes back to grazing
##   zigzag: rad      deer — weaves while it flees
##   at_bay: true     giant deer — runs, but turns and fights when cornered or wounded with the hunter close
##   pack_select      wolves — pick the weakest prey (wounded, tired, alone); each takes its own flank
##   day_rest         cave lion — lies up through the day, hungry at dusk, hunts by night
##   crouch_stalk     cats — creep in slowly and freeze whenever the prey looks up
##   sprint_limit: s  cats — a short burst: if it doesn't connect, give up, winded
##   ambush           smilodon — waits motionless by water and pounces from very close, the first blow tears
##   drag: m          smilodon — hauls a kill into cover before it eats
##   forage           bear — roots for food when hungry and there is no carcass; stands up to sniff
##   mock_charges: n  bear, rhino, mammoth — bluff charges that stop short before a real one
##   blind_charge     rhino — poor eyes: charges at what it hears or smells
##   straight_charge: s  rhino — commits to a line, thunders past and has to stop and turn
##   trample: x       bison — a stampede tramples whoever is in its way (x × damage)
##   ring: m          mammoth — the matriarch faces the threat, the herd closes ranks around the weakest;
##                    if she is hurt they all charge

const S := Animal.State

var cfg: Dictionary = {}
var mock_left := 0
var charge_dir := Vector3.ZERO
var charge_t := 0.0
var trample_cd := 0.0
var ambush_spot := Vector3.INF
var drag_to := Vector3.INF
var dragged: Animal = null
var flank := 0.0
var phase := 0.0


func init(a: Animal) -> void:
	cfg = a.def.get("behavior", {})
	mock_left = int(cfg.get("mock_charges", 0))
	flank = a.rng.randf_range(0.5, 1.3) * (1.0 if a.rng.randf() < 0.5 else -1.0)
	phase = a.rng.randf() * TAU


func has(key: String) -> bool:
	return cfg.has(key)


# ---------------------------------------------------------------- thinking

## One think step before the shared machine. True: this species handled it.
func think(a: Animal, dt: float, p: Node3D, stim: float) -> bool:
	if a.fighting:
		if a.state in [S.RECOVER, S.GRAZE, S.IDLE, S.FLEE]:
			a.fighting = false
		else:
			a._think_defensive(dt, p, stim)
			return true
	if has("sprint_limit") and _sprint_spent(a):
		return true
	if has("mock_charges") and _mock_charge(a, p):
		return true
	if has("freeze") and _freeze(a, p):
		return true
	if has("at_bay") and _at_bay(a, p):
		return true
	if has("day_rest") and _day_rest(a):
		return true
	if has("forage") and _forage(a, dt):
		return true
	if has("ambush") and _ambush(a, p):
		return true
	if has("drag") and a.state == S.DRAG:
		if dragged == null or not is_instance_valid(dragged) or a._arrived(2.0) or a.state_time > 25.0:
			a._carcass = dragged
			a._set_state(S.FEED)
		return true
	if has("blind_charge") and _blind_charge(a, p):
		return true
	if has("straight_charge") and a.state == S.CHASE:
		charge_t += dt
		var target := a.threat.global_position if a.threat and is_instance_valid(a.threat) else a.last_known
		var past := (target - a.global_position).dot(charge_dir) < -2.0
		if charge_dir != Vector3.ZERO and (charge_t > float(cfg.straight_charge) or past):
			a.last_known = target
			a._set_state(S.ALERT)   # thundered past: stop, turn round, decide again
			return true
	if has("ring") and _ring(a):
		return true
	return false


func _sprint_spent(a: Animal) -> bool:
	if a.state not in [S.HUNT_PREY, S.CHASE] or a.state_time < float(cfg.sprint_limit):
		return false
	var t := a.threat
	if t and is_instance_valid(t) and t.global_position.distance_to(a.global_position) < float(a.def.attack_range) * 1.5:
		return false
	a.mind.fatigue = minf(a.mind.fatigue + 0.45, 1.0)
	a.calm_until = a._uptime + 40.0
	a._set_state(S.PATROL)
	return true


func _mock_charge(a: Animal, p: Node3D) -> bool:
	if a.state in [S.GRAZE, S.PATROL] and a.state_time < 0.2:
		mock_left = int(cfg.mock_charges)   # calm again: the next encounter starts with bluffs
	if a.state != S.CHASE or mock_left <= 0 or a.threat != p or p == null or a.mind.wants_revenge(a._uptime) \
			or a.health < a.max_health * 0.8:
		return false
	if p.global_position.distance_to(a.global_position) < float(cfg.get("mock_stop", 5.5)):
		mock_left -= 1
		a.voice(&"roar" if a.is_predator() else &"stamp", 1.0)
		a._set_state(S.THREAT)   # pulls up short and stands its ground
		return true
	return false


func _freeze(a: Animal, p: Node3D) -> bool:
	if a.state == S.ALERT and a.state_time < 0.15 and a.mind.fear < 0.7:
		a._set_state(S.FREEZE)
		return true
	if a.state != S.FREEZE:
		return false
	var src := a.threat if a.threat and is_instance_valid(a.threat) else p
	var d := src.global_position.distance_to(a.global_position) if src else INF
	if a._predator_near() or d < 9.0 + 8.0 * a.mind.fear or a.awareness > a.mind.alert_threshold(0.75, a._uptime):
		a.voice(&"alarm", 4.0)   # the snort, then it bolts
		a._alarm_herd(src)
		a._set_state(S.FLEE)
	elif a.state_time > float(cfg.freeze) and a.awareness < 0.45:
		a._set_state(S.GRAZE)
	return true


func _at_bay(a: Animal, p: Node3D) -> bool:
	if a.state != S.FLEE or p == null or a.threat != p:
		return false
	var d := p.global_position.distance_to(a.global_position)
	var cornered := d < 5.0 and (a.health < a.max_health * 0.6 or a.state_time > 4.0 or a.mind.fatigue > 0.7)
	if not cornered:
		return false
	a.fighting = true
	a.calm_until = 0.0
	a.voice(&"roar", 2.0)
	a._set_state(S.CHASE)   # turns, antlers down
	return true


func _day_rest(a: Animal) -> bool:
	var h := a.world.day_night.time_hours if a.world and a.world.day_night else 12.0
	if h > 17.0 and h < 21.0 and a.mind.hunger > 0.4:
		a.hungry = true   # dusk: the pride wakes up hungry
	var day := h > 6.5 and h < 17.0
	if a.state == S.REST:
		if not day or a.hungry or a.awareness > 0.45:
			a._set_state(S.PATROL)
		return true
	if day and not a.hungry and a.state in [S.PATROL, S.IDLE] and a.awareness < 0.3 and a.state_time > 2.0:
		a._set_state(S.REST)
		return true
	return false


func _forage(a: Animal, dt: float) -> bool:
	if a.state == S.FORAGE:
		a.mind.hunger = maxf(a.mind.hunger - dt / 40.0, 0.0)
		if a.awareness > 0.4:
			a._set_state(S.SUSPICIOUS)   # stands up to sniff the air
		elif a.state_time > 16.0 or a.mind.hunger < 0.15:
			a.hungry = a.mind.hunger > 0.65
			a._set_state(S.PATROL)
		return true
	if a.state == S.PATROL and a.hungry and a.state_time > 3.0 and a.rng.randf() < 0.04 \
			and a._find_carcass() == null:
		a._set_state(S.FORAGE)
		return true
	return false


func _ambush(a: Animal, p: Node3D) -> bool:
	if a.state in [S.PATROL, S.IDLE] and a.hungry and a.awareness < 0.3:
		var w := a._water_near()
		if w != Vector3.INF:
			var back := (a.global_position - w)
			back.y = 0.0
			ambush_spot = w + (back.normalized() if back.length() > 0.1 else Vector3.FORWARD) * 8.0
			a._goal = ambush_spot
			a._set_state(S.AMBUSH)
			return true
	if a.state != S.AMBUSH:
		return false
	var pounce := float(a.def.get("pounce", 8.0))
	var prey := a._find_prey()
	if prey and prey.global_position.distance_to(a.global_position) < pounce and prey.state not in [S.ALERT, S.FLEE, S.FREEZE]:
		a.attack_bonus = float(cfg.get("pounce_bonus", 1.5))
		a.threat = prey
		a._set_state(S.HUNT_PREY)
	elif p and p.global_position.distance_to(a.global_position) < pounce * 0.85 and a._wants_to_attack(p) \
			and not a._fire_near(p.global_position):
		a.attack_bonus = float(cfg.get("pounce_bonus", 1.5))   # the leap from cover: the first bite tears
		a.threat = p
		a._set_state(S.CHASE)
	elif a.state_time > 120.0 or not a.hungry:
		a._set_state(S.PATROL)
	return true


func _blind_charge(a: Animal, p: Node3D) -> bool:
	if a.state != S.ALERT or p == null or a._uptime < a.calm_until or a.awareness < 0.7:
		return false
	var d := a.last_known.distance_to(a.global_position)
	if d > float(a.def.get("charge_range", 8.0)) * 2.5 or a._fire_near(a.last_known):
		return false
	a.threat = p
	a._set_state(S.CHASE)   # can't see well: it charges the noise
	return true


func _ring(a: Animal) -> bool:
	var lead := a.leader()
	if lead == a:
		return false
	var danger := lead.state in [S.ALERT, S.THREAT, S.CHASE, S.ATTACK] and lead.threat and is_instance_valid(lead.threat)
	if a.state == S.RING and not danger:
		a._set_state(S.GRAZE)
		return true
	if not danger or a.state in [S.CHASE, S.ATTACK, S.FLEE]:
		return false
	var furious := lead.state in [S.CHASE, S.ATTACK] and (lead.health < lead.max_health * 0.7 or lead.mind.wants_revenge(lead._uptime))
	if furious and a.global_position.distance_to(lead.threat.global_position) < 40.0:
		a.threat = lead.threat
		a.calm_until = 0.0
		a._set_state(S.CHASE)   # the matriarch is hurt: the whole herd charges
		return true
	if a.state != S.RING:
		a.threat = lead.threat
		a._set_state(S.RING)
	return true


## Wolves: a wounded, tired or lone animal is the one to run down. Lower is better (metres, weighted).
func prey_score(a: Animal, prey: Animal, d: float) -> float:
	if not has("pack_select"):
		return d
	var weak := prey.health / maxf(prey.max_health, 1.0)
	var company := 0
	for m: Animal in prey._herd_members():
		if m != prey and m.global_position.distance_to(prey.global_position) < 12.0:
			company += 1
	return d * (0.35 + 0.65 * weak) * (1.0 - 0.4 * prey.mind.fatigue) * (1.0 + 0.15 * company)


# ---------------------------------------------------------------- moving

func desired(a: Animal, want: Dictionary) -> Dictionary:
	var dir: Vector3 = want.dir
	var speed: float = want.speed
	var walk := float(a.def.walk)
	match a.state:
		S.FREEZE:
			var look := a.threat.global_position if a.threat and is_instance_valid(a.threat) else a.last_known
			dir = look - a.global_position
			speed = 0.0
		S.FLEE:
			if has("zigzag") and dir != Vector3.ZERO:
				dir = dir.rotated(Vector3.UP, sin(a.state_time * 2.4 + phase) * float(cfg.zigzag))
		S.FORAGE:
			dir = -a.global_transform.basis.z.rotated(Vector3.UP, sin(a.state_time * 0.7 + phase) * 0.8)
			speed = walk * 0.25 if fmod(a.state_time, 5.0) < 1.5 else 0.0
		S.AMBUSH:
			if ambush_spot != Vector3.INF and not a._arrived(2.0):
				dir = ambush_spot - a.global_position
				speed = walk * 0.7
			else:
				speed = 0.0   # lying in wait
		S.DRAG:
			dir = drag_to - a.global_position
			speed = walk * 0.6
		S.RING:
			var spot := _ring_spot(a)
			var to := spot - a.global_position
			to.y = 0.0
			if to.length() > 2.0:
				dir = to
				speed = walk * 1.3
			else:
				dir = a.threat.global_position - a.global_position if a.threat and is_instance_valid(a.threat) else dir
				speed = 0.0
		S.CHASE:
			if has("straight_charge") and a.threat and is_instance_valid(a.threat):
				if charge_dir == Vector3.ZERO:
					charge_dir = a.threat.global_position - a.global_position
					charge_dir.y = 0.0
					charge_dir = charge_dir.normalized()
					charge_t = 0.0
				dir = charge_dir
				speed = float(a.def.run) * 1.05
		S.STALK:
			if has("crouch_stalk"):
				speed = walk * 0.5
				var prey := a.threat as Animal
				if prey and (prey._lookup_t > 0.0 or prey.state in [S.ALERT, S.FREEZE]):
					speed = 0.0   # freezes while the prey looks up
			elif has("pack_select") and a.leader() != a and dir != Vector3.ZERO:
				dir = (a.threat.global_position - a.global_position).rotated(Vector3.UP, flank) if a.threat else dir
	dir.y = 0.0
	return {"dir": dir.normalized() if dir.length() > 0.01 else Vector3.ZERO, "speed": speed}


## Where a herd member stands while the matriarch faces a threat: a line between the threat and the weakest of
## the herd, spread across.
func _ring_spot(a: Animal) -> Vector3:
	var members: Array = a._herd_members()
	members.append(a)
	var weakest: Animal = a
	for m: Animal in members:
		if m.health / m.max_health < weakest.health / weakest.max_health:
			weakest = m
	var centre := weakest.global_position if weakest.health < weakest.max_health * 0.8 else a.leader().global_position
	var t := a.threat.global_position if a.threat and is_instance_valid(a.threat) else a.last_known
	var face := t - centre
	face.y = 0.0
	face = face.normalized() if face.length() > 0.1 else Vector3.FORWARD
	var idx := members.find(a)
	var across := face.cross(Vector3.UP) * (float(idx) - float(members.size() - 1) * 0.5) * 4.0
	return centre + face * float(cfg.ring) + across


# ---------------------------------------------------------------- events

func on_state(a: Animal, s: int) -> void:
	if s != S.CHASE:
		charge_dir = Vector3.ZERO
	if s == S.FEED and has("drag") and a._carcass and is_instance_valid(a._carcass) and dragged != a._carcass:
		dragged = a._carcass
		var w := a._water_near()
		var away := a.global_position - (w if w != Vector3.INF else a.global_position + a.global_transform.basis.z)
		away.y = 0.0
		drag_to = a.global_position + (away.normalized() if away.length() > 0.1 else Vector3.FORWARD) * float(cfg.drag)
		a.state = S.DRAG   # haul it off first (keeps state_time at 0, no second event)


func physics(a: Animal, delta: float) -> void:
	trample_cd = maxf(trample_cd - delta, 0.0)
	if a.state == S.DRAG and dragged and is_instance_valid(dragged):
		var behind := a.global_position + a.global_transform.basis.z * (float(a.def.get("length", 1.5)) * 0.7 + 0.6)
		dragged.global_position = dragged.global_position.lerp(Vector3(behind.x, dragged.global_position.y, behind.z), 0.2)
	if has("trample") and a.state == S.FLEE and a._speed > float(a.def.walk) * 2.0 and trample_cd <= 0.0:
		var p := a._player()
		if p and p.has_method("take_hit"):
			var off := p.global_position - a.global_position
			off.y = 0.0
			var reach := float(a.def.get("radius", 0.5)) * 2.0 + 0.9
			if off.length() < reach and (-a.global_transform.basis.z).dot(off.normalized()) > 0.2:
				trample_cd = 1.2
				p.take_hit(float(a.def.damage) * float(cfg.trample), a.species, 0.0, a.global_position, a)


func animate(a: Animal) -> bool:
	match a.state:
		S.FREEZE:
			a._play("alert")
			return true
		S.FORAGE:
			if a._speed < 0.3:
				a._play("graze")
				return true
		S.AMBUSH, S.RING:
			if a._speed < 0.3:
				a._play("alert" if a.state == S.RING else "idle")
				if a.state == S.AMBUSH:
					a._anim.speed_scale = 0.4   # barely breathing
				return true
	return false
