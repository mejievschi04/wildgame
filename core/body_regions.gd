class_name BodyRegions
extends RefCounted
## Hit-location model: which body region a world-space hit point belongs to, from the nearest bone segment.

const MULT := {&"head": 2.5, &"torso": 1.0, &"arm_l": 0.7, &"arm_r": 0.7, &"leg_l": 0.75, &"leg_r": 0.75}
## Bone hidden when the region is severed, and the joint where the stump cap goes (its parent bone).
const SEVER_BONE := {&"head": "head", &"arm_l": "lowerarm_l", &"arm_r": "lowerarm_r", &"leg_l": "calf_l", &"leg_r": "calf_r"}


static func region_of_bone(bone: String) -> StringName:
	var b := bone.to_lower()
	if b.begins_with("head") or b.begins_with("neck") or b.begins_with("snout") or b.begins_with("ear") or b.begins_with("hair_"):
		return &"head"
	var side := "l" if (b.ends_with("_l") or b.ends_with(".l")) else ("r" if (b.ends_with("_r") or b.ends_with(".r")) else "")
	for k in ["upperarm", "lowerarm", "hand", "index", "middle", "pinky", "ring", "thumb", "forearm", "hoof_f"]:
		if b.begins_with(k) and side != "":
			return StringName("arm_" + side)
	for k in ["thigh", "calf", "foot", "ball", "shin", "hoof_h"]:
		if b.begins_with(k) and side != "":
			return StringName("leg_" + side)
	return &"torso"


## Region of the bone segment nearest to a world point.
static func region_at(skel: Skeleton3D, world_point: Vector3) -> StringName:
	if skel == null:
		return &"torso"
	var best := INF
	var best_bone := ""
	var xf := skel.global_transform
	for i in skel.get_bone_count():
		var a := xf * skel.get_bone_global_pose(i).origin
		var kids := skel.get_bone_children(i)
		var b := xf * skel.get_bone_global_pose(kids[0]).origin if kids.size() > 0 else a
		var d := _seg_dist(world_point, a, b)
		if d < best:
			best = d
			best_bone = skel.get_bone_name(i)
	return region_of_bone(best_bone)


static func _seg_dist(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
	return p.distance_to(a + ab * t)
