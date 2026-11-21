class_name BuildMenu
extends Control
## Radial build menu (GDD §12 "Build radial menu"). Mouse, keyboard (Tab/arrows) and gamepad focus work.

signal chosen(piece_id: StringName)
signal closed

const RADIUS := 270.0

var player: Player
var _center: Control
var _buttons: Array[Button] = []
var _title: Label
var _desc: Label
var _cost: RichTextLabel


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.04, 0.03, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_center = Control.new()
	_center.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	add_child(_center)
	var ring := Control.new()
	ring.draw.connect(func() -> void:
		ring.draw_arc(Vector2.ZERO, RADIUS, 0, TAU, 96, Color(UITheme.OCHRE, 0.25), 2.0, true)
		ring.draw_circle(Vector2.ZERO, RADIUS - 70, Color(UITheme.CHARCOAL, 0.55)))
	_center.add_child(ring)
	var info := VBoxContainer.new()
	info.custom_minimum_size = Vector2(330, 0)
	info.position = Vector2(-165, -120)
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	_center.add_child(info)
	var head := UITheme.label(Loc.t("BUILD_MENU_TITLE"), "MutedLabel")
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_child(head)
	_title = UITheme.label("", "HeadingLabel")
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_child(_title)
	_desc = UITheme.label("", "SmallLabel")
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_child(_desc)
	_cost = RichTextLabel.new()
	_cost.bbcode_enabled = true
	_cost.fit_content = true
	_cost.scroll_active = false
	_cost.add_theme_color_override("default_color", UITheme.BONE)
	_cost.add_theme_font_size_override("normal_font_size", 16)
	info.add_child(_cost)
	var hint := UITheme.label(Loc.t("BUILD_MENU_HINT"), "MutedLabel")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_child(hint)
	var ids := ItemDB.piece_order
	for i in ids.size():
		var id: StringName = ids[i]
		var b := UITheme.button(Loc.t("BUILD_%s" % String(id).to_upper()), _choose.bind(id))
		b.custom_minimum_size = Vector2(196, 50)
		b.icon = _swatch(Color(str(ItemDB.get_piece(id).get("icon", "#888888"))))
		var a := -PI * 0.5 + TAU * i / ids.size()
		b.position = Vector2(cos(a), sin(a)) * RADIUS - b.custom_minimum_size * 0.5
		b.mouse_entered.connect(_show_info.bind(id))
		b.focus_entered.connect(_show_info.bind(id))
		_center.add_child(b)
		_buttons.append(b)


func _swatch(c: Color) -> Texture2D:
	var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)


func open() -> void:
	UITheme.show_animated(self, true)
	_show_info(ItemDB.piece_order[0])
	_buttons[0].grab_focus.call_deferred()


func close() -> void:
	UITheme.show_animated(self, false)
	closed.emit()


func _choose(id: StringName) -> void:
	visible = false
	chosen.emit(id)


func _show_info(id: StringName) -> void:
	_title.text = Loc.t("BUILD_%s" % String(id).to_upper())
	_desc.text = Loc.t("BUILD_%s_DESC" % String(id).to_upper())
	var lines := PackedStringArray(["[center]" + Loc.t("BUILD_COST")])
	var cost := ItemDB.piece_cost(id)
	for item: StringName in cost.keys():
		var have := player.inventory.count_of(item) if player else 0
		var need := int(cost[item])
		lines.append("[color=%s]%s  %d / %d[/color]" % ["#B7C99A" if have >= need else "#D98B7A",
			ItemDB.get_item(item).display_name(), mini(have, need), need])
	_cost.text = "\n".join(lines) + "[/center]"


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("build_menu") or event.is_action_pressed("pause") or event.is_action_pressed("inventory"):
		close()
		get_viewport().set_input_as_handled()
