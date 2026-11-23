class_name Weather
extends Node3D
## Basic weather (GDD Phase 2): clear / cloudy / fog / rain / storm / cold snap.
## Deterministic Markov chain (seeded), smooth parameter blending, visuals (clouds, rain particles that
## stop under roofs, wet ground, wind on foliage) and gameplay hooks (temperature, wetness, fires,
## drying, storm damage). All timing is in simulated seconds so sleeping advances weather too.

signal state_changed(state: StringName)

const STATES := {
	&"clear": {"cloud": 0.1, "rain": 0.0, "wind": 0.2, "temp": 1.5, "fog": 0.0},
	&"cloudy": {"cloud": 0.65, "rain": 0.0, "wind": 0.35, "temp": -1.0, "fog": 0.001},
	&"fog": {"cloud": 0.5, "rain": 0.0, "wind": 0.05, "temp": -1.5, "fog": 0.018},
	&"rain": {"cloud": 0.9, "rain": 0.6, "wind": 0.5, "temp": -3.0, "fog": 0.004},
	&"storm": {"cloud": 1.0, "rain": 1.0, "wind": 1.0, "temp": -5.0, "fog": 0.006},
	&"cold_snap": {"cloud": 0.2, "rain": 0.0, "wind": 0.6, "temp": -7.0, "fog": 0.0},
}
## Transition weights from each state.
const NEXT := {
	&"clear": {&"clear": 3, &"cloudy": 3, &"fog": 1, &"cold_snap": 1},
	&"cloudy": {&"clear": 2, &"cloudy": 1, &"rain": 3, &"fog": 1},
	&"fog": {&"clear": 2, &"cloudy": 2},
	&"rain": {&"cloudy": 3, &"rain": 1, &"storm": 1, &"clear": 1},
	&"storm": {&"rain": 2, &"cloudy": 1},
	&"cold_snap": {&"clear": 2, &"cloudy": 1},
}
const BLEND_SECONDS := 90.0
const STORM_DAMAGE_PER_HOUR := 3.0

var world: ForestWorld
var state: StringName = &"clear"
var state_left := 0.0  # simulated seconds until next transition
## Current blended parameters.
var cloud := 0.1
var rain := 0.0
var wind := 0.2
var temp_offset := 1.5
var fog_extra := 0.0
var wind_dir := Vector2(0.8, 0.6)

var _rng := RandomNumberGenerator.new()
var _rain_fx: GPUParticles3D
var _rain_collider: GPUParticlesCollisionHeightField3D
var _rain_audio: AudioStreamPlayer
var _damage_accum := 0.0
var _clouds: NoiseTexture2D


func _ready() -> void:
	add_to_group("weather")
	add_to_group("time_sim")
	_rng.seed = ForestWorld.SEED + 404
	if state_left <= 0.0:
		state_left = _duration_for(state)
	_build_rain()
	_build_clouds()
	_apply_visuals()


func _duration_for(s: StringName) -> float:
	var hours := _rng.randf_range(2.0, 6.0)
	if s == &"storm":
		hours = _rng.randf_range(1.0, 2.5)
	return hours * world.day_night.day_length_sec / 24.0 if world else hours * 60.0


func _pick_next() -> StringName:
	var opts: Dictionary = NEXT[state]
	var total := 0
	for w: int in opts.values():
		total += w
	var r := _rng.randi_range(1, total)
	for s: StringName in opts.keys():
		r -= int(opts[s])
		if r <= 0:
			return s
	return &"clear"


func set_state(s: StringName, instant: bool = false) -> void:
	state = s
	state_left = _duration_for(s)
	if instant:
		var t: Dictionary = STATES[s]
		cloud = t.cloud
		rain = t.rain
		wind = t.wind
		temp_offset = t.temp
		fog_extra = t.fog
	state_changed.emit(s)


func _process(delta: float) -> void:
	if world and world.menu_mode:
		return
	simulate(delta)
	_apply_visuals()


## Advances weather by simulated seconds (also used for sleep time-skips).
func simulate(seconds: float) -> void:
	var remaining := seconds
	while remaining > 0.0:
		var step := minf(remaining, 10.0)
		remaining -= step
		state_left -= step
		if state_left <= 0.0:
			set_state(_pick_next())
		var t: Dictionary = STATES[state]
		var k := clampf(step / BLEND_SECONDS, 0.0, 1.0)
		cloud = lerpf(cloud, t.cloud, k)
		rain = lerpf(rain, t.rain, k)
		wind = lerpf(wind, t.wind, k)
		temp_offset = lerpf(temp_offset, t.temp, k)
		fog_extra = lerpf(fog_extra, t.fog, k)
		wind_dir = wind_dir.rotated(_rng.randf_range(-0.02, 0.02) * step / 10.0).normalized()
		_storm_damage(step)


func _storm_damage(step: float) -> void:
	if wind < 0.8 or world == null:
		return
	_damage_accum += step
	var hour := world.day_night.day_length_sec / 24.0
	if _damage_accum < hour * 0.25:
		return
	var dmg := STORM_DAMAGE_PER_HOUR * (_damage_accum / hour) * wind
	_damage_accum = 0.0
	for p: BuildingPiece in get_tree().get_nodes_in_group("building"):
		if p.built and not p.is_queued_for_deletion():
			p.damage(dmg)


# ---------------------------------------------------------------- gameplay queries

## True when nothing built is overhead (roof, lean-to, …) at this position.
func is_exposed(pos: Vector3) -> bool:
	if world and world.get_shelter_at(pos + Vector3.UP * 0.3) > 0.0:
		return false
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return true
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 0.4, pos + Vector3.UP * 12.0, 1)
	var hit := space.intersect_ray(q)
	return hit.is_empty() or not hit.collider is BuildingPiece


## Rain hitting this position (0..1).
func rain_at(pos: Vector3) -> float:
	return rain if rain > 0.02 and is_exposed(pos) else 0.0


## Extra cooling from wind when exposed (°C, negative).
func wind_chill_at(pos: Vector3) -> float:
	return -3.5 * wind if is_exposed(pos) else 0.0


# ---------------------------------------------------------------- visuals

func _build_rain() -> void:
	_rain_fx = GPUParticles3D.new()
	_rain_fx.amount = 5000
	_rain_fx.lifetime = 1.1
	_rain_fx.visibility_aabb = AABB(Vector3(-20, -20, -20), Vector3(40, 40, 40))
	_rain_fx.collision_base_size = 0.02
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(18, 0.5, 18)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 3.0
	pm.initial_velocity_min = 13.0
	pm.initial_velocity_max = 16.0
	pm.gravity = Vector3(0, -2, 0)
	pm.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	_rain_fx.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.016, 0.6)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.billboard_keep_scale = true
	m.albedo_color = Color(0.78, 0.82, 0.9, 0.48)
	quad.material = m
	_rain_fx.draw_pass_1 = quad
	_rain_fx.emitting = false
	add_child(_rain_fx)
	# Heightfield collision captured from above: rain stops on roofs, terrain and canopies of buildings.
	_rain_collider = GPUParticlesCollisionHeightField3D.new()
	_rain_collider.size = Vector3(40, 40, 40)
	_rain_collider.resolution = GPUParticlesCollisionHeightField3D.RESOLUTION_512
	_rain_collider.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_WHEN_MOVED
	_rain_collider.follow_camera_enabled = true
	add_child(_rain_collider)
	_rain_audio = AudioStreamPlayer.new()
	_rain_audio.stream = Sfx.stream(&"rain_loop")
	_rain_audio.bus = &"Ambience"
	_rain_audio.volume_db = -80.0
	add_child(_rain_audio)


func _build_clouds() -> void:
	_clouds = NoiseTexture2D.new()
	_clouds.width = 1024
	_clouds.height = 512
	_clouds.seamless = true
	var n := FastNoiseLite.new()
	n.seed = ForestWorld.SEED + 9
	n.frequency = 0.006
	n.fractal_octaves = 5
	_clouds.noise = n
	var cr := Gradient.new()
	cr.set_color(0, Color(0, 0, 0))
	cr.set_color(1, Color(1, 1, 1))
	cr.add_point(0.45, Color(0, 0, 0))
	_clouds.color_ramp = cr


func _apply_visuals() -> void:
	RenderingServer.global_shader_parameter_set(&"wind_strength", wind)
	RenderingServer.global_shader_parameter_set(&"wind_direction", wind_dir)
	if world == null:
		return
	var dn := world.day_night
	if dn:
		dn.cloud_cover = clampf(0.15 + cloud * 0.9, 0.0, 1.0)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam:
		_rain_fx.global_position = cam.global_position + Vector3.UP * 9.0
	var r := rain if not world.menu_mode else 0.0
	_rain_fx.emitting = r > 0.05
	_rain_fx.amount_ratio = clampf(r, 0.05, 1.0)
	if _rain_audio.stream:
		if r > 0.05 and not _rain_audio.playing:
			_rain_audio.play()
		_rain_audio.volume_db = linear_to_db(maxf(r * 0.34, 0.0001))
	world.set_ground_wetness(clampf(rain * 1.2, 0.0, 1.0))


# ---------------------------------------------------------------- persistence

func save_state() -> Dictionary:
	return {"state": String(state), "left": state_left, "cloud": cloud, "rain": rain, "wind": wind,
		"temp": temp_offset, "fog": fog_extra, "dir": [wind_dir.x, wind_dir.y], "rng": _rng.state}


func load_state(d: Dictionary) -> void:
	state = StringName(str(d.get("state", "clear")))
	if not STATES.has(state):
		state = &"clear"
	state_left = float(d.get("left", 600.0))
	cloud = float(d.get("cloud", 0.1))
	rain = float(d.get("rain", 0.0))
	wind = float(d.get("wind", 0.2))
	temp_offset = float(d.get("temp", 0.0))
	fog_extra = float(d.get("fog", 0.0))
	var dir: Array = d.get("dir", [0.8, 0.6])
	wind_dir = Vector2(float(dir[0]), float(dir[1])).normalized()
	if d.has("rng"):
		_rng.state = int(d.rng)
