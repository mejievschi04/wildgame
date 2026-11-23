class_name MeadowGrass
extends Node3D
## Dense short grass and wildflower clusters around the camera, drawn by two MultiMeshes whose instances wrap
## around the camera in the vertex shader (meadow_grass.gdshader). Cheap: a tuft is ~21 triangles and nothing
## is rebuilt while walking — only the list of bare spots (fires, buildings) is refreshed every second.

const SPACING := {0: 0.5, 1: 0.4, 2: 0.32}   # tuft grid spacing by video quality (low / medium / high)
const RADIUS := {0: 15.0, 1: 22.0, 2: 30.0}
const FLOWER_SPACING := 1.25
const BARE_SLOTS := 12
const FLOWER_COLORS := [Color(0.95, 0.78, 0.16), Color(0.96, 0.95, 0.88), Color(0.58, 0.36, 0.82), Color(0.36, 0.5, 0.92),
	Color(0.92, 0.45, 0.2)]

var world: ForestWorld
var _grass: MultiMeshInstance3D
var _flowers: MultiMeshInstance3D
var _fronds: MultiMeshInstance3D
var _frond_material: ShaderMaterial
var _material: ShaderMaterial
var _flower_material: ShaderMaterial
var _bare_t := 0.0
var _quality := -1


func build(w: ForestWorld, heights: PackedFloat32Array, forest_mask: Image, macro_tex: Texture2D) -> void:
	world = w
	var row := ForestWorld.GRID + 1
	var img := Image.create_from_data(row, row, false, Image.FORMAT_RF, heights.to_byte_array())
	var height_tex := ImageTexture.create_from_image(img)
	var mask_tex := ImageTexture.create_from_image(_grass_mask(heights, forest_mask, 1.15))
	var flower_mask_tex := ImageTexture.create_from_image(_grass_mask(heights, forest_mask, 1.6))
	var shader: Shader = preload("res://world/shaders/meadow_grass.gdshader")
	_material = ShaderMaterial.new()
	_material.shader = shader
	for m: ShaderMaterial in [_material]:
		m.set_shader_parameter("height_tex", height_tex)
		m.set_shader_parameter("grass_mask", mask_tex)
		m.set_shader_parameter("macro_noise", macro_tex)
		m.set_shader_parameter("half_size", ForestWorld.HALF)
		m.set_shader_parameter("cell", ForestWorld.CELL_SIZE)
		m.set_shader_parameter("grid", ForestWorld.GRID)
		m.set_shader_parameter("map_size", ForestWorld.SIZE)
		m.set_shader_parameter("water_level", ForestWorld.WATER_LEVEL)
	_flower_material = _material.duplicate() as ShaderMaterial
	_flower_material.set_shader_parameter("flowers", true)
	_flower_material.set_shader_parameter("grass_mask", flower_mask_tex)
	# Forest floor: broad arching fronds (fern, sedge) in deep greens where the trees are.
	_frond_material = _material.duplicate() as ShaderMaterial
	_frond_material.set_shader_parameter("grass_mask", ImageTexture.create_from_image(_grass_mask(heights, forest_mask, 1.0, true)))
	_frond_material.set_shader_parameter("lush", Color(0.07, 0.13, 0.04))
	_frond_material.set_shader_parameter("dry", Color(0.16, 0.15, 0.06))
	_rebuild()
	Settings.changed.connect(func(_s: String, _k: String) -> void: _rebuild())


## Per terrain vertex: 1 on dry, gentle ground, 0 in water and on steep rock, thinned by the forest mask.
static func _grass_mask(heights: PackedFloat32Array, forest: Image, thin: float, under_trees := false) -> Image:
	var row := ForestWorld.GRID + 1
	var img := Image.create_empty(row, row, false, Image.FORMAT_L8)
	var cell := ForestWorld.CELL_SIZE
	for iz in row:
		for ix in row:
			var h := heights[iz * row + ix]
			var hx := heights[iz * row + mini(ix + 1, row - 1)]
			var hz := heights[mini(iz + 1, row - 1) * row + ix]
			var slope := Vector2(hx - h, hz - h).length() / cell
			var f := 0.0
			if forest:
				var fx := clampi(int(float(ix) / row * forest.get_width()), 0, forest.get_width() - 1)
				var fz := clampi(int(float(iz) / row * forest.get_height()), 0, forest.get_height() - 1)
				f = forest.get_pixel(fx, fz).r
			var cover := smoothstep(0.2, 0.65, f) if under_trees else clampf(1.0 - f * thin, 0.0, 1.0)
			var v := cover * clampf((h - ForestWorld.WATER_LEVEL - 0.3) * 2.0, 0.0, 1.0) \
				* (1.0 - smoothstep(0.55, 0.8, slope))
			img.set_pixel(ix, iz, Color(v, v, v))
	return img


func _rebuild() -> void:
	var q := clampi(int(Settings.get_value("video", "quality")), 0, 2)
	if q == _quality:
		return
	_quality = q
	for n in [_grass, _flowers, _fronds]:
		if is_instance_valid(n):
			n.queue_free()
	var radius: float = RADIUS[q]
	_material.set_shader_parameter("radius", radius)
	_flower_material.set_shader_parameter("radius", radius)
	_frond_material.set_shader_parameter("radius", radius)
	_grass = _field(_tuft_mesh(), float(SPACING[q]), radius, _material, false)
	_flowers = _field(_flower_mesh(), FLOWER_SPACING, radius, _flower_material, true)
	_fronds = _field(_frond_mesh(), float(SPACING[q]) * 2.0, radius, _frond_material, false)


func _field(mesh: Mesh, spacing: float, radius: float, material: ShaderMaterial, colored: bool) -> MultiMeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = ForestWorld.SEED + (911 if colored else 409)
	var n := int(ceil(radius * 2.0 / spacing))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = colored
	mm.mesh = mesh
	mm.instance_count = n * n
	for iz in n:
		for ix in n:
			var i := iz * n + ix
			var p := Vector3(-radius + (ix + rng.randf()) * spacing, 0.0, -radius + (iz + rng.randf()) * spacing)
			var s := rng.randf_range(0.8, 1.2)
			mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.75, 1.2), s)), p))
			if colored:
				mm.set_instance_custom_data(i, FLOWER_COLORS[rng.randi() % FLOWER_COLORS.size()])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Positions are made in the shader around the camera: never frustum-cull the field as a whole.
	mmi.custom_aabb = AABB(Vector3(-ForestWorld.HALF, -200.0, -ForestWorld.HALF), Vector3(ForestWorld.SIZE, 600.0, ForestWorld.SIZE))
	add_child(mmi)
	return mmi


## A tuft of 12 thin tapering blades (root at y=0), UV.y = 0 at the root … 1 at the tip, vertex colour 0 (not a flower).
static func _tuft_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for b in 12:
		_blade_id = (b + 0.5) / 12.0
		var a := rng.randf() * TAU
		var root := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.0, 0.16)
		var lean := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.04, 0.12)
		var hgt := rng.randf_range(0.12, 0.3)
		var face := rng.randf() * TAU
		_blade(st, root, lean, hgt, rng.randf_range(0.007, 0.012), face, Color(0, 0, 0))
	st.index()  # shared vertices: the vertex shader's per-tuft work runs ~40 % fewer times
	st.generate_normals()
	return st.commit()


## 12 fronds arching low and out, drooping at the tip (fern / sedge); blade ids for the LOD like the tufts.
static func _frond_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	for b in 12:
		_blade_id = (b + 0.5) / 12.0
		var a := TAU * b / 12.0 + rng.randf() * 0.4
		var out := Vector3(cos(a), 0, sin(a))
		var side := Vector3(-sin(a), 0, cos(a))
		var reach := rng.randf_range(0.28, 0.5)
		var rise := rng.randf_range(0.06, 0.16)
		var w := rng.randf_range(0.028, 0.045)
		var pts: Array = []
		for i in 6:
			var t := i / 5.0
			var p := out * reach * t + Vector3(0, rise * sin(PI * t * 0.85), 0)
			var width := w * sin(PI * clampf(t * 1.1, 0.0, 1.0)) + 0.003
			pts.append([p - side * width, p + side * width, t])
		for i in 5:
			var p0: Array = pts[i]
			var p1: Array = pts[i + 1]
			for v: Array in [[p0[0], p0[2]], [p0[1], p0[2]], [p1[0], p1[2]], [p0[1], p0[2]], [p1[1], p1[2]], [p1[0], p1[2]]]:
				st.set_color(Color(0, 0, 0))
				st.set_uv(Vector2(_blade_id, minf(v[1] * 1.4, 1.0)))
				st.add_vertex(v[0])
	st.index()
	st.generate_normals()
	return st.commit()


## A few grass blades and 3 stems with small flower heads (vertex colour 1 = take the instance's flower colour).
static func _flower_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	_blade_id = 0.0
	for b in 4:
		var a := rng.randf() * TAU
		_blade(st, Vector3(cos(a), 0, sin(a)) * 0.06, Vector3(cos(a), 0, sin(a)) * 0.08, rng.randf_range(0.18, 0.3), 0.022, rng.randf() * TAU, Color(0, 0, 0))
	for k in 3:
		var a := TAU * k / 3.0 + rng.randf() * 0.8
		var base := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.03, 0.12)
		var top := base + Vector3(cos(a) * 0.05, rng.randf_range(0.3, 0.45), sin(a) * 0.05)
		_blade(st, base, top - base - Vector3(0, top.y - base.y, 0), top.y - base.y, 0.008, rng.randf() * TAU, Color(0, 0, 0))
		# head: a small four-petal star facing up and a little sideways
		var r := rng.randf_range(0.028, 0.04)
		for p in 4:
			var pa := TAU * p / 4.0 + a
			var tip := top + Vector3(cos(pa), 0.25, sin(pa)) * r
			var side := Vector3(-sin(pa), 0, cos(pa)) * r * 0.45
			for v in [top, tip + side, tip - side]:
				st.set_color(Color(1, 1, 1))
				st.set_uv(Vector2(0, 1))
				st.add_vertex(v)
	st.index()
	st.generate_normals()
	return st.commit()


static var _blade_id := 0.0  # 0…1 per blade of a tuft (UV.x): the shader drops high ids with distance (LOD)


static func _blade(st: SurfaceTool, root: Vector3, lean: Vector3, hgt: float, width: float, face: float, col: Color) -> void:
	var side := Vector3(cos(face), 0, sin(face)) * width
	var mid := root + lean * 0.35 + Vector3(0, hgt * 0.55, 0)
	var tip := root + lean + Vector3(0, hgt, 0)
	var pts := [[root - side, 0.0], [root + side, 0.0], [mid - side * 0.7, 0.55], [mid + side * 0.7, 0.55], [tip, 1.0]]
	for tri in [[0, 1, 2], [1, 3, 2], [2, 3, 4]]:
		for k: int in tri:
			st.set_color(col)
			st.set_uv(Vector2(_blade_id, pts[k][1]))
			st.add_vertex(pts[k][0])


func _process(delta: float) -> void:
	if world == null:
		return
	_bare_t -= delta
	if _bare_t > 0.0:
		return
	_bare_t = 1.0
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var at := cam.global_position
	var spots: Array = []
	for n: Node3D in get_tree().get_nodes_in_group("campfire"):
		spots.append([n.global_position, 1.4])
	for n: Node3D in get_tree().get_nodes_in_group("building"):
		spots.append([n.global_position, 2.2])
	spots = spots.filter(func(s: Array) -> bool: return (s[0] as Vector3).distance_to(at) < RADIUS[2] + 6.0)
	spots.sort_custom(func(a: Array, b: Array) -> bool: return (a[0] as Vector3).distance_to(at) < (b[0] as Vector3).distance_to(at))
	var arr := PackedVector4Array()
	arr.resize(BARE_SLOTS)
	for i in mini(spots.size(), BARE_SLOTS):
		var p: Vector3 = spots[i][0]
		arr[i] = Vector4(p.x, p.z, spots[i][1], 0.0)
	for m: ShaderMaterial in [_material, _flower_material, _frond_material]:
		m.set_shader_parameter("bare", arr)
	if world.weather:
		var wd: Vector2 = world.weather.wind_dir
		var strength := 0.25 + 0.5 * world.weather.wind
		for m: ShaderMaterial in [_material, _flower_material, _frond_material]:
			m.set_shader_parameter("wind_dir", wd.normalized())
			m.set_shader_parameter("wind_strength", strength)
