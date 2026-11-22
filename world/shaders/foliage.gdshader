// Alpha-tested foliage with translucency and wind sway (trees, grass, ferns, shrubs).
// Wind is driven globally by the weather system (wind_strength, wind_direction).
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform bool use_normal = false;
uniform float alpha_cut = 0.42;
uniform vec3 backlight_color : source_color = vec3(0.28, 0.31, 0.22);
uniform float sway = 0.5;        // metres of top displacement at wind_strength = 1
uniform float height_ref = 12.0; // local height where sway reaches full strength

global uniform float wind_strength;
global uniform vec2 wind_direction;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = clamp(VERTEX.y / height_ref, 0.0, 1.0);
	h *= h;
	float t = TIME * (0.8 + wind_strength);
	float phase = dot(wp.xz, vec2(0.11, 0.07));
	float gust = sin(t * 0.6 + phase) * 0.5 + 0.5;
	float flutter = sin(t * 3.7 + phase * 3.0 + VERTEX.x * 4.0 + VERTEX.z * 3.0);
	float amount = wind_strength * (0.45 + 0.55 * gust) * h * sway;
	vec3 offset_world = vec3(wind_direction.x, 0.0, wind_direction.y) * amount
		+ vec3(0.0, flutter * 0.08 * wind_strength * h * sway, 0.0);
	VERTEX += inverse(mat3(MODEL_MATRIX)) * offset_world;
}

void fragment() {
	vec4 c = texture(albedo_tex, UV) * albedo_tint;
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	if (use_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
	BACKLIGHT = backlight_color;
	ROUGHNESS = 0.82;
	SPECULAR = 0.12;
}
