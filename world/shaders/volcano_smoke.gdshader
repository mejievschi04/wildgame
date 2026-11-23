// Ash plume over a volcano (Backdrop): a camera-facing column (turns about Y only) that widens and bends with the
// wind as it rises; scrolling noise billows; dark ash at the vent, paler and thinner higher up, lit from the sun's
// side, glowing orange at the base at night. Same aerial haze as the mountains.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float height = 3000.0;
uniform float width_base = 350.0;
uniform float width_top = 1700.0;
uniform vec2 drift = vec2(1200.0, 500.0);
uniform float strength = 1.0;
uniform vec3 light : source_color = vec3(1.0, 0.95, 0.88);
uniform vec3 haze_color : source_color = vec3(0.64, 0.75, 0.87);
uniform float haze_density = 0.00016;
uniform float lava_glow = 2.0;

varying float v_t;
varying float v_haze;

void vertex() {
	float t = UV.y;  // 0 at the vent … 1 at the top
	vec3 base = MODEL_MATRIX[3].xyz;
	vec3 to_cam = CAMERA_POSITION_WORLD - base;
	to_cam.y = 0.0;
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), normalize(to_cam + vec3(1e-3, 0.0, 0.0))));
	float w = mix(width_base, width_top, pow(t, 0.8));
	vec3 wp = base + right * (UV.x - 0.5) * w + vec3(0.0, t * height, 0.0)
		+ vec3(drift.x, 0.0, drift.y) * t * t;
	VERTEX = (inverse(MODEL_MATRIX) * vec4(wp, 1.0)).xyz;
	v_t = t;
	v_haze = 1.0 - exp(-length(wp - CAMERA_POSITION_WORLD) * haze_density);
}

void fragment() {
	vec2 uv = vec2(UV.x * 1.2, v_t * 1.6 - TIME * 0.006);
	float n = texture(noise_tex, uv).r * 0.6 + texture(noise_tex, uv * 2.3 + vec2(0.4, -TIME * 0.004)).r * 0.4;
	float edge = 1.0 - abs(UV.x - 0.5) * 2.0;
	float d = smoothstep(0.15, 0.65, edge * 0.9 + (n - 0.5) * 0.9);
	d *= smoothstep(0.0, 0.04, v_t) * (1.0 - smoothstep(0.55, 1.0, v_t + (n - 0.5) * 0.25));
	vec3 ash = mix(vec3(0.16, 0.15, 0.15), vec3(0.62, 0.62, 0.64), smoothstep(0.0, 0.7, v_t)) * (0.75 + 0.5 * n);
	vec3 col = ash * light;
	col += vec3(1.0, 0.35, 0.08) * lava_glow * 0.22 * pow(1.0 - v_t, 5.0);  // lit red from the crater at night
	col = mix(col, haze_color, v_haze * 0.85);
	ALBEDO = col;
	ALPHA = d * strength * mix(0.92, 0.55, v_t);
}
