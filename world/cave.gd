class_name Cave
extends Node3D
## A cave. tools/gen_terrain.py cuts it into the terrain bake as a trench (its floor and walls, so the terrain
## collision needs no holes); this node closes the trench with a rock roof:
##  · the roof's outer face is the hillside as it was before the cut (terrain material), a hair below it so it
##    only shows where the trench is;
##  · its inner face is the cave's ceiling, an arch from wall to wall, rock-textured and roughened;
##  · over the mouth, a face from the arch up to the hillside;
##  · collision for all of it, and a reflection probe that keeps the sky's light out of the dark inside.
## data/caves.json: rings every ~2 m from the mouth past the far end (x, z, floor, half-width, height, roof
## heights across it).

const ARCH := 14             # vertices across the ceiling arch
const BELOW := 0.08          # the roof's outer face sits this far under the hillside
const SINK := 0.35           # arch feet and face bottoms go this far into the ground

var id := ""
var world: ForestWorld
var dir := Vector2.RIGHT     # into the hill
var side := Vector2.DOWN     # left of dir
var entry := Vector2.ZERO
var length := 0.0
var mouth := 0.0
var rings: Array = []
var _noise := FastNoiseLite.new()


func build(w: ForestWorld, def: Dictionary, terrain_mat: Material) -> void:
	world = w
	id = def.id
	name = "Cave_%s" % id
	dir = Vector2(def.dir[0], def.dir[1])
	side = Vector2(-dir.y, dir.x)
	entry = Vector2(def.entry[0], def.entry[1])
	length = float(def.length)
	mouth = float(def.mouth)
	rings = def.rings
	_noise.seed = ForestWorld.SEED + 900 + hash(id) % 1000
	_noise.frequency = 0.35
	_noise.fractal_octaves = 3
	var rock := _rock_material()
	var top := _roof_mesh()
	var ceiling := _ceiling_mesh()
	var face := _mouth_mesh()
	for part: Array in [[top, terrain_mat, "Roof"], [ceiling, rock, "Ceiling"], [face, rock, "MouthFace"]]:
		var mi := MeshInstance3D.new()
		mi.name = part[2]
		mi.mesh = part[0]
		mi.material_override = part[1]
		add_child(mi)
	var body := StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("terrain")
	for m: ArrayMesh in [top, ceiling, face]:
		var shape := m.create_trimesh_shape()
		shape.backface_collision = true
		Graybox.add_shape(body, shape)
	add_child(body)
	_add_darkness()


## (t along the cave, lateral offset) of a world point.
func local_of(p: Vector3) -> Vector2:
	var r := Vector2(p.x, p.z) - entry
	return Vector2(r.dot(dir), r.dot(side))


## The ring just before t (rings are sorted by t).
func _ring_at(t: float) -> Dictionary:
	var best: Dictionary = rings[0]
	for r: Dictionary in rings:
		if float(r.t) <= t:
			best = r
	return best


## True inside the cave's hollow, from the mouth in.
func contains(p: Vector3) -> bool:
	var l := local_of(p)
	if l.x < mouth or l.x > float(rings[rings.size() - 1].t):
		return false
	var r := _ring_at(l.x)
	return absf(l.y) < float(r.hw) and p.y < float(r.floor) + float(r.h) + 0.5 and p.y > float(r.floor) - 1.0


## Shelter value for get_shelter_at(): a roof and walls of rock, more so deeper in.
func shelter_at(p: Vector3) -> float:
	if not contains(p):
		return 0.0
	return lerpf(7.0, 11.0, smoothstep(mouth, mouth + 12.0, local_of(p).x))


## Within the cut (trench, walls and roof), widened by `margin`: keeps trees and scatter out.
func covers(x: float, z: float, margin: float = 0.0) -> bool:
	var l := local_of(Vector3(x, 0.0, z))
	if l.x < -float(15.0) - margin or l.x > float(rings[rings.size() - 1].t) + margin:
		return false
	var r := _ring_at(maxf(l.x, mouth))
	return absf(l.y) < float(r.r) + margin


func _point(r: Dictionary, lateral: float, y: float) -> Vector3:
	var c := Vector2(float(r.x), float(r.z)) + side * lateral
	return Vector3(c.x, y, c.y)


func _rough(p: Vector3) -> float:
	return _noise.get_noise_3d(p.x, p.y, p.z)


# ---------------------------------------------------------------- meshes

## Commits the mesh with its front faces toward `facing` (checked at vertex `probe`): the rock shader culls back
## faces, so the ceiling must face down into the cave and the mouth's face out of the hill.
static func _oriented(verts: PackedVector3Array, idx: PackedInt32Array, uv_scale: float, probe: int,
		facing: Vector3) -> ArrayMesh:
	var mesh := _commit(verts, idx, uv_scale)
	var normals: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	if normals[probe].dot(facing) >= 0.0:
		return mesh
	var flipped := PackedInt32Array()
	for i in range(0, idx.size(), 3):
		flipped.append_array([idx[i], idx[i + 2], idx[i + 1]])
	return _commit(verts, flipped, uv_scale)


static func _commit(verts: PackedVector3Array, idx: PackedInt32Array, uv_scale: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in verts:
		st.set_uv(Vector2(v.x, v.z) / uv_scale)
		st.add_vertex(v)
	for i in idx:
		st.add_index(i)
	st.generate_normals()
	st.generate_tangents()
	return st.commit()


## Rows of `cols` vertices, joined row to row into quads.
static func _grid_indices(rows: int, cols: int) -> PackedInt32Array:
	var idx := PackedInt32Array()
	for i in rows - 1:
		for j in cols - 1:
			var a := i * cols + j
			idx.append_array([a, a + cols, a + 1, a + 1, a + cols, a + cols + 1])
	return idx


## The hillside over the cave. Its normals come from the hillside's own slope (not from the mesh, whose sunk edges
## would bend them), so it lights exactly like the terrain around it.
func _roof_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var cols: int = (rings[0].top as Array).size()
	var n := rings.size()
	for i in n:
		var r: Dictionary = rings[i]
		var tops: Array = r.top
		var prev: Dictionary = rings[maxi(i - 1, 0)]
		var next: Dictionary = rings[mini(i + 1, n - 1)]
		var dt := maxf(float(next.t) - float(prev.t), 0.01)
		var step := 2.0 * float(r.r) / (cols - 1)
		for j in cols:
			var lateral := lerpf(-float(r.r), float(r.r), float(j) / (cols - 1))
			var y := float(tops[j]) - BELOW
			if j == 0 or j == cols - 1:
				y -= SINK
			verts.append(_point(r, lateral, y))
			var j0 := maxi(j - 1, 0)
			var j1 := mini(j + 1, cols - 1)
			var d_lat := (float(tops[j1]) - float(tops[j0])) / maxf((j1 - j0) * step, 0.01)
			var d_t := (float((next.top as Array)[j]) - float((prev.top as Array)[j])) / dt
			var g := dir * d_t + side * d_lat
			normals.append(Vector3(-g.x, 1.0, -g.y).normalized())
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var uvs := PackedVector2Array()
	var tangents := PackedFloat32Array()
	for k in verts.size():
		uvs.append(Vector2(verts[k].x, verts[k].z) / 80.0)
		var t := Vector3(normals[k].y, -normals[k].x, 0.0).normalized()
		tangents.append_array([t.x, t.y, t.z, 1.0])
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _grid_indices(n, cols)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Arch height over the floor at a lateral offset (walls near vertical, a rounded top).
static func _arch_y(lateral: float, hw: float, h: float) -> float:
	if hw <= 0.01:
		return 0.0
	var u := clampf(absf(lateral) / hw, 0.0, 1.0)
	return h * pow(1.0 - pow(u, 3.0), 0.55)


func _ceiling_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	for r: Dictionary in rings:
		var hw := float(r.hw)
		for k in ARCH:
			var lateral := lerpf(-hw, hw, float(k) / (ARCH - 1))
			var y := float(r.floor) + _arch_y(lateral, hw, float(r.h))
			if k == 0 or k == ARCH - 1:
				y = float(r.floor) - SINK
			var p := _point(r, lateral, y)
			# rough rock: pushed in and out across the arch (not at its feet, which sit in the floor)
			var inward := Vector3(-side.x * signf(lateral), -1.0, -side.y * signf(lateral)).normalized() \
				if absf(lateral) > hw * 0.5 else Vector3.DOWN
			if k > 0 and k < ARCH - 1:
				p += inward * _rough(p) * 0.45 * minf(hw, 1.0)
			verts.append(p)
	# probe: the apex of the second ring
	return _oriented(verts, _grid_indices(rings.size(), ARCH), 6.0, ARCH + ARCH / 2, Vector3.DOWN)


## The rock face over the mouth: from the arch (or the trench wall beside it) up to the hillside.
func _mouth_mesh() -> ArrayMesh:
	var r: Dictionary = rings[0]
	var tops: Array = r.top
	var cols := tops.size()
	var hw := float(r.hw)
	var verts := PackedVector3Array()
	for j in cols:
		var lateral := lerpf(-float(r.r), float(r.r), float(j) / (cols - 1))
		var top := float(tops[j]) - BELOW
		var bottom: float
		if absf(lateral) < hw:
			bottom = float(r.floor) + _arch_y(lateral, hw, float(r.h))
		else:
			var g := _point(r, lateral, 0.0)
			bottom = world.height_at(g.x, g.z) - SINK
		bottom = minf(bottom, top)
		var lo := _point(r, lateral, bottom)
		var hi := _point(r, lateral, top)
		# a little overhang and roughness on the face, so it reads as a rock brow
		var out := Vector3(-dir.x, 0.0, -dir.y)
		hi += out * (0.6 + 0.5 * _rough(hi)) * smoothstep(0.5, 3.0, top - bottom)
		verts.append(lo)
		verts.append(hi)
	var idx := PackedInt32Array()
	for j in cols - 1:
		var a := j * 2
		idx.append_array([a, a + 1, a + 2, a + 2, a + 1, a + 3])
	return _oriented(verts, idx, 6.0, cols, Vector3(-dir.x, 0.0, -dir.y))


func _rock_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://world/shaders/cliff.gdshader")
	var tm: ShaderMaterial = world._terrain_mat
	m.set_shader_parameter("albedo_tex", tm.get_shader_parameter("albedo_tex"))
	m.set_shader_parameter("normal_tex", tm.get_shader_parameter("normal_tex"))
	m.set_shader_parameter("noise_tex", tm.get_shader_parameter("macro_noise"))
	# no waterfall here: put its spray far away
	m.set_shader_parameter("fall_point", Vector3(0.0, -5000.0, 0.0))
	m.set_shader_parameter("fall_bottom", Vector3(0.0, -5010.0, 0.0))
	return m


## Inside, only light that comes in through the mouth: a probe whose ambient light is near black.
func _add_darkness() -> void:
	var first: Dictionary = rings[0]
	var last: Dictionary = rings[rings.size() - 1]
	var widest := 0.0
	var tallest := 0.0
	for r: Dictionary in rings:
		widest = maxf(widest, float(r.hw))
		tallest = maxf(tallest, float(r.h))
	var a := Vector2(float(first.x), float(first.z)) + dir * 1.5
	var b := Vector2(float(last.x), float(last.z))
	var probe := ReflectionProbe.new()
	probe.name = "Darkness"
	probe.interior = true
	probe.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	probe.ambient_color = Color(0.035, 0.032, 0.03)
	probe.ambient_color_energy = 1.0
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.blend_distance = 3.0
	var mid := (a + b) * 0.5
	probe.size = Vector3(widest * 2.0 + 1.0, tallest + 2.0, a.distance_to(b) + 2.0)
	probe.position = Vector3(mid.x, float(first.floor) + tallest * 0.5, mid.y)
	probe.rotation.y = atan2(dir.x, dir.y)
	add_child(probe)
