class_name BuildingVisuals
extends RefCounted
## Procedural, construction-staged visuals for building pieces (data/building_pieces.json).
##
## Every piece is built the way it would really go up, in STAGES -- e.g. a wattle-and-daub wall is
## 0: frame posts + stakes, 1: woven rods, 2: clay daub. A blueprint shows the stages already paid for in real
## materials and the rest as a translucent plan (BuildingPiece.apply_stages). Each stage is merged into one mesh
## per material (a few draw calls per piece instead of dozens of parts).
##
## TIERS are material upgrades of the same piece: walls wattle -> logs -> stone, floor logs -> stone footing +
## planks, posts -> stone columns, thatch -> bark shingles.
##
## Layout: root/StageN/<MeshInstance3D>; doors keep their stages under root/Hinge (animated); the drying rack
## has root/DryRoot. root meta "stages" = stage count.

const FOUNDATION_H := 0.3
const WALL_H := 2.2
const HALF_WALL_H := 1.1
const DOOR_W := 1.0
const DOOR_H := 1.95
## Window opening in wall-local coordinates (x along the wall, y up from the floor).
const WINDOW := Rect2(-0.36, 0.95, 0.72, 0.56)
## Pitched roof (local to the roof socket = top of the walls): ridge along X.
const EAVE_Z := 1.32
const EAVE_Y := -0.14
const RIDGE_Y := 0.9
const ROOF_HALF_X := 1.22


static func build(id: StringName, tier: int = 0, seed: int = 0) -> Node3D:
	var root := Node3D.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed ^ hash(String(id)) ^ (tier * 7919)
	var m := Acc.new()
	var stages := 1
	match id:
		&"foundation": stages = _foundation(m, tier, rng)
		&"wall": stages = _wall(m, tier, WALL_H, Rect2(), rng)
		&"doorway": stages = _wall(m, tier, WALL_H, Rect2(-DOOR_W * 0.5, 0.0, DOOR_W, DOOR_H), rng)
		&"window_wall": stages = _wall(m, tier, WALL_H, WINDOW, rng)
		&"half_wall": stages = _wall(m, tier, HALF_WALL_H, Rect2(), rng)
		&"pillar": stages = _pillar(m, tier, rng)
		&"roof": stages = _roof(m, tier, rng)
		&"gable": stages = _gable(m, rng)
		&"fence": stages = _fence(m, rng)
		&"palisade": stages = _palisade(m, rng)
		&"lean_to": stages = _lean_to(m, rng)
		&"garden_bed": stages = _garden_bed(m, rng)
		&"drying_rack":
			stages = _drying_rack(m, rng)
			var dry := Node3D.new()
			dry.name = "DryRoot"
			dry.position = Vector3(0, 1.5, 0)
			root.add_child(dry)
		&"door":
			var hinge := Node3D.new()
			hinge.name = "Hinge"
			hinge.position = Vector3(-DOOR_W * 0.5, 0, 0)
			root.add_child(hinge)
			stages = _door(m, rng)
			m.commit(hinge)
			root.set_meta("stages", stages)
			return root
		&"storage":
			var s0 := Node3D.new()
			s0.name = "Stage0"
			root.add_child(s0)
			var basket := AssetLib.instance(AssetLib.PROPS[&"basket"])
			basket.scale = Vector3(2.7, 2.4, 2.7)
			s0.add_child(basket)
			root.set_meta("stages", 1)
			return root
	m.commit(root)
	root.set_meta("stages", stages)
	return root


## Stage containers of a built visual, by index (a door's live under its hinge).
static func stage_nodes(root: Node) -> Dictionary:
	var out := {}
	for n: Node in root.find_children("Stage*", "Node3D", true, false):
		var idx := int(String(n.name).substr(5))
		if not out.has(idx):
			out[idx] = []
		out[idx].append(n)
	return out


# ---------------------------------------------------------------- materials

static func _m(name: String, tint: Color, scale: float) -> Material:
	return Graybox.tex(name, tint, scale)

static func m_log() -> Material: return _m("Log", Color(1, 1, 1), 1.0)
static func m_post() -> Material: return _m("Log", Color(0.86, 0.82, 0.78), 1.4)
static func m_stake() -> Material: return _m("Wattle", Color(0.95, 0.9, 0.85), 2.5)
static func m_weave() -> Material: return _m("Wattle", Color(0.8, 0.72, 0.6), 3.5)
static func m_daub() -> Material: return _m("Mud", Color(0.95, 0.88, 0.76), 1.4)
static func m_chink() -> Material: return _m("Mud", Color(0.62, 0.56, 0.47), 3.0)
static func m_thatch() -> Material: return _m("Thatch", Color(1, 1, 1), 0.6)
static func m_thatch_dark() -> Material: return _m("Thatch", Color(0.78, 0.74, 0.66), 0.8)
static func m_stone() -> Material: return _m("Rock", Color(0.95, 0.94, 0.92), 1.3)
static func m_plank() -> Material: return _m("CutWood", Color(0.86, 0.76, 0.62), 1.2)
static func m_bark() -> Material: return _m("Log", Color(0.66, 0.6, 0.55), 2.2)
static func m_leather() -> Material: return _m("Leather", Color(0.8, 0.7, 0.6), 3.0)


# ---------------------------------------------------------------- walls

## A 2 m wall panel (x in [-1, 1], y from the floor, thickness along z) with an optional opening.
## Tier 0 wattle & daub, 1 horizontal logs with clay chinking, 2 dry-laid stone with a clay backing.
static func _wall(m: Acc, tier: int, h: float, hole: Rect2, rng: RandomNumberGenerator) -> int:
	match tier:
		1: return _wall_logs(m, h, hole, rng)
		2: return _wall_stone(m, h, hole, rng)
	return _wall_wattle(m, h, hole, rng)


static func _wall_wattle(m: Acc, h: float, hole: Rect2, rng: RandomNumberGenerator) -> int:
	# Stage 0: corner posts, top plate, stakes (split around the opening), opening frame.
	for sx in [-0.95, 0.95]:
		m.pole(0, m_post(), Vector3(sx, -0.05, 0), Vector3(sx + rng.randf_range(-0.01, 0.01), h + 0.04, 0), 0.065, 0.055)
	m.pole(0, m_post(), Vector3(-1.0, h, 0), Vector3(1.0, h + 0.01, 0), 0.05, 0.048)
	var stakes := 7
	for i in stakes:
		var x := -0.75 + i * 1.5 / (stakes - 1) + rng.randf_range(-0.02, 0.02)
		for seg: Vector2 in _span_y(x, h, hole):
			m.pole(0, m_stake(), Vector3(x, seg.x, 0), Vector3(x + rng.randf_range(-0.015, 0.015), seg.y, 0), 0.03, 0.026, 5)
	if hole.size != Vector2.ZERO:
		var top := hole.end.y
		m.pole(0, m_post(), Vector3(hole.position.x - 0.12, top + 0.02, 0), Vector3(hole.end.x + 0.12, top, 0), 0.05, 0.05)
		for x in [hole.position.x - 0.04, hole.end.x + 0.04]:
			m.pole(0, m_post(), Vector3(x, maxf(hole.position.y - 0.04, -0.02), 0), Vector3(x, top + 0.04, 0), 0.045, 0.04)
		if hole.position.y > 0.1:
			m.pole(0, m_post(), Vector3(hole.position.x - 0.06, hole.position.y - 0.02, 0), Vector3(hole.end.x + 0.06, hole.position.y - 0.02, 0), 0.04, 0.04)
	# Stage 1: rods woven in and out of the stakes, alternating every row.
	var row := 0
	var y := 0.1
	while y < h - 0.08:
		for seg: Vector2 in _span_x(y, hole, -0.92, 0.92):
			var pts: Array[Vector3] = []
			var steps := int((seg.y - seg.x) / 0.06) + 2
			for k in steps:
				var x := lerpf(seg.x, seg.y, float(k) / (steps - 1))
				var phase := (x + 0.75) / 0.25 * PI + (PI if row % 2 == 1 else 0.0)
				pts.append(Vector3(x, y + rng.randf_range(-0.006, 0.006), sin(phase) * 0.036))
			m.tube(1, m_weave(), pts, 0.017)
		y += 0.105
		row += 1
	# Stage 2: clay daub pressed onto the weave in lumpy patches (the frame posts stay visible).
	for r: Rect2 in _rects_minus(Rect2(-0.9, 0.0, 1.8, h - 0.03), hole.grow(0.05) if hole.size != Vector2.ZERO else Rect2()):
		_lumpy_panel(m, 2, m_daub(), r, 0.14, rng)
	return 3


static func _wall_logs(m: Acc, h: float, hole: Rect2, rng: RandomNumberGenerator) -> int:
	# Stage 0: corner posts.  Stage 1: stacked logs.  Stage 2: clay/moss chinking and the lintel.
	for sx in [-0.98, 0.98]:
		m.pole(0, m_post(), Vector3(sx, -0.05, 0), Vector3(sx, h + 0.05, 0), 0.11, 0.1, 8)
	var n := int(h / 0.205)
	var step := h / n
	for i in n:
		var y := step * (i + 0.5)
		var r := step * 0.5 + rng.randf_range(0.0, 0.012)
		for seg: Vector2 in _span_x(y, hole, -1.04, 1.04):
			m.pole(1, m_log(), Vector3(seg.x, y + rng.randf_range(-0.01, 0.01), rng.randf_range(-0.01, 0.01)),
				Vector3(seg.y, y + rng.randf_range(-0.01, 0.01), rng.randf_range(-0.01, 0.01)), r, r * rng.randf_range(0.9, 1.0), 9)
		if i < n - 1:
			for seg: Vector2 in _span_x(step * (i + 1), hole, -0.9, 0.9):
				m.pole(2, m_chink(), Vector3(seg.x, step * (i + 1), 0), Vector3(seg.y, step * (i + 1), 0), 0.035, 0.035, 6)
	if hole.size != Vector2.ZERO:
		m.box(2, m_plank(), Transform3D(Basis(), Vector3(hole.get_center().x, hole.end.y + 0.06, 0)), Vector3(hole.size.x + 0.4, 0.14, 0.22))
		for x in [hole.position.x - 0.03, hole.end.x + 0.03]:
			m.box(2, m_plank(), Transform3D(Basis(), Vector3(x, hole.get_center().y, 0)), Vector3(0.07, hole.size.y, 0.22))
	return 3


static func _wall_stone(m: Acc, h: float, hole: Rect2, rng: RandomNumberGenerator) -> int:
	# Stage 0: footing course.  Stage 1: upper courses.  Stage 2: clay backing, lintel, top plate.
	var y := 0.0
	var course := 0
	while y < h - 0.1:
		var ch := minf(rng.randf_range(0.2, 0.27), h - 0.04 - y)
		var x := -1.0 + (rng.randf_range(0.0, 0.18) if course % 2 == 1 else 0.0)
		while x < 1.0:
			var w := minf(rng.randf_range(0.26, 0.44), 1.0 - x)
			var c := Vector2(x + w * 0.5, y + ch * 0.5)
			if w > 0.06 and not (hole.size != Vector2.ZERO and hole.grow(0.02).has_point(c)):
				var b := Basis.from_euler(Vector3(rng.randf_range(-0.04, 0.04), rng.randf_range(-0.05, 0.05), rng.randf_range(-0.04, 0.04)))
				m.box(0 if course == 0 else 1, m_stone(), Transform3D(b, Vector3(c.x, c.y, rng.randf_range(-0.02, 0.02))),
					Vector3(w - 0.025, ch - 0.02, rng.randf_range(0.26, 0.32)))
			x += w
		y += ch
		course += 1
	for r: Rect2 in _rects_minus(Rect2(-0.98, 0.0, 1.96, h - 0.04), hole.grow(0.02) if hole.size != Vector2.ZERO else Rect2()):
		m.box(2, m_chink(), Transform3D(Basis(), Vector3(r.get_center().x, r.get_center().y, 0)), Vector3(r.size.x, r.size.y, 0.2))
	m.box(2, m_plank(), Transform3D(Basis(), Vector3(0, h - 0.04, 0)), Vector3(2.0, 0.1, 0.3))
	if hole.size != Vector2.ZERO:
		m.box(2, m_log(), Transform3D(Basis(), Vector3(hole.get_center().x, hole.end.y + 0.08, 0)), Vector3(hole.size.x + 0.5, 0.16, 0.3))
	return 3


## Vertical spans [y0, y1] of a stake at x, cut around the opening.
static func _span_y(x: float, h: float, hole: Rect2) -> Array[Vector2]:
	if hole.size == Vector2.ZERO or x < hole.position.x - 0.02 or x > hole.end.x + 0.02:
		return [Vector2(-0.04, h)]
	var out: Array[Vector2] = []
	if hole.position.y > 0.12:
		out.append(Vector2(-0.04, hole.position.y))
	if hole.end.y < h - 0.08:
		out.append(Vector2(hole.end.y, h))
	return out


## Horizontal spans [x0, x1] of a row at height y, cut around the opening.
static func _span_x(y: float, hole: Rect2, x0: float, x1: float) -> Array[Vector2]:
	if hole.size == Vector2.ZERO or y < hole.position.y or y > hole.end.y:
		return [Vector2(x0, x1)]
	var out: Array[Vector2] = []
	if hole.position.x - 0.03 > x0 + 0.05:
		out.append(Vector2(x0, hole.position.x - 0.03))
	if hole.end.x + 0.03 < x1 - 0.05:
		out.append(Vector2(hole.end.x + 0.03, x1))
	return out


## Rectangle minus a hole -> up to four rectangles (left, right, below, above).
static func _rects_minus(r: Rect2, hole: Rect2) -> Array[Rect2]:
	if hole.size == Vector2.ZERO or not r.intersects(hole):
		return [r]
	var h := r.intersection(hole)
	var out: Array[Rect2] = []
	if h.position.x > r.position.x:
		out.append(Rect2(r.position.x, r.position.y, h.position.x - r.position.x, r.size.y))
	if h.end.x < r.end.x:
		out.append(Rect2(h.end.x, r.position.y, r.end.x - h.end.x, r.size.y))
	if h.position.y > r.position.y:
		out.append(Rect2(h.position.x, r.position.y, h.size.x, h.position.y - r.position.y))
	if h.end.y < r.end.y:
		out.append(Rect2(h.position.x, h.end.y, h.size.x, r.end.y - h.end.y))
	return out


## Hand-pressed clay: overlapping slightly tilted, uneven slabs instead of one flat board.
static func _lumpy_panel(m: Acc, stage: int, mat: Material, r: Rect2, thick: float, rng: RandomNumberGenerator) -> void:
	var nx := maxi(1, ceili(r.size.x / 0.45))
	var ny := maxi(1, ceili(r.size.y / 0.4))
	var cw := r.size.x / nx
	var chh := r.size.y / ny
	for i in nx:
		for j in ny:
			var c := Vector2(r.position.x + cw * (i + 0.5), r.position.y + chh * (j + 0.5))
			var b := Basis.from_euler(Vector3(rng.randf_range(-0.03, 0.03), rng.randf_range(-0.03, 0.03), rng.randf_range(-0.02, 0.02)))
			m.box(stage, mat, Transform3D(b, Vector3(c.x, c.y, rng.randf_range(-0.006, 0.006))),
				Vector3(cw + 0.04, chh + 0.04, thick + rng.randf_range(-0.012, 0.018)))


# ---------------------------------------------------------------- floor, posts, roof

static func _foundation(m: Acc, tier: int, rng: RandomNumberGenerator) -> int:
	if tier == 0:
		# Stage 0: corner posts dug in + two sill beams.  Stage 1: cross joists.  Stage 2: split-log deck.
		for sx in [-0.86, 0.86]:
			for sz in [-0.86, 0.86]:
				m.pole(0, m_post(), Vector3(sx, -1.0, sz), Vector3(sx, 0.18, sz), 0.12, 0.1, 7)
			m.pole(0, m_log(), Vector3(sx, 0.12, -1.0), Vector3(sx, 0.12, 1.0), 0.09, 0.085, 8)
		for sz in [-0.5, 0.5]:
			m.pole(1, m_log(), Vector3(-1.0, 0.1, sz), Vector3(1.0, 0.1, sz), 0.07, 0.065, 7)
		for i in 7:
			var x := -0.86 + i * 0.287
			m.pole(2, m_log(), Vector3(x, 0.165, -1.0), Vector3(x + rng.randf_range(-0.01, 0.01), 0.165, 1.0),
				0.135 + rng.randf_range(0.0, 0.012), 0.13, 9)
		return 3
	# Tier 1: Stage 0: stone footing.  Stage 1: beams.  Stage 2: plank floor.
	for side in 4:
		var horiz := side < 2
		var off := -0.88 if side % 2 == 0 else 0.88
		var t := -1.0
		while t < 1.0:
			var w := minf(rng.randf_range(0.28, 0.42), 1.0 - t)
			var c := Vector3(t + w * 0.5, 0.0, off) if horiz else Vector3(off, 0.0, t + w * 0.5)
			var size := Vector3(w - 0.02, rng.randf_range(0.34, 0.42), 0.26) if horiz else Vector3(0.26, rng.randf_range(0.34, 0.42), w - 0.02)
			m.box(0, m_stone(), Transform3D(Basis.from_euler(Vector3(0, rng.randf_range(-0.06, 0.06), 0)), c + Vector3(0, -0.06, 0)), size)
			t += w
	for sx in [-0.7, 0.0, 0.7]:
		m.box(1, m_log(), Transform3D(Basis(), Vector3(sx, 0.18, 0)), Vector3(0.14, 0.12, 2.0))
	for i in 7:
		var x := -0.86 + i * 0.287
		m.box(2, m_plank(), Transform3D(Basis.from_euler(Vector3(0, rng.randf_range(-0.01, 0.01), 0)), Vector3(x, 0.27, rng.randf_range(-0.02, 0.02))),
			Vector3(0.27, 0.06, 2.0 - rng.randf_range(0.0, 0.05)))
	return 3


static func _pillar(m: Acc, tier: int, rng: RandomNumberGenerator) -> int:
	if tier == 0:
		m.pole(0, m_post(), Vector3(0, -0.05, 0), Vector3(rng.randf_range(-0.01, 0.01), WALL_H, 0), 0.13, 0.11, 9)
		for y in [0.35, WALL_H - 0.25]:
			m.pole(1, m_leather(), Vector3(0, y, 0), Vector3(0, y + 0.1, 0), 0.135, 0.125, 9)
		m.box(1, m_log(), Transform3D(Basis(), Vector3(0, WALL_H - 0.03, 0)), Vector3(0.34, 0.08, 0.2))
		return 2
	var y := -0.05
	while y < WALL_H - 0.2:
		var hgt := rng.randf_range(0.2, 0.3)
		m.pole(0, m_stone(), Vector3(rng.randf_range(-0.01, 0.01), y, 0), Vector3(0, y + hgt - 0.015, 0), 0.19, 0.18, 7)
		y += hgt
	m.box(1, m_plank(), Transform3D(Basis(), Vector3(0, WALL_H - 0.06, 0)), Vector3(0.42, 0.14, 0.42))
	return 2


## Point on a roof slope: t along the slope 0 (eave) .. 1 (ridge), side +1 / -1 (z), x along the ridge.
static func _slope(side: float, t: float, x: float, lift: float = 0.0) -> Vector3:
	var p := Vector3(x, lerpf(EAVE_Y, RIDGE_Y, t), side * lerpf(EAVE_Z, 0.0, t))
	return p + _slope_normal(side) * lift


static func _slope_normal(side: float) -> Vector3:
	return Vector3(0, EAVE_Z, side * (RIDGE_Y - EAVE_Y)).normalized()


static func _roof(m: Acc, tier: int, rng: RandomNumberGenerator) -> int:
	# Stage 0: ridge pole + rafters.  Stage 1: battens.  Stage 2: thatch (tier 0) or bark shingles (tier 1).
	m.pole(0, m_log(), Vector3(-ROOF_HALF_X - 0.05, RIDGE_Y, 0), Vector3(ROOF_HALF_X + 0.05, RIDGE_Y, 0), 0.07, 0.065, 8)
	for side in [-1.0, 1.0]:
		for x in [-1.08, -0.36, 0.36, 1.08]:
			m.pole(0, m_post(), _slope(side, -0.04, x), _slope(side, 1.02, x), 0.045, 0.04, 6)
		for k in 6:
			var t := 0.06 + k * 0.17
			m.pole(1, m_stake(), _slope(side, t, -ROOF_HALF_X, 0.05), _slope(side, t, ROOF_HALF_X, 0.05), 0.022, 0.022, 5)
	var slope_len := Vector2(EAVE_Z, RIDGE_Y - EAVE_Y).length()
	var pitch := atan2(RIDGE_Y - EAVE_Y, EAVE_Z)
	if tier == 0:
		for side in [-1.0, 1.0]:
			var eave := _slope(side, 0.0, 0.0)
			_thatch(m, 2, eave, (_slope(side, 1.0, 0.0) - eave).normalized(), _slope_normal(side), ROOF_HALF_X + 0.06, slope_len, 6, 0.08, rng)
		m.pole(2, m_thatch_dark(), Vector3(-ROOF_HALF_X - 0.08, RIDGE_Y + 0.12, 0), Vector3(ROOF_HALF_X + 0.08, RIDGE_Y + 0.12, 0), 0.2, 0.2, 8)
		for x in [-0.9, -0.3, 0.3, 0.9]:  # binding withies over the ridge cap
			m.pole(2, m_stake(), Vector3(x, RIDGE_Y - 0.05, -0.22), Vector3(x, RIDGE_Y + 0.33, 0.0), 0.02, 0.02, 4, false)
			m.pole(2, m_stake(), Vector3(x, RIDGE_Y + 0.33, 0.0), Vector3(x, RIDGE_Y - 0.05, 0.22), 0.02, 0.02, 4, false)
	else:
		# Bark shingles: rows of overlapping slabs, staggered, each slightly tilted out.
		for side in [-1.0, 1.0]:
			var rows := 7
			for r in rows:
				var t := float(r) / rows
				var x := -ROOF_HALF_X - (0.15 if r % 2 == 1 else 0.0)
				while x < ROOF_HALF_X:
					var w := minf(rng.randf_range(0.26, 0.36), ROOF_HALF_X + 0.04 - x)
					var tilt := pitch + deg_to_rad(rng.randf_range(4.0, 8.0))
					var b := Basis(Vector3.RIGHT, side * tilt).rotated(Vector3.UP, rng.randf_range(-0.04, 0.04))
					m.box(2, m_bark(), Transform3D(b, _slope(side, t + 0.6 / rows, x + w * 0.5, 0.1)), Vector3(w - 0.015, 0.025, slope_len / rows + 0.12))
					x += w
		m.box(2, m_plank(), Transform3D(Basis(Vector3.RIGHT, deg_to_rad(45)), Vector3(0, RIDGE_Y + 0.1, 0)), Vector3(ROOF_HALF_X * 2 + 0.1, 0.18, 0.18))
	return 3


## Gable end: fills the triangle under the pitched roof (wattle frame, then daub).
static func _gable(m: Acc, rng: RandomNumberGenerator) -> int:
	var ridge := RIDGE_Y - 0.1
	m.pole(0, m_post(), Vector3(0, 0.0, 0), Vector3(0, ridge, 0), 0.05, 0.045)
	for sx in [-1.0, 1.0]:
		m.pole(0, m_post(), Vector3(sx * 1.0, 0.05, 0), Vector3(0, ridge, 0), 0.04, 0.04)
		m.pole(0, m_stake(), Vector3(sx * 0.5, 0.0, 0), Vector3(sx * 0.5, ridge * 0.5 + 0.05, 0), 0.025, 0.025, 5)
	var poly := PackedVector2Array([Vector2(-0.98, 0.0), Vector2(0.98, 0.0), Vector2(0.98, 0.08), Vector2(0.0, ridge - 0.02), Vector2(-0.98, 0.08)])
	m.slab(1, m_daub(), Transform3D(Basis(), Vector3(0, 0, rng.randf_range(-0.005, 0.005))), poly, 0.13)
	return 2


# ---------------------------------------------------------------- free-standing pieces

static func _fence(m: Acc, rng: RandomNumberGenerator) -> int:
	# A woven hurdle: posts (stage 0), rods (stage 1).
	for i in 4:
		var x := -0.9 + i * 0.6
		m.pole(0, m_post(), Vector3(x, -0.25, 0), Vector3(x + rng.randf_range(-0.02, 0.02), 1.15, 0), 0.055, 0.045, 6)
	for row in 7:
		var y := 0.2 + row * 0.13
		var pts: Array[Vector3] = []
		for k in 34:
			var x := lerpf(-0.98, 0.98, k / 33.0)
			pts.append(Vector3(x, y, sin((x + 0.9) / 0.3 * PI + (PI if row % 2 == 1 else 0.0)) * 0.04))
		m.tube(1, m_weave(), pts, 0.016)
	return 2


static func _palisade(m: Acc, rng: RandomNumberGenerator) -> int:
	# Two rails on short posts (stage 0), then a row of sharpened logs dug in (stage 1).
	for sx in [-0.8, 0.8]:
		m.pole(0, m_post(), Vector3(sx, -0.3, -0.2), Vector3(sx, 1.9, -0.2), 0.07, 0.06, 6)
	for y in [0.55, 1.7]:
		m.pole(0, m_log(), Vector3(-1.0, y, -0.17), Vector3(1.0, y, -0.17), 0.055, 0.05, 7)
	for i in 8:
		var x := -0.875 + i * 0.25
		var r := rng.randf_range(0.11, 0.125)
		var top := rng.randf_range(2.35, 2.7)
		var lean := Vector3(rng.randf_range(-0.03, 0.03), 0, rng.randf_range(-0.02, 0.02))
		m.pole(1, m_log(), Vector3(x, -0.35, 0), Vector3(x, top, 0) + lean, r, r * 0.92, 9)
		m.pole(1, m_plank(), Vector3(x, top, 0) + lean, Vector3(x, top + 0.32, 0) + lean * 1.15, r * 0.92, 0.0, 9)
	return 2


static func _lean_to(m: Acc, rng: RandomNumberGenerator) -> int:
	# Stage 0: forked posts + ridge pole.  Stage 1: sloping poles.  Stage 2: thatch courses.
	for sx in [-1.4, 1.4]:
		m.pole(0, m_post(), Vector3(sx, -0.2, -0.6), Vector3(sx, 2.02, -0.6), 0.075, 0.065, 7)
		m.pole(0, m_post(), Vector3(sx, 1.85, -0.6), Vector3(sx + signf(sx) * 0.08, 2.12, -0.62), 0.04, 0.035, 5)
	m.pole(0, m_log(), Vector3(-1.62, 1.97, -0.62), Vector3(1.62, 1.97, -0.62), 0.07, 0.065, 8)
	var low := Vector3(0, -0.05, 0.9)
	var high := Vector3(0, 2.15, -0.85)
	for i in 6:
		var x := -1.35 + i * 0.54
		m.pole(1, m_post(), low + Vector3(x, 0, 0), high + Vector3(x + rng.randf_range(-0.03, 0.03), 0, 0), 0.055, 0.045, 6)
	var dir := (high - low).normalized()
	var nrm := Vector3(1, 0, 0).cross(dir).normalized()
	if nrm.y < 0.0:
		nrm = -nrm
	_thatch(m, 2, low + dir * 0.05, dir, nrm, 1.58, (high - low).length() - 0.05, 6, 0.05, rng)
	return 3


## Thatch: overlapping courses laid from the eave up, each a straw mat with a shaggy fringe of uneven bundles
## hanging over the course below. eave = centre of the eave line, up = unit vector up the slope, nrm = slope
## normal, half_w = half width across the slope, length = eave-to-top distance, lift = clearance over the poles.
static func _thatch(m: Acc, stage: int, eave: Vector3, up: Vector3, nrm: Vector3, half_w: float, length: float,
		rows: int, lift: float, rng: RandomNumberGenerator) -> void:
	var across := up.cross(nrm).normalized()
	var basis := Basis(across, nrm, across.cross(nrm))  # X across, Y out of the roof, Z along the slope
	var course := length / rows
	for r in rows:
		var t0 := r * course
		var out := lift + 0.06 + r * 0.018  # each course sits a little proud of the one below
		var mat := m_thatch() if r % 2 == 0 else m_thatch_dark()
		m.box(stage, mat, Transform3D(basis, eave + up * (t0 + course * 0.6) + nrm * out), Vector3(half_w * 2.0 + 0.06, 0.1, course * 1.25))
		var x := -half_w
		while x < half_w:
			var w := rng.randf_range(0.08, 0.13)
			var hang := rng.randf_range(0.0, 0.09)  # bundles end at slightly different lengths
			var bb := basis.rotated(up, rng.randf_range(-0.05, 0.05)).rotated(across, rng.randf_range(0.03, 0.12))
			var c := eave + across * (x + w * 0.5) + up * (t0 + 0.13 - hang) + nrm * (out + 0.035)
			m.box(stage, mat if rng.randf() > 0.3 else m_thatch_dark(), Transform3D(bb, c), Vector3(w, rng.randf_range(0.07, 0.11), 0.34))
			x += w * rng.randf_range(0.75, 0.95)


## Raised garden bed: woven edging (stage 0), then dug soil heaped into two ridges (stage 1). Crops are
## drawn on top by FarmPlot (ridges at z = +-0.3, soil surface ~0.27).
static func _garden_bed(m: Acc, rng: RandomNumberGenerator) -> int:
	var hw := 0.98
	var hd := 0.58
	for c: Vector2 in [Vector2(-hw, -hd), Vector2(hw, -hd), Vector2(hw, hd), Vector2(-hw, hd)]:
		m.pole(0, m_post(), Vector3(c.x, -0.15, c.y), Vector3(c.x, 0.3, c.y), 0.035, 0.03, 5)
	for side: Array in [[Vector3(-hw, 0, -hd), Vector3(hw, 0, -hd)], [Vector3(-hw, 0, hd), Vector3(hw, 0, hd)],
			[Vector3(-hw, 0, -hd), Vector3(-hw, 0, hd)], [Vector3(hw, 0, -hd), Vector3(hw, 0, hd)]]:
		var a: Vector3 = side[0]
		var b: Vector3 = side[1]
		var along := (b - a).normalized()
		var out := Vector3(along.z, 0, -along.x)
		for row in 3:
			var pts: Array[Vector3] = []
			var n := int(a.distance_to(b) / 0.06) + 2
			for k in n:
				var t := float(k) / (n - 1)
				pts.append(a.lerp(b, t) + Vector3(0, 0.07 + row * 0.08, 0) + out * sin(t * a.distance_to(b) / 0.25 * PI + row * PI) * 0.02)
			m.tube(0, m_weave(), pts, 0.014)
	var soil := _m("Mud", Color(0.55, 0.45, 0.36), 1.6)
	m.box(1, soil, Transform3D(Basis(), Vector3(0, 0.1, 0)), Vector3(hw * 2 - 0.04, 0.2, hd * 2 - 0.04))
	for z in [-0.3, 0.3]:
		m.pole(1, soil, Vector3(-hw + 0.06, 0.19, z + rng.randf_range(-0.01, 0.01)), Vector3(hw - 0.06, 0.19, z), 0.09, 0.09, 8)
	return 2


static func _drying_rack(m: Acc, rng: RandomNumberGenerator) -> int:
	for sx in [-0.75, 0.75]:
		m.pole(0, m_stake(), Vector3(sx, -0.05, 0.5), Vector3(sx, 1.62, -0.02), 0.045, 0.035, 5)
		m.pole(0, m_stake(), Vector3(sx, -0.05, -0.5), Vector3(sx, 1.62, 0.02), 0.045, 0.035, 5)
	m.pole(1, m_log(), Vector3(-0.9, 1.55, 0), Vector3(0.9, 1.55 + rng.randf_range(-0.02, 0.02), 0), 0.04, 0.035, 6)
	for sx in [-0.75, 0.75]:
		m.pole(1, m_leather(), Vector3(sx - 0.05, 1.55, 0), Vector3(sx + 0.05, 1.55, 0), 0.05, 0.05, 6)
	return 2


## Plank door (hinge at local x = 0, swinging leaf to +x): boards, then battens, brace and leather hinges.
static func _door(m: Acc, rng: RandomNumberGenerator) -> int:
	var boards := 5
	var bw := (DOOR_W - 0.06) / boards
	for i in boards:
		var x := 0.03 + bw * (i + 0.5)
		var hh := DOOR_H - 0.05 - rng.randf_range(0.0, 0.04)
		m.box(0, m_plank(), Transform3D(Basis(), Vector3(x, hh * 0.5 + 0.02, rng.randf_range(-0.004, 0.004))), Vector3(bw - 0.012, hh, 0.045))
	for y in [0.35, DOOR_H - 0.35]:
		m.box(1, m_log(), Transform3D(Basis(), Vector3(DOOR_W * 0.5, y, 0.045)), Vector3(DOOR_W - 0.1, 0.1, 0.045))
	var brace := Vector3(DOOR_W - 0.12, DOOR_H - 0.7, 0) - Vector3(0.1, 0.0, 0)
	m.box(1, m_log(), Transform3D(Basis(Vector3.BACK, atan2(brace.y, brace.x)), Vector3(DOOR_W * 0.5, DOOR_H * 0.5, 0.045)),
		Vector3(brace.length(), 0.08, 0.04))
	for y in [0.35, DOOR_H - 0.35]:
		m.box(1, m_leather(), Transform3D(Basis(), Vector3(0.05, y, 0.0)), Vector3(0.16, 0.12, 0.09))
	return 2


# ---------------------------------------------------------------- mesh accumulator

## Collects triangles per (stage, material) and commits one MeshInstance3D per stage (one surface per material).
## Triangles are oriented automatically from their normals, so callers never worry about winding.
class Acc:
	var parts := {}  # "stage|material id" -> [SurfaceTool, Material, stage]

	func st(stage: int, mat: Material) -> SurfaceTool:
		var key := "%d|%d" % [stage, mat.get_instance_id()]
		if not parts.has(key):
			var s := SurfaceTool.new()
			s.begin(Mesh.PRIMITIVE_TRIANGLES)
			parts[key] = [s, mat, stage]
		return parts[key][0]

	func tri(stage: int, mat: Material, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
		var s := st(stage, mat)
		if (b - a).cross(c - a).dot(na + nb + nc) > 0.0:  # Godot front faces wind clockwise
			var t := b
			b = c
			c = t
			var tn := nb
			nb = nc
			nc = tn
		s.set_normal(na)
		s.add_vertex(a)
		s.set_normal(nb)
		s.add_vertex(b)
		s.set_normal(nc)
		s.add_vertex(c)

	func quad(stage: int, mat: Material, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
		tri(stage, mat, a, b, c, n, n, n)
		tri(stage, mat, a, c, d, n, n, n)

	## Box of `size` centred on xf.origin (xf.basis must be a pure rotation).
	func box(stage: int, mat: Material, xf: Transform3D, size: Vector3) -> void:
		var h := size * 0.5
		for axis in 3:
			var ua := (axis + 1) % 3
			var va := (axis + 2) % 3
			for sgn: float in [-1.0, 1.0]:
				var n := Vector3.ZERO
				n[axis] = sgn
				var c := n * h[axis]
				var du := Vector3.ZERO
				du[ua] = h[ua]
				var dv := Vector3.ZERO
				dv[va] = h[va]
				quad(stage, mat, xf * (c - du - dv), xf * (c + du - dv), xf * (c + du + dv), xf * (c - du + dv), (xf.basis * n).normalized())

	## Tapered round pole from a to b (radius ra at a, rb at b; rb = 0 makes a point).
	func pole(stage: int, mat: Material, a: Vector3, b: Vector3, ra: float, rb: float, seg: int = 7, caps: bool = true) -> void:
		var axis := b - a
		var length := axis.length()
		if length < 0.001:
			return
		var d := axis / length
		var ref := Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT
		var s1 := d.cross(ref).normalized()
		var s2 := d.cross(s1)
		for i in seg:
			var a0 := TAU * i / seg
			var a1 := TAU * (i + 1) / seg
			var n0 := s1 * cos(a0) + s2 * sin(a0)
			var n1 := s1 * cos(a1) + s2 * sin(a1)
			var p0 := a + n0 * ra
			var p1 := a + n1 * ra
			var q0 := b + n0 * rb
			var q1 := b + n1 * rb
			tri(stage, mat, p0, p1, q1, n0, n1, n1)
			if rb > 0.0005:
				tri(stage, mat, p0, q1, q0, n0, n1, n0)
			if caps:
				tri(stage, mat, a, p1, p0, -d, -d, -d)
				if rb > 0.0005:
					tri(stage, mat, b, q0, q1, d, d, d)

	## Rod through a polyline (woven withies).
	func tube(stage: int, mat: Material, pts: Array[Vector3], r: float, seg: int = 5) -> void:
		for i in pts.size() - 1:
			pole(stage, mat, pts[i], pts[i + 1], r, r, seg, i == 0 or i == pts.size() - 2)

	## Polygon (local XY) extruded `thick` along local Z.
	func slab(stage: int, mat: Material, xf: Transform3D, poly: PackedVector2Array, thick: float) -> void:
		var idx := Geometry2D.triangulate_polygon(poly)
		var hz := thick * 0.5
		for side: float in [-1.0, 1.0]:
			var n := (xf.basis * Vector3(0, 0, side)).normalized()
			for i in range(0, idx.size(), 3):
				var a := poly[idx[i]]
				var b := poly[idx[i + 1]]
				var c := poly[idx[i + 2]]
				tri(stage, mat, xf * Vector3(a.x, a.y, side * hz), xf * Vector3(b.x, b.y, side * hz), xf * Vector3(c.x, c.y, side * hz), n, n, n)
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			var e := b - a
			var n2 := Vector2(e.y, -e.x).normalized()
			var centre := Vector2.ZERO
			for p in poly:
				centre += p
			centre /= poly.size()
			if n2.dot((a + b) * 0.5 - centre) < 0.0:
				n2 = -n2
			var n := (xf.basis * Vector3(n2.x, n2.y, 0)).normalized()
			quad(stage, mat, xf * Vector3(a.x, a.y, -hz), xf * Vector3(b.x, b.y, -hz), xf * Vector3(b.x, b.y, hz), xf * Vector3(a.x, a.y, hz), n)

	func commit(parent: Node3D) -> void:
		var by_stage := {}
		for key: String in parts:
			var e: Array = parts[key]
			if not by_stage.has(e[2]):
				by_stage[e[2]] = []
			by_stage[e[2]].append(e)
		for stage: int in by_stage:
			var mesh := ArrayMesh.new()
			for e: Array in by_stage[stage]:
				(e[0] as SurfaceTool).commit(mesh)
				mesh.surface_set_material(mesh.get_surface_count() - 1, e[1])
			var holder := Node3D.new()
			holder.name = "Stage%d" % stage
			parent.add_child(holder)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			holder.add_child(mi)
