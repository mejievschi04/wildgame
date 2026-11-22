class_name BuildMenu
extends Control
## Radial build menu (GDD §12 "Build radial menu"). Mouse, keyboard (Tab/arrows) and gamepad focus work.
## The centre shows a live, slowly turning 3D preview of the hovered piece (its own little world).

signal chosen(piece_id: StringName)
signal closed

const RADIUS := 270.0
## Arc length per button on the ring: the ring grows with the number of pieces so buttons never overlap.
const SLOT_ARC := 188.0

var player: Player
var _center: Control
var _buttons: Array[Button] = []
var _title: Label
var _desc: Label
var _cost: RichTextLabel
var _radius := RADIUS
## The ring is an ellipse: wide enough for every button, short enough to clear the hotbar at the bottom.
var _rx := RADIUS
var _ry := RADIUS
var _pv_pivot: Node3D
var _pv_cam: Camera3D
var _pv_id: StringName = &""


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
	_radius = maxf(RADIUS, ItemDB.piece_order.size() * SLOT_ARC / TAU)
	_ry = minf(_radius, 300.0)  # UI units: below the centre text, above the hotbar
	_rx = minf(_radius * _radius / _ry, 540.0)
	var ring := Control.new()
	ring.draw.connect(func() -> void:
		var pts := PackedVector2Array()
		for k in 97:
			pts.append(Vector2(cos(TAU * k / 96.0) * _rx, sin(TAU * k / 96.0) * _ry))
		ring.draw_polyline(pts, Color(UITheme.OCHRE, 0.25), 2.0, true)
		ring.draw_circle(Vector2.ZERO, _ry - 70, Color(UITheme.CHARCOAL, 0.55)))
	_center.add_child(ring)
	var info := VBoxContainer.new()
	info.custom_minimum_size = Vector2(330, 0)
	info.position = Vector2(-165, -270)
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	_center.add_child(info)
	info.add_child(_build_preview())
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
		b.custom_minimum_size = Vector2(176, 46)
		b.icon = _swatch(Color(str(ItemDB.get_piece(id).get("icon", "#888888"))))
		var a := -PI * 0.5 + TAU * i / ids.size()
		b.position = Vector2(cos(a) * _rx, sin(a) * _ry) - b.custom_minimum_size * 0.5
		b.mouse_entered.connect(_show_info.bind(id))
		b.focus_entered.connect(_show_info.bind(id))
		_center.add_child(b)
		_buttons.append(b)


## Little 3D stage for the piece preview: own world, soft daylight, transparent background.
func _build_preview() -> Control:
	var holder := SubViewportContainer.new()
	holder.custom_minimum_size = Vector2(330, 160)
	holder.stretch = true
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	holder.add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.6, 0.56)
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	vp.add_child(sun)
	_pv_cam = Camera3D.new()
	_pv_cam.fov = 32.0
	vp.add_child(_pv_cam)
	_pv_pivot = Node3D.new()
	vp.add_child(_pv_pivot)
	return holder


func _show_preview(id: StringName) -> void:
	if id == _pv_id or _pv_pivot == null or not _pv_pivot.is_inside_tree():
		return
	_pv_id = id
	for c in _pv_pivot.get_children():
		c.queue_free()
	var v := BuildingVisuals.build(id, 0, 1)
	_pv_pivot.add_child(v)
	var box := AABB()
	var first := true
	var inv := _pv_pivot.global_transform.affine_inverse()
	for mi: MeshInstance3D in v.find_children("*", "MeshInstance3D", true, false):
		var b := (inv * mi.global_transform) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	var c := box.get_center()
	v.position = Vector3(-c.x, 0, -c.z)  # spin about the piece centre
	var dist := box.size.length() * 1.35 + 0.6
	_pv_cam.position = Vector3(0, c.y + dist * 0.42, dist)
	_pv_cam.look_at(Vector3(0, c.y, 0))


func _process(delta: float) -> void:
	if visible and _pv_pivot:
		_pv_pivot.rotate_y(delta * 0.5)


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
	_show_preview(id)
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
