class_name Camps
extends Node3D
## Builds faction camps and regional bases. Regional guards are active only near the player.

const REGIONAL_BASES := {
	"ossara": {"camp": [112, 1280], "level": 1, "wall_radius": 0.0, "supplies": {"meat_dried": 2, "flint": 2}},
	"meyra": {"camp": [1032, 606], "level": 2, "wall_radius": 8.0, "supplies": {"meat_dried": 2, "rope": 2, "bandage": 1}},
	"tavren": {"camp": [-912, -1152], "level": 3, "wall_radius": 10.0, "supplies": {"meat_dried": 3, "arrow": 6, "bandage": 1}},
	"kharum": {"camp": [-1260, 100], "level": 4, "wall_radius": 12.0, "supplies": {"flint": 6, "arrow": 8, "bandage": 2}},
	"varkai": {"camp": [1170, -1220], "level": 5, "wall_radius": 15.0, "supplies": {"hide": 4, "arrow": 12, "bandage": 3}},
}
const GUARD_LOAD_RADIUS := 145.0
const GUARD_UNLOAD_RADIUS := 210.0

var world: ForestWorld
var factions: Factions
var npcs: Dictionary = {}  # id -> HumanNPC
var _regional_guards: Dictionary = {}  # base id -> Array[HumanNPC]
var _regional_states: Dictionary = {}  # guard id -> saved health/death while inactive
var _stream_t := 0.0


static func site(faction_def: Dictionary) -> Vector2:
	var c: Array = faction_def.get("camp", [0, 0])
	return Vector2(float(c[0]), float(c[1]))


func build_structures() -> void:
	for f: StringName in factions.defs.keys():
		var d: Dictionary = factions.defs[f]
		var c := site(d)
		var center := world.ground_point(c.x, c.y)
		world.spawn_structure(&"campfire", Transform3D(Basis(), center),
			{"fuel": Campfire.MAX_FUEL, "lit": true, "eternal": true}, "camp_%s_fire" % f)
		for i in 2:
			var a := 0.7 + i * 2.2
			var pos := center + Vector3(cos(a), 0, sin(a)) * 4.8
			var yaw := atan2(pos.x - center.x, pos.z - center.z)
			world.spawn_structure(&"piece", Transform3D(Basis(Vector3.UP, yaw), world.ground_point(pos.x, pos.z)),
				{"piece": "lean_to", "built": true}, "camp_%s_shelter%d" % [f, i])
		var extra := "drying_rack" if f == &"hunters" else "storage"
		var ep := center + Vector3(-3.5, 0, 2.5)
		world.spawn_structure(&"piece", Transform3D(Basis(Vector3.UP, 0.4), world.ground_point(ep.x, ep.z)),
			{"piece": extra, "built": true}, "camp_%s_%s" % [f, extra])
		if float(d.get("territory", 0)) > 0.0:
			_palisade(f, center, 11.0)
	build_regional_bases()


func build_regional_bases(provisioned: Array = []) -> void:
	for id: String in REGIONAL_BASES:
		var prefix := "base_%s_" % id
		if provisioned.has(id) or world.structures_root.has_node(prefix + "fire"):
			continue
		var d: Dictionary = REGIONAL_BASES[id]
		var c := site(d)
		var center := world.ground_point(c.x, c.y)
		var level := int(d.level)
		world.spawn_structure(&"campfire", Transform3D(Basis(), center),
			{"fuel": Campfire.MAX_FUEL, "lit": true, "eternal": true}, prefix + "fire")
		for i in (3 if level >= 4 else 2):
			var a := 0.85 + 2.1 * i
			var r := 8.5 if level >= 4 else 5.5
			var pos := center + Vector3(cos(a), 0, sin(a)) * r
			var yaw := atan2(center.x - pos.x, center.z - pos.z)
			world.spawn_structure(&"piece", Transform3D(Basis(Vector3.UP, yaw), world.ground_point(pos.x, pos.z)),
				{"piece": "lean_to", "built": true}, prefix + "shelter%d" % i)
		var stores := world.ground_point(c.x - 3.5, c.y + 2.5)
		var cache := world.spawn_structure(&"piece", Transform3D(Basis(), stores),
			{"piece": "storage", "built": true}, prefix + "cache") as BuildingPiece
		for item: String in d.supplies:
			cache.storage.add_item(StringName(item), int(d.supplies[item]))
		if level >= 2:
			_regional_walls(prefix, c, float(d.wall_radius), level)


func _regional_walls(prefix: String, center: Vector2, radius: float, level: int) -> void:
	var sections := ceili(TAU * radius / 1.95)
	var wall := "palisade" if level >= 4 else "fence"
	for i in sections:
		# East entrance. The lower tiers have a second entrance or broken stretches.
		if i in [0, 1, sections - 1]:
			continue
		if level < 5 and abs(i - sections / 2.0) < (2.5 if level < 4 else 1.5):
			continue
		if level == 2 and i % 6 >= 3:
			continue
		var a := TAU * i / float(sections)
		var pos := center + Vector2(cos(a), sin(a)) * radius
		var xf := Transform3D(Basis(Vector3.UP, -a + PI * 0.5), world.ground_point(pos.x, pos.y))
		world.spawn_structure(&"piece", xf, {"piece": wall, "built": true}, prefix + "wall%d" % i)


func _palisade(f: StringName, center: Vector3, radius: float) -> void:
	var n := 30
	for i in n:
		if i in [0, 1]:  # gate
			continue
		var a := TAU * i / n
		var pos := center + Vector3(cos(a), 0, sin(a)) * radius
		var yaw := -a
		world.spawn_structure(&"piece", Transform3D(Basis(Vector3.UP, yaw), world.ground_point(pos.x, pos.z)),
			{"piece": "fence", "built": true}, "camp_%s_fence%d" % [f, i])


func spawn_people() -> void:
	for f: StringName in factions.defs.keys():
		var d: Dictionary = factions.defs[f]
		var c := site(d)
		var center := world.ground_point(c.x, c.y)
		var variants: Array = d.get("variants", ["M1"])
		for i in int(d.get("count", 2)):
			var a := TAU * i / float(d.count) + 0.3
			var pp := center + Vector3(cos(a), 0, sin(a)) * 2.4
			var npc := HumanNPC.new()
			var id := "npc_%s_%d" % [f, i]
			npc.setup(id, f, str(variants[i % variants.size()]), factions, world, center,
				world.ground_point(pp.x, pp.z) + Vector3.UP * 0.1, hash(id))
			add_child(npc)
			npc.rotation.y = atan2(center.x - pp.x, center.z - pp.z)
			npcs[id] = npc


func _process(delta: float) -> void:
	if not is_instance_valid(world.player):
		return
	_stream_t -= delta
	if _stream_t <= 0.0:
		_stream_t = 0.4
		_stream_regional_guards((world.player as Node3D).global_position)


func _stream_regional_guards(at: Vector3) -> void:
	for id: String in REGIONAL_BASES:
		var d: Dictionary = REGIONAL_BASES[id]
		var c := site(d)
		var distance := c.distance_to(Vector2(at.x, at.z))
		if _regional_guards.has(id):
			if distance > GUARD_UNLOAD_RADIUS:
				for n: HumanNPC in _regional_guards[id]:
					_regional_states[n.npc_id] = n.save_state()
					npcs.erase(n.npc_id)
					remove_child(n)
					n.queue_free()
				_regional_guards.erase(id)
		elif distance < GUARD_LOAD_RADIUS:
			_spawn_regional_guards(id, c, int(d.level), float(d.wall_radius))


func _spawn_regional_guards(base_id: String, c: Vector2, level: int, wall_radius: float) -> void:
	var guards: Array[HumanNPC] = []
	var center := world.ground_point(c.x, c.y)
	var variants: Array = factions.def_of(&"clan").variants
	for i in level + 1:
		var a := 0.3 + TAU * i / float(level + 1)
		var pos := c + Vector2(cos(a), sin(a)) * (3.5 if level < 4 else 5.5)
		var id := "npc_base_%s_%d" % [base_id, i]
		var n := HumanNPC.new()
		n.setup(id, &"clan", str(variants[i % variants.size()]), factions, world, center,
			world.ground_point(pos.x, pos.y) + Vector3.UP * 0.1, hash(id))
		n.territory_radius = maxf(20.0, wall_radius + 12.0)
		n.warn_time = 12.0 - level * 2.0
		add_child(n)
		n.rotation.y = atan2(c.x - pos.x, c.y - pos.y)
		if _regional_states.has(id):
			n.load_state(_regional_states[id])
			_regional_states.erase(id)
		guards.append(n)
		npcs[id] = n
	_regional_guards[base_id] = guards


func save_state() -> Dictionary:
	var out := _regional_states.duplicate()
	for id: String in npcs.keys():
		var n: HumanNPC = npcs[id]
		if is_instance_valid(n):
			out[id] = n.save_state()
	return out


func load_state(d: Dictionary) -> void:
	_regional_states.clear()
	for id: String in d.keys():
		if npcs.has(id) and is_instance_valid(npcs[id]):
			(npcs[id] as HumanNPC).load_state(d[id])
		elif id.begins_with("npc_base_"):
			_regional_states[id] = d[id]
