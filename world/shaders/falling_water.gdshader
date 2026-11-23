// Moving water on a ribbon (Waterfall): the creek over the plateau and the fall down the cliff. UV.y runs with the
// flow (0 at the source), UV.x across. Streaks scroll down at the water's speed; the sheet is torn into ropes of
// white water and thins at its edges; foam gathers where it hits the pool. Lit and backlit, a little emissive so
// the falls glow white in shade.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float speed = 1.5;
uniform float length_m = 12.0;       // ribbon length in metres (streak scale)
uniform float whiteness = 1.0;       // 0 calm creek … 1 free fall
uniform vec3 water_color : source_color = vec3(0.16, 0.30, 0.30);
uniform vec3 foam_color : source_color = vec3(0.92, 0.95, 0.96);

void fragment() {
	vec2 uv = vec2(UV.x * 1.6, UV.y * length_m * 0.18 - TIME * speed * 0.18);
	float n = texture(noise_tex, uv * vec2(1.0, 0.35)).r;
	float n2 = texture(noise_tex, uv * vec2(3.0, 0.8) + vec2(0.37, -TIME * speed * 0.1)).r;
	float streak = smoothstep(0.35, 0.75, n * 0.6 + n2 * 0.6);
	float edge = 1.0 - pow(abs(UV.x - 0.5) * 2.0, 3.0);
	float white = clamp(mix(0.25, 1.0, whiteness) * streak + whiteness * 0.35 * UV.y + smoothstep(0.85, 1.0, UV.y) * 0.8, 0.0, 1.0);
	vec3 col = mix(water_color, foam_color, white);
	ALBEDO = col;
	EMISSION = foam_color * white * 0.12;
	ROUGHNESS = mix(0.08, 0.5, white);
	SPECULAR = 0.6;
	BACKLIGHT = col * 0.5;
	ALPHA = clamp(edge * mix(0.55, 0.97, white) * smoothstep(0.0, 0.05, UV.y), 0.0, 1.0);
}
