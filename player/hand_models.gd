class_name HandModels
extends RefCounted
## PLACEHOLDER first-person viewmodels for held items (graybox primitives).


## Hold pose per item: [position, rotation_degrees, scale] relative to the hand anchor.
const HOLD := {
	&"stone_axe": [Vector3(0, -0.12, 0), Vector3(-25, 0, -8), 0.85],
	&"flint_knife": [Vector3(0, -0.02, 0), Vector3(-55, 0, -5), 1.0],
	&"spear": [Vector3(0.0, -0.05, 0.25), Vector3(-75, 0, 0), 0.9],
	&"torch": [Vector3(0, -0.12, 0), Vector3(-12, 0, -6), 0.9],
	&"stone": [Vector3(0, 0, 0), Vector3(0, 30, 0), 1.0],
}


static func build(id: StringName) -> Node3D:
	var root := Node3D.new()
	var path := AssetLib.item_model_path(id)
	if path != "":
		var m := AssetLib.instance(path)
		var pose: Array = HOLD.get(id, [Vector3.ZERO, Vector3(-30, 0, 0), 1.0])
		m.position = pose[0]
		m.rotation_degrees = pose[1]
		m.scale = Vector3.ONE * float(pose[2])
		root.add_child(m)
		if id == &"torch":
			var flame := Graybox.part(root, Graybox.sphere(0.05, 8), Color(1.0, 0.6, 0.2), Vector3(0, 0.33, -0.08))
			flame.material_override = Graybox.mat(Color(1.0, 0.55, 0.2), 1.0, 3.0)
	else:
		Graybox.part(root, Graybox.box(Vector3(0.1, 0.1, 0.1)), Color.GRAY)
	for gi: GeometryInstance3D in root.find_children("*", "GeometryInstance3D", true, false):
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root
