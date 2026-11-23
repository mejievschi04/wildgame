class_name Waterfall
extends Node3D
## A waterfall on the main river: a rock outcrop on the bank (a heightfield added on top of the terrain, so the
## terrain, its saves and the seeded scatter are untouched) with a recessed alcove facing the water. A creek runs
## across the plateau in a cut channel, pours over the lip and falls ~11 m into the river's edge; spray and mist
## rise at its foot and white water streams downstream (water.gdshader "rapids").

const CELL := 0.5
const ALONG := 24.0      # half-length of the outcrop along the river
const D_MIN := 6.0       # distance from the river centre where the mesh starts…
const D_MAX := 52.0      # …and ends
const HEIGHT := 15.0
const NOTCH := 1.6       # depth of the creek's channel through the plateau

var world: ForestWorld
var z0 := -520.0
var side := 1.0          # +1 east bank, −1 west bank
var lip := Vector3.ZERO
var foot := Vector3.ZERO
var _c := Vector2.ZERO   # river centre at z0
var _t := Vector2.ZERO   # along the river (downstream)
var _n := Vector2.ZERO   # from the river toward this bank
var _noise := FastNoiseLite.new()


func build(w: ForestWorld, p_z0: float, p_side: float) -> void:
	world = w
	z0 = p_z0
	side = p_side
	_c = Vector2(w.river_x(z0), z0)
	_t = Vector2(w.river_x(z0 + 2.0) - w.river_x(z0 - 2.0), 4.0).normalized()
	_n = Vector2(_t.y, -_t.x) * side
	if _n.x * side < 0.0:
		_n = -_n
	_noise.seed = ForestWorld.SEED + 616
	_noise.frequency = 0.15
	_noise.fractal_octaves = 3
	# keep trees, rocks and gather piles off the outcrop
	var a := -ALONG
	while a <= ALONG:
		var d := 8.0
		while d <= D_MAX - 4.0:
			if _add(a, d) > 0.5:
				var p := _world_xz(a, d)
				w._occupy(p.x, p.y, 3.5)
			d += 5.0
		a += 5.0
	_build_outcrop()
	_build_water()
	_build_spray()


func _world_xz(along: float, d: float) -> Vector2:
	return _c + _t * along + _n * d


## Face foot distance from the river centre: an alcove at the middle where the water falls, wrapping round at the
## ends of the wall.
func _foot_d(along: float) -> float:
	return 9.0 + 2.6 * pow(clampf(absf(along) / 14.0, 0.0, 1.0), 2.0) - 0.8 * exp(-pow(along / 4.0, 2.0))


## Height added on top of the terrain at (along, d).
func _add(along: float, d: float) -> float:
	var foot_d := _foot_d(along) + _noise.get_noise_2d(along * 0.6, 3.0) * 1.4
	var rise := smoothstep(foot_d, foot_d + 1.6, d)
	var back := 1.0 - smoothstep(30.0, 36.0, d + _noise.get_noise_2d(along * 0.4, 11.0) * 3.0)
	var ends := 1.0 - smoothstep(15.0, 19.0, absf(along) + _noise.get_noise_2d(d * 0.4, 7.0) * 2.0)
	var h := HEIGHT * rise * back * ends
	# rugged top and ledges on the face
	h += (_noise.get_noise_2d(along, d) * 1.2 + _noise.get_noise_2d(along * 3.0, d * 3.0) * 0.35) * smoothstep(0.5, 3.0, h)
	# buttresses and gullies down the face: the wall steps in and out along the river
	h += _noise.get_noise_2d(along * 1.8, 40.0) * 2.5 * (smoothstep(foot_d, foot_d + 1.6, d) - smoothstep(foot_d + 1.6, foot_d + 5.0, d))
	# the creek's channel across the plateau, notching the lip
	var notch := (1.0 - smoothstep(1.5, 3.0, absf(along))) * smoothstep(foot_d + 0.8, foot_d + 2.2, d)
	h -= NOTCH * notch * smoothstep(2.0, 6.0, h)
	return maxf(h, 0.0)


func _vertex(along: float, d: float) -> Vector3:
	var p := _world_xz(along, d)
	var add := _add(along, d)
	var y := world.height_at(p.x, p.y) + add - (0.25 if add < 0.3 else 0.0)  # tuck the fringe under the terrain
	return Vector3(p.x, y, p.y)


func _build_outcrop() -> void:
	var na := int(ALONG * 2.0 / CELL) + 1
	var nd := int((D_MAX - D_MIN) / CELL) + 1
	var verts := PackedVector3Array()
	verts.resize(na * nd)
	var adds := PackedFloat32Array()
	adds.resize(na * nd)
	for i in na:
		for j in nd:
			var along := -ALONG + i * CELL
			var d := D_MIN + j * CELL
			verts[i * nd + j] = _vertex(along, d)
			adds[i * nd + j] = _add(along, d)
	# normals from the grid (always facing up/outward), indexed triangles
	var normals := PackedVector3Array()
	normals.resize(na * nd)
	for i in na:
		for j in nd:
			var pa := verts[mini(i + 1, na - 1) * nd + j] - verts[maxi(i - 1, 0) * nd + j]
			var pd := verts[i * nd + mini(j + 1, nd - 1)] - verts[i * nd + maxi(j - 1, 0)]
			var nrm := pa.cross(pd).normalized()
			normals[i * nd + j] = -nrm if nrm.y < 0.0 else nrm
	var idx := PackedInt32Array()
	for i in na - 1:
		for j in nd - 1:
			var k := i * nd + j
			if maxf(maxf(adds[k], adds[k + 1]), maxf(adds[k + nd], adds[k + nd + 1])) < 0.05:
				continue
			var tri := [k, k + nd, k + 1, k + 1, k + nd, k + nd + 1]
			var face := (verts[k + nd] - verts[k]).cross(verts[k + 1] - verts[k])
			if face.dot(normals[k]) < 0.0:
				tri = [k, k + 1, k + nd, k + 1, k + nd + 1, k + nd]
			idx.append_array(tri)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "Outcrop"
	mi.mesh = mesh
	var m := ShaderMaterial.new()
	m.shader = preload("res://world/shaders/cliff.gdshader")
	var tm: ShaderMaterial = world._terrain_mat
	m.set_shader_parameter("albedo_tex", tm.get_shader_parameter("albedo_tex"))
	m.set_shader_parameter("normal_tex", tm.get_shader_parameter("normal_tex"))
	m.set_shader_parameter("noise_tex", tm.get_shader_parameter("macro_noise"))
	mi.material_override = m
	add_child(mi)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	cs.shape = mesh.create_trimesh_shape()
	body.add_child(cs)
	add_child(body)
	# the lip (where the creek pours over) and the foot of the fall
	var lip_d := _foot_d(0.0) + 1.7
	var lv := _vertex(0.0, lip_d)
	lip = Vector3(lv.x, lv.y + 0.15, lv.z)
	var fp := _world_xz(0.0, _foot_d(0.0) - 2.2)
	foot = Vector3(fp.x, ForestWorld.WATER_LEVEL, fp.y)
	m.set_shader_parameter("fall_point", lip)
	m.set_shader_parameter("fall_bottom", foot)


func _ribbon(points: PackedVector3Array, widths: PackedFloat32Array, across: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var total := 0.0
	var dist := PackedFloat32Array([0.0])
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
		dist.append(total)
	for i in points.size() - 1:
		var a := points[i]
		var b := points[i + 1]
		var wa := across * widths[i] * 0.5
		var wb := across * widths[i + 1] * 0.5
		var va := dist[i] / total
		var vb := dist[i + 1] / total
		for v: Array in [[a - wa, 0.0, va], [a + wa, 1.0, va], [b - wb, 0.0, vb], [b - wb, 0.0, vb], [a + wa, 1.0, va], [b + wb, 1.0, vb]]:
			st.set_uv(Vector2(v[1], v[2]))
			st.set_normal(Vector3.UP)
			st.add_vertex(v[0])
	return st.commit()


func _water_mesh(mesh: ArrayMesh, speed: float, white: float, length_m: float, nm: String) -> void:
	var m := ShaderMaterial.new()
	m.shader = preload("res://world/shaders/falling_water.gdshader")
	m.set_shader_parameter("noise_tex", world._terrain_mat.get_shader_parameter("macro_noise"))
	m.set_shader_parameter("speed", speed)
	m.set_shader_parameter("whiteness", white)
	m.set_shader_parameter("length_m", length_m)
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_water() -> void:
	var across := Vector3(_t.x, 0.0, _t.y)
	# the creek: from the back of the plateau down its channel to the lip
	var creek := PackedVector3Array()
	var cw := PackedFloat32Array()
	var lip_d := _foot_d(0.0) + 1.7
	var d := 30.0
	while d > lip_d:
		var v := _vertex(0.0, d)
		creek.append(v + Vector3.UP * 0.12)
		cw.append(2.8)
		d -= 1.0
	creek.append(lip)
	cw.append(3.2)
	_water_mesh(_ribbon(creek, cw, across), 1.2, 0.15, 20.0, "Creek")
	# the fall: thrown a little out from the lip, then straight down into the river
	var fall := PackedVector3Array()
	var fw := PackedFloat32Array()
	var out := Vector3(-_n.x, 0.0, -_n.y)
	var drop := lip.y - ForestWorld.WATER_LEVEL + 0.3
	for i in 17:
		var s := i / 16.0
		fall.append(lip + out * (1.9 * sqrt(s) + 0.2) - Vector3.UP * drop * s * s * 0.15 - Vector3.UP * drop * s * 0.85)
		fw.append(lerpf(3.2, 5.0, s))
	_water_mesh(_ribbon(fall, fw, across), 3.2, 1.0, drop, "Fall")
	# drinkable / fishable creek
	var mid := _vertex(0.0, lip_d + 7.0)
	var wb := WaterBody.new()
	wb.setup(2.4, mid.y + 0.12, 12.0)
	wb.position = Vector3(mid.x, 0.0, mid.z)
	wb.rotation.y = atan2(_n.x, _n.y)
	add_child(wb)


func _build_spray() -> void:
	var p := GPUParticles3D.new()
	p.name = "Spray"
	p.amount = 60
	p.lifetime = 3.5
	p.preprocess = 3.5
	p.position = foot + Vector3.UP * 0.3
	p.visibility_aabb = AABB(Vector3(-12, -2, -12), Vector3(24, 14, 24))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 1.4
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 70.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 2.2
	pm.gravity = Vector3(0, 0.15, 0.25)  # mist lifts and drifts downstream
	pm.damping_min = 0.3
	pm.damping_max = 0.8
	pm.scale_min = 1.0
	pm.scale_max = 2.6
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.45), Color(1, 1, 1, 0.0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	pm.color_ramp = ramp
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(2.2, 2.2)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.albedo_color = Color(0.92, 0.95, 0.97)
	var dot := GradientTexture2D.new()
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(0.5, 0.0)
	var dg := Gradient.new()
	dg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	dot.gradient = dg
	m.albedo_texture = dot
	quad.material = m
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)


## Where white water forms on the river: [x, z, radius] for water.gdshader.
func rapids() -> Vector4:
	return Vector4(foot.x, foot.z, 7.0, 1.0)
