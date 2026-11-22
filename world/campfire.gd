class_name Campfire
extends StaticBody3D
## Placed campfire: fuel, ignition by friction (hold), warmth, light, cooking, crafting station.
## Visuals are PLACEHOLDER graybox primitives + CPU particles.

const MAX_FUEL := 1200.0
const IGNITE_HOLD := 4.0
const WARMTH := 20.0
const WARM_RADIUS := 4.0
const WARM_FALLOFF := 8.5
const STATION_RADIUS := 3.5
const COOK_SLOTS := 3

var structure_type: StringName = &"campfire"
var structure_id := ""
var fuel := 0.0
var lit := false
## Faction camp fires are tended by their people: they never run out.
var eternal := false
var cooking: Array = []  # [{id: StringName, t: float}]

var _light: OmniLight3D
var _flames: CPUParticles3D
var _logs: Array[MeshInstance3D] = []
var _food_root: Node3D
var _flicker_t := 0.0
var _crackle: AudioStreamPlayer3D
## A tall plume of smoke from a lit fire: how you spot your camp from across the valley.
var _smoke: CPUParticles3D


func _ready() -> void:
	collision_layer = 1
	collision_mask = 0
	add_to_group("interactable")
	add_to_group("structure")
	add_to_group("time_sim")
	add_to_group("campfire")
	_build()
	_refresh()


func _build() -> void:
	var pit := AssetLib.instance(AssetLib.PROPS[&"fire_pit"])
	pit.scale = Vector3.ONE * 0.85
	add_child(pit)
	for i in 4:
		var lg := Graybox.part_mat(self, Graybox.cylinder(0.045, 0.06, 0.75, 7), Graybox.tex("Log", Color.WHITE, 2.0).duplicate(),
			Vector3(0, 0.16, 0), Vector3(62, 45.0 * i + 10.0, 0))
		_logs.append(lg)
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.62, 0.3)
	_light.omni_range = 11.0
	_light.light_energy = 2.2
	_light.shadow_enabled = true
	_light.position = Vector3(0, 0.7, 0)
	add_child(_light)
	_flames = CPUParticles3D.new()
	_flames.amount = 70
	_flames.lifetime = 0.7
	_flames.position = Vector3(0, 0.18, 0)
	_flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_flames.emission_sphere_radius = 0.18
	_flames.direction = Vector3.UP
	_flames.spread = 12.0
	_flames.gravity = Vector3(0, 1.2, 0)
	_flames.initial_velocity_min = 0.4
	_flames.initial_velocity_max = 0.9
	_flames.scale_amount_min = 0.6
	_flames.scale_amount_max = 1.0
	var curve := Curve.new()
	curve.add_point(Vector2(0, 1))
	curve.add_point(Vector2(1, 0))
	_flames.scale_amount_curve = curve
	var quad := QuadMesh.new()
	quad.size = Vector2(0.22, 0.3)
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	fm.albedo_color = Color(1.0, 0.55, 0.15)
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fm.vertex_color_use_as_albedo = true
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.6)
	gt.fill_to = Vector2(0.5, 0.0)
	gt.width = 64
	gt.height = 64
	fm.albedo_texture = gt
	quad.material = fm
	_flames.mesh = quad
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.85, 0.4, 1.0))
	grad.set_color(1, Color(0.9, 0.2, 0.05, 0.0))
	_flames.color_ramp = grad
	add_child(_flames)
	_smoke = _make_smoke()
	add_child(_smoke)
	_food_root = Node3D.new()
	_food_root.position = Vector3(0, 0.35, 0)
	add_child(_food_root)
	_crackle = Sfx.make_loop_3d(&"fire_loop", 2.0)
	_crackle.position = Vector3(0, 0.4, 0)
	add_child(_crackle)
	Graybox.add_shape(self, Graybox.cyl_shape(0.7, 0.4), Vector3(0, 0.2, 0))


func _process(delta: float) -> void:
	if lit:
		_burn(delta)
		_flicker_t += delta * 9.0
		_light.light_energy = 2.0 + sin(_flicker_t) * 0.18 + sin(_flicker_t * 2.3) * 0.12
		var w: Weather = get_tree().get_first_node_in_group("weather") as Weather
		var wind := w.wind_dir * (0.25 + w.wind * 0.6) if w else Vector2(0.2, 0.1)
		_smoke.gravity = Vector3(wind.x, 0.35, wind.y)  # the plume leans downwind


func simulate(seconds: float) -> void:
	if lit:
		_burn(seconds)


func _rain_factor() -> float:
	var w := get_tree().get_first_node_in_group("weather") as Weather if is_inside_tree() else null
	return 1.0 + 3.0 * w.rain_at(global_position) if w else 1.0


func _burn(dt: float) -> void:
	if eternal:
		for c: Dictionary in cooking:
			c.t = float(c.t) + dt
		return
	var burn := minf(dt * _rain_factor(), fuel)
	fuel -= burn
	for c: Dictionary in cooking:
		c.t = float(c.t) + burn / _rain_factor()
	if fuel <= 0.0:
		fuel = 0.0
		lit = false
		_refresh()


func is_lit() -> bool:
	return lit


func warmth_at(pos: Vector3) -> float:
	if not lit:
		return 0.0
	var d := pos.distance_to(global_position)
	if d <= WARM_RADIUS:
		return WARMTH
	return WARMTH * (1.0 - smoothstep(WARM_RADIUS, WARM_FALLOFF, d))


func get_display_name() -> String:
	return Loc.t("STRUCT_CAMPFIRE")


func get_status_text() -> String:
	if lit:
		var txt := Loc.t("STATUS_FIRE_LIT", {"m": ceili(fuel / 60.0 / _rain_factor())})
		return txt + (Loc.t("STATUS_FIRE_RAIN") if _rain_factor() > 1.1 else "")
	if fuel > 0.0:
		return Loc.t("STATUS_FIRE_READY")
	return Loc.t("STATUS_FIRE_EMPTY")


func _ready_index() -> int:
	for i in cooking.size():
		var data := ItemDB.get_item(cooking[i].id)
		if data and float(cooking[i].t) >= data.cook_time:
			return i
	return -1


func get_interactions(player: Node) -> Array:
	var inv: Inventory = player.inventory
	var opts: Array = []
	var fuel_slot := inv.find_slot(func(d: ItemData) -> bool: return d.is_fuel())
	var fuel_opt := {}
	if fuel_slot >= 0 and fuel < MAX_FUEL - 30.0:
		var fd := inv.get_slot(fuel_slot).get_data()
		fuel_opt = {"text": Loc.t("ACT_ADD_FUEL", {"item": fd.display_name()}), "hold": 0.0, "enabled": true}
	var cook_slot := inv.find_slot(func(d: ItemData) -> bool: return d.is_cookable())
	var cook_opt := {}
	if lit and cook_slot >= 0 and cooking.size() < COOK_SLOTS:
		var cd := inv.get_slot(cook_slot).get_data()
		cook_opt = {"text": Loc.t("ACT_COOK", {"item": cd.display_name()}), "hold": 0.0, "enabled": true}

	var ready := _ready_index()
	if ready >= 0:
		var rd := ItemDB.get_item(ItemDB.get_item(cooking[ready].id).cook_result)
		opts.append({"action": &"interact", "text": Loc.t("ACT_TAKE_COOKED", {"item": rd.display_name()}),
			"hold": 0.0, "enabled": true, "op": &"take"})
		if not cook_opt.is_empty():
			opts.append(_with(cook_opt, &"alt_interact", &"cook"))
		elif not fuel_opt.is_empty():
			opts.append(_with(fuel_opt, &"alt_interact", &"fuel"))
		return opts
	if not lit:
		if fuel > 0.0:
			opts.append({"action": &"interact", "text": Loc.t("ACT_IGNITE"), "hold": IGNITE_HOLD,
				"enabled": true, "op": &"ignite"})
			if not fuel_opt.is_empty():
				opts.append(_with(fuel_opt, &"alt_interact", &"fuel"))
		elif not fuel_opt.is_empty():
			opts.append(_with(fuel_opt, &"interact", &"fuel"))
		else:
			opts.append({"action": &"interact", "text": Loc.t("NEED_FUEL"), "hold": 0.0, "enabled": false})
		return opts
	if not fuel_opt.is_empty():
		opts.append(_with(fuel_opt, &"interact", &"fuel"))
	if not cook_opt.is_empty():
		opts.append(_with(cook_opt, &"alt_interact", &"cook"))
	if opts.is_empty():
		opts.append({"action": &"interact", "text": Loc.t("NEED_FUEL"), "hold": 0.0, "enabled": false})
	return opts


func _with(opt: Dictionary, action: StringName, op: StringName) -> Dictionary:
	var o := opt.duplicate()
	o.action = action
	o.op = op
	return o


func perform_interaction(player: Node, action: StringName) -> void:
	var op: StringName = &""
	for o: Dictionary in get_interactions(player):
		if o.action == action and o.enabled:
			op = o.get("op", &"")
	var inv: Inventory = player.inventory
	match op:
		&"take":
			var i := _ready_index()
			var raw := ItemDB.get_item(cooking[i].id)
			cooking.remove_at(i)
			player.give_item(raw.cook_result, 1)
		&"ignite":
			ignite()
			Sfx.play(&"fire_ignite", global_position)
			player.world.add_journal("JOURNAL_FIRE")
		&"fuel":
			var s := inv.find_slot(func(d: ItemData) -> bool: return d.is_fuel())
			if s >= 0:
				var st := inv.take_from_slot(s, 1)
				add_fuel(st.get_data().fuel_seconds)
				Sfx.play(&"rustle", global_position, -6.0)
		&"cook":
			var s := inv.find_slot(func(d: ItemData) -> bool: return d.is_cookable())
			if s >= 0:
				var st := inv.take_from_slot(s, 1)
				cooking.append({"id": st.id, "t": 0.0})
	_refresh()


func add_fuel(seconds: float) -> void:
	fuel = minf(fuel + seconds, MAX_FUEL)
	_refresh()


func ignite() -> bool:
	if fuel <= 0.0:
		return false
	lit = true
	_refresh()
	return true


func _refresh() -> void:
	if _light == null:
		return
	_light.visible = lit
	if _crackle and _crackle.is_inside_tree() and _crackle.playing != lit:
		if lit:
			_crackle.play(randf() * 2.0)
		else:
			_crackle.stop()
	_flames.emitting = lit
	_flames.visible = lit
	_smoke.emitting = lit
	var log_col := Color.WHITE if fuel > 0.0 else Color(0.18, 0.17, 0.16)
	for l in _logs:
		(l.material_override as StandardMaterial3D).albedo_color = log_col
		l.visible = fuel > 0.0 or not lit
	for c in _food_root.get_children():
		c.queue_free()
	for i in cooking.size():
		var data := ItemDB.get_item(cooking[i].id)
		var done := float(cooking[i].t) >= data.cook_time
		var show_id: StringName = data.cook_result if done else data.id
		var path := AssetLib.item_model_path(show_id)
		if path != "":
			var m := AssetLib.instance(path)
			m.position = Vector3((i - 1) * 0.2, 0, 0)
			_food_root.add_child(m)
		else:
			Graybox.part(_food_root, Graybox.box(Vector3(0.16, 0.08, 0.12)), ItemDB.get_item(show_id).icon_color, Vector3((i - 1) * 0.2, 0, 0))


func save_state() -> Dictionary:
	var c: Array = []
	for e: Dictionary in cooking:
		c.append({"id": String(e.id), "t": e.t})
	return {"fuel": fuel, "lit": lit, "cooking": c, "eternal": eternal}


func load_state(d: Dictionary) -> void:
	fuel = float(d.get("fuel", 0.0))
	eternal = bool(d.get("eternal", false))
	lit = bool(d.get("lit", false)) and fuel > 0.0
	cooking.clear()
	for e: Dictionary in d.get("cooking", []):
		if ItemDB.get_item(StringName(str(e.id))):
			cooking.append({"id": StringName(str(e.id)), "t": float(e.get("t", 0.0))})
	_refresh()


func _make_smoke() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 110
	p.lifetime = 16.0
	p.preprocess = 8.0
	p.position = Vector3(0, 0.6, 0)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.15
	p.direction = Vector3.UP
	p.spread = 8.0
	p.initial_velocity_min = 0.4
	p.initial_velocity_max = 0.7
	p.damping_min = 0.05
	p.damping_max = 0.1
	p.gravity = Vector3(0.2, 0.35, 0.1)
	p.angular_velocity_min = -12.0
	p.angular_velocity_max = 12.0
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.15))
	grow.add_point(Vector2(1.0, 1.0))
	p.scale_amount_curve = grow
	p.scale_amount_min = 3.0
	p.scale_amount_max = 4.5
	var fade := Gradient.new()
	fade.set_color(0, Color(0.2, 0.19, 0.18, 0.0))
	fade.add_point(0.06, Color(0.24, 0.23, 0.22, 0.55))
	fade.add_point(0.5, Color(0.34, 0.33, 0.32, 0.3))
	fade.set_color(fade.get_point_count() - 1, Color(0.45, 0.45, 0.45, 0.0))
	p.color_ramp = fade
	# Own soft quad: unlike the shared dust quad it keeps particle scale, so puffs grow into a plume.
	var quad := QuadMesh.new()
	quad.size = Vector2(2.2, 2.2)
	var m := (TreeNode._puff_quad(1.0).material as StandardMaterial3D).duplicate() as StandardMaterial3D
	m.billboard_keep_scale = true
	quad.material = m
	p.mesh = quad
	p.emitting = false
	return p
