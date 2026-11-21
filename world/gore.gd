class_name Gore
extends RefCounted
## Blood and dismemberment effects (toggle: Settings → Игра → «Кровь и расчленение»).

static var _splat: Texture2D
static var _drop_mat: StandardMaterial3D


static func enabled() -> bool:
	return bool(Settings.get_value("gameplay", "gore"))


static func _drop_material() -> StandardMaterial3D:
	if _drop_mat == null:
		_drop_mat = StandardMaterial3D.new()
		_drop_mat.albedo_color = Color(0.32, 0.02, 0.02)
		_drop_mat.roughness = 0.2
	return _drop_mat


## Spray of droplets from a wound.
static func burst(parent: Node, pos: Vector3, dir: Vector3, amount: int = 24, duration: float = 0.0) -> CPUParticles3D:
	if parent == null or not parent.is_inside_tree():
		return null
	var p := CPUParticles3D.new()
	p.one_shot = duration <= 0.0
	p.explosiveness = 0.9 if p.one_shot else 0.0
	p.amount = amount if enabled() else maxi(amount / 6, 2)
	p.lifetime = 0.8
	p.direction = (dir + Vector3.UP * 0.4).normalized()
	p.spread = 35.0
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 4.0
	p.gravity = Vector3(0, -9.8, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.3
	p.mesh = Graybox.sphere(0.012, 5)
	p.material_override = _drop_material()
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	var life := p.lifetime + (duration if duration > 0.0 else 0.0) + 0.5
	if duration > 0.0:
		_after(p, duration, p.set.bind("emitting", false))
	_after(p, life, p.queue_free)
	return p


## Calls `cb` after `seconds`, owned by `node` (freed together, never calls into a freed object).
static func _after(node: Node, seconds: float, cb: Callable) -> void:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = seconds
	t.autostart = true
	t.timeout.connect(cb)
	node.add_child(t)


## Blood decal on the ground below a point (pools, drips, trails).
static func decal(world: Node3D, pos: Vector3, size: float = 0.6) -> Decal:
	if world == null or not enabled() or not world.is_inside_tree():
		return null
	var d := Decal.new()
	d.texture_albedo = _splat_texture()
	d.size = Vector3(size, 1.2, size)
	d.modulate = Color(0.35, 0.02, 0.02, 0.9)
	d.distance_fade_enabled = true
	d.distance_fade_begin = 30.0
	d.distance_fade_length = 10.0
	world.add_child(d)
	d.global_position = pos + Vector3.UP * 0.3
	d.rotation.y = randf() * TAU
	d.add_to_group("blood")
	_after(d, 900.0, d.queue_free)
	return d


static func _splat_texture() -> Texture2D:
	if _splat:
		return _splat
	var img := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var blobs: Array = []
	for i in 9:
		blobs.append([Vector2(64 + rng.randf_range(-30, 30), 64 + rng.randf_range(-30, 30)), rng.randf_range(8, 26)])
	for y in 128:
		for x in 128:
			var a := 0.0
			for b: Array in blobs:
				a = maxf(a, clampf(1.3 - Vector2(x, y).distance_to(b[0]) / float(b[1]), 0.0, 1.0))
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	_splat = ImageTexture.create_from_image(img)
	return _splat


## Flesh cap + pulsing spurt at a severed joint, following the (parent) bone.
static func stump(skel: Skeleton3D, parent_bone: String, joint_local: Vector3, radius: float) -> void:
	var att := BoneAttachment3D.new()
	att.bone_name = parent_bone
	skel.add_child(att)
	var cap := MeshInstance3D.new()
	cap.mesh = Graybox.sphere(1.0, 10)
	cap.scale = Vector3(radius, radius * 0.5, radius)
	cap.position = joint_local
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.42, 0.05, 0.04)
	m.roughness = 0.3
	cap.material_override = m
	att.add_child(cap)
	if enabled():
		var spurt := burst(att, att.global_position, Vector3.UP, 10, 4.0)
		if spurt:
			spurt.position = joint_local


## Detached part: rigid body with the rest-pose mesh placed at the bone's current pose.
static func spawn_part(world: ForestWorld, path: String, xform: Transform3D, impulse: Vector3) -> RigidBody3D:
	if not ResourceLoader.exists(path):
		return null
	var body := RigidBody3D.new()
	body.collision_layer = 4
	body.collision_mask = 1
	body.mass = 4.0
	body.add_to_group("severed")
	var mesh := AssetLib.instance(path)
	body.add_child(mesh)
	var box := AssetLib.aabb(mesh)
	var center := box.position + box.size * 0.5
	mesh.position = -center
	Graybox.add_shape(body, Graybox.box_shape(box.size.max(Vector3(0.08, 0.08, 0.08)) * 0.9))
	world.add_child(body)
	body.global_transform = Transform3D(xform.basis, xform * center)
	body.apply_central_impulse(impulse)
	body.apply_torque_impulse(Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * 0.6)
	burst(body, body.global_position, Vector3.DOWN, 12, 1.5)
	_after(body, 1200.0, body.queue_free)
	return body
