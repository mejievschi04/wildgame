"""Puts a static sculpted body (e.g. a Tripo export) on the existing Homo sapiens skeleton, so it plays every
animation made for that skeleton (the embedded clips and AN_SapiensM_*.tres).

  blender -b --factory-startup -P tools/blender/rig_sapiens.py -- OLD.gltf NEW.glb OUT.gltf

OLD.gltf is the current rigged SK_Human_SapiensM (skeleton, clips, skin weights to copy from; it is only read).
The skeleton keeps its rest pose (A-pose) so the clips stay valid; the new body is bound in a pose P of the same
skeleton that matches it (arms down, thumbs forward) through the glTF inverse bind matrices. Joint offsets
follow the new body's proportions; translation keys in the clips are shifted by the same amount.
Skin weights come from the old body and outfit posed into P (nearest points), the kilt's swinging skirt_* bones
included, then smoothed along the new mesh.
"""
import json
import math
import os
import struct
import sys

import numpy as np

HEIGHT = 1.82                        # top of the hair, metres
# Joint targets measured on the new body (glTF axes: +Y up, +Z forward, the body's right at -X). Left side mirrored.
TARGET = {
    "upperarm": (0.200, 1.470, 0.000),
    "lowerarm": (0.290, 1.190, -0.010),
    "hand": (0.330, 0.930, 0.070),
    "calf": (0.170, 0.545, 0.025),
    "foot": (0.235, 0.090, 0.015),
    "ball": (0.245, 0.010, 0.150),
}
TRUNK_Y = 0.99                       # spine, neck and head: the old heights, a touch lower
AIM = {"clavicle": "upperarm", "upperarm": "lowerarm", "lowerarm": "hand", "thigh": "calf", "calf": "foot",
       "foot": "ball"}
SMOOTH = 3

CT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load(path):
    if path.endswith(".glb"):
        d = open(path, "rb").read()
        n = struct.unpack("<I", d[12:16])[0]
        j = json.loads(d[20:20 + n])
        off = 20 + n
        bl = struct.unpack("<I", d[off:off + 4])[0]
        return j, [d[off + 8: off + 8 + bl]]
    j = json.load(open(path))
    return j, [open(os.path.join(os.path.dirname(path), b["uri"]), "rb").read() for b in j["buffers"]]


def acc(j, bins, i):
    a = j["accessors"][i]
    bv = j["bufferViews"][a["bufferView"]]
    n, dt = NC[a["type"]], np.dtype(CT[a["componentType"]])
    stride = bv.get("byteStride", n * dt.itemsize)
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    buf = bins[bv["buffer"]]
    if stride == n * dt.itemsize:
        arr = np.frombuffer(buf, dt, a["count"] * n, base).reshape(a["count"], n)
    else:
        arr = np.stack([np.frombuffer(buf, dt, n, base + k * stride) for k in range(a["count"])])
    arr = arr.copy()
    if a.get("normalized"):
        arr = arr.astype(np.float32) / np.iinfo(dt).max
    return arr


def quat_m(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def local(n):
    M = np.eye(4)
    M[:3, :3] = quat_m(n.get("rotation", [0, 0, 0, 1]))
    M[:3, 3] = n.get("translation", [0, 0, 0])
    return M


def rot_between(a, b):
    a = a / np.linalg.norm(a)
    b = b / np.linalg.norm(b)
    v, c = np.cross(a, b), float(a @ b)
    if np.linalg.norm(v) < 1e-9:
        return np.eye(3)
    V = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + V + V @ V / (1 + c)


def axis_rot(axis, ang):
    a = axis / np.linalg.norm(axis)
    K = np.array([[0, -a[2], a[1]], [a[2], 0, -a[0]], [-a[1], a[0], 0]])
    return np.eye(3) + math.sin(ang) * K + (1 - math.cos(ang)) * K @ K


def side_of(name):
    return 1.0 if name.endswith("_l") else -1.0


def target(name):
    base = name[:-2] if name[-2:] in ("_l", "_r") else name
    if base in TARGET:
        t = np.array(TARGET[base], float)
        t[0] *= side_of(name)
        return t
    return None


# ------------------------------------------------------------------------------------------- pose P

def build_pose(j):
    """Pose P, one pass from the root out: each joint goes to its measured place (or rides on its parent), bones
    with a measured child turn (minimally, from rest) to point at it; the hand continues the forearm with the
    thumb forward, half of that twist taken by the forearm."""
    par = {c: i for i, n in enumerate(j["nodes"]) for c in n.get("children", [])}
    joints = j["skins"][0]["joints"]
    names = {i: j["nodes"][i]["name"] for i in joints}
    by_name = {v: k for k, v in names.items()}
    rest_g = {}

    def rg(i):
        if i not in rest_g:
            rest_g[i] = (rg(par[i]) if i in par else np.eye(4)) @ local(j["nodes"][i])
        return rest_g[i]

    def depth(i):
        d = 0
        while i in par:
            i, d = par[i], d + 1
        return d

    def follow(i, Pp):
        Rp = rg(par[i]) if i in par else np.eye(4)
        return Pp @ np.linalg.inv(Rp) @ rg(i)

    def offset(child, s):
        h = rg(by_name["hand" + s])
        return h[:3, :3].T @ (rg(by_name[child + s])[:3, 3] - h[:3, 3])

    def thumb_angle(R_hand, s, axis):
        """Twist about `axis` that turns the thumb (as carried by R_hand) to face forward (+Z)."""
        a = axis / np.linalg.norm(axis)
        th = R_hand @ offset("thumb_02", s)
        th = th - a * (th @ a)
        want = np.array([0.0, 0.0, 1.0]) - a * a[2]
        return math.atan2(np.cross(th, want) @ a, th @ want)

    def hand_rot(R_low, s, fore):
        R = R_low @ rg(by_name["lowerarm" + s])[:3, :3].T @ rg(by_name["hand" + s])[:3, :3]
        return rot_between(R @ offset("middle_01", s), fore) @ R

    G = {}
    for i in sorted(joints, key=depth):
        n = names[i]
        base = n[:-2] if n[-2:] in ("_l", "_r") else n
        s = n[-2:]
        M = follow(i, G[par[i]] if par.get(i) in G else np.eye(4))
        t = target(n)
        if t is not None:
            M[:3, 3] = t
        elif base in ("spine_01", "spine_02", "spine_03", "neck_01", "head", "pelvis", "thigh", "clavicle"):
            M[:3, 3] = rg(i)[:3, 3] * (1, TRUNK_Y, 1)
        if base in AIM:
            c = by_name[AIM[base] + s]
            M[:3, :3] = rot_between(rg(c)[:3, 3] - rg(i)[:3, 3], target(names[c]) - M[:3, 3]) @ rg(i)[:3, :3]
        if base == "lowerarm":
            fore = target("hand" + s) - M[:3, 3]
            ang = thumb_angle(hand_rot(M[:3, :3], s, fore), s, fore)
            M[:3, :3] = axis_rot(fore, 0.5 * ang) @ M[:3, :3]
        if base == "hand":
            fore = M[:3, 3] - G[par[i]][:3, 3]
            R = hand_rot(G[par[i]][:3, :3], s, fore)
            M[:3, :3] = axis_rot(fore, thumb_angle(R, s, fore)) @ R
        G[i] = M
    return G, rg, par, joints, names


# ------------------------------------------------------------------------------------------- weights

def old_posed_points(j, bins, G, rg):
    """Vertices (and their weights over the skin joints) of the old body and outfit, posed into P."""
    joints = j["skins"][0]["joints"]
    ibm = acc(j, bins, j["skins"][0]["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
    S = np.stack([G[i] @ ibm[k] for k, i in enumerate(joints)])
    pts, wts = [], []
    skip = ("Eye", "Mouth", "Tooth", "Feather", "Talisman", "ArmTooth", "Cord")
    for n in j["nodes"]:
        if "mesh" not in n or n["name"].startswith(skip):
            continue
        for pr in j["meshes"][n["mesh"]]["primitives"]:
            a = pr["attributes"]
            V = acc(j, bins, a["POSITION"]).astype(float)
            J = acc(j, bins, a["JOINTS_0"]).astype(int)
            W = acc(j, bins, a["WEIGHTS_0"]).astype(float)
            Vh = np.c_[V, np.ones(len(V))]
            out = np.zeros((len(V), 3))
            for c in range(4):
                out += W[:, c:c + 1] * np.einsum("nij,nj->ni", S[J[:, c]], Vh)[:, :3]
            full = np.zeros((len(V), len(joints)))
            np.add.at(full, (np.arange(len(V))[:, None].repeat(4, 1), J), W)
            pts.append(out)
            wts.append(full)
    return np.concatenate(pts), np.concatenate(wts)


GROUP_OF = (("upperarm", "lowerarm", "hand", "thumb", "index", "middle", "ring", "pinky"), ("thigh", "calf", "foot", "ball"))


def bone_group(name):
    """0 trunk (with the skirt bones), 1/2 left/right arm, 3/4 left/right leg."""
    for g, parts in enumerate(GROUP_OF):
        if name.startswith(parts):
            return 1 + 2 * g + (0 if name.endswith("_l") else 1)
    return 0


def seg_dist(P, a, b):
    ab = b - a
    t = np.clip(((P - a) @ ab) / (ab @ ab), 0, 1)
    return np.linalg.norm(P - (a + t[:, None] * ab), axis=1)


def body_groups(P, G, names):
    """Which part of the body each new vertex belongs to, by the nearest bone of pose P. Arms and legs only
    claim what is close to them: the cape and the skirt hanging beside them stay with the trunk."""
    by = {v: k for k, v in names.items()}
    pos = lambda n: G[by[n]][:3, 3]
    head_top = pos("head") + np.array([0, 0.16, 0])
    trunk = [("pelvis", "spine_01"), ("spine_01", "spine_02"), ("spine_02", "spine_03"), ("spine_03", "neck_01"),
             ("neck_01", "head")]
    d_trunk = np.min([seg_dist(P, pos(a), pos(b)) for a, b in trunk] + [seg_dist(P, pos("head"), head_top)], axis=0)
    out = np.zeros(len(P), int)
    best = d_trunk.copy()
    for s, ga, gl in (("_l", 1, 3), ("_r", 2, 4)):
        # each part of the arm claims only its own thickness: the skirt fringe the hand rests on stays on the skirt
        d_up = seg_dist(P, pos("upperarm" + s), pos("lowerarm" + s))
        d_fore = seg_dist(P, pos("lowerarm" + s), pos("hand" + s))
        tip = pos("middle_03" + s) + (pos("middle_03" + s) - pos("middle_02" + s)) * 1.2     # past the last knuckle
        thumb = pos("thumb_03" + s) + (pos("thumb_03" + s) - pos("thumb_02" + s)) * 1.2
        d_hand = np.minimum(seg_dist(P, pos("hand" + s), tip), seg_dist(P, pos("thumb_01" + s), thumb) + 0.02)
        arm = np.minimum(np.minimum(np.where(d_up < 0.075, d_up, 9.0), np.where(d_fore < 0.08, d_fore, 9.0)),
                         np.where(d_hand < 0.065, d_hand, 9.0))
        take = arm < best
        out[take], best[take] = ga, arm[take]
        d_th = seg_dist(P, pos("thigh" + s), pos("calf" + s))
        d_low = np.minimum(seg_dist(P, pos("calf" + s), pos("foot" + s)), seg_dist(P, pos("foot" + s), pos("ball" + s)))
        # the sculpt's thighs are thick (skin up to ~0.14 m from the bone, the skirt beyond ~0.15 m); near the hip
        # joint only the narrower reach, so the buttocks and belly stay with the trunk
        hp, kn = pos("thigh" + s), pos("calf" + s)
        along = np.clip(((P - hp) @ (kn - hp)) / ((kn - hp) @ (kn - hp)), 0, 1)
        reach = np.where(along > 0.2, 0.145, 0.105)
        leg = np.minimum(np.where(d_th < reach, d_th, 9.0), np.where(P[:, 1] < 0.5, d_low, 9.0))
        take = leg < best
        out[take], best[take] = gl, leg[take]
    return out


def transfer(P, src, sw, k=6, groups=None, src_groups=None):
    W = np.zeros((len(P), sw.shape[1]))
    if groups is not None:
        for g in np.unique(groups):
            m, ms = groups == g, src_groups == g
            if ms.sum() < k:
                ms = np.ones(len(src), bool)
            W[m] = transfer(P[m], src[ms], sw[ms], k)
        return W
    for a in range(0, len(P), 512):
        d = np.linalg.norm(P[a:a + 512, None, :] - src[None], axis=2)
        idx = np.argpartition(d, k, axis=1)[:, :k]
        dd = np.take_along_axis(d, idx, 1)
        w = 1.0 / (dd + 0.004) ** 2
        w /= w.sum(1, keepdims=True)
        W[a:a + 512] = np.einsum("nk,nkj->nj", w, sw[idx])
    return W


def islands(T, n):
    """Connected pieces of the mesh as exported (a generated mesh is many small pieces)."""
    par = np.arange(n)

    def find(x):
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x

    for a, b, c in T:
        for u, v in ((a, b), (b, c)):
            ru, rv = find(u), find(v)
            if ru != rv:
                par[ru] = rv
    return np.array([find(i) for i in range(n)])


def vote(groups, isl):
    """Each piece belongs to one part of the body (its majority): no triangle is torn between a hand and the
    skirt it hangs beside."""
    out = groups.copy()
    for r in np.unique(isl):
        m = isl == r
        out[m] = np.bincount(groups[m]).argmax()
    return out


def settle(groups, isl, P, near=0.02, share=0.6, rounds=3):
    """Between hip and knee a loose scrap takes the part it lies among: a piece of skirt lying on the thigh
    (or a scrap of thigh skin among the skirt) would otherwise float away from its neighbours."""
    zone = (P[:, 1] > 0.45) & (P[:, 1] < 1.0) & (groups != 1) & (groups != 2)
    idx = np.where(zone)[0]
    if len(idx) == 0:
        return groups
    Z = P[idx]
    nbrs = []
    for a in range(0, len(idx), 512):
        d = np.linalg.norm(Z[a:a + 512, None, :] - Z[None], axis=2)
        nbrs += [np.where(row < near)[0] for row in d]
    out = groups.copy()
    for _ in range(rounds):
        changed = 0
        for r in np.unique(isl[idx]):
            mine = np.where(isl[idx] == r)[0]
            around = np.unique(np.concatenate([nbrs[m] for m in mine]))
            around = around[isl[idx][around] != r]
            if len(around) < 4:
                continue
            g = out[idx][around]
            vals, cnt = np.unique(g, return_counts=True)
            top = vals[np.argmax(cnt)]
            if cnt.max() / len(g) >= share and top != out[idx[mine[0]]]:
                out[idx[mine]] = top
                changed += 1
        if not changed:
            break
    return out


def skirt_follows_legs(W, P, G, names, groups, joints, most=0.45):
    """The skirt hanging in front of and behind each thigh goes part of the way with it (fading out towards
    the waist and away from the leg), so a stride doesn't push the thigh through the hide."""
    by = {v: k for k, v in names.items()}
    col = {names[i]: k for k, i in enumerate(joints)}
    pos = lambda n: G[by[n]][:3, 3]
    skirt = (groups == 0) & (P[:, 1] > 0.45) & (P[:, 1] < 0.98)
    if not skirt.any():
        return W
    W = W.copy()
    fade_waist = np.clip((0.97 - P[:, 1]) / 0.12, 0, 1)
    shares = []
    for s in ("_l", "_r"):
        d = seg_dist(P, pos("thigh" + s), pos("calf" + s))
        f = np.clip((0.27 - d) / 0.14, 0, 1)
        shares.append(f * f * (3 - 2 * f) * fade_waist * most * skirt)
    total = shares[0] + shares[1]
    over = np.maximum(total / most, 1.0)          # the panel between the legs: split, never more than `most`
    for s, f in zip(("_l", "_r"), shares):
        f = f / over
        W *= (1 - f)[:, None]
        W[:, col["thigh" + s]] += f
    return W


def weld(P):
    """Vertex -> id of its position (split vertices at a seam share one)."""
    _, inv = np.unique(np.round(P, 5), axis=0, return_inverse=True)
    return inv.reshape(-1)


def smooth(W, T, n, it, wid=None, groups=None, P=None):
    nb = [[] for _ in range(n)]
    for a, b, c in T:
        nb[a] += [b, c]
        nb[b] += [a, c]
        nb[c] += [a, b]
    if wid is not None:                          # seams: neighbours of any copy of the same point
        same = {}
        for i, w in enumerate(wid):
            same.setdefault(w, []).append(i)
        for grp in same.values():
            if len(grp) > 1:
                allnb = sum((nb[i] for i in grp), []) + grp
                for i in grp:
                    nb[i] = allnb
    nb = [np.unique(x) if x else np.array([i]) for i, x in enumerate(nb)]
    if groups is not None:
        # Parts share weights only where they really join: an arm with the trunk at the shoulder, a leg with the
        # trunk at the hip. Elsewhere they only touch in the sculpt (hand on the skirt, elbow on the belt, skirt on
        # the thigh) and must move apart.
        arm = (groups == 1) | (groups == 2)
        leg = (groups == 3) | (groups == 4)
        y = P[:, 1]
        for i in range(n):
            x = nb[i]
            other = groups[x] != groups[i]
            shoulder = (arm[x] | arm[i]) & ((groups[x] == 0) | (groups[i] == 0)) & (y[x] > 1.35) & (y[i] > 1.35)
            hip = (leg[x] | leg[i]) & ((groups[x] == 0) | (groups[i] == 0)) & (y[x] > 0.9) & (y[i] > 0.9)
            cut = other & ~shoulder & ~hip
            if cut.any():
                nb[i] = x[~cut] if (~cut).any() else np.array([i])
    for _ in range(it):
        W = 0.5 * W + 0.5 * np.stack([W[x].mean(0) for x in nb])
    return W


def top4(W):
    idx = np.argsort(-W, axis=1)[:, :4]
    w = np.take_along_axis(W, idx, 1)
    w /= np.maximum(w.sum(1, keepdims=True), 1e-9)
    return idx.astype(np.uint16), w.astype(np.float32)


# ------------------------------------------------------------------------------------------- writer

class Out:
    def __init__(self):
        self.buf = bytearray()
        self.views, self.accs = [], []

    def add(self, arr, typ, target=None, minmax=False):
        arr = np.ascontiguousarray(arr)
        ct = {np.dtype(np.float32): 5126, np.dtype(np.uint16): 5123, np.dtype(np.uint32): 5125}[arr.dtype]
        while len(self.buf) % 4:
            self.buf.append(0)
        v = {"buffer": 0, "byteOffset": len(self.buf), "byteLength": arr.nbytes}
        if target:
            v["target"] = target
        self.buf += arr.tobytes()
        self.views.append(v)
        a = {"bufferView": len(self.views) - 1, "componentType": ct, "count": len(arr), "type": typ}
        if minmax:
            a["min"] = arr.reshape(len(arr), -1).min(0).tolist()
            a["max"] = arr.reshape(len(arr), -1).max(0).tolist()
        self.accs.append(a)
        return len(self.accs) - 1


def m_quat(R):
    t = np.trace(R)
    if t > 0:
        s = math.sqrt(t + 1) * 2
        q = [(R[2, 1] - R[1, 2]) / s, (R[0, 2] - R[2, 0]) / s, (R[1, 0] - R[0, 1]) / s, s / 4]
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = math.sqrt(1 + R[0, 0] - R[1, 1] - R[2, 2]) * 2
        q = [s / 4, (R[0, 1] + R[1, 0]) / s, (R[0, 2] + R[2, 0]) / s, (R[2, 1] - R[1, 2]) / s]
    elif R[1, 1] > R[2, 2]:
        s = math.sqrt(1 + R[1, 1] - R[0, 0] - R[2, 2]) * 2
        q = [(R[0, 1] + R[1, 0]) / s, s / 4, (R[1, 2] + R[2, 1]) / s, (R[0, 2] - R[2, 0]) / s]
    else:
        s = math.sqrt(1 + R[2, 2] - R[0, 0] - R[1, 1]) * 2
        q = [(R[0, 2] + R[2, 0]) / s, (R[1, 2] + R[2, 1]) / s, s / 4, (R[1, 0] - R[0, 1]) / s]
    q = np.array(q)
    return (q / np.linalg.norm(q)).tolist()


def save_png(jpeg_bytes, path):
    import bpy
    tmp = path + ".src.jpg"
    open(tmp, "wb").write(jpeg_bytes)
    img = bpy.data.images.load(tmp)
    img.reload()
    px = np.array(img.pixels[:], np.float32)      # forces the decode
    out = bpy.data.images.new("body", img.size[0], img.size[1], alpha=False)
    out.pixels.foreach_set(px)
    img = out
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    os.remove(tmp)


def main():
    a = sys.argv[sys.argv.index("--") + 1:]
    jo, bo = load(a[0])
    jn, bn = load(a[1])
    out_path = a[2]
    G, rg, par, joints, names = build_pose(jo)
    if os.environ.get("POSE_ONLY"):
        # debugging aid: the OLD model with its skeleton's rest replaced by P (shows P on the old body)
        return pose_debug(jo, a[0], G, out_path)

    # new body, scaled to HEIGHT, feet on the ground (both files face +Z)
    pr = jn["meshes"][0]["primitives"][0]
    P = acc(jn, bn, pr["attributes"]["POSITION"]).astype(float)
    N = acc(jn, bn, pr["attributes"]["NORMAL"]).astype(float)
    UV = acc(jn, bn, pr["attributes"]["TEXCOORD_0"]).astype(np.float32)
    T = acc(jn, bn, pr["indices"]).reshape(-1, 3).astype(np.uint32)
    P[:, 1] -= P[:, 1].min()
    P *= HEIGHT / P[:, 1].max()

    src, sw = old_posed_points(jo, bo, G, rg)
    isl = islands(T, len(P))
    groups = settle(vote(body_groups(P, G, names), isl), isl, P)
    jgroup = np.array([bone_group(names[i]) for i in joints])
    sg = jgroup[np.argmax(sw, axis=1)]
    W = transfer(P, src, sw, groups=groups, src_groups=sg)
    W = smooth(W, T, len(P), SMOOTH, weld(P), groups, P)
    W = skirt_follows_legs(W, P, G, names, groups, joints)
    Jw, Ww = top4(W)

    # new rest offsets: the child's place in P, in its parent's P frame
    j = json.loads(json.dumps(jo))
    delta = {}
    for i in joints:
        n = j["nodes"][i]
        if i in par and par[i] in G:
            t = np.linalg.inv(G[par[i]]) @ np.r_[G[i][:3, 3], 1]
            old = np.array(n.get("translation", [0, 0, 0]))
            if names[i] != "Root":
                delta[i] = t[:3] - old
                n["translation"] = t[:3].tolist()

    o = Out()
    # animations: same keys, translation keys shifted with the new offsets
    anims = []
    for an in jo.get("animations", []):
        samplers, chans = [], []
        for c in an["channels"]:
            s = an["samplers"][c["sampler"]]
            inp = acc(jo, bo, s["input"]).astype(np.float32)
            outv = acc(jo, bo, s["output"]).astype(np.float32)
            node = c["target"]["node"]
            if c["target"]["path"] == "translation" and node in delta:
                outv = outv + delta[node].astype(np.float32)
            typ = {"translation": "VEC3", "scale": "VEC3", "rotation": "VEC4"}[c["target"]["path"]]
            samplers.append({"input": o.add(inp.reshape(-1), "SCALAR", minmax=True), "output": o.add(outv, typ),
                             "interpolation": s.get("interpolation", "LINEAR")})
            chans.append({"sampler": len(samplers) - 1, "target": c["target"]})
        anims.append({"name": an["name"], "samplers": samplers, "channels": chans})

    ibm = np.stack([np.linalg.inv(G[i]).T.reshape(-1) for i in joints]).astype(np.float32)
    ibm_acc = o.add(ibm.reshape(-1, 16), "MAT4")
    tex_name = "T_Human_SapiensM_body.png"
    attrs = {"POSITION": o.add(P.astype(np.float32), "VEC3", 34962, minmax=True),
             "NORMAL": o.add(N.astype(np.float32), "VEC3", 34962),
             "TEXCOORD_0": o.add(UV, "VEC2", 34962),
             "JOINTS_0": o.add(Jw, "VEC4", 34962),
             "WEIGHTS_0": o.add(Ww, "VEC4", 34962)}
    ind = o.add(T.reshape(-1), "SCALAR", 34963)

    # keep the skeleton nodes, drop the old meshes, add the body
    keep_nodes = set(joints)
    arm = [i for i, n in enumerate(j["nodes"]) if n.get("name") == "Human.rig"][0]
    nodes, remap = [], {}
    for i, n in enumerate(j["nodes"]):
        if i in keep_nodes or i == arm:
            remap[i] = len(nodes)
            nodes.append(n)
    for n in nodes:
        if "children" in n:
            n["children"] = [remap[c] for c in n["children"] if c in remap]
            if not n["children"]:
                del n["children"]
    body = {"name": "Body", "mesh": 0, "skin": 0}
    nodes.append(body)
    nodes[remap[arm]].setdefault("children", []).append(len(nodes) - 1)
    for an in anims:
        for c in an["channels"]:
            c["target"]["node"] = remap[c["target"]["node"]]
    skin = {"name": jo["skins"][0].get("name", "Human.rig"), "joints": [remap[i] for i in joints],
            "inverseBindMatrices": ibm_acc}
    gltf = {
        "asset": {"version": "2.0", "generator": "WILDBOUND rig_sapiens.py"},
        "scene": 0, "scenes": [{"name": "Scene", "nodes": [remap[arm]]}],
        "nodes": nodes, "skins": [skin], "animations": anims,
        "meshes": [{"name": "Body", "primitives": [{"attributes": attrs, "indices": ind, "material": 0}]}],
        "materials": [{"name": "M_Human_SapiensM_Body", "doubleSided": True,
                       "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0,
                                                "roughnessFactor": 0.85}}],
        "textures": [{"source": 0, "sampler": 0}],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "images": [{"name": "T_Human_SapiensM_body", "mimeType": "image/png", "uri": "textures/" + tex_name}],
        "accessors": o.accs, "bufferViews": o.views,
    }
    base = os.path.splitext(os.path.basename(out_path))[0]
    gltf["buffers"] = [{"byteLength": len(o.buf), "uri": base + ".bin"}]
    d = os.path.dirname(os.path.abspath(out_path))
    open(os.path.join(d, base + ".bin"), "wb").write(o.buf)
    json.dump(gltf, open(out_path, "w"), indent=1)
    img = jn["images"][0]
    bv = jn["bufferViews"][img["bufferView"]]
    raw = bn[0][bv.get("byteOffset", 0): bv.get("byteOffset", 0) + bv["byteLength"]]
    os.makedirs(os.path.join(d, "textures"), exist_ok=True)
    save_png(raw, os.path.join(d, "textures", tex_name))
    dom = Jw[np.arange(len(Jw)), 0]
    print("SAPIENS groups (trunk, arm L/R, leg L/R):", np.bincount(groups, minlength=5).tolist())
    print("SAPIENS body", len(P), "verts;", "skirt-weighted", int(sum(names[joints[k]].startswith("skirt") for k in dom)),
          "verts; written", out_path)


def pose_debug(jo, src_path, G, out_path):
    j = json.load(open(src_path))
    par = {c: i for i, n in enumerate(j["nodes"]) for c in n.get("children", [])}
    for i, M in G.items():
        L = np.linalg.inv(G[par[i]]) @ M if i in par and par[i] in G else M
        j["nodes"][i]["translation"] = L[:3, 3].tolist()
        j["nodes"][i]["rotation"] = m_quat(L[:3, :3])
    d = os.path.dirname(os.path.abspath(src_path))
    j["buffers"][0]["uri"] = os.path.join(d, j["buffers"][0]["uri"])
    for im in j.get("images", []):
        im["uri"] = os.path.join(d, im["uri"])
    j.pop("animations", None)
    json.dump(j, open(out_path, "w"))
    print("SAPIENS pose debug written", out_path)


if __name__ == "__main__":
    main()
