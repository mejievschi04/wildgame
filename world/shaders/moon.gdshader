// Moon disc: a camera-facing quad far out on the sky. Procedural maria and craters, a phase terminator lit
// from the side (phase 0 = new, 0.5 = full), faint earthshine on the dark side, soft limb.
shader_type spatial;
render_mode unshaded, fog_disabled, blend_mix, cull_disabled, shadows_disabled, depth_draw_never;

uniform float phase = 0.5;        // 0..1 lunar cycle
uniform float visibility = 1.0;   // fades out by day / below the horizon
uniform vec3 tint : source_color = vec3(1.0, 0.97, 0.9);

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void vertex() {
	// Billboard: keep the quad facing the camera.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	if (r > 1.0) discard;
	vec3 n = vec3(p.x, -p.y, sqrt(max(1.0 - r * r, 0.0)));
	// Surface: darker maria (large blotches) and small craters.
	float maria = smoothstep(0.45, 0.7, noise(p * 2.2 + vec2(3.1, 1.7)) * 0.7 + noise(p * 5.0) * 0.3);
	float craters = 0.0;
	for (int i = 0; i < 3; i++) {
		float sc = 7.0 + float(i) * 6.0;
		vec2 c = p * sc + float(i) * 11.0;
		float d = length(fract(c) - 0.5 - (vec2(hash(floor(c)), hash(floor(c) + 4.0)) - 0.5) * 0.4);
		craters += smoothstep(0.22, 0.12, d) * step(0.72, hash(floor(c) + 9.0)) * 0.12;
	}
	float albedo = 0.92 - maria * 0.3 - craters + (noise(p * 14.0) - 0.5) * 0.06;
	// Phase: the sun goes around the moon once a cycle.
	float a = phase * 6.2831853;
	vec3 sun_dir = normalize(vec3(sin(a), 0.0, -cos(a)));
	float lit = smoothstep(-0.03, 0.08, dot(n, sun_dir));
	float limb = 0.75 + 0.25 * n.z;  // gentle limb darkening
	vec3 col = tint * albedo * limb * (lit + 0.035);
	ALBEDO = col * 1.6;
	ALPHA = visibility * smoothstep(1.0, 0.97, r) * clamp(lit + 0.25, 0.0, 1.0);
}
