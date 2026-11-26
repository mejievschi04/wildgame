class_name TwigBush
extends RefCounted
## A dry, leafless twig bush (as the wood bushes of Far Cry Primal): ten to thirteen stems fanning up and out of
## the ground to ~1.3 m, forking twice into a tangle of twigs, weathered silver-grey toward the tips (dark at the
## foot), bark normals from the alder trees. It stands well clear of the meadow grass so it reads from afar where
## sticks on the ground were lost in it. Built once per variant as one tapered-tube mesh.

const VARIANTS := 4
const BARK_NORM := "res://assets/models/trees/textures/T_AlderBark_nor_gl.jpg"

static var _meshes: Dictionary = {}  # [variant, picked] -> ArrayMesh
static var _mat: StandardMaterial3D


## The bush mesh for `variant`; `picked` = the stubs left once every twig was gathered.
static func mesh(variant: int, picked := false) -> ArrayMesh:
	var key := Vector2i(variant % VARIANTS, 1 if picked else 0)
	if not _meshes.has(key):
		_meshes[key] = _build(key.x, picked)
	return _meshes[key]


static func material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true  # the weathering gradient, foot to tips
		_mat.vertex_color_is_srgb = true
		if ResourceLoader.exists(BARK_NORM):
			_mat.normal_enabled = true
			_mat.normal_texture = load(BARK_NORM)
			_mat.normal_scale = 0.5
		_mat.roughness = 1.0
		_mat.metallic_specular = 0.25  # dry wood: no sheen of sky on the twigs
	return _mat


static func _build(variant: int, picked: bool) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 * (variant + 1)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stems := rng.randi_range(10, 13)
	for i in stems:
		var a := TAU * i / stems + rng.randf_range(-0.3, 0.3)
		var lean := rng.randf_range(0.3, 0.9)  # radians from upright: a wide, open crown
		var dir := Vector3(cos(a) * sin(lean), cos(lean), sin(a) * sin(lean)).normalized()
		var length := rng.randf_range(0.9, 1.5)
		if picked:
			length = rng.randf_range(0.12, 0.25)  # broken-off stubs
		var base := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.02, 0.14) - Vector3(0, 0.05, 0)
		_branch(st, rng, base, dir, length, rng.randf_range(0.016, 0.024), 0 if not picked else 9, 0.0)
	st.generate_tangents()
	var m := st.commit()
	m.surface_set_material(0, material())
	return m


## A tapered, slightly bending branch from `from` along `dir`; forks into side twigs while `depth` < 2.
static func _branch(st: SurfaceTool, rng: RandomNumberGenerator, from: Vector3, dir: Vector3, length: float,
		r0: float, depth: int, age0: float) -> void:
	var segs := 4 if depth == 0 else 2
	var pts: Array[Vector3] = [from]
	var d := dir
	var bend := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.2, 0.3), rng.randf_range(-1, 1)) * 0.18
	for k in segs:
		d = (d + bend * (1.0 / segs) + Vector3.UP * 0.04).normalized()
		pts.append(pts[-1] + d * (length / segs))
	var r1 := maxf(r0 * 0.22, 0.0025)
	var age1 := minf(age0 + length / 1.2, 1.0)
	_tube(st, pts, r0, r1, age0, age1, 6 if depth == 0 else 4)
	if depth >= 2:
		return
	# side twigs along the upper two thirds, leaning out of the parent
	var twigs := rng.randi_range(4, 7) if depth == 0 else rng.randi_range(2, 3)
	for t in twigs:
		var f := rng.randf_range(0.3, 0.9)
		var seg := clampi(int(f * segs), 0, segs - 1)
		var at := pts[seg].lerp(pts[seg + 1], f * segs - seg)
		var parent_dir := (pts[seg + 1] - pts[seg]).normalized()
		var side := parent_dir.cross(Vector3(rng.randf_range(-1, 1), 0.1, rng.randf_range(-1, 1))).normalized()
		var tdir := parent_dir.rotated(side, rng.randf_range(0.6, 1.25)).normalized()
		var tlen := length * rng.randf_range(0.28, 0.45) * (1.0 - f * 0.4)
		_branch(st, rng, at, tdir, tlen, lerpf(r0, r1, f) * 0.6, depth + 1, lerpf(age0, age1, f))


## Dry wood colour by how far out along the bush (0 = foot, 1 = tips): dark, damp brown at the foot to sun-bleached
## silver-grey at the tips.
static func _wood(age: float, jitter: float) -> Color:
	var foot := Color(0.3, 0.22, 0.15)
	var tip := Color(0.72, 0.64, 0.53)
	return foot.lerp(tip, clampf(age * 1.4, 0.0, 1.0)) * (1.0 + jitter)


static func _tube(st: SurfaceTool, pts: Array[Vector3], r0: float, r1: float, age0: float, age1: float,
		sides: int) -> void:
	var rings: Array = []
	var v_acc := 0.0
	var jitter := (fposmod(pts[0].x * 91.7 + pts[0].z * 37.3 + pts[0].y * 13.1, 1.0) - 0.5) * 0.16  # per twig, stable
	for i in pts.size():
		var t := float(i) / (pts.size() - 1)
		var fwd := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
		var side := fwd.cross(Vector3.RIGHT if absf(fwd.x) < 0.9 else Vector3.FORWARD).normalized()
		var up := side.cross(fwd).normalized()
		var r := lerpf(r0, r1, t)
		var col := _wood(lerpf(age0, age1, t), jitter)
		var ring: Array = []
		for k in sides + 1:
			var ang := TAU * k / sides
			var n := (side * cos(ang) + up * sin(ang)).normalized()
			ring.append([pts[i] + n * r, n, Vector2(float(k) / sides * 0.25, v_acc), col])
		rings.append(ring)
		if i < pts.size() - 1:
			v_acc += pts[i].distance_to(pts[i + 1]) / 0.6  # bark repeats every 0.6 m
	for i in rings.size() - 1:
		for k in sides:
			var a: Array = rings[i][k]
			var b: Array = rings[i][k + 1]
			var c: Array = rings[i + 1][k + 1]
			var dd: Array = rings[i + 1][k]
			for v: Array in [a, b, c, a, c, dd]:  # clockwise seen from outside: Godot's front face
				st.set_normal(v[1])
				st.set_uv(v[2])
				st.set_color(v[3])
				st.add_vertex(v[0])
