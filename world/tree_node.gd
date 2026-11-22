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
var species: StringName = &"spruce"
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
var _trunk_r := 0.3
var _holder: Node3D
var _stump_post: MeshInstance3D
var _stump_top: MeshInstance3D


# ---------------------------------------------------------------- build

func _build(s: float) -> void:
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
	_tree = AssetLib.instance(AssetLib.pick(AssetLib.TREES[species], node_id))
	_tree.scale = Vector3.ONE * s
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
	_notch.material_override = Graybox.tex("CutWood", Color(1.45, 1.32, 1.1), 6.0)
	_notch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_notch.visible = false
	add_child(_notch)
	_trunk_r = (0.26 if species != &"alder" else 0.22) * s * 1.18 + 0.035
	_apply_cut_height()
	_shape = Graybox.add_shape(self, Graybox.cyl_shape(0.36, height), Vector3(0, height * 0.5, 0))
	_log_shape = Graybox.add_shape(self, Graybox.cyl_shape(0.3, height - cut_h))
	_log_shape.disabled = true


func _apply_cut_height() -> void:
	_pivot.position.y = cut_h
	_holder.position.y = -cut_h
	var r := _trunk_r * 0.92
	_stump_post.scale = Vector3(r, cut_h, r)
	_stump_post.position.y = cut_h * 0.5
	_stump_top.scale = Vector3(r * 0.97, 0.012, r * 0.97)
	_stump_top.position.y = cut_h
	if _log_shape:
		(_log_shape.shape as CylinderShape3D).height = height - cut_h


func _refresh() -> void:
	if _pivot == null:
		return
	_pivot.visible = stage != Stage.CLEARED
	_stump.visible = stage in [Stage.FALLEN, Stage.CLEARED]
	_notch.visible = stage == Stage.STANDING and chop > 0
	if _notch.visible:
		_notch.mesh = _notch_mesh(float(chop) / float(fell_hits))
		var toward := -fall_dir
		_notch.basis = Basis(Vector3.UP, atan2(toward.x, toward.z))
		_notch.position = Vector3(0, cut_h, 0)
	match stage:
		Stage.STANDING:
			_pivot.basis = Basis()
			cut_h = cut_h if chop > 0 else DEFAULT_CUT
			_shape.disabled = false
			_shape.shape = Graybox.cyl_shape(0.36, height)
			_shape.position = Vector3(0, height * 0.5, 0)
			_log_shape.disabled = true
		Stage.FALLEN, Stage.CLEARED:
			_shape.shape = Graybox.cyl_shape(0.36, cut_h)
			_shape.position = Vector3(0, cut_h * 0.5, 0)
			_place_log_shape()
			_log_shape.disabled = stage != Stage.FALLEN
			if stage == Stage.FALLEN:
				_pivot.basis = Basis(_axis(), final_angle)


## Felling notch as a lens-shaped strip hugging the trunk surface on the chopper's side:
## pale fresh wood with a dark slit in the middle that widens as the cut deepens.
func _notch_mesh(progress: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_angle := lerpf(0.45, 1.15, progress)
	var h := lerpf(0.07, 0.2, progress)
	var segs := 12
	var r := _trunk_r
	for i in segs:
		for k in 3:
			var a0 := lerpf(-half_angle, half_angle, float(i) / segs)
			var a1 := lerpf(-half_angle, half_angle, float(i + 1) / segs)
			var p0 := _lens(a0, half_angle, h, r, k)
			var p1 := _lens(a1, half_angle, h, r, k)
			var q0 := _lens(a0, half_angle, h, r, k + 1)
			var q1 := _lens(a1, half_angle, h, r, k + 1)
			var dark := Color(0.16, 0.12, 0.09) if k == 1 else Color(1, 1, 1)
			for v: Vector3 in [p0, p1, q1, p0, q1, q0]:
				st.set_color(dark)
				st.set_normal(Vector3(v.x, 0, v.z).normalized())
				st.set_uv(Vector2(v.x * 3.0 + v.z * 3.0, v.y * 3.0))
				st.add_vertex(v)
	return st.commit()


## Point on the notch lens: rows 0..3 = top edge, slit top, slit bottom, bottom edge.
## Pale fresh wood on both cut faces, a thin dark slit where the wedge was removed.
func _lens(a: float, half_angle: float, h: float, r: float, row: int) -> Vector3:
	var w := sqrt(maxf(1.0 - pow(a / half_angle, 2.0), 0.0))
	var y: float = [h * 0.6 * w, h * 0.04 * w, -h * 0.1 * w, -h * 0.4 * w][row]
	var rr := r - (0.05 * w if row in [1, 2] else 0.0)
	return Vector3(sin(a) * rr, y, cos(a) * rr)


func _axis() -> Vector3:
	return Vector3.UP.cross(fall_dir).normalized()


func _place_log_shape() -> void:
	var b := Basis(_axis(), final_angle)
	_log_shape.transform = Transform3D(b, Vector3(0, cut_h, 0) + b * Vector3(0, (height - cut_h) * 0.5, 0))


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
			return Loc.t("STATUS_LOGS_LEFT", {"n": remaining})
	return ""


func get_interactions(player: Node) -> Array:
	if stage in [Stage.FALLING, Stage.CLEARED]:
		return []
	var hand: ItemStack = player.inventory.hand
	var ok := hand != null and hand.get_data().has_tag(&"tool_axe")
	var text := Loc.t("ACT_FELL" if stage == Stage.STANDING else "ACT_BUCK") if ok else Loc.t("NEED_TOOL_AXE")
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
		_chips(point, (p3.global_position - point).normalized())
		Sfx.play(&"axe_chop", point)
		if regrow_seconds > 0.0 and regrow_left <= 0.0:
			regrow_left = 0.0
		if chop >= fell_hits:
			_start_fall()
		_refresh()
		return true
	# FALLEN: buck into logs
	_chips(point, Vector3.UP)
	Sfx.play(&"axe_chop", point, -2.0)
	_give(player, cfg.get("hit_yield", {"wood": 1}))
	remaining -= 1
	if remaining <= 0:
		_clear()
	_refresh()
	return true


func _impact_point(player: Node) -> Vector3:
	var ray: RayCast3D = player.get("ray")
	if ray and ray.is_colliding():
		return ray.get_collision_point()
	return global_position + Vector3.UP * cut_h - fall_dir * 0.33


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
	if was_falling:
		_drop_branches()
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
		_refresh()


# ---------------------------------------------------------------- effects

func _chips(at: Vector3, toward: Vector3) -> void:
	for dark in [false, true]:
		var p := CPUParticles3D.new()
		p.one_shot = true
		p.explosiveness = 0.95
		p.amount = 6 if dark else 14
		p.lifetime = 1.1
		p.direction = (toward + Vector3.UP * 0.8).normalized()
		p.spread = 50.0
		p.initial_velocity_min = 2.5
		p.initial_velocity_max = 5.0
		p.gravity = Vector3(0, -9.8, 0)
		p.angular_velocity_min = -720.0
		p.angular_velocity_max = 720.0
		p.scale_amount_min = 0.4
		p.scale_amount_max = 1.1
		var shrink := Curve.new()
		shrink.add_point(Vector2(0, 1))
		shrink.add_point(Vector2(0.75, 1))
		shrink.add_point(Vector2(1, 0))
		p.scale_amount_curve = shrink
		p.mesh = Graybox.box(Vector3(0.018, 0.005, 0.032))
		p.material_override = Graybox.tex("Log", Color.WHITE, 8.0) if dark else Graybox.tex("CutWood", Color(1.2, 1.1, 0.95), 8.0)
		_one_shot(p, at)


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
		"g": regrow_left, "angle": final_angle, "cut": cut_h}


func load_state(d: Dictionary) -> void:
	var st := int(d.get("stage", 0))
	chop = int(d.get("chop", 0))
	var dir: Array = d.get("dir", [0, 1])
	fall_dir = Vector3(float(dir[0]), 0, float(dir[1])).normalized()
	final_angle = float(d.get("angle", deg_to_rad(86.0)))
	cut_h = float(d.get("cut", DEFAULT_CUT))
	_apply_cut_height()
	remaining = int(d.get("r", capacity))
	regrow_left = float(d.get("g", 0.0))
	stage = Stage.FALLEN if st == Stage.FALLING else st as Stage
	_refresh()
