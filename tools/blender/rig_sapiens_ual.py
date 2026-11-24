"""The Homo sapiens man on the Universal Animation Library skeleton (Quaternius, CC0), with its motion-captured
clips, a forearm twist bone and the swinging skirt bones.

  .../python3.13 tools/blender/rig_sapiens_ual.py UAL1.glb UAL2.glb OLD.gltf BODY.gltf AN_DIR OUT.gltf

UAL1/UAL2   the libraries' Godot / Unreal-Godot .glb (same rig, same rest; UAL1 uses Rigify DEF- names)
OLD.gltf    the earlier SapiensM (MPFB rig): its rest and pose P place the joints on the body
BODY.gltf   the body already bound to the old rig by rig_sapiens.py (mesh, UVs, skin weights by bone name)
AN_DIR      folder with AN_SapiensM_combat.tres / _life.tres (old clips moved over where UAL has none)

The new skeleton keeps the UAL rest rotations (so the UAL clips play as recorded) with joint offsets fitted to
the body; the body is bound in a pose P' of it that matches the sculpt (as in rig_sapiens.py). Old clips are
moved over through the two fitted poses: both skeletons sit on the same body in P and P', so a bone's world
rotation carries over with the constant offset R_P^-1 R_P'. The walk is retimed to the game's walking speed;
the thrust's hit and the throw's release are measured and printed for world/human_npc.gd CLIP_TIMES.
"""
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path = [x for x in sys.path if os.path.abspath(x or ".") != HERE]   # tools/blender/inspect.py shadows the stdlib
import inspect  # noqa: E402,F401
import numpy as np  # noqa: E402
import numpy.ma  # noqa: E402,F401

sys.path.insert(0, HERE)
import rig_sapiens as rs                                     # noqa: E402

FPS = 30.0
WALK = 1.6                           # human_npc.gd WALK, m/s at playback rate 1
TWIST_AT = 0.55                      # forearm twist joint, fraction of the way elbow -> wrist
LOOPS = {"idle", "walk", "run", "alert", "sit", "combat_guard", "combat_strafe_l", "combat_strafe_r",
         "life_sleep", "life_work", "life_step"}
# game clip <- (library, UAL clip, in place)
UAL_CLIPS = {
    "idle": (1, "Idle_Loop", False), "walk": (1, "Walk_Loop", True), "run": (1, "Jog_Fwd_Loop", True),
    "alert": (1, "Sword_Idle", False), "gesture": (1, "Interact", False), "sit": (1, "Crouch_Idle_Loop", False),
    "death": (1, "Death01", False), "attack": (1, "Sword_Attack", False),
    "combat_guard": (1, "Sword_Idle", False), "combat_thrust": (1, "Sword_Attack", False),
    "combat_feint": (1, "Punch_Cross", False), "combat_throw": (2, "OverhandThrow", True),
    "combat_hit_l": (1, "Hit_Chest", False), "combat_hit_r": (1, "Hit_Head", False),
    "life_work": (1, "Fixing_Kneeling", False),
}
OLD_CLIPS = {"combat_strafe_l": ("combat", "strafe_l"), "combat_strafe_r": ("combat", "strafe_r"),
             "life_sleep": ("life", "sleep"), "life_step": ("life", "step")}
RENAME = {"root": "Root", "Head": "head"}


def ual1_name(n):
    """Rigify DEF- names of UAL1 -> the Unreal names of UAL2."""
    if n == "root":
        return "root"
    m = re.match(r"DEF-(.+?)\.([LR])$", n)
    side = ("_" + m.group(2).lower()) if m else ""
    base = m.group(1) if m else n[4:] if n.startswith("DEF-") else n
    table = {"shoulder": "clavicle", "upper_arm": "upperarm", "forearm": "lowerarm", "hand": "hand", "thigh": "thigh",
             "shin": "calf", "foot": "foot", "toe": "ball", "hips": "pelvis", "spine.001": "spine_01",
             "spine.002": "spine_02", "spine.003": "spine_03", "neck": "neck_01", "head": "Head"}
    if base in table:
        return table[base] + side
    f = re.match(r"(?:f_)?(index|middle|ring|pinky|thumb)\.0(\d)", base)
    if f:
        return f"{f.group(1)}_0{f.group(2)}{side}"
    return n


# ------------------------------------------------------------------------------------------ skeletons

class Skel:
    def __init__(self, names, parent, rest):          # rest: name -> 4x4 local
        self.names, self.parent, self.rest = names, parent, rest
        self.children = {n: [c for c in names if parent.get(c) == n] for n in names}

    def depth_order(self):
        def d(n):
            k = 0
            while self.parent.get(n):
                n, k = self.parent[n], k + 1
            return k
        return sorted(self.names, key=d)

    def globals(self, local):
        G = {}
        for n in self.depth_order():
            p = self.parent.get(n)
            G[n] = (G[p] if p else np.eye(4)) @ local[n]
        return G


def skel_from_gltf(j, rename=lambda n: n, drop=lambda n: False):
    joints = [i for i in j["skins"][0]["joints"] if not drop(j["nodes"][i]["name"])]
    par = {c: i for i, n in enumerate(j["nodes"]) for c in n.get("children", [])}
    name = {i: rename(j["nodes"][i]["name"]) for i in joints}
    parent = {name[i]: name.get(par.get(i)) for i in joints}
    rest = {name[i]: rs.local(j["nodes"][i]) for i in joints}
    return Skel([name[i] for i in joints], parent, rest), name


def quat_slerp_track(times, quats, t):
    k = np.searchsorted(times, t) - 1
    k = np.clip(k, 0, len(times) - 2) if len(times) > 1 else np.zeros_like(k)
    if len(times) == 1:
        return np.repeat(quats[:1], len(t), 0)
    t0, t1 = times[k], times[k + 1]
    u = np.clip((t - t0) / np.maximum(t1 - t0, 1e-9), 0, 1)[:, None]
    a, b = quats[k], quats[k + 1].copy()
    b[(a * b).sum(1) < 0] *= -1
    q = a * (1 - u) + b * u
    return q / np.linalg.norm(q, axis=1, keepdims=True)


def lerp_track(times, vals, t):
    return np.stack([np.interp(t, times, vals[:, c]) for c in range(vals.shape[1])], 1)


def qmat(q):
    return rs.quat_m(q)


def mquat(R):
    return np.array(rs.m_quat(R))


# ------------------------------------------------------------------------------------------ pose P'

def fit_pose(S, G_old, R_old_rest_g):
    """Pose P' of the new skeleton on the body: joints at the old fitted places, bones aimed at their child
    (minimal turn from the UAL rest), hand on from the forearm with the thumb forward."""
    Rg = S.globals(S.rest)
    aim = {"pelvis": "spine_01", "spine_01": "spine_02", "spine_02": "spine_03", "spine_03": "neck_01",
           "neck_01": "head", "thigh_l": "calf_l", "calf_l": "foot_l", "foot_l": "ball_l", "thigh_r": "calf_r",
           "calf_r": "foot_r", "foot_r": "ball_r"}
    for s in ("_l", "_r"):
        aim[f"clavicle{s}"] = f"upperarm{s}"
        aim[f"upperarm{s}"] = f"lowerarm{s}"
        aim[f"lowerarm{s}"] = f"hand{s}"
        for f in ("index", "middle", "ring", "pinky", "thumb"):
            aim[f"{f}_01{s}"] = f"{f}_02{s}"
            aim[f"{f}_02{s}"] = f"{f}_03{s}"

    def target(n):
        if n in G_old:
            return G_old[n][:3, 3].copy()
        if n.startswith("lowerarm_twist_01"):
            s = n[-2:]
            return (1 - TWIST_AT) * G_old["lowerarm" + s][:3, 3] + TWIST_AT * G_old["hand" + s][:3, 3]
        return None

    def offset(child, s):
        h = Rg["hand" + s]
        return h[:3, :3].T @ (Rg[child + s][:3, 3] - h[:3, 3])

    def thumb_angle(R_hand, s, axis):
        a = axis / np.linalg.norm(axis)
        th = R_hand @ offset("thumb_02", s)
        th = th - a * (th @ a)
        want = np.array([0.0, 0.0, 1.0]) - a * a[2]
        return math.atan2(np.cross(th, want) @ a, th @ want)

    G = {}
    for n in S.depth_order():
        p = S.parent.get(n)
        M = (G[p] if p else np.eye(4)) @ np.linalg.inv(Rg[p] if p else np.eye(4)) @ Rg[n]   # ride on the parent
        t = target(n)
        if t is not None:
            M[:3, 3] = t
        if n in aim and target(aim[n]) is not None:
            c = aim[n]
            M[:3, :3] = rs.rot_between(Rg[c][:3, 3] - Rg[n][:3, 3], target(c) - M[:3, 3]) @ Rg[n][:3, :3]
        s = n[-2:]
        if n in ("lowerarm_l", "lowerarm_r"):
            fore = target("hand" + s) - M[:3, 3]
            Rh = M[:3, :3] @ Rg[n][:3, :3].T @ Rg["hand" + s][:3, :3]
            Rh = rs.rot_between(Rh @ offset("middle_01", s), fore) @ Rh
            M[:3, :3] = rs.axis_rot(fore, 0.5 * thumb_angle(Rh, s, fore)) @ M[:3, :3]
        if n.startswith("hand_"):
            low = G["lowerarm" + s]
            fore = M[:3, 3] - low[:3, 3]
            Rh = low[:3, :3] @ Rg["lowerarm" + s][:3, :3].T @ Rg[n][:3, :3]
            Rh = rs.rot_between(Rh @ offset("middle_01", s), fore) @ Rh
            M[:3, :3] = rs.axis_rot(fore, thumb_angle(Rh, s, fore)) @ Rh
        G[n] = M
    return G


def build_skeleton(j2, old_skel, G_old):
    S, _ = skel_from_gltf(j2, rename=lambda n: RENAME.get(n, n), drop=lambda n: "leaf" in n)
    # forearm twist joint: lowerarm -> lowerarm_twist_01 -> hand, same orientation as the forearm
    for s in ("_l", "_r"):
        tw = "lowerarm_twist_01" + s
        S.names.insert(S.names.index("hand" + s), tw)
        S.parent[tw] = "lowerarm" + s
        S.parent["hand" + s] = tw
        L = np.eye(4)
        L[:3, 3] = S.rest["hand" + s][:3, 3] * TWIST_AT
        S.rest[tw] = L
        S.rest["hand" + s] = S.rest["hand" + s].copy()
        S.rest["hand" + s][:3, 3] *= (1 - TWIST_AT)
    # the skirt chains, hanging from the pelvis as on the old rig
    for n in old_skel.names:
        if n.startswith("skirt_"):
            S.names.append(n)
            S.parent[n] = "pelvis" if n.endswith("_1") else n[:-1] + "1"
            S.rest[n] = np.eye(4)
    S.children = {n: [c for c in S.names if S.parent.get(c) == n] for n in S.names}
    P = fit_pose(S, G_old, None)
    for n in S.names:
        if n.startswith("skirt_"):
            P[n] = G_old[n].copy()
    # rest: UAL rotations (twist and skirt: their place in P'), offsets fitted to the body
    for n in S.names:
        p = S.parent.get(n)
        Lp = np.linalg.inv(P[p]) @ P[n] if p else P[n]
        L = S.rest[n].copy()
        if n.startswith("skirt_") or n.startswith("lowerarm_twist"):
            L[:3, :3] = Lp[:3, :3] if n.startswith("skirt_") else np.eye(3)
        if p:
            L[:3, 3] = Lp[:3, 3]
        S.rest[n] = L
    return S, P


# ------------------------------------------------------------------------------------------ clips

def gltf_clips(j, bins, rename):
    out = {}
    for an in j.get("animations", []):
        tracks = {}
        for c in an["channels"]:
            node = j["nodes"][c["target"]["node"]]["name"]
            s = an["samplers"][c["sampler"]]
            t = rs.acc(j, bins, s["input"]).reshape(-1).astype(float)
            v = rs.acc(j, bins, s["output"]).astype(float)
            tracks.setdefault(rename(node), {})[c["target"]["path"]] = (t, v)
        out[an["name"]] = tracks
    return out


def tres_clips(path):
    """Animations of a Godot AnimationLibrary .tres: name -> {bone: {"rotation"/"translation": (t, v)}}, length."""
    txt = open(path).read()
    out = {}
    for block in txt.split("[sub_resource")[1:]:
        name = re.search(r'resource_name = "([^"]+)"', block).group(1)
        length = float(re.search(r"length = ([0-9.]+)", block).group(1))
        tracks = {}
        for m in re.finditer(r'tracks/(\d+)/type = "(\w+)".*?tracks/\1/path = NodePath\("[^:]+:([^"]+)"\).*?'
                             r'tracks/\1/keys = PackedFloat32Array\(([^)]*)\)', block, re.S):
            kind, bone, keys = m.group(2), m.group(3), np.array([float(x) for x in m.group(4).split(",")])
            n = 4 if kind == "rotation_3d" else 3
            keys = keys.reshape(-1, 2 + n)
            path = "rotation" if kind == "rotation_3d" else "translation"
            tracks.setdefault(bone, {})[path] = (keys[:, 0], keys[:, 2:])
        out[name] = (tracks, length)
    return out


def sample_locals(S, tracks, t, use_pos=("Root", "pelvis")):
    """Local 4x4 per bone per time (bones without a key keep their rest)."""
    L = {}
    for n in S.names:
        M = np.repeat(S.rest[n][None], len(t), 0)
        tr = tracks.get(n, {})
        if "rotation" in tr:
            q = quat_slerp_track(*tr["rotation"], t)
            M[:, :3, :3] = np.stack([qmat(x) for x in q])
        if "translation" in tr and n in use_pos:
            M[:, :3, 3] = lerp_track(*tr["translation"], t)
        L[n] = M
    return L


def fk(S, L):
    G = {}
    for n in S.depth_order():
        p = S.parent.get(n)
        G[n] = L[n] if not p else np.einsum("tij,tjk->tik", G[p], L[n])
    return G


def ual_clip(S, ual_rest_pelvis_y, new_pelvis_y, tracks, in_place):
    """A UAL clip on the new skeleton: rotations as recorded, the root and hips carried at our height."""
    k = new_pelvis_y / ual_rest_pelvis_y
    out = {}
    for n, tr in tracks.items():
        if n not in S.rest:
            continue
        o = {}
        if "rotation" in tr:
            o["rotation"] = tr["rotation"]
        if "translation" in tr and n in ("Root", "pelvis"):
            t, v = tr["translation"]
            v = v * k if n == "Root" else S.rest[n][:3, 3] + (v - v_rest[n]) * k
            o["translation"] = (t, v)
        out[n] = o
    if in_place and "Root" in out and "translation" in out["Root"]:
        t, v = out["Root"]["translation"]
        v = v.copy()
        v[:, 0] = v[0, 0]
        v[:, 2] = v[0, 2]
        out["Root"]["translation"] = (t, v)
    return out


v_rest = {}


def moved_clip(S_old, S_new, P_old, P_new, tracks, length):
    """An old-rig clip on the new skeleton, through the two poses that fit the same body."""
    t = np.arange(0.0, length + 1e-6, 1.0 / FPS)
    if len(t) < 2:
        t = np.array([0.0, max(length, 1.0 / FPS)])
    G = fk(S_old, sample_locals(S_old, tracks, t))
    C = {n: P_old[n][:3, :3].T @ P_new[n][:3, :3] for n in S_new.names if n in P_old}
    W = {}
    for n in S_new.depth_order():
        p = S_new.parent.get(n)
        if n in G and n in C:
            W[n] = np.einsum("tij,jk->tik", G[n][:, :3, :3], C[n])
        else:                                                # twist / skirt: ride on the parent as at rest
            W[n] = np.einsum("tij,jk->tik", W[p], S_new.rest[n][:3, :3])
    out = {}
    for n in S_new.names:
        p = S_new.parent.get(n)
        R = W[n] if not p else np.einsum("tji,tjk->tik", W[p], W[n])
        if n.startswith("skirt_") or n.startswith("lowerarm_twist"):
            continue
        out[n] = {"rotation": (t, np.stack([mquat(r) for r in R]))}
    out["Root"]["translation"] = (t, G["Root"][:, :3, 3])
    root = np.repeat(np.eye(4)[None], len(t), 0)
    root[:, :3, :3] = W["Root"]
    root[:, :3, 3] = G["Root"][:, :3, 3]
    pel = np.einsum("tij,tj->ti", np.linalg.inv(root), np.c_[G["pelvis"][:, :3, 3], np.ones(len(t))])[:, :3]
    out["pelvis"]["translation"] = (t, pel)
    return out


def retime(clip, f):
    return {n: {k: (t * f, v) for k, (t, v) in tr.items()} for n, tr in clip.items()}


def clip_len(clip):
    return max(float(t[-1]) for tr in clip.values() for t, _ in tr.values())


def sample_globals(S, clip, fps=60.0):
    T = clip_len(clip)
    t = np.arange(0.0, T + 1e-6, 1.0 / fps)
    return t, fk(S, sample_locals(S, clip, t))


def stride_speed(S, clip):
    """How fast the planted foot slides back under an in-place loop (m/s)."""
    t, G = sample_globals(S, clip)
    sp = []
    for s in ("_l", "_r"):
        p = G["ball" + s][:, :3, 3]
        v = np.gradient(p[:, 2], t)
        low = p[:, 1] < p[:, 1].min() + 0.03
        sp.append(-v[low])
    v = np.concatenate(sp)
    return float(np.median(v[v > 0])) if (v > 0).any() else 0.0


def hand_peak(S, clip, how):
    t, G = sample_globals(S, clip)
    z = G["hand_r"][:, 2, 3] - G["pelvis"][:, 2, 3]
    if how == "reach":
        return float(t[np.argmax(z)])
    v = np.gradient(G["hand_r"][:, 2, 3], t)
    return float(t[np.argmax(v)])


# ------------------------------------------------------------------------------------------ main

def main():
    a = sys.argv[1:]
    j1, b1 = rs.load(a[0])
    j2, b2 = rs.load(a[1])
    jo, bo = rs.load(a[2])
    jb, bb = rs.load(a[3])
    an_dir, out_path = a[4], a[5]

    # the old rig, fitted to the body (pose P) and at rest
    G_P, rg, par, joints, names = rs.build_pose(jo)
    S_old, _ = skel_from_gltf(jo)
    P_old = {names[i]: G_P[i] for i in joints}

    S, P = build_skeleton(j2, S_old, P_old)
    Rg_ual, _ = skel_from_gltf(j2, rename=lambda n: RENAME.get(n, n), drop=lambda n: "leaf" in n)
    for n in ("Root", "pelvis"):
        v_rest[n] = Rg_ual.rest[n][:3, 3]
    ual_pelvis_y = Rg_ual.globals(Rg_ual.rest)["pelvis"][1, 3]
    new_pelvis_y = P["pelvis"][1, 3]

    # clips
    lib1 = gltf_clips(j1, b1, lambda n: RENAME.get(ual1_name(n), ual1_name(n)))
    lib2 = gltf_clips(j2, b2, lambda n: RENAME.get(n, n))
    clips = {}
    for game, (lib, src, in_place) in UAL_CLIPS.items():
        clips[game] = ual_clip(S, ual_pelvis_y, new_pelvis_y, (lib1 if lib == 1 else lib2)[src], in_place)
    old = {k: tres_clips(os.path.join(an_dir, f"AN_SapiensM_{k}.tres")) for k in ("combat", "life")}
    for game, (lib, src) in OLD_CLIPS.items():
        tracks, length = old[lib][src]
        clips[game] = moved_clip(S_old, S, P_old, P, tracks, length)

    report = {}
    # the walk is matched to the game's walking speed; the library's jog is stylised (a long flight, a very
    # short contact), matched to its foot it would play in slow motion, so it keeps its own cadence
    v = stride_speed(S, clips["walk"])
    clips["walk"] = retime(clips["walk"], v / WALK)
    report["walk"] = f"stride {v:.2f} m/s -> x{WALK / v:.2f} speed, {clip_len(clips['walk']):.2f} s"
    report["run"] = f"stride {stride_speed(S, clips['run']):.2f} m/s, kept at {clip_len(clips['run']):.2f} s"
    for game, how in (("combat_thrust", "reach"), ("combat_throw", "release")):
        report[game] = f"{how} at {hand_peak(S, clips[game], how):.2f} s of {clip_len(clips[game]):.2f} s"

    # body: same mesh, weights moved over by bone name, forearm split with the twist joint
    pr = jb["meshes"][0]["primitives"][0]
    A = pr["attributes"]
    Pv = rs.acc(jb, bb, A["POSITION"]).astype(np.float32)
    Nv = rs.acc(jb, bb, A["NORMAL"]).astype(np.float32)
    UV = rs.acc(jb, bb, A["TEXCOORD_0"]).astype(np.float32)
    Tri = rs.acc(jb, bb, pr["indices"]).reshape(-1).astype(np.uint32)
    Jo = rs.acc(jb, bb, A["JOINTS_0"]).astype(int)
    Wo = rs.acc(jb, bb, A["WEIGHTS_0"]).astype(float)
    bnames = [jb["nodes"][i]["name"] for i in jb["skins"][0]["joints"]]
    idx = {n: k for k, n in enumerate(S.names)}
    W = np.zeros((len(Pv), len(S.names)))
    for c in range(4):
        tgt = np.array([idx.get(RENAME.get(bnames[x], bnames[x]), idx["pelvis"]) for x in Jo[:, c]])
        np.add.at(W, (np.arange(len(Pv)), tgt), Wo[:, c])
    # the sculpted hand is one closed fist with no separate fingers to bind: it moves whole with the hand bone
    for n in S.names:
        if n.startswith(("index", "middle", "ring", "pinky", "thumb")):
            h = idx["hand" + n[-2:]]
            W[:, h] += W[:, idx[n]]
            W[:, idx[n]] = 0.0
    for s in ("_l", "_r"):
        lo, hand = P["lowerarm" + s][:3, 3], P["hand" + s][:3, 3]
        u = np.clip(((Pv - lo) @ (hand - lo)) / ((hand - lo) @ (hand - lo)), 0, 1)
        share = np.clip((u - 0.25) / 0.65, 0, 1) ** 1.2
        k_lo, k_tw = idx["lowerarm" + s], idx["lowerarm_twist_01" + s]
        moved = W[:, k_lo] * share
        W[:, k_lo] -= moved
        W[:, k_tw] += moved
    Jw, Ww = rs.top4(W)

    # write
    o = rs.Out()
    anims = []
    node_of = {n: k + 1 for k, n in enumerate(S.names)}           # node 0 is the armature
    for game, clip in clips.items():
        samplers, chans = [], []
        for n, tr in clip.items():
            for path, (t, v) in tr.items():
                typ = "VEC4" if path == "rotation" else "VEC3"
                samplers.append({"input": o.add(t.astype(np.float32), "SCALAR", minmax=True),
                                 "output": o.add(v.astype(np.float32), typ), "interpolation": "LINEAR"})
                chans.append({"sampler": len(samplers) - 1, "target": {"node": node_of[n], "path": path}})
        anims.append({"name": game, "samplers": samplers, "channels": chans})
    nodes = [{"name": "Human.rig", "children": [node_of["Root"]]}]
    for n in S.names:
        L = S.rest[n]
        nd = {"name": n, "translation": L[:3, 3].tolist(), "rotation": rs.m_quat(L[:3, :3])}
        ch = [node_of[c] for c in S.children[n]]
        if ch:
            nd["children"] = ch
        nodes.append(nd)
    nodes.append({"name": "Body", "mesh": 0, "skin": 0})
    nodes[0]["children"].append(len(nodes) - 1)
    ibm = np.stack([np.linalg.inv(P[n]).T.reshape(-1) for n in S.names]).astype(np.float32)
    attrs = {"POSITION": o.add(Pv, "VEC3", 34962, minmax=True), "NORMAL": o.add(Nv, "VEC3", 34962),
             "TEXCOORD_0": o.add(UV, "VEC2", 34962), "JOINTS_0": o.add(Jw, "VEC4", 34962),
             "WEIGHTS_0": o.add(Ww, "VEC4", 34962)}
    gltf = {"asset": {"version": "2.0", "generator": "WILDBOUND rig_sapiens_ual.py"},
            "scene": 0, "scenes": [{"name": "Scene", "nodes": [0]}], "nodes": nodes,
            "skins": [{"name": "Human.rig", "joints": [node_of[n] for n in S.names],
                       "inverseBindMatrices": o.add(ibm.reshape(-1, 16), "MAT4")}],
            "animations": anims,
            "meshes": [{"name": "Body", "primitives": [{"attributes": attrs, "indices": o.add(Tri, "SCALAR", 34963),
                                                        "material": 0}]}],
            "materials": jb["materials"], "textures": jb["textures"], "samplers": jb["samplers"],
            "images": jb["images"], "accessors": o.accs, "bufferViews": o.views}
    base = os.path.splitext(os.path.basename(out_path))[0]
    gltf["buffers"] = [{"byteLength": len(o.buf), "uri": base + ".bin"}]
    open(os.path.join(os.path.dirname(os.path.abspath(out_path)), base + ".bin"), "wb").write(o.buf)
    json.dump(gltf, open(out_path, "w"), indent=1)
    print("UAL skeleton", len(S.names), "bones;", len(anims), "clips")
    for k, v in report.items():
        print("UAL timing", k, v)


if __name__ == "__main__":
    main()
