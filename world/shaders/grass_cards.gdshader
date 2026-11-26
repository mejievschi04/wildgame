// Meadow grass around the camera (MeadowGrass): every instance is a cluster of 3 crossed cards textured with
// one of four painted clumps (T_GrassCards_D: lush, tall with seed heads, dry, flowering). Instances live on a
// grid in a ±radius window that wraps around the camera, so each clump keeps a stable world position while in
// view. Height comes from the terrain grid (same interpolation as ForestWorld.height_at); a baked mask keeps
// water, steep rock and dense forest bare, and fires/buildings clear a circle. Wind from the weather.
shader_type spatial;
#include "res://world/shaders/cloud_shadow.gdshaderinc"
#include "res://world/shaders/biome.gdshaderinc"
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, world_vertex_coords;

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D atlas_jungle : source_color, filter_linear_mipmap_anisotropic, repeat_disable;  // forest floor, south
uniform sampler2D height_tex : filter_nearest;        // (GRID+1)² terrain heights, R32F
uniform sampler2D grass_mask : hint_default_black, filter_linear;  // baked: 0 bare … 1 full meadow
uniform sampler2D terrain_masks : hint_default_black, filter_linear;  // tools/gen_terrain.py: R creek bed
uniform sampler2D macro_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float half_size = 2100.0;
uniform float cell = 10.0;
uniform int grid = 420;
uniform float map_size = 4200.0;
uniform float radius = 24.0;
uniform vec2 wind_dir = vec2(0.8, 0.6);
uniform float wind_strength = 0.35;
uniform vec4 bare[12];
uniform bool forest_floor = false;
uniform float columns = 5.0;        // atlas columns (512 px each)
uniform float water_level = 0.0;  // T_ForestCards_D: fern, sedge, bilberry, sapling under the trees  // xz centre, radius (fires, buildings)

varying vec3 v_up;
varying float v_col;   // atlas column 0..3
varying float v_tint;
varying float v_dry;
varying float v_cloud;
varying float v_jungle;   // 1: sample the jungle atlas (forest floor)
varying float v_tundra;

float th(int ix, int iz) {
	return texelFetch(height_tex, ivec2(clamp(ix, 0, grid), clamp(iz, 0, grid)), 0).r;
}

float terrain_h(vec2 p, out vec2 grad) {
	float gx = (p.x + half_size) / cell;
	float gz = (p.y + half_size) / cell;
	int ix = min(int(floor(gx)), grid - 1);
	int iz = min(int(floor(gz)), grid - 1);
	float u = gx - float(ix);
	float v = gz - float(iz);
	float a = th(ix, iz);
	float b = th(ix + 1, iz);
	float c = th(ix, iz + 1);
	if (u + v <= 1.0) {
		grad = vec2(b - a, c - a) / cell;
		return a * (1.0 - u - v) + b * u + c * v;
	}
	float d = th(ix + 1, iz + 1);
	grad = vec2(d - c, d - b) / cell;
	return b * (1.0 - v) + c * (1.0 - u) + d * (u + v - 1.0);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	vec3 inst = MODEL_MATRIX[3].xyz;
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec2 span = vec2(radius * 2.0);
	vec2 wrapped = cam.xz + mod(inst.xz - cam.xz + radius, span) - radius;
	vec2 grad;
	float h = terrain_h(wrapped, grad);
	float r1 = hash(inst.xz);
	float r2 = hash(inst.xz + 17.0);
	float want = texture(grass_mask, wrapped / map_size + 0.5).r
		* (1.0 - smoothstep(0.25, 0.55, texture(terrain_masks, wrapped / map_size + 0.5).r));  // not in creek beds
	float n1 = texture(macro_noise, wrapped * 0.013).r;
	float dryness = smoothstep(0.5, 0.85, texture(macro_noise, wrapped * 0.004).r + (n1 - 0.5) * 0.3);
	float tall = smoothstep(0.55, 0.72, texture(macro_noise, wrapped * 0.025 + vec2(0.71, 0.13)).r);
	float bloom = smoothstep(0.6, 0.75, texture(macro_noise, wrapped * 0.03 + vec2(0.31, 0.77)).r) * (1.0 - dryness);
	// which clump: flowers in their patches, tall grass in its swathes, dry clumps where the meadow is dry
	float col = 0.0;
	float hmul = 1.0;
	if (forest_floor) {
		// sedge and bilberry carpets. No fern or spruce-sapling card: a frond or a little spruce painted on a flat card
		// reads as a ladder standing in the ground whenever it faces the camera; the 3D ferns and the groves' 3D
		// saplings (Vegetation) stand in for them.
		col = r2 < 0.6 ? 2.0 : 1.0;
		hmul = col == 0.0 ? 1.05 : (col == 3.0 ? 2.4 : (col == 2.0 ? 0.85 : 1.15));
	} else {
		if (r2 < dryness * 0.75) col = 2.0;
		if (r2 > 1.0 - tall * 0.8) col = 1.0;
		if (hash(inst.xz + 41.0) < bloom * 0.55) col = 3.0;
		// reeds and cattails along the water's edge
		float bank = (1.0 - smoothstep(0.6, 1.3, h - water_level))
			* smoothstep(0.35, 0.65, texture(macro_noise, wrapped * 0.05 + vec2(0.9, 0.2)).r);  // reed beds, not a hedge
		if (hash(inst.xz + 63.0) < bank * 0.8) {
			col = 4.0;
			hmul = 2.4;
		}
	}
	// climate: lush, tall jungle undergrowth in the south; short, sparse, rusty tundra sward in the north
	float jg = jungle_at(wrapped);
	float tn = tundra_at(wrapped);
	v_jungle = 0.0;
	if (forest_floor && hash(inst.xz + 77.0) < jg) {
		v_jungle = 1.0;
		col = floor(hash(inst.xz + 91.0) * 3.99);
		hmul = col == 2.0 ? 2.6 : (col == 0.0 ? 2.0 : 1.6);
	}
	if (!forest_floor) {
		if (col == 2.0) col = mix(col, 0.0, step(0.5, jg));          // no dry clumps in the jungle
		if (col == 3.0 && tn > 0.5 && r2 > 0.15) col = 2.0;          // few flowers on the tundra
		if (tn > 0.3 && r2 < tn * 0.6) col = 2.0;
		if (col == 4.0 && tn > 0.4) { col = 0.0; hmul = 1.0; }       // no reed beds on the tundra
		hmul = mix(hmul, hmul * 1.35, jg);
	}
	v_tundra = max(tn, taiga_at(wrapped));
	v_col = col;
	v_dry = dryness;
	v_tint = 0.85 + 0.3 * hash(inst.xz + 5.0);
	// under the snow of the cold north only a few dry stalks poke through (none on the glacier)
	float tg = taiga_at(wrapped);
	want *= (1.0 - 0.88 * tg) * (1.0 - glacier_at(wrapped));
	if (tg > 0.5) { col = 2.0; hmul *= 0.8; }
	float keep = step(r1, want);
	for (int i = 0; i < 12; i++) {
		if (bare[i].z > 0.0 && distance(wrapped, bare[i].xy) < bare[i].z) {
			keep = 0.0;
		}
	}
	float dist = distance(wrapped, cam.xz);
	float fade = 1.0 - smoothstep(radius * 0.7, radius * 0.97, dist);
	// LOD: far clusters keep one of their three cards (COLOR.g = card id)
	float lod = step(COLOR.g, 1.0 - 0.66 * smoothstep(radius * 0.35, radius * 0.6, dist));
	vec3 local = VERTEX - inst;
	float hscale = (forest_floor || col == 4.0 ? hmul : (col == 1.0 ? 1.5 : 1.0) * mix(1.0, 1.35, jg)) * mix(0.75, 1.25, hash(inst.xz + 9.0));
	hscale *= mix(1.0, 0.55, tn);                    // tundra: everything hugs the ground
	keep *= step(hash(inst.xz + 53.0), 1.0 - 0.45 * tn);   // …and is sparse
	float s = keep * lod * fade;
	local.y *= s * hscale;
	local.xz *= s;  // hidden clumps collapse to a point (a flattened card would lie on the ground as a pale patch)
	float top = clamp(1.0 - UV.y, 0.0, 1.0);  // atlas: roots at the bottom (UV.y = 1)
	float gust = sin(TIME * 1.6 + dot(wrapped, vec2(0.21, 0.13))) * 0.5 + 0.6 + 0.25 * sin(TIME * 3.9 + wrapped.x * 0.9);
	local.xz += wind_dir * gust * wind_strength * top * top * 0.35 * hscale;
	VERTEX = vec3(wrapped.x, h - 0.04, wrapped.y) + local;
	NORMAL = normalize(vec3(-grad.x, 1.0, -grad.y));
	v_up = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_cloud = cloud_shadow(vec3(wrapped.x, h, wrapped.y));
}

void fragment() {
	vec2 uv = vec2((v_col + clamp(UV.x, 0.002, 0.998)) / columns, UV.y);
	vec4 c = v_jungle > 0.5 ? texture(atlas_jungle, uv) : texture(atlas, uv);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	NORMAL = v_up;
	float top = 1.0 - UV.y;
	vec3 albedo = c.rgb * v_tint * (forest_floor ? vec3(0.8) : mix(vec3(0.86, 1.0, 1.05), vec3(1.05, 1.0, 0.85), v_dry * 0.6));
	albedo = mix(albedo, vec3(dot(albedo, vec3(0.3, 0.59, 0.11))), 0.18);  // natural, not neon
	albedo = mix(albedo, albedo * vec3(1.12, 0.92, 0.7) + vec3(0.03, 0.0, 0.0), v_tundra * 0.7);  // rusty tundra
	ALBEDO = albedo * mix(0.45, 1.0, smoothstep(0.0, 0.45, top)) * mix(1.0, 0.58, v_cloud);  // self-shadowed base
	ROUGHNESS = 0.78;
	SPECULAR = 0.3;
	BACKLIGHT = albedo * 0.55 * top;  // sun through the blades
	AO = mix(0.5, 1.0, top);
	AO_LIGHT_AFFECT = 0.35;
}
