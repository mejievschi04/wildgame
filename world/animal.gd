class_name Animal
extends CharacterBody3D
## Wildlife agent (GDD §6, Phase 3). Perception-driven state machine — no omniscience:
##   sight (range, FOV, line of sight, player visibility), hearing (player noise), smell (wind-dependent).
## Prey:      IDLE/WANDER/GRAZE → ALERT → FLEE (alarms herd) → RECOVER
## Predator:  PATROL → SUSPICIOUS → INVESTIGATE → CHASE → ATTACK (wind-up) → gives up / RETREAT when hurt
##            also HUNT_PREY (chases deer), afraid of fire/torches. No teleporting, no permanent aggro.

signal died(animal: Animal)

enum State { IDLE, WANDER, GRAZE, ALERT, FLEE, RECOVER, PATROL, SUSPICIOUS, INVESTIGATE, CHASE, ATTACK, HUNT_PREY, DEAD }
const THINK_INTERVAL := 0.1
const LAYER_CREATURE := 16

var species: StringName
var def: Dictionary = {}
var world: ForestWorld
var animal_id := ""
var health := 50.0
var max_health := 50.0
var state: State = State.IDLE
var state_time := 0.0
var awareness := 0.0  # of the player, 0..1
var threat: Node3D = null  # what prey flees from / predator targets
var last_known := Vector3.ZERO
var home := Vector3.ZERO
var herd: Array = []  # other members (prey alarm)
var butchered := false
var killed_by: StringName = &""
var hungry := false
var calm_until := 0.0  # predators won't re-engage the player before this (seconds of uptime)

var _goal := Vector3.ZERO
var _speed := 0.0
var _think_t := 0.0
var _uptime := 0.0
var _attack_cd := 0.0
var _windup := -1.0
var _step_accum := 0.0
var _stuck_t := 0.0
var _last_pos := Vector3.ZERO
var _model: Node3D
var _anim: AnimationPlayer
var _cur_anim := ""
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var rng := RandomNumberGenerator.new()


func setup(p_species: StringName, p_world: ForestWorld, pos: Vector3, seed: int, p_id: String = "") -> void:
	species = p_species
	def = ItemDB.get_animal(species)
	world = p_world
	animal_id = p_id if p_id != "" else "%s_%d" % [species, seed]
	rng.seed = seed
	max_health = float(def.get("health", 50))
	health = max_health
	home = pos
	position = pos
	_goal = pos
	hungry = rng.randf() < 0.5


func is_predator() -> bool:
	return str(def.get("diet", "prey")) == "predator"


func is_dead() -> bool:
	return state == State.DEAD


func _ready() -> void:
	collision_layer = LAYER_CREATURE
	collision_mask = 1
	floor_snap_length = 0.6
	floor_max_angle = deg_to_rad(55.0)
	add_to_group("animal")
	var r := float(def.get("radius", 0.35))
	var length := float(def.get("length", 1.3))
	var h := float(def.get("height", 1.2))
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = r
	cap.height = maxf(length, r * 2.0 + 0.1)
	cs.shape = cap
	cs.rotation_degrees = Vector3(90, 0, 0)
	cs.position = Vector3(0, h * 0.6, 0)
	add_child(cs)
	_model = AssetLib.instance(str(def.model))
	add_child(_model)
	_fix_materials(_model)
	var players := _model.find_children("*", "AnimationPlayer", true, false)
	_anim = players[0] if not players.is_empty() else null
	if _anim:
		for n in ["idle", "walk", "run", "graze", "alert"]:
			if _anim.has_animation(n):
				_anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	_set_state(State.PATROL if is_predator() else State.GRAZE)
	_last_pos = global_position


static func _fix_materials(root: Node) -> void:
	# Coat colour lives in vertex colours; make sure the material uses them.
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			if m is BaseMaterial3D:
				var d := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
				d.vertex_color_use_as_albedo = true
				d.vertex_color_is_srgb = false
				d.roughness = 0.85
				mi.set_surface_override_material(s, d)


# ---------------------------------------------------------------- perception

## Stimulus (0..1) the player currently produces for this animal.
func perceive_player(p: Node3D) -> float:
	if p == null or (p.get("dead") == true):
		return 0.0
	var to_p := p.global_position - global_position
	var d := to_p.length()
	var s := 0.0
	var vis: float = p.visibility_factor() if p.has_method("visibility_factor") else 1.0
	var sight := float(def.sight) * vis
	if d < sight:
		var fwd := -global_transform.basis.z
		var flat := Vector3(to_p.x, 0, to_p.z).normalized()
		var angle := rad_to_deg(Vector3(fwd.x, 0, fwd.z).normalized().angle_to(flat))
		if angle <= float(def.fov) * 0.5 and _line_of_sight(p.global_position + Vector3.UP * 1.2):
			s = maxf(s, 1.0 - d / sight)
	var noise: float = p.noise_level() if p.has_method("noise_level") else 0.3
	var hear := float(def.hearing) * noise
	if d < hear:
		s = maxf(s, 0.85 * (1.0 - d / hear))
	if smells(p.global_position):
		s = maxf(s, 0.6 * (1.0 - d / float(def.smell)))
	return s


## Smell works only downwind: the wind must carry the scent from source to animal.
func smells(source: Vector3) -> bool:
	var d := source.distance_to(global_position)
	if d > float(def.smell):
		return false
	var wind := world.weather.wind_dir if world and world.weather else Vector2(0.8, 0.6)
	var to_me := Vector2(global_position.x - source.x, global_position.z - source.z).normalized()
	return to_me.dot(wind) > 0.5 or d < 4.0


func _line_of_sight(target_pos: Vector3) -> bool:
	if not is_inside_tree():
		return true
	var from := global_position + Vector3.UP * float(def.get("height", 1.0))
	var q := PhysicsRayQueryParameters3D.create(from, target_pos, 1)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _player() -> Node3D:
	return world.player as Node3D if world else null


# ---------------------------------------------------------------- damage & death

func take_damage(amount: float, source: Node3D = null) -> void:
	if is_dead():
		return
	health -= amount
	_flinch()
	if health <= 0.0:
		die(&"player" if source and source.is_in_group("player") else &"other")
		return
	if source:
		threat = source
		last_known = source.global_position
	if is_predator():
		if health < max_health * float(def.get("flee_health", 0.4)):
			calm_until = _uptime + 120.0
			_set_state(State.FLEE)
		elif source and source.is_in_group("player"):
			awareness = 1.0
			_set_state(State.CHASE)
	else:
		_alarm_herd(source)
		_set_state(State.FLEE)


func _flinch() -> void:
	if _model:
		var tw := create_tween()
		tw.tween_property(_model, "position", Vector3(0, -0.06, 0.05), 0.06)
		tw.tween_property(_model, "position", Vector3.ZERO, 0.12)


func die(cause: StringName) -> void:
	if is_dead():
		return
	killed_by = cause
	state = State.DEAD
	health = 0.0
	velocity = Vector3.ZERO
	collision_layer = 4  # soft: walkable, still targetable for butchering
	add_to_group("interactable")
	add_to_group("carcass")
	_play("death", false)
	died.emit(self)


# ---------------------------------------------------------------- interaction (carcass)

func get_display_name() -> String:
	var n := Loc.t("ANIMAL_%s" % String(species).to_upper())
	return Loc.t("CARCASS_OF", {"name": n}) if is_dead() else n


func get_interactions(player: Node) -> Array:
	if not is_dead() or butchered:
		return []
	var ok: bool = player.inventory.has_tag(&"tool_knife")
	return [{"action": &"interact", "text": Loc.t("ACT_BUTCHER") if ok else Loc.t("NEED_TOOL_KNIFE"),
		"hold": 4.0, "enabled": ok}]


func perform_interaction(player: Node, _action: StringName) -> void:
	if not is_dead() or butchered or not player.inventory.has_tag(&"tool_knife"):
		return
	var loot: Dictionary = def.get("loot", {})
	var share := 0.5 if killed_by == &"wolf" else 1.0  # wolves already ate part of it
	for id: String in loot.keys():
		var n := maxi(1, int(round(int(loot[id]) * share)))
		player.give_item(StringName(id), n)
	butchered = true
	Sfx.play(&"rustle", global_position)
	if species == &"deer":
		world.add_journal("JOURNAL_HUNT")
	queue_free()


# ---------------------------------------------------------------- brain

func _set_state(s: State) -> void:
	state = s
	state_time = 0.0
	match s:
		State.WANDER, State.PATROL:
			var radius := 60.0 if is_predator() else 22.0
			var a := rng.randf() * TAU
			_goal = home + Vector3(cos(a), 0, sin(a)) * rng.randf_range(radius * 0.3, radius)


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
		_think(THINK_INTERVAL)
		_think_t = THINK_INTERVAL
	_update_attack(delta)
	_move(delta)
	_animate()
	_leave_tracks(delta)


func _think(dt: float) -> void:
	var p := _player()
	var stim := perceive_player(p) if p else 0.0
	if stim > 0.0:
		awareness = minf(awareness + stim * dt * 3.0, 1.0)
		last_known = p.global_position
	else:
		awareness = maxf(awareness - 0.12 * dt, 0.0)
	if is_predator():
		_think_predator(dt, p, stim)
	else:
		_think_prey(dt, p, stim)


func _think_prey(_dt: float, p: Node3D, stim: float) -> void:
	var d := p.global_position.distance_to(global_position) if p else INF
	match state:
		State.IDLE, State.GRAZE, State.WANDER:
			if awareness > 0.35:
				threat = p
				_set_state(State.ALERT)
			elif state == State.GRAZE and state_time > rng.randf_range(6.0, 14.0):
				_set_state(State.WANDER)
			elif state == State.IDLE and state_time > 5.0:
				_set_state(State.GRAZE)
			elif state == State.WANDER and (global_position.distance_to(_goal) < 1.5 or state_time > 25.0):
				_set_state(State.IDLE if rng.randf() < 0.4 else State.GRAZE)
		State.ALERT:
			if awareness > 0.8 or (d < 12.0 and stim > 0.2):
				_alarm_herd(p)
				_set_state(State.FLEE)
			elif awareness < 0.15 and state_time > 4.0:
				_set_state(State.GRAZE)
		State.FLEE:
			var far := threat == null or threat.global_position.distance_to(global_position) > 60.0
			if (far and state_time > 6.0) or state_time > 22.0:
				_set_state(State.RECOVER)
		State.RECOVER:
			if awareness > 0.6:
				_set_state(State.FLEE)
			elif state_time > 12.0:
				home = global_position
				_set_state(State.GRAZE)


func _think_predator(_dt: float, p: Node3D, stim: float) -> void:
	var d := p.global_position.distance_to(global_position) if p else INF
	var near_fire := _fire_near(p.global_position if p else global_position)
	var may_engage := _uptime >= calm_until
	match state:
		State.PATROL, State.IDLE:
			var prey := _find_prey()
			if hungry and prey:
				threat = prey
				_set_state(State.HUNT_PREY)
			elif may_engage and awareness > 0.4:
				_set_state(State.SUSPICIOUS)
			elif state == State.PATROL and (global_position.distance_to(_goal) < 2.0 or state_time > 40.0):
				_set_state(State.IDLE)
			elif state == State.IDLE and state_time > rng.randf_range(4.0, 9.0):
				_set_state(State.PATROL)
		State.SUSPICIOUS:
			if awareness > 0.65:
				_set_state(State.INVESTIGATE)
			elif awareness < 0.2 and state_time > 5.0:
				_set_state(State.PATROL)
		State.INVESTIGATE:
			if stim > 0.35 and d < 20.0 and _wants_to_attack(p) and not near_fire:
				threat = p
				_set_state(State.CHASE)
			elif global_position.distance_to(last_known) < 2.5 or state_time > 18.0:
				_set_state(State.PATROL)
		State.CHASE:
			if threat == null or not is_instance_valid(threat):
				_set_state(State.PATROL)
			elif state_time > float(def.give_up) or d > 45.0 or (p and p.get("dead") == true):
				calm_until = _uptime + 60.0
				_set_state(State.PATROL)
			elif near_fire and d < float(def.fire_fear):
				calm_until = _uptime + 30.0
				_set_state(State.FLEE)
			elif d <= float(def.attack_range) and _attack_cd <= 0.0:
				_set_state(State.ATTACK)
		State.ATTACK:
			if _windup < 0.0 and state_time > 0.9:
				_set_state(State.CHASE if threat else State.PATROL)
		State.HUNT_PREY:
			if threat == null or not is_instance_valid(threat) or state_time > 30.0:
				_set_state(State.PATROL)
			elif threat is Animal and (threat as Animal).is_dead():
				hungry = false
				_set_state(State.IDLE)
			elif threat.global_position.distance_to(global_position) < 1.8:
				(threat as Animal).die(&"wolf")
				hungry = false
				_set_state(State.IDLE)
			elif awareness > 0.7 and may_engage and _wants_to_attack(p):
				threat = p
				_set_state(State.CHASE)
		State.FLEE:
			if state_time > 14.0:
				_set_state(State.RECOVER)
		State.RECOVER:
			if state_time > 10.0:
				home = global_position
				_set_state(State.PATROL)


## Predators commit to the player only with a reason: hungry, night, a weak player, or provoked.
func _wants_to_attack(p: Node3D) -> bool:
	if p == null:
		return false
	var night: bool = world.day_night.is_night() if world else false
	var weak: bool = p.get("stats") != null and p.stats.health < 60.0
	return hungry or night or weak or health < max_health


func _fire_near(pos: Vector3) -> bool:
	if world == null:
		return false
	if world.get_warmth_at(pos) > 5.0:
		return true
	var p := _player()
	return p != null and p.get("inventory") != null and p.inventory.hand != null and p.inventory.hand.id == &"torch" \
		and p.global_position.distance_to(pos) < 1.0


func _find_prey() -> Animal:
	var best: Animal = null
	var best_d := float(def.sight)
	for a: Animal in get_tree().get_nodes_in_group("animal"):
		if a == self or a.is_predator() or a.is_dead():
			continue
		var d := a.global_position.distance_to(global_position)
		if d < best_d and (_line_of_sight(a.global_position + Vector3.UP) or smells(a.global_position)):
			best = a
			best_d = d
	return best


func _alarm_herd(source: Node3D) -> void:
	for a: Animal in herd:
		if is_instance_valid(a) and not a.is_dead() and a.state != State.FLEE \
				and a.global_position.distance_to(global_position) < 35.0:
			a.threat = source
			a.awareness = 1.0
			a._set_state(State.FLEE)


# ---------------------------------------------------------------- attack

func _update_attack(delta: float) -> void:
	if state != State.ATTACK:
		_windup = -1.0
		return
	if _windup < 0.0 and state_time < 0.05:
		_windup = float(def.attack_windup)
		_play("attack", false)
		Sfx.play(&"hurt", global_position, -12.0, 0.2)
	if _windup >= 0.0:
		_windup -= delta
		if _windup < 0.0:
			_attack_cd = float(def.attack_cooldown)
			var p := _player()
			if p and threat == p and p.global_position.distance_to(global_position) <= float(def.attack_range) + 0.5:
				var dir := (p.global_position - global_position).normalized()
				if (-global_transform.basis.z).dot(dir) > 0.4 and p.has_method("take_hit"):
					p.take_hit(float(def.damage), &"wolf", float(def.get("bleed_chance", 0.0)), global_position)


# ---------------------------------------------------------------- locomotion

func _desired() -> Dictionary:
	var dir := Vector3.ZERO
	var speed := 0.0
	var walk := float(def.walk)
	var run := float(def.run)
	match state:
		State.WANDER, State.PATROL:
			dir = _goal - global_position
			speed = walk
		State.FLEE:
			var from := threat.global_position if threat and is_instance_valid(threat) else last_known
			dir = global_position - from
			speed = run
		State.RECOVER:
			dir = -global_transform.basis.z
			speed = walk * 0.8
		State.INVESTIGATE:
			dir = last_known - global_position
			speed = walk * 1.3
		State.CHASE:
			if threat and is_instance_valid(threat):
				dir = threat.global_position - global_position
				var d := dir.length()
				speed = run if d > float(def.attack_range) else 0.0
		State.HUNT_PREY:
			if threat and is_instance_valid(threat):
				dir = threat.global_position - global_position
				speed = run
		State.ALERT, State.SUSPICIOUS, State.ATTACK:
			var look := last_known if state != State.ATTACK or threat == null else threat.global_position
			dir = look - global_position
			speed = 0.0
	dir.y = 0.0
	return {"dir": dir.normalized() if dir.length() > 0.01 else Vector3.ZERO, "speed": speed}


func _move(delta: float) -> void:
	var want := _desired()
	var dir: Vector3 = want.dir
	var speed: float = want.speed
	if dir != Vector3.ZERO and speed > 0.0:
		dir = _avoid(dir)
	if dir != Vector3.ZERO:
		var target_yaw := atan2(-dir.x, -dir.z)
		rotation.y = rotate_toward(rotation.y, target_yaw, float(def.turn) * delta)
	var facing := -global_transform.basis.z
	# Animals move where they face (no sliding sideways); slow down while turning hard.
	var align := clampf(facing.dot(dir), 0.2, 1.0) if dir != Vector3.ZERO else 1.0
	_speed = move_toward(_speed, speed * align, (8.0 if speed > _speed else 10.0) * delta)
	velocity.x = facing.x * _speed
	velocity.z = facing.z * _speed
	move_and_slide()
	if _speed > 0.5:
		if global_position.distance_to(_last_pos) < _speed * delta * 0.2:
			_stuck_t += delta
			if _stuck_t > 1.2:
				rotation.y += PI * 0.5 * (1.0 if rng.randf() < 0.5 else -1.0)
				_stuck_t = 0.0
				if state in [State.WANDER, State.PATROL]:
					_set_state(state)
		else:
			_stuck_t = 0.0
	_last_pos = global_position


## Steers around obstacles, water and the map edge using a few probes.
func _avoid(dir: Vector3) -> Vector3:
	var options := [0.0, 0.6, -0.6, 1.2, -1.2, 2.0, -2.0]
	for a: float in options:
		var cand := dir.rotated(Vector3.UP, a)
		if _clear(cand):
			return cand
	return dir.rotated(Vector3.UP, PI)


func _clear(dir: Vector3) -> bool:
	var ahead := global_position + dir * 3.0
	if world:
		if world.height_at(ahead.x, ahead.z) < ForestWorld.WATER_LEVEL + 0.25:
			return false
		if absf(ahead.x) > ForestWorld.PLAYABLE - 2.0 or absf(ahead.z) > ForestWorld.PLAYABLE - 2.0:
			return false
	if not is_inside_tree():
		return true
	var from := global_position + Vector3.UP * float(def.get("height", 1.0)) * 0.6
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 2.2, 1)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# ---------------------------------------------------------------- presentation

func _animate() -> void:
	if _anim == null:
		return
	match state:
		State.ATTACK:
			return
		State.GRAZE:
			_play("graze")
		State.ALERT, State.SUSPICIOUS:
			_play("alert")
		_:
			if _speed > float(def.walk) * 1.6:
				_play("run")
				_anim.speed_scale = clampf(_speed / float(def.run), 0.6, 1.4)
			elif _speed > 0.3:
				_play("walk")
				_anim.speed_scale = clampf(_speed / float(def.walk), 0.6, 1.8)
			else:
				_play("idle")


func _play(name: String, blend: bool = true) -> void:
	if _anim == null or _cur_anim == name or not _anim.has_animation(name):
		return
	_cur_anim = name
	_anim.speed_scale = 1.0
	_anim.play(name, 0.25 if blend else 0.1)


func _leave_tracks(delta: float) -> void:
	if _speed < 0.3 or world == null or world.tracks == null:
		return
	_step_accum += _speed * delta
	if _step_accum >= 1.1:
		_step_accum = 0.0
		world.tracks.add(species, str(def.get("track", "hoof")), global_position, rotation.y)


# ---------------------------------------------------------------- persistence (carcasses only)

func save_state() -> Dictionary:
	var p := global_position
	return {"species": String(species), "id": animal_id, "pos": [p.x, p.y, p.z], "yaw": rotation.y,
		"killed_by": String(killed_by)}
