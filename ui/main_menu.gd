class_name MainMenu
extends Control
## Main menu (GDD §12): Continue, New Game, Multiplayer (disabled), Settings, Credits, Quit.

var _buttons: VBoxContainer
var _left: PanelContainer
var _settings: SettingsMenu
var _credits: PanelContainer
var _continue: Button


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	var grad := TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, Color(UITheme.CHARCOAL, 0.92))
	g.set_color(1, Color(UITheme.CHARCOAL, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	grad.texture = gt
	grad.stretch_mode = TextureRect.STRETCH_SCALE
	grad.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	grad.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	grad.offset_right = 820
	grad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(grad)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	margin.add_theme_constant_override("margin_left", 96)
	margin.add_theme_constant_override("margin_top", 110)
	margin.add_theme_constant_override("margin_bottom", 64)
	add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	margin.add_child(v)
	var title := UITheme.label("WILDBOUND", "TitleLabel")
	title.add_theme_font_size_override("font_size", 76)
	v.add_child(title)
	var sub := UITheme.label(Loc.t("GAME_SUBTITLE"), "HeadingLabel")
	sub.add_theme_font_size_override("font_size", 26)
	v.add_child(sub)
	var gap := Control.new()
	gap.custom_minimum_size.y = 56
	v.add_child(gap)
	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 2)
	_buttons.custom_minimum_size.x = 340
	v.add_child(_buttons)
	_continue = _menu_button("MENU_CONTINUE", _on_continue)
	_menu_button("MENU_NEW_GAME", Game.new_game)
	var mp := _menu_button("MENU_MULTIPLAYER", func() -> void: pass)
	mp.disabled = true
	mp.tooltip_text = Loc.t("MP_LATER")
	_menu_button("MENU_SETTINGS", _show_settings)
	_menu_button("MENU_CREDITS", _show_credits)
	_menu_button("MENU_QUIT", Game.quit)
	var filler := Control.new()
	filler.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(filler)
	v.add_child(UITheme.label(Loc.t("BUILD_INFO"), "MutedLabel"))

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_settings = SettingsMenu.new()
	_settings.visible = false
	_settings.closed.connect(_back)
	center.add_child(_settings)
	_credits = _build_credits()
	_credits.visible = false
	center.add_child(_credits)
	_left = null
	_continue.disabled = not SaveManager.has_any_save()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.6)
	_focus_default.call_deferred()


func _menu_button(key: String, cb: Callable) -> Button:
	var b := UITheme.button(Loc.t(key), cb, "MenuButtonBig")
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_buttons.add_child(b)
	return b


func _focus_default() -> void:
	for b: Button in _buttons.get_children():
		if not b.disabled:
			b.grab_focus()
			return


func _on_continue() -> void:
	Game.continue_game()


func _show_settings() -> void:
	_buttons.visible = false
	UITheme.show_animated(_settings, true)
	_settings.focus_first.call_deferred()


func _show_credits() -> void:
	_buttons.visible = false
	UITheme.show_animated(_credits, true)
	(_credits.get_child(0).get_child(-1) as Button).grab_focus.call_deferred()


func _back() -> void:
	_settings.visible = false
	_credits.visible = false
	_buttons.visible = true
	_focus_default()


func _build_credits() -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(620, 0)
	var v := VBoxContainer.new()
	p.add_child(v)
	v.add_child(UITheme.label(Loc.t("MENU_CREDITS"), "HeadingLabel"))
	v.add_child(HSeparator.new())
	var l := UITheme.label(Loc.t("CREDITS_TEXT"))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(l)
	v.add_child(UITheme.button(Loc.t("BTN_BACK"), _back))
	return p


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and not _buttons.visible:
		_back()
		get_viewport().set_input_as_handled()
