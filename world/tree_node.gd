class_name TreeNode
extends ResourceNode
## Fellable tree. Lifecycle:
##   STANDING  — axe hits deepen a notch on the chopper's side, chips fly, the crown shudders
##   FALLING   — creak, then the trunk rotates around a hinge at the stump with gravity (α = 3g/2L·sinθ),
##               lands on the terrain with a small rebound, dust + leaves, camera shake, hurts anyone underneath
##   FALLEN    — buck the lying trunk into logs (wood per hit); branches dropped as sticks on landing
##   CLEARED   — only the stump remains; the tree regrows after `regrow` simulated seconds
## Visuals are the scanned/generated tree assets; physics of the fall is kinematic (deterministic, saveable).

enum Stage { STANDING, FALLING, FALLEN, CLEARED }
const DEFAULT_CUT := 0.6
const CREAK_TIME := 0.9
const FALL_DAMAGE := 45.0

var stage: Stage = Stage.STANDING
var species: StringName
var fell_hits := 6
var chop := 0
var fall_dir := Vector3(0, 0, 1)
var fall_angle := 0.0
var fall_vel := 0.0
var final_angle := deg_to_rad(86.0)
var height := 12.0
## Height of the cut = height of the first axe impact (you chop where you aim).
var cut_h := DEFAULT_CUT

var _pivot: Node3D
var _tree: Node3D
var _stump: Node3D
var _notch: MeshInstance3D
var _log_shape: CollisionShape3D
var _creak_t := 0.0
var _bounced := false
var _wobble := 0.0
var _wobble_t := 0.0
var _trunk_r := 0.3  # real bark radius at the cut height (from the model, see _trunk_at)
var _trunk_c := Vector2.ZERO  # trunk centre (x, z) at the cut height, node space
var _holder: Node3D
var _stump_post: MeshInstance3D
var _stump_top: MeshInstance3D
var _size := 1.0
var _tree_path := ""
var _debris: Node3D  # wood chips left on the ground by chopping (visual only)
## Felled trees keep their crown until it is cut off (LIMB_HITS blows on the lying tree): then the branches drop
## as sticks and the bare trunk can be bucked into logs.
const LIMB_HITS := 2
var limb := 0

## Trunk cross-sections per tree asset: [[y, cx, cz, r], ...] (unscaled model space, sorted by y).
static var _trunk_profiles: Dictionary = {}
static var _chip_mesh: Mesh
static var _chip_mat: Material
static var _bark_chip_mat: Material
const MAX_DEBRIS := 36
## Trees are sunk this far so the root flare meets the ground on slopes (model y=0 is the base of the trunk).
const SINK := 0.3
static var _notch_mat: Material


# ---------------------------------------------------------------- build

func _build(s: float) -> void:
	if species == &"":
		species = &"alder"
		if kind == &"tree_pine":
			species = &"pine" if absi(hash(node_id + "sp")) % 10 < 3 else &"spruce"
	fell_hits = int(cfg.get("fell_hits", 6))
	_pivot = Node3D.new()
	_pivot.name = "FallPivot"
	_pivot.position = Vector3(0, cut_h, 0)
	add_child(_pivot)
	var holder := Node3D.new()
	holder.position = Vector3(0, -cut_h, 0)
	holder.rotation.y = _visual.rotation.y
	_pivot.add_child(holder)
	_holder = holder
	_tree_path = AssetLib.pick(AssetLib.TREES[species], node_id)
	_tree = AssetLib.instance(_tree_path)
	_size = s
	_tree.scale = Vector3.ONE * s
	_tree.position.y = -SINK  # root flare into the ground so the base never floats on a slope
	holder.add_child(_tree)
	height = maxf(AssetLib.aabb(_tree).size.y * s, 6.0)
	# Stump = scanned root flare + a bark post up to the cut + fresh-wood cut face.
	_stump = Node3D.new()
	add_child(_stump)
	var roots := AssetLib.instance(AssetLib.pick(AssetLib.TREES[&"stump"], node_id))
	roots.scale = Vector3.ONE * 0.42
	roots.rotation.y = _visual.rotation.y
	_stump.add_child(roots)
	_stump_post = Graybox.part_mat(_stump, Graybox.cylinder(1, 1, 1, 14), Graybox.tex("Log", Color.WHITE, 2.0))
	_stump_top = Graybox.part_mat(_stump, Graybox.cylinder(1, 1, 1, 14), Graybox.tex("CutWood", Color(1.15, 1.05, 0.9), 4.0))
	_notch = MeshInstance3D.new()
	_notch.material_override = _notch_material()
	_notch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_notch.visible = false
	add_child(_notch)
	_debris = Node3D.new()
	_debris.name = "ChipDebris"
	add_child(_debris)
	_apply_cut_height()
	var t1 := _trunk_at(1.0)
	_shape = Graybox.add_shape(self, Graybox.cyl_shape(t1.z, height), Vector3(t1.x, height * 0.5, t1.y))
	_log_shape = Graybox.add_shape(self, Graybox.cyl_shape(t1.z * 0.95, height - cut_h))
	_log_shape.disabled = true


func _apply_cut_height() -> void:
	_pivot.position.y = cut_h
	_holder.position.y = -cut_h
	var t := _trunk_at(cut_h)
	_trunk_c = Vector2(t.x, t.y)
	_trunk_r = t.z
	var r := _trunk_r * 0.98
	_stump_post.scale = Vector3(r, cut_h, r)
	_stump_post.position = Vector3(_trunk_c.x, cut_h * 0.5, _trunk_c.y)
	_stump_top.scale = Vector3(r * 0.97, 0.012, r * 0.97)
	_stump_top.position = Vector3(_trunk_c.x, cut_h, _trunk_c.y)
	if _log_shape:
		(_log_shape.shape as CylinderShape3D).height = height - cut_h


## Trunk at height y (node space): Vector3(centre x, centre z, bark radius), measured from the tree model's
## bark rings and interpolated, so the notch, chips and collision sit on the real bark of this exact tree.
func _trunk_at(y: float) -> Vector3:
	var prof := _trunk_profile()
	var uy := (y + SINK) / _size
	var a: Array = prof[0]
	var b: Array = prof[prof.size() - 1]
	for i in prof.size() - 1:
		if float(prof[i + 1][0]) >= uy:
			a = prof[i]
			b = prof[i + 1]
			break
	var k := clampf((uy - float(a[0])) / maxf(float(b[0]) - float(a[0]), 0.001), 0.0, 1.0)
	var c := Vector3(lerpf(a[1], b[1], k), 0.0, lerpf(a[2], b[2], k)) * _size
	c = Basis(Vector3.UP, _visual.rotation.y) * c
	return Vector3(c.x, c.z, lerpf(a[3], b[3], k) * _size)


## [sides, phase] of the model trunk's facets at height y (from the nearest measured ring below).
func _facets(y: float) -> Array:
	var prof := _trunk_profile()
	var uy := (y + SINK) / _size
	var best: Array = prof[0]
	for e: Array in prof:
		if float(e[0]) <= uy + 0.01:
			best = e
	return [int(best[5]), float(best[6])]


## Radius of the model's faceted (flat-sided) trunk in model-space direction a, given its vertex radius.
static func _poly_r(a: float, vertex_r: float, facet: Array) -> float:
	var step := TAU / float(facet[0])
	var local := fposmod(a - float(facet[1]), step) - step * 0.5
	return vertex_r * cos(step * 0.5) / cos(local)


## Bark texture v at height y (node space), interpolated from the model's own rings.
func _bark_v(y: float) -> float:
	var prof := _trunk_profile()
	var uy := (y + SINK) / _size
	for i in prof.size() - 1:
		if float(prof[i + 1][0]) >= uy:
			var k := clampf((uy - float(prof[i][0])) / maxf(float(prof[i + 1][0]) - float(prof[i][0]), 0.001), 0.0, 1.0)
			return lerpf(prof[i][4], prof[i + 1][4], k)
	var l: Array = prof[prof.size() - 1]
	return float(l[4]) - 0.9 * (uy - float(l[0]))


func _trunk_profile() -> Array:
	if _trunk_profiles.has(_tree_path):
		return _trunk_profiles[_tree_path]
	var rings := {}
	var ring_v := {}  # texture v of each ring, so our cut section continues the model's bark exactly
	var bark := _tree.find_children("*", "MeshInstance3D", true, false)
	if not bark.is_empty():
		var mi := bark[0] as MeshInstance3D
		var xf := Transform3D()
		var n: Node = mi
		while n != null and n != _tree:  # model space, without the per-tree scale on _tree itself
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		var arrays := mi.mesh.surface_get_arrays(0)  # surface 0 = bark
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var tex: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		for i in verts.size():
			var w := xf * verts[i]
			if w.y < 12.0:
				var key := snappedf(w.y, 0.05)
				if not rings.has(key):
					rings[key] = []
					ring_v[key] = []
				rings[key].append(w)
				if i < tex.size():
					ring_v[key].append(tex[i].y)
	var prof: Array = []
	var keys := rings.keys()
	keys.sort()
	for key: float in keys:
		var pts: Array = rings[key]
		if pts.size() < 6:  # branch stubs, not a trunk ring
			continue
		var c := Vector3.ZERO
		for w: Vector3 in pts:
			c += w
		c /= pts.size()
		var r := 0.0
		for w: Vector3 in pts:
			r += Vector2(w.x - c.x, w.z - c.z).length()
		# Mean vertex radius of a ~10-sided ring; the flat faces sit a little further in.
		var vv := 0.0
		for x: float in ring_v.get(key, []):
			vv += x
		vv = vv / ring_v[key].size() if not (ring_v.get(key, []) as Array).is_empty() else 1.0 - 0.9 * key
		# Facets: how many sides the model trunk has and how they are turned (so our section matches it exactly).
		var angs: Array[float] = []
		for w: Vector3 in pts:
			var an := fposmod(atan2(w.x - c.x, w.z - c.z), TAU)
			var dup := false
			for q in angs:
				if absf(wrapf(q - an, -PI, PI)) < 0.05:
					dup = true
			if not dup:
				angs.append(an)
		var sides := maxi(angs.size(), 3)
		var phase := fposmod(angs[0], TAU / sides) if not angs.is_empty() else 0.0
		var rr := r / pts.size() * 0.96
		# Follow the single stem only: stop where the rings jump sideways or swell (a fork or a branch whorl).
		if not prof.is_empty():
			var last: Array = prof[prof.size() - 1]
			if Vector2(c.x - float(last[1]), c.z - float(last[2])).length() > maxf(float(last[3]), 0.1) * 1.2 or rr > float(last[3]) * 1.25:
				break
			if vv > float(last[4]):  # texture v runs down the trunk; a ring on a uv seam would jump back
				vv = float(last[4]) - 0.9 * (key - float(last[0]))
		prof.append([key, c.x, c.z, rr, vv, sides, phase])
	if prof.size() < 2:
		prof = [[0.0, 0.0, 0.0, 0.32, 1.0, 10, 0.0], [4.0, 0.0, 0.0, 0.26, -2.6, 10, 0.0]]
	_trunk_profiles[_tree_path] = prof
	return prof


func _refresh() -> void:
	if _pivot == null:
		return
	_pivot.visible = stage != Stage.CLEARED
	_stump.visible = stage in [Stage.FALLEN, Stage.CLEARED]
	_notch.visible = false  # superseded by the real cut geometry below
	if chop > 0 or stage != Stage.STANDING:
		_enter_cut_mode()
		_rebuild_cut()
	elif _cut_mode:
		_exit_cut_mode()
	match stage:
		Stage.STANDING:
			_pivot.basis = Basis()
			cut_h = cut_h if chop > 0 else DEFAULT_CUT
			_shape.disabled = false
			var t1 := _trunk_at(1.0)
			_shape.shape = Graybox.cyl_shape(t1.z, height)
			_shape.position = Vector3(t1.x, height * 0.5, t1.y)
			_log_shape.disabled = true
		Stage.FALLEN, Stage.CLEARED:
			_shape.shape = Graybox.cyl_shape(_trunk_r, cut_h)
			_shape.position = Vector3(_trunk_c.x, cut_h * 0.5, _trunk_c.y)
			_place_log_shape()
			_log_shape.disabled = stage != Stage.FALLEN
			if stage == Stage.FALLEN:
				_pivot.basis = Basis(_axis(), final_angle)
				if limbed():
					_make_bare_trunk()


## Felling notch: a lens-shaped V wedge on the bark, on the chopper's side. The sloped upper cut faces down-out,
## the flatter lower cut faces up-out (shaded like real cut faces), a dark slit where the wedge came out.
## It hugs the real bark radius (just outside the ~10-sided trunk so it never sinks in or floats off).
func _notch_mesh(progress: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_angle := lerpf(0.4, 1.2, progress)
	var h := lerpf(0.06, 0.22, progress)
	var segs := 14
	var r := _trunk_r * 1.03 + 0.003
	var face_tilt: Array[float] = [-0.75, 0.0, 0.55]  # upper face, slit, lower face
	for i in segs:
		for k in 3:
			var a0 := lerpf(-half_angle, half_angle, float(i) / segs)
			var a1 := lerpf(-half_angle, half_angle, float(i + 1) / segs)
			var p0 := _lens(a0, half_angle, h, r, k)
			var p1 := _lens(a1, half_angle, h, r, k)
			var q0 := _lens(a0, half_angle, h, r, k + 1)
			var q1 := _lens(a1, half_angle, h, r, k + 1)
			var col := Color(0.09, 0.065, 0.045) if k == 1 else (Color(0.62, 0.56, 0.48) if k == 0 else Color(0.95, 0.9, 0.82))  # upper face in shade, dark slit, lit lower face
			for v: Vector3 in [p0, p1, q1, p0, q1, q0]:
				var radial := Vector3(v.x, 0, v.z).normalized()
				st.set_color(col)
				st.set_normal((radial + Vector3.UP * face_tilt[k]).normalized())
				st.set_uv(Vector2(atan2(v.x, v.z) * r * 3.0, v.y * 3.0))
				st.add_vertex(v)
	return st.commit()


## Point on the notch lens: rows 0..3 = top edge, slit top, slit bottom, bottom edge.
func _lens(a: float, half_angle: float, h: float, r: float, row: int) -> Vector3:
	var w := sqrt(maxf(1.0 - pow(a / half_angle, 2.0), 0.0))
	var y: float = [h * 0.62 * w, h * 0.05 * w, -h * 0.06 * w, -h * 0.38 * w][row]
	return Vector3(sin(a) * r, y, cos(a) * r)


# ---------------------------------------------------------------- the real cut
# Like chopping in The Forest: every blow takes a chunk out of the trunk. Once a tree is first hit, its model's
# lower trunk is cut out of a per-tree copy of its mesh (_clipped_mesh) and replaced by a procedural section built
# from the measured trunk profile, with the original bark texture and UVs. A V notch is carved into it on the
# chopper's side: a flat lower cut and a sloped upper cut that deepen with each blow, fresh wood on the faces.
# When it goes over, the stump keeps a flat cut top and the falling trunk carries a cut butt end.

## Notch depth when the tree goes over, in trunk radii (just past the heart; the rest tears as it falls).
const NOTCH_MAX := 1.1
## Height of the sloped upper face per unit of depth (~45 degree face).
const NOTCH_SLOPE := 0.95
const CUT_SEGS := 32

var _cut_mode := false
var _cut_lower: MeshInstance3D  # stump + trunk up to the cut (stays)
var _cut_upper: MeshInstance3D  # cut band above it (falls with the tree)
var _clip_top := 0.0  # node-space height above which the original model is shown again
var _bark_mi: MeshInstance3D
var _bark_src: Material
var _bark_orig: Mesh
var _cut_end: MeshInstance3D  # fresh-cut top of the felled trunk where the last log came off
var _bare_for := -1  # remaining-logs count the bare trunk mesh was built for


## Current notch depth (metres into the trunk from the chopper's side).
func notch_depth() -> float:
	var k := 1.0 if stage != Stage.STANDING else clampf(float(chop) / float(fell_hits), 0.0, 1.0)
	return k * NOTCH_MAX * _trunk_r


func _enter_cut_mode() -> void:
	if _cut_mode:
		return
	_cut_mode = true
	_clip_top = cut_h + NOTCH_MAX * _trunk_r * NOTCH_SLOPE + 0.02
	var meshes := _tree.find_children("*", "MeshInstance3D", true, false)
	if not meshes.is_empty():
		_bark_mi = meshes[0]
		_bark_src = _bark_mi.get_active_material(0)
		_bark_orig = _bark_mi.mesh
		_bark_mi.mesh = _clipped_mesh(_bark_mi, (_clip_top + SINK) / _size)
	_cut_lower = MeshInstance3D.new()
	_cut_lower.name = "CutStump"
	add_child(_cut_lower)
	_cut_upper = MeshInstance3D.new()
	_cut_upper.name = "CutButt"
	_pivot.add_child(_cut_upper)
	_cut_end = MeshInstance3D.new()
	_cut_end.name = "CutEnd"
	_pivot.add_child(_cut_end)
	_bare_for = -1
	_stump_post.visible = false
	_stump_top.visible = false


func _exit_cut_mode() -> void:
	_cut_mode = false
	if _bark_mi and _bark_orig:
		_bark_mi.mesh = _bark_orig
	for m in [_cut_lower, _cut_upper, _cut_end]:
		if m and is_instance_valid(m):
			m.queue_free()
	_cut_lower = null
	_cut_upper = null
	_cut_end = null
	_stump_post.visible = true
	_stump_top.visible = true


## A copy of the tree mesh with the bark (surface 0) cut off below clip_y (mesh space): triangles crossing the
## line are clipped and their attributes interpolated, so the trunk ends exactly where our cut section begins.
## Keeps the model's own materials, so the bark looks identical. Other surfaces (foliage) are copied as-is.
static func _clipped_mesh(mi: MeshInstance3D, clip_y: float, src: Mesh = null, top_y: float = INF, bark_only := false) -> ArrayMesh:
	if src == null:
		src = mi.mesh
	var out := ArrayMesh.new()
	for si in src.get_surface_count():
		if bark_only and si > 0:
			continue  # felled: the crown is gone, only the bare trunk lies there
		var arrays := src.surface_get_arrays(si)
		if si == 0:
			arrays = _clip_arrays(arrays, clip_y)
			if top_y < INF:
				arrays = _clip_arrays(arrays, top_y, true)
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, mi.get_active_material(si))
	return out


## Drops branch geometry (triangles well away from the trunk axis) so the felled trunk is a clean log.
static func _strip_branches(mesh: ArrayMesh, prof: Array) -> ArrayMesh:
	var arrays := mesh.surface_get_arrays(0)
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var keep := PackedInt32Array()
	for f in range(0, pos.size(), 3):
		var c := (pos[f] + pos[f + 1] + pos[f + 2]) / 3.0
		var ring: Array = prof[0]
		for e: Array in prof:
			if float(e[0]) <= c.y:
				ring = e
		# Above the measured rings (they stop at 4 m) keep a generous core so the upper trunk is not dropped.
		var lim := maxf(float(ring[3]), 0.08) * 1.45
		if Vector2(c.x - float(ring[1]), c.z - float(ring[2])).length() <= lim:
			keep.append(f)
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	for k in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV]:
		if arrays[k] == null:
			continue
		var src = arrays[k]
		var dst = src.duplicate()
		dst.resize(keep.size() * 3)
		var n := 0
		for f in keep:
			for j in 3:
				dst[n] = src[f + j]
				n += 1
		out[k] = dst
	if arrays[Mesh.ARRAY_TANGENT] != null:
		var ts: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
		var td := PackedFloat32Array()
		for f in keep:
			for j in 3:
				for q in 4:
					td.append(ts[(f + j) * 4 + q])
		out[Mesh.ARRAY_TANGENT] = td
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	m.surface_set_material(0, mesh.surface_get_material(0))
	return m


static func _clip_arrays(arrays: Array, clip_y: float, keep_below := false) -> Array:
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var nrm: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var tan: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] != null else PackedFloat32Array()
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		for i in pos.size():
			idx.append(i)
	var o_pos := PackedVector3Array()
	var o_nrm := PackedVector3Array()
	var o_tan := PackedFloat32Array()
	var o_uv := PackedVector2Array()
	var emit := func(i: int, j: int, t: float) -> void:
		o_pos.append(pos[i].lerp(pos[j], t))
		if not nrm.is_empty():
			o_nrm.append(nrm[i].lerp(nrm[j], t).normalized())
		if not tan.is_empty():
			for k in 4:
				o_tan.append(lerpf(tan[i * 4 + k], tan[j * 4 + k], t) if k < 3 else tan[i * 4 + 3])
		if not uv.is_empty():
			o_uv.append(uv[i].lerp(uv[j], t))
	for f in range(0, idx.size(), 3):
		var tri := [idx[f], idx[f + 1], idx[f + 2]]
		# Sutherland-Hodgman against the plane y = clip_y, keeping the part above; then fan back to triangles.
		var poly: Array = []  # [i, j, t] = point at lerp(vertex i, vertex j, t)
		for k in 3:
			var a: int = tri[k]
			var b: int = tri[(k + 1) % 3]
			var ia := (pos[a].y >= clip_y) != keep_below
			var ib := (pos[b].y >= clip_y) != keep_below
			if ia:
				poly.append([a, a, 0.0])
			if ia != ib:
				var t := (clip_y - pos[a].y) / (pos[b].y - pos[a].y)
				poly.append([a, b, t])
		for k in range(1, poly.size() - 1):
			for e: Array in [poly[0], poly[k], poly[k + 1]]:
				emit.call(e[0], e[1], e[2])
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = o_pos
	if not o_nrm.is_empty():
		out[Mesh.ARRAY_NORMAL] = o_nrm
	if not o_tan.is_empty():
		out[Mesh.ARRAY_TANGENT] = o_tan
	if not o_uv.is_empty():
		out[Mesh.ARRAY_TEX_UV] = o_uv
	return out


## Depth of the notch at height y (0 outside the notch): full at the flat lower cut, tapering up the slope.
func _depth_at(y: float, depth: float, rise: float) -> float:
	if depth <= 0.0 or y <= cut_h or y > cut_h + rise:
		return 0.0
	return depth * (1.0 - (y - cut_h) / rise)


## One ring of the trunk at height y, carved by the notch plane: [positions, cut flags, uvs, centre].
func _cut_ring(y: float, dep: float) -> Array:
	var t := _trunk_at(y)
	var c := Vector3(t.x, y, t.y)
	var big_r := t.z / 0.96  # vertex radius of the model's faceted trunk
	var facet := _facets(y)
	var toward := Vector3(-fall_dir.x, 0, -fall_dir.z).normalized()
	var yaw := _visual.rotation.y
	var wrap := 1.5 if species == &"alder" else 2.0
	var v := _bark_v(y)
	var pts: Array[Vector3] = []
	var cuts: Array[bool] = []
	var uvs: Array[Vector2] = []
	var off := big_r - dep
	# Where the cut plane meets the bark: two angles either side of the chopper's direction.
	var a_t := atan2(toward.x, toward.z)
	var half := acos(clampf(off / big_r, -1.0, 1.0)) if dep > 0.0 else 0.0
	var state: Array[int] = []  # 0 bark, 1 cut wood, 2 exactly on the cut edge (both)
	var angles: Array[float] = []
	for i in CUT_SEGS + 1:
		var a := TAU * i / CUT_SEGS
		var da := absf(wrapf(a - a_t, -PI, PI))
		angles.append(a)
		state.append(1 if dep > 0.0 and da < half else 0)
	# Snap bark vertices next to the cut onto the exact edge, so the cut outline is smooth, not stepped.
	if dep > 0.0 and half > 0.0:
		for i in CUT_SEGS + 1:
			if state[i] != 0:
				continue
			var nb_cut := (i > 0 and state[i - 1] == 1) or (i < CUT_SEGS and state[i + 1] == 1)
			if nb_cut:
				var e1 := a_t + half
				var e2 := a_t - half
				var d1 := absf(wrapf(angles[i] - e1, -PI, PI))
				var d2 := absf(wrapf(angles[i] - e2, -PI, PI))
				var e := e1 if d1 < d2 else e2
				angles[i] = angles[i] + wrapf(e - angles[i], -PI, PI)
				state[i] = 2
	for i in CUT_SEGS + 1:
		var a := angles[i]
		var d := Vector3(sin(a), 0, cos(a))
		var r := _poly_r(a - yaw, big_r, facet)
		if state[i] == 1:
			var tt := d.dot(toward)
			r = minf(r, clampf(off / tt, 0.0, big_r)) if tt > 0.001 else 0.0
		pts.append(c + d * r)
		cuts.append(state[i] == 1)
		# Continuous along the ring (no wrap in the middle): the texture repeats anyway.
		uvs.append(Vector2((rad_to_deg(a - yaw) - 90.0) / 360.0 * wrap, v))
	var ring_state := state
	# Normal of the cut face through this ring: the sloped upper face looks down and out of the notch.
	var slope_n := (toward - Vector3.UP / NOTCH_SLOPE).normalized() if y > cut_h + 0.001 else Vector3.UP
	return [pts, cuts, uvs, c, slope_n, ring_state]


static var _section_mats: Dictionary = {}


## Bark for our cut section: the model's material with a softer normal map. Our smooth lathe catches light
## differently from the model's faceted trunk; at full strength the band reads darker than the bark above it.
func _section_bark() -> Material:
	var b := _bark_src as BaseMaterial3D
	if b == null:
		return _bark_src
	if not _section_mats.has(b):
		var m := b.duplicate() as BaseMaterial3D
		m.normal_scale = b.normal_scale * 0.3
		_section_mats[b] = m
	return _section_mats[b]


func _rebuild_cut() -> void:
	if not _cut_mode:
		return
	var depth := notch_depth()
	var rise := maxf(depth * NOTCH_SLOPE, 0.002)
	var cut_mat := Graybox.tex("CutWood", Color(1.22, 1.1, 0.94), 4.0)
	# Lower: underground base -> the flat lower cut, with a fresh-wood top (seen in the notch, and on the stump).
	var lower: Array = []
	for y: float in [-SINK, (cut_h - SINK) * 0.5, cut_h]:
		lower.append(_cut_ring(y, 0.0))
	var lm := _CutMesh.new(_section_bark(), cut_mat)
	lm.lathe(lower)
	lm.cap(lower[lower.size() - 1], Vector3.UP)
	_cut_lower.mesh = lm.commit()
	# Upper: from just above the lower cut, through the sloped upper cut, up past the clip line.
	var upper: Array = []
	var ys: Array[float] = [cut_h + 0.002]
	for k in range(1, 25):
		ys.append(cut_h + rise * k / 24.0)
	ys.append((cut_h + rise + _clip_top) * 0.5)
	ys.append(_clip_top)
	for y in ys:
		upper.append(_cut_ring(y, _depth_at(y, depth, rise) if y > cut_h + 0.001 else depth))
	var um := _CutMesh.new(_section_bark(), cut_mat)
	um.lathe(upper)
	um.cap(upper[0], Vector3.DOWN)
	_cut_upper.mesh = um.commit()
	_cut_upper.position = Vector3(0, -cut_h, 0)


## Builds a lathed trunk section (bark outside, fresh wood where the notch cuts it) plus flat cut caps.
class _CutMesh:
	var bark := SurfaceTool.new()
	var wood := SurfaceTool.new()
	var bark_mat: Material
	var wood_mat: Material
	var counts := {}  # SurfaceTool -> triangles added

	func _init(p_bark: Material, p_wood: Material) -> void:
		bark_mat = p_bark
		wood_mat = p_wood
		bark.begin(Mesh.PRIMITIVE_TRIANGLES)
		wood.begin(Mesh.PRIMITIVE_TRIANGLES)

	func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3,
			ua: Vector2, ub: Vector2, uc: Vector2) -> void:
		if (b - a).cross(c - a).dot(na + nb + nc) > 0.0:  # Godot front faces wind clockwise
			var t := b
			b = c
			c = t
			var tn := nb
			nb = nc
			nc = tn
			var tu := ub
			ub = uc
			uc = tu
		counts[st] = int(counts.get(st, 0)) + 1
		for e: Array in [[a, na, ua], [b, nb, ub], [c, nc, uc]]:
			st.set_normal(e[1])
			st.set_uv(e[2])
			st.add_vertex(e[0])

	## Bark normal: radial, tilted up a little like the model's (its trunk tapers), so both catch the same light.
	func _bark_n(rv: Vector3) -> Vector3:
		return (Vector3(rv.x, 0, rv.z).normalized() + Vector3.UP * 0.06).normalized()

	func lathe(rings: Array) -> void:
		for j in rings.size() - 1:
			var r0: Array = rings[j]
			var r1: Array = rings[j + 1]
			var p0: Array = r0[0]
			var p1: Array = r1[0]
			for i in p0.size() - 1:
				var q := [p0[i], p0[i + 1], p1[i + 1], p1[i]]
				var uvq := [r0[2][i], r0[2][i + 1], r1[2][i + 1], r1[2][i]]
				var st4 := [r0[5][i], r0[5][i + 1], r1[5][i + 1], r1[5][i]]
				var has_cut: bool = 1 in st4
				var has_bark: bool = 0 in st4
				if has_cut and has_bark:
					# Straddles the edge (rows differ): split by triangle so each side keeps its own material.
					for tri: Array in [[0, 1, 2], [0, 2, 3]]:
						var tw := 0
						for k: int in tri:
							tw += 1 if st4[k] == 1 else (-1 if st4[k] == 0 else 0)
						if tw > 0:
							var nn: Vector3 = r1[4]
							_tri(wood, q[tri[0]], q[tri[1]], q[tri[2]], nn, nn, nn, uvq[tri[0]], uvq[tri[1]], uvq[tri[2]])
						else:
							var nb := []
							for k: int in tri:
								var ax: Vector3 = r0[3] if k < 2 else r1[3]
								var rv: Vector3 = q[k] - ax
								nb.append(_bark_n(rv))
							_tri(bark, q[tri[0]], q[tri[1]], q[tri[2]], nb[0], nb[1], nb[2], uvq[tri[0]], uvq[tri[1]], uvq[tri[2]])
					continue
				if has_cut:
					# Fresh wood on the cut plane: one shared normal per face so it reads as a clean flat cut.
					var n: Vector3 = r1[4]
					_tri(wood, q[0], q[1], q[2], n, n, n, uvq[0], uvq[1], uvq[2])
					_tri(wood, q[0], q[2], q[3], n, n, n, uvq[0], uvq[2], uvq[3])
				else:
					var ns := []
					for k in 4:
						var ax: Vector3 = r0[3] if k < 2 else r1[3]
						var rv: Vector3 = q[k] - ax
						ns.append(_bark_n(rv))
					_tri(bark, q[0], q[1], q[2], ns[0], ns[1], ns[2], uvq[0], uvq[1], uvq[2])
					_tri(bark, q[0], q[2], q[3], ns[0], ns[2], ns[3], uvq[0], uvq[2], uvq[3])

	## Flat cut face across a ring (fan from the centroid of what is left of the cross-section).
	func cap(ring: Array, n: Vector3) -> void:
		var pts: Array = ring[0]
		var centre := Vector3.ZERO
		for p: Vector3 in pts:
			centre += p
		centre /= pts.size()
		for i in pts.size() - 1:
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[i + 1]
			if a.distance_to(b) < 1e-5:
				continue
			_tri(wood, centre, a, b, n, n, n, Vector2(centre.x, centre.z) * 3.0, Vector2(a.x, a.z) * 3.0, Vector2(b.x, b.z) * 3.0)

	func commit() -> ArrayMesh:
		var mesh := ArrayMesh.new()
		for e: Array in [[bark, bark_mat], [wood, wood_mat]]:
			if int(counts.get(e[0], 0)) > 0:
				(e[0] as SurfaceTool).generate_tangents()  # the bark normal map needs them
				(e[0] as SurfaceTool).commit(mesh)
				mesh.surface_set_material(mesh.get_surface_count() - 1, e[1])
		return mesh


# ---------------------------------------------------------------- bucking (felled trunk -> logs)

## Length of usable trunk on a felled tree (the thin top and the crown are not worth bucking).
func _trunk_len() -> float:
	# Up to where the trunk is still a single stem in the model (its last whole bark ring), not into the fork.
	var stem_top := (float(_trunk_profile()[-1][0]) + 0.15) * _size - SINK
	return clampf(stem_top - cut_h, 1.2, (height - cut_h) * 0.72)


## Height (along the trunk, node space as if standing) of the trunk's end with n logs left on it.
func _log_top(n: int) -> float:
	return cut_h + _trunk_len() * float(n) / float(maxi(capacity, 1))


## Felled: the crown is gone and the trunk ends in a fresh cut where the last log came off.
func _make_bare_trunk() -> void:
	if not _cut_mode or _bark_mi == null or _bare_for == remaining:
		return
	_bare_for = remaining
	var top := _log_top(remaining)
	var bare := _clipped_mesh(_bark_mi, (_clip_top + SINK) / _size, _bark_orig, (top + SINK) / _size, true)
	_bark_mi.mesh = _strip_branches(bare, _trunk_profile())
	var ring := _cut_ring(top, 0.0)
	var cm := _CutMesh.new(_section_bark(), Graybox.tex("CutWood", Color(1.22, 1.1, 0.94), 4.0))
	cm.cap(ring, Vector3.UP)
	_cut_end.mesh = cm.commit()
	_cut_end.position = Vector3(0, -cut_h, 0)


## Cuts the top log off the felled trunk: a real piece of this tree rolls away as a pickup.
func _buck_log() -> void:
	var world := _world()
	var y1 := _log_top(remaining)
	var y0 := _log_top(remaining - 1) if remaining > 1 else cut_h + 0.02
	var mid := (y0 + y1) * 0.5
	var t := _trunk_at(mid)
	var c := Vector3(t.x, mid, t.y)
	var rings: Array = []
	for y: float in [y0, mid, y1]:
		var r: Array = _cut_ring(y, 0.0)
		var pts: Array[Vector3] = []
		for q: Vector3 in r[0]:
			pts.append(q - c)
		r[0] = pts
		r[3] = (r[3] as Vector3) - c
		rings.append(r)
	var lm := _CutMesh.new(_section_bark(), Graybox.tex("CutWood", Color(1.22, 1.1, 0.94), 4.0))
	lm.lathe(rings)
	lm.cap(rings[0], Vector3.DOWN)
	lm.cap(rings[2], Vector3.UP)
	if world == null:
		return
	var log := LogPiece.new()
	log.name = "Log_%s_%d" % [node_id, remaining]
	log.setup_log(ItemStack.new(&"wood", 1), lm.commit(), t.z, y1 - y0)
	# The new log overlaps the trunk it was cut from until the trunk's collider is shortened: without an
	# exception the physics pushes them apart violently (the log used to shoot metres into the air).
	log.add_collision_exception_with(self)
	world.pickups_root.add_child(log)
	var xf := _pivot.global_transform * Transform3D(Basis(), Vector3(0, -cut_h, 0)) * Transform3D(Basis(), c)
	var o := xf.origin
	o.y = maxf(o.y, world.height_at(o.x, o.z) + t.z + 0.05)  # never inside the ground (it would fall through)
	log.global_transform = Transform3D(xf.basis.orthonormalized(), o)
	# Rolls off sideways a little, as a freshly cut log does, then settles.
	var side := _axis() * (1.0 if randf() < 0.5 else -1.0)
	log.linear_velocity = side * 0.8 + Vector3.UP * 0.3
	log.angular_velocity = Vector3.ZERO
	var me := self
	get_tree().create_timer(1.5).timeout.connect(func() -> void:
		if is_instance_valid(log) and is_instance_valid(me):
			log.remove_collision_exception_with(me))


## Direction of the felled trunk (butt to top), node space.
func _trunk_dir() -> Vector3:
	return Basis(_axis(), final_angle) * Vector3.UP


func _axis() -> Vector3:
	return Vector3.UP.cross(fall_dir).normalized()


func _place_log_shape() -> void:
	var b := Basis(_axis(), final_angle)
	var length := _log_top(remaining) - cut_h if stage == Stage.FALLEN else height - cut_h
	(_log_shape.shape as CylinderShape3D).height = maxf(length, 0.3)
	_log_shape.transform = Transform3D(b, _log_base() + b * Vector3(0, length * 0.5, 0))


## Hinge of the felled trunk (node space): the trunk centre at the cut.
func _log_base() -> Vector3:
	return Vector3(_trunk_c.x, cut_h, _trunk_c.y)


# ---------------------------------------------------------------- interaction

func get_display_name() -> String:
	match stage:
		Stage.FALLEN: return Loc.t("NODE_FALLEN_TRUNK")
		Stage.CLEARED: return Loc.t("NODE_STUMP")
	return Loc.t("TREE_%s" % String(species).to_upper())


func get_status_text() -> String:
	match stage:
		Stage.STANDING:
			return Loc.t("STATUS_CHOPPED", {"n": chop, "m": fell_hits}) if chop > 0 else ""
		Stage.FALLEN:
			if not limbed():
				return Loc.t("STATUS_LIMB", {"n": limb, "m": LIMB_HITS})
			return Loc.t("STATUS_LOGS_LEFT", {"n": remaining})
	return ""


func get_interactions(player: Node) -> Array:
	if stage in [Stage.FALLING, Stage.CLEARED]:
		return []
	var hand: ItemStack = player.inventory.hand
	var ok := hand != null and hand.get_data().has_tag(&"tool_axe")
	var act := "ACT_FELL" if stage == Stage.STANDING else ("ACT_LIMB" if not limbed() else "ACT_BUCK")
	var text := Loc.t(act) if ok else Loc.t("NEED_TOOL_AXE")
	return [{"action": &"primary_action", "text": text, "hold": 0.0, "enabled": ok, "swing": true}]


func perform_interaction(_player: Node, _action: StringName) -> void:
	pass


func on_hit(player: Node, item: ItemData) -> bool:
	if stage in [Stage.FALLING, Stage.CLEARED]:
		return false
	if item == null or not item.has_tag(&"tool_axe"):
		Events.toast(Loc.t("NEED_TOOL_AXE"), &"warn")
		return false
	var p3 := player as Node3D
	var point := _impact_point(player)
	if stage == Stage.STANDING:
		if chop == 0:
			var away := global_position - p3.global_position
			away.y = 0.0
			fall_dir = away.normalized() if away.length() > 0.01 else Vector3(0, 0, 1)
			cut_h = clampf(point.y - global_position.y, 0.4, 1.3)
			_apply_cut_height()
		chop += 1
		_wobble = 1.0
		# Every blow lands in the notch: chips burst out of it, along the bark, toward the chopper.
		var out := -fall_dir
		# Chips fly out of the notch itself: inside the cut, just above the flat lower face.
		var dep := clampf(float(chop) / float(fell_hits), 0.0, 1.0) * NOTCH_MAX * _trunk_r
		var notch := to_global(Vector3(_trunk_c.x, cut_h + dep * NOTCH_SLOPE * 0.3, _trunk_c.y) + out * maxf(_trunk_r - dep * 0.6, 0.0))
		_chips(notch, out, false)
		_sawdust(notch, out)
		_drop_debris(out, 3)
		_shed_crown(chop >= fell_hits)
		Sfx.play(&"axe_chop", notch)
		if regrow_seconds > 0.0 and regrow_left <= 0.0:
			regrow_left = 0.0
		if chop >= fell_hits:
			_start_fall()
		_refresh()
		return true
	# FALLEN, crown still on: lop the branches off first (leaves fly, sticks drop beside the trunk).
	if not limbed():
		limb += 1
		var crown := _crown_point()
		_dust(crown, true)
		Sfx.play(&"rustle", crown, 2.0)
		Sfx.play(&"axe_chop", crown, -4.0)
		if limbed():
			_crown_collapse()
			_drop_branches()
			_refresh()
		return true
	# FALLEN: buck into logs -- chips come off the log's surface where the axe bit.
	var bite := _log_surface_point(point)
	_chips(bite[0], bite[1], true)
	_sawdust(bite[0], bite[1])
	Sfx.play(&"axe_chop", bite[0], -2.0)
	_buck_log()
	remaining -= 1
	if remaining <= 0:
		_clear()
	_refresh()
	return true


## The lopped crown doesn't blink out: a copy of it sags into the ground and fades while the leaves fly.
func _crown_collapse() -> void:
	if _holder == null or not is_inside_tree():
		return
	var ghost := _holder.duplicate() as Node3D
	get_parent().add_child(ghost)
	ghost.global_transform = _holder.global_transform
	_dust(_crown_point(), true)
	var tw := ghost.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ghost, "global_position", ghost.global_position + Vector3.DOWN * 1.2, 1.1).set_ease(Tween.EASE_IN)
	tw.tween_property(ghost, "scale", ghost.scale * Vector3(0.9, 0.7, 0.9), 1.1)
	tw.chain().tween_callback(ghost.queue_free)


func limbed() -> bool:
	return limb >= LIMB_HITS


## The middle of the crown of the felled tree (world).
func _crown_point() -> Vector3:
	var b := Basis(_axis(), final_angle)
	return to_global(_log_base() + b * Vector3(0, (height - cut_h) * 0.7, 0))


func _impact_point(player: Node) -> Vector3:
	var ray: RayCast3D = player.get("ray")
	if ray and ray.is_colliding():
		return ray.get_collision_point()
	return global_position + Vector3.UP * cut_h - fall_dir * 0.33


## Where an axe aimed at `aim` (world) bites into the lying trunk: [point on the bark, outward normal].
func _log_surface_point(aim: Vector3) -> Array:
	var b := Basis(_axis(), final_angle)
	var base := to_global(_log_base())
	var dir := global_basis * (b * Vector3.UP)
	var along := clampf((aim - base).dot(dir), 0.3, (height - cut_h) * 0.8)
	var q := base + dir * along
	var normal := aim - q
	normal -= dir * normal.dot(dir)
	if normal.length() < 0.01:
		normal = Vector3.UP
	normal = normal.normalized()
	var r := _trunk_at(cut_h + along).z
	return [q + normal * r, normal]


# ---------------------------------------------------------------- felling

func _start_fall() -> void:
	stage = Stage.FALLING
	_creak_t = CREAK_TIME
	fall_angle = 0.0
	fall_vel = 0.0
	_bounced = false
	final_angle = _landing_angle()
	Sfx.play(&"tree_creak", global_position + Vector3.UP * 3.0, 2.0, 0.0)
	Events.toast(Loc.t("MSG_TIMBER"), &"warn")


## Angle at which the crown meets the terrain in the fall direction.
func _landing_angle() -> float:
	var world := _world()
	if world == null:
		return deg_to_rad(86.0)
	var base := global_position + Vector3.UP * cut_h
	for deg in range(55, 101):
		var b := Basis(_axis(), deg_to_rad(deg))
		var tip := base + b * Vector3(0, (height - cut_h) * 0.85, 0)
		if tip.y <= world.height_at(tip.x, tip.z) + 1.2:
			return deg_to_rad(deg)
	return deg_to_rad(100.0)


func _physics_process(delta: float) -> void:
	if stage == Stage.STANDING and _wobble > 0.0:
		_wobble = maxf(_wobble - delta * 2.2, 0.0)
		_wobble_t += delta
		_pivot.basis = Basis(_axis(), sin(_wobble_t * 16.0) * 0.012 * _wobble)
	if stage != Stage.FALLING:
		return
	if _creak_t > 0.0:
		# Fibres give way: a slow, small lean before the real fall.
		_creak_t -= delta
		fall_angle = lerpf(fall_angle, deg_to_rad(3.0), delta * 2.0)
		_pivot.basis = Basis(_axis(), fall_angle)
		return
	var length := maxf(height - cut_h, 2.0)
	var alpha := 1.5 * 9.8 / length * sin(fall_angle)
	fall_vel += alpha * delta
	fall_angle += fall_vel * delta
	if fall_angle >= final_angle:
		fall_angle = final_angle
		if not _bounced:
			_bounced = true
			fall_vel = -fall_vel * 0.16
			_impact()
		elif absf(fall_vel) < 0.05 or fall_vel > 0.0:
			complete_fall()
			return
	_pivot.basis = Basis(_axis(), fall_angle)


func _impact() -> void:
	var world := _world()
	var base := global_position + Vector3.UP * cut_h
	var b := Basis(_axis(), final_angle)
	var tip := base + b * Vector3(0, height - cut_h, 0)
	Sfx.play(&"collapse", base.lerp(tip, 0.5))
	for k in [0.35, 0.6, 0.85]:
		_dust(base.lerp(tip, k), k > 0.5)
	if world and world.player:
		var p := world.player as Node3D
		var d := p.global_position.distance_to(base.lerp(tip, 0.5))
		if d < 30.0 and p.has_method("shake"):
			p.shake(clampf(1.0 - d / 30.0, 0.15, 0.8))
		# Anyone standing under the trunk gets hit.
		var seg := _segment_distance(Vector2(p.global_position.x, p.global_position.z), Vector2(base.x, base.z), Vector2(tip.x, tip.z))
		if seg < 1.3 and p.has_method("take_hit"):
			p.take_hit(FALL_DAMAGE, &"tree", 0.3, base)


static func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Finishes the fall immediately (also used for loading saves and time skips).
func complete_fall() -> void:
	var was_falling := stage == Stage.FALLING
	stage = Stage.FALLEN
	fall_angle = final_angle
	fall_vel = 0.0
	remaining = capacity
	limb = 0
	_refresh()


func _drop_branches() -> void:
	var world := _world()
	if world == null:
		return
	var b := Basis(_axis(), final_angle)
	var base := global_position + Vector3.UP * cut_h
	var branches: Dictionary = cfg.get("branches", {})
	var i := 0
	for id: String in branches.keys():
		for n in int(branches[id]):
			var at := base + b * Vector3(0, (height - cut_h) * (0.45 + 0.12 * i), 0)
			at.y = world.height_at(at.x, at.z) + 0.6
			world.spawn_pickup(ItemStack.new(StringName(id), 1), at + fall_dir.cross(Vector3.UP) * (0.8 if i % 2 == 0 else -0.8))
			i += 1


func _clear() -> void:
	stage = Stage.CLEARED
	remaining = 0
	if regrow_seconds > 0.0:
		regrow_left = regrow_seconds
	Sfx.play(&"dismantle", global_position + Vector3.UP, -6.0)


func simulate(seconds: float) -> void:
	if stage == Stage.FALLING and seconds > 2.0:
		complete_fall()
	if stage != Stage.CLEARED or regrow_seconds <= 0.0:
		return
	regrow_left -= seconds
	if regrow_left <= 0.0:
		regrow_left = 0.0
		stage = Stage.STANDING
		chop = 0
		remaining = capacity
		cut_h = DEFAULT_CUT
		_apply_cut_height()
		for c in _debris.get_children():
			c.queue_free()
		_refresh()


# ---------------------------------------------------------------- effects

## Wood chips out of the cut. `out` = outward bark normal at the bite. Fresh-wood chips fly out and up in a
## cone and tumble; a few dark bark flakes peel off and drop almost straight down. They spawn from a small
## patch *on* the bark (just outside the surface), never in the air in front of it.
func _chips(at: Vector3, out: Vector3, on_log: bool) -> void:
	_ensure_chip_assets()
	var start := at + out * 0.02
	for bark in [false, true]:
		var p := CPUParticles3D.new()
		p.one_shot = true
		p.explosiveness = 0.97
		p.amount = (5 if bark else 12) if not on_log else (3 if bark else 9)
		p.lifetime = 1.4 if not bark else 1.1
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		p.emission_sphere_radius = 0.035
		p.direction = (out + Vector3.UP * (0.55 if not bark else 0.1)).normalized()
		p.spread = 38.0 if not bark else 60.0
		p.initial_velocity_min = 1.8 if not bark else 0.4
		p.initial_velocity_max = 4.2 if not bark else 1.2
		p.gravity = Vector3(0, -9.8, 0)
		p.damping_min = 0.6  # light, flat chips lose speed in the air
		p.damping_max = 1.4
		p.angular_velocity_min = -900.0
		p.angular_velocity_max = 900.0
		p.scale_amount_min = 0.5
		p.scale_amount_max = 1.3
		var shrink := Curve.new()
		shrink.add_point(Vector2(0, 1))
		shrink.add_point(Vector2(0.8, 1))
		shrink.add_point(Vector2(1, 0))
		p.scale_amount_curve = shrink
		p.mesh = _chip_mesh
		p.material_override = _bark_chip_mat if bark else _chip_mat
		_one_shot(p, start)


## A short puff of fine sawdust where the blade bites.
func _sawdust(at: Vector3, out: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.9
	p.amount = 10
	p.lifetime = 0.9
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.04
	p.direction = out
	p.spread = 45.0
	p.initial_velocity_min = 0.4
	p.initial_velocity_max = 1.3
	p.damping_min = 1.5
	p.damping_max = 2.5
	p.gravity = Vector3(0, -0.6, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.2
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.5))
	grow.add_point(Vector2(1, 1.4))
	p.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.set_color(0, Color(0.72, 0.6, 0.44, 0.28))
	fade.set_color(1, Color(0.78, 0.66, 0.48, 0.0))
	p.color_ramp = fade
	p.mesh = _puff_quad(0.07)
	_one_shot(p, at + out * 0.03)


## Chips that land stay on the ground on the chopper's side of the trunk until the tree grows back.
func _drop_debris(out: Vector3, n: int) -> void:
	var world := _world()
	if world == null or _debris.get_child_count() >= MAX_DEBRIS:
		return
	_ensure_chip_assets()
	var side := out.cross(Vector3.UP)
	for i in n:
		var c := Vector3(_trunk_c.x, 0, _trunk_c.y) + out * randf_range(_trunk_r + 0.25, _trunk_r + 1.4) \
			+ side * randf_range(-0.7, 0.7)
		var g := to_global(c)
		var chip := MeshInstance3D.new()
		chip.mesh = _chip_mesh
		chip.material_override = _chip_mat if randf() > 0.25 else _bark_chip_mat
		chip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_debris.add_child(chip)
		chip.global_position = Vector3(g.x, world.height_at(g.x, g.z) + 0.004, g.z)
		chip.rotation = Vector3(randf_range(-0.25, 0.25), randf() * TAU, randf_range(-0.25, 0.25))
		chip.scale = Vector3.ONE * randf_range(1.3, 2.4)


## Each blow shakes a few leaves / needles out of the crown; the final ones loosen a shower.
func _shed_crown(last: bool) -> void:
	var lv := CPUParticles3D.new()
	lv.one_shot = true
	lv.explosiveness = 0.6
	lv.amount = 16 if last else 5
	lv.lifetime = 4.5
	lv.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	lv.emission_sphere_radius = 1.8 if species == &"alder" else 1.2
	lv.direction = Vector3.DOWN
	lv.spread = 40.0
	lv.initial_velocity_min = 0.1
	lv.initial_velocity_max = 0.5
	lv.gravity = Vector3(0, -0.9, 0)  # flutter down slowly
	lv.damping_min = 0.3
	lv.damping_max = 0.8
	lv.angular_velocity_min = -220.0
	lv.angular_velocity_max = 220.0
	lv.mesh = Graybox.box(Vector3(0.045, 0.004, 0.03) if species == &"alder" else Vector3(0.006, 0.004, 0.04))
	lv.material_override = Graybox.mat(Color(0.35, 0.42, 0.18) if species == &"alder" else Color(0.26, 0.32, 0.17))
	_one_shot(lv, global_position + Vector3.UP * height * (0.62 if species == &"alder" else 0.5))


## Fresh-cut wood that takes the notch mesh's vertex colours (shaded upper face, dark slit, lit lower face).
static func _notch_material() -> Material:
	if _notch_mat == null:
		var m := Graybox.tex("CutWood", Color(1.15, 1.06, 0.92), 6.0).duplicate() as StandardMaterial3D
		m.vertex_color_use_as_albedo = true
		_notch_mat = m
	return _notch_mat


static func _ensure_chip_assets() -> void:
	if _chip_mesh:
		return
	_chip_mesh = Graybox.box(Vector3(0.026, 0.006, 0.042))
	_chip_mat = Graybox.tex("CutWood", Color(1.25, 1.14, 0.98), 8.0)
	_bark_chip_mat = Graybox.tex("Log", Color(0.8, 0.75, 0.7), 8.0)


static var _puff_quads: Dictionary = {}


## Camera-facing soft round quad (vertex colour = particle colour ramp).
static func _puff_quad(size: float) -> QuadMesh:
	if _puff_quads.has(size):
		return _puff_quads[size]
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	m.albedo_texture = gt
	quad.material = m
	_puff_quads[size] = quad
	return quad


func _dust(at: Vector3, leaves: bool) -> void:
	var dust := CPUParticles3D.new()
	dust.one_shot = true
	dust.explosiveness = 0.9
	dust.amount = 18
	dust.lifetime = 2.4
	dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	dust.emission_sphere_radius = 1.4
	dust.direction = Vector3.UP
	dust.spread = 70.0
	dust.initial_velocity_min = 0.4
	dust.initial_velocity_max = 1.6
	dust.gravity = Vector3(0, -0.3, 0)
	dust.scale_amount_min = 1.0
	dust.scale_amount_max = 2.6
	var grow := Curve.new()
	grow.add_point(Vector2(0, 0.4))
	grow.add_point(Vector2(1, 1.0))
	dust.scale_amount_curve = grow
	var fade := Gradient.new()
	fade.set_color(0, Color(0.42, 0.37, 0.3, 0.35))
	fade.set_color(1, Color(0.42, 0.37, 0.3, 0.0))
	dust.color_ramp = fade
	var quad := QuadMesh.new()
	quad.size = Vector2(0.9, 0.9)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	m.albedo_texture = gt
	quad.material = m
	dust.mesh = quad
	_one_shot(dust, at)
	if leaves:
		var lv := CPUParticles3D.new()
		lv.one_shot = true
		lv.explosiveness = 0.85
		lv.amount = 24
		lv.lifetime = 2.6
		lv.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		lv.emission_sphere_radius = 2.0
		lv.direction = Vector3.UP
		lv.spread = 80.0
		lv.initial_velocity_min = 1.0
		lv.initial_velocity_max = 3.0
		lv.gravity = Vector3(0, -1.2, 0)
		lv.angular_velocity_min = -300.0
		lv.angular_velocity_max = 300.0
		lv.mesh = Graybox.box(Vector3(0.05, 0.005, 0.03))
		lv.material_override = Graybox.mat(Color(0.25, 0.33, 0.16) if species != &"alder" else Color(0.35, 0.42, 0.18))
		_one_shot(lv, at)


func _one_shot(p: CPUParticles3D, at: Vector3) -> void:
	var world := _world()
	var parent: Node = world if world else self
	parent.add_child(p)
	p.global_position = at
	p.emitting = true
	get_tree().create_timer(p.lifetime + 0.5).timeout.connect(p.queue_free)


func _world() -> ForestWorld:
	var n := get_parent()
	while n != null and not n is ForestWorld:
		n = n.get_parent()
	return n as ForestWorld


# ---------------------------------------------------------------- persistence

func is_modified() -> bool:
	return stage != Stage.STANDING or chop > 0


func save_state() -> Dictionary:
	return {"stage": int(stage), "chop": chop, "dir": [fall_dir.x, fall_dir.z], "r": remaining,
		"g": regrow_left, "angle": final_angle, "cut": cut_h, "limb": limb}


func load_state(d: Dictionary) -> void:
	var st := int(d.get("stage", 0))
	chop = int(d.get("chop", 0))
	var dir: Array = d.get("dir", [0, 1])
	fall_dir = Vector3(float(dir[0]), 0, float(dir[1])).normalized()
	final_angle = float(d.get("angle", deg_to_rad(86.0)))
	cut_h = float(d.get("cut", DEFAULT_CUT))
	_apply_cut_height()
	remaining = int(d.get("r", capacity))
	# older saves had no crown on felled trunks
	limb = int(d.get("limb", LIMB_HITS if st == Stage.FALLEN else 0))
	regrow_left = float(d.get("g", 0.0))
	stage = Stage.FALLEN if st == Stage.FALLING else st as Stage
	_refresh()
