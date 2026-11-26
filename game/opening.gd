extends CanvasLayer
## A memory of the night Aruun fell. The real world provides the landscape and light.

signal finished

var world: ForestWorld
var player: Player
var _camera: Camera3D
var _middle_fire: CPUParticles3D
var _middle_glow: OmniLight3D
var _fade: ColorRect
var _title: Label
var _caption: Label
var _previous_hour: float
var _previous_frozen: bool
var _back_in_clearing := false
var _finished := false


func _ready() -> void:
	layer = 10
	_previous_hour = world.day_night.time_hours
	_previous_frozen = world.day_night.frozen
	world.day_night.frozen = true
	world.day_night.time_hours = 19.55
	world.day_night.update_visuals()
	_build_view()
	_build_overlay()
	_play()


func _build_view() -> void:
	var stage := Node3D.new()
	add_child(stage)
	const SIGNAL_Z := -35.0
	var view_target: Vector3
	for i in range(-1, 2):
		var z := SIGNAL_Z + i * 13.0
		var bank := world.river_x(z)
		var point := world.ground_point(bank + 36.0, z)
		for offset in range(14, 36):
			var candidate := world.ground_point(bank + offset, z)
			if candidate.y >= ForestWorld.WATER_LEVEL + 0.65:
				point = candidate
				break
		var beacon := Node3D.new()
		beacon.position = point
		stage.add_child(beacon)
		var pit := AssetLib.instance(AssetLib.PROPS[&"fire_pit"])
		pit.scale = Vector3.ONE * 1.7
		beacon.add_child(pit)
		for log_index in 4:
			Graybox.part_mat(beacon, Graybox.cylinder(0.07, 0.11, 1.35, 6),
				Graybox.tex("Log", Color(0.48, 0.31, 0.19), 1.0),
				Vector3.UP * 0.68, Vector3(63, log_index * 45, 0))
		var flames := Campfire.make_flames()
		flames.position = Vector3.UP * 0.73
		flames.local_coords = true
		flames.scale = Vector3.ONE * 3.5
		flames.preprocess = flames.lifetime
		beacon.add_child(flames)
		var glow := OmniLight3D.new()
		glow.position = Vector3.UP * 1.55
		glow.light_color = Color(1.0, 0.48, 0.18)
		glow.light_energy = 3.0
		glow.omni_range = 9.0
		beacon.add_child(glow)
		if i == 0:
			_middle_fire = flames
			_middle_glow = glow
			view_target = point + Vector3.UP * 2.2
	_camera = Camera3D.new()
	_camera.position = Vector3(world.river_x(SIGNAL_Z) - 7.0, ForestWorld.WATER_LEVEL + 10.0, SIGNAL_Z)
	_camera.far = player.camera.far
	_camera.keep_aspect = Camera3D.KEEP_WIDTH
	_camera.fov = 83.0
	stage.add_child(_camera)
	_camera.look_at(view_target)
	_camera.make_current()


func _build_overlay() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_fade = ColorRect.new()
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.color = Color.BLACK
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_fade)
	_title = UITheme.caption(Loc.t("OPENING_NIGHT"), 38, UITheme.BONE_HI, 600, 2)
	_title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	root.add_child(_title)
	_caption = UITheme.caption("", 24, UITheme.BONE_HI, 500)
	_caption.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_caption.offset_left = 64.0
	_caption.offset_right = -64.0
	_caption.offset_top = -152.0
	_caption.offset_bottom = -80.0
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_caption.add_theme_color_override("font_outline_color", Color.BLACK)
	_caption.add_theme_constant_override("outline_size", 8)
	root.add_child(_caption)
	var skip := UITheme.caption(
		Loc.t("OPENING_SKIP", {"key": InputSetup.label(&"pause")}), 16, UITheme.BONE, 500)
	skip.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	skip.offset_top = -54.0
	skip.offset_bottom = -22.0
	skip.offset_right = -36.0
	skip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	skip.add_theme_color_override("font_outline_color", Color.BLACK)
	skip.add_theme_constant_override("outline_size", 6)
	root.add_child(skip)


func _play() -> void:
	if not bool(Settings.get_value("accessibility", "reduce_motion")):
		var dolly := create_tween()
		dolly.tween_property(_camera, "position", _camera.position + Vector3(1.35, 0.25, 0.0), 9.0)
	var sequence := create_tween()
	sequence.tween_interval(1.65)
	sequence.tween_property(_title, "modulate:a", 0.0, 0.45)
	sequence.parallel().tween_property(_fade, "color:a", 0.0, 0.95)
	sequence.tween_callback(_show_line.bind("OPENING_KOREN"))
	sequence.tween_interval(3.1)
	sequence.tween_callback(_kill_middle_fire)
	sequence.tween_interval(2.8)
	sequence.tween_property(_fade, "color:a", 1.0, 0.65)
	sequence.tween_callback(_return_to_clearing)
	sequence.tween_interval(0.35)
	sequence.tween_property(_fade, "color:a", 0.0, 0.65)
	sequence.tween_callback(_finish)


func _show_line(key: String) -> void:
	_caption.text = Loc.t(key)


func _kill_middle_fire() -> void:
	_middle_fire.emitting = false
	create_tween().tween_property(_middle_glow, "light_energy", 0.0, 0.55)
	Sfx.play(&"tree_landing", null, -24.0, 0.0)
	_show_line("OPENING_BROKEN_SIGNAL")


func _return_to_clearing() -> void:
	if _back_in_clearing:
		return
	_back_in_clearing = true
	_caption.text = ""
	world.day_night.time_hours = _previous_hour
	world.day_night.frozen = _previous_frozen
	world.day_night.update_visuals()
	player.camera.make_current()


func _finish() -> void:
	if _finished:
		return
	_finished = true
	_return_to_clearing()
	hide()
	finished.emit()
	queue_free()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		_finish()
