class_name InventoryScreen
extends Control
## Inventory, craft and journal in one tabbed screen, in the shared UITheme look: a tab strip with painted underline,
## a scraped hide holding the item grid (cave paintings and the vitals ring on its left), stone-slab cards on the right.
## Build opens the build menu. Skills and tribe are placeholders until those systems exist.

signal closed
signal build_requested


var player: Player
var _tab := 0
var _pages: Array[Control] = []
var _tab_buttons: Array[Button] = []
## Visual tab order. Page index, or -1 to open the build menu.
var _tab_pages: Array[int] = [0, 2, -1, 3, 4, 1]
const SECTIONS := [["POUCH_WEAPONS", [&"weapon", &"tool"]], ["POUCH_FOOD", [&"food", &"drink"]],
	["POUCH_MEDICAL", [&"medical"]], ["POUCH_CAMP", [&"placeable"]], ["POUCH_MATERIALS", [&"resource"]]]
const GROUPS: Array[StringName] = [&"arms", &"ranged", &"tools", &"materials", &"shelter", &"fire", &"food", &"other"]
const CELL := 96.0
## Pouch cell size, fitted to the sheet width (6 columns).
var _cell_px := CELL
const RECIPE_CELL := 112.0

var _pouch: GridContainer
var _space_label: Label
var _selected_id: StringName = &""
var _selected_hand := false
var _detail_title: Label
var _detail_cat: Label
var _detail_text: Label
var _detail_icon: TextureRect
var _detail_bars: VBoxContainer
var _detail_buttons: HBoxContainer
var _weight_label: Label
var _vitals: _Vitals
var _recipe_list: GridContainer
var _recipe_title: Label
var _recipe_cat: Label
var _recipe_desc: Label
var _recipe_icon: TextureRect
var _recipe_needs: HBoxContainer
var _recipe_text: RichTextLabel
var _craft_button: Button
var _craft_progress: ProgressBar
var _selected_recipe: RecipeData
var _crafting_tween: Tween
var _group: StringName = &"arms"
var _group_buttons: Array[Button] = []
var _journal_text: RichTextLabel
var _bar_inv: HBoxContainer
var _bar_craft: HBoxContainer
var _bar_close: Button
var _dirty := true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	visible = false
	var shade := _Shade.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 32
	root.offset_top = 10
	root.offset_right = -32
	root.offset_bottom = -12
	root.add_theme_constant_override("separation", 14)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.add_child(_build_tabs())
	var pages := Control.new()
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(pages)
	_pages.append(_build_inventory_page())
	_pages.append(_build_journal_page())
	_pages.append(_build_craft_page())
	_pages.append(_soon_page("skills"))
	_pages.append(_soon_page("tribe"))
	for p in _pages:
		p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pages.add_child(p)
	root.add_child(_build_bar())
	_set_tab(0)
	Events.journal_added.connect(func(_k: String) -> void: _dirty = true)


func bind(p: Player) -> void:
	player = p
	p.inventory.changed.connect(func() -> void: _dirty = true)


func open(tab: int = 0) -> void:
	_set_tab(tab)
	_dirty = true
	UITheme.show_animated(self, true)
	await get_tree().process_frame
	if _tab == 0:
		var first := _pouch.find_children("*", "Button", true, false)
		if not first.is_empty():
			(first[0] as Button).grab_focus()


func close() -> void:
	_cancel_craft()
	UITheme.show_animated(self, false)
	closed.emit()


func _set_tab(i: int) -> void:
	if i < 0:
		close()
		build_requested.emit()
		return
	_tab = i
	for j in _pages.size():
		_pages[j].visible = j == i
	for b in _tab_buttons:
		(b as _Tab).active = int(b.get_meta("page")) == i
	if _bar_inv:
		_bar_inv.visible = i == 0
		_bar_craft.visible = i == 2
		_bar_close.text = Loc.t("BTN_BACK") if i == 2 else Loc.t("INV_BAR_CLOSE")
	_dirty = true


func _cycle_tab(step: int) -> void:
	var at := _tab_pages.find(_tab)
	if at < 0:
		at = 0
	_set_tab(_tab_pages[posmod(at + step, _tab_pages.size())])


# ---------------------------------------------------------------- layout: frame

func _build_tabs() -> Control:
	var strip := HBoxContainer.new()
	strip.alignment = BoxContainer.ALIGNMENT_CENTER
	strip.add_theme_constant_override("separation", 6)
	strip.custom_minimum_size.y = 58
	strip.add_child(_centered(UITheme.keycap(InputSetup.label(&"weapon_wheel"))))
	var keys := ["TAB_INVENTORY", "TAB_CRAFT", "TAB_BUILD", "TAB_SKILLS", "TAB_TRIBE", "TAB_JOURNAL"]
	var icons := ["bag", "hand", "tent", "skills", "tribe", "book"]
	for i in keys.size():
		var page: int = _tab_pages[i]
		var b := _Tab.new()
		b.title = Loc.t(keys[i]).to_upper()
		b.icon_name = icons[i]
		b.set_meta("page", page)
		b.pressed.connect(_set_tab.bind(page))
		b.pressed.connect(Sfx.ui_click)
		strip.add_child(b)
		_tab_buttons.append(b)
	strip.add_child(_centered(UITheme.keycap(InputSetup.label(&"interact"))))
	return strip


func _centered(c: Control) -> Control:
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return c


func _build_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.custom_minimum_size.y = 40
	bar.add_theme_constant_override("separation", 40)
	var lead := Control.new()
	lead.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(lead)
	_bar_inv = HBoxContainer.new()
	_bar_inv.add_theme_constant_override("separation", 40)
	_bar_inv.add_child(UITheme.hint("@mouse_l", Loc.t("HINT_SELECT")))
	_bar_inv.add_child(_bar_button("@mouse_r", Loc.t("INV_BAR_USE"), _primary_use))
	_bar_inv.add_child(_bar_button("", Loc.t("INV_BAR_DROP"), _drop_selected))
	bar.add_child(_bar_inv)
	_bar_craft = HBoxContainer.new()
	_bar_craft.add_theme_constant_override("separation", 40)
	_bar_craft.add_child(UITheme.hint("@mouse_l", Loc.t("HINT_SELECT")))
	_bar_craft.add_child(_bar_button("@hand", Loc.t("CRAFT_DO"), _on_craft_pressed))
	bar.add_child(_bar_craft)
	bar.add_child(UITheme.hint(InputSetup.label(&"weapon_wheel") + " " + InputSetup.label(&"interact"), Loc.t("HINT_TAB")))
	var mid := Control.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(mid)
	_bar_close = _bar_button("Esc", Loc.t("INV_BAR_CLOSE"), close)
	bar.add_child(_bar_close)
	var tail := Control.new()
	tail.custom_minimum_size.x = 8
	bar.add_child(tail)
	return bar


## A clickable key hint: keycap or icon, then the action name; hover paints a dark stroke.
func _bar_button(key: String, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 16)
	b.add_theme_font_override("font", UITheme.display_font(400))
	var plain := StyleBoxEmpty.new()
	plain.content_margin_left = 10
	plain.content_margin_right = 12
	for st in ["normal", "pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(st, plain)
	b.add_theme_stylebox_override("hover", UITheme.stroke_box(Color(0, 0, 0, 0.6), 10.0, 4.0))
	b.add_theme_color_override("font_color", UITheme.BONE)
	b.add_theme_color_override("font_pressed_color", UITheme.GOLD)
	if key.begins_with("@"):
		b.icon = UITheme.icon(key.substr(1), UITheme.BONE, 22)
		b.add_theme_constant_override("h_separation", 10)
	elif key != "":
		var cap := UITheme.keycap(key)
		cap.position = Vector2(-cap.get_combined_minimum_size().x - 2, 6)
		b.add_child(cap)
	b.pressed.connect(cb)
	b.pressed.connect(Sfx.ui_click)
	return b


func _drop_selected() -> void:
	if _selected_hand:
		player.drop_hand()
		return
	var i := _selected_slot()
	if i >= 0:
		player.drop_slot(i)


# ---------------------------------------------------------------- layout: inventory

func _build_inventory_page() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 18)
	var sheet := PanelContainer.new()
	sheet.add_theme_stylebox_override("panel", UITheme.hide_box(44.0))
	sheet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sheet)
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 22)
	sheet.add_child(sh)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 196
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sh.add_child(left)
	var art := _CaveArt.new()
	art.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(art)
	_vitals = _Vitals.new()
	_vitals.custom_minimum_size = Vector2(196, 196)
	left.add_child(_vitals)
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 10)
	sh.add_child(mid)
	var pscroll := ScrollContainer.new()
	pscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pscroll.resized.connect(func() -> void:
		var px := clampf(floorf((pscroll.size.x - 5 * 10 - 4) / 6.0), 84.0, 132.0)
		if absf(px - _cell_px) > 0.5:
			_cell_px = px
			_dirty = true)
	mid.add_child(pscroll)
	_pouch = GridContainer.new()
	_pouch.columns = 6
	_pouch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pouch.add_theme_constant_override("h_separation", 10)
	_pouch.add_theme_constant_override("v_separation", 10)
	pscroll.add_child(_pouch)
	_space_label = UITheme.caption("", 15, Color(UITheme.BONE, 0.72), 400, 1)
	mid.add_child(_space_label)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(420, 0)
	card.add_theme_stylebox_override("panel", UITheme.slab_box(30.0))
	h.add_child(card)
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 8)
	card.add_child(detail)
	_detail_title = UITheme.caption("", 32, UITheme.BONE_HI, 600, 1)
	_detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_child(_detail_title)
	_detail_cat = UITheme.caption("", 18, UITheme.GOLD, 400, 1)
	detail.add_child(_detail_cat)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	detail.add_child(top)
	_detail_text = UITheme.label("", "SmallLabel")
	_detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_detail_text.add_theme_color_override("font_color", Color(UITheme.BONE, 0.88))
	top.add_child(_detail_text)
	_detail_icon = _big_icon(170)
	top.add_child(_detail_icon)
	detail.add_child(_rule())
	_detail_bars = VBoxContainer.new()
	_detail_bars.add_theme_constant_override("separation", 12)
	detail.add_child(_detail_bars)
	detail.add_child(_rule())
	_weight_label = UITheme.caption("", 16, UITheme.BONE, 500, 1)
	detail.add_child(_weight_label)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_child(fill)
	_detail_buttons = HBoxContainer.new()
	_detail_buttons.add_theme_constant_override("separation", 10)
	detail.add_child(_detail_buttons)
	return h


func _big_icon(px: int) -> TextureRect:
	var t := TextureRect.new()
	t.custom_minimum_size = Vector2(px, px)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


func _rule() -> TextureRect:
	var r := TextureRect.new()
	r.texture = UITheme.tex("Stroke")
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.custom_minimum_size.y = 4
	r.modulate = Color(UITheme.BONE, 0.16)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


# ---------------------------------------------------------------- layout: craft

func _build_craft_page() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 18)
	var banner := PanelContainer.new()
	banner.custom_minimum_size.x = 268
	banner.add_theme_stylebox_override("panel", UITheme.hide_box(30.0))
	h.add_child(banner)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 2)
	banner.add_child(left)
	for g: StringName in GROUPS:
		var tb := Button.new()
		tb.text = Loc.t("CRAFT_CAT_%s" % String(g).to_upper()).to_upper()
		tb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		tb.focus_mode = Control.FOCUS_NONE
		tb.custom_minimum_size.y = 50
		tb.add_theme_constant_override("h_separation", 14)
		tb.add_theme_font_override("font", UITheme.display_font(500, 1))
		tb.add_theme_font_size_override("font_size", 19)
		tb.set_meta("group", g)
		tb.pressed.connect(_pick_group.bind(g))
		tb.pressed.connect(Sfx.ui_click)
		left.add_child(tb)
		_group_buttons.append(tb)
	var hand := TextureRect.new()
	hand.texture = UITheme.tex("Hand")
	hand.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hand.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hand.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hand.custom_minimum_size = Vector2(0, 90)
	hand.modulate = Color("#B4533A", 0.55)
	hand.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(hand)

	var grid_wrap := PanelContainer.new()
	grid_wrap.add_theme_stylebox_override("panel", UITheme.slab_box(22.0, Color(1, 1, 1, 0.82)))
	grid_wrap.custom_minimum_size.x = RECIPE_CELL * 4 + 12 * 3 + 50
	h.add_child(grid_wrap)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	grid_wrap.add_child(scroll)
	_recipe_list = GridContainer.new()
	_recipe_list.columns = 4
	_recipe_list.add_theme_constant_override("h_separation", 12)
	_recipe_list.add_theme_constant_override("v_separation", 12)
	scroll.add_child(_recipe_list)

	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", UITheme.slab_box(34.0))
	h.add_child(card)
	var detail := VBoxContainer.new()
	detail.add_theme_constant_override("separation", 10)
	card.add_child(detail)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	detail.add_child(top)
	var textcol := VBoxContainer.new()
	textcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	textcol.add_theme_constant_override("separation", 8)
	top.add_child(textcol)
	_recipe_title = UITheme.caption("", 34, UITheme.BONE_HI, 600, 1)
	_recipe_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	textcol.add_child(_recipe_title)
	_recipe_cat = UITheme.caption("", 18, UITheme.GOLD, 400, 1)
	textcol.add_child(_recipe_cat)
	_recipe_desc = UITheme.label("", "SmallLabel")
	_recipe_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_recipe_desc.add_theme_color_override("font_color", Color(UITheme.BONE, 0.88))
	textcol.add_child(_recipe_desc)
	var paint := _CaveArt.new()
	paint.compact = true
	paint.custom_minimum_size.y = 84
	textcol.add_child(paint)
	_recipe_icon = _big_icon(230)
	top.add_child(_recipe_icon)
	detail.add_child(_rule())
	detail.add_child(UITheme.caption(Loc.t("CRAFT_NEED").to_upper(), 18, UITheme.GOLD, 500, 1))
	_recipe_needs = HBoxContainer.new()
	_recipe_needs.add_theme_constant_override("separation", 12)
	detail.add_child(_recipe_needs)
	_recipe_text = RichTextLabel.new()
	_recipe_text.bbcode_enabled = true
	_recipe_text.fit_content = true
	_recipe_text.scroll_active = false
	_recipe_text.add_theme_color_override("default_color", UITheme.BONE)
	_recipe_text.add_theme_font_size_override("normal_font_size", 15)
	detail.add_child(_recipe_text)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_child(fill)
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 18)
	detail.add_child(brow)
	_craft_progress = UITheme.bar(UITheme.GOLD, 10.0)
	_craft_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_craft_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_craft_progress.visible = false
	brow.add_child(_craft_progress)
	var pad := Control.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	brow.add_child(pad)
	_craft_progress.visibility_changed.connect(func() -> void: pad.visible = not _craft_progress.visible)
	_craft_button = Button.new()
	_craft_button.text = Loc.t("CRAFT_DO").to_upper()
	_craft_button.custom_minimum_size = Vector2(300, 74)
	_craft_button.focus_mode = Control.FOCUS_ALL
	var bone := Color("#E6D7B8")
	_craft_button.add_theme_stylebox_override("normal", UITheme.stroke_box(bone, 30.0, 10.0))
	_craft_button.add_theme_stylebox_override("hover", UITheme.stroke_box(Color("#F6EBD2"), 30.0, 10.0))
	_craft_button.add_theme_stylebox_override("pressed", UITheme.stroke_box(UITheme.GOLD, 30.0, 10.0))
	_craft_button.add_theme_stylebox_override("hover_pressed", UITheme.stroke_box(UITheme.GOLD, 30.0, 10.0))
	_craft_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_craft_button.add_theme_stylebox_override("disabled", UITheme.stroke_box(Color(0.42, 0.36, 0.28, 0.75), 30.0, 10.0))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		_craft_button.add_theme_color_override(c, UITheme.INK)
	_craft_button.add_theme_color_override("font_disabled_color", Color(UITheme.INK, 0.7))
	_craft_button.add_theme_font_override("font", UITheme.display_font(600, 2))
	_craft_button.add_theme_font_size_override("font_size", 26)
	_craft_button.icon = UITheme.icon("hand", UITheme.INK, 30)
	_craft_button.add_theme_constant_override("h_separation", 14)
	_craft_button.pressed.connect(_on_craft_pressed)
	brow.add_child(_craft_button)
	return h


func _pick_group(g: StringName) -> void:
	_group = g
	_selected_recipe = null
	_dirty = true


func _soon_page(icon_name: String) -> Control:
	var c := CenterContainer.new()
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(520, 220)
	c.add_child(p)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 14)
	p.add_child(v)
	var ic := TextureRect.new()
	ic.texture = UITheme.icon(icon_name, Color(UITheme.GOLD, 0.8), 56)
	ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	v.add_child(ic)
	var l := UITheme.caption(Loc.t("TAB_SOON"), 24, UITheme.BONE, 500, 1)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	return c


func _build_journal_page() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.hide_box(64.0))
	var v := VBoxContainer.new()
	panel.add_child(v)
	v.add_child(UITheme.caption(Loc.t("TAB_JOURNAL").to_upper(), 30, UITheme.GOLD_HI, 600, 2))
	v.add_child(_rule())
	_journal_text = RichTextLabel.new()
	_journal_text.bbcode_enabled = true
	_journal_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_journal_text.add_theme_color_override("default_color", UITheme.BONE)
	_journal_text.add_theme_font_size_override("normal_font_size", 19)
	_journal_text.add_theme_font_override("bold_font", UITheme.display_font(600, 1))
	_journal_text.add_theme_font_size_override("bold_font_size", 23)
	v.add_child(_journal_text)
	return panel


# ---------------------------------------------------------------- refresh

func _process(_delta: float) -> void:
	if not visible or player == null:
		return
	if _dirty:
		_dirty = false
		_refresh_all()
	if _craft_progress.visible == false and _selected_recipe:
		_set_craft_enabled(_recipe_check(_selected_recipe).ok)


func _refresh_all() -> void:
	_vitals.stats = player.stats
	_refresh_pouch()
	_refresh_detail()
	_refresh_recipes()
	_refresh_journal()


func _item_tex(id: StringName) -> Texture2D:
	var t := AssetLib.item_icon(id)
	return t if t else _swatch(ItemDB.get_item(id).icon_color)


## Groups the bag by item kind (all stacks of one item = one cell), ordered by category.
func _refresh_pouch() -> void:
	var inv := player.inventory
	for c in _pouch.get_children():
		c.queue_free()
	var totals := {}
	var order: Array[StringName] = []
	var used := 0
	for st: ItemStack in inv.slots:
		if st == null:
			continue
		used += 1
		if not totals.has(st.id):
			totals[st.id] = [0, 0]
			order.append(st.id)
		totals[st.id][0] += st.count
		totals[st.id][1] = maxi(totals[st.id][1], st.durability)
	_space_label.text = (Loc.t("POUCH_SPACE", {"n": used, "max": inv.size}) + "      "
		+ Loc.t("WEIGHT_FMT", {"w": "%.1f" % inv.total_weight(), "max": "%.0f" % inv.max_weight}))
	var cells: Array[Dictionary] = []
	var hand := inv.hand
	if hand:
		cells.append({"id": hand.id, "count": 1, "dur": hand.durability, "hand": true})
	var sorted: Array[StringName] = []
	for sec: Array in SECTIONS:
		for id in order:
			if ItemDB.get_item(id).category in sec[1]:
				sorted.append(id)
	for id in sorted:
		cells.append({"id": id, "count": totals[id][0], "dur": totals[id][1], "hand": false})
	if _selected_id != &"" and not totals.has(_selected_id):
		_selected_id = &""
	if _selected_hand and hand == null:
		_selected_hand = false
	if _selected_id == &"" and not _selected_hand:
		if hand:
			_selected_hand = true
		elif not sorted.is_empty():
			_selected_id = sorted[0]
	var shown := maxi(cells.size(), 24)
	while shown % 6 != 0:
		shown += 1
	while cells.size() < shown:
		cells.append({})
	for cell in cells:
		if cell.is_empty():
			_pouch.add_child(_empty_cell(_cell_px, false))
		else:
			_pouch.add_child(_item_cell(cell["id"], int(cell["count"]), int(cell["dur"]), bool(cell["hand"])))


func _item_cell(id: StringName, count: int, dur: int, hand: bool) -> Button:
	var on := (hand and _selected_hand) or (not hand and not _selected_hand and id == _selected_id)
	var d := ItemDB.get_item(id)
	var tag := ""
	if hand:
		tag = Loc.t("SLOT_HAND")
	elif count > 1:
		tag = "x%d" % count
	var b := _cell_button(_item_tex(id), _cell_px, on, tag)
	if d.has_durability() and d.max_durability > 0:
		b.tooltip_text = "%s  %d%%" % [d.display_name(), roundi(100.0 * dur / d.max_durability)]
		var wear := _Wear.new()
		wear.frac = float(dur) / float(d.max_durability)
		wear.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		wear.offset_left = 10
		wear.offset_right = -10
		wear.offset_top = -7
		wear.offset_bottom = -4
		b.add_child(wear)
	else:
		b.tooltip_text = d.display_name()
	b.pressed.connect(func() -> void:
		_selected_hand = hand
		_selected_id = &"" if hand else id
		Sfx.ui_click()
		_dirty = true)
	b.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and (ev.button_index == MOUSE_BUTTON_RIGHT or ev.double_click):
			_selected_hand = hand
			_selected_id = &"" if hand else id
			_primary_use())
	return b


## A square item cell: worn inset, icon, count tag, gold rim when selected.
func _cell_button(icon: Texture2D, px: float, on: bool, tag: String, dim := false) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(px, px)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_stylebox_override("normal", UITheme.cell_box())
	b.add_theme_stylebox_override("hover", UITheme.cell_box(Color(1.45, 1.3, 1.1)))
	b.add_theme_stylebox_override("pressed", UITheme.cell_box(Color(1.6, 1.4, 1.1)))
	b.add_theme_stylebox_override("hover_pressed", UITheme.cell_box(Color(1.6, 1.4, 1.1)))
	b.add_theme_stylebox_override("focus", UITheme.rim_box(Color(UITheme.GOLD_HI, 0.6)))
	var art := TextureRect.new()
	art.texture = icon
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var inset := px * 0.05
	art.offset_left = inset
	art.offset_top = inset
	art.offset_right = -inset
	art.offset_bottom = -inset
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if dim:
		art.modulate = Color(0.75, 0.7, 0.65, 0.55)
	b.add_child(art)
	if on:
		var rim := Panel.new()
		rim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		rim.offset_left = -3
		rim.offset_top = -3
		rim.offset_right = 3
		rim.offset_bottom = 3
		rim.add_theme_stylebox_override("panel", UITheme.rim_box(UITheme.GOLD_HI))
		rim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(rim)
		var glow := _Glow.new()
		glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		b.add_child(glow)
		b.move_child(glow, 0)
	if tag != "":
		var l := UITheme.caption(tag, 15, UITheme.BONE_HI, 500)
		l.add_theme_constant_override("outline_size", 5)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		l.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		l.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		l.grow_vertical = Control.GROW_DIRECTION_BEGIN
		l.offset_right = -8
		l.offset_bottom = -6
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(l)
	return b


func _empty_cell(px: float, locked: bool) -> Control:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(px, px)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", UITheme.cell_box(Color(1, 1, 1, 0.55)))
	if locked:
		var ic := TextureRect.new()
		ic.texture = UITheme.icon("lock", Color(UITheme.BONE, 0.22), 26)
		ic.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(ic)
	return p


func _clear_bars() -> void:
	for c in _detail_bars.get_children():
		c.queue_free()


func _fill_bars(st: ItemStack) -> void:
	_clear_bars()
	var d := st.get_data()
	if d.damage > 0.0:
		_meter("damage", Loc.t("TIP_DAMAGE"), "", d.damage / 40.0)
	if d.has_durability():
		_meter("durability", Loc.t("TIP_DURABILITY_SHORT"), "%d / %d" % [st.durability, d.max_durability],
			float(st.durability) / float(d.max_durability))
	if d.food > 0.0:
		_meter("hunger", Loc.t("STAT_HUNGER"), "+%d" % roundi(d.food), d.food / 50.0)
	if d.water > 0.0:
		_meter("thirst", Loc.t("STAT_THIRST"), "+%d" % roundi(d.water), d.water / 50.0)
	if d.health > 0.0:
		_meter("health", Loc.t("STAT_HEALTH"), "+%d" % roundi(d.health), d.health / 50.0)


func _meter(icon_name: String, caption: String, value: String, frac: float) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var ic := TextureRect.new()
	ic.texture = UITheme.icon(icon_name, UITheme.GOLD, 20)
	ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	h.add_child(ic)
	var l := UITheme.caption(caption.to_upper(), 15, UITheme.BONE, 500, 1)
	l.custom_minimum_size.x = 118
	h.add_child(l)
	var bar := _Meter.new()
	bar.frac = clampf(frac, 0.0, 1.0)
	bar.custom_minimum_size = Vector2(0, 10)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(bar)
	if value != "":
		var v := UITheme.caption(value, 14, Color(UITheme.BONE, 0.75), 400)
		v.custom_minimum_size.x = 64
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		h.add_child(v)
	_detail_bars.add_child(h)


## The bag slot holding the selected kind (the least worn stack for tools, any for the rest).
func _selected_slot() -> int:
	var inv := player.inventory
	var best := -1
	for i in inv.size:
		var st := inv.get_slot(i)
		if st != null and st.id == _selected_id and (best < 0 or st.durability > inv.get_slot(best).durability):
			best = i
	return best


func _primary_use() -> void:
	if _selected_hand:
		player.inventory.unequip()
		return
	var i := _selected_slot()
	if i < 0:
		return
	var st := player.inventory.get_slot(i)
	player.use_slot(i)
	if st.get_data().category == &"placeable":
		close()


func _refresh_detail() -> void:
	for c in _detail_buttons.get_children():
		c.queue_free()
	var st: ItemStack = null
	if _selected_hand:
		st = player.inventory.hand
	elif _selected_id != &"":
		st = player.inventory.get_slot(_selected_slot())
	if st == null:
		_detail_title.text = ""
		_detail_cat.text = ""
		_detail_text.text = Loc.t("HINT_SELECT_ITEM", {"key": InputSetup.label(&"weapon_wheel")})
		_detail_icon.texture = null
		_weight_label.text = ""
		_clear_bars()
		return
	var d := st.get_data()
	_detail_title.text = d.display_name().to_upper()
	_detail_cat.text = _first_up(Loc.t("CAT_%s" % String(d.category).to_upper()))
	_detail_text.text = d.description()
	_detail_icon.texture = _item_tex(d.id)
	_fill_bars(st)
	_weight_label.text = Loc.t("TIP_WEIGHT", {"v": "%.1f кг" % (d.weight * st.count)}).to_upper()
	if _selected_hand:
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_UNEQUIP"), func() -> void: player.inventory.unequip()))
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_DROP"), func() -> void: player.drop_hand()))
		return
	if d.is_consumable():
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_USE_%s" % String(d.category).to_upper()), _primary_use))
	elif d.is_equippable():
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_EQUIP"), _primary_use))
	elif d.category == &"placeable":
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_PLACE"), _primary_use))
	_detail_buttons.add_child(UITheme.button(Loc.t("BTN_DROP"), func() -> void:
		var i := _selected_slot()
		if i >= 0:
			player.drop_slot(i)))


func _first_up(t: String) -> String:
	return t.left(1).to_upper() + t.substr(1)


func _recipe_check(r: RecipeData) -> Dictionary:
	return Crafting.check(r, player.inventory, player.world.get_stations_near(player.global_position))


func _refresh_recipes() -> void:
	for b in _group_buttons:
		_paint_group(b, b.get_meta("group") == _group)
	for c in _recipe_list.get_children():
		c.queue_free()
	var shown: Array[RecipeData] = []
	for r: RecipeData in ItemDB.all_recipes():
		if _cat_of(r) == _group:
			shown.append(r)
	if _selected_recipe == null or _cat_of(_selected_recipe) != _group:
		_selected_recipe = null
		for r in shown:
			if _recipe_check(r).ok:
				_selected_recipe = r
				break
		if _selected_recipe == null and not shown.is_empty():
			_selected_recipe = shown[0]
	for r in shown:
		_recipe_list.add_child(_recipe_cell(r))
	var pad := maxi(shown.size() + 4, 16)
	while pad % 4 != 0:
		pad += 1
	for i in pad - shown.size():
		_recipe_list.add_child(_empty_cell(RECIPE_CELL, true))
	_refresh_recipe_detail()


func _cat_of(r: RecipeData) -> StringName:
	var d := ItemDB.get_item(r.result)
	if r.result in [&"bow", &"arrow"]:
		return &"ranged"
	if r.result in [&"torch", &"campfire_kit"]:
		return &"fire"
	if r.result in [&"leaf_bed_kit", &"waterskin", &"waterskin_empty"]:
		return &"shelter"
	if r.group == &"food":
		return &"food"
	if r.group == &"materials":
		return &"materials"
	if r.group == &"medical":
		return &"other"
	if d.has_tag(&"weapon") or r.group == &"weapons":
		return &"arms"
	if r.group == &"tools":
		return &"tools"
	return &"other"


func _paint_group(b: Button, on: bool) -> void:
	var idle := StyleBoxEmpty.new()
	idle.content_margin_left = 18
	idle.content_margin_right = 12
	var sel := UITheme.stroke_box(UITheme.GOLD, 18.0, 6.0)
	var hov := UITheme.stroke_box(Color(0, 0, 0, 0.45), 18.0, 6.0)
	for state in ["normal", "pressed", "focus", "disabled", "hover_pressed"]:
		b.add_theme_stylebox_override(state, sel if on else idle)
	b.add_theme_stylebox_override("hover", sel if on else hov)
	var ink := UITheme.INK if on else UITheme.BONE
	b.add_theme_color_override("font_color", ink)
	b.add_theme_color_override("font_hover_color", ink if on else UITheme.GOLD_HI)
	b.add_theme_color_override("font_pressed_color", ink)
	b.add_theme_color_override("font_focus_color", ink)
	b.add_theme_color_override("icon_normal_color", Color.WHITE)
	b.icon = UITheme.icon(str(b.get_meta("group")), ink, 24)


func _recipe_cell(r: RecipeData) -> Button:
	var d := ItemDB.get_item(r.result)
	var ok: bool = _recipe_check(r).ok
	var b := _cell_button(_item_tex(d.id), RECIPE_CELL, _selected_recipe == r,
		"x%d" % r.result_count if r.result_count > 1 else "", not ok)
	b.tooltip_text = d.display_name()
	b.pressed.connect(_pick_recipe.bind(r))
	b.pressed.connect(Sfx.ui_click)
	return b


func _pick_recipe(r: RecipeData) -> void:
	_selected_recipe = r
	_dirty = true


func _need_chip(id: StringName, need: int) -> PanelContainer:
	var have := player.inventory.count_of(id)
	var d := ItemDB.get_item(id)
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", UITheme.cell_box(Color.WHITE, 8.0))
	chip.custom_minimum_size = Vector2(170, 0)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	chip.add_child(h)
	var icon := _big_icon(54)
	icon.texture = _item_tex(id)
	h.add_child(icon)
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 0)
	h.add_child(v)
	var name := UITheme.caption(d.display_name(), 15, UITheme.BONE, 400)
	name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name.custom_minimum_size.x = 88
	v.add_child(name)
	v.add_child(UITheme.caption("%d / %d" % [have, need], 19, UITheme.GOOD if have >= need else UITheme.BAD, 600))
	return chip


var _swatches: Dictionary = {}


func _swatch(c: Color) -> Texture2D:
	if not _swatches.has(c):
		var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		img.fill(c)
		_swatches[c] = ImageTexture.create_from_image(img)
	return _swatches[c]


func _refresh_recipe_detail() -> void:
	for c in _recipe_needs.get_children():
		c.queue_free()
	var r := _selected_recipe
	if r == null:
		_recipe_title.text = ""
		_recipe_cat.text = ""
		_recipe_desc.text = ""
		_recipe_icon.texture = null
		_recipe_text.text = Loc.t("HINT_SELECT_RECIPE")
		_set_craft_enabled(false)
		return
	var d := ItemDB.get_item(r.result)
	_recipe_title.text = d.display_name().to_upper()
	_recipe_cat.text = _first_up(Loc.t("CAT_%s" % String(d.category).to_upper()))
	_recipe_desc.text = d.description()
	_recipe_icon.texture = _item_tex(d.id)
	var check := _recipe_check(r)
	for id: StringName in r.ingredients.keys():
		_recipe_needs.add_child(_need_chip(id, int(r.ingredients[id])))
	var lines := PackedStringArray()
	if r.required_tag != &"":
		lines.append("[color=%s]%s[/color]" % [UITheme.GOOD.to_html(false) if check.tool_ok else UITheme.BAD.to_html(false),
			Loc.t("REQ_TOOL", {"tool": Loc.t("TAG_%s" % String(r.required_tag).to_upper())})])
	if r.station != &"":
		lines.append("[color=%s]%s[/color]" % [UITheme.GOOD.to_html(false) if check.station_ok else UITheme.BAD.to_html(false),
			Loc.t("REQ_STATION_%s" % String(r.station).to_upper())])
	lines.append("[color=#a8957a]%s[/color]" % Loc.t("CRAFT_TIME", {"s": r.craft_time}))
	_recipe_text.text = "\n".join(lines)
	_set_craft_enabled(check.ok and not _craft_progress.visible)


func _set_craft_enabled(on: bool) -> void:
	_craft_button.disabled = not on


func _on_craft_pressed() -> void:
	var r := _selected_recipe
	if r == null or not _recipe_check(r).ok or _craft_progress.visible:
		return
	_craft_progress.visible = true
	_craft_progress.value = 0
	_set_craft_enabled(false)
	_crafting_tween = create_tween()
	_crafting_tween.tween_property(_craft_progress, "value", 100.0, r.craft_time)
	_crafting_tween.tween_callback(func() -> void:
		_craft_progress.visible = false
		var res := Crafting.craft(r, player.inventory, player.world.get_stations_near(player.global_position))
		if res.ok:
			Sfx.play(&"craft", null, -3.0)
			Events.crafted.emit(r.id)
			Events.item_gained.emit(r.result, r.result_count - int(res.leftover))
			if int(res.leftover) > 0:
				player.world.spawn_pickup(ItemStack.new(r.result, int(res.leftover)), player.global_position + Vector3(0, 0.5, 0))
				Events.toast(Loc.t("MSG_INVENTORY_FULL"), &"warn")
		_dirty = true)


func _cancel_craft() -> void:
	if _crafting_tween and _crafting_tween.is_valid():
		_crafting_tween.kill()
	if _craft_progress:
		_craft_progress.visible = false


func _refresh_journal() -> void:
	var dn := player.world.day_night
	var part := "TIME_NIGHT"
	if dn.time_hours >= 5.0 and dn.time_hours < 10.0:
		part = "TIME_MORNING"
	elif dn.time_hours >= 10.0 and dn.time_hours < 17.0:
		part = "TIME_DAY"
	elif dn.time_hours >= 17.0 and dn.time_hours < 21.0:
		part = "TIME_EVENING"
	var out := PackedStringArray([Loc.t("JOURNAL_HEADER", {"day": dn.day, "part": Loc.t(part)}), ""])
	var entries := player.world.journal.duplicate()
	entries.reverse()
	for key: String in entries:
		out.append("[b]%s[/b]" % Loc.t(key + "_TITLE"))
		out.append(Loc.t(key))
		out.append("")
	_journal_text.text = "\n".join(out)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("inventory") or event.is_action_pressed("pause") or (event.is_action_pressed("journal") and _tab == 1):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("journal"):
		_set_tab(1)
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("weapon_wheel"):
		_cycle_tab(-1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("interact"):
		_cycle_tab(1)
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- drawn pieces

## Darkens the game behind the screen: warm dim, a darker strip under the tabs and the key bar, vignette.
class _Shade extends Control:
	var _top: GradientTexture2D
	var _bot: GradientTexture2D

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_STOP
		_top = _ramp(Vector2(0.5, 0), Vector2(0.5, 0.12))
		_bot = _ramp(Vector2(0.5, 1), Vector2(0.5, 0.9))

	func _ramp(a: Vector2, b: Vector2) -> GradientTexture2D:
		var t := GradientTexture2D.new()
		t.fill_from = a
		t.fill_to = b
		var g := Gradient.new()
		g.set_color(0, Color(0.02, 0.014, 0.01, 0.9))
		g.set_color(1, Color(0.02, 0.014, 0.01, 0.0))
		t.gradient = g
		return t

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.035, 0.025, 0.016, 0.72))
		draw_texture_rect(_top, r, false)
		draw_texture_rect(_bot, r, false)
		draw_texture_rect(UITheme.tex("Grain"), r, true, Color(1, 1, 1, 0.025))


## A tab: icon + title; the active one is gold with a painted stroke under it.
class _Tab extends Button:
	var title := ""
	var icon_name := ""
	var active := false:
		set(v):
			active = v
			if is_inside_tree():
				_paint()

	func _ready() -> void:
		text = title
		focus_mode = FOCUS_NONE
		add_theme_font_override("font", UITheme.display_font(500, 1))
		add_theme_font_size_override("font_size", 19)
		add_theme_constant_override("h_separation", 10)
		var s := StyleBoxEmpty.new()
		s.content_margin_left = 18
		s.content_margin_right = 18
		s.content_margin_top = 8
		s.content_margin_bottom = 14
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			add_theme_stylebox_override(st, s)
		mouse_entered.connect(_paint)
		mouse_exited.connect(_paint)
		_paint()

	func _paint() -> void:
		var ink := UITheme.GOLD_HI if active else (UITheme.BONE_HI if is_hovered() else Color(UITheme.BONE, 0.82))
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			add_theme_color_override(c, ink)
		icon = UITheme.icon(icon_name, ink, 26)
		queue_redraw()

	func _draw() -> void:
		if active:
			draw_texture_rect(UITheme.tex("Stroke"), Rect2(Vector2(4, size.y - 11), Vector2(size.x - 8, 10)), false, UITheme.GOLD)


## Cave paintings on the hide: the mammoth and the hunters (compact = one line, for the craft card).
class _CaveArt extends Control:
	var compact := false

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _draw() -> void:
		var paint := Color("#C98A4B", 0.5 if compact else 0.62)
		var mam := UITheme.tex("Mammoth")
		var hun := UITheme.tex("Hunters")
		if compact:
			var h := size.y
			var ms := mam.get_size() * (h / mam.get_size().y)
			draw_texture_rect(mam, Rect2(Vector2(0, 0), ms), false, paint)
			var hs := hun.get_size() * (h * 0.6 / hun.get_size().y)
			draw_texture_rect(hun, Rect2(Vector2(ms.x + 8, h - hs.y), hs), false, paint)
			return
		var w := size.x
		var ms2 := mam.get_size() * (w * 0.92 / mam.get_size().x)
		draw_texture_rect(mam, Rect2(Vector2(w * 0.04, 24), ms2), false, paint)
		var hs2 := hun.get_size() * (w * 0.9 / hun.get_size().x)
		draw_texture_rect(hun, Rect2(Vector2(w * 0.05, 24 + ms2.y + 18), hs2), false, paint)


## Vitals ring like a hide shield: four arcs (health top, hunger right, thirst bottom, stamina left), icons on them,
## a handprint in the middle.
class _Vitals extends Control:
	var stats: SurvivalStats

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_PASS

	func _process(_delta: float) -> void:
		if is_visible_in_tree():
			queue_redraw()
			if stats:
				tooltip_text = "%s %d · %s %d · %s %d · %s %d" % [Loc.t("STAT_HEALTH"), roundi(stats.health),
					Loc.t("STAT_HUNGER"), roundi(stats.hunger), Loc.t("STAT_THIRST"), roundi(stats.thirst),
					Loc.t("STAT_STAMINA"), roundi(stats.stamina)]

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.4
		draw_circle(c, r + 18.0, Color(0.06, 0.04, 0.028, 0.92))
		draw_arc(c, r + 18.0, 0, TAU, 64, Color("#7A5A36", 0.9), 3.0, true)
		draw_arc(c, r + 13.0, 0, TAU, 64, Color(0, 0, 0, 0.5), 1.5, true)
		var parts := [
			["health", -PI * 0.5, Color("#D2543F"), 1.0],
			["hunger", 0.0, Color("#E0A43C"), 1.0],
			["thirst", PI * 0.5, Color("#4C9BD0"), 1.0],
			["stamina", PI, Color("#7DB85A"), 1.0],
		]
		if stats:
			parts[0][3] = stats.health / 100.0
			parts[1][3] = stats.hunger / 100.0
			parts[2][3] = stats.thirst / 100.0
			parts[3][3] = stats.stamina / maxf(stats.max_stamina(), 1.0)
		var half := TAU / 8.0 - 0.1
		for p: Array in parts:
			var mid: float = p[1]
			draw_arc(c, r, mid - half, mid + half, 24, Color(0, 0, 0, 0.55), 12.0, true)
			var span := clampf(p[3], 0.0, 1.0) * half * 2.0
			draw_arc(c, r, mid - half, mid - half + span, 24, p[2], 10.0, true)
			var at := c + Vector2(cos(mid), sin(mid)) * r
			draw_circle(at, 13.0, Color(0.06, 0.04, 0.028, 1.0))
			draw_arc(at, 13.0, 0, TAU, 24, p[2], 1.5, true)
			var ic := UITheme.icon(p[0], UITheme.BONE_HI, 16)
			draw_texture(ic, at - ic.get_size() * 0.5)
		var inner := r - 16.0
		draw_circle(c, inner, Color(0.1, 0.07, 0.048, 1.0))
		draw_arc(c, inner, 0, TAU, 48, Color(UITheme.GOLD, 0.5), 1.5, true)
		var hand := UITheme.tex("Hand")
		var hs := Vector2(inner, inner) * 1.75
		draw_texture_rect(hand, Rect2(c - hs * 0.5, hs), false, Color("#E8DCC4", 0.45))


## Durability strip at the bottom of a cell.
class _Wear extends Control:
	var frac := 1.0

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.55))
		var col := UITheme.GOOD if frac > 0.5 else (UITheme.GOLD if frac > 0.2 else UITheme.BAD)
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * clampf(frac, 0.0, 1.0), size.y)), col)


## Stat bar on the item card: dark groove, bone-gold fill with a lit top edge.
class _Meter extends Control:
	var frac := 0.0

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0, 0, 0, 0.5))
		var f := Rect2(r.position, Vector2(r.size.x * frac, r.size.y))
		draw_rect(f, Color("#E7C88A"))
		draw_rect(Rect2(f.position, Vector2(f.size.x, f.size.y * 0.4)), Color(1, 0.95, 0.82, 0.5))


## Warm glow inside the selected cell.
class _Glow extends Control:
	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		for i in 6:
			draw_circle(c, size.x * (0.48 - i * 0.06), Color(1.0, 0.7, 0.3, 0.035))
