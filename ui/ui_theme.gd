class_name UITheme
extends RefCounted
## WILDBOUND UI design system. One look for every screen: smoked hide and stone panels, ochre brush strokes,
## cave paint, Oswald for titles and buttons. Textures come from tools/ui/gen_ui_textures.py.

const CHARCOAL := Color("#171B18")
const BONE := Color("#E8DDC5")
const PINE := Color("#34483B")
const OCHRE := Color("#C49A5A")
const DANGER := Color("#B75C4A")
const WATER := Color("#7FA3AE")
const MUTED := Color("#E8DDC5", 0.6)
const ANIM := 0.18  # seconds; GDD: 150–250 ms
const INK := Color("#120D09")
const GOLD := Color("#E0A43C")
const GOLD_HI := Color("#F3CB74")
const BONE_HI := Color("#F4EAD6")
const PAINT := Color("#C98A4B")
const GOOD := Color("#A9CC7C")
const BAD := Color("#DD836C")
## Stroke caps and panel edges, in texture pixels (the 9-slice margins of the T_UI_* textures).
const STROKE_CAP := 44
const SLAB_EDGE := 40
const HIDE_EDGE := 84
const CELL_EDGE := 16

static var _theme: Theme
static var _theme_hc: Theme
static var _tex: Dictionary = {}
static var _fonts: Dictionary = {}
static var _icons: Dictionary = {}


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
	return display_font(600, 1)


## Oswald (OFL) at a given weight; spacing adds pixels between letters.
static func display_font(weight: int = 600, spacing: int = 0) -> Font:
	var key := "%d/%d" % [weight, spacing]
	if not _fonts.has(key):
		var f := FontVariation.new()
		f.base_font = load("res://assets/fonts/Oswald.ttf")
		f.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
		f.spacing_glyph = spacing
		f.fallbacks = [body_font()]
		_fonts[key] = f
	return _fonts[key]


static func tex(name: String) -> Texture2D:
	if not _tex.has(name):
		_tex[name] = load("res://assets/ui/%s" % name if "." in name else "res://assets/ui/T_UI_%s.png" % name)
	return _tex[name]


static func _tex_box(t: Texture2D, edge: int, pad_h: float, pad_v: float, tint: Color) -> StyleBoxTexture:
	var s := StyleBoxTexture.new()
	s.texture = t
	s.texture_margin_left = edge
	s.texture_margin_right = edge
	s.texture_margin_top = edge
	s.texture_margin_bottom = edge
	s.content_margin_left = pad_h
	s.content_margin_right = pad_h
	s.content_margin_top = pad_v
	s.content_margin_bottom = pad_v
	s.modulate_color = tint
	return s


## A painted brush stroke behind text (selected tab, hovered row, primary button). Tinted by color.
static func stroke_box(color: Color, pad_h: float = 22.0, pad_v: float = 8.0) -> StyleBoxTexture:
	var s := _tex_box(tex("Stroke"), 0, pad_h, pad_v, color)
	s.texture_margin_left = STROKE_CAP
	s.texture_margin_right = STROKE_CAP
	return s


## Dark chipped stone slab (cards, dialogs).
static func slab_box(pad: float = 24.0, tint: Color = Color.WHITE) -> StyleBoxTexture:
	return _tex_box(tex("Slab"), SLAB_EDGE, pad, pad * 0.8, tint)


## Big scraped hide with a fur fringe (the inventory sheet, the loading band).
static func hide_box(pad: float = 48.0) -> StyleBoxTexture:
	return _tex_box(tex("Hide"), HIDE_EDGE, pad, pad * 0.75, Color.WHITE)


## Item cell / small dark inset.
static func cell_box(tint: Color = Color.WHITE, pad: float = 8.0) -> StyleBoxTexture:
	return _tex_box(tex("Cell"), CELL_EDGE, pad, pad, tint)


## Worn rim drawn over a selected cell.
static func rim_box(color: Color = GOLD_HI) -> StyleBoxTexture:
	return _tex_box(tex("Rim"), CELL_EDGE, 0.0, 0.0, color)


## Line icon from the built-in set (vector, crisp at any size).
static func icon(name: String, color: Color = BONE, px: int = 24) -> Texture2D:
	var key := "%s/%s/%d" % [name, color.to_html(true), px]
	if _icons.has(key):
		return _icons[key]
	var body: String = PrimalIcons.SVG.get(name, PrimalIcons.SVG["dots"])
	var hexc := "#" + color.to_html(false)
	var svg := ('<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" '
		+ 'stroke="C" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" opacity="%.3f">' % color.a
		+ body + "</svg>").replace("\"C\"", "\"%s\"" % hexc)
	var img := Image.new()
	img.load_svg_from_string(svg, float(px) / 24.0)
	var t := ImageTexture.create_from_image(img)
	_icons[key] = t
	return t


## Small keyboard key, e.g. [Esc] [Q].
static func keycap(text: String) -> PanelContainer:
	var p := PanelContainer.new()
	var s := flat(Color(BONE, 0.14), Color(BONE, 0.5), 1, 4, 7.0)
	s.content_margin_top = 1
	s.content_margin_bottom = 1
	p.add_theme_stylebox_override("panel", s)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", display_font(500))
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", BONE_HI)
	l.add_theme_constant_override("outline_size", 0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size.x = 14
	p.add_child(l)
	return p


## Key hint for the bottom bars: a keycap (or a mouse icon) and its action.
static func hint(key: String, text: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if key.begins_with("@"):
		var tr := TextureRect.new()
		tr.texture = icon(key.substr(1), BONE, 22)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		h.add_child(tr)
	else:
		h.add_child(keycap(key))
	h.add_child(caption(text, 16, BONE, 400))
	return h


## A label in the display face.
static func caption(text: String, size: int = 16, color: Color = BONE, weight: int = 500, spacing: int = 0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", display_font(weight, spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


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
	t.set_font("font", "HeadingLabel", display_font(600, 1))
	t.set_font_size("font_size", "HeadingLabel", 30)
	t.set_color("font_color", "HeadingLabel", GOLD_HI if not hc else Color("#FFD48A"))
	t.set_type_variation("TitleLabel", "Label")
	t.set_font("font", "TitleLabel", display_font(700, 4))
	t.set_font_size("font_size", "TitleLabel", 64)
	t.set_color("font_color", "TitleLabel", text)
	t.set_type_variation("MutedLabel", "Label")
	t.set_color("font_color", "MutedLabel", Color(text, 0.85) if hc else Color(BONE, 0.72))
	t.set_font_size("font_size", "MutedLabel", 16)
	t.set_type_variation("SmallLabel", "Label")
	t.set_font_size("font_size", "SmallLabel", 15)

	# Buttons: a dark worn inset; hover warms it, press paints an ochre stroke, focus draws the gold rim.
	t.set_font("font", "Button", display_font(500, 1))
	t.set_font_size("font_size", "Button", 18)
	t.set_stylebox("normal", "Button", cell_box(Color(1, 1, 1, 0.95 if not hc else 1.0), 14.0))
	t.set_stylebox("hover", "Button", cell_box(Color(1.5, 1.3, 1.1), 14.0))
	t.set_stylebox("pressed", "Button", stroke_box(GOLD, 18.0, 8.0))
	t.set_stylebox("hover_pressed", "Button", stroke_box(GOLD_HI, 18.0, 8.0))
	t.set_stylebox("focus", "Button", rim_box(GOLD_HI))
	t.set_stylebox("disabled", "Button", cell_box(Color(1, 1, 1, 0.45), 14.0))
	t.set_color("font_color", "Button", text)
	t.set_color("font_hover_color", "Button", GOLD_HI)
	t.set_color("font_pressed_color", "Button", INK)
	t.set_color("font_hover_pressed_color", "Button", INK)
	t.set_color("font_focus_color", "Button", BONE_HI)
	t.set_color("font_disabled_color", "Button", Color(text, 0.35))
	t.set_color("icon_hover_color", "Button", GOLD_HI)
	# Big menu rows: plain text; a dark stroke slides in behind on hover / focus.
	t.set_type_variation("MenuButtonBig", "Button")
	t.set_font("font", "MenuButtonBig", display_font(500, 2))
	t.set_font_size("font_size", "MenuButtonBig", 24)
	t.set_stylebox("normal", "MenuButtonBig", flat(Color.TRANSPARENT, Color.TRANSPARENT, 0, 0, 22.0))
	t.set_stylebox("hover", "MenuButtonBig", stroke_box(Color(0.05, 0.035, 0.025, 0.92), 26.0, 8.0))
	t.set_stylebox("focus", "MenuButtonBig", stroke_box(Color(0.05, 0.035, 0.025, 0.7), 26.0, 8.0))
	t.set_stylebox("pressed", "MenuButtonBig", stroke_box(GOLD, 26.0, 8.0))
	t.set_stylebox("hover_pressed", "MenuButtonBig", stroke_box(GOLD, 26.0, 8.0))
	t.set_stylebox("disabled", "MenuButtonBig", flat(Color.TRANSPARENT, Color.TRANSPARENT, 0, 0, 22.0))

	for type in ["PanelContainer", "Panel"]:
		t.set_stylebox("panel", type, slab_box(26.0) if not hc else panel_style(bg_a))
	t.set_stylebox("panel", "TooltipPanel", flat(Color(INK, 0.97), Color(GOLD, 0.5), 1, 3, 12.0))
	t.set_color("font_color", "TooltipLabel", text)
	t.set_font_size("font_size", "TooltipLabel", 16)

	t.set_stylebox("background", "ProgressBar", flat(Color(0, 0, 0, 0.45), Color(BONE, 0.1), 1, 2, 0.0))
	t.set_stylebox("fill", "ProgressBar", flat(GOLD, Color.TRANSPARENT, 0, 2, 0.0))
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
	b.pressed.connect(Sfx.ui_click)
	b.focus_mode = Control.FOCUS_ALL
	return b


static func bar(color: Color, min_h: float = 8.0) -> ProgressBar:
	var p := ProgressBar.new()
	p.show_percentage = false
	p.max_value = 100.0
	p.custom_minimum_size.y = min_h
	p.add_theme_stylebox_override("fill", flat(color, Color.TRANSPARENT, 0, 2, 0.0))
	return p
