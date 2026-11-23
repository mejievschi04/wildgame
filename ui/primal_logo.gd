class_name PrimalLogo
extends VBoxContainer
## The game's mark: a cave-painted hunt (the mammoth is the game's own model as a silhouette), the title
## carved in Oswald with rock grit, and the subtitle between two strokes. Scale with `scale_factor`.

@export var scale_factor := 1.0
@export var show_tagline := true

const GRIT_SHADER := """
shader_type canvas_item;
uniform sampler2D grain : repeat_enable, filter_linear;
void fragment() {
	vec4 c = COLOR * texture(TEXTURE, UV);
	float g = texture(grain, SCREEN_UV * vec2(5.0, 2.8)).r;
	float fine = texture(grain, SCREEN_UV * vec2(23.0, 13.0)).r;
	c.rgb *= mix(0.74, 1.08, g) * mix(0.9, 1.05, fine);
	c.a *= mix(0.45, 1.0, smoothstep(0.18, 0.42, fine));
	COLOR = c;
}
"""


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", int(4 * scale_factor))
	var k := scale_factor
	var frieze := _Frieze.new()
	frieze.custom_minimum_size = Vector2(430, 112) * k
	add_child(frieze)
	var title := Label.new()
	title.text = "WILDBOUND"
	title.add_theme_font_override("font", UITheme.display_font(700, int(7 * k)))
	title.add_theme_font_size_override("font_size", int(84 * k))
	title.add_theme_color_override("font_color", Color("#EFE3CB"))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	title.add_theme_constant_override("shadow_offset_y", int(3 * k))
	title.add_theme_constant_override("shadow_offset_x", 0)
	title.add_theme_constant_override("shadow_outline_size", int(10 * k))
	title.add_theme_constant_override("outline_size", 0)
	title.add_theme_constant_override("line_spacing", 0)
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = GRIT_SHADER
	mat.shader = sh
	mat.set_shader_parameter("grain", UITheme.tex("Grain"))
	title.material = mat
	add_child(title)
	var sub := HBoxContainer.new()
	sub.add_theme_constant_override("separation", int(12 * k))
	sub.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(sub)
	sub.add_child(_rule(k))
	var s := UITheme.caption(Loc.t("GAME_SUBTITLE").to_upper(), int(17 * k), UITheme.GOLD, 500, int(5 * k))
	sub.add_child(s)
	sub.add_child(_rule(k))
	if show_tagline:
		var tag := UITheme.caption(Loc.t("MENU_TAGLINE").to_upper(), int(14 * k), Color(UITheme.BONE, 0.7), 400, int(3 * k))
		add_child(tag)


func _rule(k: float) -> Control:
	var r := TextureRect.new()
	r.texture = UITheme.tex("Stroke")
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE
	r.custom_minimum_size = Vector2(56, 5) * k
	r.size_flags_vertical = SIZE_SHRINK_CENTER
	r.modulate = Color(UITheme.GOLD, 0.8)
	r.mouse_filter = MOUSE_FILTER_IGNORE
	return r


class _Frieze:
	extends Control

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var paint := Color("#C98A4B", 0.92)
		var h := size.y
		var mam := UITheme.tex("Mammoth")
		var ms := mam.get_size() * (h / mam.get_size().y)
		var hun := UITheme.tex("Hunters")
		var hs := hun.get_size() * (h * 0.56 / hun.get_size().y)
		draw_texture_rect(hun, Rect2(Vector2(size.x * 0.02, h - hs.y), hs), false, paint)
		draw_texture_rect(mam, Rect2(Vector2(size.x * 0.02 + hs.x * 1.08, 0), ms), false, paint)
		# A painted ground line under the scene.
		draw_texture_rect(UITheme.tex("Stroke"), Rect2(Vector2(0, h - 3), Vector2(size.x * 0.98, 4)), false, Color(paint, 0.6))
