class_name Animal
extends CharacterBody3D
## Wildlife agent (GDD §6, Phase 3). Perception-driven state machine — no omniscience:
##   sight (range, FOV, line of sight, player visibility), hearing (player noise), smell (wind-dependent).
## Prey:      IDLE/WANDER/GRAZE → ALERT → FLEE (alarms herd) → RECOVER
## Predator:  PATROL → SUSPICIOUS → INVESTIGATE → CHASE → ATTACK (wind-up) → gives up / RETREAT when hurt
##            also HUNT_PREY (deer, if the species hunts), afraid of fire/torches. Territorial ones (bear)
##            engage a player who comes too close. No teleporting, no permanent aggro.
## Defensive: grazes like prey, but warns (THREAT: faces you, stamps) and then charges (CHASE → ATTACK) a player
##            who keeps coming within `charge_range`, or charges at once when hurt; calms down after `give_up` s.
## Herds: followers keep near a leader, graze with their heads down (seeing less) and look up now and then; the
##        herd walks to water to DRINK, beds down to REST at night, and flees together in one direction.
## Predators: packs hunt together; they STALK (slow, low) before the sprint, bite prey repeatedly, then FEED at the
##        kill and guard it; they also come to carcasses left lying around. Wolves circle the player and take turns.

signal died(animal: Animal)

enum State { IDLE, WANDER, GRAZE, ALERT, FLEE, RECOVER, PATROL, SUSPICIOUS, INVESTIGATE, CHASE, ATTACK, HUNT_PREY, DEAD,
	REST, DRINK, FEED, THREAT, STALK,
	FREEZE, FORAGE, AMBUSH, DRAG, RING }  # species habits (world/animal_behavior.gd)
const HERD_RADIUS := 12.0       # followers drift back toward the leader beyond this
const LOOKUP_EVERY := Vector2(4.0, 9.0)  # grazing animals raise their heads every few seconds…
const LOOKUP_TIME := 1.6        # …and scan around for this long
const FEED_TIME := Vector2(70.0, 130.0)
const THREAT_TIME := 2.2        # warning display before a charge
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
## Needs, fear, temperament and memory (world/animal_mind.gd).
var mind := AnimalMind.new()
## Species habits (world/animal_behavior.gd).
var behavior := AnimalBehavior.new()
## A prey animal turned at bay: thinks like a defensive one until it breaks off.
var fighting := false
## Damage multiplier for the next blow (a smilodon's leap from cover).
var attack_bonus := 1.0

var _goal := Vector3.ZERO
var _speed := 0.0
var _think_t := 0.0
var _uptime := 0.0
var _attack_cd := 0.0
var _windup := -1.0
## The attack under way: clip, windup, damage multiplier, reach and frontal arc (see _pick_attack).
var _attack: Dictionary = {}
## The attack's forward travel: {start, end, speed, side} in seconds, m/s and degrees (empty: none).
var _lunge: Dictionary = {}
var _step_accum := 0.0
var _stuck_t := 0.0
var _last_pos := Vector3.ZERO
var _model: Node3D
var _anim: AnimationPlayer
var _cur_anim := ""
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var rng := RandomNumberGenerator.new()
var _bleed_t := 0.0
## Shove from a blow or a projectile (m/s, horizontal): braked on the feet, slid off by a carcass (HitPhysics).
var _push_v := Vector3.ZERO
## Staggered by a heavy shove: no steering and no attacking until it has its feet again.
var _stagger_t := 0.0
var _drip_accum := 0.0
var _lookup_t := 0.0     # >0 while a grazing animal has its head up, scanning
var _next_lookup := 0.0
var _flee_dir := Vector3.ZERO  # shared by the herd: everyone runs the same way
var _orbit := 1.0        # pack members circle the player clockwise or anticlockwise
var _feed_until := 0.0
var _carcass: Animal = null
var _bite_anim_t := 0.0
var _voice_next: Dictionary = {}  # event -> uptime when this animal may make that sound again
var _call_t := 0.0


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
	mind.init(def, rng)
	if hungry:
		mind.hunger = maxf(mind.hunger, 0.7)
	behavior.init(self)
	_next_lookup = rng.randf_range(LOOKUP_EVERY.x, LOOKUP_EVERY.y)
	_orbit = -1.0 if rng.randf() < 0.5 else 1.0


func is_predator() -> bool:
	return str(def.get("diet", "prey")) == "predator"


func is_defensive() -> bool:
	return str(def.get("diet", "prey")) == "defensive"


func is_prey() -> bool:
	return str(def.get("diet", "prey")) == "prey"


## Hostile right now (chasing or attacking) — used by the HUD danger cue.
func is_hostile() -> bool:
	return state in [State.CHASE, State.ATTACK] and (not is_prey() or fighting)


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
	# The body capsule sits at belly height; this small sphere under it is what stands on the ground
	# (without it the animal sank until the capsule touched the terrain — legs buried).
	var feet := CollisionShape3D.new()
	var ball := SphereShape3D.new()
	ball.radius = clampf(r * 0.6, 0.12, 0.5)
	feet.shape = ball
	feet.position = Vector3(0, ball.radius, 0)
	add_child(feet)
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
	# Body: baked PBR coat (albedo/normal/roughness) — used as imported. Fur cards: alpha-tested,
	# two-sided, and they don't cast shadows (dense cards would self-shadow to black).
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(s)
			if m is BaseMaterial3D and String(m.resource_name).ends_with("_Fur"):
				var d := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
				d.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				d.alpha_scissor_threshold = 0.42
				d.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_ALPHA_TO_COVERAGE
				d.cull_mode = BaseMaterial3D.CULL_DISABLED
				d.roughness = 0.85
				mi.set_surface_override_material(s, d)
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.visibility_range_end = 70.0  # silhouette fuzz only matters up close
				mi.visibility_range_end_margin = 8.0
				mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


# ---------------------------------------------------------------- perception

## Stimulus (0..1) the player currently produces for this animal.
func perceive_player(p: Node3D) -> float:
	if p == null or (p.get("dead") == true):
		return 0.0
	var to_p := p.global_position - global_position
	var d := to_p.length()
	var s := 0.0
	var vis: float = p.visibility_factor() if p.has_method("visibility_factor") else 1.0
	var sight := float(def.sight) * vis * _sight_factor()
	if d < sight:
		var fwd := -global_transform.basis.z
		var flat := Vector3(to_p.x, 0, to_p.z).normalized()
		var angle := rad_to_deg(Vector3(fwd.x, 0, fwd.z).normalized().angle_to(flat))
		if angle <= float(def.fov) * 0.5 and _line_of_sight(p.global_position + Vector3.UP * 1.2):
			s = maxf(s, 1.0 - d / sight)
	var noise: float = p.noise_level() if p.has_method("noise_level") else 0.3
	var hear := float(def.hearing) * noise * (0.7 if state == State.REST else 1.0)
	if d < hear:
		s = maxf(s, 0.85 * (1.0 - d / hear))
	if smells(p.global_position):
		s = maxf(s, 0.6 * (1.0 - d / float(def.smell)))
	return s


## Grazing with the head down or bedded down at night, an animal sees much less (sneak up then); while it has its
## head up scanning, it sees a little better than usual.
func _sight_factor() -> float:
	if state == State.REST:
		return 0.45
	if state in [State.GRAZE, State.DRINK, State.FEED]:
		return 1.15 if _lookup_t > 0.0 else 0.55
	return 1.0


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

func take_damage(amount: float, source: Node3D = null, hit_pos: Vector3 = Vector3.INF,
		_weapon: ItemData = null, heavy: bool = false) -> void:
	if is_dead():
		return
	var skels := _model.find_children("*", "Skeleton3D", true, false) if _model else []
	var region: StringName = BodyRegions.region_at(skels[0], hit_pos) if hit_pos != Vector3.INF and not skels.is_empty() else &"torso"
	var mult := 2.2 if region == &"head" else (0.75 if region != &"torso" else 1.0)
	if heavy:
		mult *= 1.0
	health -= amount * mult
	mind.hurt(global_position, source != null and source.is_in_group("player"), _uptime)
	var at := hit_pos if hit_pos != Vector3.INF else global_position + Vector3.UP * float(def.get("height", 1.0)) * 0.6
	Gore.burst(world, at, Vector3.UP, 14)
	_bleed_t = 120.0  # leaves a blood trail for a while (tracking)
	_flinch()
	if health <= 0.0:
		die(&"player" if source and source.is_in_group("player") else &"other")
		return
	voice(&"hurt", 1.5)
	if source:
		threat = source
		last_known = source.global_position
	if is_predator():
		if health < max_health * float(def.get("flee_health", 0.4)):
			calm_until = _uptime + 120.0
			_set_state(State.FLEE)
		elif source and (source.is_in_group("player") or source is HumanNPC):
			awareness = 1.0
			_set_state(State.CHASE)
	elif is_defensive():
		if health < max_health * float(def.get("flee_health", 0.25)):
			calm_until = _uptime + 120.0
			_set_state(State.FLEE)
		elif source and (source.is_in_group("player") or source is HumanNPC):
			awareness = 1.0
			calm_until = 0.0
			_set_state(State.CHASE)
	else:
		_alarm_herd(source)
		_set_state(State.FLEE)


## A blow's momentum `j` (N·s) along `dir`: shoves the body by its mass, and a hard shove staggers a living one
## (a club knocks a wolf back; a mammoth hardly moves).
func hit_impulse(j: float, dir: Vector3) -> void:
	var dv := HitPhysics.push_velocity(j, dir, HitPhysics.species_mass(species))
	_push_v = (_push_v + dv).limit_length(HitPhysics.MAX_PUSH)
	if not is_dead() and dv.length() > HitPhysics.STAGGER_PUSH:
		_stagger_t = maxf(_stagger_t, clampf(dv.length() * 0.18, 0.2, 0.9))
		_bite_anim_t = 0.0
		if state == State.ATTACK and _windup >= 0.0:
			_windup = -1.0  # the bite or lunge is broken off before it lands
			_lunge = {}
			_attack_cd = maxf(_attack_cd, 0.8)


## Knocked off balance (a parried bite or lunge): no attacking or steering for a moment.
func stagger(seconds: float) -> void:
	if is_dead():
		return
	_stagger_t = maxf(_stagger_t, seconds)
	_bite_anim_t = 0.0
	if state == State.ATTACK:
		_windup = -1.0
		_lunge = {}
		_attack_cd = maxf(_attack_cd, seconds)
	_flinch()


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
	voice(&"death", 10.0)
	if world:
		Gore.decal(world, global_position, 0.9)
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
	var share := 0.5 if ItemDB.animals.has(killed_by) else 1.0  # a predator already ate part of it
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
			var lead := leader()
			if lead != self and lead and not is_predator():
				# followers wander to a spot near the leader (the herd moves as one)
				var a := rng.randf() * TAU
				_goal = lead.global_position + Vector3(cos(a), 0, sin(a)) * rng.randf_range(3.0, 8.0)
			else:
				var radius := 60.0 if is_predator() else 22.0
				for attempt in 5:   # not back to where it met danger
					var a := rng.randf() * TAU
					_goal = home + Vector3(cos(a), 0, sin(a)) * rng.randf_range(radius * 0.3, radius)
					if not mind.near_danger(_goal, _uptime):
						break
		State.DRINK:
			_goal = _water_near()
		State.FEED:
			_feed_until = _uptime + rng.randf_range(FEED_TIME.x, FEED_TIME.y)
		State.THREAT:
			if is_defensive():
				voice(&"stamp", 2.0)
			else:
				voice(&"roar" if species in [&"lion", &"bear", &"smilodon"] else &"growl", 2.0)
	behavior.on_state(self, s)


func _physics_process(delta: float) -> void:
	_uptime += delta
	if not is_on_floor():
		velocity.y -= _gravity * delta
	if is_dead():
		# a carcass keeps the momentum of the killing blow, slides off steep ground and lies along the slope
		if world:
			var n := HitPhysics.ground_normal(world, global_position.x, global_position.z)
			_push_v = HitPhysics.corpse_slide(_push_v, n, delta) if is_on_floor() else _push_v
			HitPhysics.align_to_ground(_model, self, n, 1.0, delta)
		velocity.x = _push_v.x
		velocity.z = _push_v.z
		move_and_slide()
		return
	if _stagger_t > 0.0:
		# knocked off its stride: carried by the shove, braking on its feet
		_stagger_t -= delta
		_push_v = HitPhysics.brake(_push_v, HitPhysics.FEET_BRAKE * 0.6, delta)
		_speed = 0.0
		velocity.x = _push_v.x
		velocity.z = _push_v.z
		move_and_slide()
		_animate()
		return
	state_time += delta
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	_lookup_t = maxf(_lookup_t - delta, 0.0)
	_bite_anim_t = maxf(_bite_anim_t - delta, 0.0)
	if state in [State.GRAZE, State.DRINK, State.FEED]:
		_next_lookup -= delta
		if _next_lookup <= 0.0:
			_lookup_t = LOOKUP_TIME
			_next_lookup = rng.randf_range(LOOKUP_EVERY.x, LOOKUP_EVERY.y)
	_think_t -= delta
	if _think_t <= 0.0:
		_think(THINK_INTERVAL)
		_think_t = THINK_INTERVAL
	_update_attack(delta)
	_move(delta)
	behavior.physics(self, delta)
	_animate()
	_leave_tracks(delta)


func _think(dt: float) -> void:
	_ambient_voice(dt)
	var p := _player()
	var stim := perceive_player(p) if p else 0.0
	if stim > 0.0:
		awareness = minf(awareness + stim * dt * 3.0, 1.0)
		last_known = p.global_position
		if not is_predator():
			mind.scare(stim * dt * 0.35)   # being watched by a person unsettles prey and herds
	else:
		awareness = maxf(awareness - 0.12 * dt, 0.0)
	mind.update(dt, state, _speed > float(def.walk) * 1.6, not is_predator())
	if is_predator() and mind.hunger > 0.65:
		hungry = true
	if behavior.think(self, dt, p, stim):
		return
	if is_predator():
		_think_predator(dt, p, stim)
	elif is_defensive():
		_think_defensive(dt, p, stim)
	else:
		_think_prey(dt, p, stim)


func _think_prey(_dt: float, p: Node3D, stim: float) -> void:
	var d := p.global_position.distance_to(global_position) if p else INF
	match state:
		State.IDLE, State.GRAZE, State.WANDER, State.REST, State.DRINK:
			var person := _person_close(10.0)
			var hunter := _predator_near()
			if hunter:
				mind.scare(0.5)
				mind.remember_danger(hunter.global_position, _uptime)
				_alarm_herd(hunter)
				threat = hunter
				_set_state(State.FLEE)
			elif awareness > mind.alert_threshold(0.5 if state == State.REST else 0.35, _uptime):
				threat = p
				_set_state(State.ALERT)
				_herd_alert(p)
			elif person:
				threat = person
				_set_state(State.ALERT)
				_herd_alert(person)
			else:
				_herd_routine()
		State.ALERT:
			if threat is HumanNPC and is_instance_valid(threat) and threat.global_position.distance_to(global_position) < 8.0:
				_alarm_herd(threat)
				_set_state(State.FLEE)
			elif awareness > mind.alert_threshold(0.8, _uptime) or (d < 12.0 + 10.0 * mind.fear and stim > 0.2):
				mind.remember_danger(p.global_position, _uptime)
				_alarm_herd(p)
				_set_state(State.FLEE)
			elif awareness < 0.15 and state_time > 4.0:
				_set_state(State.GRAZE)
		State.FLEE:
			var hunter := _predator_near()
			if hunter and hunter != threat and (threat == null or not is_instance_valid(threat)
					or hunter.global_position.distance_to(global_position) < threat.global_position.distance_to(global_position)):
				threat = hunter  # run from whatever is closest on our heels
			var far := threat == null or threat.global_position.distance_to(global_position) > 60.0
			if (far and state_time > 6.0) or state_time > 22.0:
				_set_state(State.RECOVER)
		State.RECOVER:
			_flee_dir = Vector3.ZERO
			var hunter := _predator_near()
			if hunter:
				_alarm_herd(hunter)
				threat = hunter
				_set_state(State.FLEE)
			elif awareness > 0.6:
				_set_state(State.FLEE)
			elif state_time > 12.0:
				home = global_position
				_set_state(State.GRAZE)


## Makes a sound (Sfx.play_animal: a dropped-in recording if there is one, and a subtitle), at most once per
## `cooldown` seconds per kind of sound.
func voice(event: StringName, cooldown := 4.0) -> void:
	if _uptime < float(_voice_next.get(event, -1.0)) or not is_inside_tree():
		return
	_voice_next[event] = _uptime + cooldown
	Sfx.play_animal(species, event, global_position + Vector3.UP * float(def.get("height", 1.0)) * 0.8)


## Calls now and then: herds while grazing, a wolf pack howling at night (one starts, the others join in).
func _ambient_voice(dt: float) -> void:
	_call_t -= dt
	if _call_t > 0.0:
		return
	_call_t = rng.randf_range(50.0, 140.0)
	if species == &"wolf":
		if _is_night() and state in [State.PATROL, State.IDLE] and leader() == self:
			voice(&"howl", 30.0)
			for m: Animal in _herd_members():
				if m != self:
					m.get_tree().create_timer(rng.randf_range(0.8, 3.0)).timeout.connect(func() -> void:
						if is_instance_valid(m) and not m.is_dead():
							m.voice(&"howl", 30.0))
	elif state in [State.GRAZE, State.WANDER, State.IDLE] and not is_predator():
		voice(&"call", 30.0)
	elif state == State.FEED:
		voice(&"eat", 3.0)


## A predator that is hunting (or simply close) and that this animal notices: a stalking one only from close up,
## one in full sprint from much further; any predator walking right up to it.
func _predator_near() -> Animal:
	var best: Animal = null
	var best_d := INF
	for a: Animal in get_tree().get_nodes_in_group("animal"):
		if a == self or a.is_dead() or not a.is_predator():
			continue
		var d := a.global_position.distance_to(global_position)
		var notice := 9.0
		if a.state in [State.HUNT_PREY, State.CHASE, State.ATTACK]:
			notice = float(def.sight) * 0.8 * _sight_factor()
		elif a.state == State.STALK:
			notice = 15.0 * _sight_factor()
		if d < notice and d < best_d and (d < 10.0 or _line_of_sight(a.global_position + Vector3.UP * 0.6) or smells(a.global_position)):
			best = a
			best_d = d
	return best


# ---------------------------------------------------------------- herd life

func _herd_members() -> Array:
	return herd.filter(func(a: Variant) -> bool: return is_instance_valid(a) and not (a as Animal).is_dead())


## The herd's leader: the living member with the lowest id (stable, no negotiation needed).
func leader() -> Animal:
	var best: Animal = self
	for a: Animal in _herd_members():
		if a.animal_id < best.animal_id:
			best = a
	return best


func _is_night() -> bool:
	return world != null and world.day_night != null and world.day_night.is_night()


## Calm-time behaviour shared by prey and defensive herds: graze near the leader, look up now and then, go to
## water when thirsty (the leader decides, the herd follows), bed down at night and get up at dawn.
func _herd_routine() -> void:
	var lead := leader()
	var near_lead := lead == self or global_position.distance_to(lead.global_position) < HERD_RADIUS
	if _is_night():
		if state != State.REST and near_lead:
			_set_state(State.REST)
		elif not near_lead and state != State.WANDER:
			_set_state(State.WANDER)
		return
	if state == State.REST:
		_set_state(State.GRAZE)
		return
	if lead == self and state != State.DRINK and mind.thirst > 0.7:
		var w := _water_near()
		if w == Vector3.INF:
			mind.thirst = 0.3   # no water in reach: try again later
		else:
			_drink_at(w)
			for m: Animal in _herd_members():
				if m != self and m.state in [State.IDLE, State.GRAZE, State.WANDER]:
					m._drink_at(w + Vector3(rng.randf_range(-6, 6), 0, rng.randf_range(-6, 6)))
			return
	match state:
		State.DRINK:
			if state_time > 60.0 or (_arrived(2.5) and mind.thirst < 0.05):
				_set_state(State.GRAZE)
		State.GRAZE:
			if not near_lead:
				_set_state(State.WANDER)
			elif state_time > rng.randf_range(6.0, 14.0):
				_set_state(State.WANDER)
		State.IDLE:
			if state_time > 5.0:
				_set_state(State.GRAZE)
		State.WANDER:
			if _arrived(1.5) or state_time > 25.0:
				_set_state(State.IDLE if rng.randf() < 0.4 else State.GRAZE)


func _drink_at(w: Vector3) -> void:
	_set_state(State.DRINK)
	_goal = w


func _arrived(r: float) -> bool:
	return Vector2(global_position.x - _goal.x, global_position.z - _goal.z).length() < r


## The nearest spot on dry ground right at the waterline within ~180 m, or Vector3.INF.
func _water_near() -> Vector3:
	if world == null:
		return Vector3.INF
	var p := global_position
	var r := 10.0
	while r <= 180.0:
		for k in 16:
			var a := TAU * k / 16.0 + r * 0.01
			var x := p.x + cos(a) * r
			var z := p.z + sin(a) * r
			var h := world.height_at(x, z)
			if h > ForestWorld.WATER_LEVEL + 0.05 and h < ForestWorld.WATER_LEVEL + 0.6:
				return world.ground_point(x, z)
		r += 10.0
	return Vector3.INF


## Herd mates look up at a threat one of them noticed (defensive herds turn to face it, prey get ready to run).
func _herd_alert(source: Node3D) -> void:
	for a: Animal in _herd_members():
		if a != self and a.state in [State.IDLE, State.GRAZE, State.WANDER, State.REST, State.DRINK] \
				and a.global_position.distance_to(global_position) < 35.0:
			a.threat = source
			a.last_known = source.global_position if source else a.last_known
			a.awareness = maxf(a.awareness, 0.5)
			a._set_state(State.ALERT)


## Keeps a little space from herd mates (running herds don't pile into one another).
func _separation() -> Vector3:
	var push := Vector3.ZERO
	for a: Animal in _herd_members():
		if a == self:
			continue
		var off := global_position - a.global_position
		off.y = 0.0
		var d := off.length()
		var r := float(def.get("radius", 0.4)) * 4.0 + 1.0
		if d > 0.01 and d < r:
			push += off / d * (1.0 - d / r)
	return push


func _think_predator(_dt: float, p: Node3D, stim: float) -> void:
	var d := p.global_position.distance_to(global_position) if p else INF
	var near_fire := _fire_near(p.global_position if p else global_position)
	var may_engage := _uptime >= calm_until
	if threat is HumanNPC and is_instance_valid(threat) and state in [State.CHASE, State.ATTACK]:
		# Hunting a person: distances and fire are measured at them, not at the player.
		d = threat.global_position.distance_to(global_position)
		near_fire = _fire_near(threat.global_position)
		if (threat as HumanNPC).is_dead():
			hungry = false
			calm_until = _uptime + 90.0
			_set_state(State.IDLE)
			return
	match state:
		State.PATROL, State.IDLE:
			var prey := _find_prey()
			var person := _find_person() if may_engage else null
			var carcass := _find_carcass() if hungry else null
			var lead := leader()
			if hungry and prey:
				_start_hunt(prey)
			elif carcass:
				_carcass = carcass
				_set_state(State.FEED)
			elif person:
				threat = person
				_set_state(State.CHASE)
			elif may_engage and awareness > 0.4:
				_set_state(State.SUSPICIOUS)
			elif lead != self and global_position.distance_to(lead.global_position) > 25.0 and state == State.IDLE:
				_goal = lead.global_position + Vector3(rng.randf_range(-6, 6), 0, rng.randf_range(-6, 6))
				state = State.PATROL  # keep the goal: walk back to the pack
				state_time = 0.0
			elif state == State.PATROL and (global_position.distance_to(_goal) < 2.0 or state_time > 40.0):
				_set_state(State.IDLE)
			elif state == State.IDLE and state_time > rng.randf_range(4.0, 9.0) and (hungry or mind.fatigue < 0.75):
				_set_state(State.PATROL)   # a tired, fed predator lies up instead of roaming
		State.SUSPICIOUS:
			if awareness > 0.65:
				_set_state(State.INVESTIGATE)
			elif awareness < 0.2 and state_time > 5.0:
				_set_state(State.PATROL)
		State.INVESTIGATE:
			if stim > 0.35 and d < 22.0 and _wants_to_attack(p) and not near_fire:
				threat = p
				_pack_call(p)
				var only_territory := not hungry and not _is_night() and health >= max_health
				if only_territory and d > 6.0:
					_set_state(State.THREAT)   # a bear or a cat warns an intruder before it charges
				else:
					_set_state(State.STALK if d > 14.0 else State.CHASE)
			elif global_position.distance_to(last_known) < 2.5 or state_time > 18.0:
				_set_state(State.PATROL)
		State.STALK:
			if threat == null or not is_instance_valid(threat) or (threat is Animal and (threat as Animal).is_dead()):
				_set_state(State.PATROL)
				return
			var dt := threat.global_position.distance_to(global_position)
			var sprint := float(def.get("pounce", 14.0))
			if threat is Animal:
				if dt < sprint or (threat as Animal).state in [State.ALERT, State.FLEE]:
					_set_state(State.HUNT_PREY)
				elif dt > 70.0 or state_time > 45.0:
					_set_state(State.PATROL)
			else:
				if _fire_near(threat.global_position):
					calm_until = _uptime + 30.0
					_set_state(State.PATROL)
				elif dt < sprint * 0.85 or awareness > 0.95 and dt < sprint * 1.5:
					_set_state(State.CHASE)
				elif dt > 50.0 or state_time > 40.0:
					_set_state(State.PATROL)
		State.CHASE:
			if threat == null or not is_instance_valid(threat):
				_set_state(State.PATROL)
			elif state_time > float(def.give_up) or d > 45.0 or (threat == p and p and p.get("dead") == true):
				calm_until = _uptime + 60.0
				_set_state(State.PATROL)
			elif near_fire and d < float(def.fire_fear):
				calm_until = _uptime + 30.0
				_set_state(State.FLEE)
			elif d <= _reach() and _attack_cd <= 0.0:
				_set_state(State.ATTACK)
		State.ATTACK:
			if _windup < 0.0 and state_time > float(_attack.get("hold", 0.9)):
				_set_state(State.CHASE if threat else State.PATROL)
		State.HUNT_PREY:
			if threat == null or not is_instance_valid(threat) or state_time > 35.0:
				_set_state(State.PATROL)
			elif threat is Animal and (threat as Animal).is_dead():
				_carcass = threat
				_set_state(State.FEED)
			elif threat.global_position.distance_to(global_position) < float(def.attack_range) + 0.8:
				if _attack_cd <= 0.0:
					_bite(threat as Animal)
			elif awareness > 0.7 and may_engage and d < 15.0 and _wants_to_attack(p):
				threat = p  # someone right next to the chase draws the attack
				_set_state(State.CHASE)
		State.FEED:
			if _carcass == null or not is_instance_valid(_carcass) or _carcass.butchered:
				hungry = false
				_set_state(State.PATROL)
			elif _uptime > _feed_until:
				hungry = false
				mind.eat()
				calm_until = _uptime + 60.0
				_set_state(State.PATROL)
			elif p and stim > 0.15 and d < 12.0:
				# someone comes for the kill: fire drives it off, otherwise it guards the carcass
				if near_fire:
					calm_until = _uptime + 30.0
					_set_state(State.FLEE)
				else:
					threat = p
					_set_state(State.CHASE if d < 5.0 else State.THREAT)
		State.THREAT:
			_think_threat(p, d, 5.5, 16.0, State.FEED if _carcass and is_instance_valid(_carcass) else State.PATROL)
		State.FLEE:
			if state_time > 14.0:
				_set_state(State.RECOVER)
		State.RECOVER:
			if state_time > 10.0:
				home = global_position
				_set_state(State.PATROL)


## Warning display (a growl, a stamp, the head low): charge if the intruder comes closer or stays, calm down
## and go back to `back_to` if it backs off.
func _think_threat(p: Node3D, d: float, close: float, leave: float, back_to: State) -> void:
	if p == null or p.get("dead") == true:
		_set_state(back_to)
	elif _fire_near(p.global_position) and d < float(def.get("fire_fear", 6.0)):
		calm_until = _uptime + 30.0
		_set_state(State.FLEE)
	elif d < close and state_time > 0.5:
		threat = p
		calm_until = 0.0
		_set_state(State.CHASE)
	elif d > leave and state_time > 1.0:
		_set_state(back_to)
	elif state_time > THREAT_TIME and d < close * 1.6:
		threat = p
		_set_state(State.CHASE)
	elif state_time > THREAT_TIME * 2.5:
		_set_state(back_to)


func _start_hunt(prey: Animal) -> void:
	threat = prey
	_set_state(State.STALK)
	_pack_call(prey)


## Pack mates nearby join the hunt (or the fight).
func _pack_call(target: Node3D) -> void:
	for m: Animal in _herd_members():
		if m == self or m.global_position.distance_to(global_position) > 80.0:
			continue
		if m.state in [State.PATROL, State.IDLE, State.SUSPICIOUS, State.INVESTIGATE]:
			m.threat = target
			m.hungry = m.hungry or target is Animal
			m.last_known = target.global_position
			m._set_state(State.STALK)


## A bite on prey: real damage (it bleeds and runs), not an instant kill. A kill is the predator's.
func _bite(prey: Animal) -> void:
	_attack_cd = float(def.attack_cooldown) * 0.8
	_bite_anim_t = 0.45
	voice(&"attack", 0.8)
	var at := prey.global_position + Vector3.UP * float(prey.def.get("height", 1.0)) * 0.6
	prey.take_damage(float(def.damage) * 1.5 * attack_bonus, self, at)
	attack_bonus = 1.0
	if prey.is_dead() and prey.killed_by != &"player":
		prey.killed_by = species


## A carcass worth eating within smelling distance (not another predator, not yet butchered).
func _find_carcass() -> Animal:
	var best: Animal = null
	var best_d := float(def.get("smell", 60.0))
	for a: Node in get_tree().get_nodes_in_group("carcass"):
		var c := a as Animal
		if c == null or c == self or c.butchered or not c.is_dead() or not c.is_prey() and not c.is_defensive():
			continue
		var d := c.global_position.distance_to(global_position)
		if d < best_d and (smells(c.global_position) or d < 25.0):
			best = c
			best_d = d
	return best


## Predators commit to the player only with a reason: hungry, night, a weak player, provoked, or (territorial
## species) the player came too close.
func _wants_to_attack(p: Node3D) -> bool:
	if p == null:
		return false
	var night: bool = world.day_night.is_night() if world else false
	var weak: bool = p.get("stats") != null and p.stats.health < 60.0
	var intruder := p.global_position.distance_to(global_position) < float(def.get("territory", 0.0))
	return hungry or night or weak or intruder or health < max_health or mind.wants_revenge(_uptime)


func _think_defensive(_dt: float, p: Node3D, stim: float) -> void:
	var d := p.global_position.distance_to(global_position) if p else INF
	if threat is HumanNPC and is_instance_valid(threat) and state in [State.CHASE, State.ATTACK]:
		d = threat.global_position.distance_to(global_position)
		if (threat as HumanNPC).is_dead():
			_set_state(State.RECOVER)
			return
	var charge := float(def.get("charge_range", 8.0))
	var may_engage := _uptime >= calm_until
	match state:
		State.IDLE, State.GRAZE, State.WANDER, State.REST, State.DRINK:
			if awareness > mind.alert_threshold(0.5 if state == State.REST else 0.35, _uptime):
				threat = p
				_set_state(State.ALERT)
				_herd_alert(p)
			else:
				_herd_routine()
		State.ALERT:
			var fire := _fire_near(p.global_position if p else global_position)
			if mind.fear > 0.85 and health < max_health * 0.5:
				threat = p
				_alarm_herd(p)   # badly hurt and frightened: the herd runs instead of standing its ground
				_set_state(State.FLEE)
			elif may_engage and mind.wants_revenge(_uptime) and d < charge * 2.0 and stim > 0.1 and not fire:
				threat = p
				_set_state(State.CHASE)   # it remembers who hurt it: no warning this time
			elif may_engage and d < charge * 1.6 and stim > 0.1 and not fire:
				threat = p
				_set_state(State.THREAT)
			elif awareness < 0.15 and state_time > 5.0:
				_set_state(State.GRAZE)
		State.THREAT:
			_think_threat(p, d, charge, charge * 2.2, State.ALERT)
		State.CHASE:
			if threat == null or not is_instance_valid(threat) or (p and p.get("dead") == true):
				_set_state(State.GRAZE)
			elif state_time > float(def.get("give_up", 10.0)) or d > charge * 3.0:
				calm_until = _uptime + 45.0
				_set_state(State.RECOVER)
			elif _fire_near(threat.global_position if threat and is_instance_valid(threat) else global_position) and d < float(def.get("fire_fear", 6.0)):
				calm_until = _uptime + 30.0
				_set_state(State.FLEE)
			elif d <= _reach() and _attack_cd <= 0.0:
				_set_state(State.ATTACK)
		State.ATTACK:
			if _windup < 0.0 and state_time > float(_attack.get("hold", 1.2)):
				_set_state(State.CHASE if threat else State.GRAZE)
		State.FLEE:
			if state_time > 10.0:
				_set_state(State.RECOVER)
		State.RECOVER:
			if state_time > 12.0:
				home = global_position
				_set_state(State.GRAZE)


func _fire_near(pos: Vector3) -> bool:
	if world == null:
		return false
	if world.get_warmth_at(pos) > 5.0:
		return true
	var p := _player()
	return p != null and p.get("inventory") != null and p.inventory.hand != null and p.inventory.hand.id == &"torch" \
		and p.global_position.distance_to(pos) < 1.0


func _find_prey() -> Animal:
	if not bool(def.get("hunts", true)):
		return null
	var best: Animal = null
	var best_d := float(def.sight)
	for a: Animal in get_tree().get_nodes_in_group("animal"):
		if a == self or not a.is_prey() or a.is_dead() or a.max_health > float(def.get("max_prey_health", 1e9)):
			continue
		var d := a.global_position.distance_to(global_position)
		if d >= float(def.sight) or not (_line_of_sight(a.global_position + Vector3.UP) or smells(a.global_position)):
			continue
		var score := behavior.prey_score(self, a, d)
		if score < best_d:
			best = a
			best_d = score
	return best


## A tribesperson walking up close (prey animals don't let hunters stroll in).
func _person_close(radius: float) -> HumanNPC:
	for n: HumanNPC in get_tree().get_nodes_in_group("npc"):
		if not n.is_dead() and n.global_position.distance_to(global_position) < radius:
			return n
	return null


## A person worth attacking: wolves and cats on a hungry day or at night go for someone alone and away from
## the fire. Bears (territorial, not hunters) only answer people who come too close.
func _find_person() -> HumanNPC:
	var night: bool = world.day_night.is_night() if world else false
	var hunts := bool(def.get("hunts", true))
	var best: HumanNPC = null
	var best_d := float(def.sight) * (0.6 if night else 0.45)
	for n: HumanNPC in get_tree().get_nodes_in_group("npc"):
		if n.is_dead():
			continue
		var d := n.global_position.distance_to(global_position)
		var intruder := d < float(def.get("territory", 0.0))
		if d >= best_d or not (intruder or (hunts and (hungry or night))) or _fire_near(n.global_position):
			continue
		var company := 0
		for m: HumanNPC in get_tree().get_nodes_in_group("npc"):
			if m != n and not m.is_dead() and m.armed and m.global_position.distance_to(n.global_position) < 8.0:
				company += 1
		if company >= 2 and max_health < 200.0 and not intruder:
			continue  # a wolf won't take on an armed group
		if _line_of_sight(n.global_position + Vector3.UP):
			best = n
			best_d = d
	return best


## The whole herd bolts the same way: away from the threat, as seen from the herd's centre.
func _alarm_herd(source: Node3D) -> void:
	var members := _herd_members()
	if not members.has(self):
		members.append(self)
	var centre := Vector3.ZERO
	for a: Animal in members:
		centre += a.global_position
	centre /= float(members.size())
	var from := source.global_position if source else global_position - global_transform.basis.z
	var away := centre - from
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else Vector3(1, 0, 0)
	away = away.rotated(Vector3.UP, rng.randf_range(-0.35, 0.35))
	voice(&"alarm", 6.0)
	for a: Animal in members:
		a._flee_dir = away
		if a != self and a.state != State.FLEE and a.global_position.distance_to(global_position) < 35.0:
			a.threat = source
			a.awareness = 1.0
			a._set_state(State.FLEE)


# ---------------------------------------------------------------- attack

func _update_attack(delta: float) -> void:
	if state != State.ATTACK:
		_windup = -1.0
		return
	if _windup < 0.0 and state_time < 0.05:
		_attack = _pick_attack()
		_windup = float(_attack.windup)
		_lunge = {}
		if _attack.has("lunge") and threat and is_instance_valid(threat):
			# [start s, end s, max metres, side degrees]: travel to just short of the target, never past it
			var spec: Array = _attack.lunge
			var gap := threat.global_position.distance_to(global_position) - float(_attack.get("stop", 0.9))
			var dist := clampf(gap, 0.0, float(spec[2]))
			if dist > 0.05:
				_lunge = {"start": float(spec[0]), "end": float(spec[1]), "side": float(spec[3]) if spec.size() > 3 else 0.0,
					"speed": dist / maxf(float(spec[1]) - float(spec[0]), 0.05)}
		_cur_anim = ""  # the same move twice in a row starts over
		_play(String(_attack.clip), false)
		voice(&"attack", 0.8)
	if _windup >= 0.0:
		_windup -= delta
		if _windup < 0.0:
			_attack_cd = float(def.attack_cooldown) * float(_attack.get("cooldown", 1.0))
			var reach := float(_attack.range) + 0.5
			var arc := float(_attack.arc)
			var damage := float(def.damage) * float(_attack.damage) * attack_bonus
			attack_bonus = 1.0
			var p := _player()
			if p and threat == p and p.global_position.distance_to(global_position) <= reach:
				var dir := (p.global_position - global_position).normalized()
				if (-global_transform.basis.z).dot(dir) > arc and p.has_method("take_hit"):
					p.take_hit(damage, species, float(_attack.get("bleed", def.get("bleed_chance", 0.0))), global_position, self)
			elif threat is HumanNPC and is_instance_valid(threat) and not (threat as HumanNPC).is_dead() \
					and threat.global_position.distance_to(global_position) <= reach:
				var to_n := (threat.global_position - global_position).normalized()
				if (-global_transform.basis.z).dot(to_n) > arc:
					(threat as HumanNPC).take_damage(damage, self, threat.global_position + Vector3.UP * 1.0)


## How close it has to be to start an attack: the longest reach among its moves (a wolf can leap from further
## than it can bite).
func _reach() -> float:
	var r := float(def.attack_range)
	for m: Dictionary in def.get("attacks", []):
		if _anim == null or _anim.has_animation(String(m.clip)):
			r = maxf(r, float(m.get("range", r)))
	return r


## One attack move. A species may list several in data/animals.json "attacks": each {clip, windup (seconds to
## the blow), damage (× damage), range, arc (min. facing dot toward the target: lower = wider), weight,
## cooldown (× attack_cooldown)}. A move is drawn by weight among those that reach the target and whose clip
## exists; without a list it is the plain "attack" clip with the species' own windup and range. Optional "bleed"
## overrides the species' bleed_chance for that move; "lunge" [start, end, max m, side deg] carries the animal in
## (it stops "stop" metres short of the target); "hold": seconds before it may break off.
func _pick_attack() -> Dictionary:
	var move := {"clip": "attack", "windup": float(def.attack_windup), "damage": 1.0,
		"range": float(def.attack_range), "arc": 0.4}
	var moves: Array = def.get("attacks", [])
	if moves.is_empty():
		return move
	var d := threat.global_position.distance_to(global_position) if threat and is_instance_valid(threat) else 0.0
	var pool: Array[Dictionary] = []
	var total := 0.0
	for m: Dictionary in moves:
		if _anim and not _anim.has_animation(String(m.clip)):
			continue
		if d > float(m.get("range", def.attack_range)) + 0.5:
			continue
		pool.append(m)
		total += float(m.get("weight", 1.0))
	if pool.is_empty():
		return move
	var pick := randf() * total
	for m in pool:
		pick -= float(m.get("weight", 1.0))
		if pick <= 0.0:
			return move.merged(m, true)
	return move.merged(pool[-1], true)


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
			var away := global_position - from
			away.y = 0.0
			away = away.normalized() if away.length() > 0.01 else -global_transform.basis.z
			dir = away if _flee_dir == Vector3.ZERO else _flee_dir * 0.6 + away * 0.4
			dir += _separation() * 0.8
			# prey can't sprint for long: after a few seconds it slows down (wolves, built for endurance, close
			# in); a wounded animal tires even faster
			var tire := smoothstep(5.0, 14.0, state_time * (1.6 if health < max_health * 0.6 else 1.0))
			speed = run * (lerpf(1.0, 0.68, tire) if is_prey() else 1.0) * mind.stamina()
		State.RECOVER:
			dir = -global_transform.basis.z
			speed = walk * 0.8
		State.INVESTIGATE:
			dir = last_known - global_position
			speed = walk * 1.3
		State.DRINK:
			if not _arrived(2.0):
				dir = _goal - global_position
				speed = walk
		State.REST:
			var lead := leader()
			if lead != self and global_position.distance_to(lead.global_position) > HERD_RADIUS * 0.8:
				dir = lead.global_position - global_position
				speed = walk
		State.FEED:
			if _carcass and is_instance_valid(_carcass):
				dir = _carcass.global_position - global_position
				var dc := dir.length()
				speed = 0.0 if dc < float(def.get("length", 1.2)) * 0.6 + 1.0 else (walk * 2.0 if dc > 20.0 else walk)
		State.STALK:
			if threat and is_instance_valid(threat):
				dir = threat.global_position - global_position
				# pack mates spread out to come at it from the sides
				var lead := leader()
				if lead != self:
					dir = dir.rotated(Vector3.UP, 0.5 * _orbit)
				speed = walk * 0.8
		State.THREAT:
			if threat and is_instance_valid(threat):
				dir = threat.global_position - global_position
				# bluff: a short step forward every second or so
				speed = walk * 0.9 if fmod(state_time, 1.3) < 0.35 else 0.0
		State.CHASE:
			if threat and is_instance_valid(threat):
				dir = threat.global_position - global_position
				var d := dir.length()
				speed = run * mind.stamina() if d > float(def.attack_range) else 0.0
				# a pack doesn't all bite at once: between bites wolves circle round their target
				if _herd_members().size() > 1 and _attack_cd > 0.25 and d < 9.0:
					var flat := Vector3(dir.x, 0.0, dir.z).normalized()
					dir = flat.cross(Vector3.UP) * _orbit + flat * clampf((d - 5.5) * 0.4, -0.6, 0.6)
					speed = walk * 2.4
		State.HUNT_PREY:
			if threat and is_instance_valid(threat):
				dir = threat.global_position - global_position
				speed = run if dir.length() > float(def.attack_range) * 0.8 else walk
		State.ALERT, State.SUSPICIOUS, State.ATTACK:
			var look := last_known if state != State.ATTACK or threat == null else threat.global_position
			dir = look - global_position
			speed = 0.0
			if state == State.ATTACK and not _lunge.is_empty() \
					and state_time >= float(_lunge.start) and state_time <= float(_lunge.end):
				dir = dir.rotated(Vector3.UP, deg_to_rad(float(_lunge.side)))
				speed = float(_lunge.speed)   # the lunge or leap carries it in (it lands where it jumped)
	dir.y = 0.0
	return behavior.desired(self, {"dir": dir.normalized() if dir.length() > 0.01 else Vector3.ZERO, "speed": speed})


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
	if state == State.ATTACK and speed > 0.0:
		_speed = speed * align   # a lunge starts at full speed
	else:
		_speed = move_toward(_speed, speed * align, (8.0 if speed > _speed else 10.0) * delta)
	_push_v = HitPhysics.brake(_push_v, HitPhysics.FEET_BRAKE, delta)
	velocity.x = facing.x * _speed + _push_v.x
	velocity.z = facing.z * _speed + _push_v.z
	move_and_slide()
	if world and _model:
		HitPhysics.align_to_ground(_model, self, HitPhysics.ground_normal(world, global_position.x, global_position.z), 0.45, delta)
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
	if _bite_anim_t > 0.0:
		_play("attack", false)
		return
	if behavior.animate(self):
		return
	match state:
		State.ATTACK:
			return
		State.GRAZE:
			_play("alert" if _lookup_t > 0.0 else "graze")
			return
		State.DRINK, State.FEED:
			if _speed < 0.3:
				_play("alert" if _lookup_t > 0.0 else "graze")
				return
		State.ALERT, State.SUSPICIOUS, State.THREAT:
			if _speed < 0.3:
				_play("alert")
				return
		State.REST:
			if _speed < 0.3:
				_play("idle")
				_anim.speed_scale = 0.35  # slow, sleepy breathing
				return
	if _speed > float(def.walk) * 1.6:
		_play("run")
		_anim.speed_scale = clampf(_speed / float(def.run), 0.6, 1.4)
	elif _speed > 0.3:
		_play("walk")
		_anim.speed_scale = clampf(_speed / float(def.walk), 0.5, 1.8)
	else:
		_play("idle")


func _play(name: String, blend: bool = true) -> void:
	if _anim == null or _cur_anim == name or not _anim.has_animation(name):
		return
	_cur_anim = name
	_anim.speed_scale = 1.0
	_anim.play(name, 0.25 if blend else 0.1)


func _blood_trail(delta: float) -> void:
	if _bleed_t <= 0.0 or world == null:
		return
	_bleed_t -= delta
	_drip_accum += _speed * delta
	if _drip_accum > 2.2:
		_drip_accum = 0.0
		Gore.decal(world, global_position, 0.22)


func _leave_tracks(delta: float) -> void:
	_blood_trail(delta)
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
