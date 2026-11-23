// Meadow grass and wildflowers around the camera (MeadowGrass). Every instance lives on a fixed grid in a window
// of ±radius around the camera: when the camera moves, instances that fall off one edge wrap to the other, so
// each tuft keeps a stable world position while it is in view. Height comes from the terrain height grid with
// the same two-triangle interpolation as ForestWorld.height_at; the same macro noise as the terrain shader picks
// lush or dry colours, the forest mask thins it under trees, water/steep rock/fires/buildings stay bare.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, world_vertex_coords;

uniform sampler2D height_tex : filter_nearest;        // (GRID+1)² terrain heights, R32F
uniform sampler2D grass_mask : hint_default_black, filter_linear;  // baked: 0 bare … 1 full meadow
uniform sampler2D macro_noise : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float half_size = 2100.0;
uniform float cell = 10.0;
uniform int grid = 420;
uniform float map_size = 4200.0;
uniform float radius = 22.0;
uniform float water_level = 0.0;
uniform float density = 1.0;
uniform bool flowers = false;
uniform vec2 wind_dir = vec2(0.8, 0.6);
uniform float wind_strength = 0.35;
uniform vec3 lush : source_color = vec3(0.16, 0.27, 0.07);
uniform vec3 dry : source_color = vec3(0.42, 0.38, 0.15);
uniform vec4 bare[12];  // xz centre, radius (fires, buildings) — w unused

varying vec3 v_col;
varying vec3 v_up;   // ground normal in view space: both blade faces are lit like the ground
varying float v_h;
varying float v_head;

float th(int ix, int iz) {
	return texelFetch(height_tex, ivec2(clamp(ix, 0, grid), clamp(iz, 0, grid)), 0).r;
}

// Height of the terrain triangle under p (as ForestWorld.height_at); its slope goes to `grad`.
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
	// grass_mask: dry land, gentle slope, thinned under forest (baked per terrain vertex by MeadowGrass)
	float want = density * texture(grass_mask, wrapped / map_size + 0.5).r;
	float n1 = texture(macro_noise, wrapped * 0.013).r;
	float dryness = smoothstep(0.5, 0.85, texture(macro_noise, wrapped * 0.004).r + (n1 - 0.5) * 0.3);
	if (flowers) {
		want *= smoothstep(0.55, 0.75, texture(macro_noise, wrapped * 0.03 + vec2(0.31, 0.77)).r) * (1.0 - dryness * 0.7);
	}
	float keep = step(r1, want);
	for (int i = 0; i < 12; i++) {
		if (bare[i].z > 0.0 && distance(wrapped, bare[i].xy) < bare[i].z) {
			keep = 0.0;
		}
	}
	float dist = distance(wrapped, cam.xz);
	float fade = 1.0 - smoothstep(radius * 0.72, radius * 0.97, dist);
	vec3 local = VERTEX - inst;
	float s = keep * fade;
	// LOD: past ~40 % of the radius, two thirds of a tuft's blades shrink away (UV.x = blade id 0…1)
	float lod = smoothstep(radius * 0.35, radius * 0.65, dist);
	s *= step(UV.x, 1.0 - lod * 0.66);
	local *= vec3(mix(0.6, 1.0, s), s, mix(0.6, 1.0, s));
	float hgt = max(local.y, 0.0);
	float gust = sin(TIME * 1.7 + dot(wrapped, vec2(0.21, 0.13))) * 0.5 + 0.6 + 0.25 * sin(TIME * 4.1 + wrapped.x * 0.9);
	local.xz += wind_dir * gust * wind_strength * hgt * hgt * 2.2;
	VERTEX = vec3(wrapped.x, h - 0.03, wrapped.y) + local;
	NORMAL = normalize(vec3(-grad.x, 1.0, -grad.y));
	v_up = normalize((VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_h = UV.y;
	v_head = COLOR.r;
	float r2 = hash(inst.xz + 17.0);
	v_col = mix(lush, dry, dryness * 0.85) * (0.82 + 0.36 * r2);
	if (flowers) {
		v_col = mix(v_col, INSTANCE_CUSTOM.rgb, v_head);
	}
}

void fragment() {
	NORMAL = v_up;  // no dark back faces (cull_disabled would flip the normal)
	float tip = mix(0.42, 1.12, v_h);  // darker, occluded roots; sunlit tips
	ALBEDO = v_col * (v_head > 0.5 ? 1.0 : tip);
	ROUGHNESS = 0.82;
	SPECULAR = 0.25;
	BACKLIGHT = v_col * 0.45 * v_h;  // light through the blades when backlit by the sun
	AO = mix(0.55, 1.0, v_h);
	AO_LIGHT_AFFECT = 0.3;
}
