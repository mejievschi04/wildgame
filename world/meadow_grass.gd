class_name MeadowGrass
extends Node3D
## Meadow grass around the camera: one MultiMesh of 3-card clusters textured with painted clumps (lush, tall with
## seed heads, dry, flowering — tools/blender/gen_grass_atlas.py), whose instances wrap around the camera in the
## vertex shader (grass_cards.gdshader). 6 triangles per clump; nothing is rebuilt while walking — only the list
## of bare spots (fires, buildings) is refreshed every second.

const SPACING := {0: 0.5, 1: 0.4, 2: 0.32}   # clump grid spacing by video quality (low / medium / high)
const RADIUS := {0: 15.0, 1: 20.0, 2: 30.0}
const BARE_SLOTS := 12

var world: ForestWorld
var _grass: MultiMeshInstance3D
var _floor: MultiMeshInstance3D
var _material: ShaderMaterial
var _floor_material: ShaderMaterial
var _bare_t := 0.0
var _quality := -1


func build(w: ForestWorld, heights: PackedFloat32Array, forest_mask: Image, macro_tex: Texture2D) -> void:
	world = w
	var row := ForestWorld.GRID + 1
	var img := Image.create_from_data(row, row, false, Image.FORMAT_RF, heights.to_byte_array())
	_material = ShaderMaterial.new()
	_material.shader = preload("res://world/shaders/grass_cards.gdshader")
	_material.set_shader_parameter("atlas", preload("res://assets/textures/vegetation/T_GrassCards_D.png"))
	_material.set_shader_parameter("height_tex", ImageTexture.create_from_image(img))
	_material.set_shader_parameter("grass_mask", ImageTexture.create_from_image(_grass_mask(heights, forest_mask, 1.15)))
	_material.set_shader_parameter("macro_noise", macro_tex)
	_material.set_shader_parameter("half_size", ForestWorld.HALF)
	_material.set_shader_parameter("cell", ForestWorld.CELL_SIZE)
	_material.set_shader_parameter("grid", ForestWorld.GRID)
	_material.set_shader_parameter("map_size", ForestWorld.SIZE)
	# Forest floor: same field, its own atlas, where the trees stand (forest mask or a grove).
	_floor_material = _material.duplicate() as ShaderMaterial
	_floor_material.set_shader_parameter("atlas", preload("res://assets/textures/vegetation/T_ForestCards_D.png"))
	_floor_material.set_shader_parameter("grass_mask", ImageTexture.create_from_image(_grass_mask(heights, forest_mask, 1.0, true)))
	_floor_material.set_shader_parameter("forest_floor", true)
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
			var gx := -ForestWorld.HALF + ix * cell
			var gz := -ForestWorld.HALF + iz * cell
			var trees := maxf(smoothstep(0.2, 0.65, f), smoothstep(0.35, 0.8, FarForest.grove_at(gx, gz)))
			var cover := trees if under_trees else clampf(1.0 - maxf(f * thin, trees * 0.9), 0.0, 1.0)
			var v := cover * clampf((h - ForestWorld.WATER_LEVEL - 0.3) * 2.0, 0.0, 1.0) \
				* (1.0 - smoothstep(0.55, 0.8, slope))
			img.set_pixel(ix, iz, Color(v, v, v))
	return img


func _rebuild() -> void:
	var q := clampi(int(Settings.get_value("video", "quality")), 0, 2)
	if q == _quality:
		return
	_quality = q
	for n in [_grass, _floor]:
		if is_instance_valid(n):
			n.queue_free()
	var radius: float = RADIUS[q]
	_material.set_shader_parameter("radius", radius)
	_floor_material.set_shader_parameter("radius", radius)
	_grass = _field(_cluster_mesh(), float(SPACING[q]), radius, _material)
	_floor = _field(_cluster_mesh(), float(SPACING[q]) * 1.25, radius, _floor_material)


func _field(mesh: Mesh, spacing: float, radius: float, material: ShaderMaterial) -> MultiMeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = ForestWorld.SEED + 409 + int(spacing * 1000.0)
	var n := int(ceil(radius * 2.0 / spacing))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = n * n
	for iz in n:
		for ix in n:
			var p := Vector3(-radius + (ix + rng.randf()) * spacing, 0.0, -radius + (iz + rng.randf()) * spacing)
			mm.set_instance_transform(iz * n + ix, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), p))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Positions are made in the shader around the camera: never frustum-cull the field as a whole.
	mmi.custom_aabb = AABB(Vector3(-ForestWorld.HALF, -200.0, -ForestWorld.HALF), Vector3(ForestWorld.SIZE, 600.0, ForestWorld.SIZE))
	add_child(mmi)
	return mmi


## 3 vertical cards crossed at 60°, 0.62 m wide and 0.5 m tall, roots at y = 0. UV.y = 1 at the root (atlas
## orientation), COLOR.g = card id (0, 0.5, 1) for the distance LOD.
static func _cluster_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := 0.36
	var hgt := 0.5
	for k in 3:
		var a := PI * k / 3.0
		var d := Vector3(cos(a), 0, sin(a))
		var off := Vector3(-sin(a), 0, cos(a)) * 0.04 * (k - 1)
		var quad := [[-w, 0.0, 0.0, 1.0], [w, 0.0, 1.0, 1.0], [w, hgt, 1.0, 0.0], [-w, hgt, 0.0, 0.0]]
		for i: int in [0, 1, 2, 0, 2, 3]:
			var q: Array = quad[i]
			st.set_color(Color(0, k * 0.5, 0))
			st.set_uv(Vector2(q[2], q[3]))
			st.add_vertex(d * float(q[0]) + Vector3(0, q[1], 0) + off)
	st.index()
	st.generate_normals()
	return st.commit()


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
	_material.set_shader_parameter("bare", arr)
	_floor_material.set_shader_parameter("bare", arr)
	if world.weather:
		var wd: Vector2 = world.weather.wind_dir
		var strength := 0.25 + 0.5 * world.weather.wind
		for m: ShaderMaterial in [_material, _floor_material]:
			m.set_shader_parameter("wind_dir", wd.normalized())
			m.set_shader_parameter("wind_strength", strength)
