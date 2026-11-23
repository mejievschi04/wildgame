"""Bake Godot clips from the shipped rigs without rebuilding their meshes.

blender -b --python tools/blender/bake_human_combat.py [-- SapiensM NeanderthalF ...]

AN_<variant>_combat.tres: guard, thrust, feint, throw, hit_l, hit_r, strafe_l, strafe_r
AN_<variant>_life.tres:   sleep (on the side, breathing), work (squat and pick at the ground),
                          step (stepping on the spot while the body pivots)
"""
from pathlib import Path
import math
import sys

import bpy
from mathutils import Quaternion, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import human_anim as ha

MODELS = Path(__file__).resolve().parents[2] / "assets" / "models" / "humans"
FPS = 25
CONTACT_FRAME = 14
THROW_FRAME = 17  # release frame of the spear throw (human_npc.gd THROW_RELEASE = 17 / 25 s)
TO_GODOT = Quaternion(ha.X, -math.pi / 2)
SKELETON_PATH = "Human_rig/Skeleton3D"


def update(rig):
    rig.update_tag()
    bpy.context.view_layer.update()


def stance_x(body, side, extra=0.0):
    """Ankle x for a natural stance: just outside the hip joint (the rig's rest pose stands in an A)."""
    sign = 1.0 if side == "l" else -1.0
    return body.h["thigh_" + side].x + sign * (ha.STANCE + extra)


def pose(rig, rotations, root):
    ha.stance_fix(rig, rotations)   # legs under the hips (clips that place the feet with reach() re-aim them anyway)
    ha.skirt_follow(rig, rotations)
    for bone in rig.pose.bones:
        bone.rotation_mode = "QUATERNION"
        result = Quaternion()
        for axis, angle in rotations.get(bone.name, []):
            result = ha.gh.pose_rot(rig, bone.name, axis, angle) @ result
        bone.rotation_quaternion = result
        bone.location = root if bone.name == "Root" else (0, 0, 0)
    update(rig)


def aim(bone, child, target):
    present = bone.matrix.to_quaternion()
    desired = (child.head - bone.head).rotation_difference(target - bone.head) @ present
    rest = bone.parent.bone.matrix_local.inverted() @ bone.bone.matrix_local
    bone.rotation_quaternion = rest.to_quaternion().inverted() @ bone.parent.matrix.to_quaternion().inverted() @ desired


def reach(rig, names, target, pole):
    """Place a hand or foot using a two-bone solve and a preferred bend direction."""
    upper, lower, end = (rig.pose.bones[name] for name in names)
    start = upper.head.copy()
    first = (lower.head - start).length
    second = (end.head - lower.head).length
    axis = (target - start).normalized()
    distance = min(max((target - start).length, abs(first - second) + 0.001), first + second - 0.001)
    along = (first * first + distance * distance - second * second) / (2 * distance)
    bend = (pole - axis * axis.dot(pole)).normalized()
    joint = start + axis * along + bend * math.sqrt(max(0, first * first - along * along))
    orientation = end.matrix.to_quaternion()
    aim(upper, lower, joint)
    update(rig)
    aim(lower, end, start + axis * distance)
    update(rig)
    if end.name.startswith("foot_"):
        rest = end.parent.bone.matrix_local.inverted() @ end.bone.matrix_local
        end.rotation_quaternion = rest.to_quaternion().inverted() @ end.parent.matrix.to_quaternion().inverted() @ orientation
        update(rig)


def combat_pose(rig, body, draw, drive, extra=(), shift=(0.0, 0.0, 0.0)):
    rotations = ha.relaxed(body, {}, fist_r=1.0, fist_l=0.9, elbow=8)
    for bone, axis, angle in extra:
        ha.add(rotations, bone, axis, angle)
    h = body.h["pelvis"].z
    scale = h / 1.04
    root = ((0.0 + shift[0]) * scale, (0.07 * draw - 0.29 * drive + shift[1]) * scale, (-0.075 - 0.035 * drive + shift[2]) * scale)
    twist = 13 + 22 * draw - 31 * drive
    ha.add(rotations, "pelvis", ha.Z, twist * 0.36)
    ha.add(rotations, "spine_01", ha.Z, twist * 0.34)
    ha.add(rotations, "spine_02", ha.Z, twist * 0.30)
    ha.add(rotations, "spine_02", ha.X, 3 + 12 * drive)
    ha.add(rotations, "head", ha.Z, -twist)
    ha.add(rotations, "neck_01", ha.X, -5 * drive)
    pose(rig, rotations, root)
    for side, stride, lift in (("l", -0.20 - 0.28 * drive, 0.12 * math.sin(math.pi * drive)),
                               ("r", 0.18, 0)):
        foot = body.h["foot_" + side].copy()
        foot.x = stance_x(body, side, 0.035 * scale)       # fighting stance: a little wider than standing
        foot.y += stride * scale
        foot.z += lift * scale
        reach(rig, tuple(bone + "_" + side for bone in ("thigh", "calf", "foot")), foot, Vector((0, -1, 0)))
    grip = Vector(((-0.30 + 0.13 * drive) * scale, (-0.14 + 0.30 * draw - 0.57 * drive) * scale,
                   (1.14 - 0.04 * draw + 0.16 * drive) * scale))
    reach(rig, ("upperarm_r", "lowerarm_r", "hand_r"), grip, Vector((-0.6, 0.05, -1.0)))
    guide = grip + Vector((0.025 + 0.04 * drive, -0.34 + 0.09 * drive, -0.065 + 0.04 * drive)) * scale
    reach(rig, ("upperarm_l", "lowerarm_l", "hand_l"), guide, Vector((0.8, 0, -1)))


def sidestep(rig, body, phase, direction):
    # The leading foot opens the stance and the trailing foot closes it without crossing.
    cycle = math.tau * phase
    rotations = ha.relaxed(body, {}, fist_r=0.95, fist_l=0.55, elbow=12)
    ha.add(rotations, "upperarm_r", ha.X, -22)
    ha.add(rotations, "lowerarm_r", ha.X, -34)
    ha.add(rotations, "upperarm_l", ha.X, -31)
    ha.add(rotations, "lowerarm_l", ha.X, -38)
    ha.add(rotations, "spine_02", ha.Y, 4 * direction + 2 * math.sin(cycle))
    pose(rig, rotations, (0.035 * direction * math.sin(cycle), 0, -0.083 + 0.013 * math.cos(2 * cycle)))
    duty = 0.62
    stride = 20 / FPS  # 1 m/s, the combat sidestep speed
    for side in ("l", "r"):
        u = (phase + (0.5 if (side == "l") == (direction > 0) else 0.0)) % 1.0
        if u < duty:
            x = stride * (duty / 2 - u)
            lift = 0.0
        else:
            swing = (u - duty) / (1 - duty)
            x = stride * duty * (ha.smooth(swing) - 0.5)
            lift = 0.09 * math.sin(math.pi * swing)
        foot = body.h["foot_" + side].copy()
        # Use staggered foot depth to leave room for both feet during the close step.
        foot.x = stance_x(body, side, 0.03) + direction * x
        foot.y += -0.11 if side == "l" else 0.08
        foot.z += lift
        reach(rig, tuple(bone + "_" + side for bone in ("thigh", "calf", "foot")), foot, Vector((0, -1, 0)))


def throw_pose(rig, body, cock, release):
    """Overhand spear throw: the spear is drawn back over the shoulder (cock), then the arm whips forward."""
    rotations = ha.relaxed(body, {}, fist_r=1.0, fist_l=0.3, elbow=10)
    scale = body.h["pelvis"].z / 1.04
    twist = 10 + 30 * cock - 55 * release
    ha.add(rotations, "pelvis", ha.Z, twist * 0.3)
    ha.add(rotations, "spine_01", ha.Z, twist * 0.33)
    ha.add(rotations, "spine_02", ha.Z, twist * 0.33)
    ha.add(rotations, "spine_02", ha.X, -8 * cock + 22 * release)
    ha.add(rotations, "head", ha.Z, -twist * 0.9)
    root = (0.0, (0.08 * cock - 0.24 * release) * scale, (-0.06 - 0.03 * release) * scale)
    pose(rig, rotations, root)
    for side, stride in (("l", -0.24 - 0.06 * release), ("r", 0.20)):
        foot = body.h["foot_" + side].copy()
        foot.x = stance_x(body, side, 0.04 * scale)
        foot.y += stride * scale
        reach(rig, tuple(bone + "_" + side for bone in ("thigh", "calf", "foot")), foot, Vector((0, -1, 0)))
    guard = Vector((-0.30, -0.14, 1.14))
    cocked = Vector((-0.26, 0.30, 1.60))
    thrown = Vector((-0.10, -0.58, 1.38))
    grip = guard.lerp(cocked, cock).lerp(thrown, release) * scale
    reach(rig, ("upperarm_r", "lowerarm_r", "hand_r"), grip, Vector((-0.7, 0.4, -0.6)))
    aimh = Vector((0.20, -0.50, 1.42)).lerp(Vector((0.26, -0.10, 1.00)), release) * scale
    reach(rig, ("upperarm_l", "lowerarm_l", "hand_l"), aimh, Vector((0.8, 0.2, -1)))


def lying(rig, body, phase):
    """Asleep on the side, knees drawn up, slow breathing. The body is centred over the standing capsule."""
    scale = body.h["pelvis"].z / 1.04
    breath = math.sin(math.tau * phase)
    rotations = ha.relaxed(body, {}, fist_r=0.35, fist_l=0.35, elbow=0)
    ha.add(rotations, "Root", ha.Y, 90)
    for side in ("l", "r"):
        ha.add(rotations, "thigh_" + side, ha.X, -62 if side == "l" else -48)
        ha.add(rotations, "calf_" + side, ha.X, 80 if side == "l" else 70)
        ha.add(rotations, "foot_" + side, ha.X, -10)
        ha.add(rotations, "upperarm_" + side, ha.X, -55)
        ha.add(rotations, "lowerarm_" + side, ha.X, -75)
    ha.add(rotations, "spine_01", ha.X, 12)
    ha.add(rotations, "spine_02", ha.X, 8 + 1.6 * breath)
    ha.add(rotations, "spine_03", ha.X, 0.8 * breath)
    ha.add(rotations, "neck_01", ha.X, 10)
    ha.add(rotations, "head", ha.Y, -12)
    pose(rig, rotations, (-0.84 * scale, 0.0, 0.17 * scale))


def work(rig, body, phase):
    """Squatting and picking at the ground: hands take turns reaching down and back to the lap."""
    scale = body.h["pelvis"].z / 1.04
    cycle = math.tau * phase
    rotations = ha.relaxed(body, {}, fist_r=0.35, fist_l=0.35, elbow=10)
    root = (0.0, 0.10 * scale, -0.50 * scale)
    L, R = body.leg["l"], body.leg["r"]
    ha.legs(body, rotations, root, (L["ankle"].y - 0.06 * scale, L["ankle"].z + 0.01, 0),
            (R["ankle"].y - 0.10 * scale, R["ankle"].z + 0.01, 0))
    ha.add(rotations, "spine_01", ha.X, 36 + 3 * math.sin(cycle))
    ha.add(rotations, "spine_02", ha.X, 14)
    ha.add(rotations, "spine_02", ha.Z, 6 * math.sin(cycle))
    ha.add(rotations, "neck_01", ha.X, -22)
    ha.add(rotations, "head", ha.X, -8)
    pose(rig, rotations, root)
    for side, offset, sx in (("r", 0.0, -1), ("l", 0.5, 1)):
        u = (phase + offset) % 1.0
        k = math.sin(math.pi * min(u / 0.6, 1.0)) ** 2
        ground = Vector((0.17 * sx, -0.46, 0.06)) * scale
        lap = Vector((0.13 * sx, -0.30, 0.46)) * scale
        reach(rig, tuple(bone + "_" + side for bone in ("upperarm", "lowerarm", "hand")), lap.lerp(ground, k),
              Vector((0.8 * sx, 0.4, -0.3)))


def step_turn(rig, body, phase):
    """Small steps on the spot (the game turns the body): one foot after the other lifts and sets down."""
    scale = body.h["pelvis"].z / 1.04
    cycle = math.tau * phase
    rotations = ha.relaxed(body, {}, fist_r=0.2, fist_l=0.2, elbow=8)
    ha.add(rotations, "spine_02", ha.Y, 2 * math.sin(cycle))
    pose(rig, rotations, (0.02 * math.sin(cycle) * scale, 0.0, (-0.02 + 0.01 * math.cos(2 * cycle)) * scale))
    for side, offset in (("l", 0.0), ("r", 0.5)):
        u = (phase + offset) % 1.0
        lift = 0.07 * math.sin(math.pi * (u - 0.55) / 0.45) if u > 0.55 else 0.0
        foot = body.h["foot_" + side].copy()
        foot.x = stance_x(body, side)
        foot.z += lift * scale
        reach(rig, tuple(bone + "_" + side for bone in ("thigh", "calf", "foot")), foot, Vector((0, -1, 0)))


def values(vector):
    return tuple(round(component, 6) + 0.0 for component in vector)


def pack(samples):
    return "PackedFloat32Array(" + ", ".join(str(x) for sample in samples for x in sample) + ")"


def bake(rig, name, frames, sample, loop):
    # glTF bone tracks use absolute parent-local transforms. Only the root changes coordinate systems.
    tracks = {bone.name: [] for bone in rig.pose.bones}
    previous = {}
    roots = []
    for frame in range(frames + 1):
        sample(frame)
        t = frame / FPS
        for bone in rig.pose.bones:
            local = bone.parent.matrix.inverted() @ bone.matrix if bone.parent else bone.matrix
            rotation = local.to_quaternion() if bone.parent else TO_GODOT @ local.to_quaternion()
            if bone.name in previous and previous[bone.name].dot(rotation) < 0:
                rotation.negate()
            previous[bone.name] = rotation
            tracks[bone.name].append((t, 1, *values((rotation.x, rotation.y, rotation.z, rotation.w))))
            if bone.name == "Root":
                roots.append((t, 1, *values(TO_GODOT @ local.translation)))
    result = [f'[sub_resource type="Animation" id="{name}"]', f'resource_name = "{name}"',
              f"length = {frames / FPS}", f"loop_mode = {int(loop)}"]
    tracks = [("position_3d", "Root", roots)] + [
        ("rotation_3d", bone, keys) for bone, keys in tracks.items()
        if bone == "Root" or bone.startswith(("pelvis", "spine", "neck", "head", "clavicle", "upperarm",
                                             "lowerarm", "hand", "thigh", "calf", "foot", "ball",
                                             "thumb", "index", "middle", "ring", "pinky", "skirt"))
    ]
    for i, (kind, bone, keys) in enumerate(tracks):
        # Keep constant tracks for correct blending, but store their value just once.
        if all(key[2:] == keys[0][2:] for key in keys):
            keys = keys[:1]
        result.extend((f'tracks/{i}/type = "{kind}"', f"tracks/{i}/imported = false",
                       f"tracks/{i}/enabled = true", f'tracks/{i}/path = NodePath("{SKELETON_PATH}:{bone}")',
                       f"tracks/{i}/interp = 1", f"tracks/{i}/loop_wrap = true", f"tracks/{i}/keys = {pack(keys)}"))
    return "\n".join(result)


def build(variant):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(MODELS / f"SK_Human_{variant}.gltf"), bone_heuristic="BLENDER")
    rig = next(obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE")
    rig.animation_data_clear()
    for obj in list(bpy.context.scene.objects):
        if obj.type == "MESH":
            bpy.data.objects.remove(obj, do_unlink=True)
    body = ha.Body(rig)

    def thrust(frame):
        draw = ha.smooth(frame / 9) * (1 - ha.smooth((frame - 9) / (CONTACT_FRAME - 9)))
        drive = ha.smooth((frame - 9) / (CONTACT_FRAME - 9)) * (1 - ha.smooth((frame - 15) / 13))
        combat_pose(rig, body, draw, drive)

    def feint(frame):
        # Same wind-up as the thrust, a short stab that stops well short, and a quick recovery.
        draw = ha.smooth(frame / 8) * (1 - ha.smooth((frame - 10) / 6))
        drive = 0.3 * math.sin(math.pi * min(max((frame - 8) / 8, 0.0), 1.0))
        combat_pose(rig, body, draw, drive)

    def hit(direction):
        def sample(frame):
            k = ha.smooth(frame / 3) * (1 - ha.smooth((frame - 4) / 9))
            combat_pose(rig, body, 0.0, 0.0, extra=(("spine_02", ha.Z, 22 * k * direction), ("spine_02", ha.X, -14 * k),
                                                   ("head", ha.Z, 26 * k * direction), ("head", ha.X, -12 * k)),
                        shift=(-0.05 * k * direction, 0.10 * k, -0.02 * k))
        return sample

    def throw(frame):
        cock = ha.smooth(frame / 11) * (1 - ha.smooth((frame - 12) / 4))
        release = ha.smooth((frame - 12) / (THROW_FRAME - 12)) * (1 - ha.smooth((frame - 22) / 10))
        throw_pose(rig, body, cock, release)

    clips = {
        "guard": (1, lambda frame: combat_pose(rig, body, 0.0, 0.0), False),
        "thrust": (28, thrust, False),
        "feint": (22, feint, False),
        "throw": (32, throw, False),
        "hit_l": (14, hit(1), False),
        "hit_r": (14, hit(-1), False),
        "strafe_l": (20, lambda frame: sidestep(rig, body, frame / 20, 1), True),
        "strafe_r": (20, lambda frame: sidestep(rig, body, frame / 20, -1), True),
    }
    write_library(rig, variant, "combat", clips)
    write_library(rig, variant, "life", {
        "sleep": (100, lambda frame: lying(rig, body, frame / 100), True),
        "work": (60, lambda frame: work(rig, body, frame / 60), True),
        "step": (24, lambda frame: step_turn(rig, body, frame / 24), True),
    })


def write_library(rig, variant, kind, clips):
    blocks = ['[gd_resource type="AnimationLibrary" format=3]']
    blocks.extend(bake(rig, name, *args) for name, args in clips.items())
    entries = ",\n".join(f'&"{name}": SubResource("{name}")' for name in clips)
    blocks.append(f"[resource]\n_data = {{\n{entries}\n}}")
    (MODELS / f"AN_{variant}_{kind}.tres").write_text("\n\n".join(blocks) + "\n", encoding="utf-8")


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    for variant in (argv or ["SapiensM", "SapiensF", "NeanderthalM", "NeanderthalF"]):
        build(variant)
