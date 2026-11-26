// River water: depth-based colour/opacity, scrolling normal waves, screen-space refraction, sky reflection
// (low roughness + Fresnel), animated foam along the banks.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;
#include "res://world/shaders/biome.gdshaderinc"

uniform vec3 shallow_color : source_color = vec3(0.12, 0.30, 0.27);
uniform vec3 deep_color : source_color = vec3(0.015, 0.07, 0.09);
uniform vec3 foam_color : source_color = vec3(0.85, 0.88, 0.85);
uniform vec4 rapids = vec4(0.0, 0.0, 0.0, 0.0);  // x, z, radius, strength: white water below a waterfall
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
	// The riverbed seen through the water is light that already reached the eye: pass it as emission (lighting
	// it again as albedo made the water grey); the water's own colour takes over with depth.
	float clear_k = 1.0 - clamp(k * 0.92 + 0.05, 0.0, 1.0);
	ALBEDO = tint * (1.0 - clear_k);
	EMISSION = behind * tint * 3.2 * clear_k;
	// Foam: a few broken flecks where the water laps the bank (not a solid white line along it), patchy along
	// the shore — some stretches have none.
	float fn = texture(wave_a, wpos.xz * 0.6 + flow * TIME * 2.0).r * texture(wave_b, wpos.xz * 1.3 - flow * TIME).g;
	float patches = smoothstep(0.45, 0.7, texture(wave_a, wpos.xz * 0.04).g);
	float foam = (1.0 - smoothstep(0.02, 0.14, depth)) * smoothstep(0.24, 0.4, fn) * patches * 0.6;
	// white water: a churning patch where the falls hit, streaming off downstream (+z) in broken bands
	if (rapids.w > 0.0) {
		vec2 rel = wpos.xz - rapids.xy;
		float down = max(rel.y, 0.0);
		float reach = length(vec2(rel.x * mix(1.0, 1.6, smoothstep(0.0, 25.0, down)), min(rel.y, 0.0)))
			+ max(down - 0.0, 0.0) * 0.25;
		float zone = (1.0 - smoothstep(rapids.z * 0.3, rapids.z, reach)) * rapids.w;
		float churn = texture(wave_a, wpos.xz * 0.35 + vec2(0.0, -TIME * 0.6)).r * texture(wave_b, wpos.xz * 0.9 - vec2(0.0, TIME * 1.1)).g;
		float ww = zone * smoothstep(0.32 - zone * 0.12, 0.5, churn) * 0.85;
		foam = max(foam, ww);
		n = normalize(n + vec3(0.0, 0.0, zone * 0.6));
	}
	ALBEDO = mix(ALBEDO, foam_color, foam * 0.8);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ROUGHNESS = mix(0.06, 0.6, foam);
	METALLIC = 0.0;
	SPECULAR = mix(0.5, 0.9, fres);
	ALPHA = smoothstep(0.0, 0.25, depth);  // soft shoreline instead of a hard cut along the terrain
	// Frozen over in the cold north: opaque, snow-dusted ice with pale cracks and darker clear patches.
	float frozen = smoothstep(0.35, 0.6, taiga_at(wpos.xz));
	if (frozen > 0.0) {
		float crack_n = texture(wave_b, wpos.xz * 0.07).r;
		float crack = 1.0 - smoothstep(0.0, 0.025, abs(crack_n - 0.5));
		float clear = smoothstep(0.55, 0.7, texture(wave_a, wpos.xz * 0.013).g);
		float dust = smoothstep(0.35, 0.75, texture(wave_a, wpos.xz * 0.05 + 0.3).r);
		vec3 ice = mix(vec3(0.55, 0.68, 0.76), vec3(0.2, 0.32, 0.4), clear);
		ice = mix(ice, vec3(0.88, 0.91, 0.94), dust * (1.0 - clear * 0.7));
		ice = mix(ice, vec3(0.92, 0.95, 0.97), crack * 0.6);
		ALBEDO = mix(ALBEDO, ice, frozen);
		EMISSION *= 1.0 - frozen;
		NORMAL_MAP = mix(NORMAL_MAP, vec3(0.5, 0.5, 1.0), frozen * 0.85);
		ROUGHNESS = mix(ROUGHNESS, mix(0.55, 0.15, clear), frozen);
		SPECULAR = mix(SPECULAR, 0.5, frozen);
		ALPHA = mix(ALPHA, 1.0, frozen);
	}
}
