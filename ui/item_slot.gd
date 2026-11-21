class_name ItemSlot
extends PanelContainer
## One inventory/hand slot: PLACEHOLDER icon (item colour + initials), count, durability.
## Supports drag & drop between bag slots and the hand slot.

signal clicked(slot: ItemSlot, button: int, double: bool)

const HAND := -1

var inventory: Inventory
var index := 0
var compact := false
var highlight := false
var hotkey := ""
var selected := false:
	set(v):
		selected = v
		_apply_style()

var _icon: Panel
var _initials: Label
var _tex: TextureRect
var _count: Label
var _key: Label
var _dur: ProgressBar
var _last_sig := ""


func _ready() -> void:
	var px := 58.0 if compact else 66.0
	custom_minimum_size = Vector2(px, px)
	mouse_filter = Control.MOUSE_FILTER_PASS if compact else Control.MOUSE_FILTER_STOP
	if compact:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)
	_icon = Panel.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon.offset_left = 7
	_icon.offset_top = 7
	_icon.offset_right = -7
	_icon.offset_bottom = -9
	overlay.add_child(_icon)
	_initials = UITheme.label("", "SmallLabel")
	_initials.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_initials.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_initials.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_initials.add_theme_font_size_override("font_size", 14)
	_icon.add_child(_initials)
	_tex = TextureRect.new()
	_tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tex.offset_left = 3
	_tex.offset_top = 3
	_tex.offset_right = -3
	_tex.offset_bottom = -5
	_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(_tex)
	overlay.move_child(_tex, 1)
	_count = UITheme.label("", "SmallLabel")
	_count.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_count.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_count.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_count.position = Vector2(-4, -6)
	_count.add_theme_font_size_override("font_size", 14)
	overlay.add_child(_count)
	_key = UITheme.label(hotkey, "MutedLabel")
	_key.position = Vector2(-2, -6)
	_key.add_theme_font_size_override("font_size", 12)
	overlay.add_child(_key)
	_dur = UITheme.bar(UITheme.BONE, 3.0)
	_dur.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_dur.offset_left = 7
	_dur.offset_right = -7
	_dur.offset_top = -6
	_dur.offset_bottom = -3
	_dur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(_dur)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_apply_style()


func stack() -> ItemStack:
	if inventory == null:
		return null
	return inventory.hand if index == HAND else inventory.get_slot(index)


func _process(_delta: float) -> void:
	var s := stack()
	var sig := "" if s == null else "%s|%d|%d" % [s.id, s.count, s.durability]
	if sig == _last_sig:
		return
	_last_sig = sig
	_refresh(s)


func _refresh(s: ItemStack) -> void:
	var data := s.get_data() if s else null
	var icon := AssetLib.item_icon(data.id) if data else null
	_tex.texture = icon
	_tex.visible = icon != null
	_icon.visible = data != null and icon == null
	_count.visible = s != null and s.count > 1
	_dur.visible = data != null and data.has_durability()
	tooltip_text = ""
	if data == null:
		return
	var st := UITheme.flat(data.icon_color, Color(0, 0, 0, 0.4), 1, 6, 0.0)
	_icon.add_theme_stylebox_override("panel", st)
	var words := data.display_name().split(" ", false)
	var initials := ""
	for w in words.slice(0, 2):
		initials += w.substr(0, 1).to_upper()
	if words.size() == 1:
		initials = words[0].substr(0, 2)
	_initials.text = initials
	_initials.add_theme_color_override("font_color", Color.BLACK if data.icon_color.get_luminance() > 0.55 else UITheme.BONE)
	_count.text = str(s.count)
	_dur.value = s.durability_ratio() * 100.0
	if not compact:
		tooltip_text = ItemSlot.describe(s)


static func describe(s: ItemStack) -> String:
	var d := s.get_data()
	var lines := PackedStringArray([d.display_name(), d.description(), ""])
	lines.append(Loc.t("TIP_CATEGORY", {"v": Loc.t("CAT_%s" % String(d.category).to_upper())}))
	lines.append(Loc.t("TIP_WEIGHT", {"v": "%.2f" % (d.weight * s.count)}))
	if d.has_durability():
		lines.append(Loc.t("TIP_DURABILITY", {"v": s.durability, "max": d.max_durability}))
	if d.food > 0.0 or d.water > 0.0:
		lines.append(Loc.t("TIP_NUTRITION", {"f": int(d.food), "w": int(d.water)}))
	if d.is_fuel():
		lines.append(Loc.t("TIP_FUEL", {"v": int(d.fuel_seconds / 60.0)}))
	if d.is_cookable():
		lines.append(Loc.t("TIP_COOKABLE"))
	if AssetLib.item_model_path(d.id) == "":
		lines.append(Loc.t("TIP_PLACEHOLDER"))
	return "\n".join(lines)


func _apply_style() -> void:
	var border := Color(UITheme.BONE, 0.12)
	var bw := 1
	if highlight:
		border = Color(UITheme.OCHRE, 0.7)
	if selected:
		border = UITheme.OCHRE
		bw = 2
	add_theme_stylebox_override("panel", UITheme.flat(Color(UITheme.CHARCOAL, 0.72), border, bw, 4, 0.0))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		clicked.emit(self, mb.button_index, mb.double_click)


func _get_drag_data(_pos: Vector2) -> Variant:
	var s := stack()
	if s == null:
		return null
	var preview := Panel.new()
	preview.custom_minimum_size = Vector2(44, 44)
	preview.size = Vector2(44, 44)
	preview.add_theme_stylebox_override("panel", UITheme.flat(Color(UITheme.CHARCOAL, 0.6), UITheme.OCHRE, 1, 6, 0.0))
	var pic := TextureRect.new()
	pic.texture = AssetLib.item_icon(s.id)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview.add_child(pic)
	set_drag_preview(preview)
	return {"slot_index": index, "inv": inventory}


func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
	return data is Dictionary and (data as Dictionary).has("slot_index") and inventory != null \
		and (data as Dictionary).get("inv") == inventory


func _drop_data(_pos: Vector2, data: Variant) -> void:
	var from: int = data.slot_index
	if from == index:
		return
	if index == HAND:
		inventory.equip_slot(from)
	elif from == HAND:
		if inventory.get_slot(index) == null:
			inventory.slots[index] = inventory.hand
			inventory.hand = null
			inventory.changed.emit()
		else:
			inventory.equip_slot(index)
	else:
		inventory.swap_slots(from, index)
