class_name SettingsMenu
extends PanelContainer
## Settings: video / audio / gameplay / accessibility / controls (rebinding). Persists via Settings.

signal closed

var _rebinding: StringName = &""
var _rebind_buttons: Dictionary = {}
var _tabs: TabContainer


func _ready() -> void:
	custom_minimum_size = Vector2(760, 560)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	add_child(v)
	v.add_child(UITheme.label(Loc.t("MENU_SETTINGS"), "HeadingLabel"))
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_tabs)
	_tabs.add_child(_video_tab())
	_tabs.add_child(_audio_tab())
	_tabs.add_child(_gameplay_tab())
	_tabs.add_child(_access_tab())
	_tabs.add_child(_controls_tab())
	var titles := ["SET_TAB_VIDEO", "SET_TAB_AUDIO", "SET_TAB_GAMEPLAY", "SET_TAB_ACCESS", "SET_TAB_CONTROLS"]
	for i in titles.size():
		_tabs.set_tab_title(i, Loc.t(titles[i]))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(row)
	row.add_child(UITheme.button(Loc.t("BTN_BACK"), func() -> void: closed.emit()))


func focus_first() -> void:
	_tabs.get_tab_bar().grab_focus()


func _page() -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 24)
	g.add_theme_constant_override("v_separation", 10)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(g)
	return s


func _grid(page: ScrollContainer) -> GridContainer:
	return page.get_child(0) as GridContainer


func _row(page: ScrollContainer, key: String, control: Control) -> void:
	var l := UITheme.label(Loc.t(key))
	l.custom_minimum_size.x = 300
	_grid(page).add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid(page).add_child(control)


func _check(section: String, key: String) -> CheckBox:
	var c := CheckBox.new()
	c.button_pressed = bool(Settings.get_value(section, key))
	c.toggled.connect(func(on: bool) -> void: Settings.set_value(section, key, on))
	return c


func _slider(section: String, key: String, mn: float, mx: float, step: float, fmt: String = "%.2f") -> HBoxContainer:
	var h := HBoxContainer.new()
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.value = float(Settings.get_value(section, key))
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.custom_minimum_size.x = 220
	var l := UITheme.label(fmt % s.value, "SmallLabel")
	l.custom_minimum_size.x = 56
	s.value_changed.connect(func(val: float) -> void:
		l.text = fmt % val
		Settings.set_value(section, key, val))
	h.add_child(s)
	h.add_child(l)
	return h


func _options(section: String, key: String, labels: Array, values: Array) -> OptionButton:
	var o := OptionButton.new()
	for i in labels.size():
		o.add_item(Loc.t(labels[i]), i)
	var cur: Variant = Settings.get_value(section, key)
	o.selected = maxi(values.find(cur), 0)
	o.item_selected.connect(func(i: int) -> void: Settings.set_value(section, key, values[i]))
	return o


func _video_tab() -> Control:
	var p := _page()
	_row(p, "SET_QUALITY", _options("video", "quality", ["QUALITY_LOW", "QUALITY_MEDIUM", "QUALITY_HIGH"], [0, 1, 2]))
	_row(p, "SET_AA", _options("video", "aa", ["AA_OFF", "AA_FXAA", "AA_SMAA", "AA_TAA", "AA_MSAA"], [0, 1, 2, 3, 4]))
	_row(p, "SET_UPSCALER", _options("video", "upscaler", ["UPSCALE_BILINEAR", "UPSCALE_FSR2", "UPSCALE_METALFX"], [0, 1, 2]))
	_row(p, "SET_FULLSCREEN", _check("video", "fullscreen"))
	_row(p, "SET_VSYNC", _check("video", "vsync"))
	_row(p, "SET_FOV", _slider("video", "fov", 60, 110, 1, "%.0f°"))
	_row(p, "SET_RENDER_SCALE", _slider("video", "render_scale", 0.5, 1.0, 0.05, "%.2f"))
	_row(p, "SET_SHADOWS", _check("video", "shadows"))
	_row(p, "SET_MAX_FPS", _options("video", "max_fps", ["FPS_UNLIMITED", "FPS_30", "FPS_60", "FPS_120"], [0, 30, 60, 120]))
	return p


func _audio_tab() -> Control:
	var p := _page()
	_row(p, "SET_MASTER", _slider("audio", "master", 0, 1, 0.05, "%.2f"))
	_row(p, "SET_MUSIC", _slider("audio", "music", 0, 1, 0.05, "%.2f"))
	_row(p, "SET_SFX", _slider("audio", "sfx", 0, 1, 0.05, "%.2f"))
	return p


func _gameplay_tab() -> Control:
	var p := _page()
	_row(p, "SET_SENSITIVITY", _slider("gameplay", "mouse_sensitivity", 0.2, 3.0, 0.05, "%.2f"))
	_row(p, "SET_INVERT_Y", _check("gameplay", "invert_y"))
	_row(p, "SET_DIFFICULTY", _options("gameplay", "difficulty", ["DIFF_EASY", "DIFF_NORMAL", "DIFF_HARD"], [0, 1, 2]))
	_row(p, "SET_TOGGLE_SPRINT", _check("gameplay", "toggle_sprint"))
	_row(p, "SET_TOGGLE_CROUCH", _check("gameplay", "toggle_crouch"))
	_row(p, "SET_DAY_LENGTH", _slider("gameplay", "day_length_min", 12, 60, 2, "%.0f"))
	return p


func _access_tab() -> Control:
	var p := _page()
	_row(p, "SET_HUD_SCALE", _slider("accessibility", "hud_scale", 0.75, 1.5, 0.05, "%.2f"))
	_row(p, "SET_HIGH_CONTRAST", _check("accessibility", "high_contrast"))
	_row(p, "SET_REDUCE_MOTION", _check("accessibility", "reduce_motion"))
	_row(p, "SET_SUBTITLES", _check("accessibility", "subtitles"))
	return p


func _controls_tab() -> Control:
	var p := _page()
	for action: StringName in InputSetup.REMAPPABLE:
		var b := Button.new()
		b.text = InputSetup.label(action)
		b.pressed.connect(_start_rebind.bind(action))
		_rebind_buttons[action] = b
		_row(p, "ACTION_%s" % String(action).to_upper(), b)
	_row(p, "SET_RESET_BINDINGS", UITheme.button(Loc.t("BTN_RESET"), func() -> void:
		Settings.reset_bindings()
		_refresh_bindings()))
	return p


func _start_rebind(action: StringName) -> void:
	_rebinding = action
	(_rebind_buttons[action] as Button).text = Loc.t("PRESS_KEY")


func _refresh_bindings() -> void:
	for action: StringName in _rebind_buttons.keys():
		(_rebind_buttons[action] as Button).text = InputSetup.label(action)


func _input(event: InputEvent) -> void:
	if _rebinding == &"" or not is_visible_in_tree():
		return
	var accept := false
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.physical_keycode == KEY_ESCAPE:
			_rebinding = &""
			_refresh_bindings()
			get_viewport().set_input_as_handled()
			return
		var e := InputEventKey.new()
		e.physical_keycode = k.physical_keycode
		Settings.set_binding(_rebinding, e)
		accept = true
	elif event is InputEventMouseButton and event.pressed:
		var e := InputEventMouseButton.new()
		e.button_index = (event as InputEventMouseButton).button_index
		Settings.set_binding(_rebinding, e)
		accept = true
	if accept:
		_rebinding = &""
		_refresh_bindings()
		get_viewport().set_input_as_handled()
