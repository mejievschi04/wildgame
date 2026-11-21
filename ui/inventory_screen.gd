class_name InventoryScreen
extends Control
## Inventory (equipment column + item grid + contextual crafting) and Journal tabs.

signal closed

const GRID_COLUMNS := 6

var player: Player
var _tab := 0
var _pages: Array[Control] = []
var _tab_buttons: Array[Button] = []
var _slots: Array[ItemSlot] = []
var _hand_slot: ItemSlot
var _selected := -2  # -2 none, -1 hand, >=0 bag
var _detail_title: Label
var _detail_text: Label
var _detail_buttons: HBoxContainer
var _weight_bar: ProgressBar
var _weight_label: Label
var _summary: Label
var _recipe_list: VBoxContainer
var _recipe_title: Label
var _recipe_text: RichTextLabel
var _craft_button: Button
var _craft_progress: ProgressBar
var _selected_recipe: RecipeData
var _crafting_tween: Tween
var _journal_text: RichTextLabel
var _dirty := true


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.05, 0.04, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 48)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	margin.add_child(root)
	var tabs := HBoxContainer.new()
	root.add_child(tabs)
	for i in 2:
		var b := UITheme.button(Loc.t(["TAB_INVENTORY", "TAB_JOURNAL"][i]), _set_tab.bind(i))
		b.toggle_mode = true
		tabs.add_child(b)
		_tab_buttons.append(b)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(spacer)
	tabs.add_child(UITheme.label(Loc.t("HINT_CLOSE_INVENTORY", {"key": InputSetup.label(&"inventory")}), "MutedLabel"))
	var pages := Control.new()
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(pages)
	_pages.append(_build_inventory_page())
	_pages.append(_build_journal_page())
	for p in _pages:
		p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		pages.add_child(p)
	_set_tab(0)
	Events.journal_added.connect(func(_k: String) -> void: _dirty = true)


func bind(p: Player) -> void:
	player = p
	_hand_slot.inventory = p.inventory
	for s in _slots:
		s.inventory = p.inventory
	p.inventory.changed.connect(func() -> void: _dirty = true)


func open(tab: int = 0) -> void:
	_set_tab(tab)
	_dirty = true
	UITheme.show_animated(self, true)
	await get_tree().process_frame
	if _tab == 0 and _slots.size() > 0:
		_slots[0].grab_focus()


func close() -> void:
	_cancel_craft()
	UITheme.show_animated(self, false)
	closed.emit()


func _set_tab(i: int) -> void:
	_tab = i
	for j in _pages.size():
		_pages[j].visible = j == i
		_tab_buttons[j].button_pressed = j == i
	_dirty = true


# ---------------------------------------------------------------- layout

func _column(title_key: String, min_w: float, expand: bool = false) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = min_w
	if expand:
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	v.add_child(UITheme.label(Loc.t(title_key), "HeadingLabel"))
	v.add_child(HSeparator.new())
	v.set_meta("panel", panel)
	return v


func _build_inventory_page() -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)

	# Equipment column.
	var eq := _column("COL_EQUIPMENT", 270)
	h.add_child(eq.get_meta("panel"))
	eq.add_child(UITheme.label(Loc.t("SLOT_HAND"), "MutedLabel"))
	_hand_slot = ItemSlot.new()
	_hand_slot.index = ItemSlot.HAND
	_hand_slot.highlight = true
	_hand_slot.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_hand_slot.clicked.connect(_on_slot_clicked)
	eq.add_child(_hand_slot)
	for key in ["SLOT_BODY", "SLOT_BACK"]:
		var l := UITheme.label(Loc.t(key) + " — " + Loc.t("LOCKED_LATER"), "MutedLabel")
		l.modulate.a = 0.6
		eq.add_child(l)
	eq.add_child(HSeparator.new())
	_summary = UITheme.label("", "SmallLabel")
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	eq.add_child(_summary)

	# Items column.
	var items := _column("COL_ITEMS", 470)
	h.add_child(items.get_meta("panel"))
	var grid := GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	items.add_child(grid)
	for i in 24:
		var s := ItemSlot.new()
		s.index = i
		s.hotkey = str(i + 1) if i < Inventory.HOTBAR_SIZE else ""
		s.focus_mode = Control.FOCUS_ALL
		s.clicked.connect(_on_slot_clicked)
		s.focus_entered.connect(func() -> void: _select(i))
		grid.add_child(s)
		_slots.append(s)
	var wrow := HBoxContainer.new()
	items.add_child(wrow)
	_weight_label = UITheme.label("", "SmallLabel")
	wrow.add_child(_weight_label)
	_weight_bar = UITheme.bar(UITheme.OCHRE, 6.0)
	_weight_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_weight_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wrow.add_child(_weight_bar)
	items.add_child(HSeparator.new())
	_detail_title = UITheme.label("", "HeadingLabel")
	_detail_title.add_theme_font_size_override("font_size", 22)
	items.add_child(_detail_title)
	_detail_text = UITheme.label("", "SmallLabel")
	_detail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_text.custom_minimum_size.x = 420
	items.add_child(_detail_text)
	_detail_buttons = HBoxContainer.new()
	items.add_child(_detail_buttons)

	# Crafting column.
	var craft := _column("COL_CRAFTING", 380, true)
	h.add_child(craft.get_meta("panel"))
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 250
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	craft.add_child(scroll)
	_recipe_list = VBoxContainer.new()
	_recipe_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipe_list.add_theme_constant_override("separation", 4)
	scroll.add_child(_recipe_list)
	craft.add_child(HSeparator.new())
	_recipe_title = UITheme.label("", "HeadingLabel")
	_recipe_title.add_theme_font_size_override("font_size", 22)
	craft.add_child(_recipe_title)
	_recipe_text = RichTextLabel.new()
	_recipe_text.bbcode_enabled = true
	_recipe_text.fit_content = true
	_recipe_text.scroll_active = false
	_recipe_text.custom_minimum_size.y = 120
	_recipe_text.add_theme_color_override("default_color", UITheme.BONE)
	_recipe_text.add_theme_font_size_override("normal_font_size", 17)
	craft.add_child(_recipe_text)
	_craft_progress = UITheme.bar(UITheme.OCHRE, 6.0)
	_craft_progress.visible = false
	craft.add_child(_craft_progress)
	_craft_button = UITheme.button(Loc.t("BTN_CRAFT"), _on_craft_pressed)
	craft.add_child(_craft_button)
	return h


func _build_journal_page() -> Control:
	var v := _column("TAB_JOURNAL", 600, true)
	var panel: PanelContainer = v.get_meta("panel")
	_journal_text = RichTextLabel.new()
	_journal_text.bbcode_enabled = true
	_journal_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_journal_text.add_theme_color_override("default_color", UITheme.BONE)
	_journal_text.add_theme_font_size_override("normal_font_size", 19)
	_journal_text.add_theme_font_override("bold_font", UITheme.heading_font())
	_journal_text.add_theme_font_size_override("bold_font_size", 22)
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
		_craft_button.disabled = not _recipe_check(_selected_recipe).ok


func _refresh_all() -> void:
	var inv := player.inventory
	_weight_bar.max_value = inv.max_weight
	_weight_bar.value = minf(inv.total_weight(), inv.max_weight)
	_weight_label.text = Loc.t("WEIGHT_FMT", {"w": "%.1f" % inv.total_weight(), "max": "%.0f" % inv.max_weight})
	var s := player.stats
	_summary.text = Loc.t("SUMMARY_FMT", {
		"t": "%.1f" % s.body_temp, "feel": "%.0f" % s.last_effective_temp,
		"rest": int(s.rest), "h": int(s.health)})
	_refresh_detail()
	_refresh_recipes()
	_refresh_journal()


func _stack_at(i: int) -> ItemStack:
	if i == ItemSlot.HAND:
		return player.inventory.hand
	return player.inventory.get_slot(i) if i >= 0 else null


func _select(i: int) -> void:
	_selected = i
	_hand_slot.selected = i == ItemSlot.HAND
	for j in _slots.size():
		_slots[j].selected = j == i
	_refresh_detail()


func _on_slot_clicked(slot: ItemSlot, button: int, double: bool) -> void:
	_select(slot.index)
	if button == MOUSE_BUTTON_RIGHT or double:
		_primary_use(slot.index)


func _primary_use(i: int) -> void:
	if i == ItemSlot.HAND:
		player.inventory.unequip()
		return
	var st := _stack_at(i)
	if st == null:
		return
	if st.get_data().category == &"placeable":
		player.use_slot(i)
		close()
	else:
		player.use_slot(i)


func _refresh_detail() -> void:
	for c in _detail_buttons.get_children():
		c.queue_free()
	var st := _stack_at(_selected)
	if st == null:
		_detail_title.text = ""
		_detail_text.text = Loc.t("HINT_SELECT_ITEM")
		return
	var d := st.get_data()
	_detail_title.text = d.display_name()
	var desc := ItemSlot.describe(st).split("\n")
	desc.remove_at(0)
	_detail_text.text = "\n".join(desc).strip_edges()
	var i := _selected
	if i == ItemSlot.HAND:
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_UNEQUIP"), func() -> void: player.inventory.unequip()))
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_DROP"), func() -> void: player.drop_hand()))
		return
	if d.is_consumable():
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_USE_%s" % String(d.category).to_upper()), _primary_use.bind(i)))
	elif d.is_equippable():
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_EQUIP"), _primary_use.bind(i)))
	elif d.category == &"placeable":
		_detail_buttons.add_child(UITheme.button(Loc.t("BTN_PLACE"), _primary_use.bind(i)))
	_detail_buttons.add_child(UITheme.button(Loc.t("BTN_DROP"), func() -> void: player.drop_slot(i)))


func _recipe_check(r: RecipeData) -> Dictionary:
	return Crafting.check(r, player.inventory, player.world.get_stations_near(player.global_position))


func _refresh_recipes() -> void:
	for c in _recipe_list.get_children():
		c.queue_free()
	for r: RecipeData in ItemDB.all_recipes():
		var d := ItemDB.get_item(r.result)
		var ok: bool = _recipe_check(r).ok
		var b := Button.new()
		b.text = d.display_name() + ("" if r.result_count == 1 else " ×%d" % r.result_count)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.button_pressed = _selected_recipe == r
		b.modulate.a = 1.0 if ok else 0.55
		b.icon = _swatch(d.icon_color)
		b.add_theme_constant_override("h_separation", 10)
		b.pressed.connect(func() -> void:
			_selected_recipe = r
			_dirty = true)
		_recipe_list.add_child(b)
	_refresh_recipe_detail()


var _swatches: Dictionary = {}


func _swatch(c: Color) -> Texture2D:
	if not _swatches.has(c):
		var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
		img.fill(c)
		_swatches[c] = ImageTexture.create_from_image(img)
	return _swatches[c]


func _refresh_recipe_detail() -> void:
	var r := _selected_recipe
	if r == null:
		_recipe_title.text = ""
		_recipe_text.text = Loc.t("HINT_SELECT_RECIPE")
		_craft_button.disabled = true
		return
	var d := ItemDB.get_item(r.result)
	_recipe_title.text = d.display_name()
	var check := _recipe_check(r)
	var lines := PackedStringArray([d.description(), ""])
	for id: StringName in r.ingredients.keys():
		var need := int(r.ingredients[id])
		var have := player.inventory.count_of(id)
		var col := "#B7C99A" if have >= need else "#D98B7A"
		lines.append("[color=%s]%s  %d / %d[/color]" % [col, ItemDB.get_item(id).display_name(), mini(have, need), need])
	if r.required_tag != &"":
		lines.append("[color=%s]%s[/color]" % ["#B7C99A" if check.tool_ok else "#D98B7A",
			Loc.t("REQ_TOOL", {"tool": Loc.t("TAG_%s" % String(r.required_tag).to_upper())})])
	if r.station != &"":
		lines.append("[color=%s]%s[/color]" % ["#B7C99A" if check.station_ok else "#D98B7A",
			Loc.t("REQ_STATION_%s" % String(r.station).to_upper())])
	lines.append("[color=#9a9282]%s[/color]" % Loc.t("CRAFT_TIME", {"s": r.craft_time}))
	_recipe_text.text = "\n".join(lines)
	_craft_button.disabled = not check.ok


func _on_craft_pressed() -> void:
	var r := _selected_recipe
	if r == null or not _recipe_check(r).ok or _craft_progress.visible:
		return
	_craft_progress.visible = true
	_craft_progress.value = 0
	_craft_button.disabled = true
	_crafting_tween = create_tween()
	_crafting_tween.tween_property(_craft_progress, "value", 100.0, r.craft_time)
	_crafting_tween.tween_callback(func() -> void:
		_craft_progress.visible = false
		var res := Crafting.craft(r, player.inventory, player.world.get_stations_near(player.global_position))
		if res.ok:
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
	for i in Inventory.HOTBAR_SIZE:
		if event.is_action_pressed("hotbar_%d" % (i + 1)) and _selected >= 0:
			player.inventory.swap_slots(_selected, i)
			get_viewport().set_input_as_handled()
