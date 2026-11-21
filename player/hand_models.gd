class_name HandModels
extends RefCounted
## PLACEHOLDER first-person viewmodels for held items (graybox primitives).


static func build(id: StringName) -> Node3D:
	var root := Node3D.new()
	var wood := Color(0.45, 0.33, 0.21)
	var stone := Color(0.42, 0.42, 0.4)
	match id:
		&"stone_axe":
			Graybox.part(root, Graybox.cylinder(0.022, 0.026, 0.55, 6), wood, Vector3(0, 0.05, 0), Vector3(-15, 0, 0))
			Graybox.part(root, Graybox.box(Vector3(0.16, 0.09, 0.05)), stone, Vector3(0.06, 0.3, -0.07), Vector3(-15, 0, 0))
		&"flint_knife":
			Graybox.part(root, Graybox.cylinder(0.018, 0.02, 0.12, 6), Color(0.55, 0.45, 0.3), Vector3(0, 0, 0), Vector3(-60, 0, 0))
			Graybox.part(root, Graybox.box(Vector3(0.04, 0.015, 0.16)), Color(0.25, 0.27, 0.3), Vector3(0, 0.05, -0.12), Vector3(-30, 0, 0))
		&"spear":
			Graybox.part(root, Graybox.cylinder(0.018, 0.022, 1.6, 6), wood, Vector3(0, 0, -0.3), Vector3(-80, 0, 0))
			Graybox.part(root, Graybox.cylinder(0.0, 0.03, 0.14, 5), Color(0.25, 0.27, 0.3), Vector3(0, 0.14, -1.1), Vector3(-80, 0, 0))
		&"torch":
			Graybox.part(root, Graybox.cylinder(0.022, 0.026, 0.5, 6), wood, Vector3(0, 0.05, 0), Vector3(-10, 0, 0))
			var flame := Graybox.part(root, Graybox.sphere(0.06, 6), Color(1.0, 0.6, 0.2), Vector3(0, 0.32, -0.04))
			flame.material_override = Graybox.mat(Color(1.0, 0.55, 0.2), 1.0, 3.0)
		&"stone":
			Graybox.part(root, Graybox.sphere(0.06, 6), stone, Vector3.ZERO, Vector3.ZERO, Vector3(1.2, 0.9, 1.0))
		_:
			Graybox.part(root, Graybox.box(Vector3(0.1, 0.1, 0.1)), Color.GRAY)
	for mi in root.get_children():
		(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root
