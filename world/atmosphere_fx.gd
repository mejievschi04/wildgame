class_name AtmosphereFX
extends Node3D
## Life in the air around the camera: pollen and dust motes drifting in daylight (most visible against the sun),
## and fireflies blinking low over the ground on dry evenings. Both follow the camera and fade with the clock
## and the weather (rain, storms and fog clear them).

var world: ForestWorld
var _pollen: GPUParticles3D
var _flies: GPUParticles3D


func _ready() -> void:
	_pollen = _make(220, 9.0, Vector3(14, 4, 14), 0.022, Color(1.0, 0.95, 0.82, 0.55), false)
	_flies = _make(70, 5.0, Vector3(16, 1.2, 16), 0.035, Color(2.6, 3.0, 0.9, 1.0), true)


func _make(amount: int, life: float, box: Vector3, size: float, color: Color, blink: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.preprocess = life
	p.local_coords = false
	p.visibility_aabb = AABB(-box * 2.0, box * 4.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = box
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.02
	pm.initial_velocity_max = 0.15
	pm.gravity = Vector3(0, 0.01 if blink else -0.015, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.6 if blink else 0.35
	pm.turbulence_noise_speed_random = 0.4
	pm.turbulence_influence_min = 0.05
	pm.turbulence_influence_max = 0.15
	pm.scale_min = 0.6
	pm.scale_max = 1.4
	var g := Gradient.new()
	if blink:  # two slow pulses of light over a firefly's life
		g.offsets = PackedFloat32Array([0.0, 0.15, 0.3, 0.5, 0.65, 0.8, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 0), Color(1, 1, 1, 0),
			Color(1, 1, 1, 1), Color(1, 1, 1, 0), Color(1, 1, 1, 0)])
	else:
		g.offsets = PackedFloat32Array([0.0, 0.2, 0.8, 1.0])
		g.colors = PackedColorArray([Color(1, 1, 1, 0), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = g
	pm.color_ramp = ramp
	p.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if blink else BaseMaterial3D.BLEND_MODE_MIX
	m.vertex_color_use_as_albedo = true
	m.albedo_color = color
	var dot := GradientTexture2D.new()  # a soft round mote, not a square
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(0.5, 0.0)
	var dg := Gradient.new()
	dg.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	dot.gradient = dg
	dot.width = 32
	dot.height = 32
	m.albedo_texture = dot
	m.disable_receive_shadows = true
	quad.material = m
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	return p


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or world == null or world.day_night == null:
		return
	global_position = cam.global_position
	var dn := world.day_night
	var w := world.weather
	var wet: float = w.rain if w else 0.0
	var fog: float = w.fog_extra if w else 0.0
	var clear := clampf(1.0 - wet * 3.0 - fog * 60.0, 0.0, 1.0)
	var day := smoothstep(-0.05, 0.25, dn.sun_elevation())
	var h := dn.time_hours
	var dusk := clampf(1.0 - absf(h - 21.5) / 2.0, 0.0, 1.0)
	_pollen.amount_ratio = day * clear
	_pollen.emitting = _pollen.amount_ratio > 0.02
	_flies.amount_ratio = dusk * clear * (1.0 - day)
	_flies.emitting = _flies.amount_ratio > 0.02
	_flies.position = Vector3(0, -1.0, 0)  # low over the grass
