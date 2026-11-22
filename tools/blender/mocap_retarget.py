# Retarget CMU motion capture (BVH, Bruce Hahne's MotionBuilder-friendly conversion) onto the MPFB
# game_engine rig used by our hominins.
#
#   * Frame 1 of every file is a T-pose; the target is in an A-pose. For each mapped bone the target
#     "reference" orientation is its rest orientation aimed along the source T-pose bone direction, so
#     world-space rotation deltas (including twist) transfer 1:1:
#         R_target(t) = A · R_src(t) · R_src(T)⁻¹ · A⁻¹ · R_ref
#     (A = yaw that turns the actor to face our -Y).
#   * Hip translation is scaled by the leg-length ratio. Cyclic clips are cut at the two most similar
#     frames one stride apart, re-timed so the stride matches the game speed, and made in-place.
#   * Local bone rotations are solved analytically from the desired world rotations (parents first).
# Data: CMU Graphics Lab Motion Capture Database (mocap.cs.cmu.edu) — free for commercial use with credit.
import bpy, math
import numpy as np
from mathutils import Matrix, Quaternion, Vector

MAP = {
    "pelvis": "Hips", "spine_01": "LowerBack", "spine_02": "Spine", "spine_03": "Spine1",
    "neck_01": "Neck", "head": "Head",
    "clavicle_l": "LeftShoulder", "upperarm_l": "LeftArm", "lowerarm_l": "LeftForeArm", "hand_l": "LeftHand",
    "clavicle_r": "RightShoulder", "upperarm_r": "RightArm", "lowerarm_r": "RightForeArm", "hand_r": "RightHand",
    "thigh_l": "LeftUpLeg", "calf_l": "LeftLeg", "foot_l": "LeftFoot", "ball_l": "LeftToeBase",
    "thigh_r": "RightUpLeg", "calf_r": "RightLeg", "foot_r": "RightFoot", "ball_r": "RightToeBase",
}
SRC_FPS = 120.0


class Source:
    """A BVH clip sampled into armature-space bone rotations / positions (Z-up). The T-pose is turned by
    A_T (its own facing) and the motion by A (facing chosen per clip), both so the actor faces -Y."""

    def __init__(self, path):
        before = set(bpy.data.objects)
        bpy.ops.import_anim.bvh(filepath=path, global_scale=1.0, frame_start=1, use_fps_scale=False,
                                update_scene_fps=False, update_scene_duration=False, rotate_mode="NATIVE",
                                axis_forward="-Z", axis_up="Y")
        self.obj = next(o for o in bpy.data.objects if o not in before and o.type == "ARMATURE")
        act = self.obj.animation_data.action
        self.n = int(act.frame_range[1])
        self._raw = {}
        self.A_T = self.facing(1)
        self.A = self.A_T
        self._cache = {}
        self.T = self._turned(1, self.A_T)

    def raw(self, f):
        if f not in self._raw:
            sc = bpy.context.scene
            sc.frame_set(int(f))
            mw = self.obj.matrix_world
            rot, pos, tail = {}, {}, {}
            for pb in self.obj.pose.bones:
                m = mw @ pb.matrix
                rot[pb.name] = m.to_quaternion()
                pos[pb.name] = m.translation.copy()
                tail[pb.name] = (mw @ pb.tail).copy()
            self._raw[f] = {"rot": rot, "pos": pos, "tail": tail}
        return self._raw[f]

    def facing(self, f):
        R = self.raw(f)
        L = R["pos"]["LeftUpLeg"] - R["pos"]["RightUpLeg"]
        return Quaternion((0, 0, 1), -math.atan2(L.y, L.x))   # actor's left → our +X (faces -Y)

    def face_at(self, f):
        """Turn the motion so the actor faces -Y at frame f."""
        self.A = self.facing(f)
        self._cache = {}

    def _turned(self, f, A):
        R = self.raw(f)
        return {"rot": {k: A @ q for k, q in R["rot"].items()},
                "pos": {k: A @ p for k, p in R["pos"].items()},
                "tail": {k: A @ p for k, p in R["tail"].items()}}

    def pose(self, f):
        if f not in self._cache:
            self._cache[f] = self._turned(f, self.A)
        return self._cache[f]

    def hip_height(self):
        T = self.T
        return T["pos"]["LeftUpLeg"].z - min(T["pos"]["LeftToeBase"].z, T["pos"]["LeftFoot"].z)

    def remove(self):
        act = self.obj.animation_data.action if self.obj.animation_data else None
        bpy.data.objects.remove(self.obj)
        if act:
            bpy.data.actions.remove(act)


class Target:
    def __init__(self, rig):
        self.rig = rig
        B = rig.data.bones
        self.rest = {b.name: b.matrix_local.to_quaternion() for b in B}
        self.rest_m = {b.name: b.matrix_local.copy() for b in B}
        self.parent = {b.name: (b.parent.name if b.parent else None) for b in B}
        self.order = sorted((b.name for b in B), key=lambda n: len(B[n].parent_recursive))   # parents first
        self.hip_h = B["thigh_l"].head_local.z - B["foot_l"].head_local.z + 0.069

    def reference(self, src):
        """Target orientation that corresponds to the source T-pose, per mapped bone."""
        ref = {}
        T = src.T
        for tb, sb in MAP.items():
            if tb not in self.rest or sb not in T["rot"]:
                continue
            if tb in ("pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head"):
                ref[tb] = self.rest[tb]
                continue
            d_src = (T["tail"][sb] - T["pos"][sb]).normalized()
            d_tgt = (self.rest[tb] @ Vector((0, 1, 0))).normalized()
            ref[tb] = d_tgt.rotation_difference(d_src) @ self.rest[tb]
        return ref


def world_targets(tgt, src, ref, f):
    P = src.pose(f)
    T = src.T
    out = {}
    for tb, sb in MAP.items():
        if tb in ref:
            out[tb] = (P["rot"][sb] @ T["rot"][sb].inverted()) @ ref[tb]
    return out


def local_rotations(tgt, Wdesired):
    """Analytic local (basis) rotations, parents first; unmapped bones keep their rest relation."""
    W, local = {}, {}
    for b in tgt.order:
        p = tgt.parent[b]
        Rb_rest = tgt.rest[b]
        Rp_rest = tgt.rest[p] if p else Quaternion()
        Rp_world = W[p] if p else Quaternion()
        if b in Wdesired:
            W[b] = Wdesired[b]
            local[b] = Rb_rest.inverted() @ Rp_rest @ Rp_world.inverted() @ W[b]
        else:
            W[b] = Rp_world @ Rp_rest.inverted() @ Rb_rest
            local[b] = Quaternion()
    return local, W


def features(src, f):
    P = src.pose(f)
    h = P["pos"]["Hips"]
    v = []
    for j in ("LeftFoot", "RightFoot", "LeftHand", "RightHand", "LeftToeBase", "RightToeBase"):
        d = P["pos"][j] - h
        v += [d.x, d.y, d.z]
    return np.array(v)


def find_cycle(src, lo, hi, f0=None, f1=None):
    """Two frames lo..hi apart (source frames) with the most similar pose → seamless loop."""
    f0 = f0 or 2
    f1 = f1 or src.n
    best = (1e9, None, None)
    step = 2
    feats = {f: features(src, f) for f in range(f0, f1 + 1, step)}
    keys = sorted(feats)
    for a in keys:
        for b in keys:
            if lo <= b - a <= hi:
                d = np.linalg.norm(feats[a] - feats[b])
                if d < best[0]:
                    best = (d, a, b)
    return best[1], best[2], best[0]


def bake(rig, src, name, frames_src, out_fps, scale, in_place=True, extra=None, hold_loop=True):
    """frames_src: list of (possibly fractional) source frames, one per output frame."""
    tgt = Target(rig)
    ref = tgt.reference(src)
    act = bpy.data.actions.new(name)
    rig.animation_data.action = act
    for pb in rig.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = Quaternion(); pb.location = (0, 0, 0)
    T = src.T
    h0 = T["pos"]["Hips"]
    hips = [src.pose(int(round(f)))["pos"]["Hips"] for f in frames_src]
    n = len(frames_src)
    drift = (hips[-1] - hips[0]) if in_place else Vector()
    root_rest = rig.data.bones["Root"].matrix_local.to_quaternion()
    pelvis_rest = rig.data.bones["pelvis"].head_local
    for i, f in enumerate(frames_src):
        Wd = world_targets(tgt, src, ref, int(round(f)))
        local, W = local_rotations(tgt, Wd)
        if extra:
            extra(i / max(n - 1, 1), local, W, tgt)
        for b, q in local.items():
            pb = rig.pose.bones[b]
            pb.rotation_quaternion = q
            pb.keyframe_insert("rotation_quaternion", frame=i + 1)
        u = i / max(n - 1, 1)
        d = hips[i] - h0 - drift * u
        d = Vector((d.x * scale, d.y * scale, d.z * scale))
        if in_place:
            d.x *= 0.6                                      # keep a little lateral sway only
        rp = rig.pose.bones["Root"]
        rp.location = root_rest.inverted() @ d
        rp.keyframe_insert("location", frame=i + 1)
        pv = rig.pose.bones["pelvis"]; pv.location = (0, 0, 0); pv.keyframe_insert("location", frame=i + 1)
    rig.animation_data.action = None
    return act, n


def cyclic_clip(rig, path, name, game_speed, out_fps, lo_s, hi_s, extra=None):
    src = Source(path)
    tgt = Target(rig)
    scale = tgt.hip_h / src.hip_height()
    a, b, err = find_cycle(src, int(lo_s * SRC_FPS), int(hi_s * SRC_FPS), 10, src.n - 2)
    src.face_at(a)
    travel = (src.pose(b)["pos"]["Hips"] - src.pose(a)["pos"]["Hips"])
    travel.z = 0
    dur_src = (b - a) / SRC_FPS
    v_src = travel.length * scale / dur_src
    dur = travel.length * scale / game_speed            # stride matched to the game speed
    n = max(8, int(round(dur * out_fps)))
    frames = [a + (b - a) * i / n for i in range(n + 1)]
    act, n_out = bake(rig, src, name, frames, out_fps, scale, in_place=True, extra=extra)
    print(f"MOCAP {name}: {path.split('/')[-1]} frames {a}-{b} err {err:.2f} src {v_src:.2f} m/s → {game_speed} m/s, {dur:.2f}s")
    src.remove()
    return act, n_out


def segment_clip(rig, path, name, f_start, f_end, out_fps, dur=None, extra=None, turn=0.0):
    src = Source(path)
    src.face_at(f_start)
    if turn:
        src.A = Quaternion((0, 0, 1), math.radians(turn)) @ src.A
        src._cache = {}
    tgt = Target(rig)
    scale = tgt.hip_h / src.hip_height()
    dur = dur or (f_end - f_start) / SRC_FPS
    n = max(8, int(round(dur * out_fps)))
    frames = [f_start + (f_end - f_start) * i / n for i in range(n + 1)]
    act, n_out = bake(rig, src, name, frames, out_fps, scale, in_place=True, extra=extra)
    src.remove()
    return act, n_out


def analyse(path, joint="RightHand"):
    """Speed of a joint (forward component) per frame — to find thrusts in fight takes."""
    src = Source(path)
    out = []
    prev = None
    for f in range(2, src.n, 2):
        src.face_at(f)
        P = src.pose(f)
        rel = P["pos"][joint] - P["pos"]["Hips"]
        if prev is not None:
            out.append((f, -(rel.y - prev.y) * SRC_FPS / 2, rel.length))
        prev = rel
    src.remove()
    return out
