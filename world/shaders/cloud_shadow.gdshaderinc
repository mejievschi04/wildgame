// Shadows of the sky's clouds (sky.gdshader) on the land: the point is projected along the sun onto the cloud
// layer and the same cloud field is sampled there. Returns 0 (sunlit) … 1 (under a thick cloud). Globals are set
// by DayNight; cloud_cover is 0 at night, so nothing darkens then.
global uniform sampler2D cloud_noise : filter_linear_mipmap, repeat_enable;
global uniform vec2 cloud_offset;
global uniform float cloud_cover;
global uniform vec3 cloud_sun_dir;

float cloud_shadow(vec3 p) {
	if (cloud_cover <= 0.001 || cloud_sun_dir.y < 0.05) {
		return 0.0;
	}
	const float LAYER = 1500.0;
	vec2 hit = p.xz + cloud_sun_dir.xz / cloud_sun_dir.y * (LAYER - p.y);
	vec2 uv = hit / LAYER * 0.055 + cloud_offset;
	float v = texture(cloud_noise, uv).r * 0.55;
	v += texture(cloud_noise, uv * 2.13 + vec2(0.17, 0.41)).r * 0.28;
	v += texture(cloud_noise, uv * 4.7 + vec2(0.63, 0.29)).r * 0.17;
	float cover = clamp(cloud_cover, 0.0, 1.0);
	return smoothstep(0.6 - cover * 0.42, 0.8 - cover * 0.3, v);
}
