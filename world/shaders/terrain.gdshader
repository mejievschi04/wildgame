// Terrain splat shader: 6 scanned PBR layers (Texture2DArray) blended procedurally by
// forest mask, height, slope and macro noise. Layers:
// 0 forest floor · 1 grass · 2 mud bank · 3 rock · 4 river pebbles · 5 snow
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2DArray albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray arm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D forest_mask : hint_default_black, filter_linear;
uniform sampler2D macro_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float map_size = 260.0;
uniform float tile = 0.3;
uniform float water_level = 0.0;

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float n1 = texture(macro_noise, wpos.xz * 0.013).r;
	float n2 = texture(macro_noise, wpos.xz * 0.07 + vec2(0.37, 0.11)).r;
	float forest = texture(forest_mask, wpos.xz / map_size + 0.5).r;
	float h = wpos.y - water_level;
	float slope = 1.0 - wnrm.y;

	float w[6];
	float grass = clamp(1.0 - forest * 1.6 + (n1 - 0.5) * 0.9, 0.0, 1.0);
	w[0] = 1.0 - grass;
	w[1] = grass;
	float mud = 1.0 - smoothstep(0.25, 1.3, h + (n2 - 0.5) * 0.7);
	float pebbles = 1.0 - smoothstep(-0.75, -0.2, h + (n2 - 0.5) * 0.3);
	float rock = max(smoothstep(0.17, 0.3, slope + (n2 - 0.5) * 0.08), smoothstep(10.0, 14.0, h + n1 * 3.0));
	float snow = smoothstep(19.0, 23.0, h + n1 * 4.0) * (1.0 - smoothstep(0.35, 0.5, slope));
	// Apply in priority order (each layer covers the ones below it).
	for (int i = 0; i < 2; i++) { w[i] *= (1.0 - mud); }
	w[2] = mud * (1.0 - pebbles);
	w[4] = pebbles;
	for (int i = 0; i < 5; i++) { if (i != 3) w[i] *= (1.0 - rock); }
	w[3] = rock;
	for (int i = 0; i < 5; i++) { w[i] *= (1.0 - snow); }
	w[5] = snow;

	vec2 uv = wpos.xz * tile;
	// Steep rock: project on the dominant vertical plane to avoid stretching.
	vec2 uv_rock = abs(wnrm.x) > abs(wnrm.z) ? wpos.zy * tile : wpos.xy * tile;
	vec2 uv_rock_final = mix(uv, uv_rock, smoothstep(0.35, 0.6, slope));

	vec3 alb = vec3(0.0);
	vec3 nrm = vec3(0.0);
	vec3 arm = vec3(0.0);
	float total = 0.0;
	for (int i = 0; i < 6; i++) {
		if (w[i] < 0.01) continue;
		vec2 u = (i == 3) ? uv_rock_final : uv;
		// Anti-tiling: second, rotated & scaled sample blended by noise.
		vec2 u2 = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8)) * u * 0.43 + 0.5;
		float mixv = smoothstep(0.35, 0.65, n2);
		vec3 a = mix(texture(albedo_tex, vec3(u, float(i))).rgb, texture(albedo_tex, vec3(u2, float(i))).rgb, mixv);
		if (i == 1) { a *= vec3(0.82, 0.98, 0.7); }  // clearing grass: greener, less leaf-litter brown
		alb += a * w[i];
		nrm += texture(normal_tex, vec3(u, float(i))).rgb * w[i];
		arm += texture(arm_tex, vec3(u, float(i))).rgb * w[i];
		total += w[i];
	}
	total = max(total, 0.0001);
	alb /= total; nrm /= total; arm /= total;
	alb *= mix(0.82, 1.12, n1);
	// Wet darkening near the waterline.
	float wet = 1.0 - smoothstep(-0.1, 0.5, h);
	alb *= mix(1.0, 0.62, wet);
	ALBEDO = alb;
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = 1.0;
	AO = arm.r;
	AO_LIGHT_AFFECT = 0.4;
	ROUGHNESS = mix(arm.g, 0.25, wet * 0.7);
	METALLIC = 0.0;
}
