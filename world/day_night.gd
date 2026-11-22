class_name DayNight
extends Node3D
## Time of day, sun/moon, sky and ambient temperature.
## 1 game day = day_length_sec simulated seconds (default 24 real minutes).

signal new_day(day: int)

const SUNRISE := 6.0
const SUNSET := 20.0
## Lunar cycle in game days (shortened so phases are noticeable) and where the game starts in it (waxing gibbous).
const LUNAR_DAYS := 8.0
const LUNAR_START := 0.35
const MOON_MAX_ELEV := 55.0
## Sky objects ride on a dome around the camera (inside its far plane).
const MOON_DIST := 600.0
const MOON_SIZE_DEG := 3.2
const STAR_DIST := 650.0
const STAR_COUNT := 1800

var time_hours := 12.0
var day := 1
var day_length_sec := 1440.0
var frozen := false

var sun: DirectionalLight3D
var moon: DirectionalLight3D
var environment: Environment
var sky_material: ProceduralSkyMaterial
var _moon_disc: MeshInstance3D
var _moon_mat: ShaderMaterial
var _stars: MeshInstance3D
var _stars_mat: ShaderMaterial


func _ready() -> void:
	sky_material = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_material
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_exposure = 0.9
	environment.ssao_enabled = true
	environment.ssao_radius = 0.85
	environment.ssao_intensity = 1.25
	environment.ssao_light_affect = 0.12  # keep contact shadows soft rather than ink-like
	environment.ssao_detail = 0.38
	# Bounced light: screen-space indirect (medium+) and SDFGI (high) — warm light off the ground onto bodies.
	environment.ssil_enabled = true
	environment.ssil_radius = 4.0
	environment.ssil_intensity = 0.8
	environment.sdfgi_use_occlusion = true
	environment.sdfgi_cascades = 4
	environment.sdfgi_min_cell_size = 0.2
	environment.sdfgi_energy = 0.9
	# Film-like grade: a touch more contrast, slightly muted colours.
	environment.adjustment_enabled = true
	environment.adjustment_contrast = 1.035
	environment.adjustment_saturation = 0.92
	environment.volumetric_fog_enabled = true
	environment.volumetric_fog_density = 0.006
	environment.volumetric_fog_length = 90.0
	environment.volumetric_fog_anisotropy = 0.6
	environment.volumetric_fog_sky_affect = 0.0
	environment.glow_enabled = true
	environment.glow_intensity = 0.45
	environment.glow_bloom = 0.03
	environment.glow_hdr_threshold = 1.1  # only real highlights (fire, sun on water) bloom
	environment.fog_enabled = true
	environment.fog_density = 0.006
	environment.fog_sky_affect = 0.35
	environment.fog_aerial_perspective = 0.55  # distant hills dissolve into the sky colour
	environment.fog_height = ForestWorld.WATER_LEVEL + 2.0
	environment.fog_height_density = 0.0
	var we := WorldEnvironment.new()
	we.environment = environment
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.shadow_blur = 1.2
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 0.6
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.light_color = Color(0.55, 0.65, 0.9)
	moon.shadow_enabled = false
	moon.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	add_child(moon)
	_build_night_sky()
	_apply_settings()
	Settings.changed.connect(func(_s: String, _k: String) -> void: _apply_settings())
	update_visuals()


func _apply_settings() -> void:
	day_length_sec = maxf(float(Settings.get_value("gameplay", "day_length_min")), 4.0) * 60.0
	sun.shadow_enabled = bool(Settings.get_value("video", "shadows"))
	var q := Settings.quality()
	sun.directional_shadow_max_distance = q.shadow_dist
	RenderingServer.directional_shadow_atlas_set_size(int(q.shadow_atlas), true)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if int(q.splits) == 2 \
		else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	environment.volumetric_fog_enabled = q.volfog
	environment.ssao_enabled = q.ssao
	environment.ssil_enabled = bool(q.get("ssil", false))
	environment.sdfgi_enabled = bool(q.get("sdfgi", false))


func _process(delta: float) -> void:
	if not frozen:
		advance(delta)
	update_visuals()


func advance(sim_seconds: float) -> void:
	time_hours += sim_seconds * 24.0 / day_length_sec
	while time_hours >= 24.0:
		time_hours -= 24.0
		day += 1
		new_day.emit(day)


## Simulated seconds until the given clock hour (always in the future, < 24 h).
func seconds_until(hour: float) -> float:
	var dh := fposmod(hour - time_hours, 24.0)
	return dh * day_length_sec / 24.0


func is_night() -> bool:
	return time_hours < SUNRISE - 0.5 or time_hours > SUNSET + 0.5


## Ambient air temperature (°C): ~16 at 15:00, ~-2 at 03:00.
func ambient_temperature() -> float:
	return 7.0 + 9.0 * cos((time_hours - 15.0) / 24.0 * TAU)


## Position in the lunar cycle: 0 new, 0.5 full.
func moon_phase() -> float:
	return fposmod(LUNAR_START + ((day - 1) + time_hours / 24.0) / LUNAR_DAYS, 1.0)


## 0 at new moon, 1 at full moon.
func moon_fullness() -> float:
	return 0.5 - 0.5 * cos(moon_phase() * TAU)


## Fraction of the moon's arc: rises an hour before sunset, sets an hour after sunrise.
func _moon_t() -> float:
	var arc := 24.0 - (SUNSET - SUNRISE) + 2.0
	return fposmod(time_hours - (SUNSET - 1.0), 24.0) / arc


## -1..1, >0 while the moon is above the horizon.
func moon_elevation() -> float:
	var t := _moon_t()
	return sin(t * PI) if t <= 1.0 else -0.5


func moon_azimuth() -> float:
	return lerpf(100.0, -100.0, clampf(_moon_t(), 0.0, 1.0))


static func _sky_euler(elev: float, azimuth_deg: float) -> Vector3:
	return Vector3(deg_to_rad(-maxf(elev, -0.2) * MOON_MAX_ELEV), deg_to_rad(azimuth_deg), 0.0)


## Unit vector from the viewer towards the moon.
func moon_direction() -> Vector3:
	return Basis.from_euler(_sky_euler(moon_elevation(), moon_azimuth())) * Vector3(0, 0, 1)


## -1..1, >0 while the sun is above the horizon.
func sun_elevation() -> float:
	var t := (time_hours - SUNRISE) / (SUNSET - SUNRISE)
	if t >= 0.0 and t <= 1.0:
		return sin(t * PI)
	# Night: below horizon, deepest at midnight-ish.
	var night_len := 24.0 - (SUNSET - SUNRISE)
	var tn := fposmod(time_hours - SUNSET, 24.0) / night_len
	return -sin(tn * PI)


func update_visuals() -> void:
	var w: Weather = get_parent().get("weather") if get_parent() else null
	var cloud := w.cloud if w else 0.0
	var fog_extra := w.fog_extra if w else 0.0
	var elev := sun_elevation()
	var t := clampf((time_hours - SUNRISE) / (SUNSET - SUNRISE), 0.0, 1.0)
	var elev_deg := maxf(elev, 0.02) * 62.0
	sun.rotation = Vector3(deg_to_rad(-elev_deg), deg_to_rad(lerpf(100.0, -100.0, t)), 0.0)
	var day_k := smoothstep(-0.08, 0.3, elev)  # 0 night … 1 day
	var dusk_k := 1.0 - absf(clampf(elev * 3.0, -1.0, 1.0))  # strongest near the horizon
	sun.visible = elev > -0.05
	# Strong warm key light vs. a dimmer blue sky fill: the contrast that reads as "real daylight".
	# High sun is a bit gentler than low golden light (keeps midday from washing out).
	sun.light_energy = lerpf(2.4, 1.9, clampf(elev, 0.0, 1.0)) * day_k * (1.0 - 0.75 * cloud)
	sun.light_color = Color(1.0, 0.91, 0.78).lerp(Color(1.0, 0.52, 0.26), dusk_k * 0.85)
	# Moon: crosses the sky through the night, light and brightness follow its phase.
	var m_elev := moon_elevation()
	var m_up := smoothstep(-0.02, 0.1, m_elev)
	var full := moon_fullness()
	moon.rotation = _sky_euler(m_elev, moon_azimuth())
	moon.visible = day_k < 0.6 and m_elev > 0.0
	moon.light_energy = (0.05 + 0.17 * full) * (1.0 - day_k) * m_up * (1.0 - 0.7 * cloud)
	_update_night_sky(day_k, cloud, m_elev, m_up)

	var night_top := Color(0.02, 0.03, 0.06)
	var night_hor := Color(0.05, 0.06, 0.09)
	var day_top := Color(0.36, 0.52, 0.70)
	var day_hor := Color(0.72, 0.77, 0.78)
	var dusk_hor := Color(0.86, 0.52, 0.32)
	day_top = day_top.lerp(Color(0.42, 0.45, 0.48), cloud * 0.8)
	day_hor = day_hor.lerp(Color(0.55, 0.57, 0.58), cloud * 0.8)
	sky_material.sky_top_color = night_top.lerp(day_top, day_k)
	var hor := night_hor.lerp(day_hor, day_k).lerp(dusk_hor, dusk_k * 0.75 * clampf(day_k * 2.0, 0.0, 1.0))
	sky_material.sky_horizon_color = hor
	sky_material.ground_horizon_color = hor.darkened(0.2)
	sky_material.ground_bottom_color = Color(0.08, 0.09, 0.07).lerp(Color(0.2, 0.22, 0.17), day_k)
	sky_material.sky_energy_multiplier = lerpf(0.25, 1.0, day_k)
	# Overcast days lose the sun but gain sky light.
	environment.ambient_light_energy = lerpf(0.35, 0.62, day_k) * (1.0 + 0.5 * cloud)
	environment.fog_light_color = hor.darkened(0.15)
	environment.fog_density = lerpf(0.010, 0.0022, day_k) + fog_extra + cloud * 0.0015
	environment.volumetric_fog_albedo = hor.lightened(0.2)
	environment.volumetric_fog_density = lerpf(0.012, 0.0028, day_k) + 0.006 * dusk_k * day_k  # shafts at low sun
	# Valley mist: thick in the early morning and at dusk, burnt off by midday.
	var morning := clampf(1.0 - absf(time_hours - 6.5) / 3.0, 0.0, 1.0)
	var evening := clampf(1.0 - absf(time_hours - 20.0) / 2.5, 0.0, 1.0)
	environment.fog_height_density = 0.06 * maxf(morning, evening * 0.6) + fog_extra * 3.0


# ---------------------------------------------------------------- night sky

func _build_night_sky() -> void:
	_moon_mat = ShaderMaterial.new()
	_moon_mat.shader = preload("res://world/shaders/moon.gdshader")
	var quad := QuadMesh.new()
	var size := 2.0 * MOON_DIST * tan(deg_to_rad(MOON_SIZE_DEG * 0.5))
	quad.size = Vector2(size, size)
	_moon_disc = MeshInstance3D.new()
	_moon_disc.name = "MoonDisc"
	_moon_disc.mesh = quad
	_moon_disc.material_override = _moon_mat
	_moon_disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_moon_disc.extra_cull_margin = 16384.0
	add_child(_moon_disc)
	# Stars: points on the upper dome, a few bright ones, most faint; slightly blue or warm.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7741
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	for i in STAR_COUNT:
		var d := Vector3(rng.randfn(), absf(rng.randfn()) + 0.05, rng.randfn()).normalized()
		verts.append(d * STAR_DIST)
		var warm := rng.randf()
		cols.append(Color(0.8 + 0.2 * warm, 0.85 + 0.1 * warm, 1.0 - 0.25 * warm, pow(rng.randf(), 3.0)))
		uvs.append(Vector2(rng.randf(), 0))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	mesh.custom_aabb = AABB(Vector3.ONE * -STAR_DIST, Vector3.ONE * STAR_DIST * 2.0)
	_stars_mat = ShaderMaterial.new()
	_stars_mat.shader = preload("res://world/shaders/stars.gdshader")
	_stars = MeshInstance3D.new()
	_stars.name = "Stars"
	_stars.mesh = mesh
	_stars.material_override = _stars_mat
	_stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_stars)


func _update_night_sky(day_k: float, cloud: float, m_elev: float, m_up: float) -> void:
	if _moon_disc == null:
		return
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var eye := cam.global_position if cam else Vector3.ZERO
	var dir := moon_direction()
	_moon_disc.global_position = eye + dir * MOON_DIST
	_moon_disc.visible = m_elev > -0.05
	_moon_mat.set_shader_parameter("phase", moon_phase())
	# A pale day moon when it lingers after sunrise; clouds veil it.
	_moon_mat.set_shader_parameter("visibility", m_up * lerpf(0.2, 1.0, 1.0 - day_k) * (1.0 - 0.8 * cloud))
	_stars.global_position = eye
	# Stars fade in after dusk, vanish under cloud, and wash out around a bright full moon.
	var night := (1.0 - smoothstep(0.0, 0.35, day_k)) * (1.0 - cloud) * (1.0 - 0.35 * moon_fullness() * m_up)
	_stars.visible = night > 0.01
	_stars_mat.set_shader_parameter("night", night)
