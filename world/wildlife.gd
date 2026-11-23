class_name Wildlife
extends Node3D
## Ecology director (GDD §6 "spawn controlat, populații abstractizate"). Instead of topping every species up
## around the player every few seconds, each spawn has to pass a chain of rules:
##   1. Habitat   — a species only appears in the regions it lives in (`habitat` in animals.json).
##   2. Wildness  — dangerous species need distance from the Aruun start clearing (`min_wild`, metres), so the
##                  home valley is prey country and the big threats live out in the wild.
##   3. Safe camp — nothing dangerous spawns near the player's fires and buildings.
##   4. Budget    — at most PREDATOR_GROUPS (more at night) and DEFENSIVE_GROUPS dangerous groups at once.
##   5. Respawn   — a killed or departed group leaves its species "empty" for `respawn_h` in-game hours;
##                  dangerous groups are never topped up (kill 2 of 3 wolves and the third is the last).
##   6. Pacing    — dangerous groups arrive by chance (one per tick at most), never in the player's view.
## Persists carcasses plus the respawn timers.

const BALANCE_INTERVAL := 3.0
const DESPAWN_DISTANCE := 165.0
## Hard cap on live animals (performance: each carries a skinned body + fur cards). Species flagged
## "common" (the core hunting prey) are topped up first; the rest compete in random order.
const MAX_TOTAL := 24
const PREDATOR_GROUPS_DAY := 1
const PREDATOR_GROUPS_NIGHT := 2
const DEFENSIVE_GROUPS := 2
## Chance per balance tick that an eligible dangerous group actually shows up (~40 s on average).
const DANGER_CHANCE := 0.075
const NIGHT_PREDATOR_CHANCE_MULT := 2.0
## No predator / defensive spawns this close to a player fire or building.
const CAMP_SAFE_RADIUS := 90.0
## A species whose group merely wandered off (despawned) comes back sooner than one that was killed.
const DESPAWN_RESPAWN_FRACTION := 0.25
## Spawns are pushed out of the camera's view cone (half-angle, degrees).
const VIEW_HALF_ANGLE := 60.0

var world: ForestWorld
var enabled := true
var _t := 0.0
var _seq := 0
var _rng := RandomNumberGenerator.new()
var _next_ok: Dictionary = {}  # species -> in-game hour (absolute) before which it can't spawn again


func _ready() -> void:
	_rng.seed = ForestWorld.SEED + 999


func _process(delta: float) -> void:
	if world == null or world.menu_mode or not enabled:
		return
	_t += delta
	if _t >= BALANCE_INTERVAL:
		_t = 0.0
		balance()


func living(species: StringName = &"") -> Array[Animal]:
	var out: Array[Animal] = []
	for a: Animal in get_tree().get_nodes_in_group("animal"):
		if not a.is_dead() and not a.is_queued_for_deletion() and (species == &"" or a.species == species):
			out.append(a)
	return out


## Absolute in-game clock in hours (day 1 00:00 = 24). Sleeping advances it, so it also clears cooldowns.
func clock_hours() -> float:
	if world == null or world.day_night == null:
		return 0.0
	return world.day_night.day * 24.0 + world.day_night.time_hours


static func is_dangerous(def: Dictionary) -> bool:
	return str(def.get("diet", "prey")) != "prey"


func can_respawn(species: StringName) -> bool:
	return clock_hours() >= float(_next_ok.get(species, -INF))


func _set_cooldown(species: StringName, hours: float) -> void:
	_next_ok[species] = maxf(float(_next_ok.get(species, -INF)), clock_hours() + hours)


func balance() -> void:
	var p := world.player as Node3D
	if p == null:
		return
	for a in living():
		if a.global_position.distance_to(p.global_position) > DESPAWN_DISTANCE \
				and not a.state in [Animal.State.CHASE, Animal.State.ATTACK]:
			var def := ItemDB.get_animal(a.species)
			if is_dangerous(def) and living(a.species).size() <= 1:
				_set_cooldown(a.species, float(def.get("respawn_h", 4)) * DESPAWN_RESPAWN_FRACTION)
			a.queue_free()
	var common: Array[StringName] = []
	var rest: Array[StringName] = []
	for species: StringName in ItemDB.animals.keys():
		(common if bool(ItemDB.get_animal(species).get("common", false)) else rest).append(species)
	for i in range(rest.size() - 1, 0, -1):  # deterministic shuffle (seeded rng)
		var j := _rng.randi_range(0, i)
		var tmp := rest[i]
		rest[i] = rest[j]
		rest[j] = tmp
	var night: bool = world.day_night.is_night() if world.day_night else false
	var budget := {
		"predator": (PREDATOR_GROUPS_NIGHT if night else PREDATOR_GROUPS_DAY) - _active_groups("predator"),
		"defensive": DEFENSIVE_GROUPS - _active_groups("defensive"),
	}
	var camp := _camp_points()
	var danger_spawned := false
	var total := living().size()
	for species: StringName in common + rest:
		if total >= MAX_TOTAL:
			break
		var def := ItemDB.get_animal(species)
		if not can_respawn(species):
			continue
		var have := living(species).size()
		var diet := str(def.get("diet", "prey"))
		var dangerous := is_dangerous(def)
		if dangerous:
			# One group per species, never topped up; budgeted, paced and rolled by chance.
			if have > 0 or danger_spawned or int(budget[diet]) <= 0:
				continue
			var chance := DANGER_CHANCE * (NIGHT_PREDATOR_CHANCE_MULT if night and diet == "predator" else 1.0)
			if _rng.randf() > chance:
				continue
		elif have >= int(def.get("max", 4)):
			continue
		var group: Array = def.get("group", [1, 2])
		var n := _rng.randi_range(int(group[0]), int(group[1]))
		if not dangerous:
			n = mini(n, int(def.get("max", 4)) - have)
		n = mini(n, MAX_TOTAL - total)
		if n <= 0:
			continue
		var spawned := spawn_group(species, n, p.global_position, camp)
		total += spawned.size()
		if dangerous and not spawned.is_empty():
			danger_spawned = true
			budget[diet] = int(budget[diet]) - 1


func _active_groups(diet: String) -> int:
	var seen: Dictionary = {}
	for a in living():
		if str(a.def.get("diet", "prey")) == diet:
			seen[a.species] = true
	return seen.size()


## Player-made fires and buildings: dangerous animals keep away from these when spawning.
func _camp_points() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for s: Node3D in get_tree().get_nodes_in_group("structure"):
		if s.is_queued_for_deletion():
			continue
		var close := false
		for q in out:  # thin out wall pieces: one point per ~20 m is plenty
			if q.distance_to(s.global_position) < 20.0:
				close = true
				break
		if not close:
			out.append(s.global_position)
	return out


func spawn_group(species: StringName, n: int, around: Vector3, camp: Array[Vector3] = []) -> Array[Animal]:
	var def := ItemDB.get_animal(species)
	var out: Array[Animal] = []
	var dangerous := is_dangerous(def)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	for attempt in 24:
		var a := _rng.randf() * TAU
		var d := _rng.randf_range(float(def.get("spawn_min", 60)), float(def.get("spawn_max", 100)))
		var c := around + Vector3(cos(a), 0, sin(a)) * d
		if not _good_spot(c.x, c.z) or not habitat_ok(species, c.x, c.z):
			continue
		if dangerous and _near_camp(c, camp):
			continue
		if attempt < 16 and cam and _in_view(cam, c):
			continue
		for i in n:
			var off := Vector3(_rng.randf_range(-5, 5), 0, _rng.randf_range(-5, 5))
			var pos := c + off
			if not _good_spot(pos.x, pos.z):
				pos = c
			out.append(spawn(species, world.ground_point(pos.x, pos.z) + Vector3.UP * 0.3))
		break
	for m in out:
		m.herd = out.duplicate()
	return out


## Region whitelist + minimum distance from the start clearing ("how wild is this place").
func habitat_ok(species: StringName, x: float, z: float) -> bool:
	var def := ItemDB.get_animal(species)
	if Vector2(x, z).distance_to(ForestWorld.SPAWN) < float(def.get("min_wild", 0.0)):
		return false
	# climate bands come first: only jungle animals in the jungle, only cold-hardy ones on the tundra
	if ForestWorld.jungle_at(x, z) > 0.5:
		return bool(def.get("jungle", false))
	if ForestWorld.tundra_at(x, z) > 0.5:
		return bool(def.get("tundra", false))
	var hab: Array = def.get("habitat", [])
	return hab.is_empty() or hab.has(String(world.region_at(x, z)))


func _near_camp(pos: Vector3, camp: Array[Vector3]) -> bool:
	for q in camp:
		if Vector2(q.x, q.z).distance_to(Vector2(pos.x, pos.z)) < CAMP_SAFE_RADIUS:
			return true
	return false


func _in_view(cam: Camera3D, pos: Vector3) -> bool:
	var fwd := -cam.global_transform.basis.z
	var to := pos - cam.global_position
	var f2 := Vector2(fwd.x, fwd.z)
	var t2 := Vector2(to.x, to.z)
	if f2.length_squared() < 1e-4 or t2.length_squared() < 1e-4:
		return false
	return rad_to_deg(absf(f2.angle_to(t2))) < VIEW_HALF_ANGLE


func spawn(species: StringName, pos: Vector3, id: String = "") -> Animal:
	_seq += 1
	var a := Animal.new()
	a.setup(species, world, pos, ForestWorld.SEED + _seq * 7919, id)
	a.rotation.y = _rng.randf() * TAU
	add_child(a)
	a.died.connect(_on_died)
	return a


func _good_spot(x: float, z: float) -> bool:
	return absf(x) < ForestWorld.PLAYABLE - 6.0 and absf(z) < ForestWorld.PLAYABLE - 6.0 \
		and world.height_at(x, z) > 0.6 and world.normal_at(x, z).y > 0.85


func _on_died(a: Animal) -> void:
	# A kill empties the species locally for a while; dangerous ones stay gone for good until then.
	_set_cooldown(a.species, float(a.def.get("respawn_h", 4)))
	if a.killed_by == &"player" and a.species == &"wolf":
		world.add_journal("JOURNAL_WOLF")


## Strongest awareness any animal has of the player: {value, hostile}.
func max_awareness() -> Dictionary:
	var v := 0.0
	var hostile := false
	for a in living():
		if a.awareness > v:
			v = a.awareness
		if a.is_hostile() and a.threat == world.player:
			hostile = true
	return {"value": v, "hostile": hostile}


func save_state() -> Array:
	var out: Array = []
	for a: Animal in get_tree().get_nodes_in_group("carcass"):
		if a.is_dead() and not a.butchered and not a.is_queued_for_deletion():
			out.append(a.save_state())
	return out


func load_state(arr: Array) -> void:
	for a: Animal in get_tree().get_nodes_in_group("animal"):
		a.queue_free()
	for d: Dictionary in arr:
		var p: Array = d.get("pos", [0, 0, 0])
		var a := spawn(StringName(str(d.species)), Vector3(float(p[0]), float(p[1]), float(p[2])), str(d.get("id", "")))
		a.rotation.y = float(d.get("yaw", 0.0))
		a.killed_by = StringName(str(d.get("killed_by", "")))
		a.die(a.killed_by)


## Respawn timers: {species: absolute in-game hour}.
func save_director() -> Dictionary:
	var out := {}
	for k: StringName in _next_ok:
		out[String(k)] = _next_ok[k]
	return out


func load_director(d: Dictionary) -> void:
	_next_ok.clear()
	for k: String in d:
		_next_ok[StringName(k)] = float(d[k])
