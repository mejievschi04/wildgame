class_name Wildlife
extends Node3D
## Population director (GDD §6 "spawn controlat, populații abstractizate"): keeps a few herds/packs
## alive out of the player's sight, despawns far-away animals, persists only carcasses.

const BALANCE_INTERVAL := 3.0
const DESPAWN_DISTANCE := 165.0
## Hard cap on live animals (performance: each carries a skinned body + fur cards). Species flagged
## "common" (the core hunting prey) are topped up first; the rest compete in random order.
const MAX_TOTAL := 24

var world: ForestWorld
var enabled := true
var _t := 0.0
var _seq := 0
var _rng := RandomNumberGenerator.new()


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


func balance() -> void:
	var p := world.player as Node3D
	if p == null:
		return
	for a in living():
		if a.global_position.distance_to(p.global_position) > DESPAWN_DISTANCE \
				and not a.state in [Animal.State.CHASE, Animal.State.ATTACK]:
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
	var total := living().size()
	for species: StringName in common + rest:
		var def := ItemDB.get_animal(species)
		var have := living(species).size()
		if have >= int(def.get("max", 4)) or total >= MAX_TOTAL:
			continue
		var group: Array = def.get("group", [1, 2])
		var n := mini(mini(_rng.randi_range(int(group[0]), int(group[1])), int(def.max) - have), MAX_TOTAL - total)
		total += maxi(n, 0)
		if n > 0:
			spawn_group(species, n, p.global_position)


func spawn_group(species: StringName, n: int, around: Vector3) -> Array[Animal]:
	var def := ItemDB.get_animal(species)
	var out: Array[Animal] = []
	for attempt in 24:
		var a := _rng.randf() * TAU
		var d := _rng.randf_range(float(def.get("spawn_min", 60)), float(def.get("spawn_max", 100)))
		var c := around + Vector3(cos(a), 0, sin(a)) * d
		if not _good_spot(c.x, c.z):
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
