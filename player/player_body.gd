class_name PlayerBody
extends Node3D
## The player's own Homo sapiens body (SK_Human_SapiensM, the same man as the Aruun NPCs), seen in first person:
## look down and you see your chest, arms, legs and feet move as you walk, run, crouch, jump and swim.
##
## Two copies play the same clip:
##  · the visible one, its head shrunk away (the camera sits where the eyes are) and, while something is in hand,
##    the arm that the held item's own hand replaces; it is kept under the camera each frame, so leaning clips
##    (sprinting, crouching) never put the camera inside the chest; and as you look down it leans back from the
##    feet, so the chest gives way and you see your belly, legs and feet (as you would bending your neck);
##  · a full body that only casts the shadow, standing where the player stands.

const MODEL := "res://assets/models/humans/SK_Human_SapiensM.gltf"
const BACK := 0.12           # the visible body sits this far behind the eyes (its head joint)
const BELOW_EYE := 0.07      # head joint (base of the skull) under the camera
const BLEND := 0.2
const LAND_TIME := 0.35

var player: Player
var visible_model: Node3D
var shadow_model: Node3D
var clip := ""
var _anims: Array[AnimationPlayer] = []
var _skel: Skeleton3D
var _trims: Array[BodyTrim] = []
var _head := -1
var _scale := 1.0
var _air := 0.0
var _land := 0.0
var _backwards := false
var _offset := Vector3.ZERO
const LEAN_FROM := 0.35      # head pitch (rad, down) where the lean begins
const LEAN := 0.45           # lean per radian of pitch beyond that


## After the clip each frame: keep the Root in place (the capsule moves the body) and shrink hidden parts.
class BodyTrim extends SkeletonModifier3D:
	var root_bone := -1
	var hidden: PackedInt32Array = []

	func _process_modification() -> void:
		var sk := get_skeleton()
		if sk == null:
			return
		if root_bone >= 0:
			var rest := sk.get_bone_rest(root_bone).origin
			sk.set_bone_pose_position(root_bone, Vector3(rest.x, sk.get_bone_pose_position(root_bone).y, rest.z))
		for b in hidden:
			sk.set_bone_pose_scale(b, Vector3.ONE * 0.001)


func setup(p: Player) -> void:
	player = p
	name = "Body"
	visible_model = _make(false)
	shadow_model = _make(true)
	_skel = visible_model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	_head = _skel.find_bone("head")
	# match the head joint to the eye height (the man is 1.82 m; the player's eyes are at Player.EYE_STAND)
	var head_y := (_skel.transform * _skel.get_bone_global_rest(_head)).origin.y
	_scale = (Player.EYE_STAND - BELOW_EYE) / maxf(head_y, 0.5)
	for m in [visible_model, shadow_model]:
		m.scale = Vector3.ONE * _scale
	set_hidden_arms(false, false)


func _make(shadow_only: bool) -> Node3D:
	var m := AssetLib.instance(MODEL)
	m.rotation.y = PI  # the model faces +Z, the player looks down -Z
	add_child(m)
	HumanNPC._tune_skin(m)
	for gi: GeometryInstance3D in m.find_children("*", "GeometryInstance3D", true, false):
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if shadow_only \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		gi.extra_cull_margin = 2.0  # skinned: animation moves it outside the rest bounds
	var ap := m.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	for n: StringName in ap.get_animation_list():
		var s := String(n)
		if s in ["idle", "walk", "run", "combat_strafe_l", "combat_strafe_r"] or \
				(s.begins_with("player_") and not s.contains("jump_start") and not s.contains("jump_land")):
			ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	_anims.append(ap)
	var sk := m.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var trim := BodyTrim.new()
	trim.name = "BodyTrim"
	trim.root_bone = sk.find_bone("Root")
	sk.add_child(trim)
	if not shadow_only:
		_trims.append(trim)
	return m


## Shrinks the head always, and an arm when the held item draws its own hand (the bow: both arms).
func set_hidden_arms(right: bool, left: bool) -> void:
	for trim in _trims:
		var sk := trim.get_skeleton()
		var bones := PackedInt32Array([sk.find_bone("head"), sk.find_bone("neck_01")])
		if right:
			bones.append(sk.find_bone("upperarm_r"))
		if left:
			bones.append(sk.find_bone("upperarm_l"))
		trim.hidden = bones


func _physics_process(delta: float) -> void:
	if player == null:
		return
	visible = not (player.dead or player.is_sleeping)
	var v := player.velocity
	var local := player.global_transform.basis.inverse() * Vector3(v.x, 0.0, v.z)
	var speed := local.length()
	var forward := -local.z
	var side := local.x
	var on_floor := player.is_on_floor()
	if on_floor:
		if _air > 0.45:
			_land = LAND_TIME
		_air = 0.0
	else:
		_air += delta
	_land = maxf(_land - delta, 0.0)
	var in_water := player.global_position.y < ForestWorld.WATER_LEVEL - 0.25
	if in_water:
		_play("player_swim" if speed > 0.4 else "player_swim_idle", clampf(speed / 1.6, 0.5, 1.4))
	elif not on_floor and _air > 0.18:
		_play("player_jump_start" if v.y > 1.0 and _air < 0.5 else "player_jump_loop")
	elif _land > 0.0:
		_play("player_jump_land", 1.4)
	elif player._crouching:
		if speed > 0.3:
			_play("player_crouch_walk", clampf(speed / 1.4, 0.5, 1.6), forward < -0.2)
		else:
			_play("player_crouch_idle")
	elif speed < 0.3:
		_play("idle")
	elif forward < -0.3:
		_play("walk", clampf(speed / HumanNPC.WALK, 0.5, 1.8), true)
	elif absf(side) > absf(forward) * 1.2:
		_play("combat_strafe_l" if side < 0.0 else "combat_strafe_r", clampf(speed / 2.0, 0.6, 1.8))
	elif speed > Player.WALK_SPEED * 1.25:
		_play("player_sprint", clampf(speed / Player.SPRINT_SPEED, 0.7, 1.3))
	else:
		_play("run", clampf(speed / HumanNPC.RUN, 0.55, 1.2))


func _process(_delta: float) -> void:
	if player == null or _head < 0:
		return
	# keep the visible body's head joint just under and behind the camera, whatever the clip does with it
	var upright := Basis(Vector3.UP, PI).scaled(Vector3.ONE * _scale)
	var head_local := upright * (_skel.transform * _skel.get_bone_global_pose(_head)).origin
	var want := Vector3(0.0, player.head.position.y - BELOW_EYE, BACK)
	var off := want - head_local
	off.y = clampf(off.y, -0.6, 0.4)  # never lift the feet far off the ground or sink them deep
	_offset = _offset.lerp(off, 0.5)
	# looking down, the body leans back from the feet (player +Z is behind)
	var lean := clampf(-player.head.rotation.x - LEAN_FROM, 0.0, 1.2) * LEAN
	visible_model.transform = Transform3D(Basis(Vector3.RIGHT, lean) * upright, _offset)


func _play(name: String, rate := 1.0, backwards := false) -> void:
	for ap in _anims:
		if not ap.has_animation(name):
			continue
		ap.speed_scale = rate
		if clip != name or _backwards != backwards:
			ap.play(name, BLEND, 1.0, backwards)
	clip = name
	_backwards = backwards
