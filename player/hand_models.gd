class_name HandModels
extends RefCounted
## First-person viewmodels for held items: the item model in a per-item hold pose.


## Hold pose per item: [position, rotation_degrees, scale] relative to the hand anchor.
const HOLD := {
	# Low on the right and tipped forward, the head leaning in toward the crosshair (as in Far Cry Primal):
	# the blade/club head reads in silhouette and the forearm comes from the lower right corner.
	&"stone_axe": [Vector3(-0.02, 0.12, 0.26), Vector3(-30, -50, 24), 1.0],
	&"club": [Vector3(-0.02, 0.1, 0.26), Vector3(-30, -45, 24), 1.0],
	&"flint_knife": [Vector3(0, -0.02, 0), Vector3(-55, 0, -5), 1.0],
	&"bone_knife": [Vector3(0, -0.02, 0), Vector3(-55, 0, -5), 1.0],
	&"sickle": [Vector3(0, -0.04, 0), Vector3(-35, -20, -8), 1.0],
	&"digging_stick": [Vector3(-0.02, 0.05, 0.12), Vector3(-62, 0, 0), 0.9],
	&"fishing_spear": [Vector3(-0.02, 0.05, 0.14), Vector3(-75, 0, 0), 0.9],
	# Carried diagonally across the view, point up and out to the right, the hand low in the corner.
	&"spear": [Vector3(-0.1, 0.06, 0.1), Vector3(-40, -70, -10), 0.9],
	&"torch": [Vector3(0, -0.12, 0), Vector3(-12, 0, -6), 0.9],
	&"stone": [Vector3(0, 0, 0), Vector3(0, 30, 0), 1.0],
	# Held out front on the left, string toward the camera, canted like an instinctive archer (the stave is thick:
	# kept clear of the line of sight).
	&"bow": [Vector3(-0.62, 0.42, -0.05), Vector3(6, 14, 24), 1.0],
}
const HAND_PATH := "res://assets/models/humans/SM_FP_Hand_R.gltf"
const HAND_L_PATH := "res://assets/models/humans/SM_FP_Hand_L.gltf"
## Items held without the right hand drawn (the bow is held in the left hand; small stones are thrown).
const NO_HAND := [&"bow", &"stone"]
## Held in the left hand (its own hand model, its forearm coming from the lower left).
const LEFT_HAND := [&"bow"]
## Aiming pose (right mouse button) per item, blended in by the player: [position, rotation_degrees] of the model.
## The spear goes back over the shoulder, point forward, ready to throw.
const AIM := {
	&"spear": [Vector3(0.0, 0.62, 0.5), Vector3(-95, 8, 0)],
}
## Per item: [yaw of the hand around the handle (degrees), offset along the handle] in the item's model space.
const HAND_FIX := {}
const FOREARM_TOWARD := Vector3(0.45, -0.55, 1.0)  # in the hand anchor's space: back toward the eye, low right
const FOREARM_TOWARD_L := Vector3(-0.35, -0.6, 1.0)  # the left hand's forearm: back toward the eye, low left


## Yaw (degrees, about the handle = the item's +Y) that points the hand's forearm (its +Z) most toward `toward`.
static func _forearm_yaw(item_basis: Basis, toward := FOREARM_TOWARD) -> float:
	var target := toward.normalized()
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


## Where the arrow's nock sits on the bow string, in the bow model's space (printed by gen_items.py b_bow: the
## string 0.195 m behind the grip; the arrow rests on the right of the stave, just above the grip).
const NOCK := Vector3(0.032, 0.03, 0.195)


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
		if id in LEFT_HAND and ResourceLoader.exists(HAND_L_PATH):
			# the bow hand: round the grip at the model's origin, forearm toward the lower left
			var left := AssetLib.instance(HAND_L_PATH)
			left.name = "HandL"
			left.rotation_degrees = Vector3(0, _forearm_yaw(m.basis, FOREARM_TOWARD_L), 0)
			left.scale = Vector3.ONE * BOW_HAND_SCALE / BOW_VIEW_SCALE
			m.add_child(left)
			HumanNPC._tune_skin(left)
		if id == &"torch":
			var flame := Graybox.part(root, Graybox.sphere(0.05, 8), Color(1.0, 0.6, 0.2), Vector3(0, 0.33, -0.08))
			flame.material_override = Graybox.mat(Color(1.0, 0.55, 0.2), 1.0, 3.0)
	else:
		Graybox.part(root, Graybox.box(Vector3(0.1, 0.1, 0.1)), Color.GRAY)
	_no_shadows(root)
	_viewmodel_materials(root)
	return root


## Forearm length from the grip to the elbow (hand_root units).
const FOREARM := 0.3
## Viewmodel depth squeezed toward the eye: the held item and hand draw over a trunk or wall right in front of
## the player instead of sinking into it (the axe used to vanish into the tree at the blow, head left floating).
const VIEW_Z_CLIP := 0.2


## Where a swing turns the held item round (hand_root space): the elbow, one forearm back from the grip along
## the forearm's direction, so the forearm stays rooted in the corner of the view as the blow comes down.
static func swing_pivot(id: StringName) -> Vector3:
	var pose: Array = HOLD.get(id, [Vector3.ZERO, Vector3(-30, 0, 0), 1.0])
	var toward := FOREARM_TOWARD_L if id in LEFT_HAND else FOREARM_TOWARD
	return (pose[0] as Vector3) + toward.normalized() * FOREARM


static var _view_mats: Dictionary = {}


## Viewmodel copies of the item's and hand's materials (z clip scale), shared by every build of the same item.
static func _viewmodel_materials(root: Node) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			if not m is BaseMaterial3D:
				continue
			if not _view_mats.has(m):
				var d := (m as BaseMaterial3D).duplicate() as BaseMaterial3D
				d.use_z_clip_scale = true
				d.z_clip_scale = VIEW_Z_CLIP
				_view_mats[m] = d
			mi.set_surface_override_material(s, _view_mats[m])


## The bow is placed in the camera's space, not by a hold pose, as Far Cry Primal shows it: low in the right half of
## the view, the left fist on the grip near the bottom edge, the stave canted with its upper limb reaching up and
## away to the right, an arrow on the string, and the arrow always pointing at the crosshair (the shot really
## leaves along the view axis). Drawing pulls the arrow back and lifts the bow a little; the pose stays the same.
## Static vars so AutoShot can tune them.
const BOW_VIEW_SCALE := 0.8
const BOW_HAND_SCALE := 1.2
static var BOW_GRIP := Vector3(0.1, -0.22, -0.42)      # the grip (model origin) in the view, carried
static var BOW_GRIP_DRAWN := Vector3(0.07, -0.17, -0.46)
static var BOW_CANT := 30.0                             # degrees, the top to the right
const BOW_AIM_DIST := 25.0                              # where along the view axis the arrow points


## Transform of the bow model in the view (camera) space; w = 0 carried … 1 drawn; pull = how far the arrow is drawn
## (0..1), so the arrow at its nock is the one aimed at the crosshair.
static func bow_view_transform(w: float, pull := 0.0) -> Transform3D:
	var e := w * w * (3.0 - 2.0 * w)
	var grip := BOW_GRIP.lerp(BOW_GRIP_DRAWN, e)
	var nock := NOCK + Vector3(0.0, 0.0, Player.BOW_PULL * pull)
	var target := Vector3(0.0, 0.0, -BOW_AIM_DIST)
	var b := Basis.IDENTITY
	for i in 3:  # the arrow's line depends on the basis, the basis on the arrow's direction: settles in a few steps
		var at := grip + b * (nock * BOW_VIEW_SCALE)
		var f := (target - at).normalized()
		var up := (Vector3.UP - f * Vector3.UP.dot(f)).normalized()
		up = up.rotated(f, deg_to_rad(BOW_CANT))
		var z := -f
		b = Basis(up.cross(z), up, z)
	return Transform3D(b.scaled_local(Vector3.ONE * BOW_VIEW_SCALE), grip)


## Yaw about a hand's grip axis (its +Y) that brings its forearm (+Z) closest to `toward`, both in view space;
## `basis` is the hand parent's basis in view space.
static func forearm_yaw_in(basis: Basis, toward: Vector3) -> float:
	var target := toward.normalized()
	var best := 0.0
	var best_dot := -INF
	for k in 72:
		var yaw := k * 5.0
		var d := (basis * Basis(Vector3.UP, deg_to_rad(yaw)) * Vector3(0, 0, 1)).normalized()
		if d.dot(target) > best_dot:
			best_dot = d.dot(target)
			best = yaw
	return best


## Puts an arrow on the string of a bow viewmodel built by build(&"bow"), with the right hand pinching it on the
## string; returns the nock (arrow + hand) so the caller can pull it back along +Z while drawing
## (position.z = NOCK.z + pull).
static func nock_arrow(bow_root: Node3D) -> Node3D:
	var path := AssetLib.item_model_path(&"arrow")
	var model := bow_root.get_node_or_null("Model") as Node3D
	if path == "" or model == null:
		return null
	var nock := Node3D.new()
	nock.name = "Nock"
	nock.position = NOCK
	model.add_child(nock)
	var a := AssetLib.instance(path)
	a.rotation_degrees = Vector3(-90, 0, 0)  # arrow model points +Y; on the bow it points forward (-Z)
	nock.add_child(a)
	if ResourceLoader.exists(HAND_PATH):
		# the draw hand: its fist round the string (the string runs up the bow like a handle), forearm straight
		# back toward the eye, a little behind the nock so the fingers hook the string
		var hand := AssetLib.instance(HAND_PATH)
		hand.name = "DrawHand"
		hand.position = Vector3(0.012, 0.0, 0.035)
		hand.rotation_degrees = Vector3(0, DRAW_HAND_YAW, 0)
		hand.scale = Vector3.ONE * BOW_HAND_SCALE / BOW_VIEW_SCALE
		nock.add_child(hand)
		HumanNPC._tune_skin(hand)
	_no_shadows(nock)
	_viewmodel_materials(nock)
	return nock


const DRAW_HAND_HIDE := 0.33
const DRAW_HAND_YAW := 37.0  # forearm back and out to the right, past the cheek


## Bends a bow viewmodel: 0 = rest, 1 = full draw (limbs flexed, string in a V at NOCK + Player.BOW_PULL).
## The draw hand shows only on the first part of the draw: past it the hand is at the cheek, out of sight.
static func set_bow_draw(bow_root: Node3D, w: float) -> void:
	var hand := bow_root.get_node_or_null("Model/Nock/DrawHand") as Node3D
	if hand:
		hand.visible = w < DRAW_HAND_HIDE
	for mi: MeshInstance3D in bow_root.find_children("*", "MeshInstance3D", true, false):
		var idx := mi.find_blend_shape_by_name(&"Drawn")
		if idx >= 0:
			mi.set_blend_shape_value(idx, w)


static func _no_shadows(n: Node) -> void:
	for gi: GeometryInstance3D in n.find_children("*", "GeometryInstance3D", true, false):
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
