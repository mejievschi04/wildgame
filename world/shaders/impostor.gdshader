// Far trees (FarForest): two crossed cards textured with an unlit capture of the tree model. Lit as a soft
// volume (normals bent out from the trunk axis), hidden closer than far_begin where the real trees stand.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;
#include "res://world/shaders/biome.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float far_begin = 165.0;
uniform float height = 16.0;
uniform vec3 backlight_color : source_color = vec3(0.25, 0.3, 0.12);

varying float v_y;
varying float v_snow;

void vertex() {
	v_y = clamp(VERTEX.y / height, 0.0, 1.0);
	v_snow = taiga_at((MODEL_MATRIX * vec4(VERTEX, 1.0)).xz);
	NORMAL = normalize(vec3(VERTEX.x, (VERTEX.y - height * 0.55) * 0.3, VERTEX.z) + NORMAL * 0.3);
	if (distance(MODEL_MATRIX[3].xz, INV_VIEW_MATRIX[3].xz) < far_begin) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb * mix(0.65, 1.0, v_y);
	ALBEDO = mix(ALBEDO, vec3(0.84, 0.87, 0.91) * mix(0.75, 1.0, v_y), v_snow * 0.6);  // snow-laden crowns
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ROUGHNESS = 0.85;
	SPECULAR = 0.1;
	BACKLIGHT = backlight_color;
}
