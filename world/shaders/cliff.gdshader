// Rock outcrops (Waterfall): the terrain's scanned rock layer, triplanar so the vertical faces don't stretch,
// with ledges catching moss and grass, dark wet rock where the falls spray, and ambient occlusion in the cracks.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform sampler2DArray albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 fall_point = vec3(0.0);   // where the water pours over the lip
uniform vec3 fall_bottom = vec3(0.0);
uniform float scale = 0.22;

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec4 tri(int layer, vec3 p, vec3 w) {
	return texture(albedo_tex, vec3(p.zy * scale, float(layer))) * w.x
		+ texture(albedo_tex, vec3(p.xz * scale, float(layer))) * w.y
		+ texture(albedo_tex, vec3(p.xy * scale, float(layer))) * w.z;
}

void fragment() {
	vec3 w = pow(abs(wnrm), vec3(4.0));
	w /= w.x + w.y + w.z;
	float n = texture(noise_tex, wpos.xz * 0.05).r;
	float n2 = texture(noise_tex, wpos.xz * 0.3 + wpos.y * 0.07).r;
	vec3 rock = tri(3, wpos, w).rgb;
	rock = mix(rock, vec3(dot(rock, vec3(0.3, 0.59, 0.11))), 0.45) * 1.15 + vec3(0.04);  // grey stone
	float strata = sin(wpos.y * 2.6 + n * 6.0) * 0.5 + 0.5;
	rock *= mix(0.72, 1.05, smoothstep(0.25, 0.75, strata)) * (0.8 + 0.35 * n2);
	// moss and grass on anything facing up
	float up = smoothstep(0.8, 0.95, wnrm.y + (n2 - 0.5) * 0.2);
	vec3 moss = tri(1, wpos, w).rgb * vec3(0.38, 0.52, 0.26);
	vec3 col = mix(rock, moss, up);
	// wet and dark in the spray around the fall, a streak of algae under the lip
	vec3 fall_dir = fall_bottom - fall_point;
	float t = clamp(dot(wpos - fall_point, fall_dir) / dot(fall_dir, fall_dir), 0.0, 1.0);
	float d = distance(wpos, fall_point + fall_dir * t);
	float wet = 1.0 - smoothstep(1.5, 7.0, d);
	col *= mix(1.0, 0.6, wet);
	col = mix(col, vec3(0.08, 0.11, 0.05), wet * (1.0 - up) * 0.35);
	// darker in the recesses (horizontal-facing rock low down, cracks)
	col *= mix(0.85, 1.0, smoothstep(0.0, 0.5, wnrm.y + 0.3));
	ALBEDO = col;
	ROUGHNESS = mix(0.9, 0.5, wet * (1.0 - up));
	SPECULAR = mix(0.25, 0.45, wet);
	NORMAL_MAP = texture(normal_tex, vec3((abs(wnrm.x) > abs(wnrm.z) ? wpos.zy : wpos.xy) * scale, 3.0)).rgb;
	NORMAL_MAP_DEPTH = 1.2;
	// sky and bounce light off the river and the meadow fill the shaded faces (they read as black otherwise)
	EMISSION = col * vec3(0.10, 0.12, 0.13) * (1.0 - up * 0.5);
}
