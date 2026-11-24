class_name HandModels
extends RefCounted
## First-person viewmodels for held items: the item model in a per-item hold pose.


## Hold pose per item: [position, rotation_degrees, scale] relative to the hand anchor.
const HOLD := {
	&"stone_axe": [Vector3(-0.05, 0.11, 0.03), Vector3(-20, -35, 16), 1.0],
	&"club": [Vector3(-0.045, 0.08, 0.03), Vector3(-20, -20, 16), 1.0],
	&"flint_knife": [Vector3(0, -0.02, 0), Vector3(-55, 0, -5), 1.0],
	&"bone_knife": [Vector3(0, -0.02, 0), Vector3(-55, 0, -5), 1.0],
	&"sickle": [Vector3(0, -0.04, 0), Vector3(-35, -20, -8), 1.0],
	&"digging_stick": [Vector3(-0.02, 0.05, 0.12), Vector3(-62, 0, 0), 0.9],
	&"fishing_spear": [Vector3(-0.02, 0.05, 0.14), Vector3(-75, 0, 0), 0.9],
	&"spear": [Vector3(-0.02, 0.05, 0.14), Vector3(-75, 0, 0), 0.9],
	&"torch": [Vector3(0, -0.12, 0), Vector3(-12, 0, -6), 0.9],
	&"stone": [Vector3(0, 0, 0), Vector3(0, 30, 0), 1.0],
	# Held upright out front, string toward the camera, canted a little like an instinctive archer.
	&"bow": [Vector3(-0.43, 0.46, -0.05), Vector3(6, 14, 12), 1.0],
}
const HAND_PATH := "res://assets/models/humans/SM_FP_Hand_R.gltf"
## Items held without the right hand drawn (the bow is held in the left hand; small stones are thrown).
const NO_HAND := [&"bow", &"stone"]
## Per item: [yaw of the hand around the handle (degrees), offset along the handle] in the item's model space.
const HAND_FIX := {}
const FOREARM_TOWARD := Vector3(0.45, -0.55, 1.0)  # in the hand anchor's space: back toward the eye, low right


## Yaw (degrees, about the handle = the item's +Y) that points the hand's forearm (its +Z) most toward the viewer.
static func _forearm_yaw(item_basis: Basis) -> float:
	var target := FOREARM_TOWARD.normalized()
	var best := 0.0
	var best_dot := -INF
	for k in 36:
		var yaw := k * 10.0
		var d := item_basis * Basis(Vector3.UP, deg_to_rad(yaw)) * Vector3(0, 0, 1)
		var dot := d.normalized().dot(target)
		if dot > best_dot:
			best_dot = dot
			best = yaw
	return best


## Where the arrow's nock sits on the bow string, in the bow model's space (see gen_items.py b_bow:
## string at +Z = BOW_BRACE behind the grip; the arrow rests on the left of the stave, just above the grip).
const NOCK := Vector3(-0.022, 0.03, 0.132)


static func build(id: StringName) -> Node3D:
	var root := Node3D.new()
	var path := AssetLib.item_model_path(id)
	if path != "":
		var m := AssetLib.instance(path)
		m.name = "Model"
		var pose: Array = HOLD.get(id, [Vector3.ZERO, Vector3(-30, 0, 0), 1.0])
		m.position = pose[0]
		m.rotation_degrees = pose[1]
		m.scale = Vector3.ONE * float(pose[2])
		root.add_child(m)
		if id not in NO_HAND and ResourceLoader.exists(HAND_PATH):
			# The player's own hand around the grip: a child of the item, so it follows its hold pose and swings.
			var hand := AssetLib.instance(HAND_PATH)
			hand.name = "Hand"
			var fix: Array = HAND_FIX.get(id, [INF, Vector3.ZERO])
			# turn round the handle so the forearm comes from the camera, down and to the right
			hand.rotation_degrees = Vector3(0, float(fix[0]) if fix[0] != INF else _forearm_yaw(m.basis), 0)
			hand.position = fix[1]
			hand.scale = Vector3.ONE / maxf(float(pose[2]), 0.01)
			m.add_child(hand)
			HumanNPC._tune_skin(hand)
		if id == &"torch":
			var flame := Graybox.part(root, Graybox.sphere(0.05, 8), Color(1.0, 0.6, 0.2), Vector3(0, 0.33, -0.08))
			flame.material_override = Graybox.mat(Color(1.0, 0.55, 0.2), 1.0, 3.0)
	else:
		Graybox.part(root, Graybox.box(Vector3(0.1, 0.1, 0.1)), Color.GRAY)
	_no_shadows(root)
	return root


## Puts an arrow on the string of a bow viewmodel built by build(&"bow"); returns it so the caller can pull it
## back along +Z while drawing (position.z = NOCK.z + pull).
static func nock_arrow(bow_root: Node3D) -> Node3D:
	var path := AssetLib.item_model_path(&"arrow")
	var model := bow_root.get_node_or_null("Model") as Node3D
	if path == "" or model == null:
		return null
	var a := AssetLib.instance(path)
	a.rotation_degrees = Vector3(-90, 0, 0)  # arrow model points +Y; on the bow it points forward (-Z)
	a.position = NOCK
	model.add_child(a)
	_no_shadows(a)
	return a


## Bends a bow viewmodel: 0 = rest, 1 = full draw (limbs flexed, string in a V at NOCK + Player.BOW_PULL).
static func set_bow_draw(bow_root: Node3D, w: float) -> void:
	for mi: MeshInstance3D in bow_root.find_children("*", "MeshInstance3D", true, false):
		var idx := mi.find_blend_shape_by_name(&"Drawn")
		if idx >= 0:
			mi.set_blend_shape_value(idx, w)


static func _no_shadows(n: Node) -> void:
	for gi: GeometryInstance3D in n.find_children("*", "GeometryInstance3D", true, false):
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
