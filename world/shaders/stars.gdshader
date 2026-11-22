// Star field: one vertex per star on a big dome that follows the camera. COLOR.a = brightness,
// UV.x = twinkle seed. Faded in by `night` (0 day .. 1 deep night).
shader_type spatial;
render_mode unshaded, fog_disabled, blend_add, cull_disabled, shadows_disabled, depth_draw_never;

uniform float night = 0.0;
uniform float point_scale = 1.0;

varying float v_bright;

void vertex() {
	float tw = 0.75 + 0.25 * sin(TIME * (1.3 + UV.x * 2.7) + UV.x * 40.0);
	v_bright = COLOR.a * tw;
	POINT_SIZE = (1.0 + COLOR.a * 1.8) * point_scale;
}

void fragment() {
	ALBEDO = COLOR.rgb * v_bright * night * 1.4;
}
