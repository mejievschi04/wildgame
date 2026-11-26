class_name ThrownSpear
extends WorldPickup
## A thrown spear or a shot arrow with real flight (GDD §10 "suliță aruncată"):
## - ballistic flight under gravity with air drag (a = -k·|v|·v), point first along the velocity;
## - the tip is swept every physics step, so it hits what the point reaches, not what the shaft brushes;
## - it sinks into what it hits by speed, angle and material: deep in soil, less in wood, into flesh, never into
##   stone; it stays there quivering, and moves with what it is stuck in (an animal's bone, a falling tree);
## - glancing, slow or stone hits ricochet: it bounces off and tumbles as a rigid body (mass from the item data);
## - water slows it hard; arrows can snap, spears wear.
## Arrows reuse it with their own damage, speed, drag and break chances (player.gd _release_draw).

const BASE_DAMAGE := 48.0
const WEAR := 8
const MAX_FLIGHT := 12.0  # seconds; anything still flying then (fell off the world) is dropped
## Penetration depth (m) at full speed head-on, per material.
const DEPTH := {&"soil": 0.32, &"wood": 0.09, &"flesh": 0.25}
## Restitution of the bounce off each material (the part of the normal speed that comes back).
const BOUNCE := {&"stone": 0.3, &"soil": 0.08, &"wood": 0.15, &"flesh": 0.05}
const WOBBLE_TIME := 0.9

var thrower: Node3D
var flying := true
var base_damage := BASE_DAMAGE
## Impact speed at which base_damage applies in full (damage grows with the speed, 0.3x..1.3x).
var ref_speed := 22.0
var wear := WEAR
## Air drag coefficient (1/m): a javelin flies clean, fletched arrows slow down more.
var drag := 0.0009
## Below this impact speed (along the shaft) nothing is pierced, it just bounces off.
var stick_speed := 9.0
## Chance the projectile is destroyed when it hits each material (arrows snap; spears only wear).
var break_chance := 0.0
var stone_break_chance := 0.0
## Spears are hurled with a little wobble; it shows in a slow nose oscillation round the velocity.
var flight_wobble := 0.0

var _vel := Vector3.ZERO
var _tip := 0.9  # body origin → tip, along +Z
var _prev_tip := Vector3.ZERO
var _age := 0.0
var _in_water := false
var _exclude: Array[RID] = []
## Stuck: what it is stuck in (a body, or a skeleton with a bone), and its transform relative to that.
var _host: Node3D
var _host_bone := -1
var _rel := Transform3D.IDENTITY
var _wobble_t := -1.0
var _wobble_axis := Vector3.RIGHT
var _wobble_amp := 0.0
var _rest_t := 0.0
var _base_xf := Transform3D.IDENTITY  # stuck in something that never moves: where it rests


func launch(p_stack: ItemStack, from: Vector3, vel: Vector3, by: Node3D) -> void:
	setup(p_stack)
	thrower = by
	var data := stack.get_data()
	mass = maxf(data.weight if data else 1.0, 0.03)
	for cs: CollisionShape3D in find_children("*", "CollisionShape3D", false, false):
		if cs.shape is BoxShape3D:
			_tip = (cs.shape as BoxShape3D).size.z * 0.5
	# in flight it is moved by hand (kinematic) and touches nothing until its tip does
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	collision_layer = 0
	collision_mask = 0
	if by is CollisionObject3D:
		_exclude.append((by as CollisionObject3D).get_rid())
	_vel = vel
	global_position = from
	_orient(1.0)
	_prev_tip = from  # the first sweep starts at the hand, so nothing right in front is skipped
	set_physics_process(true)
	set_process(false)


func _physics_process(delta: float) -> void:
	if flying:
		_fly(delta)
	elif _host != null:
		_follow_host(delta)
	elif not freeze:
		_settle(delta)


# ---------------------------------------------------------------- flight

func _fly(delta: float) -> void:
	_age += delta
	if _age > MAX_FLIGHT:
		_release(Vector3.ZERO, Vector3.ZERO)
		return
	var g := Vector3.DOWN * float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var k := drag * (30.0 if _in_water else 1.0)
	_vel += (g - _vel * _vel.length() * k) * delta
	global_position += _vel * delta
	_orient(delta)
	var tip := global_position + _dir() * _tip
	_sweep(_prev_tip, tip)
	if flying:
		_prev_tip = tip


func _dir() -> Vector3:
	return global_transform.basis.z.normalized()


## Point along the velocity (fletching and a forward balance keep it there), with a hurled spear's slow wobble.
func _orient(delta: float) -> void:
	if _vel.length() < 0.5:
		return
	var f := _vel.normalized()
	if flight_wobble > 0.0:
		var side := f.cross(Vector3.UP)
		if side.length() > 0.01:
			f = f.rotated(side.normalized(), sin(_age * 9.0) * flight_wobble * exp(-_age * 1.5))
	var up := Vector3.UP if absf(f.y) < 0.98 else Vector3.FORWARD
	var b := Basis.looking_at(-f, up)
	global_transform.basis = b if delta >= 1.0 else global_transform.basis.orthonormalized().slerp(b, minf(delta * 30.0, 1.0))


func _sweep(a: Vector3, b: Vector3) -> void:
	var space := get_world_3d().direct_space_state
	if not _in_water:
		var wq := PhysicsRayQueryParameters3D.create(a, b, 8)
		wq.collide_with_areas = true
		wq.collide_with_bodies = false
		var w := space.intersect_ray(wq)
		if not w.is_empty():
			_in_water = true
			_vel *= 0.45
			Sfx.play(&"step_water", w.position, -4.0)
	var mask := 1 | 4 | Animal.LAYER_CREATURE  # 4: carcasses and corpses (pickups and bushes are flown through)
	if not (thrower != null and thrower.is_in_group("player")):
		mask |= 2  # the player can be hit by what others throw
	for i in 8:
		var q := PhysicsRayQueryParameters3D.create(a, b, mask, _exclude)
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return
		var body := hit.collider as Node
		if _passes_through(body):
			_exclude.append(hit.rid)
			continue
		_impact(body, hit.position, hit.normal)
		return


## Flown through: people of the thrower's own band (the spear flies past them), and on the soft layer everything
## but bodies: pickups (other arrows), bushes, reeds, unbuilt blueprints.
func _passes_through(body: Node) -> bool:
	if body is HumanNPC and thrower is HumanNPC and not (body as HumanNPC).is_dead():
		return (body as HumanNPC).faction == (thrower as HumanNPC).faction
	if body is CollisionObject3D and (body as CollisionObject3D).collision_layer & 1 == 0 \
			and (body as CollisionObject3D).collision_layer & Animal.LAYER_CREATURE == 0:
		return not (body is Animal or body is HumanNPC)
	return false


# ---------------------------------------------------------------- impact

func _impact(body: Node, point: Vector3, normal: Vector3) -> void:
	flying = false
	var speed := _vel.length()
	var dir := _vel / maxf(speed, 0.001)
	if normal == Vector3.ZERO:
		normal = -dir
	var head_on := clampf(dir.dot(-normal), 0.0, 1.0)  # 1 = straight in, 0 = grazing
	var mat := _material(body, normal)
	var data := stack.get_data()
	if mat == &"flesh" and not _is_dead_body(body):
		var dmg := base_damage * clampf(pow(speed / ref_speed, 1.5), 0.3, 1.3) * lerpf(0.6, 1.0, head_on)
		if body is HumanNPC:
			(body as HumanNPC).take_damage(dmg, thrower, point, data)
		elif body is Animal:
			(body as Animal).take_damage(dmg, thrower, point, data)
		elif body.has_method("take_hit"):
			body.take_hit(dmg, &"human", 0.5, point - dir * 3.0, thrower)
		if is_instance_valid(body) and body.has_method("hit_impulse"):
			body.hit_impulse(HitPhysics.projectile_impulse(mass, speed), dir)
		Sfx.play(&"chop", point, -4.0)
	elif mat == &"flesh":
		Sfx.play(&"chop", point, -8.0)
	elif mat == &"wood":
		Sfx.play(&"axe_chop", point, -10.0, 0.15)
	elif mat == &"stone":
		Sfx.play(&"stone_knock", point, -6.0, 0.2)
	else:
		Sfx.play(&"step_grass", point, -6.0, 0.2)
	if _wear_out(mat):
		return
	var along := speed * head_on
	if mat == &"flesh":
		along = speed  # a creature's collider is a rough capsule: its normal says little, and flesh gives way
	if DEPTH.has(mat) and along > stick_speed and (head_on > 0.3 or mat == &"flesh") and not body.is_in_group("player"):
		var depth := float(DEPTH[mat]) * clampf(along / ref_speed, 0.25, 1.0)
		_stick(body, point + dir * depth - dir * _tip, dir, point)
	else:
		_ricochet(point, normal, dir, speed, mat)


## soil (terrain, the ground), wood (trees, logs, buildings), flesh (anything alive), stone (rocks, cliffs, caves).
func _material(body: Node, normal: Vector3) -> StringName:
	if body is Animal or body is HumanNPC or body is Carcass or body.is_in_group("player"):
		return &"flesh"
	if body is TreeNode or body is BuildingPiece or body is LogPiece or body is LeafBed or body is Stash \
			or body.has_meta(&"wood"):
		return &"wood"
	if body is ResourceNode:
		return &"wood" if String((body as ResourceNode).kind).begins_with("tree") else &"stone"
	if body.is_in_group("terrain"):
		if body.get_parent() is Cave:
			return &"stone"
		return &"soil" if normal.y > 0.6 else &"stone"  # steep faces are rock
	return &"stone"


## Wears a spear / maybe snaps an arrow on impact. True when it is gone.
func _wear_out(mat: StringName) -> bool:
	var p := stone_break_chance if mat == &"stone" else break_chance
	if p > 0.0 and randf() < p:
		queue_free()
		return true
	if stack.durability > 0:
		stack.durability -= wear * (2 if mat == &"stone" else 1)
		if stack.durability <= 0:
			Events.toast(Loc.t("MSG_TOOL_BROKE", {"item": stack.get_data().display_name()}), &"danger")
			queue_free()
			return true
	return false


## Stays in what it hit, tip buried, quivering; follows it if it moves (a creature's bone, a falling tree).
func _stick(body: Node, at: Vector3, dir: Vector3, point: Vector3) -> void:
	global_position = at
	collision_layer = 4  # can be pulled out and picked up
	collision_mask = 0
	_host = body as Node3D
	_host_bone = -1
	if body is Animal or body is HumanNPC:
		var skel := _skeleton_of(body)
		if skel:
			_host = skel
			_host_bone = _nearest_bone(skel, point)
	if body is StaticBody3D and body.get_class() == "StaticBody3D" and not (body is ResourceNode):
		_host = null  # the ground and rocks never move: no need to follow
	_rel = _host_xf().affine_inverse() * global_transform if _host else Transform3D.IDENTITY
	var side := dir.cross(Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT).normalized()
	_wobble_axis = side.rotated(dir, randf() * TAU)
	_wobble_amp = deg_to_rad(5.0 if mass < 0.5 else 3.5)
	_wobble_t = 0.0
	if _host == null:
		_base_xf = global_transform
	set_physics_process(true)
	set_process(_host == null)



func _skeleton_of(body: Node) -> Skeleton3D:
	var s: Variant = body.get("_skel")
	if s is Skeleton3D:
		return s
	var found := body.find_children("*", "Skeleton3D", true, false)
	return found[0] as Skeleton3D if not found.is_empty() else null


func _nearest_bone(skel: Skeleton3D, point: Vector3) -> int:
	var best := -1
	var best_d := INF
	for i in skel.get_bone_count():
		var d := (skel.global_transform * skel.get_bone_global_pose(i).origin).distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = i
	return best


func _host_xf() -> Transform3D:
	if _host_bone >= 0:
		var skel := _host as Skeleton3D
		var bone := skel.get_bone_global_pose(_host_bone)
		return skel.global_transform * Transform3D(bone.basis.orthonormalized(), bone.origin)
	return _host.global_transform


func _follow_host(delta: float) -> void:
	if not is_instance_valid(_host) or not _host.is_inside_tree():
		# what it was stuck in is gone (butchered, despawned): it drops
		_host = null
		_release(Vector3.ZERO, Vector3.ZERO)
		return
	var xf := _host_xf() * _rel
	global_transform = _wobble(xf, delta)


func _wobble(xf: Transform3D, delta: float) -> Transform3D:
	if _wobble_t < 0.0:
		return xf
	_wobble_t += delta
	if _wobble_t > WOBBLE_TIME:
		_wobble_t = -1.0
		if _host == null:
			set_physics_process(false)
			set_process(false)
		return xf
	var a := _wobble_amp * exp(-_wobble_t * 6.0) * sin(_wobble_t * 48.0)
	# quiver round the buried tip
	var pivot := xf * Vector3(0, 0, _tip)
	var r := Basis(_wobble_axis, a)
	return Transform3D(r * xf.basis, pivot + r * (xf.origin - pivot))


func _process(delta: float) -> void:
	if _host == null and _wobble_t >= 0.0 and not flying:
		global_transform = _wobble(_base_xf, delta)


## Bounces off: the normal part of the speed comes back by the material's restitution, the rest is scrubbed by
## friction, and the blow on the point sets it tumbling end over end. Then it is an ordinary rigid body.
func _ricochet(point: Vector3, normal: Vector3, dir: Vector3, speed: float, mat: StringName) -> void:
	var v := dir * speed
	var vn := normal * v.dot(normal)
	var vt := v - vn
	var e := float(BOUNCE.get(mat, 0.2))
	var out := vt * 0.55 - vn * e
	global_position = point - dir * (_tip + 0.02) + normal * 0.03
	var spin := dir.cross(normal) * minf(speed * 0.25 / maxf(_tip, 0.2), 8.0)
	_release(out, spin)


func _release(vel: Vector3, spin: Vector3) -> void:
	flying = false
	_host = null
	_wobble_t = -1.0
	collision_layer = 4
	collision_mask = 1
	freeze = false
	lock_rotation = false
	if physics_material_override == null:
		physics_material_override = PhysicsMaterial.new()
		physics_material_override.friction = 0.8
		physics_material_override.bounce = 0.15
		physics_material_override.rough = true
	angular_damp = 1.5
	linear_velocity = vel
	angular_velocity = spin
	_rest_t = 0.0
	set_physics_process(true)


func _settle(delta: float) -> void:
	# a long thin body spinning into a heightmap can slip under it: put it back on top
	var w := _world()
	if w:
		var g := w.ground_point(global_position.x, global_position.z)
		if global_position.y < g.y - 0.05:
			global_position.y = g.y + 0.06
			linear_velocity = Vector3(linear_velocity.x, absf(linear_velocity.y) * 0.2, linear_velocity.z)
	_rest_t = _rest_t + delta if linear_velocity.length() < 0.2 and angular_velocity.length() < 0.5 else 0.0
	if _rest_t > 1.0 or sleeping:
		set_physics_process(false)


func _world() -> ForestWorld:
	var n := get_parent()
	while n != null and not (n is ForestWorld):
		n = n.get_parent()
	return n as ForestWorld


func _is_dead_body(body: Node) -> bool:
	return body is Carcass or (body.has_method("is_dead") and body.is_dead())
