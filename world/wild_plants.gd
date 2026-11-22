class_name WildPlants
extends RefCounted
## Procedural wild plants gathered by hand (resource_nodes.json): a stand of wild emmer, wild carrot with its
## lace-white umbels, yarrow, blue-flowered flax, a reed bed with brown cattail heads, a wet clay bank.
## One merged mesh per material (BuildingVisuals.Acc) so a whole meadow stays cheap.


static func build(kind: StringName, parent: Node3D, seed: int, s: float) -> void:
	var m := BuildingVisuals.Acc.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	match kind:
		&"wild_grain": _grain(m, rng, s)
		&"wild_carrot": _carrot(m, rng, s)
		&"herbs": _yarrow(m, rng, s)
		&"flax": _flax(m, rng, s)
		&"reeds": _reeds(m, rng, s)
		&"clay": _clay(m, rng, s)
	m.commit(parent)
	for mi: MeshInstance3D in parent.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if kind != &"clay" else GeometryInstance3D.SHADOW_CASTING_SETTING_ON


static func _mat(c: Color, rough: float = 0.85) -> Material:
	return Graybox.mat(c, rough)


## Random point in a disc of radius r (denser towards the middle, like a real clump).
static func _spot(rng: RandomNumberGenerator, r: float) -> Vector3:
	var a := rng.randf() * TAU
	var d := sqrt(rng.randf()) * r
	return Vector3(cos(a) * d, 0, sin(a) * d)


static func _grain(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, s: float) -> void:
	var stalk := _mat(Color(0.62, 0.6, 0.3))
	var green := _mat(Color(0.42, 0.52, 0.24))
	var head := _mat(Color(0.82, 0.7, 0.38), 0.7)
	for i in 46:
		var base := _spot(rng, 0.55 * s)
		var lean := Vector3(rng.randf_range(-0.08, 0.08), 0, rng.randf_range(-0.08, 0.08))
		var top := base + lean + Vector3(0, rng.randf_range(0.6, 0.85) * s, 0)
		m.pole(0, stalk if rng.randf() > 0.3 else green, base, top, 0.007, 0.005, 4, false)
		var droop := (lean + Vector3(0.02, 0, 0)).normalized() * 0.04
		m.pole(0, head, top - Vector3(0, 0.01, 0), top + Vector3(0, 0.1, 0) + droop, 0.015, 0.007, 5)
		if i % 3 == 0:  # a blade of leaf low on the stem
			var b := Basis.from_euler(Vector3(rng.randf_range(0.6, 1.0), rng.randf() * TAU, 0))
			m.box(0, green, Transform3D(b, base.lerp(top, 0.25)), Vector3(0.015, 0.004, 0.22) * s)


static func _carrot(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, s: float) -> void:
	var stem := _mat(Color(0.36, 0.5, 0.24))
	var leaf := _mat(Color(0.3, 0.48, 0.2))
	var lace := _mat(Color(0.93, 0.92, 0.86), 0.9)
	for i in 6:
		var base := _spot(rng, 0.4 * s)
		for k in 7:  # feathery rosette
			var a := TAU * k / 7.0 + rng.randf_range(-0.2, 0.2)
			var tip := base + Vector3(cos(a) * 0.16, rng.randf_range(0.12, 0.22), sin(a) * 0.16) * s
			m.box(0, leaf, Transform3D(Basis.looking_at((tip - base).normalized(), Vector3.UP), base.lerp(tip, 0.55)), Vector3(0.06, 0.004, 0.2) * s)
		var top := base + Vector3(rng.randf_range(-0.05, 0.05), rng.randf_range(0.5, 0.75) * s, rng.randf_range(-0.05, 0.05))
		m.pole(0, stem, base, top, 0.008, 0.006, 4, false)
		m.pole(0, lace, top, top + Vector3(0, 0.025, 0), 0.07 * s, 0.075 * s, 9)  # flat white umbel


static func _yarrow(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, s: float) -> void:
	var stem := _mat(Color(0.34, 0.46, 0.25))
	var bloom := _mat(Color(0.94, 0.82, 0.86), 0.9)
	for i in 9:
		var base := _spot(rng, 0.35 * s)
		var top := base + Vector3(rng.randf_range(-0.04, 0.04), rng.randf_range(0.32, 0.5) * s, rng.randf_range(-0.04, 0.04))
		m.pole(0, stem, base, top, 0.008, 0.006, 4, false)
		for k in 3:
			var at := base.lerp(top, 0.2 + k * 0.22)
			m.box(0, stem, Transform3D(Basis.from_euler(Vector3(0.35, rng.randf() * TAU, 0)), at), Vector3(0.1, 0.005, 0.022) * s)
		for k in 4:  # a flat-topped cluster of tiny florets
			var o := Vector3(rng.randf_range(-0.035, 0.035), rng.randf_range(0.0, 0.015), rng.randf_range(-0.035, 0.035)) * s
			m.box(0, bloom, Transform3D(Basis(), top + o), Vector3(0.04, 0.018, 0.04) * s)


static func _flax(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, s: float) -> void:
	var stem := _mat(Color(0.4, 0.52, 0.28))
	var blue := _mat(Color(0.45, 0.58, 0.9), 0.6)
	for i in 34:
		var base := _spot(rng, 0.5 * s)
		var top := base + Vector3(rng.randf_range(-0.05, 0.05), rng.randf_range(0.55, 0.75) * s, rng.randf_range(-0.05, 0.05))
		m.pole(0, stem, base, top, 0.005, 0.004, 4, false)
		if rng.randf() < 0.7:
			m.box(0, blue, Transform3D(Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)), top), Vector3(0.038, 0.008, 0.038) * s)


static func _reeds(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, s: float) -> void:
	var stalk := _mat(Color(0.5, 0.55, 0.3))
	var dry := _mat(Color(0.66, 0.6, 0.38))
	var head := _mat(Color(0.36, 0.22, 0.12), 0.9)
	for i in 30:
		var base := _spot(rng, 0.55 * s)
		var top := base + Vector3(rng.randf_range(-0.1, 0.1), rng.randf_range(1.3, 2.0) * s, rng.randf_range(-0.1, 0.1))
		m.pole(0, stalk if rng.randf() > 0.35 else dry, base, top, 0.012, 0.006, 4, false)
		if i % 3 == 0:  # cattail head
			var h := base.lerp(top, 0.82)
			m.pole(0, head, h, h + (top - base).normalized() * 0.18 * s, 0.025, 0.022, 6)
		if i % 2 == 0:  # long arching leaf
			var a := rng.randf() * TAU
			var tip := base + Vector3(cos(a) * 0.35, rng.randf_range(0.7, 1.1), sin(a) * 0.35) * s
			m.box(0, stalk, Transform3D(Basis.looking_at((tip - base).normalized(), Vector3.UP), base.lerp(tip, 0.5)),
				Vector3(0.03, 0.005, base.distance_to(tip)))


static func _clay(m: BuildingVisuals.Acc, rng: RandomNumberGenerator, s: float) -> void:
	var clay := Graybox.tex("Mud", Color(0.78, 0.66, 0.56), 1.5)
	var wet := Graybox.tex("Mud", Color(0.55, 0.46, 0.4), 1.5)
	for i in 9:
		var c := _spot(rng, 0.45 * s)
		var b := Basis.from_euler(Vector3(rng.randf_range(-0.2, 0.2), rng.randf() * TAU, rng.randf_range(-0.2, 0.2)))
		m.box(0, clay if i % 3 != 0 else wet, Transform3D(b, c + Vector3(0, 0.06, 0)),
			Vector3(rng.randf_range(0.22, 0.4), rng.randf_range(0.08, 0.16), rng.randf_range(0.2, 0.35)) * s)
	m.box(0, wet, Transform3D(Basis(), Vector3(0, 0.02, 0)), Vector3(1.0, 0.05, 0.9) * s)
