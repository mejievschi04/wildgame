class_name Player
extends CharacterBody3D
## First-person survivor: movement, look, interaction ray (hold-to-interact), tool swings,
## hotbar, consumables, placement mode and sleeping. Owns SurvivalStats + Inventory models.

signal died(cause: StringName)
signal slept(hours: float)
signal hurt(amount: float)

const WALK_SPEED := 3.6
const SPRINT_SPEED := 6.2
const CROUCH_SPEED := 1.8
const JUMP_VELOCITY := 4.6
const JUMP_COST := 10.0
const SWING_COST := 8.0
const SWING_COOLDOWN := 0.65
const EYE_STAND := 1.62
const EYE_CROUCH := 1.0
const INTERACT_RANGE := 2.7
const INSULATION := 4.0  # basic hide clothing (°C); clothing items later
const SAFE_FALL_SPEED := 9.0
const WAKE_HOUR := 6.5

var stats := SurvivalStats.new()
var inventory := Inventory.new()
var world: ForestWorld

var head: Node3D
var camera: Camera3D
var ray: RayCast3D
var hand_root: Node3D
## Rest position of the held item / hand in camera space: low on the right, the fist in view.
const HAND_REST := Vector3(0.33, -0.33, -0.6)
var placement: PlacementController
var build: BuildController

var input_enabled := true
var is_sleeping := false
var dead := false
var respawn_point := Vector3.ZERO

## Current interaction target state (read by the HUD).
var look_target: Node = null
var look_options: Array = []
var hold_action: StringName = &""
var hold_ratio := 0.0

var _hold_time := 0.0
var _swing_cd := 0.0
var _crouching := false
var _sprint_toggled := false
var _bob_t := 0.0
var _last_step_sign := 1.0
var _fall_speed := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _hand_item_id: StringName = &""
var _hand_visual: Node3D
var _torch_light: OmniLight3D
var _torch_wear_accum := 0.0
var _noise_burst := 0.0
var _move_noise := 0.05
var aiming := false
## Melee: charge (hold LMB) for a heavy blow; RMB raises a guard (block / perfect parry).
var blocking := false
var _block_started := 0.0
var _charging := false
var _charge_t := 0.0
const HEAVY_CHARGE := 0.4
const PARRY_WINDOW := 0.25
var _gesture_t := 0.0
var _shake := 0.0
## Footprint under the crosshair (read by the HUD): {species, age, yaw} or {}.
var look_track: Dictionary = {}


func _ready() -> void:
	collision_layer = 2
	collision_mask = 1 | Animal.LAYER_CREATURE
	add_to_group("player")
	floor_snap_length = 0.4
	floor_max_angle = deg_to_rad(50.0)
	var cs := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	cs.shape = capsule
	cs.position.y = 0.9
	add_child(cs)
	head = Node3D.new()
	head.name = "Head"
	head.position.y = EYE_STAND
	add_child(head)
	camera = Camera3D.new()
	camera.near = 0.05
	camera.far = 14000.0  # the border mountains and volcanoes (Backdrop) stand up to ~11 km away
	camera.current = true
	head.add_child(camera)
	ray = RayCast3D.new()
	ray.target_position = Vector3(0, 0, -INTERACT_RANGE)
	ray.collision_mask = 1 | 4 | 8 | Animal.LAYER_CREATURE
	ray.collide_with_areas = true
	ray.add_exception(self)
	camera.add_child(ray)
	hand_root = Node3D.new()
	hand_root.position = HAND_REST
	hand_root.rotation_degrees = Vector3(-8, -12, 0)
	hand_root.scale = Vector3.ONE * 0.75
	camera.add_child(hand_root)
	_torch_light = OmniLight3D.new()
	_torch_light.light_color = Color(1.0, 0.65, 0.35)
	_torch_light.omni_range = 9.0
	_torch_light.light_energy = 1.4
	_torch_light.position = Vector3(0.0, 0.35, 0.0)
	_torch_light.visible = false
	hand_root.add_child(_torch_light)
	placement = PlacementController.new()
	placement.player = self
	add_child(placement)
	build = BuildController.new()
	build.player = self
	add_child(build)

	stats.difficulty = Settings.difficulty_mult()
	stats.died.connect(_on_died)
	inventory.changed.connect(_refresh_hand)
	Settings.changed.connect(_on_settings_changed)
	_on_settings_changed("", "")


func _on_settings_changed(_section: String, _key: String) -> void:
	camera.fov = float(Settings.get_value("video", "fov"))
	stats.difficulty = Settings.difficulty_mult()


# ---------------------------------------------------------------- input

var _skip_capture_motion := false


func capture_mouse() -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_skip_capture_motion = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled or dead or is_sleeping:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Capturing the pointer can send a motion from its desktop position to the window centre.
		if _skip_capture_motion:
			_skip_capture_motion = false
		else:
			_look((event as InputEventMouseMotion).relative * 0.0022 * float(Settings.get_value("gameplay", "mouse_sensitivity")))
	# No hotbar: number keys pick the n-th weapon of the wheel, the mouse wheel cycles through them.
	for i in Inventory.HOTBAR_SIZE:
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			var ids := equippable_choices()
			if i < ids.size():
				equip_id(ids[i])
			get_viewport().set_input_as_handled()
			return
	if not drawing and not aiming and not _charging:
		if event.is_action_pressed("hotbar_next"):
			cycle_weapon(1)
		elif event.is_action_pressed("hotbar_prev"):
			cycle_weapon(-1)
	if event.is_action_pressed("gesture"):
		gesture()
	if event.is_action_pressed("sprint") and bool(Settings.get_value("gameplay", "toggle_sprint")):
		_sprint_toggled = not _sprint_toggled
	if event.is_action_pressed("crouch"):
		if bool(Settings.get_value("gameplay", "toggle_crouch")):
			_crouching = not _crouching
	if event.is_action_pressed("primary_action"):
		if build.active:
			build.confirm()
		elif placement.active:
			placement.confirm()
		elif _hand_is(&"bow"):
			_begin_draw()
		elif aiming:
			throw_spear()
		else:
			_begin_charge()
	if event.is_action_pressed("secondary_action"):
		if build.active:
			build.cancel()
		elif placement.active:
			placement.cancel()
		elif _hand_is(&"spear") or _hand_is(&"bow"):
			aiming = true
		else:
			_set_blocking(true)
	if event.is_action_released("secondary_action"):
		aiming = drawing
		_set_blocking(false)
	if event.is_action_released("primary_action") and _charging:
		_release_charge()
	if event.is_action_released("primary_action") and drawing:
		_release_draw()


func _look(rel: Vector2) -> void:
	var inv := -1.0 if bool(Settings.get_value("gameplay", "invert_y")) else 1.0
	rotate_y(-rel.x)
	head.rotation.x = clampf(head.rotation.x - rel.y * inv, deg_to_rad(-88.0), deg_to_rad(88.0))


# ---------------------------------------------------------------- physics

func teleport_to(destination: Vector3) -> void:
	global_position = destination
	velocity = Vector3.ZERO
	_fall_speed = 0.0
	_reset_hold()
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
		_fall_speed = maxf(_fall_speed, -velocity.y)
	var active := input_enabled and not dead and not is_sleeping
	var move := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if active else Vector2.ZERO
	if active:
		var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
		if stick.length() > 0.05:
			_look(stick * delta * 2.6 * float(Settings.get_value("gameplay", "mouse_sensitivity")))
		if not bool(Settings.get_value("gameplay", "toggle_crouch")):
			_crouching = Input.is_action_pressed("crouch")
	var sprint_held := _sprint_toggled if bool(Settings.get_value("gameplay", "toggle_sprint")) else Input.is_action_pressed("sprint")
	var sprinting := active and sprint_held and move.y < -0.1 and not _crouching and stats.can_sprint() and is_on_floor()
	if _sprint_toggled and (move.length() < 0.1 or not stats.can_sprint()):
		_sprint_toggled = false

	var speed := SPRINT_SPEED if sprinting else (CROUCH_SPEED if _crouching else WALK_SPEED)
	speed *= inventory.weight_factor()
	if stats.has_condition(&"fracture"):
		speed *= 0.6
	var in_water := global_position.y < ForestWorld.WATER_LEVEL - 0.25
	if in_water:
		speed *= 0.6
	var dir := (transform.basis * Vector3(move.x, 0, move.y)).normalized()
	var accel := 10.0 if is_on_floor() else 2.0
	velocity.x = move_toward(velocity.x, dir.x * speed, accel * speed * delta)
	velocity.z = move_toward(velocity.z, dir.z * speed, accel * speed * delta)
	if active and is_on_floor() and Input.is_action_just_pressed("jump") and stats.use_stamina(JUMP_COST):
		velocity.y = JUMP_VELOCITY
		_noise_burst = maxf(_noise_burst, 0.4)
	var moving := move.length() > 0.1
	_move_noise = 0.05 if not moving else (1.0 if sprinting else (0.12 if _crouching else 0.45))
	_noise_burst = maxf(_noise_burst - delta, 0.0)
	_gesture_t = maxf(_gesture_t - delta, 0.0)
	if _charging:
		_charge_t += delta
		if _charge_t > 1.4:
			_release_charge()
	if blocking and stats.stamina <= 0.5:
		_set_blocking(false)
	if drawing:
		_tick_draw(delta)
	if not (_hand_is(&"spear") or _hand_is(&"bow")):
		aiming = false
	var was_on_floor := is_on_floor()
	move_and_slide()
	if is_on_floor() and not was_on_floor:
		_on_landed(_fall_speed)
	if is_on_floor():
		_fall_speed = 0.0

	_update_head(delta, move.length() > 0.1 and is_on_floor(), sprinting)
	if not dead:
		stats.tick(delta, survival_env(is_sleeping, sprinting and move.length() > 0.1))
	_tick_torch(delta)
	_swing_cd = maxf(_swing_cd - delta, 0.0)
	_update_interaction(delta)


## Environment for the survival model at the player's position (ambient, fire warmth, clothing + shelter).
func survival_env(sleeping: bool = false, sprinting: bool = false) -> Dictionary:
	if world == null:
		return {"ambient_temp": 15.0, "warmth": 0.0, "insulation": INSULATION, "sleeping": sleeping, "sprinting": sprinting}
	var pos := global_position + Vector3.UP * 0.5
	return {
		"ambient_temp": world.ambient_temperature_at(global_position),
		"warmth": world.get_warmth_at(global_position),
		"insulation": INSULATION + world.get_shelter_at(pos),
		"rain": world.weather.rain_at(pos) if world.weather else 0.0,
		"sleeping": sleeping, "sprinting": sprinting,
	}


func _begin_charge() -> void:
	if _swing_cd > 0.0 or _swinging or dead or blocking:
		return
	_charging = true
	_charge_t = 0.0
	# Draw the weapon back while charging.
	var st: Array = SWING_STYLES[_swing_style()]
	var v := _hand_visual if _hand_visual else hand_root
	var tw := create_tween()
	tw.tween_property(v, "rotation_degrees", (st[0] as Vector3) * 0.6, HEAVY_CHARGE).set_trans(Tween.TRANS_SINE)


func _release_charge() -> void:
	if not _charging:
		return
	_charging = false
	swing(_charge_t >= HEAVY_CHARGE)


## True while the player is visibly preparing a blow (NPCs may raise their guard).
func is_winding_up() -> bool:
	return _charging or (_swinging and _swing_cd > 0.3)


func _set_blocking(on: bool) -> void:
	if on == blocking:
		return
	if on and (dead or stats.stamina < 5.0 or _swinging):
		return
	blocking = on
	if on:
		_block_started = Time.get_ticks_msec() / 1000.0
	var tw := create_tween()
	tw.tween_property(hand_root, "position", Vector3(0.08, -0.28, -0.5) if on else HAND_REST, 0.12)
	tw.parallel().tween_property(hand_root, "rotation_degrees", Vector3(-8, -12, 70) if on else Vector3(-8, -12, 0), 0.12)


## Open-palm gesture (GDD §7: diplomacy without a shared language).
func gesture() -> void:
	if _gesture_t > 0.0 or dead:
		return
	_gesture_t = 2.2
	Events.toast(Loc.t("MSG_GESTURE"), &"info")
	var tw := create_tween()
	tw.tween_property(hand_root, "position:y", -0.9, 0.2)
	tw.tween_interval(1.6)
	tw.tween_property(hand_root, "position:y", HAND_REST.y, 0.3)


func is_gesturing() -> bool:
	return _gesture_t > 0.0


## How audible the player is right now (0..1): movement + recent actions (chopping, gathering, jumping).
func noise_level() -> float:
	return clampf(maxf(_move_noise, _noise_burst), 0.0, 1.0)


## How visible the player is (multiplies animal sight range).
func visibility_factor() -> float:
	var v := 1.0
	if _crouching:
		v *= 0.55
	var torch := inventory.hand != null and inventory.hand.id == &"torch"
	if world and world.day_night.is_night():
		v *= 1.3 if torch else 0.5
	if world and world.weather:
		v *= 1.0 - 0.35 * clampf(world.weather.fog_extra / 0.018, 0.0, 1.0)
	return v


## Damage from a creature (wolf bite): may cause bleeding.
func take_hit(amount: float, cause: StringName, bleed_chance: float = 0.0, from_pos: Vector3 = Vector3.ZERO,
		attacker: Node = null) -> void:
	if dead:
		return
	if blocking and from_pos != Vector3.ZERO:
		var to_att := from_pos - global_position
		to_att.y = 0.0
		if (-global_transform.basis.z).dot(to_att.normalized()) > 0.3:
			var now := Time.get_ticks_msec() / 1000.0
			if now - _block_started <= PARRY_WINDOW:
				# Perfect parry: no damage, attacker knocked off balance.
				Sfx.play(&"stone_knock", null, 0.0, 0.05)
				Events.toast(Loc.t("MSG_PARRY"), &"good")
				if attacker and attacker.has_method("stagger"):
					attacker.stagger(1.2)
				_hit_stop(0.06)
				return
			stats.use_stamina(minf(15.0, stats.stamina))
			amount *= 0.25
			bleed_chance = 0.0
			Sfx.play(&"stone_knock", null, -4.0, 0.1)
			if stats.stamina <= 0.5:
				_set_blocking(false)
				Events.toast(Loc.t("MSG_GUARD_BROKEN"), &"warn")
	stats.damage(amount, cause)
	if randf() < bleed_chance:
		stats.add_condition(&"bleeding")
		Events.toast(Loc.t("MSG_BLEEDING"), &"danger")
	if not bool(Settings.get_value("accessibility", "reduce_motion")):
		_shake = 1.0
	if from_pos != Vector3.ZERO:
		var push := (global_position - from_pos)
		push.y = 0.0
		velocity += push.normalized() * 2.5
	Sfx.play(&"hurt", null)
	hurt.emit(amount)


func throw_spear() -> void:
	if inventory.hand == null or inventory.hand.id != &"spear" or not stats.use_stamina(12.0):
		return
	var st := inventory.hand
	inventory.hand = null
	inventory.changed.emit()
	aiming = false
	var spear := ThrownSpear.new()
	world.pickups_root.add_child(spear)
	var fwd := -camera.global_transform.basis.z
	spear.launch(st, camera.global_position + fwd * 0.7, fwd * 24.0 + Vector3(velocity.x, 0, velocity.z), self)
	_noise_burst = maxf(_noise_burst, 0.6)
	Sfx.play(&"whoosh", null, -4.0)


# ---------------------------------------------------------------- bow

## Hold LMB to draw (needs an arrow), release to shoot. Power, speed and damage scale with the draw.
const BOW_DRAW_TIME := 0.85
const BOW_MIN_DRAW := 0.2  # releasing earlier just lets the string down, the arrow stays nocked in the quiver
const ARROW_SPEED_MIN := 16.0
const ARROW_SPEED_MAX := 46.0
const BOW_HOLD_STAMINA := 5.0  # per second while holding a full draw
const ARROW_BREAK_CHANCE := 0.3
## How far the nock travels back at full draw (bow model metres). The bow's "Drawn" blend shape pulls the string
## exactly this far (tools/blender/gen_items.py BOW_PULL), so string and arrow stay together.
const BOW_PULL := 0.45
const BOW_SNAP_TIME := 0.07  # string/limbs spring back to rest after a shot or let-down

var drawing := false
var _draw_t := 0.0
var _draw_w := 0.0  # eased draw (0..1): nock offset and bow blend shape
var _nocked: Node3D


func _hand_is(id: StringName) -> bool:
	return inventory.hand != null and inventory.hand.id == id


## 0..1 how far the bow is drawn (HUD).
func draw_ratio() -> float:
	return clampf(_draw_t / BOW_DRAW_TIME, 0.0, 1.0) if drawing else 0.0


func _begin_draw() -> void:
	if drawing or dead or _swinging or blocking:
		return
	if inventory.count_of(&"arrow") <= 0:
		Events.toast(Loc.t("MSG_NO_ARROWS"), &"warn")
		return
	drawing = true
	aiming = true
	_draw_t = 0.0
	if _hand_visual:
		_nocked = HandModels.nock_arrow(_hand_visual)


func _tick_draw(delta: float) -> void:
	if not _hand_is(&"bow") or dead:
		_cancel_draw()
		return
	_draw_t += delta
	if _draw_t > BOW_DRAW_TIME and not stats.use_stamina(BOW_HOLD_STAMINA * delta):
		_cancel_draw()  # arms give out: the string is let down without a shot
		return
	_draw_w = 1.0 - pow(1.0 - draw_ratio(), 2.0)  # fast at first, heavier toward full draw
	if _nocked and is_instance_valid(_nocked):
		_nocked.position.z = HandModels.NOCK.z + BOW_PULL * _draw_w
	if _hand_visual:
		HandModels.set_bow_draw(_hand_visual, _draw_w)


func _cancel_draw() -> void:
	drawing = false
	_draw_t = 0.0
	aiming = Input.is_action_pressed("secondary_action") and _hand_is(&"bow")
	if _nocked and is_instance_valid(_nocked):
		_nocked.queue_free()
	_nocked = null
	if _hand_visual and is_instance_valid(_hand_visual) and _draw_w > 0.0:
		var bow := _hand_visual
		create_tween().tween_method(func(w: float) -> void:
			if is_instance_valid(bow):
				HandModels.set_bow_draw(bow, w), _draw_w, 0.0, BOW_SNAP_TIME).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_draw_w = 0.0


func _release_draw() -> void:
	var k := draw_ratio()
	_cancel_draw()
	if k < BOW_MIN_DRAW or not _hand_is(&"bow") or not inventory.remove_item(&"arrow", 1):
		return
	var arrow := ThrownSpear.new()
	world.pickups_root.add_child(arrow)
	var data := ItemDB.get_item(&"arrow")
	arrow.base_damage = data.damage if data else 30.0
	arrow.ref_speed = ARROW_SPEED_MAX * 0.85
	arrow.break_chance = ARROW_BREAK_CHANCE
	var fwd := -camera.global_transform.basis.z
	# A weak, hurried draw is less accurate.
	var wobble := (1.0 - k) * 0.035
	fwd = (fwd + camera.global_transform.basis.x * randf_range(-wobble, wobble)
		+ camera.global_transform.basis.y * randf_range(-wobble, wobble)).normalized()
	var speed := lerpf(ARROW_SPEED_MIN, ARROW_SPEED_MAX, k)
	arrow.launch(ItemStack.new(&"arrow", 1), camera.global_position + fwd * 0.6, fwd * speed + Vector3(velocity.x, 0, velocity.z), self)
	_noise_burst = maxf(_noise_burst, 0.3)  # bows are quiet
	Sfx.play(&"whoosh", null, -6.0, 0.15)
	if inventory.wear_hand(1):
		Events.toast(Loc.t("MSG_TOOL_BROKE", {"item": ItemDB.get_item(&"bow").display_name()}), &"danger")
		Sfx.play(&"tool_break", null)


## Sleep needs safety: no hostile/wary armed strangers nearby, no predator hunting you.
func _safe_to_sleep() -> bool:
	for n: HumanNPC in get_tree().get_nodes_in_group("npc"):
		if n.is_dead() or n.global_position.distance_to(global_position) > 40.0:
			continue
		if n.armed and world.factions and world.factions.stance(n.faction) in [&"hostile", &"wary"]:
			return false
		if n.state == HumanNPC.State.COMBAT:
			return false
	for a: Animal in get_tree().get_nodes_in_group("animal"):
		if a.is_predator() and not a.is_dead() and a.state in [Animal.State.CHASE, Animal.State.ATTACK]:
			return false
	return true


func _on_landed(speed: float) -> void:
	if speed <= SAFE_FALL_SPEED:
		return
	stats.damage((speed - SAFE_FALL_SPEED) * 9.0, &"fall")
	Sfx.play(&"hurt", null)
	if speed > SAFE_FALL_SPEED + 4.0:
		stats.add_condition(&"fracture", 600.0)
		Events.toast(Loc.t("MSG_FRACTURE"), &"danger")


func _update_head(delta: float, moving: bool, sprinting: bool) -> void:
	var base_fov := float(Settings.get_value("video", "fov"))
	camera.fov = lerpf(camera.fov, base_fov * (0.72 if aiming else 1.0), 1.0 - exp(-10.0 * delta))
	if _shake > 0.0:
		_shake = maxf(_shake - delta * 3.0, 0.0)
		camera.h_offset = randf_range(-1, 1) * _shake * 0.05
		camera.v_offset = randf_range(-1, 1) * _shake * 0.05
	else:
		camera.h_offset = 0.0
		camera.v_offset = 0.0
	var target := EYE_CROUCH if _crouching else EYE_STAND
	var reduce := bool(Settings.get_value("accessibility", "reduce_motion"))
	var bob := 0.0
	if moving:
		_bob_t += delta * (11.0 if sprinting else 7.5) * (0.7 if _crouching else 1.0)
		if not reduce:
			bob = sin(_bob_t) * (0.045 if sprinting else 0.025)
		var sgn := signf(sin(_bob_t))
		if sgn != _last_step_sign and sgn < 0.0:
			_footstep(sprinting)
		_last_step_sign = sgn
	head.position.y = lerpf(head.position.y, target + bob, 1.0 - exp(-12.0 * delta))


func _footstep(sprinting: bool) -> void:
	var surface := &"step_grass"
	if global_position.y < ForestWorld.WATER_LEVEL - 0.1:
		surface = &"step_water"
	else:
		var on_wood := false
		for i in get_slide_collision_count():
			if get_slide_collision(i).get_collider() is BuildingPiece:
				on_wood = true
				break
		if on_wood:
			surface = &"step_wood"
		elif ForestWorld.tundra_at(global_position.x, global_position.z) > 0.55:
			surface = &"step_snow"
	var vol := -8.0 if sprinting else (-16.0 if _crouching else -12.0)
	Sfx.play(surface, global_position, vol, 0.12)


# ---------------------------------------------------------------- interaction

func _find_interactable(n: Node) -> Node:
	while n != null:
		if n.is_in_group("interactable"):
			return n
		n = n.get_parent()
	return null


func _stone_below_water() -> ResourceNode:
	# Water has its own interaction surface. Check for a loose stone along the same sight line.
	var query := PhysicsRayQueryParameters3D.create(ray.global_position, ray.to_global(ray.target_position), 1 | 4, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var stone := hit.get("collider") as ResourceNode
	return stone if stone and stone.kind == &"loose_stone" else null


func _update_interaction(delta: float) -> void:
	var target: Node = null
	if input_enabled and not dead and not is_sleeping and not placement.active and not build.active and ray.is_colliding():
		target = _find_interactable(ray.get_collider() as Node)
		if target is WaterBody:
			var stone := _stone_below_water()
			if stone:
				target = stone
	look_target = target
	look_options = target.get_interactions(self) if target else []
	look_track = {}
	if target == null and input_enabled and ray.is_colliding() and world and world.tracks \
			and (ray.get_collider() as Node).is_in_group("terrain"):
		look_track = world.tracks.nearest(ray.get_collision_point(), 0.8)
	var pressed_opt := {}
	for opt: Dictionary in look_options:
		if opt.get("swing", false) or not opt.enabled:
			continue
		if Input.is_action_pressed(opt.action):
			pressed_opt = opt
			break
	if pressed_opt.is_empty():
		_reset_hold()
		return
	if hold_action != pressed_opt.action:
		_reset_hold()
		hold_action = pressed_opt.action
		if float(pressed_opt.hold) <= 0.0:
			# Instant actions fire once per press.
			if Input.is_action_just_pressed(pressed_opt.action):
				target.perform_interaction(self, pressed_opt.action)
			return
	if float(pressed_opt.hold) <= 0.0:
		return
	_hold_time += delta
	hold_ratio = clampf(_hold_time / float(pressed_opt.hold), 0.0, 1.0)
	if hold_ratio >= 1.0:
		target.perform_interaction(self, pressed_opt.action)
		_noise_burst = maxf(_noise_burst, 0.5)
		_hold_time = 0.0  # holding keeps repeating (e.g. gathering several times)
		hold_ratio = 0.0


func _reset_hold() -> void:
	hold_action = &""
	_hold_time = 0.0
	hold_ratio = 0.0


## Gives items to the player; anything that does not fit is dropped at their feet.
func give_item(id: StringName, count: int, durability: int = -1) -> void:
	var leftover := inventory.add_item(id, count, durability)
	if leftover < count:
		Events.item_gained.emit(id, count - leftover)
	if leftover > 0:
		Events.toast(Loc.t("MSG_INVENTORY_FULL"), &"warn")
		if world:
			world.spawn_pickup(ItemStack.new(id, leftover, durability), global_position + Vector3(0, 0.6, 0) - transform.basis.z * 0.6)


## Swing styles: [windup rot, windup pos, strike rot, strike pos, windup s, strike s, recover s]
const SWING_STYLES := {
	# Over the right shoulder, then a diagonal strike that brings the head to the crosshair.
	&"chop": [Vector3(38, -18, -28), Vector3(0.06, 0.3, 0.14), Vector3(-78, 14, 38), Vector3(-0.32, 0.04, -0.34), 0.26, 0.1, 0.34],
	&"slash": [Vector3(20, 35, 20), Vector3(0.1, 0.06, 0.05), Vector3(-30, -45, -20), Vector3(-0.14, -0.04, -0.12), 0.14, 0.08, 0.22],
	&"thrust": [Vector3(6, 0, 0), Vector3(0.0, -0.02, 0.22), Vector3(-4, 0, 0), Vector3(0.0, 0.03, -0.42), 0.22, 0.09, 0.3],
	&"punch": [Vector3(10, 0, 0), Vector3(0.0, -0.05, 0.1), Vector3(-10, 0, 0), Vector3(0.0, 0.0, -0.25), 0.12, 0.07, 0.18],
}

var _swinging := false
var _heavy := false


func _swing_style() -> StringName:
	var id: StringName = inventory.hand.id if inventory.hand else &""
	match id:
		&"stone_axe", &"stone", &"club": return &"chop"
		&"flint_knife", &"torch", &"bone_knife", &"sickle": return &"slash"
		&"digging_stick": return &"chop"
		&"fishing_spear": return &"thrust"
		&"spear": return &"thrust"
	return &"punch"


## Phased swing: wind-up → fast strike → impact (hit resolved NOW, not on click) → recoil → recover.
func swing(heavy: bool = false) -> void:
	if _swing_cd > 0.0 or dead or _swinging:
		return
	_heavy = heavy
	if not stats.use_stamina(SWING_COST * (1.8 if heavy else 1.0)):
		Events.toast(Loc.t("MSG_NO_STAMINA"), &"warn")
		return
	var st: Array = SWING_STYLES[_swing_style()]
	var windup: float = st[4] * (0.6 if heavy else 1.0)  # already drawn back while charging
	var strike: float = st[5] * (1.15 if heavy else 1.0)
	var recover: float = st[6] * (1.3 if heavy else 1.0)
	_swing_cd = windup + strike + recover + 0.05
	_swinging = true
	_noise_burst = maxf(_noise_burst, 0.7)
	var v := _hand_visual if _hand_visual else hand_root
	var rest_rot := Vector3.ZERO if _hand_visual else hand_root.rotation_degrees
	var rest_pos := Vector3.ZERO if _hand_visual else hand_root.position
	var tw := create_tween()
	tw.tween_property(v, "rotation_degrees", rest_rot + st[0], windup).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(v, "position", rest_pos + st[1], windup).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func() -> void: Sfx.play(&"whoosh", null, -8.0, 0.1))
	tw.tween_property(v, "rotation_degrees", rest_rot + st[2], strike).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(v, "position", rest_pos + st[3], strike).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(func() -> void:
		if _resolve_swing():
			_kick(v, rest_rot, st)
		else:
			var held := inventory.hand.get_data() if inventory.hand else null
			if held and held.has_tag(&"tool_axe"):
				Sfx.play(&"axe_glance", global_position + Vector3.UP, -8.0, 0.05))
	tw.tween_property(v, "rotation_degrees", rest_rot, recover).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.parallel().tween_property(v, "position", rest_pos, recover).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(func() -> void: _swinging = false)


## Impact: the tool stops in the wood/body — small rebound and a camera nudge.
func _kick(v: Node3D, rest_rot: Vector3, st: Array) -> void:
	var tw := create_tween()
	tw.tween_property(v, "rotation_degrees", rest_rot + (st[2] as Vector3) * 0.82, 0.05)
	if not bool(Settings.get_value("accessibility", "reduce_motion")):
		_shake = maxf(_shake, 0.25)
		var base_pitch := head.rotation.x
		var t2 := create_tween()
		t2.tween_property(head, "rotation:x", base_pitch - 0.012, 0.04)
		t2.tween_property(head, "rotation:x", base_pitch, 0.12)


## Returns true when the swing hit something solid.
func _resolve_swing() -> bool:
	if dead or not ray.is_colliding():
		return false
	var item := inventory.hand.get_data() if inventory.hand else null
	var hit := ray.get_collider()
	var creature := (hit is Animal and not (hit as Animal).is_dead()) or hit is HumanNPC
	if creature:
		var dmg := (item.damage if item and item.damage > 0.0 else 3.0) * (1.8 if _heavy else 1.0)
		hit.take_damage(dmg, self, ray.get_collision_point(), item, _heavy)
		Sfx.play(&"axe_chop" if item and item.has_tag(&"tool_axe") else &"chop", ray.get_collision_point(), -4.0)
		_hit_stop(0.07 if _heavy else 0.04)
		if item and inventory.wear_hand(1):
			Events.toast(Loc.t("MSG_TOOL_BROKE", {"item": item.display_name()}), &"danger")
		return true
	var target := _find_interactable(hit as Node)
	if target and target.has_method("on_hit") and target.on_hit(self, item):
		if inventory.wear_hand(1):
			Events.toast(Loc.t("MSG_TOOL_BROKE", {"item": item.display_name()}), &"danger")
			Sfx.play(&"tool_break", null)
		return true
	return hit is StaticBody3D


## Brief freeze on impact — sells the weight of a blow.
func _hit_stop(seconds: float) -> void:
	if not is_inside_tree() or Engine.time_scale < 1.0:
		return
	Engine.time_scale = 0.08
	get_tree().create_timer(seconds, true, false, true).timeout.connect(func() -> void: Engine.time_scale = 1.0)


func shake(strength: float) -> void:
	if not bool(Settings.get_value("accessibility", "reduce_motion")):
		_shake = maxf(_shake, strength)


# ---------------------------------------------------------------- items

## Hotbar / inventory "use": consume, equip/unequip, or start placement.
## Weapon wheel order: weapons first, then tools, then the rest that can be held (torch, a stone).
const WHEEL_ORDER := [&"weapon", &"tool"]


## One entry per kind of item you can hold (the hand item included), in wheel order: [StringName ids].
func equippable_choices() -> Array[StringName]:
	var ids: Array[StringName] = []
	var all: Array = inventory.slots.duplicate()
	all.append(inventory.hand)
	for s: ItemStack in all:
		if s != null and s.get_data() != null and s.get_data().is_equippable() and not s.id in ids:
			ids.append(s.id)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool:
		var ca := WHEEL_ORDER.find(ItemDB.get_item(a).category)
		var cb := WHEEL_ORDER.find(ItemDB.get_item(b).category)
		ca = ca if ca >= 0 else 9
		cb = cb if cb >= 0 else 9
		return ca < cb if ca != cb else String(a) < String(b))
	return ids


## Takes an item of this kind in hand (the least worn one); &"" puts the hand item away.
func equip_id(id: StringName) -> void:
	if id == &"":
		inventory.unequip()
		return
	if inventory.hand != null and inventory.hand.id == id:
		return
	var best := -1
	for i in inventory.size:
		var s := inventory.get_slot(i)
		if s != null and s.id == id and (best < 0 or s.durability > inventory.get_slot(best).durability):
			best = i
	if best >= 0:
		inventory.equip_slot(best)
		Sfx.play(&"ui_click", null, -8.0)


## Mouse wheel / shoulder buttons: next or previous weapon without opening the wheel.
func cycle_weapon(step: int) -> void:
	var ids := equippable_choices()
	if ids.is_empty():
		return
	var cur := ids.find(inventory.hand.id) if inventory.hand else -1
	equip_id(ids[posmod(cur + step, ids.size())])


func use_slot(i: int) -> void:
	var s := inventory.get_slot(i)
	if s == null:
		if i < Inventory.HOTBAR_SIZE and inventory.hand != null:
			inventory.unequip()
		return
	var data := s.get_data()
	if data.is_consumable():
		consume_slot(i)
	elif data.is_equippable():
		inventory.equip_slot(i)
	elif data.category == &"placeable":
		placement.begin(i, data)
	else:
		Events.toast(Loc.t("MSG_CANNOT_USE"), &"info")


func consume_slot(i: int) -> void:
	var s := inventory.get_slot(i)
	if s == null:
		return
	var data := s.get_data()
	if not data.is_consumable():
		return
	inventory.take_from_slot(i, 1)
	Sfx.play(&"drink" if data.category == &"drink" else &"eat", null, -4.0)
	var sick := stats.consume(data)
	if data.use_result != &"":
		# Put the container back into the same slot when possible.
		if inventory.get_slot(i) == null:
			inventory.slots[i] = ItemStack.new(data.use_result, 1)
			inventory.changed.emit()
		else:
			give_item(data.use_result, 1)
	if sick:
		Events.toast(Loc.t("MSG_FEEL_SICK"), &"danger")


func drop_slot(i: int) -> void:
	var st := inventory.take_from_slot(i)
	if st and world:
		world.spawn_pickup(st, camera.global_position - camera.global_transform.basis.z * 0.8)


func drop_hand() -> void:
	if inventory.hand == null or world == null:
		return
	var st := inventory.hand
	inventory.hand = null
	inventory.changed.emit()
	world.spawn_pickup(st, camera.global_position - camera.global_transform.basis.z * 0.8)


func _refresh_hand() -> void:
	var id: StringName = inventory.hand.id if inventory.hand else &""
	if id == _hand_item_id:
		return
	_hand_item_id = id
	if _hand_visual:
		_hand_visual.queue_free()
		_hand_visual = null
	_torch_light.visible = id == &"torch"
	if id == &"":
		return
	_hand_visual = HandModels.build(id)
	hand_root.add_child(_hand_visual)


func _tick_torch(delta: float) -> void:
	if _hand_item_id != &"torch":
		return
	_torch_wear_accum += delta
	if _torch_wear_accum >= 1.0:
		_torch_wear_accum -= 1.0
		if inventory.wear_hand(1):
			Events.toast(Loc.t("MSG_TORCH_OUT"), &"warn")
	_torch_light.light_energy = 1.3 + sin(Time.get_ticks_msec() * 0.013) * 0.12


# ---------------------------------------------------------------- sleep

func can_sleep() -> Dictionary:
	if stats.rest > 85.0 and not world.day_night.is_night():
		return {"ok": false, "reason": Loc.t("SLEEP_NOT_TIRED")}
	if not _safe_to_sleep():
		return {"ok": false, "reason": Loc.t("SLEEP_UNSAFE")}
	if world.weather and world.weather.rain_at(global_position + Vector3.UP * 0.5) > 0.1:
		return {"ok": false, "reason": Loc.t("SLEEP_RAIN")}
	var env := survival_env(true)
	var eff: float = env.ambient_temp + env.warmth + env.insulation
	if eff < 8.0:
		return {"ok": false, "reason": Loc.t("SLEEP_TOO_COLD")}
	if stats.hunger < 8.0 or stats.thirst < 8.0:
		return {"ok": false, "reason": Loc.t("SLEEP_NEEDS")}
	return {"ok": true, "reason": ""}


## Time skip until morning (or until rested), simulated in 10 s steps so fires can burn
## out mid-sleep and the cold then wakes the player.
func sleep_at(bed: Node3D) -> void:
	if not can_sleep().ok:
		return
	respawn_point = bed.global_position + Vector3(0, 0.4, 0)
	is_sleeping = true
	var total := world.day_night.seconds_until(WAKE_HOUR)
	if not world.day_night.is_night():
		total = minf(total, (SurvivalStats.MAX - stats.rest) / stats.rest_regen_sleeping + 1.0)
	var elapsed := 0.0
	var woke_cold := false
	const STEP := 10.0
	while elapsed < total and not stats.dead:
		var dt := minf(STEP, total - elapsed)
		world.advance_time(dt)
		stats.tick(dt, survival_env(true))
		elapsed += dt
		if stats.body_temp < 35.8:
			woke_cold = true
			break
	is_sleeping = false
	var hours := elapsed * 24.0 / world.day_night.day_length_sec
	slept.emit(hours)
	if woke_cold:
		Events.toast(Loc.t("MSG_WOKE_COLD"), &"danger")
	else:
		Events.toast(Loc.t("MSG_SLEPT", {"h": snappedf(hours, 0.1)}), &"good")
	if world.day_night.day >= 2:
		world.add_journal("JOURNAL_FIRST_NIGHT")


# ---------------------------------------------------------------- life & death

func _on_died(cause: StringName) -> void:
	dead = true
	placement.cancel()
	build.cancel()
	died.emit(cause)
	Events.player_died.emit(cause)


func to_dict() -> Dictionary:
	var p := global_position
	return {
		"pos": [p.x, p.y, p.z], "yaw": rotation.y, "pitch": head.rotation.x,
		"respawn": [respawn_point.x, respawn_point.y, respawn_point.z],
		"crouch": _crouching, "stats": stats.to_dict(), "inventory": inventory.to_dict(),
	}


func from_dict(d: Dictionary) -> void:
	var p: Array = d.get("pos", [0, 5, 0])
	global_position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	rotation.y = float(d.get("yaw", 0.0))
	head.rotation.x = float(d.get("pitch", 0.0))
	var r: Array = d.get("respawn", p)
	respawn_point = Vector3(float(r[0]), float(r[1]), float(r[2]))
	_crouching = bool(d.get("crouch", false))
	stats.from_dict(d.get("stats", {}))
	inventory.from_dict(d.get("inventory", {}))
	dead = stats.dead
