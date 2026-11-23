class_name Birds
extends Node3D
## Birds in the sky by day: a few flocks of small birds that wander in loose groups over the land around the
## player (flapping, with short glides), and raptors soaring in wide circles high up. All of them are one
## MultiMesh of 8-triangle silhouettes; positions are updated on the CPU (a few dozen birds), wing beats in the
## vertex shader (bird.gdshader). They keep away from the ground and go to roost at dusk.

const FLOCKS := 4
const PER_FLOCK := 9
const RAPTORS := 3
const AREA := 420.0  # flocks wander within this distance of the player

var world: ForestWorld
var _mm: MultiMesh
var _flocks: Array = []   # {center, target, vel, members: [{off, phase, speed}]}
var _raptors: Array = []  # {center, radius, height, angle, speed}
var _rng := RandomNumberGenerator.new()
var _time := 0.0


func _ready() -> void:
	_rng.seed = ForestWorld.SEED + 808
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _bird_mesh()
	_mm.instance_count = FLOCKS * PER_FLOCK + RAPTORS
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	var m := ShaderMaterial.new()
	m.shader = preload("res://world/shaders/bird.gdshader")
	mmi.material_override = m
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-5000, -100, -5000), Vector3(10000, 1500, 10000))
	add_child(mmi)
	for f in FLOCKS:
		var members := []
		for i in PER_FLOCK:
			members.append({"off": Vector3(_rng.randf_range(-6, 6), _rng.randf_range(-2, 2), _rng.randf_range(-6, 6)),
				"phase": _rng.randf(), "wob": _rng.randf() * TAU})
		_flocks.append({"center": Vector3.ZERO, "target": Vector3.ZERO, "vel": Vector3.ZERO, "members": members,
			"placed": false, "speed": _rng.randf_range(9.0, 13.0)})
	for r in RAPTORS:
		_raptors.append({"center": Vector3.ZERO, "radius": _rng.randf_range(50, 110), "height": _rng.randf_range(90, 160),
			"angle": _rng.randf() * TAU, "speed": _rng.randf_range(0.08, 0.14) * (1.0 if r % 2 == 0 else -1.0), "placed": false})


## Body plus two wings (each three triangles: an inner and an outer panel with a swept tip), 1 m span.
static func _bird_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tri := func(a: Vector3, b: Vector3, c: Vector3, ta: float, tb: float, tc: float, side: float) -> void:
		for v: Array in [[a, ta], [b, tb], [c, tc]]:
			st.set_color(Color(v[1], side, 0))
			st.add_vertex(v[0])
	# body: a thin diamond along -Z (forward)
	tri.call(Vector3(0, 0, -0.32), Vector3(0.05, 0, 0), Vector3(-0.05, 0, 0), 0.0, 0.0, 0.0, 0.5)
	tri.call(Vector3(0.05, 0, 0), Vector3(0, 0, 0.3), Vector3(-0.05, 0, 0), 0.0, 0.0, 0.0, 0.5)
	tri.call(Vector3(0, 0, 0.22), Vector3(0.09, 0, 0.36), Vector3(-0.09, 0, 0.36), 0.0, 0.0, 0.0, 0.5)  # tail
	for s: float in [1.0, -1.0]:
		var sd := 1.0 if s > 0.0 else 0.0
		var root_f := Vector3(0.04 * s, 0, -0.06)
		var root_b := Vector3(0.04 * s, 0, 0.1)
		var mid_f := Vector3(0.26 * s, 0, -0.04)
		var mid_b := Vector3(0.24 * s, 0, 0.14)
		var tip := Vector3(0.5 * s, 0, 0.12)
		tri.call(root_f, mid_f, root_b, 0.0, 0.5, 0.0, sd)
		tri.call(mid_f, mid_b, root_b, 0.5, 0.5, 0.0, sd)
		tri.call(mid_f, tip, mid_b, 0.5, 1.0, 0.5, sd)
	st.generate_normals()
	return st.commit()


func _process(delta: float) -> void:
	if world == null or world.day_night == null or not is_instance_valid(world.player):
		return
	_time += delta
	var p := (world.player as Node3D).global_position
	var day := smoothstep(-0.02, 0.15, world.day_night.sun_elevation())
	var rainy: float = world.weather.rain if world.weather else 0.0
	var show := day * (1.0 - clampf(rainy * 2.0, 0.0, 1.0))
	_mm.visible_instance_count = _mm.instance_count if show > 0.05 else 0
	if show <= 0.05:
		return
	var idx := 0
	for f: Dictionary in _flocks:
		var c: Vector3 = f.center
		if not f.placed or c.distance_to(p) > AREA * 1.6:
			c = p + Vector3(_rng.randf_range(-AREA, AREA), 0, _rng.randf_range(-AREA, AREA))
			f.placed = true
			f.target = c
		if (f.target as Vector3).distance_to(c) < 25.0:
			var a := _rng.randf() * TAU
			f.target = p + Vector3(cos(a), 0, sin(a)) * _rng.randf_range(60.0, AREA)
		var ground := world.height_at(c.x, c.z)
		var want := (f.target as Vector3) - c
		want.y = 0.0
		var dir := want.normalized() * float(f.speed)
		f.vel = (f.vel as Vector3).lerp(dir, 1.0 - exp(-delta * 0.6))
		c += (f.vel as Vector3) * delta
		c.y = lerpf(c.y if c.y > 0.0 else ground + 40.0, ground + 28.0 + 12.0 * sin(_time * 0.2 + idx), 1.0 - exp(-delta * 0.5))
		f.center = c
		var heading := atan2(-(f.vel as Vector3).x, -(f.vel as Vector3).z)
		for m: Dictionary in f.members:
			var off: Vector3 = m.off
			var wob := Vector3(sin(_time * 1.3 + float(m.wob)), sin(_time * 1.9 + float(m.wob)) * 0.5, cos(_time * 1.1 + float(m.wob))) * 2.0
			var pos := c + off.rotated(Vector3.UP, heading) + wob
			var xf := Transform3D(Basis(Vector3.UP, heading).scaled(Vector3.ONE * 1.1), pos)  # crow-sized (a little large, to read from afar)
			_mm.set_instance_transform(idx, xf)
			# flap in bursts, glide in between
			var flap := 1.0 if fmod(_time * 0.7 + float(m.phase) * 3.0, 3.0) < 2.0 else 0.15
			_mm.set_instance_custom_data(idx, Color(float(m.phase), flap, 1.0, 0.0))
			idx += 1
	for r: Dictionary in _raptors:
		var c: Vector3 = r.center
		if not r.placed or Vector2(c.x - p.x, c.z - p.z).length() > AREA * 1.5:
			c = p + Vector3(_rng.randf_range(-250, 250), 0, _rng.randf_range(-250, 250))
			r.placed = true
		c = c.lerp(Vector3(p.x, c.y, p.z), delta * 0.004)  # slowly drift after the player
		r.center = c
		r.angle = float(r.angle) + float(r.speed) * delta
		var a: float = r.angle
		var pos := c + Vector3(cos(a), 0, sin(a)) * float(r.radius)
		pos.y = world.height_at(pos.x, pos.z) + float(r.height) + 6.0 * sin(_time * 0.3 + a)
		var tangent := Vector3(-sin(a), 0, cos(a)) * signf(float(r.speed))
		var basis := Basis.looking_at(tangent, Vector3.UP) * Basis(Vector3.FORWARD, 0.25 * signf(float(r.speed)))  # banking
		_mm.set_instance_transform(idx, Transform3D(basis.scaled(Vector3.ONE * 3.2), pos))  # eagle-sized
		_mm.set_instance_custom_data(idx, Color(0.0, 0.0, 1.0, 0.0))  # soaring: wings held still
		idx += 1
