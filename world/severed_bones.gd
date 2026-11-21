class_name SeveredBones
extends SkeletonModifier3D
## Runs after the AnimationPlayer: collapses severed bones (and their children) to zero scale every frame,
## so cut-off limbs/heads disappear from the skinned body regardless of the playing clip.

var hidden: PackedStringArray = PackedStringArray()


func _process_modification_with_delta(_delta: float) -> void:
	_apply()


func _apply() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	for name in hidden:
		var i := sk.find_bone(name)
		if i >= 0:
			sk.set_bone_pose_scale(i, Vector3.ONE * 0.0001)
