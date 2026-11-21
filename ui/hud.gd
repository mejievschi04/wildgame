class_name HUD
extends Control
## Restrained HUD (GDD §12): 4 permanent indicators bottom-left (health, stamina, satiety, hydration);
## temperature/rest/conditions/weight appear only when relevant; minimal reticle; prompts only on interaction.

const CONDITION_KEYS := [&"hypothermia", &"overheat", &"bleeding", &"food_poisoning", &"fracture", &"wet"]
const TOAST_TIME := 3.2
const MAX_TOASTS := 5

var player: Player

var _health: ProgressBar
var _stamina: ProgressBar
var _hunger: ProgressBar
var _thirst: ProgressBar
var _context_box: VBoxContainer
var _temp_label: Label
var _rest_label: Label
var _weight_label: Label
var _cond_label: Label
var _reticle: Control
var _prompt_box: VBoxContainer
var _target_label: Label
var _status_label: Label
var _option_labels: Array[Label] = []
var _hold_bar: ProgressBar
var _hotbar_slots: Array[ItemSlot] = []
var _hand_slot: ItemSlot
var _toasts: VBoxContainer
var _vignette: ColorRect
var _fade: ColorRect
var _build_box: VBoxContainer
var _caption: Label
var _build_title: Label
var _build_info: Label
var _build_keys: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	_build_vignette()
	_build_stats()
	_build_reticle()
	_build_prompt()
	_build_hotbar()
	_build_toasts()
	_build_build_hint()
	_caption = UITheme.label("", "SmallLabel")
	_caption.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_caption.offset_top = -250
	_caption.offset_bottom = -222
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.add_theme_color_override("font_color", Color(UITheme.BONE, 0.9))
	_caption.modulate.a = 0.0
	add_child(_caption)
	Sfx.caption.connect(_on_caption)
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fade)
	Events.notify.connect(_on_notify)
	Events.item_gained.connect(_on_item_gained)
	Events.journal_added.connect(func(_k: String) -> void: _on_notify(Loc.t("MSG_JOURNAL_UPDATED"), &"good"))
	Events.game_saved.connect(func(_s: String) -> void: _on_notify(Loc.t("MSG_SAVED"), &"good"))
	Settings.changed.connect(func(_s: String, _k: String) -> void:
		theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast"))))


func bind(p: Player) -> void:
	player = p
	_hand_slot.inventory = p.inventory
	for s in _hotbar_slots:
		s.inventory = p.inventory
	p.slept.connect(func(_h: float) -> void: fade_flash())
	p.hurt.connect(func(_a: float) -> void: _hit_flash())


func _build_vignette() -> void:
	_vignette = ColorRect.new()
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
uniform vec4 tint : source_color = vec4(0.72, 0.36, 0.29, 1.0);
uniform float strength = 0.0;
void fragment() {
	float d = distance(UV, vec2(0.5));
	float v = smoothstep(0.35, 0.78, d) * strength;
	COLOR = vec4(tint.rgb, v);
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	_vignette.material = m
	add_child(_vignette)


func _build_stats() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	box.position = Vector2(32, -40)
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	box.custom_minimum_size.x = 260
	box.add_theme_constant_override("separation", 5)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	_context_box = VBoxContainer.new()
	_context_box.add_theme_constant_override("separation", 2)
	box.add_child(_context_box)
	_temp_label = UITheme.label("", "SmallLabel")
	_rest_label = UITheme.label("", "SmallLabel")
	_weight_label = UITheme.label("", "SmallLabel")
	_cond_label = UITheme.label("", "SmallLabel")
	_cond_label.add_theme_color_override("font_color", UITheme.DANGER.lightened(0.25))
	for l in [_cond_label, _temp_label, _rest_label, _weight_label]:
		_context_box.add_child(l)
	_health = _stat_row(box, "HUD_HEALTH", UITheme.DANGER, 10.0)
	_stamina = _stat_row(box, "HUD_STAMINA", UITheme.BONE, 6.0)
	var needs := HBoxContainer.new()
	needs.add_theme_constant_override("separation", 14)
	box.add_child(needs)
	_hunger = _stat_row(needs, "HUD_HUNGER", UITheme.OCHRE, 5.0)
	_thirst = _stat_row(needs, "HUD_THIRST", UITheme.WATER, 5.0)


func _stat_row(parent: Container, key: String, color: Color, h: float) -> ProgressBar:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.label(Loc.t(key), "MutedLabel")
	l.add_theme_font_size_override("font_size", 13)
	v.add_child(l)
	var b := UITheme.bar(color, h)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(b)
	parent.add_child(v)
	return b


func _build_reticle() -> void:
	_reticle = Control.new()
	_reticle.set_anchors_preset(Control.PRESET_CENTER)
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.draw.connect(_draw_reticle)
	add_child(_reticle)


func _draw_reticle() -> void:
	var has_target := player != null and player.look_target != null
	var c := Color(UITheme.BONE, 0.9 if has_target else 0.55)
	_reticle.draw_circle(Vector2.ZERO, 2.2, c)
	if has_target:
		_reticle.draw_arc(Vector2.ZERO, 9.0, 0, TAU, 28, Color(UITheme.BONE, 0.35), 1.5, true)
	if player != null and player.world and player.world.wildlife:
		var aw: Dictionary = player.world.wildlife.max_awareness()
		if float(aw.value) > 0.15:
			var col := UITheme.DANGER if aw.hostile else UITheme.OCHRE
			_reticle.draw_arc(Vector2.ZERO, 18.0, PI * 1.15, PI * 1.85, 24, Color(col, clampf(float(aw.value), 0.2, 0.85)), 2.0, true)
	if player != null and player.aiming:
		_reticle.draw_line(Vector2(-6, 0), Vector2(6, 0), Color(UITheme.BONE, 0.8), 1.0)
		_reticle.draw_line(Vector2(0, -6), Vector2(0, 6), Color(UITheme.BONE, 0.8), 1.0)
	if player != null and player.hold_ratio > 0.0:
		_reticle.draw_arc(Vector2.ZERO, 12.0, -PI / 2, -PI / 2 + TAU * player.hold_ratio, 32, UITheme.OCHRE, 3.0, true)


func _build_prompt() -> void:
	_prompt_box = VBoxContainer.new()
	_prompt_box.set_anchors_preset(Control.PRESET_CENTER)
	_prompt_box.position = Vector2(-220, 34)
	_prompt_box.custom_minimum_size = Vector2(440, 0)
	_prompt_box.alignment = BoxContainer.ALIGNMENT_BEGIN
	_prompt_box.add_theme_constant_override("separation", 2)
	_prompt_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_prompt_box)
	_target_label = UITheme.label("")
	_status_label = UITheme.label("", "MutedLabel")
	for l in [_target_label, _status_label]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_prompt_box.add_child(l)
	for i in 2:
		var l := UITheme.label("", "SmallLabel")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_prompt_box.add_child(l)
		_option_labels.append(l)
	_hold_bar = UITheme.bar(UITheme.OCHRE, 3.0)
	_hold_bar.custom_minimum_size.x = 160
	_hold_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_prompt_box.add_child(_hold_bar)


func _build_hotbar() -> void:
	var holder := CenterContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	holder.offset_top = -96
	holder.offset_bottom = -22
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(holder)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(bar)
	_hand_slot = ItemSlot.new()
	_hand_slot.index = ItemSlot.HAND
	_hand_slot.compact = true
	_hand_slot.highlight = true
	bar.add_child(_hand_slot)
	var sep := VSeparator.new()
	sep.modulate.a = 0.3
	bar.add_child(sep)
	for i in Inventory.HOTBAR_SIZE:
		var s := ItemSlot.new()
		s.index = i
		s.compact = true
		s.hotkey = str(i + 1)
		bar.add_child(s)
		_hotbar_slots.append(s)


func _build_build_hint() -> void:
	_build_box = VBoxContainer.new()
	_build_box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_build_box.offset_top = -200
	_build_box.offset_bottom = -104
	_build_box.alignment = BoxContainer.ALIGNMENT_END
	_build_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_box.add_theme_constant_override("separation", 2)
	add_child(_build_box)
	_build_title = UITheme.label("", "HeadingLabel")
	_build_title.add_theme_font_size_override("font_size", 22)
	_build_info = UITheme.label("", "SmallLabel")
	_build_keys = UITheme.label("", "MutedLabel")
	for l in [_build_title, _build_info, _build_keys]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_build_box.add_child(l)
	_build_box.visible = false


func _update_build_hint() -> void:
	var b := player.build
	_build_box.visible = b.active
	if not b.active:
		return
	_build_title.text = Loc.t("BUILD_%s" % String(b.piece_id).to_upper())
	if b.valid:
		var parts := PackedStringArray()
		var cost := ItemDB.piece_cost(b.piece_id)
		for id: StringName in cost.keys():
			parts.append("%s %d/%d" % [ItemDB.get_item(id).display_name(), mini(player.inventory.count_of(id), int(cost[id])), int(cost[id])])
		_build_info.text = Loc.t("BUILD_COST") + " " + ", ".join(parts)
		_build_info.add_theme_color_override("font_color", UITheme.BONE)
	else:
		_build_info.text = b.reason
		_build_info.add_theme_color_override("font_color", UITheme.DANGER.lightened(0.3))
	_build_keys.text = Loc.t("HINT_BUILD_MODE", {
		"place": InputSetup.label(&"primary_action"), "rotate": InputSetup.label(&"alt_interact"),
		"snap": InputSetup.label(&"toggle_snap"), "snapstate": Loc.t("BUILD_SNAP_ON" if b.snap else "BUILD_SNAP_OFF"),
		"cancel": InputSetup.label(&"secondary_action")})


func _build_toasts() -> void:
	_toasts = VBoxContainer.new()
	_toasts.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_toasts.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_toasts.position = Vector2(-28, 28)
	_toasts.alignment = BoxContainer.ALIGNMENT_BEGIN
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toasts)


func _on_item_gained(id: StringName, count: int) -> void:
	var d := ItemDB.get_item(id)
	if d:
		_on_notify("+%d  %s" % [count, d.display_name()], &"good")


func _on_notify(text: String, kind: StringName) -> void:
	var panel := PanelContainer.new()
	var border := UITheme.OCHRE
	match kind:
		&"danger": border = UITheme.DANGER
		&"warn": border = UITheme.OCHRE.lightened(0.2)
		&"good": border = UITheme.PINE.lightened(0.35)
		_: border = Color(UITheme.BONE, 0.4)
	var st := UITheme.flat(Color(UITheme.CHARCOAL, 0.82), Color.TRANSPARENT, 0, 3, 12.0)
	st.border_width_left = 3
	st.border_color = border
	panel.add_theme_stylebox_override("panel", st)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UITheme.label(text, "SmallLabel")
	panel.add_child(l)
	_toasts.add_child(panel)
	while _toasts.get_child_count() > MAX_TOASTS:
		_toasts.get_child(0).free()
	panel.modulate.a = 0.0
	var tw := panel.create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, UITheme.ANIM)
	tw.tween_interval(TOAST_TIME)
	tw.tween_property(panel, "modulate:a", 0.0, 0.4)
	tw.tween_callback(panel.queue_free)


func _on_caption(text: String) -> void:
	_caption.text = text
	var tw := _caption.create_tween()
	_caption.modulate.a = 1.0
	tw.tween_interval(2.2)
	tw.tween_property(_caption, "modulate:a", 0.0, 0.4)


func _hit_flash() -> void:
	var m := _vignette.material as ShaderMaterial
	m.set_shader_parameter("tint", UITheme.DANGER)
	m.set_shader_parameter("strength", 0.9)
	_hit_t = 0.35


var _hit_t := 0.0


func fade_flash() -> void:
	_fade.color.a = 1.0
	var tw := create_tween()
	tw.tween_interval(0.35)
	tw.tween_property(_fade, "color:a", 0.0, 1.2)


func _process(_delta: float) -> void:
	if player == null:
		return
	var s := player.stats
	_health.value = s.health
	_stamina.value = s.stamina
	_stamina.max_value = SurvivalStats.MAX
	_hunger.value = s.hunger
	_thirst.value = s.thirst
	_update_context(s)
	_update_prompt()
	_update_build_hint()
	_reticle.queue_redraw()
	if _hit_t > 0.0:
		_hit_t -= _delta
		return
	var low_health := clampf((40.0 - s.health) / 40.0, 0.0, 1.0)
	var cold := clampf((36.2 - s.body_temp) / 1.5, 0.0, 1.0)
	var m := _vignette.material as ShaderMaterial
	if cold > low_health:
		m.set_shader_parameter("tint", Color(0.55, 0.7, 0.85))
		m.set_shader_parameter("strength", cold * 0.55)
	else:
		m.set_shader_parameter("tint", UITheme.DANGER)
		m.set_shader_parameter("strength", low_health * 0.7)
	visible = not player.dead


func _update_context(s: SurvivalStats) -> void:
	var feels_cold := s.last_effective_temp < 8.0
	var show_temp := s.body_temp < 36.5 or s.body_temp > 37.6 or feels_cold
	_temp_label.visible = show_temp
	if show_temp:
		var key := "HUD_COLD" if (s.body_temp < 37.0 or feels_cold) else "HUD_HOT"
		_temp_label.text = Loc.t(key, {"t": "%.1f" % s.body_temp})
		_temp_label.add_theme_color_override("font_color",
			Color(0.65, 0.8, 0.95) if key == "HUD_COLD" else UITheme.OCHRE)
	_rest_label.visible = s.rest < 30.0
	_rest_label.text = Loc.t("HUD_TIRED")
	_weight_label.visible = player.inventory.is_overweight()
	_weight_label.text = Loc.t("HUD_OVERWEIGHT")
	var conds := PackedStringArray()
	for c: StringName in CONDITION_KEYS:
		if s.has_condition(c):
			conds.append(Loc.t("COND_%s" % String(c).to_upper()))
	_cond_label.visible = not conds.is_empty()
	_cond_label.text = " · ".join(conds)


func _update_prompt() -> void:
	var t := player.look_target
	var options := player.look_options
	_prompt_box.visible = t != null and not options.is_empty()
	if t == null and not player.look_track.is_empty():
		var tr: Dictionary = player.look_track
		_prompt_box.visible = true
		_target_label.text = Loc.t("TRACKS_OF", {"name": Loc.t("ANIMAL_%s" % String(tr.species).to_upper())})
		var mins := int(float(tr.age) / 60.0)
		_status_label.text = Loc.t("TRACK_FRESH") if mins < 2 else Loc.t("TRACK_AGE", {"m": mins})
		_status_label.visible = true
		for l in _option_labels:
			l.visible = false
		_hold_bar.visible = false
		return
	if not _prompt_box.visible:
		if t != null and options.is_empty():
			_prompt_box.visible = true
			_target_label.text = t.get_display_name()
			_status_label.visible = false
			for l in _option_labels:
				l.visible = false
			_hold_bar.visible = false
		return
	_target_label.text = t.get_display_name()
	var status: String = t.get_status_text() if t.has_method("get_status_text") else ""
	_status_label.text = status
	_status_label.visible = status != ""
	for i in _option_labels.size():
		var l := _option_labels[i]
		if i >= options.size():
			l.visible = false
			continue
		var o: Dictionary = options[i]
		l.visible = true
		var prefix := "[%s]  " % InputSetup.label(o.action)
		if o.get("swing", false) and not o.enabled:
			prefix = ""
		l.text = prefix + str(o.text) + (Loc.t("HOLD_SUFFIX") if float(o.hold) > 0.0 and o.enabled else "")
		l.modulate.a = 1.0 if o.enabled else 0.5
	_hold_bar.visible = player.hold_ratio > 0.0
	_hold_bar.value = player.hold_ratio * 100.0
