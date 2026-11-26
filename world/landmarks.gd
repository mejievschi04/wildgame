class_name Landmarks
extends Node3D
## Landmarks across the wilds, roughly one every 300 m (as Far Cry Primal's Oros, where the eye always has something
## to walk toward): mammoth skeletons, carved totems, rings of standing stones, abandoned hunting camps and the
## smouldering hearths of hunters nearby, whose thin smoke shows from far off. Deterministic (seeded jittered grid),
## procedural (BuildingVisuals.Acc: one merged mesh per landmark), decorative with simple collision. The climate
## picks the kind: bones on the cold steppe and tundra, totems in the jungle, stones on high ground.

const SPACING := 300.0
const KEEP_CLEAR := 140.0       # from the start, the camps and the regional bases
const VIS_RANGE := 700.0        # drawn from afar: they are what you head for
const KINDS := [&"mammoth", &"totem", &"stones", &"old_camp", &"embers"]

var world: ForestWorld
## [kind, Vector3 position] of every landmark placed (tests, map).
var placed: Array = []


func build(w: ForestWorld, avoid: Array[Vector2]) -> void:
	world = w
	var rng := RandomNumberGenerator.new()
	rng.seed = ForestWorld.SEED + 8123
	var n := int(ForestWorld.PLAYABLE * 2.0 / SPACING)
	for gx in n:
		for gz in n:
			var c := Vector2(-ForestWorld.PLAYABLE + (gx + 0.5) * SPACING, -ForestWorld.PLAYABLE + (gz + 0.5) * SPACING)
			var kind: StringName = KINDS[rng.randi() % KINDS.size()]
			var yaw := rng.randf() * TAU
			var at := Vector2.INF
			for attempt in 12:
				var p := c + Vector2(rng.randf_range(-0.38, 0.38), rng.randf_range(-0.38, 0.38)) * SPACING
				if _site_ok(p, avoid):
					at = p
					break
			if at == Vector2.INF:
				continue
			kind = _climate_kind(kind, at, rng)
			var root := Node3D.new()
			root.name = "Landmark_%d_%d_%s" % [gx, gz, kind]
			root.position = world.ground_point(at.x, at.y)
			root.rotation.y = yaw
			add_child(root)
			_build_kind(kind, root, rng)
			world._occupy(at.x, at.y, 7.0)
			placed.append([kind, root.position])


func _site_ok(p: Vector2, avoid: Array[Vector2]) -> bool:
	if absf(p.x) > ForestWorld.PLAYABLE - 30.0 or absf(p.y) > ForestWorld.PLAYABLE - 30.0:
		return false
	var h := world.height_at(p.x, p.y)
	if h < 2.0 or h > 150.0 or world.normal_at(p.x, p.y).y < 0.93:
		return false
	if world.water_distance(p.x, p.y) < 25.0 or world.in_cave_cut(p.x, p.y, 15.0):
		return false
	for a in avoid:
		if a.distance_to(p) < KEEP_CLEAR:
			return false
	return world.is_scatter_site_free(p.x, p.y, 8.0)


## Bones lie on the open cold ground, totems stand in the jungle, stone rings on the uplands.
func _climate_kind(kind: StringName, p: Vector2, rng: RandomNumberGenerator) -> StringName:
	var t := ForestWorld.tundra_at(p.x, p.y)
	var j := ForestWorld.jungle_at(p.x, p.y)
	if t > 0.4 and rng.randf() < 0.6:
		return &"mammoth"
	if j > 0.5 and kind in [&"mammoth", &"stones"]:
		return &"totem"
	if world.height_at(p.x, p.y) > 60.0 and rng.randf() < 0.5:
		kind = &"stones"
	# bones and stone rings are open-ground sights: under a canopy they'd be lost, so the forest gets a camp or a totem
	var forest := world.forest_mask.get_pixelv(Vector2i(
		clampi(int((p.x / ForestWorld.SIZE + 0.5) * world.forest_mask.get_width()), 0, world.forest_mask.get_width() - 1),
		clampi(int((p.y / ForestWorld.SIZE + 0.5) * world.forest_mask.get_height()), 0, world.forest_mask.get_height() - 1))).r
	forest = maxf(forest, FarForest.grove_at(p.x, p.y))
	if forest > 0.55 and kind in [&"mammoth", &"stones"]:
		return [&"totem", &"old_camp", &"embers"][rng.randi() % 3]
	return kind


func _build_kind(kind: StringName, root: Node3D, rng: RandomNumberGenerator) -> void:
	var m := BuildingVisuals.Acc.new()
	match kind:
		&"mammoth": _mammoth(m, rng, root)
		&"totem": _totem(m, rng, root)
		&"stones": _stones(m, rng, root)
		&"old_camp": _old_camp(m, rng, root, false)
		&"embers": _old_camp(m, rng, root, true)
	m.commit(root)
	var snowy := ForestWorld.taiga_at(root.position.x, root.position.z) > 0.05
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if snowy:
			mi.material_overlay = Vegetation.snow_overlay()
		mi.visibility_range_end = VIS_RANGE
		mi.visibility_range_end_margin = 40.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


# ---------------------------------------------------------------- materials

static func _bone() -> Material:
	return Graybox.mat(Color(0.58, 0.54, 0.45), 0.92)  # weathered, lichen-stained: not bright white


static func _ivory() -> Material:
	return Graybox.mat(Color(0.66, 0.6, 0.47), 0.6)


static func _char() -> Material:
	return Graybox.mat(Color(0.06, 0.055, 0.05), 0.95)


static func _ochre() -> Material:
	return Graybox.mat(Color(0.55, 0.16, 0.08), 0.8)


func _body(root: Node3D, size: Vector3, at: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	Graybox.add_shape(body, Graybox.box_shape(size), at)
	root.add_child(body)


# ---------------------------------------------------------------- kinds

## A mammoth skeleton sunk in the grass: the great skull with both curving tusks, a spine running back over the
## ribs (arches standing out of the ground, some broken), the pelvis and a scatter of leg bones.
func _mammoth(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, root: Node3D) -> void:
	var bone := _bone()
	var ivory := _ivory()
	var sc := rng.randf_range(0.9, 1.15)
	# skull: a high domed cranium, the broad tusk sockets and the jaw, head down at the front (+z)
	var skull := Vector3(0, 0.75, 3.0) * sc
	var dome := [[-0.6, 0.45], [-0.3, 0.6], [0.0, 0.64], [0.25, 0.58], [0.45, 0.44], [0.6, 0.22], [0.66, 0.02]]
	for k in dome.size() - 1:
		m.pole(0, bone, skull + Vector3(0, dome[k][0], -0.3 + 0.05 * k) * sc, skull + Vector3(0, dome[k + 1][0], -0.25 + 0.05 * k) * sc,
			dome[k][1] * sc, dome[k + 1][1] * sc, 12, k == 0)
	m.pole(0, bone, skull + Vector3(0, -0.3, 0.1) * sc, skull + Vector3(0, -0.5, 0.55) * sc, 0.42 * sc, 0.3 * sc, 9)
	m.box(0, bone, Transform3D(Basis(Vector3.RIGHT, 0.4), skull + Vector3(0, -0.6, -0.55) * sc), Vector3(0.7, 0.25, 0.6) * sc)
	# tusks: out of the sockets forward and down, sweeping out and up, the tips curling back in (~2.6 m)
	for side: float in [-1.0, 1.0]:
		var pts: Array[Vector3] = []
		for k in 11:
			var t := k / 10.0
			var a := t * PI * 0.95
			pts.append(skull + Vector3(side * (0.28 + 0.75 * sin(a) - 0.5 * t * t * t),
				-0.45 - 0.35 * sin(a * 1.3) + 1.25 * t * t,
				0.45 + 1.6 * sin(a * 0.7)) * sc)
		for k in pts.size() - 1:
			var r0 := lerpf(0.13, 0.035, float(k) / 10.0) * sc
			var r1 := lerpf(0.13, 0.035, float(k + 1) / 10.0) * sc
			m.pole(0, ivory, pts[k], pts[k + 1], r0, r1, 8, false)
	# spine and ribs
	var spine_pts: Array[Vector3] = []
	for k in 9:
		var t := k / 8.0
		spine_pts.append(Vector3(0.0, (1.25 + 0.35 * sin(t * PI) - 0.9 * t) * sc, (2.0 - 4.6 * t) * sc))
	m.tube(0, bone, spine_pts, 0.09 * sc, 6)
	for k in range(1, 7):
		var s := spine_pts[k]
		var depth := s.y * (1.0 - 0.08 * k)
		for side: float in [-1.0, 1.0]:
			if rng.randf() < 0.18:
				continue  # a rib gone
			var rib: Array[Vector3] = []
			var length := rng.randf_range(0.7, 1.0)
			for q in 7:
				var a := q / 6.0 * PI * 0.5 * length
				rib.append(s + Vector3(side * sin(a) * 1.25 * sc, -depth * (1.0 - cos(a)) * 1.05 - 0.05, -0.06 * q * sc))
			m.tube(0, bone, rib, 0.055 * sc, 5)
	# pelvis and the long bones lying about
	var hip := spine_pts[7]
	m.pole(0, bone, hip + Vector3(-0.6, -0.2, 0) * sc, hip + Vector3(0.6, -0.2, 0) * sc, 0.2 * sc, 0.2 * sc, 7)
	for k in 5:
		var a := rng.randf() * TAU
		var c := Vector3(rng.randf_range(-2.2, 2.2), 0.08, rng.randf_range(-2.5, 2.0)) * sc
		var d := Vector3(cos(a), 0.05, sin(a)) * rng.randf_range(0.6, 1.1) * sc
		m.pole(0, bone, c - d, c + d, 0.09 * sc, 0.07 * sc, 6)
		m.pole(0, bone, c + d, c + d * 1.12, 0.13 * sc, 0.02 * sc, 6)
	_body(root, Vector3(3.0, 2.0, 5.5) * sc, Vector3(0, 0.7, 0.4) * sc)


## A carved totem: a tall trunk with stacked, ochre-painted faces and a horned skull on top, hide strips and
## feathers hanging off it, a ring of stones and offerings at its foot.
func _totem(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, root: Node3D) -> void:
	var wood := BuildingVisuals.m_post()
	var dark := BuildingVisuals.m_bark()
	var bone := _bone()
	var ochre := _ochre()
	var h := rng.randf_range(4.2, 5.6)
	m.pole(0, wood, Vector3(0, -0.3, 0), Vector3(0, h, 0), 0.32, 0.24, 10)
	# carved bands: bulging faces, eyes and mouths in ochre and charcoal
	var faces := rng.randi_range(2, 3)
	for k in faces:
		var y := h * (0.3 + 0.55 * k / maxf(faces - 1, 1)) - 0.4
		m.pole(0, dark, Vector3(0, y - 0.35, 0), Vector3(0, y + 0.35, 0), 0.38, 0.36, 10)
		for side: float in [-1.0, 1.0]:
			m.box(0, _char(), Transform3D(Basis.IDENTITY, Vector3(side * 0.13, y + 0.12, 0.36)), Vector3(0.12, 0.08, 0.06))
		m.box(0, ochre, Transform3D(Basis.IDENTITY, Vector3(0, y - 0.15, 0.37)), Vector3(0.3, 0.07, 0.05))
		m.box(0, ochre, Transform3D(Basis.IDENTITY, Vector3(0, y + 0.3, 0.37)), Vector3(0.5, 0.05, 0.05))
	# the horned skull on top
	var top := Vector3(0, h + 0.15, 0.05)
	m.pole(0, bone, top + Vector3(0, -0.2, -0.1), top + Vector3(0, 0.12, 0.25), 0.2, 0.1, 8)
	for side: float in [-1.0, 1.0]:
		var horn: Array[Vector3] = []
		for q in 6:
			var t := q / 5.0
			horn.append(top + Vector3(side * (0.15 + 0.65 * t), 0.05 + 0.55 * t * t, -0.1 * t))
		for q in horn.size() - 1:
			m.pole(0, bone, horn[q], horn[q + 1], lerpf(0.07, 0.015, q / 5.0), lerpf(0.07, 0.015, (q + 1) / 5.0), 6, false)
	# hide strips and feathers hanging from a crossbar
	var bar_y := h * 0.72
	m.pole(0, wood, Vector3(-0.9, bar_y, 0), Vector3(0.9, bar_y, 0), 0.06, 0.06, 6)
	for k in 6:
		var x := lerpf(-0.8, 0.8, k / 5.0)
		var length := rng.randf_range(0.4, 0.9)
		m.box(0, BuildingVisuals.m_leather() if k % 2 == 0 else bone,
			Transform3D(Basis(Vector3.FORWARD, rng.randf_range(-0.1, 0.1)), Vector3(x, bar_y - length * 0.5 - 0.05, 0.02)),
			Vector3(0.07, length, 0.015))
	# stones and offerings at the foot
	for k in 9:
		var a := TAU * k / 9.0
		m.box(0, BuildingVisuals.m_stone(), Transform3D(Basis(Vector3.UP, a), Vector3(cos(a) * 0.9, 0.08, sin(a) * 0.9)),
			Vector3(0.35, 0.22, 0.28) * rng.randf_range(0.8, 1.3))
	for k in 3:
		var a := rng.randf() * TAU
		m.pole(0, bone, Vector3(cos(a) * 0.6, 0.05, sin(a) * 0.6), Vector3(cos(a + 0.4) * 0.9, 0.08, sin(a + 0.4) * 0.9), 0.04, 0.03, 5)
	_body(root, Vector3(0.7, h, 0.7), Vector3(0, h * 0.5, 0))


## A ring of standing stones: the mossy boulders stood on end and drawn up into rough slabs (menhirs), leaning a
## little, the tallest at the head of the ring, a flat altar stone in the middle with old soot and ochre on it.
func _stones(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, root: Node3D) -> void:
	var count := rng.randi_range(5, 8)
	var r := rng.randf_range(4.0, 5.5)
	var paths: Array = AssetLib.ROCKS[&"medium"]
	for k in count:
		if rng.randf() < 0.15:
			continue  # fallen long ago
		var a := TAU * k / count + rng.randf_range(-0.12, 0.12)
		var h := rng.randf_range(1.8, 2.7) * (1.4 if k == 0 else 1.0)
		var mesh := _rock_mesh(paths[rng.randi() % paths.size()])
		var box := mesh.get_aabb()
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		# lay the boulder's long side upright, then stretch it to a slab ~h tall, ~0.9 m wide, ~0.5 m thick
		var stand := Basis(Vector3.RIGHT, -PI * 0.5)  # the boulder's +z (its long side) turned up
		var sc := Vector3(0.9 / box.size.x, 0.5 / box.size.y, h / box.size.z)
		var b := Basis(Vector3.UP, -a + PI * 0.5) * Basis(Vector3.RIGHT, rng.randf_range(-0.07, 0.1)) \
			* Basis(Vector3.FORWARD, rng.randf_range(-0.07, 0.07)) * stand * Basis.from_scale(sc)
		var at := Vector3(cos(a) * r, -0.35, sin(a) * r)
		mi.transform = Transform3D(b, at - b * Vector3(box.get_center().x, box.get_center().y, box.position.z))
		root.add_child(mi)
		_body(root, Vector3(0.9, h, 0.5), at + Vector3(0, h * 0.5, 0))
	var altar := _rock_mesh(paths[rng.randi() % paths.size()])
	var am := MeshInstance3D.new()
	am.mesh = altar
	var abox := altar.get_aabb()
	am.transform = Transform3D(Basis.from_scale(Vector3(1.9 / abox.size.x, 0.55 / abox.size.y, 1.3 / abox.size.z)),
		Vector3(-abox.get_center().x * 1.9 / abox.size.x, -0.1, -abox.get_center().z * 1.3 / abox.size.z))
	root.add_child(am)
	m.box(0, _char(), Transform3D(Basis.IDENTITY, Vector3(0.1, 0.46, 0.05)), Vector3(0.6, 0.02, 0.5))
	m.box(0, _ochre(), Transform3D(Basis(Vector3.UP, 0.4), Vector3(-0.35, 0.46, -0.2)), Vector3(0.3, 0.02, 0.12))
	_body(root, Vector3(1.9, 0.5, 1.2), Vector3(0, 0.25, 0))


static var _rock_cache: Dictionary = {}


static func _rock_mesh(path: String) -> Mesh:
	if not _rock_cache.has(path):
		_rock_cache[path] = AssetLib.mesh(path)
	return _rock_cache[path]


## An abandoned hunting camp: a collapsed hide lean-to, a drying rack with a few bones still hanging, a stone ring
## of old ashes and charred ends. `embers`: hunters were here today — the hearth still smoulders and a thin plume
## of smoke rises from it, visible across the valley.
func _old_camp(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, root: Node3D, embers: bool) -> void:
	var wood := BuildingVisuals.m_log()
	var hide := BuildingVisuals.m_leather()
	var bone := _bone()
	# lean-to: poles against a ridge pole, the hide sagging and torn
	var lean := Vector3(-2.4, 0, -1.0)
	m.pole(0, wood, lean + Vector3(-1.4, 0, 0), lean + Vector3(-1.5, 1.7, 0.1), 0.06, 0.05, 6)
	m.pole(0, wood, lean + Vector3(1.4, 0, 0), lean + Vector3(1.3, 1.6, 0.1), 0.06, 0.05, 6)
	m.pole(0, wood, lean + Vector3(-1.6, 1.65, 0.1), lean + Vector3(1.5, 1.55, 0.1), 0.05, 0.05, 6)
	for k in 5:
		var x := lerpf(-1.3, 1.3, k / 4.0)
		m.pole(0, wood, lean + Vector3(x, 0, -1.6), lean + Vector3(x + 0.05, 1.65, 0.15), 0.04, 0.035, 5)
	var sag := Basis(Vector3.RIGHT, -0.85)
	m.box(0, hide, Transform3D(sag, lean + Vector3(-0.4, 0.85, -0.75)), Vector3(1.7, 2.0, 0.02))
	# drying rack, one leg broken
	var rack := Vector3(2.6, 0, -1.6)
	m.pole(0, wood, rack + Vector3(-1.0, 0, 0), rack + Vector3(-1.0, 1.6, 0), 0.05, 0.04, 5)
	m.pole(0, wood, rack + Vector3(1.0, 0, 0), rack + Vector3(1.0, 0.9, 0.3), 0.05, 0.04, 5)
	m.pole(0, wood, rack + Vector3(-1.05, 1.55, 0), rack + Vector3(1.0, 0.85, 0.3), 0.035, 0.035, 5)
	for k in 3:
		var p := rack + Vector3(-0.6 + 0.5 * k, 1.35 - 0.25 * k, 0.1 * k)
		m.pole(0, bone, p, p + Vector3(0.05, -0.45, 0.0), 0.03, 0.02, 5)
	# hearth: a ring of stones, ash, charred ends of wood, bones from the meal
	var hearth := Vector3(0.6, 0, 1.2)
	for k in 8:
		var a := TAU * k / 8.0
		m.box(0, BuildingVisuals.m_stone(), Transform3D(Basis(Vector3.UP, a), hearth + Vector3(cos(a) * 0.65, 0.07, sin(a) * 0.65)),
			Vector3(0.28, 0.18, 0.22) * rng.randf_range(0.8, 1.25))
	m.box(0, Graybox.mat(Color(0.32, 0.31, 0.3), 1.0), Transform3D(Basis.IDENTITY, hearth + Vector3(0, 0.01, 0)), Vector3(1.0, 0.02, 1.0))
	for k in 4:
		var a := rng.randf() * TAU
		m.pole(0, _char(), hearth + Vector3(cos(a) * 0.45, 0.05, sin(a) * 0.45), hearth + Vector3(cos(a) * 0.05, 0.12, sin(a) * 0.05), 0.05, 0.04, 5)
	for k in 4:
		var a := rng.randf() * TAU
		var c := hearth + Vector3(cos(a), 0.03, sin(a)) * rng.randf_range(1.1, 2.0)
		m.pole(0, bone, c, c + Vector3(rng.randf_range(-0.3, 0.3), 0.0, rng.randf_range(-0.3, 0.3)), 0.035, 0.03, 5)
	_body(root, Vector3(3.0, 1.7, 1.8), lean + Vector3(0, 0.85, -0.6))
	if embers:
		m.box(0, Graybox.mat(Color(1.0, 0.35, 0.08), 0.8, 2.5), Transform3D(Basis.IDENTITY, hearth + Vector3(0, 0.05, 0)),
			Vector3(0.35, 0.04, 0.3))
		var smoke := _smoke()
		smoke.position = hearth + Vector3(0, 0.3, 0)
		root.add_child(smoke)
		var glow := OmniLight3D.new()
		glow.light_color = Color(1.0, 0.45, 0.15)
		glow.light_energy = 0.6
		glow.omni_range = 3.0
		glow.position = hearth + Vector3(0, 0.3, 0)
		glow.distance_fade_enabled = true
		glow.distance_fade_begin = 50.0
		glow.distance_fade_length = 15.0
		root.add_child(glow)


## A thin, tall plume (thinner than a lit campfire's): it marks the place from far off.
func _smoke() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 80
	p.lifetime = 22.0
	p.preprocess = 22.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.1
	p.direction = Vector3.UP
	p.spread = 5.0
	p.initial_velocity_min = 0.5
	p.initial_velocity_max = 0.8
	p.gravity = Vector3(0.15, 0.3, 0.05)
	p.angular_velocity_min = -10.0
	p.angular_velocity_max = 10.0
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.1))
	grow.add_point(Vector2(1.0, 1.0))
	p.scale_amount_curve = grow
	p.scale_amount_min = 3.0
	p.scale_amount_max = 4.4
	var fade := Gradient.new()
	fade.set_color(0, Color(0.3, 0.29, 0.28, 0.0))
	fade.add_point(0.06, Color(0.36, 0.35, 0.34, 0.6))
	fade.add_point(0.6, Color(0.5, 0.5, 0.5, 0.32))
	fade.set_color(fade.get_point_count() - 1, Color(0.6, 0.6, 0.6, 0.0))
	p.color_ramp = fade
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	var mat := (TreeNode._puff_quad(1.0).material as StandardMaterial3D).duplicate() as StandardMaterial3D
	mat.billboard_keep_scale = true
	quad.material = mat
	p.mesh = quad
	p.visibility_range_end = 1500.0
	return p
