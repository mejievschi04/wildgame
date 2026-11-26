class_name Camps
extends Node3D
## Builds small field camps and the six clan settlements. City populations stream near the player.

const Layout := preload("res://world/settlement_layout.gd")
const Geography := preload("res://world/world_layout.gd")

static var REGIONAL_BASES := {
	"kharum": {"camp": Geography.data.stone, "level": 3, "wall_radius": 10.0,
		"supplies": {"flint": 6, "arrow": 8, "bandage": 1}},
	"north": {"camp": Geography.data.north, "level": 4, "wall_radius": 8.0,
		"supplies": {"hide": 4, "meat_dried": 3, "bandage": 2}},
	"varkai": {"camp": Geography.data.red, "level": 5, "wall_radius": 15.0,
		"supplies": {"hide": 4, "arrow": 12, "bandage": 3}},
	"aruun": {"camp": Geography.data.aruun, "level": 5, "wall_radius": 0.0,
		"supplies": {"hide": 3, "flint": 6, "bandage": 2}},
}
const GUARD_LOAD_RADIUS := 145.0
const GUARD_UNLOAD_RADIUS := 210.0

var world: ForestWorld
var factions: Factions
var npcs: Dictionary = {}  # id -> HumanNPC
var groups: Dictionary = {}  # group id -> TribeGroup (one per camp / active base)
var _regional_guards: Dictionary = {}  # base id -> Array[HumanNPC]
var _regional_states: Dictionary = {}  # guard id -> saved health/death while inactive
var _stream_t := 0.0
var _city_posts: Dictionary = {}


static func site(faction_def: Dictionary) -> Vector2:
	var c: Array = faction_def.get("camp", [0, 0])
	return Vector2(float(c[0]), float(c[1]))


func build_structures() -> void:
	for f: StringName in factions.defs.keys():
		var d: Dictionary = factions.defs[f]
		if not d.has("camp"):
			continue
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
	for id: String in REGIONAL_BASES:
		var def: Dictionary = REGIONAL_BASES[id]
		var city := Node3D.new()
		city.name = id.capitalize()
		add_child(city)
		_city_posts[id] = Layout.build(world, city, id, site(def), float(def.wall_radius))
	build_city_services()
	build_player_camp()


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
		if float(d.wall_radius) > 0.0:
			_regional_walls(prefix, c, float(d.wall_radius), level)


func build_player_camp() -> void:
	var center := ForestWorld.SPAWN
	var fire_at := world.ground_point(center.x - 1.5, center.y + 4.0)
	world.spawn_structure(&"campfire", Transform3D(Basis(), fire_at),
		{"fuel": 250.0, "lit": true}, "player_camp_fire")
	var cover := world.ground_point(center.x - 5.0, center.y + 3.8)
	world.spawn_structure(&"piece", Transform3D(Basis(Vector3.UP, PI * 0.5), cover),
		{"piece": "lean_to", "built": true}, "player_camp_shelter")
	var bed := world.ground_point(center.x - 5.0, center.y + 3.8)
	world.spawn_structure(&"bed", Transform3D(Basis(Vector3.UP, PI * 0.5), bed), {}, "player_camp_bed")
	var marker := Node3D.new()
	marker.name = "PlayerCampMarker"
	add_child(marker)
	var hall_at := center + Vector2(10.0, 8.0)
	Layout.place_shelter(world, marker, hall_at, center, Vector2(8.8, 11.8), "player", "CoastalHall")
	Layout.place_shelter(world, marker, center + Vector2(12.0, 19.0), hall_at, Vector2(5.2, 6.4),
		"player", "FamilyShelter")
	Layout.Detail.tower(world, marker, center + Vector2(16.0, -7.0), "player", center)
	Layout.Detail.canopy(world, marker, center + Vector2(6.7, -8.6), "player", -PI * 0.35)
	Layout.banner(world, marker, center + Vector2(5.0, 6.0), "player", PI * 0.8)


func build_city_services(provisioned: Array = []) -> void:
	for id: String in REGIONAL_BASES:
		if provisioned.has(id):
			continue
		var def: Dictionary = REGIONAL_BASES[id]
		var center := site(def)
		for row: Array in Layout.PLANS[id].districts:
			var role: String = row[2]
			if role not in ["workshops", "stores"]:
				continue
			var offset: Vector2 = row[1]
			var axis := offset.normalized()
			var side := Vector2(-axis.y, axis.x)
			var yard := center + offset + axis * 2.0
			var end := yard + side * 3.3
			var cache := world.spawn_structure(&"piece",
				Transform3D(Basis(), world.ground_point(end.x, end.y)),
				{"piece": "storage", "built": true}, "city_%s_%s_store" % [id, row[0]]) as BuildingPiece
			for item: String in def.supplies:
				cache.storage.add_item(StringName(item), maxi(1, floori(float(def.supplies[item]) * 0.5)))
			var p := yard - side * 3.3
			world.spawn_structure(&"piece", Transform3D(Basis(), world.ground_point(p.x, p.y)),
				{"piece": "drying_rack", "built": true}, "city_%s_%s_rack" % [id, row[0]])


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
		if not d.has("camp"):
			continue
		var c := site(d)
		var center := world.ground_point(c.x, c.y)
		var variants: Array = d.get("variants", ["M1"])
		var g := _make_group("camp_%s" % f, f, c, int(d.get("count", 2)))
		for i in int(d.get("count", 2)):
			var a := TAU * i / float(d.count) + 0.3
			var pp := center + Vector3(cos(a), 0, sin(a)) * 2.4
			var npc := HumanNPC.new()
			var id := "npc_%s_%d" % [f, i]
			npc.setup(id, f, str(variants[i % variants.size()]), factions, world, center,
				world.ground_point(pp.x, pp.z) + Vector3.UP * 0.1, hash(id))
			npc.group = g
			g.members.append(npc)
			add_child(npc)
			npc.rotation.y = atan2(center.x - pp.x, center.z - pp.z)
			npcs[id] = npc
	_bake_camps.call_deferred()


## A camp's shared places: the fire, the store (approached from the fire side) and sleeping spots around
## the hearth, clear of the shelters and the store.
func _make_group(id: String, f: StringName, c: Vector2, count: int) -> TribeGroup:
	var center := world.ground_point(c.x, c.y)
	var store := world.ground_point(c.x - 3.5, c.y + 2.5)
	var g := TribeGroup.new(id, f, center, store.lerp(center, 0.4))
	for i in count:
		var a := 1.8 + TAU * i / float(maxi(count, 1)) * 0.8
		var p := center + Vector3(cos(a), 0, sin(a)) * 2.7
		g.beds.append(world.ground_point(p.x, p.z))
	groups[id] = g
	return g


func _bake_camps() -> void:
	if world.npc_nav == null or not is_inside_tree():
		return
	for i in 2:  # new colliders reach the physics space on the next step
		await get_tree().physics_frame
	for f: StringName in factions.defs.keys():
		var def: Dictionary = factions.defs[f]
		if not def.has("camp"):
			continue
		var c := site(def)
		world.npc_nav.add_site("camp_%s" % f, world.ground_point(c.x, c.y), 30.0)


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
				groups.erase("base_%s" % id)
				groups.erase("residents_%s" % id)
				if world.npc_nav:
					world.npc_nav.remove_site("base_%s" % id)
		elif distance < GUARD_LOAD_RADIUS:
			_spawn_regional_guards(id, c, int(d.level))


func _spawn_regional_guards(base_id: String, c: Vector2, level: int) -> void:
	var guards: Array[HumanNPC] = []
	var center := world.ground_point(c.x, c.y)
	var faction := &"varkai" if base_id == "aruun" else StringName(base_id)
	var variants: Array = factions.def_of(faction).variants
	var patrols: Array[Vector2] = _city_posts[base_id]
	var guard_count := level + 1 + patrols.size()
	var workers := 0 if base_id == "aruun" else patrols.size()
	var radius := Layout.radius(base_id)
	var g := _make_group("base_%s" % base_id, faction, c, level + 1)
	g.guards = true
	var resident_group: TribeGroup
	if workers > 0:
		resident_group = _make_group("residents_%s" % base_id, faction, c, workers)
	for i in guard_count + workers:
		var a := 0.3 + TAU * i / float(level + 1)
		var pos := c + Vector2(cos(a), sin(a)) * (3.5 if level < 4 else 5.5)
		if i >= level + 1:
			var post_index := (i - level - 1) % patrols.size()
			pos = patrols[post_index] + (Vector2(1.75, 0.5) if i >= guard_count else Vector2.ZERO)
		var id := "npc_base_%s_%d" % [base_id, i]
		var n := HumanNPC.new()
		var post := world.ground_point(pos.x, pos.y)
		var home := center if i < guard_count else post
		n.setup(id, faction, str(variants[i % variants.size()]), factions, world, home,
			post + Vector3.UP * 0.1, hash(id))
		n.territory_radius = radius if i < guard_count else 18.0
		n.warn_time = 12.0 - level * 2.0
		n.group = g if i < guard_count else resident_group
		n.group.members.append(n)
		if i >= guard_count:
			n.armed = false
			n.spears = 0
		add_child(n)
		n.rotation.y = atan2(c.x - pos.x, c.y - pos.y)
		if _regional_states.has(id):
			n.load_state(_regional_states[id])
			_regional_states.erase(id)
		guards.append(n)
		npcs[id] = n
	_regional_guards[base_id] = guards
	if world.npc_nav:
		world.npc_nav.add_site("base_%s" % base_id, center, radius + 9.0)


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
