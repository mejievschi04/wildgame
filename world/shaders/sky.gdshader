// WILDBOUND sky: colour gradient from DayNight, the sun's disc and halo, and a layer of drifting fractal clouds
// (cover from the weather) lit from the sun's side — bright silver edges toward it, grey-blue undersides,
// warm at sunrise/sunset. Distant clouds flatten and fade into the horizon haze.
shader_type sky;
render_mode use_debanding;

uniform vec3 top_color : source_color = vec3(0.2, 0.42, 0.78);
uniform vec3 horizon_color : source_color = vec3(0.64, 0.75, 0.87);
uniform vec3 ground_horizon : source_color = vec3(0.5, 0.55, 0.6);
uniform vec3 ground_bottom : source_color = vec3(0.2, 0.22, 0.17);
uniform float energy = 1.0;
uniform float cloud_cover = 0.3;
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.98, 0.94);
uniform vec3 cloud_shade : source_color = vec3(0.52, 0.58, 0.68);
uniform vec2 cloud_offset = vec2(0.0);
uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;
uniform float day = 1.0;  // 0 night … 1 day (clouds go dark at night)

float fbm(vec2 p) {
	float v = texture(cloud_noise, p).r * 0.55;
	v += texture(cloud_noise, p * 2.13 + vec2(0.17, 0.41)).r * 0.28;
	v += texture(cloud_noise, p * 4.7 + vec2(0.63, 0.29)).r * 0.17;
	return v;
}

void sky() {
	vec3 d = EYEDIR;
	float y = d.y;
	vec3 col;
	if (y >= 0.0) {
		float t = pow(clamp(y, 0.0, 1.0), 0.45);
		col = mix(horizon_color, top_color, t);
	} else {
		col = mix(ground_horizon, ground_bottom, clamp(-y * 6.0, 0.0, 1.0));
	}
	// sun: soft wide glow, a tighter halo and the disc
	float sd = dot(d, LIGHT0_DIRECTION);
	vec3 sun = LIGHT0_COLOR * LIGHT0_ENERGY;
	// The sun's disc and halo only where the eye sees the sky: in the radiance/ambient cubemap they would be
	// blurred over every rough surface as a grey sheen (the DirectionalLight already lights and highlights them).
	if (LIGHT0_ENABLED && !AT_CUBEMAP_PASS) {
		col += sun * (pow(max(sd, 0.0), 6.0) * 0.12 + pow(max(sd, 0.0), 64.0) * 0.35) * day;
		float disc = smoothstep(cos(radians(1.4)), cos(radians(1.0)), sd);
		col += sun * disc * 6.0 * step(0.0, y);
	}
	// clouds on a plane overhead
	if (y > 0.0) {
		vec2 uv = d.xz / (y + 0.08) * 0.055 + cloud_offset;
		float n = fbm(uv);
		float cover = clamp(cloud_cover, 0.0, 1.0);
		float density = smoothstep(0.62 - cover * 0.42, 0.78 - cover * 0.3, n);
		density *= smoothstep(0.0, 0.18, y);  // thin out toward the horizon
		vec2 to_sun = normalize(LIGHT0_DIRECTION.xz + vec2(1e-4)) * 0.02;
		float n2 = fbm(uv + to_sun);
		float lit = clamp(0.55 + (n - n2) * 6.0, 0.0, 1.0);   // thinner toward the sun = brighter edge
		vec3 c = mix(cloud_shade, cloud_lit, lit);
		c = mix(c, c * LIGHT0_COLOR, 0.5);                    // golden at low sun
		c += sun * pow(max(sd, 0.0), 12.0) * 0.4 * (1.0 - density);  // silver lining near the sun
		c *= mix(0.08, 1.0, day);
		c = mix(c, horizon_color, smoothstep(0.25, 0.0, y) * 0.6);
		col = mix(col, c, density * 0.95);
	}
	COLOR = col * energy;
}
