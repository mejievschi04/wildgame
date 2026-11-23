class_name Vegetation
extends Node3D
## Streamed harvestable trees and gather piles, with batched grass, ferns and shrubs.

const CHUNK := 48.0
const LOAD_RADIUS := 2  # real (fellable) trees within ~100–170 m; FarForest impostors take over beyond
const GRASS_DENSITY := 0.9  # candidates per m²
const GRASS_RANGE := 42.0
const FERN_DENSITY := 0.16
const FERN_RANGE := 75.0
const ROCK_RANGE := 160.0
const TREE_SCALE := 1.2  # wilderness trees grow a little taller than the starter valley's…


## …except in regions that are already dense (Tavren's tall spruce): bigger crowns there cost a lot of fill-rate.
static func tree_scale(density: float) -> float:
	return lerpf(TREE_SCALE, 1.0, smoothstep(0.006, 0.01, density))

var world: ForestWorld
var _rng := RandomNumberGenerator.new()
var _grass_meshes: Array[Mesh] = []
var _fern_meshes: Array[Mesh] = []
var _ground_prop_meshes: Array[Mesh] = []
var _rock_meshes: Array[Mesh] = []
var _log_mesh: Mesh
var _log_box := AABB()
var _active: Dictionary = {}
var _last_center := Vector2i(2147483647, 2147483647)
var _queue: Array = []  # Vector2i chunk keys waiting to be built (nearest first)


func build(w: ForestWorld, forest_mask: Image) -> void:
	world = w
	_rng.seed = ForestWorld.SEED + 77
	for path: String in AssetLib.PLANTS[&"grass"]:
		_grass_meshes.append(AssetLib.mesh(path))
	for path: String in AssetLib.PLANTS[&"fern"]:
		_fern_meshes.append(AssetLib.mesh(path))
	for path: String in AssetLib.PLANTS[&"shrub"]:
		_ground_prop_meshes.append(AssetLib.mesh(path))
	_stream_near(ForestWorld.SPAWN)
	_scatter_decor(forest_mask)


func _process(_delta: float) -> void:
	if not is_instance_valid(world) or not is_instance_valid(world.player):
		return
	_stream_near(Vector2(world.player.global_position.x, world.player.global_position.z), false)
	# Build queued chunks one per frame, nearest first: walking into new ground never builds a whole ring of
	# chunks (hundreds of trees) in one frame.
	if not _queue.is_empty():
		var key: Vector2i = _queue.pop_front()
		if not _active.has(key):
			_add_chunk(key, Vector2(key.x * CHUNK, key.y * CHUNK))


## immediate = build every missing chunk now (start-up, teleports, tests); otherwise queue them for _process.
func _stream_near(pos: Vector2, immediate := true) -> void:
	var center := Vector2i(floori(pos.x / CHUNK), floori(pos.y / CHUNK))
	if center == _last_center:
		return
	_last_center = center
	var wanted := {}
	for dz in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
		for dx in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
			var key := center + Vector2i(dx, dz)
			var origin := Vector2(key.x * CHUNK, key.y * CHUNK)
			if origin.x >= ForestWorld.PLAYABLE or origin.x + CHUNK <= -ForestWorld.PLAYABLE \
					or origin.y >= ForestWorld.PLAYABLE or origin.y + CHUNK <= -ForestWorld.PLAYABLE:
				continue
			wanted[key] = true
			if not _active.has(key):
				if immediate:
					_add_chunk(key, origin)
				elif not _queue.has(key):
					_queue.append(key)
	_queue = _queue.filter(func(k: Vector2i) -> bool: return wanted.has(k))
	_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - center).length_squared() < (b - center).length_squared())
	for key: Vector2i in _active.keys():
		if not wanted.has(key):
			var root: Node3D = _active[key]
			world.unload_region_resources(root)
			remove_child(root)
			root.queue_free()
			_active.erase(key)


func _add_chunk(key: Vector2i, origin: Vector2) -> void:
	var root := Node3D.new()
	root.name = "Vegetation_%d_%d" % [key.x, key.y]
	add_child(root)
	_active[key] = root
	_rng.seed = int(hash(Vector3i(key.x, key.y, ForestWorld.SEED + 77)))
	_chunk(key, origin, _grass_meshes, _fern_meshes, world.forest_mask, root)


func _mask_at(mask: Image, x: float, z: float) -> float:
	var u := clampi(int((x / ForestWorld.SIZE + 0.5) * mask.get_width()), 0, mask.get_width() - 1)
	var v := clampi(int((z / ForestWorld.SIZE + 0.5) * mask.get_height()), 0, mask.get_height() - 1)
	return mask.get_pixel(u, v).r


func _ok_ground(x: float, z: float) -> bool:
	var h := world.height_at(x, z)
	return h > 0.55 and h < 125.0 and world.normal_at(x, z).y > 0.86 \
		and absf(x) < ForestWorld.PLAYABLE and absf(z) < ForestWorld.PLAYABLE


func _chunk(key: Vector2i, origin: Vector2, grass: Array[Mesh], ferns: Array[Mesh], mask: Image, root: Node3D) -> void:
	var g_xf: Array = []
	for i in grass.size():
		g_xf.append([])
	var f_xf: Array = []
	for i in ferns.size():
		f_xf.append([])
	var p_xf: Array = []
	for i in _ground_prop_meshes.size():
		p_xf.append([])
	var region := world.region_at(origin.x + CHUNK * 0.5, origin.y + CHUNK * 0.5)
	var species: StringName = &"pine"
	var tree_density := 0.0012
	match region:
		&"tavren":
			species = &"spruce"
			tree_density = 0.011
		&"meyra":
			species = &"alder"
			tree_density = 0.0052
		&"kharum":
			species = &"spruce"
			tree_density = 0.0042
		&"varkai":
			tree_density = 0.0034
		&"ossara":
			tree_density = 0.0011
		&"tundra":
			tree_density = 0.00065
		&"aruun":
			species = &"alder"
			tree_density = 0.0042
	var tree_count := int(CHUNK * CHUNK * tree_density * (0.3 + _mask_at(mask, origin.x + CHUNK * 0.5, origin.y + CHUNK * 0.5)))
	var occupied: Array[Vector2] = []
	for i in tree_count:
		var x := origin.x + _rng.randf() * CHUNK
		var z := origin.y + _rng.randf() * CHUNK
		if Vector2(x, z).distance_to(ForestWorld.SPAWN) < 135.0 or world.river_distance(x, z) < 20.0:
			continue
		if not _ok_tree_ground(x, z):
			continue
		if not world.is_scatter_site_free(x, z, 1.0) or _within_clearance(x, z, occupied):
			continue
		occupied.append(Vector2(x, z))
		var id := "region_%d_%d_tree_%d" % [key.x, key.y, i]
		var kind := &"tree_birch" if species == &"alder" else &"tree_pine"
		world.spawn_region_resource(root, id, kind, Vector2(x, z), _rng.randf_range(0.78, 1.22) * tree_scale(tree_density), _rng.randf() * TAU, species)
	for kind: StringName in [&"sticks", &"stones"]:
		for i in 2:
			var at := origin + Vector2(_rng.randf_range(2.0, CHUNK - 2.0), _rng.randf_range(2.0, CHUNK - 2.0))
			if absf(at.x) >= ForestWorld.PLAYABLE or absf(at.y) >= ForestWorld.PLAYABLE or at.distance_to(ForestWorld.SPAWN) < 10.0:
				continue
			if world.height_at(at.x, at.y) <= 0.55 or world.normal_at(at.x, at.y).y < 0.86:
				continue
			if not world.is_scatter_site_free(at.x, at.y, 1.0) or _within_clearance(at.x, at.y, occupied):
				continue
			occupied.append(at)
			var id := "region_%d_%d_%s_%d" % [key.x, key.y, kind, i]
			world.spawn_region_resource(root, id, kind, at, 1.0, _rng.randf() * TAU)
	var flint_at := _place_flint(key, origin, region, root, occupied)
	flint_at.append_array(_place_plants(key, origin, region, root, occupied))
	var pile_positions: Array[Vector2] = flint_at
	var bounds := Rect2(origin, Vector2(CHUNK, CHUNK)).grow(2.0)
	for pile: Node3D in get_tree().get_nodes_in_group("gather_pile"):
		var at := Vector2(pile.global_position.x, pile.global_position.z)
		if bounds.has_point(at):
			pile_positions.append(at)
	var prop_density := 0.0022 if region == &"meyra" else (0.0028 if region == &"kharum" else 0.0012)
	var prop_count := int(CHUNK * CHUNK * prop_density)
	for i in prop_count:
		var x := origin.x + _rng.randf() * CHUNK
		var z := origin.y + _rng.randf() * CHUNK
		if world.river_distance(x, z) < 11.0 or not _ok_ground(x, z) or _within_clearance(x, z, pile_positions):
			continue
		var index := _rng.randi_range(0, _ground_prop_meshes.size() - 1)
		var scale := _rng.randf_range(0.8, 1.5)
		var prop_xf := Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * scale),
			world.ground_point(x, z) - Vector3(0.0, 0.02, 0.0))
		p_xf[index].append(prop_xf)
	var n_grass := 0  # meadow grass is drawn by MeadowGrass (card clumps around the camera)
	for i in n_grass:
		var x := origin.x + _rng.randf() * CHUNK
		var z := origin.y + _rng.randf() * CHUNK
		var forest := _mask_at(mask, x, z)
		if _rng.randf() < forest * 1.4 or not _ok_ground(x, z) or _within_clearance(x, z, pile_positions):
			continue
		var xf := Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * _rng.randf_range(2.2, 3.4)),
			world.ground_point(x, z) + Vector3(0, -0.03, 0))
		g_xf[_rng.randi() % grass.size()].append(xf)
	var n_fern := int(CHUNK * CHUNK * FERN_DENSITY)
	if region == &"meyra":
		n_fern = int(CHUNK * CHUNK * 0.18)
	for i in n_fern:
		var x := origin.x + _rng.randf() * CHUNK
		var z := origin.y + _rng.randf() * CHUNK
		# under the trees and along forest edges; a few out in the meadow
		if _rng.randf() > clampf(_mask_at(mask, x, z) * 1.3 + 0.08, 0.0, 1.0) or not _ok_ground(x, z) \
				or _within_clearance(x, z, pile_positions):
			continue
		var xf := Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * _rng.randf_range(1.1, 2.0)),
			world.ground_point(x, z) + Vector3(0, -0.05, 0))
		f_xf[_rng.randi() % ferns.size()].append(xf)
	var center := Vector3(origin.x + CHUNK * 0.5, 0, origin.y + CHUNK * 0.5)
	_place_rocks(key, origin, root, pile_positions)
	_place_groves(key, origin, region, species, tree_density, root, occupied)
	for i in grass.size():
		_multimesh(grass[i], g_xf[i], center, GRASS_RANGE, root)
	for i in ferns.size():
		_multimesh(ferns[i], f_xf[i], center, FERN_RANGE, root)
	for i in _ground_prop_meshes.size():
		_multimesh(_ground_prop_meshes[i], p_xf[i], center, FERN_RANGE, root)


## Dense stands where the grove field (FarForest.grove_at) is high: extra fellable trees, a third of them spruce
## among broadleaf species, saplings at the edges, and fallen trunks on the floor. Own RNG and "_grove_" ids, so
## the chunk's original trees keep their ids and saved states.
func _place_groves(key: Vector2i, origin: Vector2, region: StringName, species: StringName, density: float,
		root: Node3D, occupied: Array[Vector2]) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(hash(Vector3i(key.x, key.y, ForestWorld.SEED + 2727)))
	# top dense regions up to ~0.012 trees/m² inside a grove; regions already that dense (Tavren) get none
	var tries := int(CHUNK * CHUNK * clampf(0.0125 - density, 0.0, 0.009))
	var logs: Array = []
	for i in tries:
		var x := origin.x + rng.randf() * CHUNK
		var z := origin.y + rng.randf() * CHUNK
		var g := FarForest.grove_at(x, z)
		if rng.randf() > g * g or Vector2(x, z).distance_to(ForestWorld.SPAWN) < 135.0 or world.river_distance(x, z) < 20.0:
			continue
		if not _ok_tree_ground(x, z) or not world.is_scatter_site_free(x, z, 1.0):
			continue
		var clear := false
		for at in occupied:
			if at.distance_squared_to(Vector2(x, z)) < 3.2 * 3.2:
				clear = true
				break
		if clear:
			continue
		occupied.append(Vector2(x, z))
		var sp := species
		if species != &"spruce" and rng.randf() < 0.35:
			sp = &"spruce"
		var kind := &"tree_birch" if sp == &"alder" else &"tree_pine"
		var sc := rng.randf_range(0.7, 1.3) * lerpf(0.75, 1.0, g) * tree_scale(density)  # younger, smaller at the edge
		world.spawn_region_resource(root, "region_%d_%d_grove_%d" % [key.x, key.y, i], kind, Vector2(x, z), sc,
			rng.randf() * TAU, sp)
		if g > 0.7 and rng.randf() < 0.06:
			logs.append(Vector2(x + rng.randf_range(-4, 4), z + rng.randf_range(-4, 4)))
	# fallen trunks on the forest floor
	if logs.is_empty():
		return
	if _log_mesh == null:
		_log_mesh = AssetLib.mesh(AssetLib.TREES[&"dead_trunk"][0])
		var probe := AssetLib.instance(AssetLib.TREES[&"dead_trunk"][0])
		_log_box = AssetLib.aabb(probe)
		probe.free()
	var xfs: Array = []
	for at: Vector2 in logs:
		if not _ok_ground(at.x, at.y) or not world.is_scatter_site_free(at.x, at.y, 1.5):
			continue
		var yaw := rng.randf() * TAU
		var p := world.ground_point(at.x, at.y) - Vector3(0, 0.1, 0)
		var sc := rng.randf_range(0.8, 1.3)
		xfs.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * sc), p))
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.position = p
		body.rotation.y = yaw
		Graybox.add_shape(body, Graybox.box_shape(_log_box.size * sc * 0.8), (_log_box.position + _log_box.size * 0.5) * sc)
		root.add_child(body)
	_multimesh(_log_mesh, xfs, Vector3(origin.x + CHUNK * 0.5, 0, origin.y + CHUNK * 0.5), ROCK_RANGE, root)


## Mossy boulders in groups out in the meadows and forest, and stones along and in the river (half sunk in the
## shallows). Own RNG, so nothing else in the chunk (trees, piles, save ids) shifts. Visual MultiMeshes; boulders
## big enough to block the way get a collision box.
func _place_rocks(key: Vector2i, origin: Vector2, root: Node3D, avoid: Array[Vector2]) -> void:
	if _rock_meshes.is_empty():
		for path: String in AssetLib.ROCKS[&"medium"] + AssetLib.ROCKS[&"big"]:
			_rock_meshes.append(AssetLib.mesh(path))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(hash(Vector3i(key.x, key.y, ForestWorld.SEED + 1313)))
	var xfs: Array = []
	for i in _rock_meshes.size():
		xfs.append([])
	var add := func(x: float, z: float, sc: float, sink: float, solid: bool) -> void:
		if _within_clearance(x, z, avoid) or not world.is_scatter_site_free(x, z, 0.8):
			return
		var k := rng.randi() % _rock_meshes.size()
		var basis := Basis(Vector3.UP, rng.randf() * TAU) * Basis(Vector3.RIGHT, rng.randf_range(-0.15, 0.15))
		var at := world.ground_point(x, z) - Vector3(0, sink * sc, 0)
		xfs[k].append(Transform3D(basis.scaled(Vector3.ONE * sc), at))
		if solid:
			var body := StaticBody3D.new()
			body.collision_layer = 1
			body.collision_mask = 0
			body.position = at + Vector3(0, 0.35 * sc, 0)
			Graybox.add_shape(body, Graybox.box_shape(Vector3(1.1, 0.7, 1.1) * sc), Vector3.ZERO)
			root.add_child(body)
	# groups of boulders
	for g in rng.randi_range(1, 3):
		var cx := origin.x + rng.randf_range(4.0, CHUNK - 4.0)
		var cz := origin.y + rng.randf_range(4.0, CHUNK - 4.0)
		if Vector2(cx, cz).distance_to(ForestWorld.SPAWN) < 12.0 or not _ok_tree_ground(cx, cz):
			continue
		for r in rng.randi_range(2, 6):
			var a := rng.randf() * TAU
			var d := rng.randf_range(0.0, 3.5)
			var sc := rng.randf_range(0.35, 1.0) if r > 0 else rng.randf_range(0.9, 1.6)
			add.call(cx + cos(a) * d, cz + sin(a) * d, sc, 0.15, sc > 0.8)
	# the river: stones on the banks and in the shallows
	for i in 160:
		var x := origin.x + rng.randf() * CHUNK
		var z := origin.y + rng.randf() * CHUNK
		var h := world.height_at(x, z)
		if h < -0.9 or h > 1.0 or absf(x) > ForestWorld.PLAYABLE or absf(z) > ForestWorld.PLAYABLE:
			continue
		add.call(x, z, rng.randf_range(0.25, 0.9), 0.25, false)
	var center := Vector3(origin.x + CHUNK * 0.5, 0, origin.y + CHUNK * 0.5)
	for i in _rock_meshes.size():
		if not (xfs[i] as Array).is_empty():
			_multimesh(_rock_meshes[i], xfs[i], center, ROCK_RANGE, root)


## Flint outcrops beyond the start valley (which has its own hand-placed flint): river banks everywhere, and the
## Kharum mountains are rich in it. Uses its own RNG so the chunk's tree/pile/grass sequence (and save ids) don't
## shift. Returns the positions so grass and props keep clear of them.
const FLINT_RIVER_CHANCE := 0.5
const FLINT_KHARUM_CHANCES := [0.65, 0.3]
const FLINT_MIN_FROM_SPAWN := 260.0


func _place_flint(key: Vector2i, origin: Vector2, region: StringName, root: Node3D, occupied: Array[Vector2]) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var center := origin + Vector2(CHUNK, CHUNK) * 0.5
	if center.distance_to(ForestWorld.SPAWN) < FLINT_MIN_FROM_SPAWN:
		return out
	var r := RandomNumberGenerator.new()
	r.seed = int(hash(Vector3i(key.x, key.y, ForestWorld.SEED + 4111)))
	var wants: Array[String] = []  # one entry per node we try to place: "river" | "rock"
	if r.randf() < FLINT_RIVER_CHANCE:
		wants.append("river")
	if region == &"kharum":
		for c: float in FLINT_KHARUM_CHANCES:
			if r.randf() < c:
				wants.append("rock")
	for want in wants:
		for attempt in 10:
			var at := origin + Vector2(r.randf_range(2.0, CHUNK - 2.0), r.randf_range(2.0, CHUNK - 2.0))
			if absf(at.x) >= ForestWorld.PLAYABLE or absf(at.y) >= ForestWorld.PLAYABLE:
				continue
			var rd := world.river_distance(at.x, at.y)
			if want == "river" and (rd < 6.0 or rd > 24.0):
				continue
			if world.height_at(at.x, at.y) <= 0.6 or world.normal_at(at.x, at.y).y < (0.86 if want == "river" else 0.78):
				continue
			if not world.is_scatter_site_free(at.x, at.y, 2.0) or _within_clearance(at.x, at.y, occupied):
				continue
			occupied.append(at)
			out.append(at)
			var id := "region_%d_%d_flint_%d" % [key.x, key.y, out.size() - 1]
			world.spawn_region_resource(root, id, &"flint", at, r.randf_range(0.85, 1.2), r.randf() * TAU)
			break
	return out


## Wild food / fibre plants per region (chance per chunk), plus reeds and clay on river banks anywhere.
## Own RNG, like _place_flint, so the rest of the chunk's sequence and save ids are untouched.
const PLANTS_BY_REGION := {
	&"aruun": {&"wild_grain": 0.35, &"wild_carrot": 0.3, &"herbs": 0.4, &"hazel": 0.3, &"flax": 0.2},
	&"tavren": {&"herbs": 0.45, &"hazel": 0.45, &"wild_carrot": 0.15},
	&"meyra": {&"herbs": 0.5, &"flax": 0.4, &"wild_carrot": 0.25},
	&"ossara": {&"wild_grain": 0.6, &"flax": 0.35, &"wild_carrot": 0.3},
	&"kharum": {&"herbs": 0.35, &"hazel": 0.2},
	&"varkai": {&"wild_grain": 0.3, &"herbs": 0.2},
	&"tundra": {&"herbs": 0.15},
}


func _place_plants(key: Vector2i, origin: Vector2, region: StringName, root: Node3D, occupied: Array[Vector2]) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if (origin + Vector2(CHUNK, CHUNK) * 0.5).distance_to(ForestWorld.SPAWN) < 260.0:
		return out
	var r := RandomNumberGenerator.new()
	r.seed = int(hash(Vector3i(key.x, key.y, ForestWorld.SEED + 8233)))
	var wants: Array[StringName] = []
	var table: Dictionary = PLANTS_BY_REGION.get(region, {})
	for k: StringName in table:
		if r.randf() < float(table[k]):
			wants.append(k)
	for k: StringName in [&"reeds", &"clay"]:
		if r.randf() < (0.55 if k == &"reeds" else 0.3):
			wants.append(k)
	var n := 0
	for want in wants:
		for attempt in 8:
			var at := origin + Vector2(r.randf_range(2.0, CHUNK - 2.0), r.randf_range(2.0, CHUNK - 2.0))
			if absf(at.x) >= ForestWorld.PLAYABLE or absf(at.y) >= ForestWorld.PLAYABLE:
				continue
			var rd := world.river_distance(at.x, at.y)
			var bank := want in [&"reeds", &"clay"]
			if (bank and (rd < 9.0 or rd > 22.0)) or (not bank and rd < 20.0):
				continue
			if world.height_at(at.x, at.y) <= 0.6 or world.normal_at(at.x, at.y).y < 0.86:
				continue
			if not world.is_scatter_site_free(at.x, at.y, 1.2) or _within_clearance(at.x, at.y, occupied):
				continue
			occupied.append(at)
			out.append(at)
			world.spawn_region_resource(root, "region_%d_%d_%s_%d" % [key.x, key.y, want, n], want, at, r.randf_range(0.85, 1.15), r.randf() * TAU)
			n += 1
			break
	return out


func _within_clearance(x: float, z: float, positions: Array[Vector2]) -> bool:
	for at in positions:
		if at.distance_squared_to(Vector2(x, z)) < 1.5 * 1.5:
			return true
	return false


func _ok_tree_ground(x: float, z: float) -> bool:
	var h := world.height_at(x, z)
	return h > 1.5 and h < 135.0 and world.normal_at(x, z).y > 0.72 \
		and absf(x) < ForestWorld.PLAYABLE and absf(z) < ForestWorld.PLAYABLE


func _multimesh(mesh: Mesh, xfs: Array, center: Vector3, vis_range: float, root: Node3D) -> void:
	if xfs.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size():
		var xf: Transform3D = xfs[i]
		mm.set_instance_transform(i, Transform3D(xf.basis, xf.origin - center))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.position = center
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if vis_range == ROCK_RANGE \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var q := Settings.quality()
	mmi.visibility_range_end = q.grass_range if vis_range == GRASS_RANGE else (ROCK_RANGE if vis_range == ROCK_RANGE else q.fern_range)
	mmi.visibility_range_end_margin = 8.0
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	root.add_child(mmi)


func _scatter_decor(mask: Image) -> void:
	var sets := [
		[AssetLib.TREES[&"dead_trunk"], 45, 0.6, 1.4, true],
		[AssetLib.TREES[&"stump"], 35, 0.45, 0.7, true],
		[AssetLib.ROCKS[&"medium"], 80, 0.5, 1.2, true],
		[AssetLib.PLANTS[&"shrub"], 60, 2.0, 3.0, false],
	]
	for set: Array in sets:
		var placed := 0
		var tries := 0
		while placed < int(set[1]) and tries < int(set[1]) * 10:
			tries += 1
			var x := _rng.randf_range(ForestWorld.SPAWN.x - 360.0, ForestWorld.SPAWN.x + 360.0)
			var z := _rng.randf_range(ForestWorld.SPAWN.y - 360.0, ForestWorld.SPAWN.y + 360.0)
			if not _ok_ground(x, z) or Vector2(x, z).distance_to(ForestWorld.SPAWN) < 9.0:
				continue
			if _rng.randf() > 0.25 + _mask_at(mask, x, z):
				continue
			var path: String = (set[0] as Array)[_rng.randi() % (set[0] as Array).size()]
			var node := AssetLib.instance(path)
			var sc := _rng.randf_range(set[2], set[3])
			node.scale = Vector3.ONE * sc
			node.rotation.y = _rng.randf() * TAU
			node.position = world.ground_point(x, z) + Vector3(0, -0.06, 0)
			if bool(set[4]):
				var body := StaticBody3D.new()
				body.collision_layer = 1
				body.collision_mask = 0
				body.position = node.position
				body.rotation = node.rotation
				node.position = Vector3.ZERO
				node.rotation = Vector3.ZERO
				body.add_child(node)
				var box := AssetLib.aabb(node)
				Graybox.add_shape(body, Graybox.box_shape(box.size * sc * 0.85), (box.position + box.size * 0.5) * sc)
				add_child(body)
			else:
				add_child(node)
			placed += 1
