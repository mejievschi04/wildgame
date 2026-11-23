// Mountains beyond the playable map (Backdrop): forested foothills, bare rock and snow fields in the north;
// dark basalt, ash and glowing lava gullies on the southern volcanoes. Own aerial haze (the scene fog would hide
// everything this far away): the surface fades toward the sky's horizon colour with distance, less on high peaks.
// COLOR: r = north weight, g = south (volcanic) weight, b = near a crater (0..1), a = angle around that crater.
shader_type spatial;
render_mode fog_disabled, diffuse_burley, specular_schlick_ggx, cull_back;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 haze_color : source_color = vec3(0.64, 0.75, 0.87);
uniform float haze_density = 0.0003;      // scene fog density: applies inside the map square
uniform float haze_far_density = 0.0001; // thinner beyond it, so the far ranges stay readable
uniform float map_half = 2100.0;
uniform float haze_energy = 1.0;
uniform float lava_glow = 2.0;

varying vec3 wpos;
varying vec3 wnrm;
varying vec4 v_mask;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_mask = COLOR;
}

void fragment() {
	float h = wpos.y;
	float slope = 1.0 - wnrm.y;
	float n = texture(noise_tex, wpos.xz * 0.00035).r;
	float n2 = texture(noise_tex, wpos.xz * 0.0025 + vec2(0.3, 0.7)).r;
	float n3 = texture(noise_tex, wpos.xz * 0.012 + vec2(0.61, 0.17)).r;
	float north = v_mask.r;
	float south = v_mask.g;
	// low slopes: conifer forest (dark, mottled) with meadow clearings; volcanic lowland: olive scrub and ash
	float crowns = texture(noise_tex, wpos.xz * 0.045 + vec2(0.11, 0.53)).r;  // single trees, too small to see one by one
	vec3 forest = vec3(0.045, 0.072, 0.035) * (0.7 + 0.6 * crowns) * (0.9 + 0.2 * n2);
	vec3 meadow = vec3(0.15, 0.19, 0.08) * (0.9 + 0.2 * crowns);
	vec3 low = mix(forest, meadow, smoothstep(0.62, 0.8, n) * (1.0 - smoothstep(0.15, 0.3, slope)) * 0.7);
	low = mix(low, vec3(0.16, 0.15, 0.1) * (0.8 + 0.4 * n3), south * 0.6);
	// rock: grey granite in the north, near-black basalt and rust-brown ash on the volcanoes
	vec3 granite = vec3(0.30, 0.29, 0.28) * (0.6 + 0.6 * n3) * mix(0.75, 1.1, n2);
	vec3 basalt = mix(vec3(0.085, 0.08, 0.08), vec3(0.3, 0.2, 0.15), smoothstep(0.45, 0.8, n2)) * (0.75 + 0.5 * n3);
	vec3 rock = mix(granite, basalt, south);
	float treeline = mix(mix(700.0, 950.0, north), 650.0, south) + (n - 0.5) * 300.0;
	float bare = max(smoothstep(treeline - 80.0, treeline + 80.0, h), smoothstep(0.5, 0.75, slope + (n3 - 0.5) * 0.2));
	vec3 col = mix(low, rock, bare);
	// snow: low in the north, only the highest volcano tops in the south; it slides off steep faces
	float snowline = mix(mix(1500.0, 1250.0, north), 2400.0, south) + (n - 0.5) * 380.0 + (n2 - 0.5) * 160.0;
	float snow = smoothstep(snowline - 50.0, snowline + 120.0, h)
		* (1.0 - smoothstep(0.3 + 0.18 * smoothstep(snowline, snowline + 800.0, h), 0.5, slope + (n3 - 0.5) * 0.18));
	snow *= 1.0 - v_mask.b * 0.9;  // warm crater rims stay bare
	col = mix(col, vec3(0.9, 0.92, 0.96) * (0.92 + 0.1 * n3), snow);
	// lava: thin glowing streaks running down from the crater
	float streak = smoothstep(0.9, 0.99, sin(v_mask.a * TAU * 23.0 + n2 * 5.0) * 0.5 + 0.5) * smoothstep(0.7, 0.97, v_mask.b);
	streak = max(streak, smoothstep(0.96, 1.0, v_mask.b));  // the crater floor
	col = mix(col, vec3(0.05, 0.03, 0.02), streak * 0.8);
	vec3 ray = wpos - CAMERA_POSITION_WORLD;
	float dist = length(ray);
	vec2 dir = ray.xz / max(dist, 1.0);
	vec2 cam = CAMERA_POSITION_WORLD.xz;
	// how far the view ray runs inside the map square before it leaves it
	vec2 safe = vec2(abs(dir.x) < 1e-4 ? 1e-4 : dir.x, abs(dir.y) < 1e-4 ? 1e-4 : dir.y);
	vec2 tx = (sign(safe) * map_half - cam) / safe;
	float inside = clamp(min(tx.x, tx.y), 0.0, dist);
	float haze = 1.0 - exp(-inside * haze_density - (dist - inside) * haze_far_density);
	haze *= mix(1.0, 0.6, smoothstep(400.0, 2600.0, h));  // peaks stand above the thickest air
	ALBEDO = col * (1.0 - haze);
	ROUGHNESS = mix(0.92, 0.55, snow);
	SPECULAR = mix(0.2, 0.45, snow);
	EMISSION = haze_color * haze * haze_energy
		+ vec3(1.0, 0.32, 0.06) * streak * lava_glow * (1.0 - haze * 0.6);
}
