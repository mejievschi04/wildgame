class_name Vegetation
extends Node3D
## Decorative, non-interactive vegetation (CC0 scanned assets):
## grass & ferns as chunked MultiMeshes with visibility ranges, plus scattered fallen trunks,
## stumps, mossy rocks, branches and shrubs. Deterministic (fixed seed).

const CHUNK := 20.0
const GRASS_DENSITY := 0.9  # candidates per m²
const GRASS_RANGE := 42.0
const FERN_DENSITY := 0.07
const FERN_RANGE := 75.0

var world: ForestWorld
var _rng := RandomNumberGenerator.new()


func build(w: ForestWorld, forest_mask: Image) -> void:
	world = w
	_rng.seed = ForestWorld.SEED + 77
	var grass_meshes: Array[Mesh] = []
	for path: String in AssetLib.PLANTS[&"grass"]:
		grass_meshes.append(AssetLib.mesh(path))
	var fern_meshes: Array[Mesh] = []
	for path: String in AssetLib.PLANTS[&"fern"]:
		fern_meshes.append(AssetLib.mesh(path))
	var lim := ForestWorld.PLAYABLE + 6.0
	var c := -lim
	while c < lim:
		var r := -lim
		while r < lim:
			_chunk(Vector2(c, r), grass_meshes, fern_meshes, forest_mask)
			r += CHUNK
		c += CHUNK
	_scatter_decor(forest_mask)


func _mask_at(mask: Image, x: float, z: float) -> float:
	var u := clampi(int((x / ForestWorld.SIZE + 0.5) * mask.get_width()), 0, mask.get_width() - 1)
	var v := clampi(int((z / ForestWorld.SIZE + 0.5) * mask.get_height()), 0, mask.get_height() - 1)
	return mask.get_pixel(u, v).r


func _ok_ground(x: float, z: float) -> bool:
	var h := world.height_at(x, z)
	return h > 0.55 and world.normal_at(x, z).y > 0.86 and absf(x) < ForestWorld.PLAYABLE and absf(z) < ForestWorld.PLAYABLE


func _chunk(origin: Vector2, grass: Array[Mesh], ferns: Array[Mesh], mask: Image) -> void:
	var g_xf: Array = []
	for i in grass.size():
		g_xf.append([])
	var f_xf: Array = []
	for i in ferns.size():
		f_xf.append([])
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
		_multimesh(grass[i], g_xf[i], center, GRASS_RANGE)
	for i in ferns.size():
		_multimesh(ferns[i], f_xf[i], center, FERN_RANGE)


func _multimesh(mesh: Mesh, xfs: Array, center: Vector3, vis_range: float) -> void:
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
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var q := Settings.quality()
	mmi.visibility_range_end = q.grass_range if vis_range == GRASS_RANGE else q.fern_range
	mmi.visibility_range_end_margin = 8.0
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	var m := mesh.surface_get_material(0)
	mmi.material_override = AssetLib.tuned(m)
	add_child(mmi)


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
			var x := _rng.randf_range(-ForestWorld.PLAYABLE, ForestWorld.PLAYABLE)
			var z := _rng.randf_range(-ForestWorld.PLAYABLE, ForestWorld.PLAYABLE)
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
