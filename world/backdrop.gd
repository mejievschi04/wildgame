class_name Backdrop
extends Node3D
## The world's borders, beyond the playable map (out to ±EXTENT m): a high snowy range closes the north, wooded
## hills run east and west, and to the south dark volcanic lowlands rise into four volcanoes — the largest one
## smoking, with lava glowing in its gullies at night.
## The relief is baked offline with hydraulic erosion (tools/gen_backdrop.py → assets/textures/backdrop): height
## above the map's edge, water flow, sediment, normals and AO. At start-up a worker thread turns it into one mesh
## (40 m cells near the map, coarser further out) standing on the terrain's edge heights, plus an absolute-height
## texture the shader marches over for terrain shadows. Its shader hazes it itself, so it stays visible ~10 km away.

const EXTENT := 11000.0
const FINE := 40.0
const FINE_TO := 3800.0
const INNER := 2100.0  # = ForestWorld.HALF: the terrain mesh covers everything inside
const HMAX := 6000.0   # gen_backdrop.py HMAX: 16-bit height range
const HM_PATH := "res://assets/textures/backdrop/T_Backdrop_HM.png"
const N_PATH := "res://assets/textures/backdrop/T_Backdrop_N.png"
## [x, z, height, radius, crater radius, smoke]  (south = +z) — keep in sync with gen_backdrop.py
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
var _plumes: Array[MeshInstance3D] = []
var _task := -1
var _abort := false
var _n := 0
var _bake := PackedFloat32Array()   # height above the map edge, n×n, row = z


func build(w: ForestWorld) -> void:
	world = w
	if DisplayServer.get_name() == "headless" or not ResourceLoader.exists(HM_PATH):
		return
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
	var hm: Texture2D = load(HM_PATH)
	_material = ShaderMaterial.new()
	_material.shader = preload("res://world/shaders/backdrop.gdshader")
	_material.set_shader_parameter("noise_tex", noise)
	_material.set_shader_parameter("hm_tex", hm)
	_material.set_shader_parameter("n_tex", load(N_PATH))
	_material.set_shader_parameter("extent", EXTENT)
	_material.set_shader_parameter("map_half", INNER)
	if world._terrain_mat:
		_material.set_shader_parameter("rock_tex", world._terrain_mat.get_shader_parameter("albedo_tex"))
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
		plume.visible = false  # placed once the heights are in
		plume.set_meta("volcano", v)
		add_child(plume)
		_plumes.append(plume)
	var img := hm.get_image()
	if img.is_compressed():
		img.decompress()
	img.clear_mipmaps()
	img.convert(Image.FORMAT_RGBA8)
	_task = WorkerThreadPool.add_task(_compute.bind(img), false, "Backdrop")


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


func _texel(c: float) -> float:
	return (c + EXTENT) / (2.0 * EXTENT) * (_n - 1)


## Baked mountain height above the edge at (x, z), bilinear.
func _bake_at(x: float, z: float) -> float:
	var gx := clampf(_texel(x), 0.0, _n - 1.001)
	var gz := clampf(_texel(z), 0.0, _n - 1.001)
	var ix := int(gx)
	var iz := int(gz)
	var fx := gx - ix
	var fz := gz - iz
	var a := iz * _n + ix
	return lerpf(lerpf(_bake[a], _bake[a + 1], fx), lerpf(_bake[a + _n], _bake[a + _n + 1], fx), fz)


## Height of the terrain's edge seen from (x, z): the terrain height at the nearest point of the map square.
func _edge(x: float, z: float) -> float:
	return world._terrain_height(clampf(x, -INNER, INNER), clampf(z, -INNER, INNER))


func _masks(x: float, z: float) -> Color:
	var cheb := maxf(absf(x), absf(z))
	var nz := -z / maxf(cheb, 1.0)
	var crater := 0.0
	for v: Array in VOLCANOES:
		var d := Vector2(x - float(v[0]), z - float(v[1])).length()
		var cr := float(v[4])
		crater = maxf(crater, 1.0 - smoothstep(cr * 0.6, cr * 4.0, d))
	return Color(smoothstep(0.45, 0.95, nz), smoothstep(0.45, 0.95, -nz), crater, 1.0)


func _compute(img: Image) -> void:
	_n = img.get_width()
	var data := img.get_data()
	_bake.resize(_n * _n)
	for i in _n * _n:
		_bake[i] = float(data[i * 4] * 256 + data[i * 4 + 1]) / 65535.0 * HMAX
	if _abort:
		return
	# absolute heights for the shadow march: baked height + the edge it stands on (inside the map ~ the terrain)
	var en := PackedFloat32Array(); en.resize(_n)
	var es := PackedFloat32Array(); es.resize(_n)
	var ee := PackedFloat32Array(); ee.resize(_n)
	var ew := PackedFloat32Array(); ew.resize(_n)
	for i in _n:
		var c := -EXTENT + 2.0 * EXTENT * i / (_n - 1)
		en[i] = _edge(c, -INNER - 1.0)
		es[i] = _edge(c, INNER + 1.0)
		ew[i] = _edge(-INNER - 1.0, c)
		ee[i] = _edge(INNER + 1.0, c)
	var abs_h := PackedFloat32Array()
	abs_h.resize(_n * _n)
	for iz in _n:
		var z := -EXTENT + 2.0 * EXTENT * iz / (_n - 1)
		for ix in _n:
			var x := -EXTENT + 2.0 * EXTENT * ix / (_n - 1)
			var e := 60.0
			if absf(x) > INNER or absf(z) > INNER:
				if absf(z) >= absf(x):
					e = en[ix] if z < 0.0 else es[ix]
				else:
					e = ew[iz] if x < 0.0 else ee[iz]
			abs_h[iz * _n + ix] = _bake[iz * _n + ix] + e
	if _abort:
		return
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
			var cheb := maxf(absf(x), absf(z))
			var y: float
			if cheb <= INNER:  # the overlap ring under the terrain's edge, tucked a little lower inward
				y = world._terrain_height(x, z) - 25.0 * smoothstep(0.0, 60.0, INNER - cheb)
			else:
				y = _edge(x, z) + _bake_at(x, z)
			verts[iz * n + ix] = Vector3(x, y, z)
			cols[iz * n + ix] = _masks(x, z)
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
		_finish.call_deferred(arrays, abs_h)


func _finish(arrays: Array, abs_h: PackedFloat32Array) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if not is_inside_tree():
		return
	var himg := Image.create_from_data(_n, _n, false, Image.FORMAT_RF, abs_h.to_byte_array())
	_material.set_shader_parameter("height_tex", ImageTexture.create_from_image(himg))
	_material.set_shader_parameter("texels", float(_n))
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_inst = MeshInstance3D.new()
	_mesh_inst.name = "Mountains"
	_mesh_inst.mesh = mesh
	_mesh_inst.material_override = _material
	_mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_inst)
	for p in _plumes:
		var v: Array = p.get_meta("volcano")
		p.position = Vector3(float(v[0]), _edge(float(v[0]), float(v[1])) + _bake_at(float(v[0]), float(v[1])) - 60.0, float(v[1]))
		p.visible = true


func _process(_delta: float) -> void:
	if world == null or _material == null or world.day_night == null:
		return
	var dn := world.day_night
	var env := dn.environment
	var day := smoothstep(-0.08, 0.3, dn.sun_elevation())
	var haze_col: Color = env.fog_light_color
	var dens := env.fog_density * 0.65
	var far_dens := clampf(env.fog_density * 0.22, 0.00004, 0.00012)
	var glow := lerpf(4.0, 0.2, day)
	_material.set_shader_parameter("haze_color", haze_col)
	_material.set_shader_parameter("haze_density", dens)
	_material.set_shader_parameter("haze_far_density", far_dens)
	_material.set_shader_parameter("haze_energy", lerpf(0.25, 1.0, day))
	_material.set_shader_parameter("lava_glow", glow)
	_material.set_shader_parameter("sun_dir", dn.sun.global_transform.basis.z)
	var h := dn.time_hours
	var morning := clampf(1.0 - absf(h - 7.0) / 3.0, 0.0, 1.0)
	_material.set_shader_parameter("mist", 0.18 + 0.35 * morning)
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
