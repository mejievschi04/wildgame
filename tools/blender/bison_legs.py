"""Give the rhino-based bison (prepare_bison_from_rhino.py) bison legs: longer, with slender cannons and narrower
hooves, then scale it back to its game height and retime the gaits.

  blender -b --factory-startup --python tools/blender/bison_legs.py -- bison_from_rhino.glb SK_Bison_Textured.glb

The rhino skeleton is flat: every bone hangs from the root and is keyed in translation, and the hooves are keyed on
the ground. Raising the translation keys of the body bones (the wrist / hock bones part of the way, the hooves not
at all) lengthens the lower legs in every clip. The skin of each lower leg is reweighted into a straight gradient
hoof -> wrist / hock -> elbow / stifle so the stretch spreads over the whole cannon, then slimmed around the leg
axis in the posed idle frame and mapped back to the bind pose.
"""
import struct
import sys
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path[:0] = [str(SCRIPT_DIR), str(SCRIPT_DIR.parent)]
from prepare_bear import read_glb, write_glb
from prepare_bison_from_rhino import mix_skin, point_transform, posed_skin, read_array, smooth
from prepare_megaloceros import accessor

RISE = 0.26                       # metres the body is lifted in the idle pose (elbow 0.67 -> 0.93 m)
LOWER = {"wrist": 0.70, "hock": 0.95}   # share of the rise for the carpus / hock bones
HEIGHT = 1.9                      # withers height in data/animals.json
# Gait timing: ground-contact speed measured on the result (tools: contact.py in the session notes) at the
# source timing, and the game speeds in data/animals.json. The jog clip cannot reach a gallop: at 9 m/s it
# would cycle 4.6 times a second, so the bison runs at 5.5 m/s (cycle 0.31 s).
MEASURED = {"walk": 1.10, "run": 4.03}
SPEEDS = {"walk": 1.4, "run": 5.5}
LEGS = {   # elbow or stifle, wrist or hock, hoof bones
    "fL": ("forearm.L", "Bone_FL_Tarsal_013", ("Bone_FL_Toes_014", "hoof_f.L", "Vfx_FL_Foot_011")),
    "fR": ("forearm.R", "Bone_FR_Tarsal_018", ("Bone_FR_Toes_019", "hoof_f.R", "Vfx_FR_Foot_016")),
    "hL": ("shin.L", "Bone_L_Tarsal_040", ("Bone_BL_Toes_08", "hoof_h.L", "Vfx_BL_Foot_038")),
    "hR": ("shin.R", "Bone_R_Tarsal_048", ("Bone_BR_Toes_09", "hoof_h.R", "Vfx_BR_Foot_046")),
}
UPPER = {"fL": "upperarm.L", "fR": "upperarm.R", "hL": "thigh.L", "hR": "thigh.R"}


def node_worlds(model):
    """Rest world matrix of every node."""
    nodes, world = model["nodes"], {}

    def local(node):
        if "matrix" in node:
            return np.array(node["matrix"]).reshape(4, 4).T
        x, y, z, w = node.get("rotation", (0, 0, 0, 1))
        r = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                      [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                      [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])
        m = np.eye(4)
        m[:3, :3] = r * np.array(node.get("scale", (1, 1, 1)))
        m[:3, 3] = node.get("translation", (0, 0, 0))
        return m

    def walk(i, parent):
        world[i] = parent @ local(nodes[i])
        for c in nodes[i].get("children", []):
            walk(c, world[i])

    for i in model["scenes"][model.get("scene", 0)]["nodes"]:
        walk(i, np.eye(4))
    return world


def tuck_throat(points):
    """The throat filler that closes the head graft hangs below the jaw like a sack. Lift every part of the
    underside between the brisket and the jaw that sags below the straight line joining them; the lift fades out
    towards the middle of the neck. Posed idle space: +Y up, the head towards -Z."""
    y, z = points[:, 1], -points[:, 2]                     # z: forwards
    height = y.max() - y.min()
    mid = np.abs(points[:, 0]) < 0.08 * height
    front = z.max()
    zs = np.arange(front - 0.75 * height, front - 0.05 * height, 0.025 * height)
    under, top = [], []
    for zz in zs:
        s = y[mid & (np.abs(z - zz) < 0.02 * height) & (y > y.min() + 0.2 * height)]
        under.append(np.percentile(s, 5) if len(s) else np.nan)
        top.append(np.percentile(s, 95) if len(s) else np.nan)
    under, top = np.array(under), np.array(top)
    ok = ~np.isnan(under)
    zs, under, top = zs[ok], under[ok], top[ok]
    a = int(np.argmin(under[: len(under) // 2 + 1]))         # brisket: lowest point of the chest
    b = len(zs) - 1                                          # jaw, under the muzzle
    line = np.interp(zs, [zs[a], zs[b]], [under[a], under[b]])
    lift = np.where((zs > zs[a]) & (zs < zs[b]), np.maximum(line - under, 0), 0)
    vz = np.interp(z, zs, lift, left=0, right=0)
    vu = np.interp(z, zs, under)
    vt = np.interp(z, zs, top)
    fade = 1 - smooth(vu, vu + 0.65 * (vt - vu) + 1e-6, y)
    fade *= smooth(vu - 0.04 * height, vu, y)              # the legs hang below the underside: leave them
    points[:, 1] += vz * fade
    print(f"Throat: brisket z {zs[a]:.2f}, jaw z {zs[b]:.2f}, largest lift {lift.max():.2f} m")


def write_array(model, binary, index, array):
    a = model["accessors"][index]
    view = model["bufferViews"][a["bufferView"]]
    offset = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    assert "byteStride" not in view
    data = np.ascontiguousarray(array, dtype=array.dtype).tobytes()
    binary[offset:offset + len(data)] = data


def main():
    src, dst = (Path(p) for p in sys.argv[sys.argv.index("--") + 1:][:2])
    model, data = read_glb(src)
    binary = bytearray(data[:model["buffers"][0]["byteLength"]])
    nodes = model["nodes"]
    skin_def = model["skins"][0]
    joints = skin_def["joints"]
    names = [nodes[j]["name"] for j in joints]
    jid = {n: i for i, n in enumerate(names)}
    skin = posed_skin(model, binary)                          # idle frame 0, world @ inverse bind
    ibm = read_array(model, binary, skin_def["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
    joint_pos = np.array([(s @ np.linalg.inv(b))[:3, 3] for s, b in zip(skin, ibm)])

    # Share of the rise per joint, from its ancestor under the root bone.
    root = next(i for i, n in enumerate(nodes) if n.get("name") == "Bone_Root_01")
    parent = {c: i for i, n in enumerate(nodes) for c in n.get("children", [])}
    hooves = {n for leg in LEGS.values() for n in leg[2]}

    def share(node):
        if node == root or node not in parent:
            return 0.0                                          # the root itself stays on the ground
        while parent.get(node) != root:
            if node not in parent:
                return 0.0
            node = parent[node]
        name = nodes[node]["name"]
        if name in hooves:
            return 0.0
        if "Tarsal" in name:
            return LOWER["hock"] if name.startswith(("Bone_L_", "Bone_R_")) else LOWER["wrist"]
        return 1.0

    k = np.array([share(j) for j in joints])
    root_world = node_worlds(model)[root]
    up_local = np.linalg.solve(root_world[:3, :3], np.array((0.0, RISE, 0.0)))   # world +Y rise in root space

    # Raise the bones: rest translation and every translation key of the root's children.
    top_level = [c for c in nodes[root].get("children", [])]
    lift = {c: up_local * share(c) for c in top_level if share(c) > 0}
    for c, d in lift.items():
        nodes[c]["translation"] = (np.array(nodes[c].get("translation", (0, 0, 0))) + d).tolist()
    for anim in model["animations"]:
        for ch in anim["channels"]:
            node = ch["target"]["node"]
            if ch["target"]["path"] == "translation" and node in lift:
                # samplers can be shared between bones (the hind hooves share one with other bones): give the
                # raised channel its own copy
                sampler = dict(anim["samplers"][ch["sampler"]])
                keys = read_array(model, binary, sampler["output"]) + lift[node]
                sampler["output"] = accessor(model, binary, keys.astype("<f4"), "VEC3")
                anim["samplers"].append(sampler)
                ch["sampler"] = len(anim["samplers"]) - 1
    new_skin = skin.copy()
    new_skin[:, :3, 3] += np.outer(k, (0, RISE, 0))           # the rise is a world translation after the bone

    # Lower legs of the coat: gradient weights, rise, slim.
    coat_mesh = next(m for m in model["meshes"] if m["name"] != "BisonFur")
    coat = coat_mesh["primitives"][0]
    attrs = coat["attributes"]
    P = read_array(model, binary, attrs["POSITION"]).astype(float)
    J = read_array(model, binary, attrs["JOINTS_0"]).astype(int)
    W = read_array(model, binary, attrs["WEIGHTS_0"]).astype(float)
    posed = point_transform(mix_skin(skin, J, W), P)
    ground = posed[:, 1].min()
    member = {leg: np.zeros(len(P)) for leg in LEGS}
    for leg, (knee, wrist, hoof) in LEGS.items():
        bones = [jid[n] for n in (knee, wrist, UPPER[leg]) + hoof]
        member[leg] = (np.isin(J, bones) * W).sum(axis=1)
    which = np.array(list(LEGS))[np.argmax(np.column_stack(list(member.values())), axis=1)]
    for leg, (knee, wrist, hoof) in LEGS.items():
        sel = (which == leg) & (member[leg] > 0.5)
        h = posed[sel, 1] - ground
        hk, hw = joint_pos[jid[knee], 1] - ground, joint_pos[jid[wrist], 1] - ground
        h_hoof = 0.12
        main_hoof = jid[hoof[0]]
        # blend factor: 0 keeps the original weights (hoof, upper arm), 1 uses the gradient
        blend = smooth(h_hoof - 0.04, h_hoof + 0.04, h) * (1 - smooth(hk - 0.12, hk + 0.02, h))
        t_low = np.clip((h - h_hoof) / (hw - h_hoof), 0, 1)
        t_up = np.clip((h - hw) / (hk - hw), 0, 1)
        grad = np.zeros((sel.sum(), 4))
        gj = np.zeros((sel.sum(), 4), dtype=int)
        low = h < hw
        gj[:] = (main_hoof, jid[wrist], jid[knee], jid[UPPER[leg]])
        grad[low, 0], grad[low, 1] = 1 - t_low[low], t_low[low]
        grad[~low, 1], grad[~low, 2] = 1 - t_up[~low], t_up[~low]
        idx = np.flatnonzero(sel)
        for n, v in enumerate(idx):
            acc = {}
            for j, w in zip(J[v], W[v] * (1 - blend[n])):
                acc[j] = acc.get(j, 0) + w
            for j, w in zip(gj[n], grad[n] * blend[n]):
                acc[j] = acc.get(j, 0) + w
            best = sorted(acc.items(), key=lambda t: -t[1])[:4]
            best += [(0, 0.0)] * (4 - len(best))
            total = sum(w for _, w in best) or 1
            J[v] = [j for j, _ in best]
            W[v] = [w / total for _, w in best]
    # Posed positions after the rise (each vertex moves by its weighted share), then slim.
    raised = posed + np.outer((W * k[J]).sum(axis=1), (0, RISE, 0))
    for leg, (knee, wrist, hoof) in LEGS.items():
        sel = (which == leg) & (member[leg] > 0.3)
        m = np.clip((member[leg][sel] - 0.3) / 0.5, 0, 1)
        h = raised[sel, 1] - ground
        axis_pts = [joint_pos[jid[n]] + (0, RISE * k[jid[n]], 0) for n in (hoof[0], wrist, knee)]
        hs = [p[1] - ground for p in axis_pts]
        hs[0] = 0.0
        cx = np.interp(h, hs, [p[0] for p in axis_pts])
        cz = np.interp(h, hs, [p[2] for p in axis_pts])
        # hoof, pastern, slim cannon, wrist / hock, forearm, elbow
        slim = np.interp(h, [0.0, 0.05, 0.14, hs[1], (hs[1] + hs[2]) / 2, hs[2] + 0.05],
                         [0.78, 0.70, 0.60, 0.70, 0.85, 1.0])
        f = 1 - m * (1 - slim)
        raised[sel, 0] = cx + (raised[sel, 0] - cx) * f
        raised[sel, 2] = cz + (raised[sel, 2] - cz) * f
    tuck_throat(raised)
    rest = point_transform(np.linalg.inv(mix_skin(new_skin, J, W)), raised)
    attrs["POSITION"] = accessor(model, binary, rest.astype("<f4"), "VEC3")
    attrs["JOINTS_0"] = accessor(model, binary, J.astype("<u2"), "VEC4")
    attrs["WEIGHTS_0"] = accessor(model, binary, W.astype("<f4"), "VEC4")

    # Retime walk and run so the hooves don't skate at the game speeds.
    for anim in model["animations"]:
        if anim["name"] not in SPEEDS:
            continue
        factor = MEASURED[anim["name"]] / SPEEDS[anim["name"]]
        scaled = {}
        for sampler in anim["samplers"]:
            old = sampler["input"]
            if old not in scaled:
                times = read_array(model, binary, old) * factor
                scaled[old] = accessor(model, binary, times.astype("<f4"), "SCALAR")
                model["accessors"][scaled[old]].update(min=[float(times.min())], max=[float(times.max())])
            sampler["input"] = scaled[old]

    # Game height: scale the scene root.
    height = raised[:, 1].max() - ground
    top = model["scenes"][model.get("scene", 0)]["nodes"][0]
    factor = HEIGHT / height
    nodes[top]["scale"] = (np.array(nodes[top].get("scale", (1, 1, 1))) * factor).tolist()
    print(f"Bison legs: height {height:.2f} -> {HEIGHT} m (x{factor:.3f})")
    model["buffers"][0]["byteLength"] = len(binary)
    write_glb(dst, model, binary)


if __name__ == "__main__":
    main()
