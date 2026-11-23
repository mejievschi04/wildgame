class_name HumanNPC
extends CharacterBody3D
## Tribe member (GDD §7). Perception-based (sight with line of sight + FOV, hearing, seeing gestures),
## behaviour from faction temper × relation, a day in camp, and the animals around them:
##   day:    IDLE / SIT by the fire / PATROL / GATHER → WORK → DELIVER / SOCIAL / TEND a wounded kinsman /
##           HUNT (two armed members, once a day) / SLEEP by the fire at night (one keeps watch)
##   player: SUSPICIOUS → INVESTIGATE → WARN (territory) → COMBAT (armed) / FLEE (unarmed or hurt) → RECOVER
##           friendly: GREET (open-palm gesture). No shared language: offerings (E) and barter (R).
##   beasts: armed people fight predators that come close (together, from slots around it, spears thrown
##           first), everyone else runs to the fire; big cats and bears are only faced by three or more.
## Fighting: one or two attack at a time (TribeGroup tokens), the others hold their slot, circle and feint;
## spears are thrown from 6–15 m; a hit during the wind-up interrupts the attack; the group falls back when
## half of its fighters are badly hurt. Movement: paths through camp (NpcNav), the head turns before the
## body, turning on the spot steps the feet.

signal died(npc: HumanNPC)

enum State { IDLE, SIT, PATROL, GATHER, SUSPICIOUS, INVESTIGATE, WARN, COMBAT, FLEE, RECOVER, GREET, DEAD,
	SLEEP, WORK, DELIVER, SOCIAL, HUNT, TEND }
const WALK := 1.6
const RUN := 4.6
const SIDE_STEP := 1.0
const TURN := 4.0
const ACCEL := 3.6  # m/s² — a walk builds up over a step or two instead of snapping to speed
const DECEL := 5.5
const SIGHT := 34.0
const FOV := 210.0
const HEARING := 24.0
const ATTACK_MIN_RANGE := 1.25
const ATTACK_RANGE := 1.9
const ATTACK_WINDUP := 0.56  # contact frame in bake_human_combat.py
const ATTACK_COMMIT := 0.36
const ATTACK_COOLDOWN := 1.8
const THROW_MIN := 6.0
const THROW_MAX := 15.0
const THROW_RELEASE := 0.68  # THROW_FRAME 17 / 25 fps
const THROW_SPEED := 20.0
const SPEAR_TIP := 1.31  # model origin is the grip, with the tip along +Y
const DAMAGE := 18.0
const WARN_TIME := 6.0
const BEAST_SCAN := 0.5
const HUNT_OUT := Vector2(50.0, 85.0)  # how far from camp the hunting ground lies
const HUNT_TIME := 260.0
const BODY_STYLES := {
	"M1": ["SapiensM", Vector3(1.02, 0.94, 1.00), Color("c6915d"), Color("bbb098"), ["Feather"]],
	"M2": ["SapiensM", Vector3(1.12, 0.89, 1.07), Color("79674d"), Color("b2ad9e"), ["Feather", "Human_SapiensMBeard"]],
	"M3": ["SapiensM", Vector3(0.95, 0.98, 0.96), Color("a4734b"), Color("928278"), ["Feather", "Talisman", "Mantle", "Human_SapiensMMantleFur"]],
	"F1": ["SapiensF", Vector3(1.01, 1.00, 1.02), Color("ba925c"), Color("afa291"), ["Feather"]],
	"F2": ["SapiensF", Vector3(1.08, 0.96, 1.05), Color("7a694c"), Color("a99e8d"), ["Talisman"]],
	"NM1": ["NeanderthalM", Vector3(1.0, 1.0, 1.0), Color.WHITE, Color.WHITE, []],
	"NM2": ["NeanderthalM", Vector3(1.06, 0.97, 1.05), Color("8a7458"), Color("c9bba6"), ["Feather"]],
	"NM3": ["NeanderthalM", Vector3(0.97, 1.02, 0.98), Color("a88a68"), Color("9d8a74"), ["Talisman"]],
	"NF1": ["NeanderthalF", Vector3(1.0, 1.0, 1.0), Color.WHITE, Color.WHITE, []],
	"NF2": ["NeanderthalF", Vector3(1.04, 0.98, 1.03), Color("8f795c"), Color("b9aa95"), ["Feather"]],
}
## Day activities by temper: [state, weight].
const DAY_PLAN := {
	&"peaceful": [[State.GATHER, 5], [State.WORK, 2], [State.SOCIAL, 2], [State.SIT, 2]],
	&"wary": [[State.WORK, 3], [State.PATROL, 2], [State.SOCIAL, 2], [State.SIT, 3], [State.GATHER, 1]],
	&"territorial": [[State.PATROL, 4], [State.WORK, 2], [State.SOCIAL, 2], [State.SIT, 2]],
}
const GATHER_ITEMS := [&"berries", &"stick", &"fiber", &"mushroom"]

var npc_id := ""
var faction: StringName
var variant := "M1"
var factions: Factions
var world: ForestWorld
var group: TribeGroup
var health := 100.0
var max_health := 100.0
var armed := false
var spears := 0  # spare throwing spears (armed people carry one)
var territory_radius := -1.0  # use the faction default unless the guard has a local assignment
var warn_time := WARN_TIME
var state: State = State.IDLE
var state_time := 0.0
var awareness := 0.0
var last_known := Vector3.ZERO
var home := Vector3.ZERO
var post := Vector3.ZERO
var greeted_until := 0.0
var foe: Node3D = null  # what this person is fighting (the player or an animal)
var being_tended := false
var carrying: StringName = &""
## Hit-location health per body region; a cutting weapon severs a region that reaches 0.
var region_hp := {&"head": 45.0, &"torso": 999.0, &"arm_l": 35.0, &"arm_r": 35.0, &"leg_l": 45.0, &"leg_r": 45.0}
var severed: Array[StringName] = []
var bleeding := 0.0  # health lost per second
var _skel: Skeleton3D
var _severed_mod: SeveredBones
var _stagger_t := 0.0
var _guard_t := 0.0
var _react_t := 0.0
var _react_clip := ""
var _limp := 1.0
var _strafe_dir := 1.0

var _goal := Vector3.ZERO
var _travel := Vector3.ZERO
var _speed := 0.0
var _turning := false
var _detour := Vector3.ZERO
var _detour_t := 0.0
var _path := PackedVector3Array()
var _path_i := 0
var _path_goal := Vector3.INF
var _path_t := 0.0
var _face_meshes: Array[MeshInstance3D] = []   # meshes carrying the expr_* blend shapes (new hominin models)
var _hurt_face_t := 0.0
var _uptime := 0.0
var _think_t := 0.0
var _scan_t := 0.0
var _attack_cd := 0.0
var _attack_time := -1.0
var _attack_kind := &"thrust"
var _attack_target := Vector3.ZERO
var _avoid_until := 0.0
var _flee_from: Node3D = null
var _duration := 10.0
var _partner: HumanNPC = null
var _patient: HumanNPC = null
var _hunting := false
var _hunt_phase := &""
var _hunt_goal := Vector3.ZERO
var _hunt_t := 0.0
var _prey: Animal = null
var _thrown: Array = []  # ThrownSpear nodes still lying where they fell
var _model: Node3D
var _body_model: String
var _anim: AnimationPlayer
var _cur_anim := ""
var _spear: Node3D
var _spear_hand := -1
var _spear_axis := Vector3.ZERO
var _carry_node: Node3D
var _look: Marker3D
var _look_mods: Array[LookAtModifier3D] = []
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var rng := RandomNumberGenerator.new()


func setup(p_id: String, p_faction: StringName, p_variant: String, p_factions: Factions, p_world: ForestWorld,
		p_home: Vector3, p_post: Vector3, seed: int) -> void:
	npc_id = p_id
	faction = p_faction
	variant = p_variant
	factions = p_factions
	world = p_world
	home = p_home
	post = p_post
	position = p_post
	rng.seed = seed
	_strafe_dir = -1.0 if seed % 2 == 0 else 1.0
	armed = bool(factions.def_of(faction).get("armed", false))
	spears = 1 if armed else 0


func temper() -> StringName:
	return StringName(str(factions.def_of(faction).get("temper", "wary")))


func is_dead() -> bool:
	return state == State.DEAD


## Free for a camp job (not fighting, fleeing, hunting or asleep).
func is_idle_for_work() -> bool:
	return not is_dead() and state in [State.IDLE, State.SIT, State.PATROL, State.SOCIAL, State.WORK, State.GATHER]


func _ready() -> void:
	collision_layer = Animal.LAYER_CREATURE
	collision_mask = 1
	floor_snap_length = 0.5
	add_to_group("npc")
	add_to_group("interactable")
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.7
	cs.shape = cap
	cs.position.y = 0.85
	add_child(cs)
	var style: Array = BODY_STYLES.get(variant, [])
	_body_model = variant if style.is_empty() else style[0]
	_model = AssetLib.instance("res://assets/models/humans/SK_Human_%s.gltf" % _body_model)
	# The exported mesh already faces +Z, the same direction as the NPC body.
	add_child(_model)
	_tune_skin(_model)
	if not style.is_empty():
		_style_outfit(style)
	for mi: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh and mi.mesh.get_blend_shape_count() > 0:
			_face_meshes.append(mi)
	var players := _model.find_children("*", "AnimationPlayer", true, false)
	_anim = players[0] if not players.is_empty() else null
	if _anim:
		for n in ["idle", "walk", "run", "alert", "sit"]:
			if _anim.has_animation(n):
				_anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
		_center_mocap()
		for kind in ["combat", "life"]:
			var lib_path := "res://assets/models/humans/AN_%s_%s.tres" % [_body_model, kind]
			if ResourceLoader.exists(lib_path):
				_anim.add_animation_library(StringName(kind), load(lib_path))
	var skels := _model.find_children("*", "Skeleton3D", true, false)
	_skel = skels[0] if not skels.is_empty() else null
	if _skel:
		_add_look_at()
		_severed_mod = SeveredBones.new()
		_skel.add_child(_severed_mod)
		_add_spring_bones()
	if armed:
		_attach_spear()
	process_priority = 1  # place the spear after AnimationPlayer has posed the hand
	_set_state(State.SIT if rng.randf() < 0.5 else State.IDLE)


func _style_outfit(style: Array) -> void:
	_model.scale = style[1]
	var hide_tint: Color = style[2]
	var fur_tint: Color = style[3]
	var removed: Array = style[4]
	for mesh: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
		var mesh_name := String(mesh.name)
		var gone := mesh_name.get_slice(".", 0).get_slice("_", 0) in removed or mesh_name in removed
		for r: String in removed:
			gone = gone or ("_" in r and mesh_name.begins_with(r))  # "…Beard" also hides the beard cap
		if gone:
			mesh.hide()
			continue
		for i in mesh.mesh.get_surface_count():
			var source := mesh.get_active_material(i) as BaseMaterial3D
			if source == null:
				continue
			var material_name := String(source.resource_name)
			var tint := Color.WHITE
			if material_name in ["M_Hide", "M_Strap", "M_StrapAcc", "M_Pouch"]:
				tint = hide_tint
			elif material_name == "M_FurBase" or "MantleFur" in material_name or "BootsFur" in material_name:
				tint = fur_tint
			if tint != Color.WHITE:
				var material := source.duplicate() as BaseMaterial3D
				material.albedo_color *= tint
				mesh.set_surface_override_material(i, material)


func _center_mocap() -> void:
	# Existing Sapiens assets were exported with the recording's starting position baked in.
	for name in [&"walk", &"run"]:
		if not _anim.has_animation(name):
			continue
		var clip := _anim.get_animation(name)
		var track := clip.find_track(NodePath("Human_rig/Skeleton3D:Root"), Animation.TYPE_POSITION_3D)
		if track < 0 or clip.track_get_key_count(track) == 0:
			continue
		var start: Vector3 = clip.track_get_key_value(track, 0)
		if Vector2(start.x, start.z).length() < 0.5:
			continue
		var offset := Vector3(start.x, 0.0, start.z)
		for i in clip.track_get_key_count(track):
			var key: Vector3 = clip.track_get_key_value(track, i)
			clip.track_set_key_value(track, i, key - offset)


static func _tune_skin(root: Node) -> void:
	Animal._fix_materials(root)  # hair / beard / fur trims are alpha-tested strand cards
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			if m is BaseMaterial3D and String(m.resource_name).ends_with("_Skin"):
				var d := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
				d.subsurf_scatter_enabled = true
				d.subsurf_scatter_strength = 0.35
				d.metallic_specular = 0.28
				mi.set_surface_override_material(s, d)
			elif m is BaseMaterial3D and String(m.resource_name).ends_with("_Eye"):
				var d := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
				d.albedo_color *= Color("d0c2b3")
				d.roughness = 0.38
				d.metallic_specular = 0.25
				mi.set_surface_override_material(s, d)


## Head and neck turn toward what the person attends to before the body follows (LookAtModifier3D).
func _add_look_at() -> void:
	_look = Marker3D.new()
	_look.name = "LookTarget"
	_look.top_level = true
	add_child(_look)
	_look.global_position = global_position + global_transform.basis.z * 4.0 + Vector3.UP * 1.6
	var model_fwd := Vector3(0, 0, 1)  # the rig faces +Z in model space
	# [bone, influence, duration, yaw range, pitch range] — together about ±80° of head turn, like a real neck
	for spec: Array in [["neck_01", 0.45, 0.6, 90.0, 50.0], ["head", 0.8, 0.35, 110.0, 60.0]]:
		var bone := _skel.find_bone(spec[0])
		if bone < 0:
			continue
		var rest := _skel.get_bone_global_rest(bone).basis
		var mod := LookAtModifier3D.new()
		mod.name = "Look_%s" % spec[0]
		mod.bone_name = spec[0]
		mod.forward_axis = _closest_axis(rest, model_fwd) as SkeletonModifier3D.BoneAxis
		mod.primary_rotation_axis = (_closest_axis(rest, Vector3.UP) / 2) as Vector3.Axis
		mod.use_angle_limitation = true
		mod.symmetry_limitation = true
		mod.primary_limit_angle = deg_to_rad(spec[3])
		mod.primary_damp_threshold = 0.7
		mod.use_secondary_rotation = true
		mod.secondary_limit_angle = deg_to_rad(spec[4])
		mod.secondary_damp_threshold = 0.6
		mod.duration = spec[2]
		mod.transition_type = Tween.TRANS_SINE
		mod.ease_type = Tween.EASE_IN_OUT
		mod.influence = spec[1]
		_skel.add_child(mod)
		mod.target_node = mod.get_path_to(_look)
		_look_mods.append(mod)


## The bone-local axis (as a SkeletonModifier3D.BoneAxis: +X, −X, +Y, −Y, +Z, −Z) closest to `dir`.
static func _closest_axis(basis: Basis, dir: Vector3) -> int:
	var best := 0
	var best_dot := -INF
	for i in 3:
		var axis := Vector3.ZERO
		axis[i] = 1.0
		var d := (basis * axis).normalized().dot(dir)
		if d > best_dot:
			best_dot = d
			best = i * 2
		if -d > best_dot:
			best_dot = -d
			best = i * 2 + 1
	return best


## Secondary motion: strip skirt and long hair swing on their bone chains (hominin models only).
func _add_spring_bones() -> void:
	var chains: Array = []  # [root, end, stiffness, drag, gravity, radius]
	for k in 8:
		if _skel.find_bone("skirt_%d_1" % k) >= 0:
			chains.append(["skirt_%d_1" % k, "skirt_%d_2" % k, 2.4, 0.5, 0.4, 0.025])
	for k in 3:
		if _skel.find_bone("hair_%d_1" % k) >= 0:
			chains.append(["hair_%d_1" % k, "hair_%d_2" % k, 1.0, 0.55, 0.9, 0.03])
	if chains.is_empty():
		return
	var sim := SpringBoneSimulator3D.new()
	sim.name = "SpringBones"
	_skel.add_child(sim)
	sim.setting_count = chains.size()
	for i in chains.size():
		var c: Array = chains[i]
		var root := _skel.find_bone(c[0])
		var end := _skel.find_bone(c[1])
		sim.set_root_bone_name(i, c[0])
		sim.set_end_bone_name(i, c[1])
		sim.set_extend_end_bone(i, true)
		sim.set_end_bone_length(i, _skel.get_bone_rest(end).origin.length() if end >= 0 else 0.15)
		sim.set_stiffness(i, c[2])
		sim.set_drag(i, c[3])
		sim.set_gravity(i, c[4])
		sim.set_radius(i, c[5])
		sim.set_enable_all_child_collisions(i, true)
		if root < 0:
			push_warning("spring chain without bones: %s" % c[0])
	for b: Array in [["thigh_l", 0.085, 0.45], ["thigh_r", 0.085, 0.45], ["spine_03", 0.13, 0.32]]:
		if _skel.find_bone(b[0]) < 0:
			continue
		var cap := SpringBoneCollisionCapsule3D.new()
		cap.bone_name = b[0]
		cap.radius = b[1]
		cap.height = b[2]
		cap.position_offset = Vector3(0, b[2] * 0.45, 0)  # capsule axis runs along the bone
		sim.add_child(cap)


func _attach_spear() -> void:
	if _skel == null:
		return
	_spear_hand = _skel.find_bone("hand_r")
	if _spear_hand < 0:
		return
	_spear = AssetLib.instance(AssetLib.item_model_path(&"spear"))
	_spear.name = "SpearHold"
	add_child(_spear)


func _process(delta: float) -> void:
	if is_instance_valid(_spear):
		_pose_spear(delta)
	if is_instance_valid(_carry_node) and _skel:
		var hand := _skel.find_bone("hand_l")
		if hand >= 0:
			var xf := _skel.global_transform * _skel.get_bone_global_pose(hand)
			_carry_node.global_position = xf.origin + xf.basis.y.normalized() * 0.09
	_update_look(delta)


func _pose_spear(delta: float, immediate := false) -> void:
	var hand := _skel.global_transform * _skel.get_bone_global_pose(_spear_hand)
	var forward := global_transform.basis.z
	var side := global_transform.basis.x
	var axis := (Vector3.UP * 0.92 + forward * 0.35 - side * 0.16).normalized()
	if _attack_time >= 0.0 and _attack_kind == &"throw":
		var to_t := _attack_target - hand.origin
		axis = (to_t.normalized() + Vector3.UP * 0.12).normalized()
	elif _attack_time >= 0.0 or _cur_anim.begins_with("combat/"):
		var pitch := 0.10
		if _attack_time >= 0.0:
			var to_chest := _attack_target - hand.origin
			pitch = clampf(to_chest.y / maxf(0.7, Vector2(to_chest.x, to_chest.z).length()), -0.42, 0.42)
		axis = (forward + Vector3.UP * pitch).normalized()
	elif is_dead():
		axis = (-forward + Vector3.UP * 0.02).normalized()
	elif state == State.SLEEP:
		axis = (forward + side * 0.3).normalized()
	if immediate or _spear_axis == Vector3.ZERO:
		_spear_axis = axis
	else:
		_spear_axis = _spear_axis.lerp(axis, 1.0 - exp(-delta * 12.0)).normalized()
	var across := _spear_axis.cross(forward if absf(_spear_axis.dot(forward)) < 0.8 else side).normalized()
	var grip := hand.origin + hand.basis.y.normalized() * 0.055
	if state == State.SLEEP and _speed < 0.2:
		grip = global_position + side * 0.55 + Vector3.UP * 0.05  # laid down beside the sleeper
	_spear.global_transform = Transform3D(Basis(across, _spear_axis, across.cross(_spear_axis)), grip)


## What the eyes follow: the foe, the stranger, the partner, the next step of the path.
func _look_point() -> Vector3:
	var eye := Vector3.UP * 1.55
	if foe and is_instance_valid(foe) and state in [State.COMBAT, State.FLEE]:
		return foe.global_position + Vector3.UP * (1.3 if foe is Animal else 1.55)
	var p := _player()
	if p and awareness > 0.3 and state in [State.SUSPICIOUS, State.INVESTIGATE, State.WARN, State.GREET]:
		return p.global_position + eye
	if state == State.SOCIAL and is_instance_valid(_partner):
		return _partner.global_position + eye
	if state == State.TEND and is_instance_valid(_patient):
		return _patient.global_position + Vector3.UP * 0.6
	if state == State.SIT:
		return home + Vector3.UP * 0.3
	if _speed > 0.3 and _path_i < _path.size():
		return _path[_path_i] + eye
	return global_position + global_transform.basis.z * 4.0 + eye


func _update_look(delta: float) -> void:
	if _look_mods.is_empty():
		return
	var off := is_dead() or state in [State.SLEEP, State.WORK] or (_attack_time >= 0.0) or _react_t > 0.0 \
		or (state == State.HUNT and _hunt_phase == &"butcher")
	for i in _look_mods.size():
		var want := 0.0 if off else (0.45 if i == 0 else 0.8)
		_look_mods[i].influence = move_toward(_look_mods[i].influence, want, delta * 3.0)
	var want_at := _look_point()
	var to_t := want_at - global_position
	to_t.y = 0.0
	var fwd := global_transform.basis.z
	if to_t.length() > 0.3 and fwd.dot(to_t.normalized()) < -0.2:
		want_at = global_position + fwd * 4.0 + Vector3.UP * 1.55  # behind: the body turns first, not the neck
	_look.global_position = _look.global_position.lerp(want_at, 1.0 - exp(-delta * 6.0))


# ---------------------------------------------------------------- perception

func _player() -> Node3D:
	return world.player as Node3D if world else null


func _sees(p: Node3D) -> float:
	var to_p := p.global_position - global_position
	var d := to_p.length()
	var vis: float = p.visibility_factor() if p.has_method("visibility_factor") else 1.0
	if state == State.SLEEP:
		vis *= 0.0  # eyes closed: only noise wakes a sleeper
	var range := SIGHT * vis
	var s := 0.0
	if d < range:
		var fwd := global_transform.basis.z  # model faces +Z
		var flat := Vector3(to_p.x, 0, to_p.z).normalized()
		if rad_to_deg(Vector3(fwd.x, 0, fwd.z).normalized().angle_to(flat)) <= FOV * 0.5 and _los(p.global_position + Vector3.UP * 1.3):
			s = 1.0 - d / range
	var noise: float = p.noise_level() if p.has_method("noise_level") else 0.3
	var hearing := HEARING * (0.45 if state == State.SLEEP else 1.0)
	if d < hearing * noise:
		s = maxf(s, 0.8 * (1.0 - d / (hearing * noise)))
	return s


func _los(target: Vector3) -> bool:
	if not is_inside_tree():
		return true
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 1.6, target, 1)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## The nearest animal that endangers this person or their kin (predators close by or hunting one of us,
## defensive beasts that are charging).
func _beast_threat() -> Animal:
	var best: Animal = null
	var best_d := 32.0
	for a: Animal in get_tree().get_nodes_in_group("animal"):
		if a.is_dead():
			continue
		var d := a.global_position.distance_to(global_position)
		if d >= best_d:
			continue
		var on_us: bool = a.threat == self or (a.threat is HumanNPC and (a.threat as HumanNPC).faction == faction)
		var charging := a.state in [Animal.State.CHASE, Animal.State.ATTACK]
		var danger := false
		if a.is_predator():
			danger = on_us or d < (14.0 if state != State.SLEEP else 6.0)
		elif a.is_defensive():
			danger = charging and (on_us or d < 10.0)
		if danger and (d < 8.0 or on_us or _los(a.global_position + Vector3.UP)):
			best = a
			best_d = d
	return best


## Nearest living prey animal in view (for hunters).
func _find_prey(radius: float) -> Animal:
	var best: Animal = null
	var best_d := radius
	for a: Animal in get_tree().get_nodes_in_group("animal"):
		if a.is_dead() or not a.is_prey() or a.max_health > 160.0:
			continue
		var d := a.global_position.distance_to(global_position)
		if d < best_d and _los(a.global_position + Vector3.UP * 0.8):
			best = a
			best_d = d
	return best


# ---------------------------------------------------------------- interaction (offerings & barter)

func get_display_name() -> String:
	return Loc.t("NPC_%s" % String(faction).to_upper())


func get_status_text() -> String:
	if is_dead():
		return Loc.t("NPC_DEAD")
	if state == State.SLEEP:
		return Loc.t("NPC_ASLEEP")
	return Loc.t("STANCE_%s" % String(factions.stance(faction)).to_upper())


func _best_offering(inv: Inventory) -> StringName:
	var best: StringName = &""
	var best_v := 0
	for s: ItemStack in inv.slots:
		if s == null:
			continue
		var v := factions.want_value(faction, s.id)
		if v > best_v:
			best_v = v
			best = s.id
	return best


func _gift() -> StringName:
	var gives: Dictionary = factions.def_of(faction).get("gives", {})
	var keys := gives.keys()
	return StringName(str(keys[rng.randi() % keys.size()])) if not keys.is_empty() else &""


func get_interactions(player: Node) -> Array:
	if is_dead() or state in [State.COMBAT, State.FLEE, State.SLEEP, State.HUNT] or factions.stance(faction) == &"hostile":
		return []
	var inv: Inventory = player.inventory
	var offer := _best_offering(inv)
	var opts: Array = []
	if offer != &"":
		var name := ItemDB.get_item(offer).display_name()
		opts.append({"action": &"interact", "text": Loc.t("ACT_OFFER", {"item": name}), "hold": 0.8, "enabled": true})
		if factions.relation(faction) >= Factions.WARY:
			opts.append({"action": &"alt_interact", "text": Loc.t("ACT_BARTER", {"item": name}), "hold": 0.8, "enabled": true})
	else:
		opts.append({"action": &"interact", "text": Loc.t("ACT_NOTHING_TO_OFFER"), "hold": 0.0, "enabled": false})
	return opts


func perform_interaction(player: Node, action: StringName) -> void:
	var inv: Inventory = player.inventory
	var offer := _best_offering(inv)
	if offer == &"" or not inv.remove_item(offer, 1):
		return
	var value := factions.want_value(faction, offer)
	match action:
		&"interact":
			factions.change(faction, float(value), &"offering")
			_caption("CAPTION_THANKS")
		&"alt_interact":
			var gift := _gift()
			if gift != &"":
				player.give_item(gift, 1)
			factions.change(faction, 1.0, &"barter")
			_caption("CAPTION_BARTER")
	factions.meet(faction)
	_face(player.global_position)
	_set_state(State.GREET)


func _caption(key: String) -> void:
	if bool(Settings.get_value("accessibility", "subtitles")):
		Sfx.caption.emit(Loc.t(key))


# ---------------------------------------------------------------- damage

func is_guarding() -> bool:
	return _guard_t > 0.0


func is_staggered() -> bool:
	return _stagger_t > 0.0


## Damage with hit location. weapon = the item that hit (cutting weapons can sever); heavy = charged blow.
func take_damage(amount: float, source: Node3D = null, hit_pos: Vector3 = Vector3.INF,
		weapon: ItemData = null, heavy: bool = false) -> void:
	_hurt_face_t = 1.4
	var region: StringName = BodyRegions.region_at(_skel, hit_pos) if hit_pos != Vector3.INF else &"torso"
	if region in severed:
		region = &"torso"
	var cutting := weapon != null and weapon.has_tag(&"tool_axe")
	var at := hit_pos if hit_pos != Vector3.INF else global_position + Vector3.UP * 1.2
	if is_dead():
		# Corpses can still be dismembered with a cutting weapon.
		if cutting and region != &"torso":
			region_hp[region] = float(region_hp[region]) - amount
			Gore.burst(world, at, Vector3.UP, 10)
			if float(region_hp[region]) <= 0.0 and Gore.enabled():
				sever(region, source)
		return
	var dmg := amount * float(BodyRegions.MULT.get(region, 1.0))
	if _guard_t > 0.0 and source and region != &"leg_l" and region != &"leg_r":
		var to_src := (source.global_position - global_position).normalized()
		if global_transform.basis.z.dot(to_src) > 0.3:
			dmg *= 0.35  # blocked with the spear shaft
			Sfx.play(&"stone_knock", at, -4.0)
			if heavy:
				stagger(0.8)
	health -= dmg
	region_hp[region] = float(region_hp[region]) - dmg
	Gore.burst(world, at, (at - (source.global_position if source else at + Vector3.FORWARD)).normalized(), 18 if heavy else 12)
	if randf() < 0.35:
		Gore.decal(world, Vector3(at.x, global_position.y, at.z), 0.4)
	if heavy:
		stagger(0.6)
	elif _attack_time >= 0.0 and _attack_time < ATTACK_COMMIT:
		_cancel_attack()  # a blow during the wind-up spoils the attack
	_hit_reaction(source, at)
	var by_player := source != null and source.is_in_group("player")
	if by_player:
		factions.change(faction, -40.0, &"attacked")
		_rally(source)
	_wound_effects(region)
	if cutting and region != &"torso" and float(region_hp[region]) <= 0.0 and Gore.enabled():
		sever(region, source)
		if is_dead():
			return
	if health <= 0.0:
		die(by_player)
		return
	if state == State.SLEEP:
		awareness = 1.0
	if health < max_health * 0.4 or not armed:
		_avoid_until = _uptime + 90.0
		_flee(source)
	elif source is Animal:
		_engage(source)
		_call_kin(source as Animal)
	elif by_player and state != State.COMBAT:
		_engage(source)


func _hit_reaction(source: Node3D, at: Vector3) -> void:
	if _anim == null or not _anim.has_animation(&"combat/hit_l") or _attack_time >= 0.0:
		return
	var from := source.global_position if source else at
	var side := (from - global_position).dot(global_transform.basis.x)
	_react_clip = "combat/hit_l" if side > 0.0 else "combat/hit_r"
	_react_t = 0.5
	_cur_anim = ""


func _wound_effects(region: StringName) -> void:
	if region in [&"leg_l", &"leg_r"] and float(region_hp[region]) < 22.0:
		_limp = 0.55
	if region == &"arm_r" and float(region_hp[region]) < 15.0 and armed:
		_drop_weapon()


func stagger(seconds: float) -> void:
	_stagger_t = maxf(_stagger_t, seconds)
	_cancel_attack()
	if _model:
		var tw := create_tween()
		tw.tween_property(_model, "position", Vector3(0, -0.05, -0.15), 0.08)
		tw.tween_property(_model, "position", Vector3.ZERO, 0.35)


func _drop_weapon() -> void:
	armed = false
	_cancel_attack()
	if is_instance_valid(_spear):
		_spear.hide()
		_spear.queue_free()
		_spear = null
	if world:
		world.spawn_pickup(ItemStack.new(&"spear", 1, 40), global_position + Vector3.UP * 1.0 + global_transform.basis.z * 0.5)


## Cuts a body region off: hides it on the skinned mesh, caps the stump, throws the part away.
func sever(region: StringName, source: Node3D = null) -> void:
	if region in severed or region == &"torso" or _skel == null:
		return
	severed.append(region)
	var bone: String = BodyRegions.SEVER_BONE[region]
	var bi := _skel.find_bone(bone)
	if bi < 0:
		return
	var parent := _skel.get_bone_parent(bi)
	var part_xf := _skel.global_transform * _skel.get_bone_global_pose(bi) * _skel.get_bone_global_rest(bi).affine_inverse()
	_severed_mod.hidden.append(bone)
	Gore.stump(_skel, _skel.get_bone_name(parent), _skel.get_bone_rest(bi).origin, 0.06 if region != &"head" else 0.07)
	var push := Vector3.UP * 2.0
	if source:
		push += (global_position - source.global_position).normalized() * 3.0
	if world:
		Gore.spawn_part(world, "res://assets/models/humans/parts/SM_Part_%s_%s.gltf" % [_body_model, region], part_xf, push)
		Gore.decal(world, global_position, 1.1)
	Sfx.play(&"axe_chop", _skel.global_transform * _skel.get_bone_global_pose(bi).origin, 2.0)
	if region == &"arm_r" and armed:
		_drop_weapon()
	if is_dead():
		return
	match region:
		&"head":
			die(source != null and source.is_in_group("player"))
		&"leg_l", &"leg_r":
			health = minf(health, 8.0)
			bleeding = 6.0
			die(source != null and source.is_in_group("player"))
		_:
			bleeding = 3.0
			_avoid_until = _uptime + 300.0
			_flee(source)


func _rally(source: Node3D) -> void:
	for n: HumanNPC in get_tree().get_nodes_in_group("npc"):
		if n.faction == faction and not n.is_dead() and n.global_position.distance_to(global_position) < 40.0:
			n.awareness = 1.0
			n.last_known = source.global_position
			if n != self:
				if n.armed:
					n._engage(source)
				else:
					n._flee(source)


## Kin within 25 m join against a beast; those who can't fight run to the fire.
func _call_kin(beast: Animal) -> void:
	if group == null:
		return
	var big := beast.max_health >= 200.0
	var fighters := 0
	for m: HumanNPC in group.living():
		if m.armed and m.global_position.distance_to(global_position) < 25.0:
			fighters += 1
	for m: HumanNPC in group.living():
		if m == self or m.global_position.distance_to(global_position) > 25.0 or m.state in [State.COMBAT, State.FLEE]:
			continue
		if m.armed and (not big or fighters >= 3):
			m._engage(beast)
		else:
			m._flee(beast)


func die(by_player: bool) -> void:
	_cancel_attack()
	_drop_carry()
	if group:
		group.release_attack(self)
		group.end_hunt(self)
	state = State.DEAD
	health = 0.0
	velocity = Vector3.ZERO
	remove_from_group("interactable")
	add_to_group("corpse")
	# Corpse stays hittable (dismemberment) but no longer blocks movement.
	collision_layer = 4
	for c in get_children():
		if c is CollisionShape3D:
			c.rotation_degrees = Vector3(90, 0, 0)
			c.position = Vector3(0, 0.25, -0.6)
	if by_player:
		factions.change(faction, -60.0, &"killed")
	_play("death", false)
	died.emit(self)


# ---------------------------------------------------------------- face

## Expression that fits the current state (concept sheet: focused, angry, surprised, pain, happy).
func wanted_expression() -> StringName:
	if is_dead() or _hurt_face_t > 0.0:
		return &"pain"
	match state:
		State.WARN, State.COMBAT:
			return &"angry"
		State.FLEE:
			return &"surprised"
		State.SUSPICIOUS, State.INVESTIGATE, State.WORK, State.TEND:
			return &"focused"
		State.HUNT:
			return &"focused" if _hunt_phase in [&"stalk", &"search"] else &""
		State.GREET:
			return &"happy"
		State.SOCIAL:
			return &"happy" if fmod(state_time, 9.0) < 2.5 else &""
	return &""


func expression_weight(expr: StringName) -> float:
	for mi in _face_meshes:
		var i := mi.find_blend_shape_by_name("expr_" + String(expr))
		if i >= 0:
			return mi.get_blend_shape_value(i)
	return 0.0


func _update_face(delta: float) -> void:
	if _face_meshes.is_empty():
		return
	_hurt_face_t = maxf(_hurt_face_t - delta, 0.0)
	var want := "expr_" + String(wanted_expression())
	var rate := delta * (6.0 if want == "expr_pain" else 3.0)
	for mi in _face_meshes:
		for i in mi.mesh.get_blend_shape_count():
			var n := String(mi.mesh.get_blend_shape_name(i))
			if n.begins_with("expr_"):
				var target := 0.6 if (n == want and is_dead()) else (1.0 if n == want else 0.0)
				mi.set_blend_shape_value(i, move_toward(mi.get_blend_shape_value(i), target, rate))


# ---------------------------------------------------------------- brain

func _set_state(s: State) -> void:
	if state == State.COMBAT and s != State.COMBAT and group:
		group.release_attack(self)
	if state == State.TEND and s != State.TEND and is_instance_valid(_patient):
		_patient.being_tended = false
	state = s
	state_time = 0.0
	_path_goal = Vector3.INF
	_duration = rng.randf_range(12.0, 30.0)
	match s:
		State.PATROL:
			if armed and group and not group.guards:
				var a := rng.randf() * TAU  # walk the camp's edge
				_goal = home + Vector3(cos(a), 0, sin(a)) * rng.randf_range(8.0, 13.0)
			else:
				var a := rng.randf() * TAU
				_goal = home + Vector3(cos(a), 0, sin(a)) * rng.randf_range(4.0, 14.0)
		State.GATHER:
			_goal = _forage_spot()
		State.IDLE, State.SIT, State.RECOVER:
			_goal = post
		State.SLEEP:
			_goal = group.bed_for(self) if group else post
			_drop_carry()
		State.WORK:
			_duration = rng.randf_range(8.0, 16.0)
			if _goal.distance_to(global_position) > 2.0 or carrying == &"":
				# Tending the fire / mending at the store when there is nothing to pick here.
				var at := home if rng.randf() < 0.5 or group == null else group.storage
				_goal = at + (global_position - at).normalized() * 1.3
		State.DELIVER:
			var store := group.storage if group else home
			_goal = store + (global_position - store).normalized() * 0.5
		State.SOCIAL:
			_duration = rng.randf_range(14.0, 28.0)
		State.TEND:
			_duration = 8.0
		State.COMBAT:
			if foe == null or not is_instance_valid(foe):
				foe = _player()


## Fight `target` (the player or an animal).
func _engage(target: Node3D) -> void:
	if target == null or is_dead():
		return
	foe = target
	last_known = target.global_position
	awareness = maxf(awareness, 1.0 if target.is_in_group("player") else awareness)
	if state != State.COMBAT:
		_set_state(State.COMBAT)


## Run from `threat`: toward the fire when that does not mean running at it, otherwise straight away.
func _flee(threat: Node3D) -> void:
	_flee_from = threat
	if threat is Animal:
		foe = threat
	if state != State.FLEE:
		_set_state(State.FLEE)


func _physics_process(delta: float) -> void:
	_uptime += delta
	_update_face(delta)
	if not is_on_floor():
		velocity.y -= _gravity * delta
	if is_dead():
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return
	state_time += delta
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	_stagger_t = maxf(_stagger_t - delta, 0.0)
	_guard_t = maxf(_guard_t - delta, 0.0)
	_react_t = maxf(_react_t - delta, 0.0)
	if bleeding > 0.0:
		health -= bleeding * delta
		if randf() < delta * 1.5:
			Gore.decal(world, global_position, 0.25)
		if health <= 0.0:
			die(true)
			return
	if state == State.COMBAT and armed and _attack_time < 0.0 and _guard_t <= 0.0 and _stagger_t <= 0.0:
		var pl := _player()
		if pl and foe == pl and pl.has_method("is_winding_up") and pl.is_winding_up() \
				and pl.global_position.distance_to(global_position) < 3.2 and rng.randf() < delta * 2.5:
			_guard_t = 0.8
	_think_t -= delta
	if _think_t <= 0.0:
		_think_t = 0.12
		_think(0.12)
	_update_attack(delta)
	_move(delta)
	_animate()


func _inside_territory(pos: Vector3) -> bool:
	var r := territory_radius if territory_radius >= 0.0 else float(factions.def_of(faction).get("territory", 0))
	return r > 0.0 and Vector2(pos.x - home.x, pos.z - home.z).length() < r


func _think(dt: float) -> void:
	var p := _player()
	if p == null:
		return
	_scan_t -= dt
	if _scan_t <= 0.0:
		_scan_t = BEAST_SCAN
		if _think_beasts():
			return
	var stim := _sees(p) if p.get("dead") != true else 0.0
	if stim > 0.0:
		awareness = minf(awareness + stim * dt * 3.0, 1.0)
		last_known = p.global_position
	else:
		awareness = maxf(awareness - 0.1 * dt, 0.0)
	var d := p.global_position.distance_to(global_position)
	if awareness > 0.3 and d < 30.0:
		factions.meet(faction)
	if stim > 0.2 and p.has_method("is_gesturing") and p.is_gesturing() and d < 25.0:
		if factions.gesture_seen(faction):
			_caption("CAPTION_GESTURE_BACK")
		if state in [State.WARN, State.SUSPICIOUS]:
			_set_state(State.GREET)
	var stance := factions.stance(faction)
	match state:
		State.COMBAT:
			_think_combat(p)
			return
		State.FLEE:
			var gone := _flee_from == null or not is_instance_valid(_flee_from) \
				or (_flee_from is Animal and (_flee_from as Animal).is_dead()) \
				or _flee_from.global_position.distance_to(global_position) > 30.0
			if state_time > 14.0 or (gone and state_time > 4.0):
				_set_state(State.RECOVER)
			return
		State.GREET:
			if state_time > 2.5:
				_set_state(State.IDLE)
			return
		State.RECOVER:
			if state_time > 8.0:
				_set_state(State.IDLE)
			return
	if state == State.SLEEP and awareness < 0.55:
		_routine()
		return
	if awareness < 0.3:
		_routine()
		return
	if state == State.SLEEP:
		_set_state(State.IDLE)  # woken by the stranger
	# The player is noticed.
	match temper():
		&"peaceful":
			if stance == &"hostile" or (d < 12.0 and _uptime < _avoid_until):
				_flee(p)
			elif d < 9.0 and _uptime > greeted_until:
				greeted_until = _uptime + 40.0
				_set_state(State.GREET)
			else:
				_watch()
		&"wary":
			if stance == &"hostile" and armed and d < 22.0:
				_engage(p)
			elif stance == &"wary" and d < 7.0:
				_set_state(State.WARN)
			elif stance in [&"neutral", &"friendly"] and d < 8.0 and _uptime > greeted_until:
				greeted_until = _uptime + 40.0
				_set_state(State.GREET)
			else:
				_watch()
		&"territorial":
			var inside := _inside_territory(p.global_position)
			if stance == &"hostile" and armed and d < 30.0:
				_engage(p)
			elif stance == &"friendly":
				if d < 8.0 and _uptime > greeted_until:
					greeted_until = _uptime + 40.0
					_set_state(State.GREET)
				else:
					_watch()
			elif inside:
				if state != State.WARN:
					_set_state(State.WARN)
					_caption("CAPTION_WARNING")
				elif state_time > warn_time and d < 16.0:
					factions.change(faction, -12.0, &"trespass")
					if armed:
						_engage(p)
			else:
				_watch()


## Animals near the person. Returns true when it took over this think step.
func _think_beasts() -> bool:
	if state in [State.COMBAT, State.FLEE] or not world or not world.wildlife:
		return false
	var beast := _beast_threat()
	if beast == null:
		return false
	if state == State.SLEEP:
		awareness = 1.0
	var big := beast.max_health >= 200.0
	var fighters := 0
	if group:
		for m: HumanNPC in group.living():
			if m.armed and m.global_position.distance_to(global_position) < 22.0:
				fighters += 1
	elif armed:
		fighters = 1
	if armed and beast.is_predator() and (not big or fighters >= 3):
		_engage(beast)
	else:
		_flee(beast)
	_call_kin(beast)
	return true


func _think_combat(p: Node3D) -> void:
	if foe == null or not is_instance_valid(foe):
		_end_fight()
		return
	var d := foe.global_position.distance_to(global_position)
	if foe is Animal:
		var beast := foe as Animal
		if beast.is_dead():
			if _hunting and beast == _prey:
				_hunt_phase = &"butcher"
			_end_fight()
		elif state_time > 30.0 or d > (40.0 if _hunting else 26.0) or beast.state == Animal.State.FLEE and d > 18.0:
			_end_fight()
		elif group and group.should_retreat(foe):
			_flee(foe)
		return
	var give_up: bool = state_time > 25.0 or d > 35.0 or p.get("dead") == true
	if temper() == &"territorial" and not _inside_territory(p.global_position) and state_time > 4.0:
		give_up = true
	if give_up:
		_end_fight()
	elif group and group.should_retreat(foe) and health < max_health * 0.6:
		_avoid_until = _uptime + 60.0
		_flee(foe)


func _end_fight() -> void:
	_cancel_attack()
	if _hunting:
		_set_state(State.HUNT)
		if _hunt_phase in [&"stalk", &"chase", &""]:
			_hunt_phase = &"retrieve"
		return
	_set_state(State.RECOVER)


func _watch() -> void:
	if state in [State.IDLE, State.SIT, State.PATROL, State.GATHER, State.WORK, State.SOCIAL, State.DELIVER]:
		_set_state(State.SUSPICIOUS)
	elif state == State.SUSPICIOUS and awareness > 0.7 and state_time > 3.0:
		_set_state(State.INVESTIGATE)
	elif state == State.INVESTIGATE and (global_position.distance_to(last_known) < 3.0 or state_time > 15.0):
		_set_state(State.RECOVER)
	elif state == State.WARN and awareness < 0.4:
		_set_state(State.RECOVER)


# ---------------------------------------------------------------- the day in camp

func _hour() -> float:
	return world.day_night.time_hours if world and world.day_night else 12.0


func day_phase() -> StringName:
	var h := _hour()
	if h >= 22.0 or h < 5.5:
		return &"night"
	if h < 7.5:
		return &"morning"
	if h < 18.0:
		return &"day"
	return &"evening"


func _arrived(radius := 1.2) -> bool:
	return Vector2(global_position.x - _goal.x, global_position.z - _goal.z).length() < radius


func _routine() -> void:
	match state:
		State.SUSPICIOUS, State.INVESTIGATE, State.WARN:
			_set_state(State.RECOVER)
			return
		State.HUNT:
			_think_hunt()
			return
	var phase := day_phase()
	if phase == &"night":
		if group and group.on_watch(self):
			if state not in [State.SIT, State.PATROL]:
				_set_state(State.SIT)
			elif state == State.SIT and state_time > 50.0:
				_set_state(State.PATROL)
			elif state == State.PATROL and (_arrived() or state_time > 40.0):
				_set_state(State.SIT)
			return
		if state != State.SLEEP:
			_set_state(State.SLEEP)
		return
	if state == State.SLEEP:
		_set_state(State.IDLE)  # morning
		return
	match state:
		State.IDLE:
			if _hunting:
				_set_state(State.HUNT)  # interrupted by a stranger or a beast: carry on with the hunt
			elif state_time > rng.randf_range(4.0, 10.0):
				_choose_activity(phase)
		State.SIT:
			if state_time > _duration * (2.0 if phase == &"evening" else 1.0):
				_set_state(State.IDLE)
		State.PATROL:
			if _arrived() or state_time > 40.0:
				_set_state(State.IDLE if rng.randf() < 0.5 else State.PATROL)
		State.GATHER:
			if _arrived(1.0):
				carrying = GATHER_ITEMS[rng.randi() % GATHER_ITEMS.size()]
				_goal = global_position
				_set_state(State.WORK)
			elif state_time > 45.0:
				_set_state(State.IDLE)
		State.WORK:
			if state_time > _duration:
				if carrying != &"":
					_show_carry(carrying)
					_set_state(State.DELIVER)
				else:
					_set_state(State.IDLE)
			elif state_time > 30.0:
				_set_state(State.IDLE)
		State.DELIVER:
			if _arrived(1.4) or state_time > 50.0:
				if group:
					group.deposit(carrying, 1 + rng.randi() % 3)
				_drop_carry()
				_set_state(State.IDLE)
		State.SOCIAL:
			if not is_instance_valid(_partner) or _partner.is_dead() or state_time > _duration:
				_set_state(State.IDLE)
		State.TEND:
			if not is_instance_valid(_patient) or _patient.is_dead():
				_set_state(State.IDLE)
			elif state_time > _duration and global_position.distance_to(_patient.global_position) < 1.8:
				_patient.health = minf(_patient.max_health, _patient.health + 35.0)
				_patient.bleeding = 0.0
				_patient.being_tended = false
				_set_state(State.IDLE)
			elif state_time > 40.0:
				_set_state(State.IDLE)


func _choose_activity(phase: StringName) -> void:
	if group:
		var hurt := group.wounded_near(global_position, 25.0)
		if hurt and hurt != self:
			_patient = hurt
			hurt.being_tended = true
			_set_state(State.TEND)
			return
		if phase == &"day" and _hour() < 15.0:
			var party := group.plan_hunt(world.day_night.day if world and world.day_night else 0)
			if self in party:
				_start_hunt(party)
				return
	if phase == &"evening" or phase == &"morning":
		if rng.randf() < (0.65 if phase == &"evening" else 0.4):
			_set_state(State.SIT)
		elif not _start_social():
			_set_state(State.WORK if phase == &"morning" else State.SIT)
		return
	var plan: Array = DAY_PLAN.get(temper(), DAY_PLAN[&"wary"])
	var total := 0
	for row: Array in plan:
		total += int(row[1])
	var pick := rng.randi() % total
	for row: Array in plan:
		pick -= int(row[1])
		if pick < 0:
			var s: State = row[0]
			if s == State.SOCIAL:
				if not _start_social():
					_set_state(State.SIT)
			elif s == State.PATROL and not armed:
				_set_state(State.GATHER)
			else:
				_set_state(s)
			return


func _start_social() -> bool:
	if group == null:
		return false
	for m: HumanNPC in group.living():
		if m != self and m.state in [State.IDLE, State.SIT] and m.global_position.distance_to(global_position) < 16.0:
			_partner = m
			_set_state(State.SOCIAL)
			if m.state == State.IDLE:
				m._partner = self
				m._set_state(State.SOCIAL)
				m._duration = _duration
			return true
	return false


func _forage_spot() -> Vector3:
	for i in 6:
		var a := rng.randf() * TAU
		var p := home + Vector3(cos(a), 0, sin(a)) * rng.randf_range(9.0, 24.0)
		var g := world.ground_point(p.x, p.z) if world else p
		if g.y > ForestWorld.WATER_LEVEL + 0.3:
			return g
	return post


func _show_carry(item: StringName) -> void:
	_drop_carry()
	carrying = item
	if not ItemDB.items.has(item):
		return
	_carry_node = AssetLib.instance(AssetLib.item_model_path(item))
	if _carry_node:
		_carry_node.name = "Carry"
		_carry_node.top_level = true
		add_child(_carry_node)


func _drop_carry() -> void:
	carrying = &""
	if is_instance_valid(_carry_node):
		_carry_node.queue_free()
	_carry_node = null


# ---------------------------------------------------------------- hunting party

func _start_hunt(party: Array) -> void:
	var lead: HumanNPC = party[0]
	var goal := Vector3.INF
	if lead != self and lead._hunting:
		goal = lead._hunt_goal + Vector3(rng.randf_range(-4, 4), 0, rng.randf_range(-4, 4))
	else:
		for i in 8:
			var a := rng.randf() * TAU
			var p := home + Vector3(cos(a), 0, sin(a)) * rng.randf_range(HUNT_OUT.x, HUNT_OUT.y)
			if world and world.habitat_ok_for_people(p):
				goal = world.ground_point(p.x, p.z)
				break
	if goal == Vector3.INF:
		if group:
			group.end_hunt(self)
		return
	_hunting = true
	_hunt_goal = goal
	_hunt_phase = &"out"
	_hunt_t = 0.0
	_prey = null
	_set_state(State.HUNT)
	for m: HumanNPC in party:
		if m != self and not m._hunting and m.is_idle_for_work():
			m._start_hunt(party)


func _think_hunt() -> void:
	_hunt_t += 0.12
	var going_home := _hunt_phase in [&"home", &"retrieve"]
	if not going_home and (_hunt_t > HUNT_TIME or day_phase() in [&"evening", &"night"]):
		_hunt_phase = &"retrieve"
	match _hunt_phase:
		&"out", &"search":
			var prey := _find_prey(45.0)
			if prey:
				_prey = prey
				_hunt_phase = &"stalk"
				for m: HumanNPC in (group.hunters if group else []):
					if m != self and is_instance_valid(m) and m._hunting and m._hunt_phase in [&"out", &"search"]:
						m._prey = prey
						m._hunt_phase = &"stalk"
			elif _hunt_phase == &"out" and _arrived(4.0):
				_hunt_phase = &"search"
				_goal = _hunt_goal
			elif _hunt_phase == &"search" and (_arrived(2.0) or state_time > 25.0):
				var a := rng.randf() * TAU
				_goal = _hunt_goal + Vector3(cos(a), 0, sin(a)) * rng.randf_range(6.0, 22.0)
				state_time = 0.0
		&"stalk":
			if _prey == null or not is_instance_valid(_prey) or _prey.is_dead():
				_hunt_phase = &"butcher" if is_instance_valid(_prey) and _prey.is_dead() else &"search"
			elif global_position.distance_to(_prey.global_position) < THROW_MAX - 1.0 or _prey.state == Animal.State.FLEE:
				_hunt_phase = &"chase"
				_engage(_prey)
			elif global_position.distance_to(_prey.global_position) > 60.0:
				_hunt_phase = &"search"
		&"butcher":
			if _prey == null or not is_instance_valid(_prey) or _prey.butchered:
				_hunt_phase = &"retrieve"
			elif global_position.distance_to(_prey.global_position) < 1.8:
				if state_time > 8.0:
					var meat := int((_prey.def.get("loot", {}) as Dictionary).get("meat_raw", 2))
					_prey.butchered = true
					_prey.queue_free()
					_prey = null
					for m: HumanNPC in (group.hunters if group else []):
						if is_instance_valid(m) and m._hunting:
							m._hunt_phase = &"retrieve"
							m._show_carry(&"meat_raw")
					if group:
						group.deposit(&"meat_raw", maxi(1, meat))
					_hunt_phase = &"retrieve"
			else:
				state_time = 0.0
		&"retrieve":
			var spear := _nearest_thrown()
			if spear == null:
				_hunt_phase = &"home"
				if carrying == &"" and _prey == null and rng.randf() < 0.35:
					_show_carry(&"meat_raw")  # something was caught out of sight
					if group:
						group.deposit(&"meat_raw", 2)
			elif global_position.distance_to(spear.global_position) < 1.4:
				_thrown.erase(spear)
				spear.queue_free()
				spears += 1
		&"home":
			var store := group.storage if group else home
			if global_position.distance_to(store) < 2.6:
				_drop_carry()
				_hunting = false
				_hunt_phase = &""
				if group:
					group.end_hunt(self)
				_set_state(State.IDLE)


func _nearest_thrown() -> Node3D:
	var best: Node3D = null
	var best_d := 40.0
	for s: Variant in _thrown.duplicate():
		if not is_instance_valid(s) or (s as ThrownSpear).flying:
			if not is_instance_valid(s):
				_thrown.erase(s)
			continue
		var d := (s as Node3D).global_position.distance_to(global_position)
		if d < best_d:
			best = s
			best_d = d
	return best


func _hunt_goal_now() -> Vector3:
	match _hunt_phase:
		&"out":
			return _hunt_goal
		&"search":
			return _goal
		&"stalk", &"butcher":
			return _prey.global_position if is_instance_valid(_prey) else _goal
		&"retrieve":
			var s := _nearest_thrown()
			return s.global_position if s else (group.storage if group else home)
		&"home":
			return group.storage if group else home
	return _goal


# ---------------------------------------------------------------- combat

func _update_attack(delta: float) -> void:
	var target := foe if foe and is_instance_valid(foe) else _player()
	if (state != State.COMBAT or not armed or _stagger_t > 0.0 or _guard_t > 0.0 or target == null
			or target.get("dead") == true or (target is Animal and (target as Animal).is_dead())
			or not is_instance_valid(_spear) or _anim == null or not _anim.has_animation(&"combat/thrust")):
		_cancel_attack()
		return
	if _attack_time < 0.0:
		_start_attack(target)
		return
	var clip := _anim.get_animation(&"combat/" + String(_attack_kind))
	if _attack_time < ATTACK_COMMIT or (_attack_kind == &"throw" and _attack_time < THROW_RELEASE):
		_attack_target = _aim_point(target)
	var before := _attack_time
	_attack_time = minf(_attack_time + delta, clip.length)
	match _attack_kind:
		&"thrust":
			if before < ATTACK_WINDUP and _attack_time >= ATTACK_WINDUP:
				_anim.seek(ATTACK_WINDUP, true)
				_skel.force_update_all_bone_transforms()
				_pose_spear(delta, true)
				_attack_cd = ATTACK_COOLDOWN
				_strafe_dir *= -1.0
				_try_spear_hit(target)
				if _attack_time < 0.0:  # the player can parry and cancel the thrust on contact
					return
		&"throw":
			if before < THROW_RELEASE and _attack_time >= THROW_RELEASE:
				_release_throw(target)
		&"feint":
			if before < 0.5 and _attack_time >= 0.5:
				_attack_cd = 0.45  # the real thrust follows quickly if the guard drops
				_strafe_dir *= -1.0
	_anim.seek(_attack_time, true)
	if _attack_time >= clip.length:
		_cancel_attack()


func _aim_point(target: Node3D) -> Vector3:
	if target is Animal:
		return target.global_position + Vector3.UP * float((target as Animal).def.get("height", 1.0)) * 0.6
	return target.global_position + Vector3.UP * 1.15


## Picks the attack: a throw from range, a feint against a raised guard, else the thrust (when this
## fighter holds one of the group's attack tokens).
func _start_attack(target: Node3D) -> void:
	var to_t := target.global_position - global_position
	var flat := Vector3(to_t.x, 0.0, to_t.z)
	var distance := flat.length()
	var facing := global_transform.basis.z.dot(flat.normalized())
	if _attack_cd > 0.0 or absf(to_t.y) > 2.5:
		return
	if spears > 0 and distance > THROW_MIN and distance < THROW_MAX and facing > 0.9 and _speed < RUN * 0.6 \
			and _anim.has_animation(&"combat/throw") and _los(target.global_position + Vector3.UP):
		_begin(&"throw", target)
		return
	if (_speed > WALK * 0.75 or distance < ATTACK_MIN_RANGE or distance > ATTACK_RANGE + 1.0
			or absf(to_t.y) > 1.15 or facing < 0.90 or not _los(target.global_position + Vector3.UP)):
		return
	if group and not group.request_attack(self, target):
		return
	if target.get("blocking") == true and _anim.has_animation(&"combat/feint") and rng.randf() < 0.6:
		_begin(&"feint", target)
	elif distance <= ATTACK_RANGE:
		_begin(&"thrust", target)


func _begin(kind: StringName, target: Node3D) -> void:
	_attack_kind = kind
	_attack_time = 0.0
	_attack_target = _aim_point(target)
	_cur_anim = ""
	_play("combat/" + String(kind), false, 0.0)
	_anim.advance(0.0)


func _cancel_attack() -> void:
	if _attack_time < 0.0:
		return
	_attack_time = -1.0
	_attack_cd = maxf(_attack_cd, 0.35)
	_cur_anim = ""
	if group:
		group.release_attack(self)


func _try_spear_hit(target: Node3D) -> void:
	# Check the active length of the tip's thrust against the target's body.
	var tip := _spear.global_position + _spear_axis * SPEAR_TIP
	var start := tip - _spear_axis * 0.65
	var bottom := target.global_position + Vector3.UP * 0.35
	var top := target.global_position + Vector3.UP * 1.45
	var reach := 0.35
	if target is Animal:
		var h := float((target as Animal).def.get("height", 1.0))
		bottom = target.global_position + Vector3.UP * h * 0.3
		top = target.global_position + Vector3.UP * h * 0.9
		reach = float((target as Animal).def.get("radius", 0.35)) + 0.2
	var contact := Geometry3D.get_closest_points_between_segments(start, tip, bottom, top)
	if contact[0].distance_squared_to(contact[1]) > reach * reach:
		return
	var ray := PhysicsRayQueryParameters3D.create(_spear.global_position, contact[0], 1)
	if not get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
		return
	if target is Animal:
		(target as Animal).take_damage(DAMAGE * 1.6, self, contact[1])
	elif target.has_method("take_hit"):
		target.take_hit(DAMAGE, &"human", 0.3, global_position, self)


func _release_throw(target: Node3D) -> void:
	_attack_cd = ATTACK_COOLDOWN * 1.4
	if spears <= 0 or world == null:
		return
	spears -= 1
	var from := _spear.global_position + _spear_axis * 0.6 if is_instance_valid(_spear) else global_position + Vector3.UP * 1.7
	var aim := _aim_point(target)
	var lead: Vector3 = target.get("velocity") if target.get("velocity") != null else Vector3.ZERO
	var t := from.distance_to(aim) / THROW_SPEED
	aim += Vector3(lead.x, 0.0, lead.z) * t * 0.8
	aim.y += 0.5 * _gravity * t * t  # lob to cancel the drop
	var spear := ThrownSpear.new()
	world.pickups_root.add_child(spear)
	spear.launch(ItemStack.new(&"spear", 1, 40), from, (aim - from).normalized() * THROW_SPEED, self)
	_thrown.append(spear)
	Sfx.play(&"whoosh", from, -6.0)


# ---------------------------------------------------------------- locomotion & animation

func _face(target: Vector3) -> void:
	var d := target - global_position
	rotation.y = atan2(d.x, d.z)


## Direction toward `goal`, following a path through the camp when one exists.
func _steer(goal: Vector3) -> Vector3:
	var nav: NpcNav = world.npc_nav if world else null
	_path_t -= 0.016
	if nav and (_path_goal == Vector3.INF or _path_goal.distance_to(goal) > 1.5 or _path_t <= 0.0):
		_path = nav.path(global_position, goal)
		_path_i = 1 if _path.size() > 1 else 0
		_path_goal = goal
		_path_t = 3.0
	while _path_i < _path.size() and Vector2(_path[_path_i].x - global_position.x, _path[_path_i].z - global_position.z).length() < 0.7:
		_path_i += 1
	if _path_i < _path.size():
		var to_wp := _path[_path_i] - global_position
		if _path_i == _path.size() - 1 and goal.distance_to(_path[_path_i]) > 1.5:
			pass  # the path ends at the site edge; beyond it, steer straight
		return to_wp
	return goal - global_position


func _desired() -> Dictionary:
	var p := _player()
	var dir := Vector3.ZERO
	var speed := 0.0
	match state:
		State.PATROL, State.GATHER, State.IDLE, State.SIT, State.RECOVER, State.SLEEP, State.WORK, State.DELIVER:
			var to_goal := _goal - global_position
			to_goal.y = 0.0
			if to_goal.length() > 0.8:
				dir = _steer(_goal)
				speed = WALK
		State.SOCIAL:
			if is_instance_valid(_partner):
				var spot := _partner.global_position + (global_position - _partner.global_position).normalized() * 1.4
				var to_spot := spot - global_position
				to_spot.y = 0.0
				if to_spot.length() > 0.5:
					dir = _steer(spot)
					speed = WALK
				else:
					dir = _partner.global_position - global_position
		State.TEND:
			if is_instance_valid(_patient):
				var spot := _patient.global_position + (global_position - _patient.global_position).normalized() * 1.1
				if spot.distance_to(global_position) > 0.6:
					dir = _steer(spot)
					speed = WALK * 1.3
				else:
					dir = _patient.global_position - global_position
		State.HUNT:
			var g := _hunt_goal_now()
			var to_g := g - global_position
			to_g.y = 0.0
			var stop := 1.5 if _hunt_phase == &"butcher" else (1.0 if _hunt_phase == &"retrieve" else 2.0)
			if to_g.length() > stop:
				dir = _steer(g)
				speed = WALK * (0.75 if _hunt_phase == &"stalk" else (1.25 if _hunt_phase in [&"out", &"home"] else 1.0))
			else:
				dir = to_g
		State.INVESTIGATE:
			dir = _steer(last_known)
			speed = WALK * 1.2
		State.COMBAT:
			var target := foe if foe and is_instance_valid(foe) else p
			if target:
				var r := _combat_move(target)
				dir = r[0]
				speed = r[1]
		State.FLEE:
			var from := _flee_from if _flee_from and is_instance_valid(_flee_from) else p
			if from:
				var away := global_position - from.global_position
				away.y = 0.0
				var to_fire := home - global_position
				to_fire.y = 0.0
				if to_fire.length() > 2.5 and to_fire.normalized().dot(away.normalized()) > -0.3:
					dir = _steer(home)  # the fire keeps beasts (and the angry) at bay
				else:
					dir = away
				speed = RUN
		State.WARN:
			if p:
				dir = p.global_position - global_position
				speed = 0.0
		State.SUSPICIOUS, State.GREET:
			dir = last_known - global_position
	dir.y = 0.0
	return {"dir": dir.normalized() if dir.length() > 0.05 else Vector3.ZERO, "speed": speed}


## [direction, speed] while fighting: the token holder closes in; the others keep their slot around the foe,
## circle and sometimes fake a lunge from outside reach.
func _combat_move(target: Node3D) -> Array:
	var to_p := target.global_position - global_position
	to_p.y = 0.0
	var dist := to_p.length()
	if _attack_time >= 0.0 or _guard_t > 0.0:
		return [Vector3.ZERO, 0.0]
	if _stagger_t > 0.0 or _react_t > 0.25:
		return [-to_p, 0.6]
	if dist < ATTACK_MIN_RANGE:
		return [-to_p, 0.8]
	if spears > 0 and dist > THROW_MIN and dist < THROW_MAX and _attack_cd <= 0.0:
		return [to_p, 0.0]  # stop and throw
	var token := group == null or group.request_attack(self, target)
	var holding := 3.0 if group else 0.0
	if token and _attack_cd <= 0.1:
		return [to_p, minf(RUN, maxf(0.0, (dist - 1.65) * 2.6))]
	if _attack_cd > 0.1 and dist < 3.4 and token:
		var inward := to_p.normalized()
		return [inward.cross(Vector3.UP) * _strafe_dir + inward * clampf((dist - 2.15) * 0.9, -0.7, 0.7), SIDE_STEP]
	# Waiting for a turn: take the slot, then circle on it.
	var slot := group.slot_for(self, target) if group else target.global_position - to_p.normalized() * holding
	var to_slot := slot - global_position
	to_slot.y = 0.0
	if to_slot.length() > 1.2:
		return [to_slot, minf(RUN, to_slot.length() * 1.6)]
	var inward2 := to_p.normalized()
	if armed and _attack_cd <= 0.0 and dist < 3.6 and rng.randf() < 0.004 and _anim and _anim.has_animation(&"combat/feint") \
			and is_instance_valid(_spear):
		_begin(&"feint", target)  # a fake lunge from the slot keeps the foe guessing
		return [Vector3.ZERO, 0.0]
	return [inward2.cross(Vector3.UP) * _strafe_dir + inward2 * clampf((dist - holding) * 0.8, -0.6, 0.6), SIDE_STEP * 0.8]


func _move(delta: float) -> void:
	var want := _desired()
	var dir: Vector3 = want.dir
	var target_speed: float = want.speed
	_detour_t = maxf(_detour_t - delta, 0.0) if target_speed > 0.0 else 0.0
	if _detour_t > 0.0:
		dir = (_detour + dir * 0.25).normalized()
		target_speed = minf(target_speed, WALK)
	var face := dir
	var pl := _player()
	var target := foe if foe and is_instance_valid(foe) else pl
	if state == State.COMBAT and target and (_attack_time < ATTACK_COMMIT or _attack_kind == &"throw"):
		face = (target.global_position - global_position)  # keep facing the opponent while circling
		face.y = 0.0
	elif state == State.WARN and pl:
		face = pl.global_position - global_position
		face.y = 0.0
	elif state == State.SLEEP and _arrived(0.9):
		face = (global_position - home).cross(Vector3.UP)  # lie along the fire's circle
	_turning = false
	if face.length() > 0.01:
		var want_yaw := atan2(face.x, face.z)
		_turning = absf(angle_difference(rotation.y, want_yaw)) > 0.35
		rotation.y = rotate_toward(rotation.y, want_yaw, TURN * delta)
	var fwd := global_transform.basis.z
	var desired := dir * target_speed * _limp
	if state != State.COMBAT:
		# People walk where they face: a big change of direction is a pivot on the spot first.
		desired = fwd * maxf(0.0, fwd.dot(desired))
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var rate := DECEL if desired.length_squared() < horizontal.length_squared() else ACCEL
	if state in [State.COMBAT, State.FLEE] or target_speed > WALK * 1.5:
		rate *= 2.2  # fighting and running react faster
	horizontal = horizontal.move_toward(desired, rate * delta)
	if _attack_time >= 0.0:
		horizontal = Vector3.ZERO
	velocity.x = horizontal.x
	velocity.z = horizontal.z
	move_and_slide()
	if _detour_t <= 0.0 and target_speed > 0.0:
		_step_around_wall(dir)
	var actual := get_real_velocity()
	_travel = Vector3(actual.x, 0.0, actual.z)
	_speed = _travel.length()


func _step_around_wall(direction: Vector3) -> void:
	for i in get_slide_collision_count():
		var normal := get_slide_collision(i).get_normal()
		if absf(normal.y) > 0.65 or direction.dot(normal) > -0.2:
			continue
		normal.y = 0.0
		normal = normal.normalized()
		var tangent := normal.cross(Vector3.UP)
		var along := tangent.dot(direction)
		var side := signf(along) if absf(along) > 0.18 else _strafe_dir
		_detour = tangent * side + normal * 0.18
		_detour_t = 1.15
		_path_t = 0.0  # replan after getting around it
		return


func _animate() -> void:
	if _anim == null or state == State.DEAD:
		return
	if _attack_time >= 0.0:
		return
	if _react_t > 0.0 and _react_clip != "":
		_play(_react_clip, false)
		return
	if _guard_t > 0.0:
		_play("combat/guard")
		return
	var still := _speed < 0.2
	match state:
		State.SIT:
			if still:
				_play("sit")
				return
		State.SLEEP:
			if still and _arrived(1.0):
				_play_any(["life/sleep", "sit"])
				return
		State.WORK, State.TEND:
			if still:
				_play_any(["life/work", "sit"])
				return
		State.HUNT:
			if still and _hunt_phase == &"butcher":
				_play_any(["life/work", "sit"])
				return
		State.DELIVER:
			if still and _arrived(1.4):
				_play_any(["life/work", "sit"])
				return
		State.SOCIAL:
			if still and fmod(state_time + float(npc_id.hash() % 5), 7.0) < 1.8:
				_play("gesture")
				return
		State.GREET:
			_play("gesture")
			return
		State.WARN, State.SUSPICIOUS:
			_play("combat/guard" if armed and state == State.WARN else "alert")
			return
	if state == State.COMBAT and armed:
		if _speed < 0.13:
			_play("combat/guard")
			return
		var forward := _travel.dot(global_transform.basis.z)
		var sideways := _travel.dot(global_transform.basis.x)
		if absf(sideways) > absf(forward) * 0.85:
			_play("combat/strafe_l" if sideways > 0.0 else "combat/strafe_r", true,
				clampf(absf(sideways) / SIDE_STEP, 0.3, 1.35))
			return
		if forward < -0.13:
			_play("walk", true, -clampf(absf(forward) / WALK, 0.25, 1.1))
			return
	if _speed > WALK * (1.45 if _cur_anim == "run" else 1.65):
		_play("run", true, clampf(_speed / RUN, 0.48, 1.3))
	elif _speed > 0.13:
		_play("walk", true, clampf(_speed / WALK, 0.18, 1.6))
	elif _turning and _anim.has_animation(&"life/step"):
		_play("life/step")  # stepping round on the spot instead of sliding the feet
	else:
		_play("idle")


func _play_any(names: Array) -> void:
	for n: String in names:
		if _anim.has_animation(n):
			_play(n)
			return


func _play(name: String, blend: bool = true, rate := 1.0) -> void:
	if _anim == null or not _anim.has_animation(name):
		return
	_anim.speed_scale = rate
	if _cur_anim == name:
		return
	_cur_anim = name
	_anim.play(name, 0.18 if blend else 0.0, 1.0, rate < 0.0)


# ---------------------------------------------------------------- persistence

func save_state() -> Dictionary:
	return {"health": health, "dead": is_dead()}


func load_state(d: Dictionary) -> void:
	health = float(d.get("health", max_health))
	if bool(d.get("dead", false)):
		die(false)
		var p := global_position
		position = p
