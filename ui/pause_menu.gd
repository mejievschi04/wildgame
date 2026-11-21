class_name PauseMenu
extends Control
## Pause overlay: resume, save, load, settings, main menu, quit. Pauses the SceneTree.

signal resumed
signal save_requested(slot: String)

var _main: VBoxContainer
var _settings: SettingsMenu
var _slots: SaveSlotsPanel
var _day_label: Label
var day_text_provider: Callable


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.03, 0.66)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(380, 0)
	_main = VBoxContainer.new()
	_main.add_theme_constant_override("separation", 6)
	panel.add_child(_main)
	center.add_child(panel)
	_main.add_child(UITheme.label(Loc.t("MENU_PAUSED"), "HeadingLabel"))
	_day_label = UITheme.label("", "MutedLabel")
	_main.add_child(_day_label)
	_main.add_child(HSeparator.new())
	_main.add_child(UITheme.button(Loc.t("MENU_RESUME"), resume, "MenuButtonBig"))
	_main.add_child(UITheme.button(Loc.t("MENU_SAVE"), _show_slots.bind("save"), "MenuButtonBig"))
	_main.add_child(UITheme.button(Loc.t("MENU_LOAD"), _show_slots.bind("load"), "MenuButtonBig"))
	_main.add_child(UITheme.button(Loc.t("MENU_SETTINGS"), _show_settings, "MenuButtonBig"))
	_main.add_child(UITheme.button(Loc.t("MENU_MAIN_MENU"), Game.to_main_menu, "MenuButtonBig"))
	_main.add_child(UITheme.button(Loc.t("MENU_QUIT"), Game.quit, "MenuButtonBig"))
	_settings = SettingsMenu.new()
	_settings.visible = false
	_settings.closed.connect(_back)
	center.add_child(_settings)
	_slots = SaveSlotsPanel.new()
	_slots.visible = false
	_slots.closed.connect(_back)
	_slots.slot_chosen.connect(_on_slot)
	center.add_child(_slots)
	_main.set_meta("panel", panel)


func open() -> void:
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if day_text_provider.is_valid():
		_day_label.text = day_text_provider.call()
	_back()
	UITheme.show_animated(self, true)


func resume() -> void:
	get_tree().paused = false
	UITheme.show_animated(self, false)
	resumed.emit()


func _panel() -> PanelContainer:
	return _main.get_meta("panel")


func _back() -> void:
	_settings.visible = false
	_slots.visible = false
	_panel().visible = true
	(_main.get_child(3) as Button).grab_focus.call_deferred()


func _show_settings() -> void:
	_panel().visible = false
	_settings.visible = true
	_settings.focus_first.call_deferred()


func _show_slots(mode: String) -> void:
	_panel().visible = false
	_slots.mode = mode
	_slots.visible = true
	_slots.refresh()


func _on_slot(slot: String) -> void:
	if _slots.mode == "save":
		save_requested.emit(slot)
		_slots.refresh()
	else:
		Game.load_slot(slot)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("pause"):
		if _panel().visible:
			resume()
		else:
			_back()
		get_viewport().set_input_as_handled()
