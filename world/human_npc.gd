class_name HumanNPC
extends CharacterBody3D
## Tribe member (GDD §7). Perception-based (sight with line of sight + FOV, hearing, seeing gestures),
## behaviour from faction temper × relation:
##   routine: IDLE / SIT by the fire / PATROL / GATHER
##   → SUSPICIOUS → INVESTIGATE → WARN (territory) → COMBAT (armed) / FLEE (unarmed or hurt) → RECOVER
##   friendly: GREET (open-palm gesture). No shared language: offerings (E) and barter (R).

signal died(npc: HumanNPC)

enum State { IDLE, SIT, PATROL, GATHER, SUSPICIOUS, INVESTIGATE, WARN, COMBAT, FLEE, RECOVER, GREET, DEAD }
const WALK := 1.3
const RUN := 4.6
const TURN := 4.0
const SIGHT := 34.0
const FOV := 210.0
const HEARING := 24.0
const ATTACK_RANGE := 1.9
const ATTACK_WINDUP := 0.55
const ATTACK_COOLDOWN := 1.8
const DAMAGE := 18.0
const WARN_TIME := 6.0

var npc_id := ""
var faction: StringName
var variant := "M1"
var factions: Factions
var world: ForestWorld
var health := 100.0
var max_health := 100.0
var armed := false
var state: State = State.IDLE
var state_time := 0.0
var awareness := 0.0
var last_known := Vector3.ZERO
var home := Vector3.ZERO
var post := Vector3.ZERO
var greeted_until := 0.0

var _goal := Vector3.ZERO
var _speed := 0.0
var _uptime := 0.0
var _think_t := 0.0
var _attack_cd := 0.0
var _windup := -1.0
var _avoid_until := 0.0
var _model: Node3D
var _anim: AnimationPlayer
var _cur_anim := ""
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
	_model = AssetLib.instance("res://assets/models/humans/SK_Human_%s.gltf" % variant)
	_model.rotation.y = PI  # MPFB characters face -Y in Blender → +Z in Godot
	add_child(_model)
	_tune_skin(_model)
	var players := _model.find_children("*", "AnimationPlayer", true, false)
	_anim = players[0] if not players.is_empty() else null
	if _anim:
		for n in ["idle", "walk", "run", "alert", "sit"]:
			if _anim.has_animation(n):
				_anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	if armed:
		_attach_spear()
	_set_state(State.SIT if rng.randf() < 0.5 else State.IDLE)


static func _tune_skin(root: Node) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			if m is BaseMaterial3D and m.resource_name == "M_Skin":
				var d := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
				d.subsurf_scatter_enabled = true
				d.subsurf_scatter_strength = 0.35
				mi.set_surface_override_material(s, d)


func _attach_spear() -> void:
	var skels := _model.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		return
	var sk: Skeleton3D = skels[0]
	if sk.find_bone("hand_r") < 0:
		return
	var att := BoneAttachment3D.new()
	att.bone_name = "hand_r"
	sk.add_child(att)
	var spear := AssetLib.instance(AssetLib.item_model_path(&"spear"))
	spear.rotation_degrees = Vector3(90, 0, 0)
	spear.position = Vector3(0.0, 0.05, -0.4)
	att.add_child(spear)


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

func take_damage(amount: float, source: Node3D = null) -> void:
	if is_dead():
		return
	health -= amount
	var by_player := source != null and source.is_in_group("player")
	if by_player:
		factions.change(faction, -40.0, &"attacked")
		_rally(source)
	if health <= 0.0:
		die(by_player)
		return
	if health < max_health * 0.4 or not armed:
		_avoid_until = _uptime + 90.0
		_set_state(State.FLEE)
	elif by_player:
		_set_state(State.COMBAT)


func _rally(source: Node3D) -> void:
	for n: HumanNPC in get_tree().get_nodes_in_group("npc"):
		if n.faction == faction and not n.is_dead() and n.global_position.distance_to(global_position) < 40.0:
			n.awareness = 1.0
			n.last_known = source.global_position
			if n != self:
				n._set_state(State.COMBAT if n.armed else State.FLEE)


func die(by_player: bool) -> void:
	state = State.DEAD
	health = 0.0
	velocity = Vector3.ZERO
	remove_from_group("interactable")
	collision_layer = 0
	if by_player:
		factions.change(faction, -60.0, &"killed")
	_play("death", false)
	died.emit(self)


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
	if not is_on_floor():
		velocity.y -= _gravity * delta
	if is_dead():
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return
	state_time += delta
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	_think_t -= delta
	if _think_t <= 0.0:
		_think_t = 0.12
		_think(0.12)
	_update_attack(delta)
	_move(delta)
	_animate()


func _inside_territory(pos: Vector3) -> bool:
	var r := float(factions.def_of(faction).get("territory", 0))
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
				elif state_time > WARN_TIME and d < 16.0:
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
	if state != State.COMBAT or not armed:
		_windup = -1.0
		return
	var p := _player()
	if p == null:
		return
	if _windup < 0.0 and _attack_cd <= 0.0 and p.global_position.distance_to(global_position) <= ATTACK_RANGE:
		_windup = ATTACK_WINDUP
		_cur_anim = ""
		_play("attack", false)
	if _windup >= 0.0:
		_windup -= delta
		if _windup < 0.0:
			_attack_cd = ATTACK_COOLDOWN
			var dir := (p.global_position - global_position).normalized()
			if p.global_position.distance_to(global_position) <= ATTACK_RANGE + 0.4 and global_transform.basis.z.dot(dir) > 0.4:
				if p.has_method("take_hit"):
					p.take_hit(DAMAGE, &"human", 0.3, global_position)


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
				dir = p.global_position - global_position
				speed = RUN if dir.length() > ATTACK_RANGE * 0.9 else 0.0
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
	if dir != Vector3.ZERO:
		rotation.y = rotate_toward(rotation.y, atan2(dir.x, dir.z), TURN * delta)
	var fwd := global_transform.basis.z
	var align := clampf(fwd.dot(dir), 0.2, 1.0) if dir != Vector3.ZERO else 1.0
	_speed = move_toward(_speed, float(want.speed) * align, 6.0 * delta)
	velocity.x = fwd.x * _speed
	velocity.z = fwd.z * _speed
	move_and_slide()


func _animate() -> void:
	if _anim == null or state == State.DEAD:
		return
	if _windup >= 0.0:
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
			_play("alert")
			return
	if _speed > WALK * 1.6:
		_play("run")
	elif _speed > 0.2:
		_play("walk")
	else:
		_play("idle")


func _play(name: String, blend: bool = true) -> void:
	if _anim == null or _cur_anim == name or not _anim.has_animation(name):
		return
	_cur_anim = name
	_anim.play(name, 0.25 if blend else 0.08)


# ---------------------------------------------------------------- persistence

func save_state() -> Dictionary:
	return {"health": health, "dead": is_dead()}


func load_state(d: Dictionary) -> void:
	health = float(d.get("health", max_health))
	if bool(d.get("dead", false)):
		die(false)
		var p := global_position
		position = p
