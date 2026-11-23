class_name MainMenu
extends Control
## Start screen: key art from the game itself (BG_Menu_Herd), the logo, a column of menu rows, a "now in the game"
## card and key hints. Settings / load / credits open as slabs over a dim layer.

const BACKDROP := "res://assets/ui/BG_Menu_Herd.jpg"
const CARD_ART := "res://assets/ui/BG_Load_Camp.jpg"

var _home: Control
var _rows: Array[Button] = []
var _dim: ColorRect
var _settings: SettingsMenu
var _credits: PanelContainer
var _slots: SaveSlotsPanel


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	var bg := PrimalBackdrop.new()
	bg.texture = load(BACKDROP)
	bg.left_shade = 0.92
	bg.bottom_shade = 0.55
	add_child(bg)
	_home = Control.new()
	_home.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_home.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_home)
	_build_column()
	_build_card()
	_build_footer()
	_build_overlays()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.7).set_trans(Tween.TRANS_SINE)
	_focus_default.call_deferred()


# ---------------------------------------------------------------- layout

func _build_column() -> void:
	var col := VBoxContainer.new()
	col.position = Vector2(64, 44)
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_home.add_child(col)
	col.add_child(PrimalLogo.new())
	var gap := Control.new()
	gap.custom_minimum_size.y = 34
	col.add_child(gap)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 2)
	rows.custom_minimum_size.x = 420
	col.add_child(rows)
	var has_save := SaveManager.has_any_save()
	var day := _latest_day()
	if has_save:
		var sub := Loc.t("MENU_DAY", {"day": day}) if day > 0 else ""
		rows.add_child(_row("play", Loc.t("MENU_CONTINUE"), sub, _on_continue, true))
	rows.add_child(_row("tent", Loc.t("MENU_NEW_GAME"), "" if has_save else Loc.t("MENU_SOLO"), Game.new_game, not has_save))
	var load_row := _row("load", Loc.t("MENU_LOAD"), "", _show_load)
	load_row.disabled = not has_save
	rows.add_child(load_row)
	rows.add_child(_row("settings", Loc.t("MENU_SETTINGS"), "", _show_settings))
	var mp := _row("tribe", Loc.t("MENU_MULTIPLAYER"), Loc.t("MENU_SOON"), func() -> void: pass)
	mp.disabled = true
	mp.tooltip_text = Loc.t("MP_LATER")
	rows.add_child(mp)
	rows.add_child(_row("credits", Loc.t("MENU_CREDITS"), "", _show_credits))
	rows.add_child(_row("power", Loc.t("MENU_QUIT"), "", Game.quit))


func _row(icon_name: String, text: String, sub: String, cb: Callable, primary := false) -> Button:
	var b := _MenuRow.new()
	b.icon_name = icon_name
	b.title = text
	b.subtitle = sub
	b.primary = primary
	b.pressed.connect(cb)
	b.pressed.connect(Sfx.ui_click)
	_rows.append(b)
	return b


func _build_card() -> void:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.slab_box(20.0))
	card.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	card.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	card.grow_vertical = Control.GROW_DIRECTION_BEGIN
	card.offset_right = -48
	card.offset_bottom = -78
	card.custom_minimum_size.x = 360
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_home.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	card.add_child(v)
	var art := TextureRect.new()
	art.texture = load(CARD_ART)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.custom_minimum_size = Vector2(0, 130)
	art.clip_contents = true
	v.add_child(art)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", UITheme.stroke_box(UITheme.GOLD, 26.0, 9.0))
	badge.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	badge.add_child(UITheme.caption(Loc.t("MENU_NOW").to_upper(), 14, UITheme.INK, 600, 1))
	v.add_child(badge)
	v.add_child(UITheme.caption(Loc.t("MENU_NOW_TITLE"), 22, UITheme.BONE_HI, 600))
	for e: Array in [["damage", "MENU_NOW_HERDS"], ["fire", "MENU_NOW_CAMP"], ["map", "MENU_NOW_WORLD"]]:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		var ic := TextureRect.new()
		ic.texture = UITheme.icon(e[0], UITheme.GOLD, 18)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		h.add_child(ic)
		var l := UITheme.label(Loc.t(e[1]), "SmallLabel")
		l.add_theme_color_override("font_color", Color(UITheme.BONE, 0.86))
		h.add_child(l)
		v.add_child(h)


func _build_footer() -> void:
	var hints := HBoxContainer.new()
	hints.add_theme_constant_override("separation", 28)
	hints.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	hints.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hints.offset_left = 72
	hints.offset_bottom = -26
	hints.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hints.add_child(UITheme.hint("↑↓", Loc.t("HINT_NAV")))
	hints.add_child(UITheme.hint("Enter", Loc.t("HINT_CONFIRM")))
	_home.add_child(hints)
	var build := UITheme.caption(Loc.t("BUILD_INFO"), 14, Color(UITheme.BONE, 0.55), 400, 1)
	build.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	build.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	build.grow_vertical = Control.GROW_DIRECTION_BEGIN
	build.offset_right = -52
	build.offset_bottom = -30
	_home.add_child(build)


func _build_overlays() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0.02, 0.015, 0.01, 0.72)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.visible = false
	_dim.gui_input.connect(_dim_clicked)
	add_child(_dim)
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
	_slots = SaveSlotsPanel.new()
	_slots.visible = false
	_slots.mode = "load"
	_slots.closed.connect(_back)
	_slots.slot_chosen.connect(_on_slot)
	center.add_child(_slots)


func _latest_day() -> int:
	var day := 0
	var best := -1.0
	for info: Dictionary in SaveManager.list_slots():
		if info.exists and float(info.saved_at) > best:
			best = float(info.saved_at)
			day = int(info.day)
	return day


func _focus_default() -> void:
	for b in _rows:
		if not b.disabled:
			b.grab_focus()
			return


# ---------------------------------------------------------------- actions

func _on_continue() -> void:
	Game.continue_game()


func _show_settings() -> void:
	_open_overlay(_settings)
	_settings.focus_first.call_deferred()


func _show_credits() -> void:
	_open_overlay(_credits)
	(_credits.get_child(0).get_child(-1) as Button).grab_focus.call_deferred()


func _show_load() -> void:
	_open_overlay(_slots)
	_slots.refresh()


func _on_slot(slot: String) -> void:
	Game.load_slot(slot)


func _open_overlay(panel: Control) -> void:
	_home.visible = false
	_dim.visible = true
	UITheme.show_animated(panel, true)


func _back() -> void:
	_settings.visible = false
	_credits.visible = false
	_slots.visible = false
	_dim.visible = false
	_home.visible = true
	_focus_default()


func _dim_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_back()
		get_viewport().set_input_as_handled()


func _build_credits() -> PanelContainer:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(660, 0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	p.add_child(v)
	v.add_child(UITheme.label(Loc.t("MENU_CREDITS").to_upper(), "HeadingLabel"))
	var l := UITheme.label(Loc.t("CREDITS_TEXT"), "SmallLabel")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(l)
	var back := UITheme.button(Loc.t("BTN_BACK"), _back)
	back.size_flags_horizontal = Control.SIZE_SHRINK_END
	v.add_child(back)
	return p


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause") and not _home.visible:
		_back()
		get_viewport().set_input_as_handled()


## One menu entry: icon, title, optional second line. Primary = painted ochre stroke; others get a dark stroke
## and gold text on hover / focus.
class _MenuRow:
	extends Button

	var icon_name := ""
	var title := ""
	var subtitle := ""
	var primary := false
	var _icon: TextureRect
	var _title: Label
	var _sub: Label

	func _ready() -> void:
		focus_mode = FOCUS_ALL
		custom_minimum_size = Vector2(420, 84 if primary else 54)
		var idle := StyleBoxEmpty.new()
		var lit := UITheme.stroke_box(Color(0.06, 0.04, 0.028, 0.9), 0.0, 0.0)
		var gold := UITheme.stroke_box(UITheme.GOLD, 0.0, 0.0)
		var gold_hi := UITheme.stroke_box(UITheme.GOLD_HI, 0.0, 0.0)
		add_theme_stylebox_override("normal", gold if primary else idle)
		add_theme_stylebox_override("hover", gold_hi if primary else lit)
		add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		add_theme_stylebox_override("pressed", gold_hi)
		add_theme_stylebox_override("hover_pressed", gold_hi)
		add_theme_stylebox_override("disabled", idle)
		var h := HBoxContainer.new()
		h.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		h.offset_left = 28
		h.offset_right = -16
		h.add_theme_constant_override("separation", 18)
		h.mouse_filter = MOUSE_FILTER_IGNORE
		add_child(h)
		_icon = TextureRect.new()
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		_icon.custom_minimum_size = Vector2(30, 0)
		_icon.mouse_filter = MOUSE_FILTER_IGNORE
		h.add_child(_icon)
		var v := VBoxContainer.new()
		v.alignment = BoxContainer.ALIGNMENT_CENTER
		v.add_theme_constant_override("separation", -6)
		v.mouse_filter = MOUSE_FILTER_IGNORE
		h.add_child(v)
		_title = UITheme.caption(title.to_upper(), 27 if primary else 23, UITheme.BONE, 600 if primary else 500, 2)
		_title.add_theme_constant_override("outline_size", 0)
		v.add_child(_title)
		if subtitle != "":
			_sub = UITheme.caption(subtitle, 15, UITheme.BONE, 400, 1)
			v.add_child(_sub)
		mouse_entered.connect(_paint)
		mouse_exited.connect(_paint)
		focus_entered.connect(_paint)
		focus_exited.connect(_paint)
		mouse_entered.connect(func() -> void:
			if not disabled:
				grab_focus())
		_paint()

	func _paint() -> void:
		var hot := (is_hovered() or has_focus()) and not disabled
		if hot and not primary:
			add_theme_stylebox_override("normal", UITheme.stroke_box(Color(0.06, 0.04, 0.028, 0.9), 0.0, 0.0))
		elif not primary:
			add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		else:
			add_theme_stylebox_override("normal", UITheme.stroke_box(UITheme.GOLD_HI if hot else UITheme.GOLD, 0.0, 0.0))
		var ink: Color
		if primary:
			ink = UITheme.INK
		elif disabled:
			ink = Color(UITheme.BONE, 0.38)
		else:
			ink = UITheme.GOLD_HI if hot else UITheme.BONE
		_title.add_theme_color_override("font_color", ink)
		if _sub:
			_sub.add_theme_color_override("font_color", Color(ink, 0.78))
		_icon.texture = UITheme.icon(icon_name, ink, 26)
		if hot and not primary:
			_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
