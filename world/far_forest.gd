class_name FarForest
extends Node3D
## Forests to the horizon. The fellable trees are streamed only ~150 m around the player (Vegetation), which
## left distant hills bare. Every tree model is photographed once at start-up into an impostor (two crossed cards,
## 4 triangles) and those are placed over the whole map by the same regional density and forest mask, in 256 m
## MultiMesh chunks without shadows. Each card hides itself closer than BEGIN (vertex shader), where the real trees
## stand. Positions are computed on a worker thread.

const CHUNK := 256.0
const STEP := 8.0
const BEGIN := 165.0
const END := {0: 650.0, 1: 950.0, 2: 1400.0}
const SPAWN_CLEAR := 135.0
## region -> [species, trees per m²] (as Vegetation._chunk)
const REGION_TREES := {
	&"tavren": [&"spruce", 0.011], &"meyra": [&"alder", 0.0052], &"kharum": [&"spruce", 0.0042],
	&"varkai": [&"pine", 0.0034], &"ossara": [&"pine", 0.0011], &"tundra": [&"pine", 0.00065], &"aruun": [&"alder", 0.0042],
}

var world: ForestWorld
var instances := 0
var _meshes: Dictionary = {}  # species -> Array[Mesh] (far materials)
var _task := -1
var _abort := false  # set when the world goes away mid-computation (tests boot and free worlds quickly)


func build(w: ForestWorld, mask: Image) -> void:
	world = w
	if DisplayServer.get_name() == "headless":
		return  # nothing to capture impostors with (and nothing to see)
	for sp: StringName in [&"spruce", &"pine", &"alder"]:
		var list: Array[Mesh] = []
		for path: String in AssetLib.TREES[sp]:
			list.append(await _impostor(path))
		_meshes[sp] = list
	if is_inside_tree():
		_task = WorkerThreadPool.add_task(_compute.bind(mask), false, "FarForest")


## Photographs a tree model once (unlit, transparent background) and returns two crossed cards wearing it.
func _impostor(path: String) -> Mesh:
	var tree := AssetLib.instance(path)
	var box := AssetLib.aabb(tree)
	var h := box.end.y
	var r := maxf(maxf(absf(box.position.x), box.end.x), maxf(absf(box.position.z), box.end.z))
	var vp := SubViewport.new()
	vp.size = Vector2i(256, int(256.0 * h / (2.0 * r)))
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = h
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.position = Vector3(0, h * 0.5, r * 4.0)
	vp.add_child(cam)
	vp.add_child(tree)
	add_child(vp)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	var tex: Texture2D = null
	if img and not img.is_empty():
		img.generate_mipmaps()
		tex = ImageTexture.create_from_image(img)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for axis: Vector3 in [Vector3(1, 0, 0), Vector3(0, 0, 1)]:
		var n := axis.cross(Vector3.UP)
		var quad := [[-r, 0.0, 0.0, 1.0], [r, 0.0, 1.0, 1.0], [r, h, 1.0, 0.0], [-r, h, 0.0, 0.0]]
		for k: int in [0, 1, 2, 0, 2, 3]:
			var q: Array = quad[k]
			st.set_normal(n)
			st.set_uv(Vector2(q[2], q[3]))
			st.add_vertex(axis * float(q[0]) + Vector3(0, q[1], 0))
	var mesh := st.commit()
	var m := ShaderMaterial.new()
	m.shader = preload("res://world/shaders/impostor.gdshader")
	m.set_shader_parameter("albedo_tex", tex)
	m.set_shader_parameter("far_begin", BEGIN)
	m.set_shader_parameter("height", h)
	mesh.surface_set_material(0, m)
	return mesh


func _compute(mask: Image) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = ForestWorld.SEED + 4242
	var groves := FastNoiseLite.new()  # real forests grow in stands and groves, with meadows between them
	groves.seed = ForestWorld.SEED + 77
	groves.frequency = 0.006
	groves.fractal_octaves = 3
	var chunks := {}  # Vector2i -> {"sp:i": Array[Transform3D]}
	var lim := ForestWorld.PLAYABLE - 10.0
	var z := -lim
	while z < lim and not _abort:
		var x := -lim
		while x < lim:
			var px := x + rng.randf() * STEP
			var pz := z + rng.randf() * STEP
			x += STEP
			var row: Array = REGION_TREES.get(world.region_at(px, pz), [&"pine", 0.0012])
			var forest := _mask(mask, px, pz)
			# ~40 % of the near density, drawn a little larger: in the haze the canopy reads just as closed
			var grove := smoothstep(-0.05, 0.35, groves.get_noise_2d(px, pz)) * 2.4
			var p := float(row[1]) * STEP * STEP * (0.3 + forest) * 0.4 * grove
			if rng.randf() > p:
				continue
			if Vector2(px, pz).distance_to(ForestWorld.SPAWN) < SPAWN_CLEAR or world.river_distance(px, pz) < 20.0:
				continue
			var h := world.height_at(px, pz)
			if h < 1.5 or h > 135.0 or world.normal_at(px, pz).y < 0.72:
				continue
			var sp: StringName = row[0]
			var i := rng.randi() % (_meshes[sp] as Array).size()
			var s := rng.randf_range(1.0, 1.45)
			var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), Vector3(px, h - 0.3, pz))
			var key := Vector2i(floori(px / CHUNK), floori(pz / CHUNK))
			if not chunks.has(key):
				chunks[key] = {}
			var k := "%s:%d" % [sp, i]
			if not chunks[key].has(k):
				chunks[key][k] = []
			chunks[key][k].append(xf)
		z += STEP
	if not _abort:
		_finish.call_deferred(chunks)


func _mask(mask: Image, x: float, z: float) -> float:
	if mask == null:
		return 0.5
	var u := clampi(int((x / ForestWorld.SIZE + 0.5) * mask.get_width()), 0, mask.get_width() - 1)
	var v := clampi(int((z / ForestWorld.SIZE + 0.5) * mask.get_height()), 0, mask.get_height() - 1)
	return mask.get_pixel(u, v).r


func _finish(chunks: Dictionary) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if not is_inside_tree():
		return
	var end: float = END[clampi(int(Settings.get_value("video", "quality")), 0, 2)]
	for key: Vector2i in chunks:
		var center := Vector3((key.x + 0.5) * CHUNK, 0.0, (key.y + 0.5) * CHUNK)
		for k: String in chunks[key]:
			var parts := k.split(":")
			var mesh: Mesh = _meshes[StringName(parts[0])][int(parts[1])]
			var xfs: Array = chunks[key][k]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mesh
			mm.instance_count = xfs.size()
			for i in xfs.size():
				var xf: Transform3D = xfs[i]
				mm.set_instance_transform(i, Transform3D(xf.basis, xf.origin - center))
			instances += xfs.size()
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.position = center
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.visibility_range_end = end
			mmi.visibility_range_end_margin = 80.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			add_child(mmi)
	print_verbose("FarForest: %d impostors" % instances)


func _exit_tree() -> void:
	_abort = true
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
