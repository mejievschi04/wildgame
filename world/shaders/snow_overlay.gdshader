// Snow lying on whatever it overlays (material_overlay on rocks, logs and landmarks in the cold north): white on
// the upward-facing parts, broken at the edges, fading out of the cold climate (biome.gdshaderinc taiga_at).
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley, specular_schlick_ggx;
#include "res://world/shaders/biome.gdshaderinc"

uniform float amount = 1.0;

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

float hash3(vec3 p) {
	return fract(sin(dot(floor(p), vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}

void fragment() {
	float n = hash3(wpos * 6.0) * 0.5 + hash3(wpos * 2.0) * 0.5;
	float up = smoothstep(0.3 + 0.25 * n, 0.65 + 0.2 * n, wnrm.y);
	float cold = taiga_at(wpos.xz);
	ALBEDO = vec3(0.86, 0.89, 0.93);
	ROUGHNESS = 0.8;
	SPECULAR = 0.3;
	ALPHA = clamp(up * cold * amount, 0.0, 1.0);
}
