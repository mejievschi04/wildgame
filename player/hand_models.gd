class_name HandModels
extends RefCounted
## PLACEHOLDER first-person viewmodels for held items (graybox primitives).


static func build(id: StringName) -> Node3D:
	var root := Node3D.new()
	var wood := Graybox.tex("Log", Color(1.15, 1.05, 0.95), 6.0)
	var flint := Graybox.tex("Rock", Color(0.42, 0.43, 0.48), 8.0)
	var stone := Graybox.tex("Rock", Color(0.85, 0.83, 0.78), 6.0)
	var binding := Graybox.tex("Leather", Color(0.8, 0.65, 0.5), 10.0)
	match id:
		&"stone_axe":
			Graybox.part_mat(root, Graybox.cylinder(0.02, 0.026, 0.55, 8), wood, Vector3(0, 0.05, 0), Vector3(-15, 0, 0))
			Graybox.part_mat(root, Graybox.sphere(0.06, 9), stone, Vector3(0.05, 0.3, -0.07), Vector3(-15, 0, 20), Vector3(1.7, 0.9, 0.55))
			Graybox.part_mat(root, Graybox.cylinder(0.03, 0.03, 0.07, 8), binding, Vector3(0, 0.29, -0.07), Vector3(-15, 0, 0))
		&"flint_knife":
			Graybox.part_mat(root, Graybox.cylinder(0.018, 0.02, 0.12, 8), binding, Vector3(0, 0, 0), Vector3(-60, 0, 0))
			Graybox.part_mat(root, Graybox.sphere(0.04, 8), flint, Vector3(0, 0.05, -0.12), Vector3(-30, 0, 0), Vector3(0.5, 0.25, 2.2))
		&"spear":
			Graybox.part_mat(root, Graybox.cylinder(0.018, 0.022, 1.6, 8), wood, Vector3(0, 0, -0.3), Vector3(-80, 0, 0))
			Graybox.part_mat(root, Graybox.sphere(0.035, 8), flint, Vector3(0, 0.15, -1.12), Vector3(-80, 0, 0), Vector3(0.6, 2.4, 0.3))
			Graybox.part_mat(root, Graybox.cylinder(0.026, 0.026, 0.08, 8), binding, Vector3(0, 0.13, -1.03), Vector3(-80, 0, 0))
		&"torch":
			Graybox.part_mat(root, Graybox.cylinder(0.022, 0.026, 0.5, 8), wood, Vector3(0, 0.05, 0), Vector3(-10, 0, 0))
			Graybox.part_mat(root, Graybox.cylinder(0.04, 0.035, 0.1, 8), binding, Vector3(0, 0.28, -0.04), Vector3(-10, 0, 0))
			var flame := Graybox.part(root, Graybox.sphere(0.06, 6), Color(1.0, 0.6, 0.2), Vector3(0, 0.36, -0.05))
			flame.material_override = Graybox.mat(Color(1.0, 0.55, 0.2), 1.0, 3.0)
		&"stone":
			var st := AssetLib.instance(AssetLib.ROCKS[&"small"][0])
			st.scale = Vector3.ONE * 0.9
			root.add_child(st)
		_:
			Graybox.part(root, Graybox.box(Vector3(0.1, 0.1, 0.1)), Color.GRAY)
	for mi: GeometryInstance3D in root.find_children("*", "GeometryInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root
