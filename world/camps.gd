class_name Camps
extends Node3D
## Builds the three faction camps (fire that never dies, shelters, racks, the clan's palisade)
## and their people. Camp structures are regular structures (saved with the world);
## NPC health/death is saved here.

var world: ForestWorld
var factions: Factions
var npcs: Dictionary = {}  # id -> HumanNPC


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


func save_state() -> Dictionary:
	var out := {}
	for id: String in npcs.keys():
		var n: HumanNPC = npcs[id]
		if is_instance_valid(n):
			out[id] = n.save_state()
	return out


func load_state(d: Dictionary) -> void:
	for id: String in d.keys():
		if npcs.has(id) and is_instance_valid(npcs[id]):
			(npcs[id] as HumanNPC).load_state(d[id])
