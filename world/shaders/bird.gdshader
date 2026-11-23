// A bird silhouette (Birds): body and two wings; the wings flap (or hold a glide) in the vertex shader.
// Mesh: wing vertices carry COLOR.r = 1 at the tip (0 at the body), COLOR.g = side (−1 left, +1 right encoded 0/1).
// INSTANCE_CUSTOM: r = flap phase, g = flap amount (0 glide … 1 flapping), b = size.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;

uniform vec3 color : source_color = vec3(0.08, 0.07, 0.07);

void vertex() {
	float tip = COLOR.r;
	float side = COLOR.g * 2.0 - 1.0;
	float phase = INSTANCE_CUSTOM.r * 6.2832 + TIME * 9.0;
	float flap = INSTANCE_CUSTOM.g;
	float beat = sin(phase) * 0.9 * flap + 0.12;   // a slight dihedral when gliding
	VERTEX.y += abs(VERTEX.x) * beat * tip * 1.4;
	VERTEX.x *= mix(1.0, 0.82, abs(sin(phase)) * flap * tip);
}

void fragment() {
	ALBEDO = color;
	ROUGHNESS = 0.9;
}
