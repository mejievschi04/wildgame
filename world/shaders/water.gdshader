// River water: depth-based colour/opacity, scrolling normal waves, screen-space refraction.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 shallow_color : source_color = vec3(0.15, 0.23, 0.20);
uniform vec3 deep_color : source_color = vec3(0.025, 0.065, 0.07);
uniform float depth_fade = 1.6;
uniform sampler2D wave_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D wave_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec2 flow = vec2(0.0, 0.035);
uniform sampler2D depth_tex : hint_depth_texture, filter_linear;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv1 = wpos.xz * 0.11 + flow * TIME;
	vec2 uv2 = wpos.xz * 0.27 - flow.yx * TIME * 1.7;
	vec3 n = normalize(texture(wave_a, uv1).rgb * 2.0 - 1.0 + texture(wave_b, uv2).rgb * 2.0 - 1.0);
	NORMAL_MAP = n * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.6;

	float raw = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * ndc;
	view.xyz /= view.w;
	float depth = clamp(VERTEX.z - view.z, 0.0, 20.0);
	float k = 1.0 - exp(-depth / depth_fade);

	vec2 refr = SCREEN_UV + n.xy * 0.02 * k;
	vec3 behind = textureLod(screen_tex, refr, 1.0).rgb;
	vec3 tint = mix(shallow_color, deep_color, k);
	// Opaque surface showing the refracted bottom through clear shallows; soft shoreline.
	ALBEDO = mix(behind * 0.85, tint, clamp(k * 0.9 + 0.08, 0.0, 1.0));
	ROUGHNESS = 0.14;
	METALLIC = 0.0;
	SPECULAR = 0.38;
	ALPHA = smoothstep(0.0, 0.15, depth);
}
