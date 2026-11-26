class_name FarForest
extends Node3D
## Forests to the horizon. The fellable trees are streamed only ~150 m around the player (Vegetation), which
## left distant hills bare. Every tree model is photographed once at start-up into an impostor (two crossed cards,
## 4 triangles) and those are placed over the whole map by the same regional density and forest mask, in 256 m
## MultiMesh chunks without shadows. Each card hides itself closer than BEGIN (vertex shader), where the real trees
## stand. Positions are computed on a worker thread.

const CHUNK := 640.0  # big chunks: each (chunk, tree model) is one draw call
const STEP := 6.0
const BANDS := 16
const BEGIN := 95.0  # = Vegetation.LOAD_RADIUS × CHUNK: real trees are always loaded at least this far
const END := {0: 900.0, 1: 1500.0, 2: 2200.0}
const IMPOSTOR_PX := 512
const CACHE_DIR := "res://assets/textures/impostors"
const PLACEMENT_CACHE := "user://world_layout_far_forest.bin"
const VERSION := 4  # bump when the placement rules change
const SPAWN_CLEAR := 135.0
const SPECIES := [&"spruce", &"pine", &"alder", &"jungle", &"palm"]
## region -> [species, trees per m²] (as Vegetation._chunk)
const REGION_TREES := {
	&"tavren": [&"spruce", 0.011], &"meyra": [&"alder", 0.0052], &"kharum": [&"spruce", 0.0042],
	&"varkai": [&"pine", 0.0034], &"ossara": [&"pine", 0.0011], &"tundra": [&"pine", 0.00065], &"aruun": [&"alder", 0.0042],
	&"sakhal": [&"spruce", 0.009], &"ilmar": [&"spruce", 0.0018],
}

var world: ForestWorld
var instances := 0
var _meshes: Dictionary = {}  # species -> Array[Mesh] (far materials)
var _task := -1
var _pending: Dictionary = {}
var _bands: Array = []  # per-band placement results
var _band_done_ms := 0
var _fingerprint := 0  # placement that finished before the impostors were ready
var _abort := false  # set when the world goes away mid-computation (tests boot and free worlds quickly)


var _t0 := 0


func build(w: ForestWorld, mask: Image) -> void:
	world = w
	_t0 = Time.get_ticks_msec()
	if DisplayServer.get_name() == "headless":
		return  # nothing to see (and no renderer to capture impostors with)
	# placement: from the cache when the terrain is unchanged, else computed on all cores (and cached)
	_fingerprint = _terrain_fingerprint()
	var cached := _load_placement()
	if cached.is_empty():
		grove_at(0.0, 0.0)  # create the shared noise before the threads read it
		_bands.resize(BANDS)
		_task = WorkerThreadPool.add_group_task(_compute_band.bind(mask), BANDS, -1, false, "FarForest")
	for sp: StringName in SPECIES:
		var list: Array[Mesh] = []
		for path: String in AssetLib.TREES[sp]:
			list.append(await _impostor(path))
		_meshes[sp] = list
	print_verbose("FarForest impostors ready in %d ms" % (Time.get_ticks_msec() - _t0))
	if not cached.is_empty():
		_finish(cached)
	elif not _pending.is_empty():
		_finish(_pending)


## Photographs a tree model once (unlit, transparent background) and returns two crossed cards wearing it.
func _impostor(path: String) -> Mesh:
	var tree := AssetLib.instance(path)
	var box := AssetLib.aabb(tree)
	var h := box.end.y
	var r := maxf(maxf(absf(box.position.x), box.end.x), maxf(absf(box.position.z), box.end.z))
	# Photographed once, then kept with the project (instant on every later start, and in exported builds).
	var cache := "%s/T_Impostor_%s_%d.res" % [CACHE_DIR, path.get_file().get_basename(), IMPOSTOR_PX]
	var tex: Texture2D = load(cache) if ResourceLoader.exists(cache) else null
	if tex:
		tree.free()
		return _cards(tex, h, r)
	var vp := SubViewport.new()
	vp.size = Vector2i(IMPOSTOR_PX, int(IMPOSTOR_PX * h / (2.0 * r)))
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
	if img and not img.is_empty():
		img.generate_mipmaps()
		tex = ImageTexture.create_from_image(img)
		if OS.has_feature("editor"):
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
			ResourceSaver.save(tex, cache, ResourceSaver.FLAG_COMPRESS)
	return _cards(tex, h, r)


## Two crossed cards wearing an impostor texture.
func _cards(tex: Texture2D, h: float, r: float) -> Mesh:
	h *= AssetLib.TREE_MODEL_SCALE
	r *= AssetLib.TREE_MODEL_SCALE
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


## One band of rows (BANDS bands share the map), run in parallel on the worker pool; each band has its own RNG.
func _compute_band(band: int, mask: Image) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = ForestWorld.SEED + 4242 + band
	var chunks := {}  # Vector2i -> {"sp:i": Array[Transform3D]}
	var lim := ForestWorld.PLAYABLE - 10.0
	var rows := int(ceil(2.0 * lim / STEP))
	var r0 := rows * band / BANDS
	var r1 := rows * (band + 1) / BANDS
	for r in range(r0, r1):
		if _abort:
			return
		var z := -lim + r * STEP
		var x := -lim
		while x < lim:
			var px := x + rng.randf() * STEP
			var pz := z + rng.randf() * STEP
			x += STEP
			var row: Array = REGION_TREES.get(world.region_at(px, pz), [&"pine", 0.0012])
			var forest := _mask(mask, px, pz)
			var g := grove_at(px, pz)
			# groves close into a canopy (crowns overlap), with a few lone trees in the meadows between them
			var jg := ForestWorld.jungle_at(px, pz)
			var tn := ForestWorld.tundra_at(px, pz)
			var dens := lerpf(float(row[1]), 0.009, jg) * (1.0 - 0.85 * tn)
			var p := dens * STEP * STEP * (0.3 + maxf(forest, jg)) * (0.12 + 7.0 * g * g)
			if rng.randf() > p:
				continue
			if Vector2(px, pz).distance_to(ForestWorld.SPAWN) < SPAWN_CLEAR or world.water_distance(px, pz) < 20.0 \
					or world.in_cave_cut(px, pz, 6.0) or world.in_settlement(px, pz):
				continue
			var h := world.height_at(px, pz)
			if h < 1.5 or h > 135.0 or world.normal_at(px, pz).y < 0.72:
				continue
			var sp: StringName = row[0]
			var climate := 1.0
			if rng.randf() < jg:
				sp = &"palm" if rng.randf() < 0.3 else &"jungle"
			elif tn > 0.0:
				sp = &"spruce"
				climate = lerpf(1.0, 0.5, tn)
			var i := rng.randi() % (AssetLib.TREES[sp] as Array).size()
			var s := rng.randf_range(1.0, 1.55) * Vegetation.TREE_SCALE * climate
			var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), Vector3(px, h - 0.3, pz))
			var key := Vector2i(floori(px / CHUNK), floori(pz / CHUNK))
			if not chunks.has(key):
				chunks[key] = {}
			var k := "%s:%d" % [sp, i]
			if not chunks[key].has(k):
				chunks[key][k] = []
			chunks[key][k].append(xf)
	_bands[band] = chunks
	_band_done_ms = maxi(_band_done_ms, Time.get_ticks_msec() - _t0)


## A cheap hash of everything the placement depends on (terrain, regions, groves, tree variant counts):
## the cached placement is only used while it still matches.
func _terrain_fingerprint() -> int:
	var parts: Array = [VERSION, STEP, ForestWorld.SEED, Vegetation.TREE_SCALE, SPAWN_CLEAR, str(REGION_TREES)]
	for species: StringName in SPECIES:
		parts.append(AssetLib.TREES[species].size())
	for i in 64:
		var x := -1900.0 + (i % 8) * 540.0
		var z := -1900.0 + (i / 8) * 540.0
		parts.append(snappedf(world.height_at(x, z), 0.01))
		parts.append(snappedf(world.water_distance(x, z), 0.1))
		parts.append(snappedf(grove_at(x, z), 0.001))
	return hash(parts)


func _load_placement() -> Dictionary:
	if not FileAccess.file_exists(PLACEMENT_CACHE):
		return {}
	var f := FileAccess.open(PLACEMENT_CACHE, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = bytes_to_var(f.get_buffer(f.get_length()))
	if not data is Dictionary or int((data as Dictionary).get("fingerprint", 0)) != _fingerprint:
		return {}
	var out := {}
	var chunks: Dictionary = data.chunks
	for key: Vector2i in chunks:
		out[key] = {}
		for k: String in chunks[key]:
			var flat: PackedFloat32Array = chunks[key][k]
			var xfs: Array = []
			for j in range(0, flat.size(), 12):
				xfs.append(Transform3D(Vector3(flat[j], flat[j + 1], flat[j + 2]), Vector3(flat[j + 3], flat[j + 4], flat[j + 5]),
					Vector3(flat[j + 6], flat[j + 7], flat[j + 8]), Vector3(flat[j + 9], flat[j + 10], flat[j + 11])))
			out[key][k] = xfs
	return out


func _save_placement(chunks: Dictionary) -> void:
	var flat_chunks := {}
	for key: Vector2i in chunks:
		flat_chunks[key] = {}
		for k: String in chunks[key]:
			var flat := PackedFloat32Array()
			for xf: Transform3D in chunks[key][k]:
				flat.append_array([xf.basis.x.x, xf.basis.x.y, xf.basis.x.z, xf.basis.y.x, xf.basis.y.y, xf.basis.y.z,
					xf.basis.z.x, xf.basis.z.y, xf.basis.z.z, xf.origin.x, xf.origin.y, xf.origin.z])
			flat_chunks[key][k] = flat
	var f := FileAccess.open(PLACEMENT_CACHE, FileAccess.WRITE)
	if f:
		f.store_buffer(var_to_bytes({"fingerprint": _fingerprint, "chunks": flat_chunks}))


func _process(_delta: float) -> void:
	if _task < 0 or not WorkerThreadPool.is_group_task_completed(_task):
		return
	WorkerThreadPool.wait_for_group_task_completion(_task)
	_task = -1
	if _abort:
		return
	var merged := {}
	for chunks: Dictionary in _bands:
		for key: Vector2i in chunks:
			if not merged.has(key):
				merged[key] = {}
			for k: String in chunks[key]:
				if not merged[key].has(k):
					merged[key][k] = []
				merged[key][k].append_array(chunks[key][k])
	_bands.clear()
	_save_placement(merged)
	print_verbose("FarForest: placement computed in %d ms (threads done at %d ms)" % [Time.get_ticks_msec() - _t0, _band_done_ms])
	_finish(merged)


static var _groves: FastNoiseLite


## The grove field over the whole map as an image (for the terrain shader: forest floor under groves, and the
## canopy's shade on the ground beyond the impostors).
static func grove_image(size := 256) -> Image:
	var img := Image.create_empty(size, size, false, Image.FORMAT_L8)
	for iz in size:
		for ix in size:
			var x := (ix + 0.5) / size * ForestWorld.SIZE - ForestWorld.HALF
			var z := (iz + 0.5) / size * ForestWorld.SIZE - ForestWorld.HALF
			var g := grove_at(x, z)
			img.set_pixel(ix, iz, Color(g, g, g))
	return img


## 0 open meadow … 1 inside a grove. Real forests grow in stands with clearings between them; FarForest and the
## near, fellable grove trees (Vegetation) share this field so the two meet seamlessly.
static func grove_at(x: float, z: float) -> float:
	if _groves == null:
		_groves = FastNoiseLite.new()
		_groves.seed = ForestWorld.SEED + 77
		_groves.frequency = 0.006
		_groves.fractal_octaves = 3
	# none in the start valley (no trees grow within SPAWN_CLEAR of the spawn)
	var open_valley := smoothstep(SPAWN_CLEAR, SPAWN_CLEAR + 45.0, Vector2(x, z).distance_to(ForestWorld.SPAWN))
	var g := smoothstep(-0.05, 0.35, _groves.get_noise_2d(x, z))
	g = maxf(g, ForestWorld.jungle_at(x, z) * 0.9)          # the jungle closes into one canopy
	g *= 1.0 - 0.85 * ForestWorld.tundra_at(x, z)           # the tundra is open
	g = maxf(g, ForestWorld.taiga_at(x, z) * 0.75)           # the snowy taiga is one forest, broken by clearings
	g *= 1.0 - ForestWorld.glacier_at(x, z)
	return g * open_valley


func _mask(mask: Image, x: float, z: float) -> float:
	if mask == null:
		return 0.5
	var u := clampi(int((x / ForestWorld.SIZE + 0.5) * mask.get_width()), 0, mask.get_width() - 1)
	var v := clampi(int((z / ForestWorld.SIZE + 0.5) * mask.get_height()), 0, mask.get_height() - 1)
	return mask.get_pixel(u, v).r


func _finish(chunks: Dictionary) -> void:
	if not is_inside_tree():
		return
	if _meshes.size() < SPECIES.size():  # impostors still being photographed (first run): build when they are
		_pending = chunks
		return
	_pending = {}
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
	print_verbose("FarForest: %d impostors placed in %d ms" % [instances, Time.get_ticks_msec() - _t0])


func _exit_tree() -> void:
	_abort = true
	if _task >= 0:
		WorkerThreadPool.wait_for_group_task_completion(_task)
		_task = -1
