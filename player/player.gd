class_name Player
extends CharacterBody3D
## First-person survivor: movement, look, interaction ray (hold-to-interact), tool swings,
## hotbar, consumables, placement mode and sleeping. Owns SurvivalStats + Inventory models.

signal died(cause: StringName)
signal slept(hours: float)

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
var _fall_speed := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _hand_item_id: StringName = &""
var _hand_visual: Node3D
var _torch_light: OmniLight3D
var _torch_wear_accum := 0.0


func _ready() -> void:
	collision_layer = 2
	collision_mask = 1
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
	camera.far = 700.0
	camera.current = true
	head.add_child(camera)
	ray = RayCast3D.new()
	ray.target_position = Vector3(0, 0, -INTERACT_RANGE)
	ray.collision_mask = 1 | 4 | 8
	ray.collide_with_areas = true
	ray.add_exception(self)
	camera.add_child(ray)
	hand_root = Node3D.new()
	hand_root.position = Vector3(0.36, -0.42, -0.62)
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

func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled or dead or is_sleeping:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look((event as InputEventMouseMotion).relative * 0.0022 * float(Settings.get_value("gameplay", "mouse_sensitivity")))
	for i in Inventory.HOTBAR_SIZE:
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			use_slot(i)
			get_viewport().set_input_as_handled()
			return
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
		else:
			swing()
	if event.is_action_pressed("secondary_action"):
		if build.active:
			build.cancel()
		elif placement.active:
			placement.cancel()


func _look(rel: Vector2) -> void:
	var inv := -1.0 if bool(Settings.get_value("gameplay", "invert_y")) else 1.0
	rotate_y(-rel.x)
	head.rotation.x = clampf(head.rotation.x - rel.y * inv, deg_to_rad(-88.0), deg_to_rad(88.0))


# ---------------------------------------------------------------- physics

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
		"sleeping": sleeping, "sprinting": sprinting,
	}


func _on_landed(speed: float) -> void:
	if speed <= SAFE_FALL_SPEED:
		return
	stats.damage((speed - SAFE_FALL_SPEED) * 9.0, &"fall")
	if speed > SAFE_FALL_SPEED + 4.0:
		stats.add_condition(&"fracture", 600.0)
		Events.toast(Loc.t("MSG_FRACTURE"), &"danger")


func _update_head(delta: float, moving: bool, sprinting: bool) -> void:
	var target := EYE_CROUCH if _crouching else EYE_STAND
	var reduce := bool(Settings.get_value("accessibility", "reduce_motion"))
	var bob := 0.0
	if moving and not reduce:
		_bob_t += delta * (11.0 if sprinting else 7.5)
		bob = sin(_bob_t) * (0.045 if sprinting else 0.025)
	head.position.y = lerpf(head.position.y, target + bob, 1.0 - exp(-12.0 * delta))


# ---------------------------------------------------------------- interaction

func _find_interactable(n: Node) -> Node:
	while n != null:
		if n.is_in_group("interactable"):
			return n
		n = n.get_parent()
	return null


func _update_interaction(delta: float) -> void:
	var target: Node = null
	if input_enabled and not dead and not is_sleeping and not placement.active and not build.active and ray.is_colliding():
		target = _find_interactable(ray.get_collider() as Node)
	look_target = target
	look_options = target.get_interactions(self) if target else []
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


func swing() -> void:
	if _swing_cd > 0.0 or dead:
		return
	if not stats.use_stamina(SWING_COST):
		Events.toast(Loc.t("MSG_NO_STAMINA"), &"warn")
		return
	_swing_cd = SWING_COOLDOWN
	_animate_swing()
	var item := inventory.hand.get_data() if inventory.hand else null
	if not ray.is_colliding():
		return
	var target := _find_interactable(ray.get_collider() as Node)
	if target and target.has_method("on_hit") and target.on_hit(self, item):
		if inventory.wear_hand(1):
			Events.toast(Loc.t("MSG_TOOL_BROKE", {"item": item.display_name()}), &"danger")


func _animate_swing() -> void:
	if _hand_visual == null:
		return
	var tw := create_tween()
	tw.tween_property(_hand_visual, "rotation_degrees", Vector3(-70, 10, 0), 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_hand_visual, "rotation_degrees", Vector3.ZERO, 0.22).set_trans(Tween.TRANS_SINE)


# ---------------------------------------------------------------- items

## Hotbar / inventory "use": consume, equip/unequip, or start placement.
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
