// Border mountains (Backdrop), shaded from the baked, eroded heightfield (tools/gen_backdrop.py):
//  · per-texel normals (~21 m) and ambient occlusion from T_Backdrop_N; water flow (gullies) and deposited sediment
//    from T_Backdrop_HM
//  · real terrain shadows: every pixel marches toward the sun over the height texture, so ridges shade the valleys
//    behind them and peaks throw long shadows at sunrise and sunset
//  · materials: conifer forest that climbs higher in the gullies, alpine meadow, layered granite with a scanned
//    rock texture up close, scree fans, snow on ledges and in couloirs; on the volcanoes basalt, rusty ash and lava
//    glowing in the gullies below the crater
//  · own aerial haze (inside the map: the scene fog density; beyond it thinner) and mist lying in the valleys.
// COLOR: r = north weight, g = south (volcanic) weight, b = near a crater, a = unused.
shader_type spatial;
render_mode fog_disabled, cull_back;

uniform sampler2D hm_tex : filter_linear_mipmap, repeat_disable;    // b = flow, a = deposit
uniform sampler2D n_tex : filter_linear_mipmap, repeat_disable;     // rgb = world normal, a = AO
uniform sampler2D height_tex : filter_linear, repeat_disable;       // absolute height (m), RF
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform sampler2DArray rock_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float extent = 11000.0;
uniform float texels = 1024.0;
uniform vec3 sun_dir = vec3(0.3, 0.8, 0.4);   // toward the sun, world space
uniform vec3 haze_color : source_color = vec3(0.64, 0.75, 0.87);
uniform float haze_density = 0.0002;
uniform float haze_far_density = 0.00006;
uniform float map_half = 2100.0;
uniform float haze_energy = 1.0;
uniform float mist = 0.3;
uniform float lava_glow = 2.0;

varying vec3 wpos;
varying vec4 v_mask;
varying float v_shadow;
varying float v_snow;
varying vec3 v_sun_view;

vec2 to_uv(vec2 p) {
	return (p + extent) / (2.0 * extent) * (texels - 1.0) / texels + 0.5 / texels;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_mask = COLOR;
}

vec3 triplanar(vec3 p, vec3 n, float layer, float scale) {
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	return texture(rock_tex, vec3(p.zy * scale, layer)).rgb * w.x
		+ texture(rock_tex, vec3(p.xz * scale, layer)).rgb * w.y
		+ texture(rock_tex, vec3(p.xy * scale, layer)).rgb * w.z;
}

void fragment() {
	vec2 uv = to_uv(wpos.xz);
	vec4 nt = texture(n_tex, uv);
	vec3 nw = normalize(nt.xyz * 2.0 - 1.0);
	float ao = nt.a;
	vec4 hm = texture(hm_tex, uv);
	float flow = hm.b;
	float dep = hm.a;
	float h = wpos.y;
	float n = texture(noise_tex, wpos.xz * 0.00035).r;
	float n2 = texture(noise_tex, wpos.xz * 0.0025 + vec2(0.3, 0.7)).r;
	float n3 = texture(noise_tex, wpos.xz * 0.012 + vec2(0.61, 0.17)).r;
	float north = v_mask.r;
	float south = v_mask.g;
	float slope = 1.0 - nw.y;
	vec3 ray = wpos - CAMERA_POSITION_WORLD;
	float dist = length(ray);
	float near = 1.0 - smoothstep(250.0, 1100.0, dist);  // scanned texture detail only where it can be seen

	// ---- rock: layered granite (north) / basalt and ash (volcanoes)
	vec3 granite = vec3(0.23, 0.22, 0.21) * (0.8 + 0.4 * n3);
	float strata = sin(h * 0.035 + n * 9.0) * 0.5 + 0.5;  // bedding planes across the cliffs
	granite *= mix(0.88, 1.06, smoothstep(0.3, 0.7, strata));
	granite = mix(granite, vec3(0.42, 0.36, 0.29), smoothstep(0.55, 0.8, n) * 0.35);  // iron-stained bands
	vec3 basalt = mix(vec3(0.075, 0.07, 0.07), vec3(0.32, 0.2, 0.14), smoothstep(0.45, 0.8, n2 + dep * 0.4)) * (0.8 + 0.4 * n3);
	vec3 rock = mix(granite, basalt, south);
	if (near > 0.0) {
		vec3 det = triplanar(wpos, nw, 3.0, 1.0 / 14.0);
		float l = dot(det, vec3(0.3, 0.59, 0.11));
		rock *= mix(1.0, clamp(l / 0.35, 0.5, 1.6), near * 0.8);
	}
	rock *= mix(0.5, 1.0, ao) * mix(1.0, 0.7, flow) * mix(1.0, 0.72, smoothstep(0.55, 0.85, slope));  // dark cliffs   // wet, shaded gullies; bright ridges
	// scree: grey debris fans where sediment collects below the cliffs
	vec3 scree = mix(vec3(0.42, 0.40, 0.37), vec3(0.22, 0.18, 0.14), south) * (0.8 + 0.3 * n3);
	rock = mix(rock, scree, smoothstep(0.25, 0.7, dep) * (1.0 - smoothstep(0.55, 0.8, slope)));

	// ---- vegetation: forest up to the treeline (higher in sheltered gullies), alpine meadow above
	float crowns = texture(noise_tex, wpos.xz * 0.045 + vec2(0.11, 0.53)).r;
	vec3 forest = vec3(0.04, 0.065, 0.032) * (0.65 + 0.7 * crowns) * mix(0.75, 1.0, ao);
	vec3 meadow = mix(vec3(0.20, 0.24, 0.09), vec3(0.32, 0.30, 0.14), n2) * (0.85 + 0.3 * crowns);
	vec3 ash_plain = vec3(0.17, 0.15, 0.1) * (0.8 + 0.4 * n3);
	float treeline = mix(mix(850.0, 1050.0, north), 600.0, south) + (n - 0.5) * 260.0 + flow * 220.0;
	float tree = (1.0 - smoothstep(treeline - 60.0, treeline + 60.0, h)) * (1.0 - smoothstep(0.42, 0.62, slope));
	float grass = (1.0 - smoothstep(treeline + 250.0, treeline + 450.0, h)) * (1.0 - smoothstep(0.35, 0.55, slope)) * (1.0 - tree);
	vec3 col = rock;
	col = mix(col, mix(meadow, ash_plain, south * 0.7), grass);
	col = mix(col, mix(forest, ash_plain * 0.8, south * 0.5), tree);

	// ---- snow: on ledges and gentle slopes above the snowline, deep in the couloirs, blown off the steep faces
	float snowline = mix(mix(1400.0, 1250.0, north), 2300.0, south) + (n - 0.5) * 300.0 + (n2 - 0.5) * 120.0;
	float above = smoothstep(snowline - 60.0, snowline + 140.0, h);
	float hold = 1.0 - smoothstep(0.32 + 0.22 * smoothstep(snowline, snowline + 900.0, h), 0.62, slope + (n3 - 0.5) * 0.16);
	float couloir = smoothstep(0.35, 0.8, flow) * smoothstep(snowline - 250.0, snowline + 100.0, h) * (1.0 - smoothstep(0.6, 0.85, slope));
	float snow = clamp(max(above * hold, couloir * 0.9), 0.0, 1.0) * (1.0 - v_mask.b * 0.95);
	vec3 snow_col = vec3(0.92, 0.94, 0.98) * mix(0.82, 1.0, ao) * (0.94 + 0.08 * n3);
	col = mix(col, snow_col, snow);

	// ---- lava: down the gullies just below the crater
	float lava = smoothstep(0.45, 0.85, flow) * smoothstep(0.55, 0.95, v_mask.b);
	lava = max(lava, smoothstep(0.96, 1.0, v_mask.b));
	col = mix(col, vec3(0.04, 0.025, 0.02), lava * 0.8);

	// ---- terrain shadow: march toward the sun across the height field
	float shadow = 1.0;
	if (sun_dir.y > -0.05) {
		vec3 sd = normalize(sun_dir);
		float t = 30.0;
		for (int i = 0; i < 26; i++) {
			vec3 p = wpos + sd * t + nw * 8.0;
			vec2 q = to_uv(p.xz);
			if (q.x < 0.0 || q.y < 0.0 || q.x > 1.0 || q.y > 1.0 || p.y > 4200.0) {
				break;
			}
			float hs = texture(height_tex, q).r;
			shadow = min(shadow, clamp((p.y - hs) / (0.06 * t) + 0.5, 0.0, 1.0));
			if (shadow <= 0.0) {
				break;
			}
			t *= 1.24;
		}
	}
	v_shadow = shadow;
	v_snow = snow;
	v_sun_view = normalize((VIEW_MATRIX * vec4(sun_dir, 0.0)).xyz);

	// ---- haze and valley mist
	vec2 dir = ray.xz / max(dist, 1.0);
	vec2 cam = CAMERA_POSITION_WORLD.xz;
	vec2 safe = vec2(abs(dir.x) < 1e-4 ? 1e-4 : dir.x, abs(dir.y) < 1e-4 ? 1e-4 : dir.y);
	vec2 tx = (sign(safe) * map_half - cam) / safe;
	float inside = clamp(min(tx.x, tx.y), 0.0, dist);
	float haze = 1.0 - exp(-inside * haze_density - (dist - inside) * haze_far_density);
	haze *= mix(1.0, 0.5, smoothstep(400.0, 2800.0, h));
	float valley = (1.0 - smoothstep(350.0, 900.0, h + (n2 - 0.5) * 200.0)) * smoothstep(2500.0, 6000.0, dist);
	haze = clamp(haze + valley * mist, 0.0, 1.0);

	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	ALBEDO = col * (1.0 - haze);
	AO = ao;
	AO_LIGHT_AFFECT = 0.0;
	ROUGHNESS = mix(0.9, 0.5, snow);
	EMISSION = haze_color * haze * haze_energy + vec3(1.0, 0.32, 0.06) * lava * lava_glow * (1.0 - haze * 0.6);
}

void light() {
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	float sh = LIGHT_IS_DIRECTIONAL && dot(LIGHT, v_sun_view) > 0.99 ? v_shadow : 1.0;
	DIFFUSE_LIGHT += ndl * ATTENUATION * LIGHT_COLOR * sh / PI;
	vec3 hv = normalize(LIGHT + VIEW);
	SPECULAR_LIGHT += pow(clamp(dot(NORMAL, hv), 0.0, 1.0), 48.0) * ndl * ATTENUATION * LIGHT_COLOR * sh * v_snow * 0.08;
}
