// Terrain splat shader: 6 scanned PBR layers (Texture2DArray) blended procedurally by
// forest mask, height, slope and macro noise. Layers:
// 0 forest floor · 1 grass · 2 mud bank · 3 rock · 4 river pebbles · 5 snow
shader_type spatial;
#include "res://world/shaders/cloud_shadow.gdshaderinc"
#include "res://world/shaders/biome.gdshaderinc"
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2DArray albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray arm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D forest_mask : hint_default_black, filter_linear;
uniform sampler2D grove_tex : hint_default_black, filter_linear;  // FarForest.grove_at: stands of trees
uniform sampler2D biome_tint : source_color, filter_linear;
uniform sampler2D macro_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
// tools/gen_terrain.py: R creek bed · G runoff gullies · B sediment
uniform sampler2D terrain_masks : hint_default_black, filter_linear;
uniform float map_size = 260.0;
uniform float tile = 0.3;
uniform float water_level = 0.0;
uniform float rain_wetness = 0.0;
// TerrainLod's far mesh: drop its pixels inside the window the full-resolution chunks cover (xz min, xz max)
uniform bool far_mesh = false;
uniform vec4 hole = vec4(0.0);

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	if (far_mesh && wpos.x > hole.x && wpos.z > hole.y && wpos.x < hole.z && wpos.z < hole.w) {
		discard;
	}
	float n1 = texture(macro_noise, wpos.xz * 0.013).r;
	float n2 = texture(macro_noise, wpos.xz * 0.07 + vec2(0.37, 0.11)).r;
	float forest = max(texture(forest_mask, wpos.xz / map_size + 0.5).r,
		smoothstep(0.35, 0.8, texture(grove_tex, wpos.xz / map_size + 0.5).r));
	float h = wpos.y - water_level;
	float slope = 1.0 - wnrm.y;

	float w[6];
	float grass = clamp(1.0 - forest * 1.45 + (n1 - 0.5) * 0.42, 0.0, 1.0);
	w[0] = 1.0 - grass;
	w[1] = grass;
	vec4 tm = texture(terrain_masks, wpos.xz / map_size + 0.5);
	float creek = tm.r + (n2 - 0.5) * 0.25;
	float mud = max(1.0 - smoothstep(0.25, 1.3, h + (n2 - 0.5) * 0.7), smoothstep(0.15, 0.45, creek));
	float pebbles = max(1.0 - smoothstep(-0.75, -0.2, h + (n2 - 0.5) * 0.3), smoothstep(0.55, 0.85, creek));
	// steep ground and the scree of eroded gullies are bare rock; the highest summits too
	float gully = smoothstep(0.45, 0.85, tm.g) * smoothstep(0.12, 0.3, slope) * smoothstep(25.0, 60.0, h);
	float rock = max(max(smoothstep(0.22, 0.42, slope + (n2 - 0.5) * 0.06), gully),
		smoothstep(128.0, 160.0, h + n1 * 6.0));
	float northern_range = smoothstep(800.0, 1800.0, wpos.x) * (1.0 - smoothstep(-2200.0, -1620.0, wpos.z));
	float snow_line = mix(278.0, 165.0, northern_range);
	float snow = smoothstep(snow_line, snow_line + 30.0, h + n1 * 6.0) * (1.0 - smoothstep(0.4, 0.58, slope));
	// the cold north lies under snow: everywhere but the steepest rock, thinner under the densest canopy, with
	// wind-scoured patches where the ground shows; the glacier is ice
	float tg = taiga_at(wpos.xz);
	float scour = smoothstep(0.62, 0.8, texture(macro_noise, wpos.xz * 0.021 + vec2(0.13, 0.57)).r + (n2 - 0.5) * 0.3);
	float cover = tg * (1.0 - smoothstep(0.5, 0.75, slope)) * (1.0 - 0.4 * smoothstep(0.6, 0.95, forest)) * (1.0 - 0.75 * scour);
	float glacier = glacier_at(wpos.xz);
	snow = max(snow, max(cover, glacier));
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
		if (i == 1) {
			// Meadow: keep the scan's detail (its brightness) but give it living colour — lush green with
			// drier, yellowed patches (the same macro noise drives the grass blades' colour).
			float lum = dot(a, vec3(0.299, 0.587, 0.114));
			float dry = smoothstep(0.5, 0.85, texture(macro_noise, wpos.xz * 0.004).r + (n1 - 0.5) * 0.3);
			vec3 meadow = mix(vec3(0.17, 0.26, 0.09), vec3(0.34, 0.32, 0.15), dry * 0.55);
			a = mix(a, meadow * clamp(lum / 0.34, 0.65, 1.2), 0.75);
		}
		if (i == 5) {
			// fresh snow: bright, faintly cool white (the scan read grey-violet under the blue sky light)
			float ls = dot(a, vec3(0.299, 0.587, 0.114));
			a = vec3(0.9, 0.93, 0.97) * clamp(0.82 + (ls - 0.6) * 0.5, 0.75, 1.0);
		}
		if (i == 3) {
			// Rock: the lichen scan is near black-brown and read as bare earth on the hillsides; lift it toward the
			// weathered sandstone of the 3D outcrops (Vegetation._place_outcrops), keeping all its lichen contrast.
			float lr = dot(a, vec3(0.299, 0.587, 0.114));
			a = mix(a, vec3(lr) * vec3(1.08, 1.0, 0.88), 0.4) * 1.7;
		}
		if (i == 0) {
			// Forest floor: dark, damp litter with mossy patches (no bright bare dirt under the trees).
			// moss and low green growth in broad patches, so a slope under open trees isn't one flat brown sheet
			float moss = smoothstep(0.3, 0.62, n2 + (n1 - 0.5) * 0.5 + (texture(macro_noise, wpos.xz * 0.11).r - 0.5) * 0.35);
			float l0 = dot(a, vec3(0.299, 0.587, 0.114));
			vec3 litter = vec3(0.30, 0.24, 0.16) * (l0 / 0.32);   // brown needles and leaves, not orange sand
			vec3 green = vec3(0.16, 0.24, 0.08) * (l0 / 0.32);    // moss
			a = mix(a, mix(litter, green, moss), 0.7) * 0.82;
		}
		alb += a * w[i];
		nrm += texture(normal_tex, vec3(u, float(i))).rgb * w[i];
		arm += texture(arm_tex, vec3(u, float(i))).rgb * w[i];
		total += w[i];
	}
	total = max(total, 0.0001);
	alb /= total; nrm /= total; arm /= total;
	vec3 biome = texture(biome_tint, wpos.xz / map_size + 0.5).rgb;
	alb *= mix(0.96, 1.04, n1) * mix(vec3(1.0), biome, 0.14);
	// Wet darkening near the waterline.
	float wet = max(max(1.0 - smoothstep(-0.1, 0.5, h), smoothstep(0.35, 0.8, tm.r) * 0.85), rain_wetness * 0.75);
	// ---- climate bands
	float tn = tundra_at(wpos.xz);
	float jg = jungle_at(wpos.xz);
	float ground = 1.0 - w[2] - w[3] - w[4] - w[5];   // the soil layers (meadow + forest floor)
	if (tn > 0.0) {
		// tundra: lichen-grey and moss-olive mottling with rusty dwarf-shrub patches, snow lying in hollows
		float l = dot(alb, vec3(0.299, 0.587, 0.114));
		float m1 = texture(macro_noise, wpos.xz * 0.05).r;
		float m2 = texture(macro_noise, wpos.xz * 0.21 + vec2(0.4, 0.1)).r;
		vec3 lichen = mix(vec3(0.46, 0.47, 0.40), vec3(0.30, 0.33, 0.18), smoothstep(0.35, 0.7, m1));
		lichen = mix(lichen, vec3(0.42, 0.24, 0.12), smoothstep(0.62, 0.8, m2) * 0.8);
		alb = mix(alb, lichen * clamp(l / 0.3, 0.7, 1.3), tn * ground * 0.85);
		float patch = smoothstep(0.58, 0.7, texture(macro_noise, wpos.xz * 0.018 + vec2(0.7, 0.3)).r + (1.0 - wnrm.y) * -1.5);
		alb = mix(alb, vec3(0.86, 0.88, 0.92), patch * tn * smoothstep(0.5, 1.0, tn));
	}
	if (jg > 0.0) {
		// jungle: deep, saturated greens in the open; dark red-brown soil and leaf litter under the canopy
		alb = mix(alb, alb * vec3(0.7, 0.95, 0.55), jg * w[1] * 0.7);
		vec3 soil = mix(vec3(0.20, 0.10, 0.05), vec3(0.11, 0.13, 0.05), smoothstep(0.4, 0.7, n2));
		alb = mix(alb, soil * (0.8 + 0.4 * n1), jg * w[0] * 0.7);
	}
	alb *= mix(1.0, 0.62, wet);
	alb = mix(alb, vec3(dot(alb, vec3(0.299, 0.587, 0.114))), w[2] * 0.35);  // muddy banks: earthy, not orange
	// Beyond the 3D grass, the ground reads as covered: meadows a deeper green, forests in their canopy's shade.
	float cam_d = length(wpos - CAMERA_POSITION_WORLD);
	float far = smoothstep(18.0, 90.0, cam_d);
	// Under the 3D grass the ground is the dark, shaded base of the sward: gaps between clumps read as grass, not dirt.
	// (wherever MeadowGrass grows: open, dry ground up to fairly steep slopes, including the rock layer's edge)
	float grassy = (1.0 - smoothstep(0.42, 0.62, slope)) * (1.0 - w[2] - w[4] - w[5]) * (1.0 - smoothstep(0.62, 0.9, forest));
	float sward = clamp(grassy, 0.0, 1.0) * (1.0 - smoothstep(20.0, 34.0, cam_d)) * (1.0 - wet);
	alb = mix(alb, vec3(0.04, 0.055, 0.02) * (0.8 + 0.4 * n2), sward);
	// under the trees: dark, damp humus between the forest-floor plants
	float humus = smoothstep(0.35, 0.75, forest) * (1.0 - smoothstep(0.45, 0.65, slope)) * (1.0 - w[2] - w[4] - w[5])
		* (1.0 - smoothstep(18.0, 30.0, cam_d)) * (1.0 - wet);
	// ... broken by low moss and sward in broad patches: in an open grove a sunlit slope was one sheet of bare earth
	float mossy = smoothstep(0.35, 0.65, n2 + (n1 - 0.5) * 0.5 + (texture(macro_noise, wpos.xz * 0.11).r - 0.5) * 0.35);
	vec3 humus_col = mix(vec3(0.055, 0.045, 0.03), vec3(0.035, 0.055, 0.02), mossy * 0.85);
	alb = mix(alb, humus_col * (0.75 + 0.5 * n2), clamp(humus, 0.0, 1.0) * 0.8);
	alb = mix(alb, alb * vec3(0.82, 0.95, 0.72), far * w[1] * (1.0 - wet));
	// beyond the impostors: the ground under a canopy is in its shade and reads as a dark green mass of crowns
	float canopy = smoothstep(0.25, 0.8, forest);
	alb = mix(alb, vec3(0.05, 0.075, 0.035) * (0.8 + 0.4 * n1), canopy * smoothstep(400.0, 1500.0, cam_d) * 0.85);
	alb *= mix(1.0, 0.62, far * canopy);
	// glacier ice: blue-white, streaked along its flow with dirty moraine bands and dark crevasses across it
	if (glacier > 0.01) {
		float along = wpos.z * 0.05 + (n1 - 0.5) * 3.0;
		float ghw = 170.0 * (0.75 + 0.7 * smoothstep(-3330.0, -4150.0, wpos.z)) + 28.0 * sin(wpos.z * 0.011 + 1.7);
		float across = (wpos.x - (155.0 + 95.0 * sin(wpos.z * 0.0019) + 34.0 * sin(wpos.z * 0.0044 + 1.3))) / ghw;
		float crev = smoothstep(0.82, 0.95, sin(along * 6.0 + across * 4.0 + n2 * 4.0) * 0.5 + 0.5) * smoothstep(0.2, 0.7, abs(across));
		float moraine = smoothstep(0.7, 0.85, abs(across)) * 0.6 + smoothstep(0.02, 0.0, abs(abs(across) - 0.45)) * 0.3;
		// snow-covered in the cirque, bare blue ice lower down the tongue
		float bare = smoothstep(-3700.0, -3450.0, wpos.z);
		vec3 ice = mix(vec3(0.86, 0.9, 0.95), mix(vec3(0.26, 0.46, 0.6), vec3(0.42, 0.6, 0.72), n2), bare * 0.9);
		ice = mix(ice, vec3(0.42, 0.4, 0.38), moraine);
		ice = mix(ice, vec3(0.12, 0.26, 0.38), crev * 0.85);
		alb = mix(alb, ice, glacier);
	}
	// beyond the impostors the snowy taiga's canopy reads grey-white, not the summer forest's dark green
	alb = mix(alb, vec3(0.62, 0.66, 0.68) * (0.85 + 0.3 * n1), tg * canopy * smoothstep(400.0, 1500.0, cam_d) * 0.7);
	ALBEDO = alb * mix(1.0, 0.58, cloud_shadow(wpos));
	NORMAL_MAP = nrm;
	NORMAL_MAP_DEPTH = 1.0;
	AO = arm.r;
	AO_LIGHT_AFFECT = 0.4;
	// Ground is matte (scanned roughness on the meadow layer let it mirror the bright sky at grazing angles).
	ROUGHNESS = mix(mix(max(arm.g, 0.85), 0.25, wet * 0.7), 0.35, glacier);
	SPECULAR = mix(0.25, 0.5, wet);
	// snow crystals glint in the sun: sparse, view-dependent sparkle
	float sparkle = step(0.985, fract(sin(dot(floor(wpos.xz * 40.0) + floor(VIEW.xy * 6.0), vec2(12.9898, 78.233))) * 43758.5453));
	EMISSION = vec3(0.6, 0.65, 0.7) * sparkle * w[5] * (1.0 - smoothstep(8.0, 30.0, cam_d));
	ROUGHNESS = mix(ROUGHNESS, 0.62, w[5]);
	METALLIC = 0.0;
}
