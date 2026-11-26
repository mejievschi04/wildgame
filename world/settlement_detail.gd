extends RefCounted
## Settlement architecture from the Blender models (tools/blender/gen_buildings.py): four clan styles
## (player = thatch + yellow hand, stone = dry-stone + bull skull, north = mammoth tusks + furs, red = dyed hides
## + wolf) x hall / house / hut / canopy / tower / fence / gate / banner. The models face +Z (door) and reach
## ~0.5 m below their origin so they sit into uneven ground. Collision is a few simple boxes per building.

const DIR := "res://assets/models/buildings/"
const HutSmoke := preload("res://world/hut_smoke.gd")
const META_PATH := DIR + "buildings.json"
## How far each kind stays visible (m). Halls and towers mark a town from far away; fences fade sooner.
const VIEW := {"Hall": 1600.0, "Tower": 1600.0, "House": 1000.0, "Hut": 900.0, "Ruin": 900.0,
	"Canopy": 500.0, "Gate": 900.0, "Banner": 450.0, "Fence": 700.0, "FenceB": 700.0}
## How deep the origin may sit under the highest footprint point (more and the uphill side is buried).
const MAX_SINK := 0.45

static var _meta: Dictionary = {}


static func meta(model: String) -> Dictionary:
	if _meta.is_empty():
		_meta = JSON.parse_string(FileAccess.get_file_as_string(META_PATH))
	return _meta.get(model, {"footprint": [4.0, 4.0], "shape": "rect", "height": 4.0})


static func model_name(style: String, kind: String) -> String:
	return "%s_%s" % [style.capitalize(), kind]


static func path(style: String, kind: String) -> String:
	return DIR + "SM_Bld_%s.gltf" % model_name(style, kind)


## Snow in the cold north, a view distance per kind, shadows on.
static func dress(root: Node3D, kind: String, at: Vector3) -> void:
	var snowy := ForestWorld.taiga_at(at.x, at.z) > 0.05
	for mi: GeometryInstance3D in root.find_children("*", "GeometryInstance3D", true, false):
		if snowy:
			mi.material_overlay = Vegetation.snow_overlay()
		mi.visibility_range_end = float(VIEW.get(kind, 800.0))
		mi.visibility_range_end_margin = 60.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


## Lowest and highest ground under a footprint (half extents, rotated by yaw).
static func ground_span(world: ForestWorld, at: Vector2, yaw: float, half: Vector2) -> Vector2:
	var lo := INF
	var hi := -INF
	for p: Vector2 in [Vector2.ZERO, Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1),
			Vector2(0, 1), Vector2(0, -1), Vector2(1, 0), Vector2(-1, 0)]:
		var local := Vector2(p.x * half.x, p.y * half.y).rotated(-yaw)
		var h := world.height_at(at.x + local.x, at.y + local.y)
		lo = minf(lo, h)
		hi = maxf(hi, h)
	return Vector2(lo, hi)


## Ground height for a rigid footprint: low enough that the downhill side doesn't float, not so low that the
## uphill side is buried. On steeper ground a terrace (plinth) fills the gap below.
static func seat(world: ForestWorld, at: Vector2, yaw: float, half: Vector2) -> float:
	var span := ground_span(world, at, yaw, half)
	return clampf(span.x + 0.3, span.y - MAX_SINK, span.y)


static var _plinth_mat: StandardMaterial3D

## A dry-stone terrace under a building whose downhill side would float: rough rock walls down to the ground,
## packed earth on top. `drop` = how far below the floor the lowest ground lies.
static func plinth(body: StaticBody3D, half: Vector2, drop: float) -> void:
	if _plinth_mat == null:
		_plinth_mat = Graybox.tex("Rock", Color(0.78, 0.76, 0.72), 0.8)
	var depth := drop + 0.6
	var mi := MeshInstance3D.new()
	mi.name = "Terrace"
	var box := BoxMesh.new()
	box.size = Vector3(half.x * 2.0 + 0.9, depth, half.y * 2.0 + 0.9)
	box.subdivide_width = 4
	box.subdivide_depth = 4
	mi.mesh = box
	mi.material_override = _plinth_mat
	mi.position = Vector3.UP * (0.02 - depth * 0.5)
	body.add_child(mi)
	_box(body, Vector3.UP * (0.02 - depth * 0.5), box.size)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(body.get_path())
	for i in int((half.x + half.y) * 1.2):  # loose stones along the foot of the terrace
		var side := rng.randi() % 4
		var t := rng.randf_range(-1.0, 1.0)
		var p := Vector3(t * (half.x + 0.45), 0, (half.y + 0.5) * (1 if side % 2 else -1)) if side < 2 \
			else Vector3((half.x + 0.5) * (1 if side % 2 else -1), 0, t * (half.y + 0.45))
		var rock := AssetLib.instance(AssetLib.ROCKS[&"small"][i % 3])
		rock.position = p + Vector3.UP * rng.randf_range(-0.5, -0.1)
		rock.scale = Vector3.ONE * rng.randf_range(1.6, 2.6)
		rock.rotation.y = rng.randf() * TAU
		body.add_child(rock)


## A building as a StaticBody3D named `label` holding the model; returns it (null if the model is missing).
static func place(world: ForestWorld, parent: Node3D, label: String, style: String, kind: String, at: Vector2,
		yaw: float, size := Vector2.ZERO) -> StaticBody3D:
	var model := model_name(style, kind)
	var info := meta(model)
	var fp := Vector2(info.footprint[0], info.footprint[1])
	var s := Vector3.ONE
	if size != Vector2.ZERO:
		var sx := clampf(size.x / fp.x, 0.75, 1.4)
		var sz := clampf(size.y / fp.y, 0.75, 1.4)
		s = Vector3(sx, (sx + sz) * 0.5, sz)
		if info.shape == "round" and fp.x == fp.y:  # domes keep their shape
			s = Vector3.ONE * (sx + sz) * 0.5
	var half := Vector2(fp.x * s.x, fp.y * s.z) * 0.5
	var body := StaticBody3D.new()
	body.name = label
	body.collision_mask = 0
	var y := seat(world, at, yaw, half)
	body.position = Vector3(at.x, y, at.y)
	body.rotation.y = yaw
	parent.add_child(body, true)
	var drop := y - ground_span(world, at, yaw, half * 1.1).x
	if drop > 0.45 and kind not in ["Tower", "Canopy"]:
		plinth(body, half, drop)
	var visual := AssetLib.instance(path(style, kind))
	visual.name = "Model"
	visual.scale = s
	body.add_child(visual)
	dress(visual, kind, body.position)
	_collide(body, String(info.shape), half, float(info.height) * s.y)
	if info.has("smoke"):  # a lived-in hut: real hearth smoke out of its smoke hole
		var smoke := HutSmoke.new()
		smoke.name = "Smoke"
		smoke.position = Vector3(info.smoke[0], info.smoke[1], info.smoke[2]) * s
		body.add_child(smoke)
	return body


static func _collide(body: StaticBody3D, shape: String, half: Vector2, height: float) -> void:
	var wall_h := minf(2.6, height)
	match shape:
		"rect":  # three walls and the two halves of the door gable
			var t := 0.35
			_box(body, Vector3(-half.x + 0.3, wall_h * 0.5, 0), Vector3(t, wall_h, half.y * 2.0))
			_box(body, Vector3(half.x - 0.3, wall_h * 0.5, 0), Vector3(t, wall_h, half.y * 2.0))
			_box(body, Vector3(0, wall_h * 0.5, -half.y + 0.2), Vector3(half.x * 2.0, wall_h, t))
			var jamb := (half.x - 0.9) * 0.5
			for side: float in [-1.0, 1.0]:
				_box(body, Vector3(side * (0.9 + jamb), wall_h * 0.5, half.y - 0.2), Vector3(jamb * 2.0, wall_h, t))
		"round":  # a ring with the door gap at +Z
			const N := 14
			for i in N:
				var a := TAU * (i + 0.5) / N
				var dir := Vector2(sin(a), cos(a))
				if dir.y > 0.93:
					continue
				var p := Vector2(dir.x * half.x, dir.y * half.y) * 0.9
				var cs := _box(body, Vector3(p.x, wall_h * 0.5, p.y),
					Vector3(TAU * maxf(half.x, half.y) / N * 0.95, wall_h, 0.4))
				cs.rotation.y = a
		"open":
			for c: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				_box(body, Vector3(c.x * half.x * 0.95, 1.2, c.y * half.y * 0.95), Vector3(0.3, 2.4, 0.3))


static func _box(body: StaticBody3D, at: Vector3, size: Vector3) -> CollisionShape3D:
	return Graybox.add_shape(body, Graybox.box_shape(size), at)


## The lookout tower (the user's Tripo model, re-dyed per clan). `toward` = the point its ladder and banner face.
static func tower(world: ForestWorld, parent: Node3D, at: Vector2, style: String, toward: Vector2) -> void:
	var facing := (toward - at).normalized()
	var body := place(world, parent, "LookoutTower", style, "Tower", at, atan2(facing.x, facing.y))
	for c in body.get_children():
		if c is CollisionShape3D:
			c.free()
	_box(body, Vector3.UP * 1.8, Vector3(4.4, 4.2, 4.4))  # the tapering stone base


static func gate(world: ForestWorld, parent: Node3D, at: Vector2, style: String, yaw: float,
		width: float) -> void:
	var entry := StaticBody3D.new()
	entry.name = "TribalGate"
	entry.collision_mask = 0
	entry.position = world.ground_point(at.x, at.y) - Vector3.UP * 0.1
	entry.rotation.y = yaw
	parent.add_child(entry, true)
	var visual := AssetLib.instance(path(style, "Gate"))
	visual.scale = Vector3(width / 6.0, 1.0, 1.0)
	entry.add_child(visual)
	dress(visual, "Gate", entry.position)
	for side: float in [-1.0, 1.0]:
		_box(entry, Vector3(side * (width * 0.5 - 0.1), 1.3, 0.0), Vector3(0.7, 2.6, 0.7))


static func canopy(world: ForestWorld, parent: Node3D, at: Vector2, style: String, yaw: float) -> void:
	place(world, parent, "WorkCanopy", style, "Canopy", at, yaw)


static func banner(world: ForestWorld, parent: Node3D, at: Vector2, style: String, yaw: float) -> void:
	var post := Node3D.new()
	post.name = "TribalBanner"
	post.position = world.ground_point(at.x, at.y) - Vector3.UP * 0.05
	post.rotation.y = yaw
	parent.add_child(post, true)
	var visual := AssetLib.instance(path(style, "Banner"))
	post.add_child(visual)
	dress(visual, "Banner", post.position)


## A ring of wall segments (4 m models, MultiMesh per variant): each segment is sheared to follow the ground
## between its ends so the stakes stay upright. `skip(mid_angle)` leaves openings. Returns the collision body.
static func ring_wall(world: ForestWorld, parent: Node3D, center: Vector2, r: float, style: String,
		skip: Callable, banner_every := 6) -> StaticBody3D:
	var wall := StaticBody3D.new()
	wall.name = "OuterRampart"
	wall.collision_mask = 0
	parent.add_child(wall)
	var sections := ceili(TAU * r / 4.0)
	var xforms := {"Fence": [], "FenceB": []}
	for i in sections:
		var a := float(i) * TAU / sections
		var b := float(i + 1) * TAU / sections
		var mid := (a + b) * 0.5
		if skip.call(mid):
			continue
		var from := center + Vector2.from_angle(a) * r
		var to := center + Vector2.from_angle(b) * r
		var d := to - from
		var span := d.length()
		var h0 := world.height_at(from.x, from.y)
		var h1 := world.height_at(to.x, to.y)
		var m := (from + to) * 0.5
		var hm := minf(world.height_at(m.x, m.y), (h0 + h1) * 0.5)
		var yaw := atan2(-d.y, d.x) + PI  # local +Z (the outside) faces away from the centre
		var x_axis := Vector3(cos(yaw), 0.0, -sin(yaw)) * (span / 4.0)  # points from `to` back to `from`
		x_axis.y = (h0 - h1) / 4.0
		var basis := Basis(x_axis, Vector3.UP, Vector3(sin(yaw), 0.0, cos(yaw)))
		var kind := "FenceB" if banner_every > 0 and i % banner_every == banner_every / 2 else "Fence"
		xforms[kind].append(Transform3D(basis, Vector3(m.x, hm - 0.05, m.y)))
		var collider := CollisionShape3D.new()
		collider.shape = Graybox.box_shape(Vector3(span + 0.08, 2.7, 0.4))
		collider.position = Vector3(m.x, hm + 1.1, m.y)
		collider.rotation.y = -d.angle()
		wall.add_child(collider)
	for kind: String in xforms:
		var list: Array = xforms[kind]
		if list.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = AssetLib.mesh(path(style, kind))
		mm.instance_count = list.size()
		for j in list.size():
			mm.set_instance_transform(j, list[j])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = kind
		mmi.multimesh = mm
		wall.add_child(mmi)
		dress(mmi, kind, Vector3(center.x, 0.0, center.y))
	return wall
