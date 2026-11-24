"""Rig the Tripo wolf scan (a static textured mesh) with the rig-v2 skeleton and the wolf clips:
blender -b --factory-startup --python rig_wolf.py -- tripo_wolf.glb SK_Wolf_Textured.glb

1. orient (head along +Y), turn the body onto the axis (the scan stands at an angle) and centre each length slice;
2. scale to the wolf's height, feet on the ground, and set the paws into a neutral stance (the scan is mid-step);
3. joints from the mesh: the paws, the nose, the ear tips, the mouth opening and the tail's centre line; legs stand
   on their paws with a wolf's proportions (fauna_lib WOLF_J);
4. skin weights by distance to the bones, each leg kept to its own side and end of the body, the tail and the lower
   jaw kept to their own parts, smoothed along the surface;
5. the IK clips of gen_animals (timed to the game speeds) and a bite; the scan's own texture is kept.
"""
import math
import os
import sys
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fauna_lib as fl
import gen_animals as ga
from rig_mammoth import bump, components, ramp, smoothstep

REF = {k: np.array(v, float) for k, v in fl.complete_joints(ga.WOLF_J).items()}
REF_H = float(REF["ear_t.L"][2])                     # the reference wolf's ear-tip height


def load(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(path))
    body = next(o for o in bpy.context.scene.objects if o.type == "MESH")
    body.data.transform(body.matrix_world)
    body.parent = None
    body.matrix_world = Matrix.Identity(4)
    for o in list(bpy.context.scene.objects):
        if o is not body:
            bpy.data.objects.remove(o)
    body.data.transform(Matrix.Rotation(math.pi / 2, 4, "Z"))      # glTF +X head -> Blender +Y
    return body


def straighten(P):
    """Rotate the body onto the Y axis (fit through the topline slices), then centre every slice on x = 0."""
    H = P[:, 2].max()
    top = P[:, 2] > 0.55 * H
    ys, xs = [], []
    for y in np.linspace(P[:, 1].min(), P[:, 1].max(), 30):
        s = P[top & (np.abs(P[:, 1] - y) < 0.02)]
        if len(s) > 5:
            ys.append(y)
            xs.append((s[:, 0].min() + s[:, 0].max()) / 2)
    slope = np.polyfit(ys, xs, 1)[0]
    a = math.atan(slope)
    R = np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1]])
    P = P @ R.T
    ys, xs = [], []
    for y in np.linspace(P[:, 1].min(), P[:, 1].max(), 30):
        s = P[top & (np.abs(P[:, 1] - y) < 0.02)]
        if len(s) > 5:
            ys.append(y)
            xs.append((s[:, 0].min() + s[:, 0].max()) / 2)
    xs = np.convolve(np.pad(xs, 2, mode="edge"), np.ones(5) / 5, mode="valid")
    P[:, 0] -= np.interp(P[:, 1], ys, xs)
    print(f"Wolf: body turned {math.degrees(a):.1f} deg onto the axis")
    return P


def feet(P, s):
    low = P[P[:, 2] < 0.04 * s]
    mid_y = (low[:, 1].min() + low[:, 1].max()) / 2
    out = {}
    for name, front, sx in (("fh.L", True, 1), ("fh.R", True, -1), ("hh.L", False, 1), ("hh.R", False, -1)):
        m = low[((low[:, 1] > mid_y) == front) & (np.sign(low[:, 0]) == sx)]
        out[name] = m.mean(0)
    return out


def neutral_stance(P, F, s):
    """The scan is mid-step: move each paw (and its leg, fading out towards the body) to the mean position of
    its pair, so the legs stand square and the gait cycles about a neutral pose."""
    for leg, top in (("fh", 0.45), ("hh", 0.42)):
        L, R = F[f"{leg}.L"], F[f"{leg}.R"]
        y = (L[1] + R[1]) / 2
        w = (abs(L[0]) + abs(R[0])) / 2
        for side, sx in (("L", 1), ("R", -1)):
            f = F[f"{leg}.{side}"]
            d = np.array((sx * w - f[0], y - f[1], 0.0))
            near = np.linalg.norm(P[:, :2] - f[:2], axis=1)
            member = (1 - smoothstep(0.10 * s, 0.16 * s, near)) * (np.sign(P[:, 0]) == sx)
            fall = 1 - smoothstep(0.0, top * s * 1.6, P[:, 2])
            P += np.outer(member * fall, d)
            F[f"{leg}.{side}"] = f + d
    return P


def surface_samples(P, tris, per_m2=60000, seed=3):
    """Points spread over the surface (the scan's legs are a few long triangles: vertices alone leave gaps)."""
    a, b, c = P[tris[:, 0]], P[tris[:, 1]], P[tris[:, 2]]
    area = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    rng = np.random.default_rng(seed)
    n = rng.poisson(area * per_m2) + 1
    idx = np.repeat(np.arange(len(tris)), n)
    u, v = rng.random(len(idx)), rng.random(len(idx))
    flip = u + v > 1
    u[flip], v[flip] = 1 - u[flip], 1 - v[flip]
    return a[idx] + (b[idx] - a[idx]) * u[:, None] + (c[idx] - a[idx]) * v[:, None]


def leg_path(Q, foot, sx, s):
    """The centre line of a leg from the paw up, until its slice merges into the body: [(x, y, z), ...].
    Q: surface samples."""
    side = Q[np.sign(Q[:, 0]) == sx]
    cur = foot[:2].copy()
    path, misses = [], 0
    z = 0.06 * s                                          # above the paw (the toes reach forward)
    while z < 0.62 * s and misses < 4:
        sl = side[(np.abs(side[:, 2] - z) < 0.01 * s) & (np.linalg.norm(side[:, :2] - cur, axis=1) < 0.08 * s)]
        z += 0.01 * s
        if len(sl) < 8:
            misses += 1
            continue
        misses = 0
        if np.ptp(sl[:, 1]) > 0.17 * s or np.ptp(sl[:, 0]) > 0.13 * s:
            break                                         # into the chest / the haunch
        c = (sl[:, :2].min(0) + sl[:, :2].max(0)) / 2     # middle of the cross-section
        cur = 0.5 * cur + 0.5 * c
        path.append((cur[0], cur[1], z))
    return np.array(path)


def joints(P, F, s, Q):
    """Leg joints at the middle of each leg's cross-section at a wolf's joint heights (elbow, wrist, stifle,
    hock); the shoulder and the hip go up into the body above the top of the leg."""
    J = {}
    for side, sx in (("L", 1), ("R", -1)):
        for foot_key, chain in (("fh", ("ca", "el", "sh")), ("hh", ("ho", "st", "hp"))):
            foot = F[f"{foot_key}.{side}"]
            path = leg_path(Q, foot, sx, s)
            # the paw: the ankle joint at the back of the paw just off the ground, the toe at the paw's front edge
            paw = Q[(np.sign(Q[:, 0]) == sx) & (Q[:, 2] < 0.05 * s) & (np.linalg.norm(Q[:, :2] - foot[:2], axis=1) < 0.09 * s)]
            heel = path[0] if len(path) else foot
            J[f"{foot_key}.{side}"] = np.array((heel[0], heel[1], REF[f"{foot_key}.L"][2] * s + 0.02 * s))
            front_y = np.percentile(paw[:, 1], 95) if len(paw) else foot[1] + 0.05 * s
            J[f"toe_{'f' if foot_key == 'fh' else 'h'}.{side}"] = np.array((heel[0], front_y - 0.01 * s, 0.02 * s))
            top = path[-1] if len(path) else np.array((foot[0], foot[1], 0.3 * s))
            for name in chain[:2]:
                zj = REF[f"{name}.L"][2] * s
                if len(path) and zj <= path[-1][2]:
                    q = path[np.argmin(np.abs(path[:, 2] - zj))]
                else:   # above the free leg: follow the leg's last direction up into the body
                    q = top + (top - path[max(0, len(path) - 8)]) / max(top[2] - path[max(0, len(path) - 8)][2], 1e-6) \
                        * (zj - top[2]) if len(path) > 8 else np.array((top[0], top[1], zj))
                J[f"{name}.{side}"] = np.array((q[0], q[1], zj))
            upper = chain[2]
            below = J[f"{chain[1]}.{side}"]
            r = REF[f"{upper}.L"] - REF[f"{chain[1]}.L"]
            # the shoulder / hip joint sits in the body, a little in from the leg and above it
            J[f"{upper}.{side}"] = np.array((below[0] * 0.8, below[1] + r[1] * s, REF[f"{upper}.L"][2] * s))
            print(f"Wolf leg {foot_key}.{side}: tracked to z {top[2]:.2f} ({len(path)} slices)")
    fy = (F["fh.L"][1] + F["fh.R"][1]) / 2
    hy = (F["hh.L"][1] + F["hh.R"][1]) / 2
    H = P[:, 2].max()
    mid = np.abs(P[:, 0]) < 0.05 * s
    head_pts = P[mid & (P[:, 2] > 0.55 * H)]
    nose = head_pts[np.argmax(head_pts[:, 1])]
    J["nose"] = np.array((0.0, nose[1] - 0.012 * s, nose[2] - 0.01 * s))
    for k in ("head", "neck2"):
        J[k] = J["nose"] + (REF[k] - REF["nose"]) * s
    J["chest"] = np.array((0.0, fy + (REF["chest"][1] - REF["fh.L"][1]) * s, REF["chest"][2] * s))
    J["hips"] = np.array((0.0, hy + (REF["hips"][1] - REF["hh.L"][1]) * s, REF["hips"][2] * s))
    J["spine"] = (J["chest"] + J["hips"]) / 2 + np.array((0, 0, -0.01 * s))
    J["neck"] = (J["chest"] + J["neck2"]) / 2 + np.array((0, 0, 0.02 * s))
    # ears: the highest points either side of the skull
    skull = P[(P[:, 1] > J["neck2"][1]) & (P[:, 2] > J["head"][2])]
    for side, sx in (("L", 1), ("R", -1)):
        sel = skull[np.sign(skull[:, 0]) == sx]
        tip = sel[np.argmax(sel[:, 2])]
        J[f"ear_t.{side}"] = tip
        J[f"ear.{side}"] = tip + (REF["ear.L"] - REF["ear_t.L"]) * s * np.array((sx, 1, 1))
    # the mouth: seen from the corner of the mouth the open jaws leave an empty wedge (the scan snarls). The
    # lower jaw is everything in the snout below it; close_mouth() turns it up about the hinge.
    hinge = np.array((0.0, J["head"][1] - 0.035 * s, J["head"][2] - 0.05 * s))
    snout = (np.abs(P[:, 0]) < 0.05 * s) & (P[:, 1] > hinge[1] + 0.03 * s)
    th = np.degrees(np.arctan2(P[:, 2] - hinge[2], P[:, 1] - hinge[1]))
    r = np.hypot(P[:, 2] - hinge[2], P[:, 1] - hinge[1])
    near = snout & (r > 0.05 * s) & (r < 0.35 * s)
    hist, edges = np.histogram(th[near], bins=np.arange(-45, 6, 2))
    lo, hi = np.argmax(hist[:10]), 10 + np.argmax(hist[10:])     # lower jaw / upper jaw clusters
    gap_bin = lo + int(np.argmin(hist[lo:hi + 1]))
    gap = (edges[gap_bin] + edges[gap_bin + 1]) / 2
    opening = (edges[hi] - edges[lo]) * 0.85                    # lip line to lip line, a little short of it
    J["jaw"] = hinge
    J["jaw_t"] = J["nose"] + np.array((0.0, -0.04 * s, -0.045 * s))
    mouth = {"hinge": hinge, "gap": gap, "opening": opening}
    # tail: behind the buttocks, off the hind legs; its centre line in five stations from root to tip
    # the back of the buttocks: a wolf's tail root sits about 12 cm behind the hip joint (the topline itself
    # runs on into the raised tail, so it can't be measured from the back of the mesh)
    rear = J["hips"][1] + (REF["tail"][1] - REF["hips"][1]) * s
    legs_x = (abs(F["hh.L"][0]) + abs(F["hh.R"][0])) / 2
    tail = P[(P[:, 1] < rear + 0.03 * s) & ~((np.abs(np.abs(P[:, 0]) - legs_x) < 0.06 * s) & (P[:, 2] < 0.45 * s))
             & (P[:, 2] > 0.1 * s)]
    order = np.argsort(-tail[:, 1])
    chunks = np.array_split(tail[order], 5)
    for name, c in zip(("tail", "tq1", "tail2", "tq3", "tail3"), chunks):
        J[name] = c.mean(0)
    J["tail"] = np.array((0.0, rear + 0.01 * s, J["hips"][2] - 0.03 * s))
    J = {k: np.array(v, float) for k, v in fl.complete_joints({k: tuple(v) for k, v in J.items()}).items()}
    return J, mouth, rear


def jaw_mask(P, mouth, s):
    """0..1 per vertex: how much it belongs to the lower jaw (below the gap, in front of the hinge; the cheek
    near the hinge and the throat under it stay with the head)."""
    h = mouth["hinge"]
    dy, dz = P[:, 1] - h[1], P[:, 2] - h[2]
    th = np.degrees(np.arctan2(dz, dy))
    r = np.hypot(dy, dz)
    m = smoothstep(mouth["gap"] + 1.5, mouth["gap"] - 6.0, th)        # below the gap
    m *= smoothstep(-80.0, -60.0, th)                                  # not the throat straight under the hinge
    # fades out over the cheek towards the hinge (a hard edge there tears the corner of the mouth)
    m *= smoothstep(0.02 * s, 0.11 * s, r) * smoothstep(-0.01 * s, 0.05 * s, dy)
    m *= 1 - smoothstep(0.07 * s, 0.13 * s, np.abs(P[:, 0]))           # the snout, not the neck ruff
    return m


def close_mouth(P, mouth, s):
    """Turn the lower jaw up about the hinge (an axis across the head) by the opening angle."""
    m = jaw_mask(P, mouth, s)
    h = mouth["hinge"]
    # the last few degrees are the rig's: a jaw with a real mouth rests at fl.JAW_REST (shut a little more)
    a = np.radians(mouth["opening"] - fl.JAW_REST) * m
    dy, dz = P[:, 1] - h[1], P[:, 2] - h[2]
    P = P.copy()
    P[:, 1] = h[1] + dy * np.cos(a) - dz * np.sin(a)
    P[:, 2] = h[2] + dy * np.sin(a) + dz * np.cos(a)
    print(f"Wolf: mouth closed by {mouth['opening']:.0f} deg (mesh {mouth['opening'] - fl.JAW_REST:.0f}, "
          f"rig rest {fl.JAW_REST:.0f}; gap at {mouth['gap']:.0f} deg)")
    return P, m


def bind(body, P, rig, sp, J, mouth, rear, s, jaw):
    _, first, index = np.unique(P.round(5), axis=0, return_index=True, return_inverse=True)
    p = P[first]
    edges = np.empty(len(body.data.edges) * 2, dtype=np.int32)
    body.data.edges.foreach_get("vertices", edges)
    edges = np.unique(np.sort(index[edges.reshape(-1, 2)], axis=1), axis=0)
    a, b = edges[edges[:, 0] != edges[:, 1]].T
    x, y, z = p.T
    H = z.max()
    legs_x = (abs(J["hh.L"][0]) + abs(J["hh.R"][0])) / 2
    tail = ((y < rear + 0.02 * s) & ~((np.abs(np.abs(x) - legs_x) < 0.06 * s) & (z < 0.45 * s))
            & (z > 0.1 * s)).astype(float)
    tail = tail * smoothstep(rear + 0.03 * s, rear - 0.03 * s, y)
    head = smoothstep(J["neck2"][1] - 0.03 * s, J["neck2"][1] + 0.03 * s, y)
    jaw = jaw[first]
    leg = 1 - smoothstep(0.40 * s, 0.58 * s, z)
    mid_y = (J["sh.L"][1] + J["hp.L"][1]) / 2
    weights, groups = [], []
    for name, start, end, _ in fl.bone_table(sp):
        h0, t0 = J[start], J[end]
        axis = t0 - h0
        t = np.clip((p - h0) @ axis / max(axis @ axis, 1e-9), 0, 1)
        d2 = np.sum((p - h0 - t[:, None] * axis) ** 2, axis=1)
        width = 0.09 * s
        if name.startswith("tail") or name.startswith("tq"):
            gate, width = tail, 0.07 * s
        elif name == "jaw":
            gate, width = jaw, 0.08 * s
        elif name.startswith("ear."):
            side = 1 if name.endswith(".L") else -1
            gate = head * smoothstep(J["head"][2], J["head"][2] + 0.04 * s, z) * (np.sign(x) == side)
            width = 0.04 * s
        elif "." in name:
            side = 1 if name.endswith(".L") else -1
            front = name.startswith(("scapula", "upperarm", "forearm", "hoof_f"))
            gate = leg * smoothstep(-0.02 * s, 0.03 * s, side * x) * (1 - tail) * (1 - head)
            gate = gate * (smoothstep(mid_y - 0.05 * s, mid_y + 0.05 * s, y) if front
                           else smoothstep(mid_y + 0.05 * s, mid_y - 0.05 * s, y))
            width = 0.045 * s if not name.startswith(("scapula", "upperarm", "thigh")) else 0.07 * s
        elif name in ("head", "snout"):
            gate, width = head * (1 - 0.95 * jaw), 0.12 * s
        else:
            gate = (1 - tail) * (1 - 0.9 * head) * (0.05 + smoothstep(0.30 * s, 0.50 * s, z))
            width = 0.12 * s
        weights.append(gate * np.exp(-d2 / width ** 2) + 1e-9 * (name == "spine"))
        groups.append(body.vertex_groups.new(name=name))
    w = np.array(weights).T
    w /= w.sum(axis=1, keepdims=True)
    src, dst = np.r_[a, b], np.r_[b, a]
    deg = np.maximum(np.bincount(src, minlength=len(p)), 1)
    for _ in range(4):
        avg = np.zeros_like(w)
        np.add.at(avg, src, w[dst])
        w = 0.55 * w + 0.45 * avg / deg[:, None]
    # the lower jaw is the jaw bone's alone: no smoothing may pull the upper teeth or lips along with it
    j = [g.name for g in groups].index("jaw")
    w[:, j] = 0.0
    w *= ((1.0 - jaw) / np.maximum(w.sum(axis=1), 1e-9))[:, None]
    w[:, j] = jaw
    top = np.argsort(w, axis=1)[:, -4:]
    vals = np.take_along_axis(w, top, axis=1)
    vals /= vals.sum(axis=1, keepdims=True)
    for vertex, row in enumerate(index):
        for g, wt in zip(top[row], vals[row]):
            if wt > 0.001:
                groups[g].add([vertex], float(wt), "REPLACE")
    body.parent = rig
    body.modifiers.new("Wolf skin", "ARMATURE").object = rig


# ------------------------------------------------------------------------------------- attacks
# Key poses with the legs solved by IK, so paws stay planted while the body gathers, push off the ground and
# reach out in flight. The forward travel of a lunge or a leap is done by the game (data/animals.json "lunge"),
# so the wolf lands where it jumped instead of sliding back; the clips only lift, pitch and lower the body.
# Rotation conventions of this rig (degrees about the bone's X): body / neck / head + = front or nose up,
# leg bones + = paw forward and up, tail + = tail down; about Z: + = turn to the wolf's left.

LEG_CHAINS = {"fL": ("sh", "el", "ca", "fh", "toe_f", "L"), "fR": ("sh", "el", "ca", "fh", "toe_f", "R"),
              "hL": ("hp", "st", "ho", "hh", "toe_h", "L"), "hR": ("hp", "st", "ho", "hh", "toe_h", "R")}


def leg_table(J):
    legs = {}
    for name, (a, b, c, d, e, s) in LEG_CHAINS.items():
        P = [np.array(J[f"{k}.{s}"]) for k in (a, b, c, d, e)]
        front = name.startswith("f")
        legs[name] = {"P": P, "front": front, "side": s,
                      "L1": math.dist(P[0][1:], P[1][1:]), "L2": math.dist(P[1][1:], P[2][1:]),
                      "L3": math.dist(P[2][1:], P[3][1:]),
                      "a1": fl._yz(P[1] - P[0]), "a2": fl._yz(P[2] - P[1]), "a3": fl._yz(P[3] - P[2]),
                      "a4": fl._yz(P[4] - P[3]),
                      "bones": (f"upperarm.{s}", f"forearm.{s}", f"hoof_f.{s}", f"hoof_f_toe.{s}") if front else
                               (f"thigh.{s}", f"shin.{s}", f"hoof_h.{s}", f"hoof_h_toe.{s}")}
    return legs


def solve_leg(Lg, top, parent, foot, cannon, toe):
    """Angles (r1..r4) that put the paw at `foot` (y, z) with the cannon at `cannon` degrees (absolute, YZ plane)."""
    cr = math.radians(cannon)
    wy, wz = foot[0] - Lg["L3"] * math.cos(cr), foot[1] - Lg["L3"] * math.sin(cr)
    dy, dz = wy - top[1], wz - top[2]
    L1, L2 = Lg["L1"], Lg["L2"]
    dd = min(max(math.hypot(dy, dz), abs(L1 - L2) + 1e-3), (L1 + L2) * 0.999)
    aa = math.degrees(math.acos(max(-1.0, min(1.0, (L1 * L1 + dd * dd - L2 * L2) / (2 * L1 * dd)))))
    th = math.degrees(math.atan2(dz, dy))
    a1 = th - aa if Lg["front"] else th + aa                   # elbow points back, stifle forward
    ky, kz = top[1] + L1 * math.cos(math.radians(a1)), top[2] + L1 * math.sin(math.radians(a1))
    a2 = math.degrees(math.atan2(wz - kz, wy - ky))
    r1 = a1 - Lg["a1"] - parent
    r2 = a2 - Lg["a2"] - (r1 + parent)
    r3 = cannon - Lg["a3"] - (r1 + r2 + parent)
    r4 = toe - Lg["a4"] - (r1 + r2 + r3 + parent)
    return r1, r2, r3, r4


def body_point(J, p, pitch, chest, loc):
    """A rest point carried by the chest (front) about spine2 and the whole body about the hips, then moved."""
    q = fl._rot(p, J["spine2"], chest) if chest else tuple(p)
    q = fl._rot(q, J["hips"], pitch)
    return np.array((q[0], q[1] + loc[0], q[2] + loc[1]))


def lerp_pose(a, b, u):
    out = {}
    for k in a:
        va, vb = a[k], b.get(k, a[k])
        if isinstance(va, dict):
            out[k] = {leg: tuple(x + (y - x) * u for x, y in zip(va[leg], vb[leg])) for leg in va}
        elif isinstance(va, (tuple, list)):
            out[k] = tuple(x + (y - x) * u for x, y in zip(va, vb))
        else:
            out[k] = va + (vb - va) * u
    return out


STAND = {"loc": (0.0, 0.0), "pitch": 0.0, "chest": 0.0, "neck": 0.0, "head": 0.0, "yaw": 0.0, "jaw": 0.0,
         "ears": 0.0, "tail": 0.0, "tail_yaw": 0.0}


def attack_clip(rig, J, seconds, keys, feet):
    """keys: [(time s, pose overrides)], eased between. feet(time s, pose, tops, legs) -> {leg: (y, z, cannon, toe)}."""
    legs = leg_table(J)
    keys = [(t, dict(STAND, **k)) for t, k in keys]
    n = int(seconds * fl.FPS)
    for f in range(n + 1):
        sec = f / fl.FPS
        i = max(k for k in range(len(keys)) if keys[k][0] <= sec + 1e-6)
        if i == len(keys) - 1:
            pose = keys[i][1]
        else:
            (t0, a), (t1, b) = keys[i], keys[i + 1]
            u = (sec - t0) / (t1 - t0)
            pose = lerp_pose(a, b, u * u * (3 - 2 * u))
        loc = pose["loc"]
        tops = {}
        for name, Lg in legs.items():
            tops[name] = body_point(J, Lg["P"][0], pose["pitch"], pose["chest"] if Lg["front"] else 0.0, loc)
        r = fl.zero_pose(rig)
        r["hips"] = (pose["pitch"], 0, 0)
        r["chest"] = (pose["chest"], 0, 0)
        r["neck"] = (pose["neck"], 0, pose["yaw"] * 0.5)
        r["head"] = (pose["head"], 0, pose["yaw"] * 0.5)
        r["jaw"] = (fl.jaw_open(rig, -pose["jaw"]), 0, 0)
        r["ear.L"] = (-pose["ears"], 0, 0)
        r["ear.R"] = (-pose["ears"], 0, 0)
        r["tail"] = (pose["tail"], 0, pose["tail_yaw"])
        r["tail2"] = (pose["tail"] * 0.4, 0, pose["tail_yaw"] * 0.6)
        r["tail3"] = (pose["tail"] * 0.3, 0, pose["tail_yaw"] * 0.4)
        for name, (fy, fz, cannon, toe) in feet(sec, pose, tops, legs).items():
            Lg = legs[name]
            parent = pose["pitch"] + (pose["chest"] if Lg["front"] else 0.0)
            for bone, ang in zip(Lg["bones"], solve_leg(Lg, tops[name], parent, (fy, fz), cannon, toe)):
                r[bone] = (ang, 0, 0)
        fl.key(rig, f + 1, r, (0, loc[0], loc[1]))
    return n


def planted(legs, name):
    """The paw where it stands, flat on the ground."""
    Lg = legs[name]
    return (Lg["P"][3][1], Lg["P"][3][2], Lg["a3"], Lg["a4"])


def leap_clip(rig, J):
    """Pounce. 1.2 s: gather (0-0.24), push off (0.32), apex (0.45), forepaws land and the jaws shut (0.6),
    hold and shake (0.6-0.95), recover. The game carries it forward over 0.33-0.6 s (data "lunge"), once
    the hind paws are off the ground."""
    keys = [(0.0, {"neck": -6, "head": 4, "ears": -15}),
            (0.24, {"loc": (-0.06, -0.12), "pitch": -6, "chest": -4, "neck": -14, "head": 10, "ears": -25, "tail": -8}),
            (0.32, {"loc": (0.0, 0.06), "pitch": 16, "chest": 4, "neck": -4, "head": 2, "ears": 15, "jaw": 12, "tail": -14}),
            (0.45, {"loc": (0.0, 0.36), "pitch": 4, "chest": 2, "neck": 6, "head": -4, "ears": 30, "jaw": 34, "tail": -18}),
            (0.58, {"loc": (0.0, 0.07), "pitch": -12, "chest": -4, "neck": -10, "head": 6, "ears": 30, "jaw": 30, "tail": -10}),
            (0.64, {"loc": (0.0, -0.05), "pitch": -9, "chest": -6, "neck": -18, "head": 6, "ears": 25, "jaw": 0, "tail": -6}),
            (0.78, {"loc": (0.0, -0.06), "pitch": -8, "chest": -6, "neck": -16, "head": 6, "yaw": 14, "ears": 25, "tail": -6}),
            (0.92, {"loc": (0.0, -0.05), "pitch": -6, "chest": -5, "neck": -14, "head": 6, "yaw": -12, "ears": 20, "tail": -4}),
            (1.2, {})]

    def feet(sec, pose, tops, legs):
        out = {}
        for name, Lg in legs.items():
            top = tops[name]
            rest = planted(legs, name)
            if Lg["front"]:
                if sec < 0.27 or sec >= 0.6:
                    out[name] = rest                                             # on the ground
                else:
                    u = (sec - 0.27) / 0.33                                      # lift, tuck, reach out, land
                    tuck = (top[1] - 0.06, top[2] - 0.26, Lg["a3"] - 70, Lg["a4"] - 40)
                    reach = (top[1] + 0.34, top[2] - 0.36, Lg["a3"] + 20, Lg["a4"] + 10)
                    land = (rest[0] + 0.12, 0.02, Lg["a3"], Lg["a4"])
                    if u < 0.35:
                        out[name] = tuple(np.array(rest) + (np.array(tuck) - np.array(rest)) * (u / 0.35))
                    elif u < 0.7:
                        out[name] = tuple(np.array(tuck) + (np.array(reach) - np.array(tuck)) * ((u - 0.35) / 0.35))
                    else:
                        out[name] = tuple(np.array(reach) + (np.array(land) - np.array(reach)) * ((u - 0.7) / 0.3))
            else:
                if sec < 0.34 or sec >= 0.66:
                    out[name] = rest                                             # push off / landed behind
                else:
                    u = (sec - 0.34) / 0.32                                      # trail back, then swing in
                    trail = (top[1] - 0.38, top[2] - 0.3, Lg["a3"] - 25, Lg["a4"] - 20)
                    if u < 0.5:
                        out[name] = tuple(np.array(rest) + (np.array(trail) - np.array(rest)) * (u / 0.5))
                    else:
                        out[name] = tuple(np.array(trail) + (np.array(rest) - np.array(trail)) * ((u - 0.5) / 0.5))
        return out

    return attack_clip(rig, J, 1.2, keys, feet)


def bite_clip(rig, J):
    """The ordinary bite: gather, a step in with the jaws wide, the snap at 0.45 s, a short tug, back.
    0.9 s; the game moves it in over 0.22-0.45 s."""
    keys = [(0.0, {}),
            (0.2, {"loc": (-0.04, -0.05), "pitch": -4, "neck": -12, "head": 8, "ears": -20, "jaw": 6}),
            (0.38, {"loc": (0.06, -0.02), "pitch": 2, "neck": 2, "head": 0, "ears": 20, "jaw": 32}),
            (0.45, {"loc": (0.08, -0.03), "pitch": -2, "neck": -6, "head": 4, "ears": 20, "jaw": 0}),
            (0.6, {"loc": (-0.04, -0.03), "pitch": -3, "neck": -10, "head": 6, "yaw": 10, "ears": 15}),
            (0.9, {})]

    def feet(sec, pose, tops, legs):
        out = {n: planted(legs, n) for n in legs}
        # the near forefoot steps in with the lunge
        if 0.15 < sec < 0.45:
            u = (sec - 0.15) / 0.3
            y, z, c, t = planted(legs, "fL")
            out["fL"] = (y + 0.16 * u, z + 0.09 * math.sin(math.pi * u), c, t)
        elif sec >= 0.45:
            y, z, c, t = planted(legs, "fL")
            out["fL"] = (y + 0.16 * max(0.0, 1 - (sec - 0.6) / 0.3) if sec > 0.6 else y + 0.16, z, c, t)
        return out

    return attack_clip(rig, J, 0.9, keys, feet)


def snap_clip(rig, J):
    """A quick snap from where it stands: the head darts in, jaws open and shut at 0.22 s, and it pulls back.
    0.55 s, no step."""
    keys = [(0.0, {}),
            (0.1, {"loc": (-0.03, -0.02), "pitch": -2, "neck": -8, "head": 6, "ears": -15, "jaw": 20}),
            (0.19, {"loc": (0.07, -0.01), "pitch": 2, "chest": 2, "neck": 4, "head": -2, "ears": 20, "jaw": 26}),
            (0.22, {"loc": (0.08, -0.01), "pitch": 2, "chest": 2, "neck": 3, "head": -1, "ears": 20, "jaw": 0}),
            (0.34, {"loc": (-0.05, -0.02), "pitch": -1, "neck": -6, "head": 4, "ears": 5}),
            (0.55, {})]
    return attack_clip(rig, J, 0.55, keys, lambda sec, pose, tops, legs: {n: planted(legs, n) for n in legs})


def hamstring_clip(rig, J):
    """In low and from the side at a leg: head down and turned, the slash at 0.4 s, a tug back with a shake,
    away. 0.8 s; the game carries it in at an angle over 0.08-0.36 s."""
    keys = [(0.0, {}),
            (0.14, {"loc": (0.0, -0.08), "pitch": -6, "chest": -4, "neck": -24, "head": 12, "yaw": 22, "ears": -25,
                    "jaw": 10, "tail": -6}),
            (0.34, {"loc": (0.04, -0.1), "pitch": -8, "chest": -5, "neck": -28, "head": 10, "yaw": 34, "ears": 25,
                    "jaw": 28, "tail": -8}),
            (0.4, {"loc": (0.05, -0.1), "pitch": -8, "chest": -5, "neck": -26, "head": 10, "yaw": 34, "ears": 25,
                   "jaw": 0, "tail": -8}),
            (0.55, {"loc": (-0.12, -0.07), "pitch": -5, "chest": -3, "neck": -18, "head": 8, "yaw": 18, "ears": 20,
                    "tail": -4, "tail_yaw": 12}),
            (0.62, {"loc": (-0.13, -0.06), "pitch": -4, "neck": -16, "head": 8, "yaw": 30, "ears": 20, "tail_yaw": -10}),
            (0.8, {})]
    return attack_clip(rig, J, 0.8, keys, lambda sec, pose, tops, legs: {n: planted(legs, n) for n in legs})


def main():
    src, dst = (Path(a) for a in sys.argv[sys.argv.index("--") + 1:][:2])
    bpy.context.scene.render.fps = fl.FPS
    body = load(src)
    bpy.context.scene.render.fps = fl.FPS
    P = np.array([v.co[:] for v in body.data.vertices])
    P = straighten(P)
    P[:, 2] -= P[:, 2].min()
    s = REF_H / P[:, 2].max()                      # ear tips at the reference wolf's height
    P *= s
    s = 1.0                                        # from here on metres of a reference-sized wolf
    F = feet(P, s)
    centre = (F["fh.L"][1] + F["fh.R"][1] + F["hh.L"][1] + F["hh.R"][1]) / 4
    P[:, 1] -= centre - (REF["fh.L"][1] + REF["hh.L"][1]) / 2
    F = feet(P, s)
    P = neutral_stance(P, F, s)
    body.data.calc_loop_triangles()
    tris = np.array([t.vertices[:] for t in body.data.loop_triangles])
    J, mouth, rear = joints(P, F, s, surface_samples(P, tris))
    P, jaw = close_mouth(P, mouth, s)
    J["jaw_t"] = J["nose"] + np.array((0.0, -0.035, -0.06))      # the closed lower jaw's tip, under the nose
    body.data.vertices.foreach_set("co", P.ravel())
    body.data.update()
    for m in body.data.materials:
        m.name = "M_Wolf_Textured"
        bsdf = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf:
            bsdf.inputs["Metallic"].default_value = 0.0
            bsdf.inputs["Roughness"].default_value = 0.85
    for poly in body.data.polygons:
        poly.use_smooth = True
    sp = dict(ga.WOLF, J={k: tuple(float(c) for c in v) for k, v in J.items()}, mouth=None)
    Jt = fl.complete_joints(sp["J"])           # the joints the rig is built on (for the attack IK)
    rig_ref = []
    sp["speeds"] = ga.game_speeds(sp)
    sp["clips"] = lambda rig: fl.std_clips(rig, sp, ga.WOLF_WALK, ga.WOLF_RUN,
                                           extra={"attack_snap": lambda: snap_clip(rig, Jt), "attack_leap": lambda: leap_clip(rig, Jt),
                                                  "attack_hamstring": lambda: hamstring_clip(rig, Jt)})
    sp["attack"] = lambda rig: bite_clip(rig, Jt)
    # standing about the mouth stays shut, with now and then a few breaths through it; it pants when it runs
    sp["idle_extra"] = lambda r, t: r.update({"jaw": (fl.jaw_open(rig_ref[0], -9.0 * max(0.0, math.sin(t * math.tau * 2 - 1.2)) ** 6), 0, 0)})
    rig = fl.build_rig(sp)
    rig_ref.append(rig)
    rig["mouth"] = True          # a real mouth: bites and panting open it all the way (fl.jaw_open)
    bind(body, P, rig, sp, J, mouth, rear, s, jaw)
    print("Wolf clips:", fl.make_clips(rig, sp))
    print("Wolf joints:", {k: np.round(J[k], 3).tolist() for k in ("nose", "head", "jaw_t", "chest", "hips",
                                                                    "el.L", "ca.L", "st.L", "ho.L", "tail", "tail3")})
    fl.activate(rig)
    body.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(dst), export_format="GLB", use_selection=True,
                              export_animations=True, export_animation_mode="NLA_TRACKS", export_skins=True)


if __name__ == "__main__":
    main()
