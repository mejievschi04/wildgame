class_name HumanNPC
extends CharacterBody3D
## Tribe member (GDD §7). Perception-based (sight with line of sight + FOV, hearing, seeing gestures),
## behaviour from faction temper × relation:
##   routine: IDLE / SIT by the fire / PATROL / GATHER
##   → SUSPICIOUS → INVESTIGATE → WARN (territory) → COMBAT (armed) / FLEE (unarmed or hurt) → RECOVER
##   friendly: GREET (open-palm gesture). No shared language: offerings (E) and barter (R).

signal died(npc: HumanNPC)

enum State { IDLE, SIT, PATROL, GATHER, SUSPICIOUS, INVESTIGATE, WARN, COMBAT, FLEE, RECOVER, GREET, DEAD }
const WALK := 1.6
const RUN := 4.6
const SIDE_STEP := 1.0
const TURN := 4.0
const SIGHT := 34.0
const FOV := 210.0
const HEARING := 24.0
const ATTACK_MIN_RANGE := 1.25
const ATTACK_RANGE := 1.9
const ATTACK_WINDUP := 0.56  # contact frame in bake_human_combat.py
const ATTACK_COMMIT := 0.36
const ATTACK_COOLDOWN := 1.8
const SPEAR_TIP := 1.31  # model origin is the grip, with the tip along +Y
const DAMAGE := 18.0
const WARN_TIME := 6.0
const BODY_STYLES := {
	"M1": ["SapiensM", Vector3(1.02, 0.94, 1.00), Color("c6915d"), Color("bbb098"), ["Feather"]],
	"M2": ["SapiensM", Vector3(1.12, 0.89, 1.07), Color("79674d"), Color("b2ad9e"), ["Feather", "Human_SapiensMBeard"]],
	"M3": ["SapiensM", Vector3(0.95, 0.98, 0.96), Color("a4734b"), Color("928278"), ["Feather", "Talisman", "Mantle", "Human_SapiensMMantleFur"]],
	"F1": ["SapiensF", Vector3(1.01, 1.00, 1.02), Color("ba925c"), Color("afa291"), ["Feather"]],
	"F2": ["SapiensF", Vector3(1.08, 0.96, 1.05), Color("7a694c"), Color("a99e8d"), ["Talisman"]],
}

var npc_id := ""
var faction: StringName
var variant := "M1"
var factions: Factions
var world: ForestWorld
var health := 100.0
var max_health := 100.0
var armed := false
var territory_radius := -1.0  # use the faction default unless the guard has a local assignment
var warn_time := WARN_TIME
var state: State = State.IDLE
var state_time := 0.0
var awareness := 0.0
var last_known := Vector3.ZERO
var home := Vector3.ZERO
var post := Vector3.ZERO
var greeted_until := 0.0
## Hit-location health per body region; a cutting weapon severs a region that reaches 0.
var region_hp := {&"head": 45.0, &"torso": 999.0, &"arm_l": 35.0, &"arm_r": 35.0, &"leg_l": 45.0, &"leg_r": 45.0}
var severed: Array[StringName] = []
var bleeding := 0.0  # health lost per second
var _skel: Skeleton3D
var _severed_mod: SeveredBones
var _stagger_t := 0.0
var _guard_t := 0.0
var _limp := 1.0
var _strafe_dir := 1.0

var _goal := Vector3.ZERO
var _travel := Vector3.ZERO
var _speed := 0.0
var _detour := Vector3.ZERO
var _detour_t := 0.0
var _face_meshes: Array[MeshInstance3D] = []   # meshes carrying the expr_* blend shapes (new hominin models)
var _hurt_face_t := 0.0
var _uptime := 0.0
var _think_t := 0.0
var _attack_cd := 0.0
var _attack_time := -1.0
var _attack_target := Vector3.ZERO
var _avoid_until := 0.0
var _model: Node3D
var _body_model: String
var _anim: AnimationPlayer
var _cur_anim := ""
var _spear: Node3D
var _spear_hand := -1
var _spear_axis := Vector3.ZERO
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


func temper() -> StringName:
	return StringName(str(factions.def_of(faction).get("temper", "wary")))


func is_dead() -> bool:
	return state == State.DEAD


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
		if armed:
			_anim.add_animation_library(&"combat", load("res://assets/models/humans/AN_%s_combat.tres" % _body_model))
	var skels := _model.find_children("*", "Skeleton3D", true, false)
	_skel = skels[0] if not skels.is_empty() else null
	if _skel:
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
		if String(mesh.name).get_slice(".", 0).get_slice("_", 0) in removed or String(mesh.name) in removed:
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


func _pose_spear(delta: float, immediate := false) -> void:
	var hand := _skel.global_transform * _skel.get_bone_global_pose(_spear_hand)
	var forward := global_transform.basis.z
	var side := global_transform.basis.x
	var axis := (Vector3.UP * 0.92 + forward * 0.35 - side * 0.16).normalized()
	if _attack_time >= 0.0 or _cur_anim.begins_with("combat/"):
		var pitch := 0.10
		if _attack_time >= 0.0:
			var to_chest := _attack_target - hand.origin
			pitch = clampf(to_chest.y / maxf(0.7, Vector2(to_chest.x, to_chest.z).length()), -0.42, 0.42)
		axis = (forward + Vector3.UP * pitch).normalized()
	elif is_dead():
		axis = (-forward + Vector3.UP * 0.02).normalized()
	if immediate or _spear_axis == Vector3.ZERO:
		_spear_axis = axis
	else:
		_spear_axis = _spear_axis.lerp(axis, 1.0 - exp(-delta * 12.0)).normalized()
	var across := _spear_axis.cross(forward if absf(_spear_axis.dot(forward)) < 0.8 else side).normalized()
	var grip := hand.origin + hand.basis.y.normalized() * 0.055
	_spear.global_transform = Transform3D(Basis(across, _spear_axis, across.cross(_spear_axis)), grip)


# ---------------------------------------------------------------- perception

func _player() -> Node3D:
	return world.player as Node3D if world else null


func _sees(p: Node3D) -> float:
	var to_p := p.global_position - global_position
	var d := to_p.length()
	var vis: float = p.visibility_factor() if p.has_method("visibility_factor") else 1.0
	var range := SIGHT * vis
	var s := 0.0
	if d < range:
		var fwd := global_transform.basis.z  # model faces +Z
		var flat := Vector3(to_p.x, 0, to_p.z).normalized()
		if rad_to_deg(Vector3(fwd.x, 0, fwd.z).normalized().angle_to(flat)) <= FOV * 0.5 and _los(p.global_position + Vector3.UP * 1.3):
			s = 1.0 - d / range
	var noise: float = p.noise_level() if p.has_method("noise_level") else 0.3
	if d < HEARING * noise:
		s = maxf(s, 0.8 * (1.0 - d / (HEARING * noise)))
	return s


func _los(target: Vector3) -> bool:
	if not is_inside_tree():
		return true
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 1.6, target, 1)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# ---------------------------------------------------------------- interaction (offerings & barter)

func get_display_name() -> String:
	return Loc.t("NPC_%s" % String(faction).to_upper())


func get_status_text() -> String:
	if is_dead():
		return Loc.t("NPC_DEAD")
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
	if is_dead() or state in [State.COMBAT, State.FLEE] or factions.stance(faction) == &"hostile":
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
	if health < max_health * 0.4 or not armed:
		_avoid_until = _uptime + 90.0
		_set_state(State.FLEE)
	elif by_player and state != State.COMBAT:
		_set_state(State.COMBAT)


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
			_set_state(State.FLEE)


func _rally(source: Node3D) -> void:
	for n: HumanNPC in get_tree().get_nodes_in_group("npc"):
		if n.faction == faction and not n.is_dead() and n.global_position.distance_to(global_position) < 40.0:
			n.awareness = 1.0
			n.last_known = source.global_position
			if n != self:
				n._set_state(State.COMBAT if n.armed else State.FLEE)


func die(by_player: bool) -> void:
	_cancel_attack()
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
		State.SUSPICIOUS, State.INVESTIGATE:
			return &"focused"
		State.GREET:
			return &"happy"
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
	state = s
	state_time = 0.0
	match s:
		State.PATROL, State.GATHER:
			var a := rng.randf() * TAU
			_goal = home + Vector3(cos(a), 0, sin(a)) * rng.randf_range(4.0, 14.0)
		State.IDLE, State.SIT, State.RECOVER:
			_goal = post


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
	if bleeding > 0.0:
		health -= bleeding * delta
		if randf() < delta * 1.5:
			Gore.decal(world, global_position, 0.25)
		if health <= 0.0:
			die(true)
			return
	if state == State.COMBAT and armed and _attack_time < 0.0 and _guard_t <= 0.0 and _stagger_t <= 0.0:
		var pl := _player()
		if pl and pl.has_method("is_winding_up") and pl.is_winding_up() \
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
			var give_up: bool = state_time > 25.0 or d > 35.0 or p.get("dead") == true
			if temper() == &"territorial" and not _inside_territory(p.global_position) and state_time > 4.0:
				give_up = true
			if give_up:
				_set_state(State.RECOVER)
			return
		State.FLEE:
			if state_time > 14.0:
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
	if awareness < 0.3:
		_routine()
		return
	# The player is noticed.
	match temper():
		&"peaceful":
			if stance == &"hostile" or (d < 12.0 and _uptime < _avoid_until):
				_set_state(State.FLEE)
			elif d < 9.0 and _uptime > greeted_until:
				greeted_until = _uptime + 40.0
				_set_state(State.GREET)
			else:
				_watch()
		&"wary":
			if stance == &"hostile" and armed and d < 22.0:
				_set_state(State.COMBAT)
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
				_set_state(State.COMBAT)
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
						_set_state(State.COMBAT)
			else:
				_watch()


func _watch() -> void:
	if state in [State.IDLE, State.SIT, State.PATROL, State.GATHER]:
		_set_state(State.SUSPICIOUS)
	elif state == State.SUSPICIOUS and awareness > 0.7 and state_time > 3.0:
		_set_state(State.INVESTIGATE)
	elif state == State.INVESTIGATE and (global_position.distance_to(last_known) < 3.0 or state_time > 15.0):
		_set_state(State.RECOVER)
	elif state == State.WARN and awareness < 0.4:
		_set_state(State.RECOVER)


func _routine() -> void:
	match state:
		State.SUSPICIOUS, State.INVESTIGATE, State.WARN:
			_set_state(State.RECOVER)
		State.IDLE:
			if state_time > rng.randf_range(6.0, 14.0):
				_set_state([State.SIT, State.PATROL, State.GATHER][rng.randi() % 3])
		State.SIT:
			if state_time > rng.randf_range(20.0, 40.0):
				_set_state(State.IDLE)
		State.PATROL, State.GATHER:
			if global_position.distance_to(_goal) < 1.2:
				if state == State.GATHER and state_time < 30.0:
					_goal = global_position  # crouch and pick for a while
				if state_time > 20.0:
					_set_state(State.IDLE)
			elif state_time > 40.0:
				_set_state(State.IDLE)


# ---------------------------------------------------------------- combat

func _update_attack(delta: float) -> void:
	var p := _player()
	if (state != State.COMBAT or not armed or _stagger_t > 0.0 or _guard_t > 0.0 or p == null
			or p.get("dead") == true or not is_instance_valid(_spear) or _anim == null
			or not _anim.has_animation(&"combat/thrust")):
		_cancel_attack()
		return
	var clip := _anim.get_animation(&"combat/thrust")
	if _attack_time < ATTACK_COMMIT:
		_attack_target = p.global_position + Vector3.UP * 1.15
	if _attack_time < 0.0:
		var to_player := p.global_position - global_position
		var flat := Vector3(to_player.x, 0.0, to_player.z)
		var distance := flat.length()
		if (_attack_cd > 0.0 or _speed > WALK * 0.75 or distance < ATTACK_MIN_RANGE or distance > ATTACK_RANGE
				or absf(to_player.y) > 1.15 or global_transform.basis.z.dot(flat.normalized()) < 0.90
				or not _los(p.global_position + Vector3.UP)):
			return
		_attack_time = 0.0
		_cur_anim = ""
		_play("combat/thrust", false, 0.0)
		_anim.advance(0.0)
		return
	var before := _attack_time
	_attack_time = minf(_attack_time + delta, clip.length)
	if before < ATTACK_WINDUP and _attack_time >= ATTACK_WINDUP:
		_anim.seek(ATTACK_WINDUP, true)
		_skel.force_update_all_bone_transforms()
		_pose_spear(delta, true)
		_attack_cd = ATTACK_COOLDOWN
		_strafe_dir *= -1.0
		_try_spear_hit(p)
		if _attack_time < 0.0:  # the player can parry and cancel the thrust on contact
			return
	_anim.seek(_attack_time, true)
	if _attack_time >= clip.length:
		_cancel_attack()


func _cancel_attack() -> void:
	if _attack_time < 0.0:
		return
	_attack_time = -1.0
	_attack_cd = maxf(_attack_cd, 0.35)
	_cur_anim = ""


func _try_spear_hit(target: Node3D) -> void:
	# Check the active length of the tip's thrust against the player's standing capsule.
	var tip := _spear.global_position + _spear_axis * SPEAR_TIP
	var start := tip - _spear_axis * 0.65
	var bottom := target.global_position + Vector3.UP * 0.35
	var top := target.global_position + Vector3.UP * 1.45
	var contact := Geometry3D.get_closest_points_between_segments(start, tip, bottom, top)
	if contact[0].distance_squared_to(contact[1]) > 0.35 * 0.35 or not target.has_method("take_hit"):
		return
	var ray := PhysicsRayQueryParameters3D.create(_spear.global_position, contact[0], 1)
	if get_world_3d().direct_space_state.intersect_ray(ray).is_empty():
		target.take_hit(DAMAGE, &"human", 0.3, global_position, self)


# ---------------------------------------------------------------- locomotion & animation

func _face(target: Vector3) -> void:
	var d := target - global_position
	rotation.y = atan2(d.x, d.z)


func _desired() -> Dictionary:
	var p := _player()
	var dir := Vector3.ZERO
	var speed := 0.0
	match state:
		State.PATROL, State.GATHER, State.IDLE, State.SIT, State.RECOVER:
			dir = _goal - global_position
			speed = WALK if dir.length() > 0.8 else 0.0
		State.INVESTIGATE:
			dir = last_known - global_position
			speed = WALK * 1.2
		State.COMBAT:
			if p:
				var to_p := p.global_position - global_position
				to_p.y = 0.0
				var dist := to_p.length()
				if _attack_time >= 0.0 or _guard_t > 0.0:
					pass
				elif _stagger_t > 0.0:
					dir = -to_p
					speed = 0.6
				elif dist < ATTACK_MIN_RANGE:
					dir = -to_p
					speed = 0.8
				elif _attack_cd > 0.1 and dist < 3.4:
					var inward := to_p.normalized()
					dir = inward.cross(Vector3.UP) * _strafe_dir + inward * clampf((dist - 2.15) * 0.9, -0.7, 0.7)
					speed = SIDE_STEP
				else:
					dir = to_p
					speed = minf(RUN, maxf(0.0, (dist - 1.65) * 2.6))
		State.FLEE:
			if p:
				dir = global_position - p.global_position
				speed = RUN
		State.WARN:
			if p:
				dir = p.global_position - global_position
				speed = 0.0
		State.SUSPICIOUS, State.GREET:
			dir = last_known - global_position
	dir.y = 0.0
	return {"dir": dir.normalized() if dir.length() > 0.05 else Vector3.ZERO, "speed": speed}


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
	if state == State.COMBAT and pl and (_attack_time < ATTACK_COMMIT):
		face = (pl.global_position - global_position)  # keep facing the opponent while circling
		face.y = 0.0
	elif state == State.WARN and pl:
		face = pl.global_position - global_position
		face.y = 0.0
	if face.length() > 0.01:
		rotation.y = rotate_toward(rotation.y, atan2(face.x, face.z), TURN * delta)
	var fwd := global_transform.basis.z
	var desired := dir * target_speed * _limp
	if state != State.COMBAT:
		desired = fwd * maxf(0.0, fwd.dot(desired))
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	horizontal = horizontal.move_toward(desired, (9.0 if desired.length_squared() < horizontal.length_squared() else 6.0) * delta)
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
		return


func _animate() -> void:
	if _anim == null or state == State.DEAD:
		return
	if _attack_time >= 0.0:
		return
	if _guard_t > 0.0:
		_play("combat/guard")
		return
	match state:
		State.SIT:
			if _speed < 0.2:
				_play("sit")
				return
		State.GATHER:
			if _speed < 0.2:
				_play("sit")
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
	else:
		_play("idle")


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
