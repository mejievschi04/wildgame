// Alpha-tested foliage with translucency and wind sway (trees, grass, ferns, shrubs).
// Wind is driven globally by the weather system (wind_strength, wind_direction).
shader_type spatial;
#include "res://world/shaders/cloud_shadow.gdshaderinc"
#include "res://world/shaders/biome.gdshaderinc"
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_tint : source_color = vec4(1.0);
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform bool use_normal = false;
uniform float alpha_cut = 0.42;
uniform vec3 backlight_color : source_color = vec3(0.28, 0.31, 0.22);
uniform float sway = 0.5;        // metres of top displacement at wind_strength = 1
uniform float height_ref = 12.0; // local height where sway reaches full strength
// Trees: shade the crown as one soft volume (normals pointing out from the trunk axis) instead of per leaf card,
// darken its inside and underside, and pull the leaf colour toward a deeper green.
uniform bool crown = false;
uniform float crown_center = 9.0;    // model-space height of the crown's middle
uniform float crown_radius = 3.5;
uniform vec3 color_mul = vec3(1.0);
uniform float far_begin = 0.0;   // FarForest copies: hidden closer than this (the streamed, fellable trees are there)

varying float v_ao;
varying float v_cloud;
varying float v_snow;  // snow lying on the branches (the cold north): more on top, on upward-facing cards

global uniform float wind_strength;
global uniform vec2 wind_direction;

void vertex() {
	v_ao = 1.0;
	// snow on the branches: from the card's own facing (before the crown's normal bend), heavier toward the top
	vec3 wn0 = normalize(mat3(MODEL_MATRIX) * NORMAL);
	v_snow = taiga_at((MODEL_MATRIX * vec4(VERTEX, 1.0)).xz) * clamp(0.55 + abs(wn0.y) * 0.6, 0.0, 1.0)
		* mix(0.7, 1.0, clamp(VERTEX.y / max(height_ref, 0.1), 0.0, 1.0));
	if (crown) {
		vec3 out_dir = vec3(VERTEX.x, (VERTEX.y - crown_center) * 0.45, VERTEX.z);
		float r = length(VERTEX.xz);
		NORMAL = normalize(mix(NORMAL, normalize(out_dir + vec3(0.0, 0.15, 0.0)), 0.75));
		// the crown's inside and underside are shaded, but light still filters through needles: not black
		v_ao = mix(0.62, 1.0, clamp(r / crown_radius, 0.0, 1.0)) * mix(0.8, 1.0, clamp((VERTEX.y - crown_center) / crown_radius * 0.5 + 0.5, 0.0, 1.0));
	}
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_cloud = cloud_shadow(wp);
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
	if (far_begin > 0.0 && distance(MODEL_MATRIX[3].xz, INV_VIEW_MATRIX[3].xz) < far_begin) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	vec4 c = texture(albedo_tex, UV) * albedo_tint;
	ALBEDO = c.rgb * color_mul * mix(1.0, v_ao, 0.5) * mix(1.0, 0.58, v_cloud);
	// snow clings in clumps along the needles: a broken white over the top of each card
	float clump = smoothstep(0.25, 0.65, fract(sin(dot(floor(UV * 9.0), vec2(12.9898, 78.233))) * 43758.5453));
	float snow = clamp(v_snow * (0.55 + 0.6 * clump), 0.0, 0.92);
	ALBEDO = mix(ALBEDO, vec3(0.86, 0.89, 0.93) * mix(1.0, v_ao, 0.4), snow);
	AO = v_ao;
	AO_LIGHT_AFFECT = 0.35;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_cut;
	// Leaves right in front of the eye thin out (standing at a trunk you'd push the branches aside): the
	// screen no longer fills with dark needles while chopping.
	float eye = length(VERTEX);
	ALPHA *= smoothstep(0.5, 1.9, eye);
	if (use_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
	BACKLIGHT = backlight_color * (crown ? v_ao : 1.0);
	ROUGHNESS = 0.82;
	SPECULAR = 0.12;
}
