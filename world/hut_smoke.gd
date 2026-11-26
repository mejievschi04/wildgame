extends CPUParticles3D
## Hearth smoke rising out of a lived-in hut's smoke hole: a thin column that thickens and leans downwind
## (the hut models from tools/blender/gen_buildings.py record where their smoke hole is).

var _t := 0.0


func _init() -> void:
	amount = 46
	lifetime = 14.0
	preprocess = 14.0
	emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	emission_sphere_radius = 0.12
	direction = Vector3.UP
	spread = 6.0
	initial_velocity_min = 0.45
	initial_velocity_max = 0.7
	damping_min = 0.04
	damping_max = 0.08
	gravity = Vector3(0.15, 0.28, 0.05)
	angular_velocity_min = -10.0
	angular_velocity_max = 10.0
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.12))
	grow.add_point(Vector2(0.35, 0.45))
	grow.add_point(Vector2(1.0, 1.0))
	scale_amount_curve = grow
	scale_amount_min = 2.6
	scale_amount_max = 3.8
	var fade := Gradient.new()
	fade.set_color(0, Color(0.27, 0.26, 0.25, 0.0))
	fade.add_point(0.05, Color(0.32, 0.31, 0.3, 0.5))
	fade.add_point(0.55, Color(0.47, 0.47, 0.47, 0.26))
	fade.set_color(fade.get_point_count() - 1, Color(0.58, 0.58, 0.58, 0.0))
	color_ramp = fade
	var quad := QuadMesh.new()
	quad.size = Vector2(1.6, 1.6)
	var m := (TreeNode._puff_quad(1.0).material as StandardMaterial3D).duplicate() as StandardMaterial3D
	m.billboard_keep_scale = true
	quad.material = m
	mesh = quad
	visibility_range_end = 1200.0
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _process(delta: float) -> void:
	_t -= delta
	if _t > 0.0:
		return
	_t = 1.0
	var w := get_tree().get_first_node_in_group("weather") as Weather
	var wind := w.wind_dir * (0.25 + w.wind * 0.6) if w else Vector2(0.2, 0.1)
	gravity = Vector3(wind.x, 0.28, wind.y)
