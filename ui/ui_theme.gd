class_name UITheme
extends RefCounted
## WILDBOUND UI design system: palette from GDD §12, readable type, restrained stone/hide feel.

const CHARCOAL := Color("#171B18")
const BONE := Color("#E8DDC5")
const PINE := Color("#34483B")
const OCHRE := Color("#C49A5A")
const DANGER := Color("#B75C4A")
const WATER := Color("#7FA3AE")
const MUTED := Color("#E8DDC5", 0.6)
const ANIM := 0.18  # seconds; GDD: 150–250 ms

static var _theme: Theme
static var _theme_hc: Theme


static func get_theme(high_contrast: bool = false) -> Theme:
	if high_contrast:
		if _theme_hc == null:
			_theme_hc = _build(true)
		return _theme_hc
	if _theme == null:
		_theme = _build(false)
	return _theme


static func body_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Avenir Next", "Segoe UI", "Helvetica Neue", "Noto Sans", "DejaVu Sans", "sans-serif"])
	f.font_weight = 500
	return f


static func heading_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Palatino", "Georgia", "Noto Serif", "DejaVu Serif", "serif"])
	f.font_weight = 600
	return f


static func flat(bg: Color, border: Color = Color.TRANSPARENT, border_w: int = 0, radius: int = 3,
		margin: float = 10.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.set_corner_radius_all(radius)
	s.content_margin_left = margin
	s.content_margin_right = margin
	s.content_margin_top = margin * 0.6
	s.content_margin_bottom = margin * 0.6
	s.anti_aliasing = true
	return s


static func panel_style(alpha: float = 0.9) -> StyleBoxFlat:
	var s := flat(Color(CHARCOAL, alpha), Color(OCHRE, 0.28), 1, 4, 18.0)
	s.shadow_color = Color(0, 0, 0, 0.35)
	s.shadow_size = 10
	return s


static func _build(hc: bool) -> Theme:
	var t := Theme.new()
	var text := Color.WHITE if hc else BONE
	var bg_a := 0.98 if hc else 0.9
	t.default_font = body_font()
	t.default_font_size = 19

	t.set_color("font_color", "Label", text)
	t.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.6))
	t.set_constant("shadow_offset_x", "Label", 0)
	t.set_constant("shadow_offset_y", "Label", 1)
	t.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.55))
	t.set_constant("outline_size", "Label", 4)

	t.set_type_variation("HeadingLabel", "Label")
	t.set_font("font", "HeadingLabel", heading_font())
	t.set_font_size("font_size", "HeadingLabel", 30)
	t.set_color("font_color", "HeadingLabel", OCHRE if not hc else Color("#FFD48A"))
	t.set_type_variation("TitleLabel", "Label")
	t.set_font("font", "TitleLabel", heading_font())
	t.set_font_size("font_size", "TitleLabel", 64)
	t.set_color("font_color", "TitleLabel", text)
	t.set_type_variation("MutedLabel", "Label")
	t.set_color("font_color", "MutedLabel", Color(text, 0.85) if hc else Color(BONE, 0.78))
	t.set_font_size("font_size", "MutedLabel", 16)
	t.set_type_variation("SmallLabel", "Label")
	t.set_font_size("font_size", "SmallLabel", 15)

	var btn_bg := Color(PINE, 0.0)
	var border := Color(OCHRE, 0.0)
	t.set_stylebox("normal", "Button", flat(Color(CHARCOAL, 0.55 if not hc else 0.95), Color(BONE, 0.12 if not hc else 0.6), 1, 3, 14.0))
	t.set_stylebox("hover", "Button", flat(Color(PINE, 0.85), OCHRE, 1, 3, 14.0))
	t.set_stylebox("pressed", "Button", flat(Color(OCHRE, 0.85), OCHRE, 1, 3, 14.0))
	t.set_stylebox("focus", "Button", flat(btn_bg, Color(OCHRE, 0.9), 2, 3, 14.0))
	t.set_stylebox("disabled", "Button", flat(Color(CHARCOAL, 0.35), Color(BONE, 0.06), 1, 3, 14.0))
	t.set_color("font_color", "Button", text)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", CHARCOAL)
	t.set_color("font_focus_color", "Button", text)
	t.set_color("font_disabled_color", "Button", Color(text, 0.35))
	t.set_type_variation("MenuButtonBig", "Button")
	t.set_font_size("font_size", "MenuButtonBig", 24)
	t.set_stylebox("normal", "MenuButtonBig", flat(Color.TRANSPARENT, border, 0, 2, 16.0))
	t.set_stylebox("hover", "MenuButtonBig", flat(Color(PINE, 0.7), Color.TRANSPARENT, 0, 2, 16.0))
	t.set_stylebox("focus", "MenuButtonBig", flat(Color(PINE, 0.45), Color(OCHRE, 0.8), 1, 2, 16.0))
	t.set_stylebox("pressed", "MenuButtonBig", flat(Color(OCHRE, 0.9), Color.TRANSPARENT, 0, 2, 16.0))
	t.set_stylebox("disabled", "MenuButtonBig", flat(Color.TRANSPARENT, Color.TRANSPARENT, 0, 2, 16.0))

	for type in ["PanelContainer", "Panel"]:
		t.set_stylebox("panel", type, panel_style(bg_a))
	t.set_stylebox("panel", "TooltipPanel", flat(Color(CHARCOAL, 0.97), Color(OCHRE, 0.5), 1, 3, 12.0))
	t.set_color("font_color", "TooltipLabel", text)
	t.set_font_size("font_size", "TooltipLabel", 16)

	t.set_stylebox("background", "ProgressBar", flat(Color(0, 0, 0, 0.45), Color(BONE, 0.1), 1, 2, 0.0))
	t.set_stylebox("fill", "ProgressBar", flat(OCHRE, Color.TRANSPARENT, 0, 2, 0.0))
	t.set_color("font_color", "ProgressBar", text)

	t.set_stylebox("slider", "HSlider", flat(Color(0, 0, 0, 0.5), Color(BONE, 0.15), 1, 2, 3.0))
	t.set_stylebox("grabber_area", "HSlider", flat(Color(OCHRE, 0.8), Color.TRANSPARENT, 0, 2, 3.0))
	t.set_stylebox("grabber_area_highlight", "HSlider", flat(OCHRE, Color.TRANSPARENT, 0, 2, 3.0))

	t.set_color("font_color", "CheckBox", text)
	t.set_color("font_hover_color", "CheckBox", Color.WHITE)
	t.set_color("font_pressed_color", "CheckBox", text)
	t.set_color("font_focus_color", "CheckBox", text)
	for st in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		t.set_stylebox(st, "CheckBox", flat(Color(PINE, 0.35) if st.begins_with("hover") else Color.TRANSPARENT,
			Color(OCHRE, 0.8) if st == "focus" else Color.TRANSPARENT, 1 if st == "focus" else 0, 3, 8.0))

	t.set_stylebox("panel", "TabContainer", panel_style(0.0))
	t.set_stylebox("tab_selected", "TabContainer", flat(Color(PINE, 0.9), OCHRE, 1, 3, 14.0))
	t.set_stylebox("tab_unselected", "TabContainer", flat(Color(CHARCOAL, 0.6), Color(BONE, 0.1), 1, 3, 14.0))
	t.set_stylebox("tab_hovered", "TabContainer", flat(Color(PINE, 0.6), Color(OCHRE, 0.6), 1, 3, 14.0))
	t.set_stylebox("tab_focus", "TabContainer", flat(Color.TRANSPARENT, OCHRE, 2, 3, 14.0))
	t.set_color("font_selected_color", "TabContainer", Color.WHITE)
	t.set_color("font_unselected_color", "TabContainer", Color(text, 0.7))
	t.set_color("font_hovered_color", "TabContainer", text)

	t.set_stylebox("normal", "OptionButton", flat(Color(CHARCOAL, 0.7), Color(BONE, 0.15), 1, 3, 12.0))
	t.set_stylebox("hover", "OptionButton", flat(Color(PINE, 0.8), OCHRE, 1, 3, 12.0))
	t.set_stylebox("focus", "OptionButton", flat(Color.TRANSPARENT, OCHRE, 2, 3, 12.0))
	t.set_stylebox("pressed", "OptionButton", flat(Color(PINE, 0.9), OCHRE, 1, 3, 12.0))
	t.set_stylebox("panel", "PopupMenu", flat(Color(CHARCOAL, 0.98), Color(OCHRE, 0.4), 1, 3, 8.0))
	t.set_stylebox("hover", "PopupMenu", flat(Color(PINE, 0.9), Color.TRANSPARENT, 0, 2, 8.0))
	t.set_color("font_color", "PopupMenu", text)
	t.set_color("font_hover_color", "PopupMenu", Color.WHITE)

	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_constant("separation", "VBoxContainer", 8)
	t.set_constant("separation", "HBoxContainer", 10)
	t.set_stylebox("separator", "HSeparator", flat(Color(OCHRE, 0.25), Color.TRANSPARENT, 0, 0, 0.0))
	return t


## Fade + slight slide-in for overlays. Returns the tween.
static func show_animated(c: Control, visible: bool) -> Tween:
	var tw := c.create_tween()
	if visible:
		c.visible = true
		c.modulate.a = 0.0
		tw.tween_property(c, "modulate:a", 1.0, ANIM).set_trans(Tween.TRANS_SINE)
	else:
		tw.tween_property(c, "modulate:a", 0.0, ANIM * 0.8).set_trans(Tween.TRANS_SINE)
		tw.tween_callback(func() -> void: c.visible = false)
	return tw


static func label(text: String, variation: String = "") -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	return l


static func button(text: String, cb: Callable, variation: String = "") -> Button:
	var b := Button.new()
	b.text = text
	if variation != "":
		b.theme_type_variation = variation
	b.pressed.connect(cb)
	b.focus_mode = Control.FOCUS_ALL
	return b


static func bar(color: Color, min_h: float = 8.0) -> ProgressBar:
	var p := ProgressBar.new()
	p.show_percentage = false
	p.max_value = 100.0
	p.custom_minimum_size.y = min_h
	p.add_theme_stylebox_override("fill", flat(color, Color.TRANSPARENT, 0, 2, 0.0))
	return p
