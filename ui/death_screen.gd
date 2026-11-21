class_name DeathScreen
extends Control
## Shown when the player dies: cause + load last save / main menu.

var _cause: Label
var _load_btn: Button


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.02, 0.02, 0.85)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 14)
	center.add_child(v)
	var t := UITheme.label(Loc.t("DEATH_TITLE"), "TitleLabel")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_color_override("font_color", UITheme.DANGER.lightened(0.15))
	v.add_child(t)
	_cause = UITheme.label("", "MutedLabel")
	_cause.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cause.add_theme_font_size_override("font_size", 20)
	v.add_child(_cause)
	_load_btn = UITheme.button(Loc.t("BTN_LOAD_LAST"), func() -> void: Game.continue_game(), "MenuButtonBig")
	v.add_child(_load_btn)
	v.add_child(UITheme.button(Loc.t("MENU_MAIN_MENU"), Game.to_main_menu, "MenuButtonBig"))


func show_death(cause: StringName) -> void:
	_cause.text = Loc.t("DEATH_%s" % String(cause).to_upper())
	_load_btn.disabled = not SaveManager.has_any_save()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	UITheme.show_animated(self, true)
	var focus_btn: Button = _load_btn if not _load_btn.disabled else _load_btn.get_parent().get_child(3)
	focus_btn.grab_focus.call_deferred()
