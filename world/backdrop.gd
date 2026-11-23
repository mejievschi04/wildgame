class_name Backdrop
extends Node3D
## The world's borders, beyond the playable map (out to ±EXTENT m): a high snowy range closes the north, wooded
## hills run east and west, and to the south dark volcanic lowlands rise into four volcanoes — the largest one
## smoking, with lava glowing in its gullies at night. One heightfield mesh (fine 40 m cells near the map,
## coarser further out) computed on a worker thread; it meets the terrain at the map's edge and slips under it.
## Its shader hazes it toward the sky colour itself, so it stays visible ~10 km away.

const EXTENT := 11000.0
const FINE := 40.0
const FINE_TO := 3800.0
const INNER := 2100.0  # = ForestWorld.HALF: the terrain mesh covers everything inside
## [x, z, height, radius, crater radius, smoke]  (south = +z)
const VOLCANOES := [
	[900.0, 5400.0, 2700.0, 3900.0, 380.0, 1.0],
	[-1500.0, 3900.0, 1800.0, 2700.0, 240.0, 0.25],
	[3100.0, 3600.0, 1350.0, 2300.0, 200.0, 0.0],
	[-3700.0, 3200.0, 1100.0, 2000.0, 170.0, 0.0],
]

var world: ForestWorld
var _mesh_inst: MeshInstance3D
var _material: ShaderMaterial
var _smoke: Array[ShaderMaterial] = []
var _task := -1
var _abort := false
var _ridged: FastNoiseLite
var _warp: FastNoiseLite


func build(w: ForestWorld) -> void:
	world = w
	if DisplayServer.get_name() == "headless":
		return
	_ridged = FastNoiseLite.new()
	_ridged.seed = ForestWorld.SEED + 3131
	_ridged.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	_ridged.frequency = 0.00032
	_ridged.fractal_octaves = 5
	_ridged.fractal_gain = 0.42
	_warp = FastNoiseLite.new()
	_warp.seed = ForestWorld.SEED + 3132
	_warp.frequency = 0.00025
	var noise := NoiseTexture2D.new()
	noise.width = 512
	noise.height = 512
	noise.seamless = true
	noise.generate_mipmaps = true
	var nl := FastNoiseLite.new()
	nl.seed = ForestWorld.SEED + 3133
	nl.frequency = 0.02
	nl.fractal_octaves = 4
	noise.noise = nl
	_material = ShaderMaterial.new()
	_material.shader = preload("res://world/shaders/backdrop.gdshader")
	_material.set_shader_parameter("noise_tex", noise)
	for v: Array in VOLCANOES:
		if float(v[5]) <= 0.0:
			continue
		var m := ShaderMaterial.new()
		m.shader = preload("res://world/shaders/volcano_smoke.gdshader")
		m.set_shader_parameter("noise_tex", noise)
		m.set_shader_parameter("strength", float(v[5]))
		m.set_shader_parameter("height", 2600.0 * float(v[5]) + 600.0)
		m.set_shader_parameter("width_base", 120.0 + 260.0 * float(v[5]))
		m.set_shader_parameter("width_top", 500.0 + 1300.0 * float(v[5]))
		_smoke.append(m)
		var plume := MeshInstance3D.new()
		plume.mesh = _plume_mesh()
		plume.material_override = m
		plume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		plume.custom_aabb = AABB(Vector3(-4000, -100, -4000), Vector3(8000, 6000, 8000))
		plume.name = "VolcanoSmoke"
		add_child(plume)
		plume.position = Vector3(float(v[0]), _volcano_top(v), float(v[1]))
	_task = WorkerThreadPool.add_task(_compute, false, "Backdrop")


static func _plume_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows := 24
	for i in rows:
		var t0 := float(i) / rows
		var t1 := float(i + 1) / rows
		for q: Vector2 in [Vector2(0, t0), Vector2(1, t0), Vector2(1, t1), Vector2(0, t0), Vector2(1, t1), Vector2(0, t1)]:
			st.set_uv(q)
			st.add_vertex(Vector3(q.x - 0.5, q.y, 0.0))
	return st.commit()


## Grid coordinates along one axis: 40 m steps out to FINE_TO, then growing steps out to EXTENT.
static func _axis() -> PackedFloat32Array:
	var half := PackedFloat32Array()
	var c := 0.0
	var step := FINE
	while c < EXTENT:
		half.append(c)
		if c >= FINE_TO:
			step *= 1.07
		c += step
	half.append(EXTENT)
	var out := PackedFloat32Array()
	for i in range(half.size() - 1, 0, -1):
		out.append(-half[i])
	out.append_array(half)
	return out


func _volcano_top(v: Array) -> float:
	return float(v[2]) * pow(1.0 - float(v[4]) / float(v[3]), 1.7) + 140.0


## Height of the backdrop at (x, z) and its masks [north, south, crater].
func _height(x: float, z: float) -> Array:
	var cheb := maxf(absf(x), absf(z))
	var edge := world._terrain_height(clampf(x, -INNER, INNER), clampf(z, -INNER, INNER))
	if cheb <= INNER:  # the overlap ring under the terrain's edge, tucked a little lower inward
		return [world._terrain_height(x, z) - 25.0 * smoothstep(0.0, 60.0, INNER - cheb), 0.0, 0.0, 0.0, 0.0]
	var e := cheb - INNER
	var nz := -z / cheb  # +1 along the whole north side, −1 along the south
	var wn := smoothstep(0.45, 0.95, nz)
	var ws := smoothstep(0.45, 0.95, -nz)
	var wx := x + _warp.get_noise_2d(x, z) * 900.0
	var wz := z + _warp.get_noise_2d(z, x) * 900.0
	var ridge := _ridged.get_noise_2d(wx, wz) * 0.5 + 0.5
	var rise := smoothstep(0.0, 2200.0, e)
	var north := rise * (800.0 + 1500.0 * ridge * ridge) + 80.0 * ridge * rise
	var sides := rise * (250.0 + 650.0 * ridge * ridge)
	var southl := rise * (90.0 + 260.0 * ridge)
	var h := lerpf(lerpf(sides, north, wn), southl, ws)
	var crater := 0.0
	var around := 0.0  # angle around the nearest crater (0..1), seam facing away from the map
	for v: Array in VOLCANOES:
		var d := Vector2(x - float(v[0]), z - float(v[1])).length()
		var r := float(v[3])
		if d >= r:
			continue
		var ang := atan2(x - float(v[0]), z - float(v[1]))
		var gully := 1.0 + 0.05 * sin(ang * 23.0 + ridge * 6.0) * (d / r)
		var top := float(v[2]) * pow(1.0 - float(v[4]) / r, 1.7)
		var cone := float(v[2]) * pow(1.0 - d / r, 1.7) * gully
		var cr := float(v[4])
		if d < cr:
			cone = top - 0.35 * cr * (1.0 - pow(d / cr, 2.0))  # the crater bowl
		h = maxf(h, cone + 140.0 * smoothstep(0.0, 1.0, 1.0 - d / r))
		var near := 1.0 - smoothstep(cr * 0.6, cr * 4.0, d)
		if near > crater:
			crater = near
			around = atan2(-(x - float(v[0])), -(z - float(v[1]))) / TAU + 0.5
	# meet the terrain's edge height and keep climbing from there
	return [edge + h, wn, ws, crater, around]


func _compute() -> void:
	var ax := _axis()
	var n := ax.size()
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(n * n)
	cols.resize(n * n)
	for iz in n:
		if _abort:
			return
		for ix in n:
			var x := ax[ix]
			var z := ax[iz]
			var r: Array = _height(x, z)
			verts[iz * n + ix] = Vector3(x, r[0], z)
			cols[iz * n + ix] = Color(r[1], r[2], r[3], r[4])
	var normals := PackedVector3Array()
	normals.resize(n * n)
	for iz in n:
		for ix in n:
			var l := verts[iz * n + maxi(ix - 1, 0)]
			var rr := verts[iz * n + mini(ix + 1, n - 1)]
			var d := verts[maxi(iz - 1, 0) * n + ix]
			var u := verts[mini(iz + 1, n - 1) * n + ix]
			normals[iz * n + ix] = (u - d).cross(rr - l).normalized()
	var idx := PackedInt32Array()
	for iz in n - 1:
		for ix in n - 1:
			# skip cells wholly inside the terrain (keep a 60 m overlap ring under its edge)
			var cx := maxf(absf(ax[ix]), absf(ax[ix + 1]))
			var cz := maxf(absf(ax[iz]), absf(ax[iz + 1]))
			if cx < INNER - 60.0 and cz < INNER - 60.0:
				continue
			var a := iz * n + ix
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	if not _abort:
		_finish.call_deferred(arrays)


func _finish(arrays: Array) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if not is_inside_tree():
		return
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.name = "Mountains"
	_mesh_inst.mesh = mesh
	_mesh_inst.material_override = _material
	_mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_inst)


func _process(_delta: float) -> void:
	if world == null or _material == null or world.day_night == null:
		return
	var dn := world.day_night
	var env := dn.environment
	var day := smoothstep(-0.08, 0.3, dn.sun_elevation())
	var haze_col: Color = env.fog_light_color
	var dens := env.fog_density
	var far_dens := clampf(env.fog_density * 0.22, 0.00004, 0.00012)
	var glow := lerpf(4.0, 0.2, day)
	_material.set_shader_parameter("haze_color", haze_col)
	_material.set_shader_parameter("haze_density", dens)
	_material.set_shader_parameter("haze_far_density", far_dens)
	_material.set_shader_parameter("haze_energy", lerpf(0.25, 1.0, day))
	_material.set_shader_parameter("lava_glow", glow)
	var light := (dn.sun.light_color * clampf(dn.sun.light_energy * 0.5, 0.0, 1.0)).lerp(Color(0.12, 0.14, 0.2), 1.0 - day)
	var wd := world.weather.wind_dir.normalized() if world.weather else Vector2(0.8, 0.6)
	for m in _smoke:
		m.set_shader_parameter("haze_color", haze_col * lerpf(0.25, 1.0, day))
		m.set_shader_parameter("haze_density", far_dens)
		m.set_shader_parameter("lava_glow", glow)
		m.set_shader_parameter("light", light)
		m.set_shader_parameter("drift", wd * 1400.0)


func _exit_tree() -> void:
	_abort = true
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
