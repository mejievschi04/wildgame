class_name TerrainLod
extends Node3D
## Draws the baked terrain (ForestWorld bake, ~2 m grid) in two levels:
##  · near: full-resolution chunks of CHUNK² cells in a (2·RADIUS+1)² window around the camera, streamed a few
##    per frame as the camera moves; each has a skirt so no crack shows against the far mesh.
##  · far: one mesh over the whole map from every FAR_STRIDE-th sample (~8 m), whose material discards its pixels
##    inside the loaded window (terrain.gdshader "hole").
## Both use the bake grid's triangulation, so what you see matches the collision and ForestWorld.height_at().

const CHUNK := 32            # cells per chunk side (~66 m)
const RADIUS := 3            # chunks on each side of the camera's chunk: a ~460 m window at 2 m
const FAR_STRIDE := 8        # far mesh: every 8th bake sample (~16 m on the 8 km map; must divide BAKE_N - 1)
const BUILD_PER_FRAME := 2
const SKIRT := 1.5           # metres the chunk edges hang down under the far mesh

var world: ForestWorld
var material: ShaderMaterial
var far_material: ShaderMaterial
var far_mesh: MeshInstance3D
var _chunks: Dictionary = {}        # Vector2i -> MeshInstance3D
var _window := Rect2i()             # chunk window being loaded / shown
var _shown := Rect2i()              # window whose chunks are all built (the far mesh's hole)
var _queue: Array[Vector2i] = []


static func chunks_per_side() -> int:
	return (ForestWorld.BAKE_N - 1) / CHUNK


func build(w: ForestWorld, mat: ShaderMaterial, focus: Vector3) -> void:
	world = w
	material = mat
	far_material = mat.duplicate() as ShaderMaterial
	far_material.set_shader_parameter("far_mesh", true)
	far_mesh = MeshInstance3D.new()
	far_mesh.name = "FarTerrain"
	far_mesh.mesh = _far_mesh()
	far_mesh.material_override = far_material
	add_child(far_mesh)
	# the first window is built at once, so the opening frames are not drawn from the coarse mesh
	_recenter(_chunk_of(focus))
	while not _queue.is_empty():
		_build_next()
	_finish_window()


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var c := _chunk_of(cam.global_position)
	if not _window.has_point(c) or c != _window.get_center():
		_recenter(c)
	for i in BUILD_PER_FRAME:
		if _queue.is_empty():
			break
		_build_next()
	if _queue.is_empty() and _shown != _window:
		_finish_window()


func _chunk_of(p: Vector3) -> Vector2i:
	var n := chunks_per_side()
	var size := CHUNK * ForestWorld.BAKE_CELL
	return Vector2i(clampi(floori((p.x + ForestWorld.HALF) / size), 0, n - 1),
		clampi(floori((p.z + ForestWorld.HALF) / size), 0, n - 1))


func _recenter(c: Vector2i) -> void:
	var n := chunks_per_side()
	var lo := Vector2i(clampi(c.x - RADIUS, 0, n - 1), clampi(c.y - RADIUS, 0, n - 1))
	var hi := Vector2i(clampi(c.x + RADIUS, 0, n - 1), clampi(c.y + RADIUS, 0, n - 1))
	_window = Rect2i(lo, hi - lo + Vector2i.ONE)
	_queue.clear()
	for z in range(lo.y, hi.y + 1):
		for x in range(lo.x, hi.x + 1):
			var k := Vector2i(x, z)
			if not _chunks.has(k):
				_queue.append(k)
	_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (a - c).length_squared() < (b - c).length_squared())


func _build_next() -> void:
	var k: Vector2i = _queue.pop_front()
	var mi := MeshInstance3D.new()
	mi.name = "Chunk_%d_%d" % [k.x, k.y]
	mi.mesh = _chunk_mesh(k)
	mi.material_override = material
	add_child(mi)
	_chunks[k] = mi


## Every chunk of the new window is built: hide the far mesh under it and drop the chunks left behind (they stay
## until now, so the old window never shows a gap while the new one streams in).
func _finish_window() -> void:
	for k: Vector2i in _chunks.keys():
		if not _window.has_point(k):
			(_chunks[k] as Node).queue_free()
			_chunks.erase(k)
	_shown = _window
	var size := CHUNK * ForestWorld.BAKE_CELL
	var lo := Vector2(_window.position) * size - Vector2.ONE * ForestWorld.HALF
	var hi := Vector2(_window.end) * size - Vector2.ONE * ForestWorld.HALF
	far_material.set_shader_parameter("hole", Vector4(lo.x, lo.y, hi.x, hi.y))


func is_full_resolution(x: float, z: float) -> bool:
	return _chunks.has(_chunk_of(Vector3(x, 0.0, z)))


# ---------------------------------------------------------------- meshes

static func _tangent(nrm: Vector3) -> Vector3:
	# along +x (the UV's u), on the surface
	return Vector3(nrm.y, -nrm.x, 0.0).normalized()


static func _arrays(verts: PackedVector3Array, normals: PackedVector3Array, idx: PackedInt32Array) -> Array:
	var uvs := PackedVector2Array()
	uvs.resize(verts.size())
	var tangents := PackedFloat32Array()
	tangents.resize(verts.size() * 4)
	for i in verts.size():
		uvs[i] = Vector2(verts[i].x, verts[i].z) / 80.0
		var t := _tangent(normals[i])
		tangents[i * 4] = t.x
		tangents[i * 4 + 1] = t.y
		tangents[i * 4 + 2] = t.z
		tangents[i * 4 + 3] = 1.0
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays


## Quads (a b / c d) split along b–c, like the bake's triangulation (u + v <= 1).
static func _grid_indices(n: int, idx: PackedInt32Array) -> void:
	for iz in n - 1:
		for ix in n - 1:
			var a := iz * n + ix
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])


func _far_mesh() -> ArrayMesh:
	var n := (ForestWorld.BAKE_N - 1) / FAR_STRIDE + 1
	var bake := ForestWorld._bake
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	verts.resize(n * n)
	normals.resize(n * n)
	for iz in n:
		var bz := iz * FAR_STRIDE
		for ix in n:
			var bx := ix * FAR_STRIDE
			verts[iz * n + ix] = Vector3(-ForestWorld.HALF + bx * ForestWorld.BAKE_CELL, bake[bz * ForestWorld.BAKE_N + bx],
				-ForestWorld.HALF + bz * ForestWorld.BAKE_CELL)
			normals[iz * n + ix] = ForestWorld.bake_normal(bx, bz, FAR_STRIDE)
	var idx := PackedInt32Array()
	_grid_indices(n, idx)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(verts, normals, idx))
	return mesh


func _chunk_mesh(k: Vector2i) -> ArrayMesh:
	var n := CHUNK + 1
	var bake := ForestWorld._bake
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	verts.resize(n * n)
	normals.resize(n * n)
	for iz in n:
		var bz := k.y * CHUNK + iz
		for ix in n:
			var bx := k.x * CHUNK + ix
			verts[iz * n + ix] = Vector3(-ForestWorld.HALF + bx * ForestWorld.BAKE_CELL, bake[bz * ForestWorld.BAKE_N + bx],
				-ForestWorld.HALF + bz * ForestWorld.BAKE_CELL)
			normals[iz * n + ix] = ForestWorld.bake_normal(bx, bz)
	var idx := PackedInt32Array()
	_grid_indices(n, idx)
	# skirts: each edge row copied SKIRT m lower and stitched to it (the shader draws both faces)
	var edges: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]
	for i in n:
		edges[0].append(i)                    # north
		edges[1].append((n - 1) * n + i)      # south
		edges[2].append(i * n)                # west
		edges[3].append(i * n + n - 1)        # east
	for edge in edges:
		var base := verts.size()
		for i in edge:
			verts.append(verts[i] - Vector3(0.0, SKIRT, 0.0))
			normals.append(normals[i])
		for j in n - 1:
			idx.append_array([edge[j], edge[j + 1], base + j, edge[j + 1], base + j + 1, base + j])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(verts, normals, idx))
	return mesh
