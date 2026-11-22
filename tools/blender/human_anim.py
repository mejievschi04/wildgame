# Human locomotion & action clips for the MPFB game_engine rig (characters face -Y, Z up).
# Legs are solved with 2-bone IK against explicit foot paths, so the stance foot stays planted at the
# game's movement speed (human_npc.gd: WALK 1.3 m/s, RUN 4.6 m/s): heel strike → foot flat → heel-off →
# toe-off → swing. Pelvis bob / sway / yaw / roll, counter-rotating chest, opposed arm swing with elbow
# bend, relaxed fingers (fist on the spear hand when fighting). Clips: idle, walk, run, alert, gesture,
# attack (spear thrust: guard → wind-up → lunge → recover), sit (squat by the fire), death.
import math
from mathutils import Vector, Quaternion
import gen_humans as gh

FPS = gh.FPS
X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)
WALK_V, RUN_V = 1.6, 4.6


def yz_ang(v):
    return math.degrees(math.atan2(v.z, v.y))


def rot_yz(v, deg):
    a = math.radians(deg)
    return Vector((v.x, v.y * math.cos(a) - v.z * math.sin(a), v.y * math.sin(a) + v.z * math.cos(a)))


def smooth(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


class Body:
    """Rest-pose measurements of one rig."""

    def __init__(self, rig):
        self.rig = rig
        B = rig.data.bones
        self.h = {n: B[n].head_local.copy() for n in B.keys()}
        self.t = {n: B[n].tail_local.copy() for n in B.keys()}
        self.leg = {}
        for s in ("l", "r"):
            hip, knee, ank, ball = self.h["thigh_" + s], self.h["calf_" + s], self.h["foot_" + s], self.h["ball_" + s]
            p = lambda v: Vector((0, v.y, v.z))
            self.leg[s] = {
                "hip": hip, "ankle": ank, "ball": ball,
                "L1": (p(knee) - p(hip)).length, "L2": (p(ank) - p(knee)).length,
                "thigh0": yz_ang(knee - hip), "calf0": yz_ang(ank - knee), "foot0": yz_ang(ball - ank),
            }
        self.fingers = self._finger_axes()

    def palm_normal(self, s):
        """Rest-pose palm normal (armature space), pointing out of the palm toward the body midline."""
        side = self.h["pinky_01_" + s] - self.h["index_01_" + s]
        d = (self.t["middle_01_" + s] - self.h["middle_01_" + s]).normalized()
        nrm = d.cross(side).normalized()
        if nrm.x * (-self.h["hand_" + s].x) < 0:
            nrm = -nrm
        return nrm

    def _finger_axes(self):
        out = {}
        for s in ("l", "r"):
            if "index_01_" + s not in self.h:
                continue
            side = self.h["pinky_01_" + s] - self.h["index_01_" + s]
            for f in ("index", "middle", "ring", "pinky", "thumb"):
                for i in (1, 2, 3):
                    n = f"{f}_{i:02d}_{s}"
                    if n not in self.h:
                        continue
                    d = (self.t[n] - self.h[n]).normalized()
                    nrm = d.cross(side).normalized()
                    if nrm.x * (-self.h["hand_" + s].x) < 0:    # palm faces the body
                        nrm = -nrm
                    out[n] = d.cross(nrm).normalized()            # +angle curls toward the palm
        return out

    def solve_leg(self, s, ankle_y, ankle_z, foot_deg, root):
        """Thigh / calf / foot rotations (deg about +X, armature space) putting the ankle at (y, z)."""
        L = self.leg[s]
        H = L["hip"] + Vector(root)
        dy, dz = ankle_y - H.y, ankle_z - H.z
        d = min(max(math.hypot(dy, dz), abs(L["L1"] - L["L2"]) + 1e-3), (L["L1"] + L["L2"]) * 0.999)
        a = math.degrees(math.acos((L["L1"] ** 2 + d * d - L["L2"] ** 2) / (2 * L["L1"] * d)))
        th = math.degrees(math.atan2(dz, dy))
        thigh = th - a                                            # knee bends forward (-Y)
        K = Vector((0, H.y + L["L1"] * math.cos(math.radians(thigh)), H.z + L["L1"] * math.sin(math.radians(thigh))))
        calf = math.degrees(math.atan2(ankle_z - K.z, ankle_y - K.y))
        thigh_rot = thigh - L["thigh0"]
        calf_rot = calf - L["calf0"] - thigh_rot
        foot_rot = (L["foot0"] + foot_deg) - L["foot0"] - thigh_rot - calf_rot
        return thigh_rot, calf_rot, foot_rot

    def planted(self, s, y_off, roll, lift=0.0):
        """Ankle (y, z) for a foot whose ball is at rest-ball + y_off; roll>0 lifts the heel around the ball."""
        L = self.leg[s]
        ball = Vector((0, L["ball"].y + y_off, L["ball"].z + lift))
        a = ball + rot_yz(Vector((0, L["ankle"].y - L["ball"].y, L["ankle"].z - L["ball"].z)), roll)
        return a.y, a.z


def skirt_follow(rig, rots):
    """Strip skirt follows the thighs in the baked clips: front strips are pushed by a thigh swinging
    forward, back strips by one swinging back (the game adds spring-bone inertia on top)."""
    if "skirt_0_1" not in rig.pose.bones:
        return
    th = {s: sum(d for ax, d in rots.get("thigh_" + s, []) if ax == X) for s in ("l", "r")}
    for k in range(8):
        ang = k / 8 * math.tau
        wl = 0.5 + 0.5 * math.sin(ang)                  # +X side = left leg
        sw = wl * th["l"] + (1 - wl) * th["r"]
        front, back = max(0.0, math.cos(ang)), max(0.0, -math.cos(ang))
        rot = 0.85 * (front * min(sw, 0.0) + back * max(sw, 0.0))
        side = 0.25 * abs(math.sin(ang)) * min(sw, 0.0)   # side strips open a little on a big stride
        rots[f"skirt_{k}_1"] = [(X, rot + side * 0.5)]
        rots[f"skirt_{k}_2"] = [(X, rot * 0.25)]


def key(rig, frame, rots, root=(0, 0, 0)):
    skirt_follow(rig, rots)
    for pb in rig.pose.bones:
        pb.rotation_mode = "QUATERNION"
    for bone, parts in rots.items():
        if bone not in rig.pose.bones:
            continue
        q = Quaternion()
        for axis, deg in parts:
            q = gh.pose_rot(rig, bone, axis, deg) @ q
        pb = rig.pose.bones[bone]
        pb.rotation_quaternion = q
        pb.keyframe_insert("rotation_quaternion", frame=frame)
    pv = rig.pose.bones["pelvis"]; pv.location = (0, 0, 0); pv.keyframe_insert("location", frame=frame)
    rt = rig.pose.bones["Root"]; rt.location = root; rt.keyframe_insert("location", frame=frame)


def add(r, bone, axis, deg):
    r.setdefault(bone, []).append((axis, deg))


def relaxed(b, r, fist_r=0.0, fist_l=0.0, elbow=0.0):
    """Arms hanging at the sides, elbows a little bent, fingers softly curled (fist_* 0..1)."""
    add(r, "upperarm_l", Y, gh.ARMS_DOWN * 0.95)
    add(r, "upperarm_r", Y, -gh.ARMS_DOWN * 0.95)
    for s in ("l", "r"):
        add(r, "lowerarm_" + s, X, 22 - elbow)                    # rest forearm is bent ~45°: open it to ~20°
    for n, ax in b.fingers.items():
        f = fist_r if n.endswith("_r") else fist_l
        base = 12 if n.startswith("thumb") else (14 + 6 * int(n.split("_")[1]))
        add(r, n, tuple(ax), base + f * (55 if not n.startswith("thumb") else 25))
    return r


def legs(b, r, root, left, right):
    """left/right = (ankle_y, ankle_z, foot_deg)."""
    for s, (ay, az, fd) in (("l", left), ("r", right)):
        t, c, f = b.solve_leg(s, ay, az, fd, root)
        add(r, "thigh_" + s, X, t); add(r, "calf_" + s, X, c); add(r, "foot_" + s, X, f)


def foot_path(b, s, u, duty, stride, lift, run=False):
    """Ankle (y, z, foot angle) at cycle phase u (0 = heel strike) for a foot moving at stride per cycle."""
    L = b.leg[s]
    y0 = L["ankle"].y
    if u < duty:                                                   # stance: planted, sliding back at body speed
        s_ = u / duty
        y_ball = -stride * duty / 2 + stride * duty * s_          # forward (-Y) at contact → behind at toe-off
        if run:
            roll = 30 * smooth((s_ - 0.55) / 0.45)
            strike = 0.0
        else:
            roll = 38 * smooth((s_ - 0.6) / 0.4)                  # heel-off → toe-off
            strike = -14 * (1 - smooth(s_ / 0.15))                # heel strike, toes up, then foot flat
        ay, az = b.planted(s, y_ball, roll)
        if strike < 0:
            ay, az = L["ankle"].y + y_ball, L["ankle"].z + 0.004
        return ay, az, (roll if roll > 0 else strike), roll
    s_ = (u - duty) / (1 - duty)                                    # swing
    y_back, y_front = stride * duty / 2, -stride * duty / 2
    yy = y_back + (y_front - y_back) * smooth(s_ ** (0.85 if not run else 0.75))
    if run:
        hz = lift * math.sin(math.pi * min(s_ / 0.75, 1.0)) ** 0.9   # heel kicks up behind, knee drives forward
        fd = 30 * (1 - smooth(s_ / 0.5)) - 8 * smooth((s_ - 0.6) / 0.4)
    else:
        hz = lift * math.sin(math.pi * s_) ** 1.3
        fd = 38 * (1 - smooth(s_ / 0.35)) - 14 * smooth((s_ - 0.55) / 0.45)
    return y0 + yy, L["ankle"].z + 0.03 * (1 - s_) + hz, fd, 0.0


def locomotion(rig, b, run):
    v = RUN_V if run else WALK_V
    T = 0.64 if run else 1.08
    duty = 0.36 if run else 0.61
    stride = v * T
    n = int(round(T * FPS))
    for f in range(n + 1):
        t = f / n
        w = t * math.tau
        r = relaxed(b, {}, elbow=(70 if run else 8), fist_r=(0.6 if run else 0.0), fist_l=(0.6 if run else 0.0))
        if run:
            rz = -0.05 - 0.035 * math.cos(2 * w)        # lowest at mid-stance (compression)
        else:
            rz = -0.012 - 0.018 * math.cos(2 * w)       # lowest at heel strike, highest at mid-stance
        rx = (0.012 if run else 0.02) * math.sin(w)     # sway over the stance leg
        root = (rx, 0.0, rz)
        feet = {}
        for s, off in (("l", 0.0), ("r", 0.5)):
            u = (t + off) % 1.0
            ay, az, fd, roll = foot_path(b, s, u, duty, stride, 0.32 if run else 0.11, run)
            feet[s] = (ay, az, fd)
            if roll > 0:
                add(r, "ball_" + s, X, -roll)           # toes stay on the ground during heel-off
        legs(b, r, root, feet["l"], feet["r"])
        lean = 11 if run else 3
        yaw = (8 if run else 6) * math.cos(w)
        add(r, "pelvis", Z, -yaw)                        # hip of the forward leg leads
        add(r, "pelvis", Y, -(2 if run else 3) * math.sin(w))
        add(r, "spine_01", X, lean * 0.5)
        add(r, "spine_02", X, lean * 0.3)
        add(r, "spine_02", Z, yaw * 0.6)
        add(r, "spine_03", Z, yaw * 0.6)                 # chest counter-rotates
        add(r, "spine_03", X, 1.5 * math.sin(2 * w))
        add(r, "neck_01", X, -lean * 0.5)
        add(r, "head", X, -lean * 0.3 + (1.5 if run else 1.0) * math.cos(2 * w))
        add(r, "head", Z, -yaw * 0.4)
        A = 42 if run else 17
        swing_l = A * math.cos(w)                        # left arm back when the left leg is forward
        for s, sw in (("l", swing_l), ("r", -swing_l)):
            add(r, "upperarm_" + s, X, sw + (-6 if run else 0))
            add(r, "lowerarm_" + s, X, -(18 if run else 6) * max(0.0, -sw / A))   # elbow folds on the forward swing
        add(r, "clavicle_l", X, swing_l * 0.08)
        add(r, "clavicle_r", X, -swing_l * 0.08)
        key(rig, f + 1, r, root)
    return n


def clip_idle(rig, b):
    n = 6 * FPS
    for f in range(0, n + 1, 3):
        t = f / n
        w = t * math.tau
        r = relaxed(b, {}, elbow=4)
        shift = math.sin(w)                              # weight shifts slowly from leg to leg
        root = (0.022 * shift, 0.0, -0.006 - 0.004 * abs(shift))
        L, R = b.leg["l"], b.leg["r"]
        legs(b, r, root, (L["ankle"].y - 0.04, L["ankle"].z, 0), (R["ankle"].y + 0.05, R["ankle"].z, 0))
        add(r, "pelvis", Y, -2.5 * shift)
        add(r, "spine_02", Y, 1.5 * shift)
        add(r, "spine_03", X, 1.2 * math.sin(w * 3))     # breathing
        add(r, "head", Z, 14 * math.sin(w * 0.5 + 0.7) * smooth(abs(math.sin(w * 0.5 + 0.7)) * 1.4))
        add(r, "head", X, -3 + 2 * math.sin(w * 1.5))
        add(r, "upperarm_l", X, 2 * math.sin(w + 0.4))
        add(r, "upperarm_r", X, -2 * math.sin(w + 0.4))
        key(rig, f + 1, r, root)
    return n


def guard(b, r, k=1.0):
    """Spear guard: knees soft, torso turned right, spear hand at the hip, lead hand forward."""
    add(r, "spine_02", Z, 14 * k); add(r, "spine_03", Z, 10 * k); add(r, "head", Z, -18 * k)
    add(r, "spine_01", X, 6 * k)
    add(r, "upperarm_r", X, -10 * k); add(r, "lowerarm_r", X, -55 * k)
    add(r, "upperarm_l", X, -45 * k); add(r, "lowerarm_l", X, -30 * k)
    return r


def clip_alert(rig, b):
    n = 3 * FPS
    for f in range(0, n + 1, 2):
        t = f / n
        w = t * math.tau
        r = relaxed(b, {}, fist_r=0.9, fist_l=0.3)
        guard(b, r, 0.8)
        root = (0, 0.02, -0.07)
        L, R = b.leg["l"], b.leg["r"]
        legs(b, r, root, (L["ankle"].y - 0.16, L["ankle"].z, 0), (R["ankle"].y + 0.14, R["ankle"].z, 0))
        add(r, "head", Z, 22 * math.sin(w))
        add(r, "neck_01", Z, 8 * math.sin(w))
        add(r, "spine_03", X, 1.5 * math.sin(w * 4))
        key(rig, f + 1, r, root)
    return n


def clip_attack(rig, b):
    """Spear thrust: guard → wind-up (weight back, twist) → lunge (step, untwist, both arms drive) → recover.
    The hit lands at ~0.55 s (human_npc.gd uses a 0.55 s wind-up)."""
    dur = 1.15
    n = int(dur * FPS)
    L, R = b.leg["l"], b.leg["r"]
    keys = [  # time, twist, arm drive (0 back … 1 extended), lunge (0 … 1), root
        (0.00, 1.0, 0.15, 0.0), (0.32, 1.5, 0.0, -0.25), (0.55, -0.8, 1.0, 1.0), (0.72, -0.9, 1.0, 1.0), (1.15, 1.0, 0.15, 0.0)]

    def interp(t):
        for i in range(len(keys) - 1):
            a, c = keys[i], keys[i + 1]
            if a[0] <= t <= c[0]:
                u = smooth((t - a[0]) / (c[0] - a[0]))
                return [a[j] + (c[j] - a[j]) * u for j in (1, 2, 3)]
        return list(keys[-1][1:])
    for f in range(n + 1):
        t = f / n * dur
        twist, drive, lunge = interp(t)
        r = relaxed(b, {}, fist_r=1.0, fist_l=0.8)
        root = (0.0, -0.22 * max(lunge, 0) + 0.06 * max(-lunge, 0) * 4 * 0.25, -0.06 - 0.06 * abs(lunge))
        step = -0.22 - 0.30 * max(lunge, 0)                     # lead (left) foot steps forward
        legs(b, r, root, (L["ankle"].y + step, L["ankle"].z, 0), (R["ankle"].y + 0.18 - 0.05 * max(lunge, 0), R["ankle"].z, 6 * max(lunge, 0)))
        add(r, "spine_02", Z, 12 * twist); add(r, "spine_03", Z, 10 * twist); add(r, "head", Z, -16 * twist)
        add(r, "pelvis", Z, 8 * twist)
        add(r, "spine_01", X, 6 + 10 * max(lunge, 0)); add(r, "spine_02", X, 4 * max(lunge, 0))
        add(r, "neck_01", X, -8 * max(lunge, 0))
        # spear hand: pulled back by the hip → driven forward at shoulder height
        add(r, "upperarm_r", X, 20 * (1 - drive) - 80 * drive); add(r, "lowerarm_r", X, -75 * (1 - drive) - 8 * drive)
        add(r, "upperarm_l", X, -40 - 30 * drive); add(r, "lowerarm_l", X, -40 + 25 * drive)
        add(r, "clavicle_r", X, -10 * drive)
        key(rig, f + 1, r, root)
    return n


def clip_gesture(rig, b):
    """Open palm raised and held: the peaceful sign."""
    n = int(1.8 * FPS)
    for f in range(n + 1):
        k = smooth(min(f / n / 0.35, 1.0)) * (1 - smooth((f / n - 0.75) / 0.25))
        r = relaxed(b, {}, elbow=4)
        add(r, "upperarm_r", Y, gh.ARMS_DOWN * 0.95 * k)
        add(r, "upperarm_r", X, -75 * k); add(r, "lowerarm_r", X, -55 * k); add(r, "hand_r", Y, 15 * k)
        add(r, "head", X, 5 * k); add(r, "spine_03", X, -2 * k)
        L, R = b.leg["l"], b.leg["r"]
        legs(b, r, (0, 0, -0.005), (L["ankle"].y, L["ankle"].z, 0), (R["ankle"].y + 0.03, R["ankle"].z, 0))
        key(rig, f + 1, r, (0, 0, -0.005))
    return n


def clip_sit(rig, b):
    """Deep squat by the fire, forearms resting on the knees."""
    n = 4 * FPS
    for f in range(0, n + 1, 4):
        w = f / n * math.tau
        r = relaxed(b, {}, elbow=25, fist_r=0.2, fist_l=0.2)
        root = (0, 0.12, -0.50)
        L, R = b.leg["l"], b.leg["r"]
        legs(b, r, root, (L["ankle"].y - 0.06, L["ankle"].z + 0.01, 0), (R["ankle"].y - 0.06, R["ankle"].z + 0.01, 0))
        add(r, "spine_01", X, 28); add(r, "spine_02", X, 10)
        add(r, "neck_01", X, -18); add(r, "head", X, -12 + 2 * math.sin(w)); add(r, "head", Z, 6 * math.sin(w * 0.5))
        for s in ("l", "r"):
            add(r, "upperarm_" + s, X, -38); add(r, "lowerarm_" + s, X, -35)
        add(r, "spine_03", X, 1.2 * math.sin(w * 2))
        key(rig, f + 1, r, root)
    return n


def clip_death(rig, b):
    """Knees buckle, the body twists and falls onto its side and back."""
    n = int(1.5 * FPS)
    L, R = b.leg["l"], b.leg["r"]
    for f in range(n + 1):
        t = f / n
        k1 = smooth(t / 0.35)                    # buckle
        k2 = smooth((t - 0.25) / 0.6)            # fall
        r = relaxed(b, {}, elbow=10 + 30 * k2, fist_r=0.3, fist_l=0.3)
        rootz = -0.25 * k1 - 0.55 * k2
        if k2 < 0.3:
            legs(b, r, (0, 0.05 * k1, rootz), (L["ankle"].y, L["ankle"].z, 0), (R["ankle"].y + 0.05, R["ankle"].z, 0))
        else:
            add(r, "thigh_l", X, -35 * k2); add(r, "calf_l", X, 60 * k2)
            add(r, "thigh_r", X, -15 * k2); add(r, "calf_r", X, 25 * k2)
        add(r, "pelvis", X, -78 * k2)            # falls backward
        add(r, "pelvis", Y, 25 * k2)
        add(r, "spine_02", X, 15 * k1 - 10 * k2); add(r, "head", X, 20 * k1 - 25 * k2); add(r, "head", Z, 30 * k2)
        add(r, "upperarm_l", Y, 35 * k2); add(r, "upperarm_r", Y, -50 * k2); add(r, "upperarm_r", X, -30 * k2)
        key(rig, f + 1, r, (0.05 * k2, 0.25 * k2, rootz - 0.05 * k2))
    return n


MOCAP = "/".join(__file__.split("/")[:-3]) + "/art_source/mocap/"   # CMU Graphics Lab Motion Capture Database


def mocap_extra(rig, b, fist=0.6, wrist=10.0):
    """Per-frame additions to retargeted mocap: curled fingers (the CMU data has none) and the strip
    skirt following the thighs."""
    def f(u, local, W, tgt):
        for n, ax in b.fingers.items():
            base = 12 if n.startswith("thumb") else (14 + 6 * int(n.split("_")[1]))
            local[n] = gh.pose_rot(rig, n, tuple(ax), base + fist * (55 if not n.startswith("thumb") else 25))
        for sd in ("l", "r"):                                   # forearm roll: palm toward the body (thumb up)
            lo, up = "lowerarm_" + sd, "upperarm_" + sd
            if lo not in W or "middle_01_" + sd not in b.h:
                continue
            v_local = tgt.rest[lo].inverted() @ b.palm_normal(sd)
            axis = (W[lo] @ Vector((0, 1, 0))).normalized()
            n_w = W[lo] @ v_local
            want = Vector((-1.0 if sd == "l" else 1.0, 0, 0))
            want = want - axis * want.dot(axis)
            n_p = n_w - axis * n_w.dot(axis)
            if want.length < 0.2 or n_p.length < 1e-4:
                continue
            ang = math.atan2(axis.dot(n_p.cross(want)), n_p.dot(want.normalized()) * want.length / want.length)
            ang = max(-math.radians(110), min(math.radians(110), ang)) * min(1.0, (want.length - 0.2) / 0.3)
            Wn = Quaternion(axis, ang) @ W[lo]
            W[lo] = Wn
            local[lo] = tgt.rest[lo].inverted() @ tgt.rest[up] @ W[up].inverted() @ Wn
        for sd in ("l", "r"):                                   # firm wrist: slight extension (no limp drop)
            ax = b.fingers.get("middle_01_" + sd)
            if ax is not None and "hand_" + sd in rig.pose.bones:
                local["hand_" + sd] = gh.pose_rot(rig, "hand_" + sd, tuple(ax), -wrist)
        if "skirt_0_1" not in local:
            return
        rots = {}
        for s in ("l", "r"):
            t = "thigh_" + s
            d = W[t] @ Vector((0, 1, 0))
            r0 = tgt.rest[t] @ Vector((0, 1, 0))
            pitch = math.degrees(math.atan2(d.z, d.y)) - math.degrees(math.atan2(r0.z, r0.y))
            rots[t] = [(X, pitch)]
        skirt_follow(rig, rots)
        for k, parts in rots.items():
            if k.startswith("skirt_"):
                q = Quaternion()
                for ax, deg in parts:
                    q = gh.pose_rot(rig, k, ax, deg) @ q
                local[k] = q
    return f


def mocap_clips(rig, b):
    import mocap_retarget as mr
    out = {}
    out["walk"] = mr.cyclic_clip(rig, MOCAP + "08_01.bvh", "walk", WALK_V, FPS, 0.85, 1.4, extra=mocap_extra(rig, b, 0.15))
    out["run"] = mr.cyclic_clip(rig, MOCAP + "09_02.bvh", "run", RUN_V, FPS, 0.5, 0.85, extra=mocap_extra(rig, b, 0.45, 18.0))
    return out


def make_clips(rig):
    b = Body(rig)
    rig.animation_data_create()
    clips = {
        "idle": lambda: clip_idle(rig, b),
        "walk": lambda: locomotion(rig, b, False),
        "run": lambda: locomotion(rig, b, True),
        "alert": lambda: clip_alert(rig, b),
        "gesture": lambda: clip_gesture(rig, b),
        "attack": lambda: clip_attack(rig, b),
        "sit": lambda: clip_sit(rig, b),
        "death": lambda: clip_death(rig, b),
    }
    try:
        mc = mocap_clips(rig, b)
    except Exception as e:  # mocap files missing → procedural fallbacks
        print("MOCAP unavailable:", e)
        mc = {}
    for name, fn in clips.items():
        if name in mc:
            act, frames = mc[name]
            tr = rig.animation_data.nla_tracks.new(); tr.name = name
            st = tr.strips.new(name, 1, act); st.action_frame_end = frames + 1
            continue
        act = bpy_new_action(name)
        rig.animation_data.action = act
        for pb in rig.pose.bones:
            pb.rotation_mode = "QUATERNION"; pb.rotation_quaternion = Quaternion(); pb.location = (0, 0, 0)
        frames = fn()
        tr = rig.animation_data.nla_tracks.new(); tr.name = name
        st = tr.strips.new(name, 1, act); st.action_frame_end = frames + 1
        rig.animation_data.action = None
    return list(clips)


def bpy_new_action(name):
    import bpy
    return bpy.data.actions.new(name)
