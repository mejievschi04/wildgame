class_name Vegetation
extends Node3D
## Decorative, non-interactive vegetation (CC0 scanned assets):
## grass & ferns as chunked MultiMeshes with visibility ranges, plus scattered fallen trunks,
## stumps, mossy rocks, branches and shrubs. Deterministic (fixed seed).

const CHUNK := 48.0
const LOAD_RADIUS := 3
const GRASS_DENSITY := 0.9  # candidates per m²
const GRASS_RANGE := 42.0
const FERN_DENSITY := 0.07
const FERN_RANGE := 75.0

var world: ForestWorld
var _rng := RandomNumberGenerator.new()
var _grass_meshes: Array[Mesh] = []
var _fern_meshes: Array[Mesh] = []
var _tree_paths: Array[String] = []
var _tree_meshes: Array[Mesh] = []
var _ground_prop_meshes: Array[Mesh] = []
var _active: Dictionary = {}
var _last_center := Vector2i(2147483647, 2147483647)


func build(w: ForestWorld, forest_mask: Image) -> void:
	world = w
	_rng.seed = ForestWorld.SEED + 77
	for path: String in AssetLib.PLANTS[&"grass"]:
		_grass_meshes.append(AssetLib.mesh(path))
	for path: String in AssetLib.PLANTS[&"fern"]:
		_fern_meshes.append(AssetLib.mesh(path))
	for species: StringName in [&"spruce", &"pine", &"alder"]:
		for path: String in AssetLib.TREES[species]:
			_tree_paths.append(path)
			_tree_meshes.append(AssetLib.mesh(path))
	for path: String in AssetLib.PLANTS[&"shrub"] + AssetLib.ROCKS[&"small"]:
		_ground_prop_meshes.append(AssetLib.mesh(path))
	_stream_near(ForestWorld.SPAWN)
	_scatter_decor(forest_mask)


func _process(_delta: float) -> void:
	if not is_instance_valid(world) or not is_instance_valid(world.player):
		return
	_stream_near(Vector2(world.player.global_position.x, world.player.global_position.z))


func _stream_near(pos: Vector2) -> void:
	var center := Vector2i(floori(pos.x / CHUNK), floori(pos.y / CHUNK))
	if center == _last_center:
		return
	_last_center = center
	var wanted := {}
	for dz in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
		for dx in range(-LOAD_RADIUS, LOAD_RADIUS + 1):
			var key := center + Vector2i(dx, dz)
			var origin := Vector2(key.x * CHUNK, key.y * CHUNK)
			if absf(origin.x) > ForestWorld.PLAYABLE or absf(origin.y) > ForestWorld.PLAYABLE:
				continue
			wanted[key] = true
			if not _active.has(key):
				_add_chunk(key, origin)
	for key: Vector2i in _active.keys():
		if not wanted.has(key):
			(_active[key] as Node).queue_free()
			_active.erase(key)


func _add_chunk(key: Vector2i, origin: Vector2) -> void:
	var root := Node3D.new()
	root.name = "Vegetation_%d_%d" % [key.x, key.y]
	add_child(root)
	_active[key] = root
	_rng.seed = int(hash(Vector3i(key.x, key.y, ForestWorld.SEED + 77)))
	_chunk(origin, _grass_meshes, _fern_meshes, world.forest_mask, root)


func _mask_at(mask: Image, x: float, z: float) -> float:
	var u := clampi(int((x / ForestWorld.SIZE + 0.5) * mask.get_width()), 0, mask.get_width() - 1)
	var v := clampi(int((z / ForestWorld.SIZE + 0.5) * mask.get_height()), 0, mask.get_height() - 1)
	return mask.get_pixel(u, v).r


func _ok_ground(x: float, z: float) -> bool:
	var h := world.height_at(x, z)
	return h > 0.55 and h < 125.0 and world.normal_at(x, z).y > 0.86 \
		and absf(x) < ForestWorld.PLAYABLE and absf(z) < ForestWorld.PLAYABLE


func _chunk(origin: Vector2, grass: Array[Mesh], ferns: Array[Mesh], mask: Image, root: Node3D) -> void:
	var g_xf: Array = []
	for i in grass.size():
		g_xf.append([])
	var f_xf: Array = []
	for i in ferns.size():
		f_xf.append([])
	var t_xf: Array = []
	for i in _tree_meshes.size():
		t_xf.append([])
	var p_xf: Array = []
	for i in _ground_prop_meshes.size():
		p_xf.append([])
	var region := world.region_at(origin.x + CHUNK * 0.5, origin.y + CHUNK * 0.5)
	var tree_choices: Array = AssetLib.TREES[&"pine"]
	var tree_density := 0.0012
	match region:
		&"tavren":
			tree_choices = AssetLib.TREES[&"spruce"]
			tree_density = 0.011
		&"meyra":
			tree_choices = AssetLib.TREES[&"alder"]
			tree_density = 0.0052
		&"kharum":
			tree_choices = AssetLib.TREES[&"spruce"]
			tree_density = 0.0042
		&"varkai":
			tree_density = 0.0034
		&"ossara":
			tree_density = 0.0011
		&"tundra":
			tree_density = 0.00065
		&"aruun":
			tree_choices = AssetLib.TREES[&"alder"]
			tree_density = 0.0042
	var tree_count := int(CHUNK * CHUNK * tree_density * (0.3 + _mask_at(mask, origin.x + CHUNK * 0.5, origin.y + CHUNK * 0.5)))
	for i in tree_count:
		var x := origin.x + _rng.randf() * CHUNK
		var z := origin.y + _rng.randf() * CHUNK
		if Vector2(x, z).distance_to(ForestWorld.SPAWN) < 135.0 or world.river_distance(x, z) < 20.0:
			continue
		if not _ok_tree_ground(x, z):
			continue
		var path: String = tree_choices[_rng.randi() % tree_choices.size()]
		var mesh_index := _tree_paths.find(path)
		if mesh_index < 0:
			continue
		var tree_xf := Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * _rng.randf_range(0.78, 1.22)),
			world.ground_point(x, z) - Vector3(0.0, 0.02, 0.0))
		t_xf[mesh_index].append(tree_xf)
	var prop_density := 0.0022 if region == &"meyra" else (0.0028 if region == &"kharum" else 0.0012)
	var prop_count := int(CHUNK * CHUNK * prop_density)
	for i in prop_count:
		var x := origin.x + _rng.randf() * CHUNK
		var z := origin.y + _rng.randf() * CHUNK
		if world.river_distance(x, z) < 11.0 or not _ok_ground(x, z):
			continue
		var use_rock := region == &"kharum" and _rng.randf() < 0.7
		var index := _rng.randi_range(3, _ground_prop_meshes.size() - 1) if use_rock \
			else _rng.randi_range(0, 2)
		var scale := _rng.randf_range(0.7, 1.4) if use_rock else _rng.randf_range(0.8, 1.5)
		var prop_xf := Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * scale),
			world.ground_point(x, z) - Vector3(0.0, 0.02, 0.0))
		p_xf[index].append(prop_xf)
	var n_grass := int(CHUNK * CHUNK * GRASS_DENSITY)
	for i in n_grass:
		var x := origin.x + _rng.randf() * CHUNK
		var z := origin.y + _rng.randf() * CHUNK
		var forest := _mask_at(mask, x, z)
		if _rng.randf() < forest * 1.4 or not _ok_ground(x, z):
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
		if _rng.randf() > _mask_at(mask, x, z) or not _ok_ground(x, z):
			continue
		var xf := Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * _rng.randf_range(0.9, 1.6)),
			world.ground_point(x, z) + Vector3(0, -0.05, 0))
		f_xf[_rng.randi() % ferns.size()].append(xf)
	var center := Vector3(origin.x + CHUNK * 0.5, 0, origin.y + CHUNK * 0.5)
	for i in grass.size():
		_multimesh(grass[i], g_xf[i], center, GRASS_RANGE, root)
	for i in ferns.size():
		_multimesh(ferns[i], f_xf[i], center, FERN_RANGE, root)
	for i in _tree_meshes.size():
		_multimesh(_tree_meshes[i], t_xf[i], center, 240.0, root, &"tree")
	for i in _ground_prop_meshes.size():
		_multimesh(_ground_prop_meshes[i], p_xf[i], center, FERN_RANGE, root)


func _ok_tree_ground(x: float, z: float) -> bool:
	var h := world.height_at(x, z)
	return h > 1.5 and h < 135.0 and world.normal_at(x, z).y > 0.72 \
		and absf(x) < ForestWorld.PLAYABLE and absf(z) < ForestWorld.PLAYABLE


func _multimesh(mesh: Mesh, xfs: Array, center: Vector3, vis_range: float, root: Node3D, profile: StringName = &"ground") -> void:
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
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if profile == &"tree" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var q := Settings.quality()
	mmi.visibility_range_end = vis_range if profile == &"tree" else (q.grass_range if vis_range == GRASS_RANGE else q.fern_range)
	mmi.visibility_range_end_margin = 20.0 if profile == &"tree" else 8.0
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	var m := mesh.surface_get_material(0)
	mmi.material_override = AssetLib.tuned(m, profile)
	root.add_child(mmi)


func _scatter_decor(mask: Image) -> void:
	var sets := [
		[AssetLib.TREES[&"dead_trunk"], 45, 0.6, 1.4, true],
		[AssetLib.TREES[&"stump"], 35, 0.45, 0.7, true],
		[AssetLib.ROCKS[&"medium"], 80, 0.5, 1.2, true],
		[AssetLib.PLANTS[&"branches"], 110, 0.8, 1.2, false],
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
