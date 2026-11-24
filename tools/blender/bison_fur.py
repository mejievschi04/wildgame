"""Grow the long wisent hair under the bison's neck and chest and on the upper front legs: the throat mane runs
from the beard back to the brisket, and the forelegs wear shaggy "chaps" down to mid-forearm. It also hides the
seams of the grafted hide there.

  blender -b --factory-startup --python tools/blender/bison_fur.py -- SK_Bison_Textured.glb SK_Bison_Textured.glb

Run after bison_legs.py. The new strands are copies of the beard's hair cards (same texture, alpha fade and
material), rooted on the hide in the posed idle frame, hanging down and a little back, and skinned rigidly to
the bones of the skin they grow from.
"""
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path[:0] = [str(SCRIPT_DIR), str(SCRIPT_DIR.parent)]
from prepare_bear import read_glb, write_glb
from prepare_bison_from_rhino import mix_skin, point_transform, posed_skin, read_array
from prepare_megaloceros import accessor

SEED = 7
SPACING = 0.028          # metres between strands of the throat mane
THROAT_LENGTH = (0.18, 0.32)
CHAPS_LENGTH = (0.10, 0.17)
STRAND_WIDTH = 0.6
SHADE = 0.55            # the wisent's throat mane and chaps are darker than the coat (vertex colour tint)
FRONT_LEGS = ("upperarm.L", "upperarm.R", "forearm.L", "forearm.R")


def card_parts(triangles, count):
    parent = np.arange(count)

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for a, b, c in triangles:
        parent[root(b)] = root(a)
        parent[root(c)] = root(a)
    part = np.array([root(i) for i in range(count)])
    return [np.flatnonzero(part == i) for i in np.unique(part)]


def yaw(angle):
    c, s = np.cos(angle), np.sin(angle)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def main():
    src, dst = (Path(p) for p in sys.argv[sys.argv.index("--") + 1:][:2])
    model, data = read_glb(src)
    binary = bytearray(data[:model["buffers"][0]["byteLength"]])
    rng = np.random.default_rng(SEED)
    skin = posed_skin(model, binary)          # idle frame 0; world space: +Y up, the head towards -Z
    names = [model["nodes"][j]["name"] for j in model["skins"][0]["joints"]]

    body = next(m for m in model["meshes"] if m["name"] != "BisonFur")["primitives"][0]["attributes"]
    bJ = read_array(model, binary, body["JOINTS_0"]).astype(int)
    bW = read_array(model, binary, body["WEIGHTS_0"]).astype(float)
    B = point_transform(mix_skin(skin, bJ, bW), read_array(model, binary, body["POSITION"]))

    fur = next(m for m in model["meshes"] if m["name"] == "BisonFur")["primitives"][0]
    fa = fur["attributes"]
    fP = read_array(model, binary, fa["POSITION"])
    fJ = read_array(model, binary, fa["JOINTS_0"]).astype(int)
    fW = read_array(model, binary, fa["WEIGHTS_0"]).astype(float)
    fN = read_array(model, binary, fa["NORMAL"])
    fUV = read_array(model, binary, fa["TEXCOORD_0"])
    fC = read_array(model, binary, fa["COLOR_0"])
    fT = read_array(model, binary, fur["indices"]).reshape(-1, 3).astype(int)
    fM = mix_skin(skin, fJ, fW)
    fX = point_transform(fM, fP)
    fNX = np.einsum("nij,nj->ni", fM[:, :3, :3], fN)              # posed normals of the existing cards

    # Templates: the beard's hanging cards, as offsets from their root (the end with the highest V).
    candidates = []
    for ids in card_parts(fT, len(fP)):
        v = fUV[ids, 1]
        root = fX[ids[v >= v.max() - 1e-4]].mean(axis=0)
        tip = fX[ids[v <= v.min() + 1e-4]].mean(axis=0)
        d = tip - root
        length = np.linalg.norm(d)
        # hanging, long enough, and not faded at the mane's hem (an alpha fade turns into a hard cut at the
        # mask threshold)
        if d[1] < -0.8 * length and length > 0.08 and fC[ids, 3].min() > 0.9:
            off = (fX[ids] - root) / length
            off[:, [0, 2]] *= STRAND_WIDTH          # thinner locks than the beard's clumps
            candidates.append((root[1], ids, off))
    # Only the beard (the lowest hanging cards): the collar and brow cards are lighter and shorter.
    cut = np.percentile([c[0] for c in candidates], 40)
    templates = [(ids, off) for y, ids, off in candidates if y <= cut]
    card_of = np.full(len(fP), -1)
    for k, (ids, _) in enumerate(templates):
        card_of[ids] = k
    local_tris = [[] for _ in templates]
    for t in fT:
        k = card_of[t[0]]
        if k >= 0:
            ids = templates[k][0]
            local_tris[k].append(np.searchsorted(ids, t))
    local_tris = [np.array(t) for t in local_tris]

    height = B[:, 1].max() - B[:, 1].min()
    head = B[:, 2].min()                      # muzzle tip
    anchors = []                              # (body vertex, strand length range, sweep back)
    # Throat mane: the lowest hide in each column under the neck and chest, behind the beard, between the legs.
    for z in np.arange(head + 0.30, head + 1.10, SPACING):
        for x in np.arange(-0.24, 0.24 + 1e-6, SPACING):
            col = np.flatnonzero((np.abs(B[:, 2] - z) < SPACING / 2) & (np.abs(B[:, 0] - x) < SPACING / 2))
            if not len(col):
                continue
            low = col[np.argmin(B[col, 1])]
            if B[low, 1] < 0.32 * height:     # a leg hangs here
                continue
            reach = 1 - abs(x) / 0.30          # longest on the midline
            anchors.append((low, THROAT_LENGTH, 0.35, reach))
    # Chaps: hide on the upper front legs, from the elbow to the middle of the forearm.
    leg = np.isin(bJ, [names.index(n) for n in FRONT_LEGS])
    share = (leg * bW).sum(axis=1)
    elbow = np.mean([B[(bJ[:, 0] == names.index(n)) & (bW[:, 0] > 0.6), 1].mean() for n in ("forearm.L", "forearm.R")])
    chaps = np.flatnonzero((share > 0.6) & (B[:, 1] > elbow - 0.18) & (B[:, 1] < elbow + 0.22))
    chaps = rng.choice(chaps, size=min(len(chaps), 260), replace=False)
    anchors += [(i, CHAPS_LENGTH, 0.0, 0.8) for i in chaps]

    new = {"P": [], "N": [], "UV": [], "C": [], "J": [], "W": [], "T": []}
    count = len(fP)
    centre = B.mean(axis=0)
    for vertex, (lo, hi), sweep, reach in anchors:
        k = rng.integers(len(templates))
        ids, off = templates[k]
        length = rng.uniform(lo, hi) * (0.55 + 0.45 * reach)
        r = yaw(rng.uniform(0, 2 * np.pi))
        shape = off @ r.T * length
        # sweep the strand back (+Z) and a touch outward from the body's centre line
        drop = -shape[:, 1:2]
        out = np.sign(B[vertex, 0] - centre[0]) if abs(B[vertex, 0]) > 0.05 else 0
        shape = shape + drop * np.array((0.15 * out, 0, sweep))
        root = B[vertex] + np.array((0, 0.02, 0))           # root just inside the hide
        pts = root + shape
        J = np.tile(bJ[vertex], (len(ids), 1))
        W = np.tile(bW[vertex], (len(ids), 1))
        inverse = np.linalg.inv(mix_skin(skin, J, W))
        new["P"].append(point_transform(inverse, pts))
        n = np.einsum("nij,nj->ni", inverse[:, :3, :3], fNX[ids] @ r.T)   # posed -> this strand's bind pose
        new["N"].append(n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-6))
        new["UV"].append(fUV[ids])
        new["C"].append(fC[ids] * np.array((SHADE, SHADE, SHADE, 1.0)))
        new["J"].append(J)
        new["W"].append(W)
        new["T"].append(local_tris[k] + count)
        count += len(ids)

    P = np.vstack([fP] + new["P"]).astype("<f4")
    fa["POSITION"] = accessor(model, binary, P, "VEC3")
    fa["NORMAL"] = accessor(model, binary, np.vstack([fN] + new["N"]).astype("<f4"), "VEC3")
    fa["TEXCOORD_0"] = accessor(model, binary, np.vstack([fUV] + new["UV"]).astype("<f4"), "VEC2")
    fa["COLOR_0"] = accessor(model, binary, np.vstack([fC] + new["C"]).astype("<f4"), "VEC4")
    fa["JOINTS_0"] = accessor(model, binary, np.vstack([fJ] + new["J"]).astype("<u2"), "VEC4")
    fa["WEIGHTS_0"] = accessor(model, binary, np.vstack([fW] + new["W"]).astype("<f4"), "VEC4")
    tris = np.vstack([fT] + new["T"]).astype("<u4")
    fur["indices"] = accessor(model, binary, tris.ravel(), "SCALAR")
    model["buffers"][0]["byteLength"] = len(binary)
    write_glb(dst, model, binary)
    print(f"Bison fur: {len(anchors)} strands added ({len(chaps)} on the forelegs), {len(templates)} templates")


if __name__ == "__main__":
    main()
