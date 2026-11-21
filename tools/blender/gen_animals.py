# Realistic procedural Pleistocene fauna for WILDBOUND.
#   blender -b --python tools/blender/gen_animals.py -- [species ...]     (default: all)
# Each species = anatomical joints (also the rig) + an SDF sculpt (ribcage, scapulae, haunches, skull,
# muzzle, limbs…) + coat painting rules + hair-card rules + gait parameters. See fauna_lib.py.
import bpy, math, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fauna_lib as fl
from fauna_lib import Sculpt, mirror_joints, loop_clip, std_clips, bite_attack

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "models", "animals")

LEG = ("upperarm", "forearm", "hoof_f", "thigh", "shin", "hoof_h")
LOWLEG = ("forearm", "hoof_f", "shin", "hoof_h")


def mix(a, b, t):
    t = min(max(t, 0.0), 1.0)
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def part(bone):
    return bone.split(".")[0]


def both(fn):
    for s in (1, -1):
        fn(s)


def X(v, s):
    return (v[0] * s, v[1], v[2])


# ===================================================================== WOLF (Canis lupus, Pleistocene)

WOLF_J = mirror_joints({
    "nose": (0, 0.95, 0.735), "head": (0, 0.70, 0.80), "neck2": (0, 0.60, 0.79), "neck": (0, 0.46, 0.74),
    "chest": (0, 0.28, 0.70), "spine": (0, -0.05, 0.68), "hips": (0, -0.33, 0.68),
    "tail": (0, -0.45, 0.67), "tail2": (0, -0.62, 0.50), "tail3": (0, -0.74, 0.30),
    "ear.L": (0.055, 0.655, 0.87), "ear_t.L": (0.07, 0.645, 0.945),
    "sh.L": (0.085, 0.33, 0.56), "el.L": (0.085, 0.22, 0.40), "ca.L": (0.07, 0.255, 0.11), "fh.L": (0.068, 0.30, 0.025),
    "hp.L": (0.085, -0.38, 0.60), "st.L": (0.095, -0.22, 0.43), "ho.L": (0.075, -0.46, 0.21), "hh.L": (0.07, -0.40, 0.025),
})


def wolf_sculpt(J):
    sc = Sculpt()
    sc.ell((0, 0.15, 0.57), (0.12, 0.25, 0.165), k=0.06)          # ribcage, deep & narrow
    sc.ell((0, 0.31, 0.53), (0.095, 0.10, 0.13), (20, 0, 0), k=0.05)  # brisket
    sc.ell((0, -0.12, 0.61), (0.095, 0.21, 0.095), (-6, 0, 0), k=0.06)  # tucked abdomen
    sc.ell((0, -0.04, 0.665), (0.085, 0.30, 0.055), k=0.05)       # loin / topline
    sc.ell((0, -0.33, 0.625), (0.095, 0.13, 0.10), k=0.05)        # pelvis
    both(lambda s: sc.ell((0.07 * s, -0.33, 0.53), (0.055, 0.12, 0.13), (-18, 0, 0), k=0.05))  # haunch
    both(lambda s: sc.ell((0.08 * s, 0.30, 0.61), (0.042, 0.075, 0.13), (28, 0, 0), k=0.05))  # scapula
    both(lambda s: sc.ell((0.07 * s, -0.25, 0.51), (0.05, 0.10, 0.065), (-10, 0, 0), k=0.05))  # flank fold
    sc.cone((0, 0.30, 0.645), (0, 0.585, 0.785), 0.118, 0.085, k=0.05)  # neck
    sc.ell((0, 0.665, 0.81), (0.08, 0.09, 0.072), k=0.03)       # cranium
    sc.ell((0, 0.70, 0.772), (0.088, 0.06, 0.06), k=0.025)       # zygomatic / cheeks
    sc.cone((0, 0.735, 0.785), (0, 0.925, 0.748), 0.05, 0.028, k=0.03)  # muzzle bridge
    sc.cone((0, 0.68, 0.735), (0, 0.895, 0.712), 0.044, 0.023, k=0.025)  # lower jaw
    sc.ell((0, 0.937, 0.742), (0.021, 0.018, 0.017), k=0.012)     # nose leather
    sc.ell((0, 0.745, 0.815), (0.03, 0.03, 0.02), k=0.03)         # stop / brow
    both(lambda s: sc.sphere((0.041 * s, 0.775, 0.80), 0.013, k=0.008, sub=True))  # eye sockets
    both(lambda s: sc.leaf((0.055 * s, 0.655, 0.865), (0.066 * s, 0.647, 0.925), 0.034, 0.01, (s * 0.25, 1, 0), k=0.016))
    both(lambda s: sc.cone((0.062 * s, 0.65, 0.905), (0.072 * s, 0.643, 0.962), 0.013, 0.002, k=0.01))  # pointed ear tip
    for s in (1, -1):
        L = lambda k: X(J[k + ".L"], s)
        sc.cone(L("sh"), L("el"), 0.062, 0.046, k=0.04)
        sc.ell(np.add(L("el"), (0, 0.012, -0.07)), (0.035, 0.038, 0.08), k=0.03)   # forearm muscles
        sc.cone(L("el"), L("ca"), 0.036, 0.024, k=0.025)
        sc.cone(L("ca"), np.add(L("fh"), (0, -0.015, 0.012)), 0.023, 0.022, k=0.012)
        sc.ell(np.add(L("fh"), (0, 0.01, 0.0)), (0.031, 0.045, 0.024), k=0.015)    # front paw
        sc.cone(L("hp"), L("st"), 0.078, 0.05, k=0.04)
        sc.ell(np.add(L("st"), (0, -0.055, -0.06)), (0.036, 0.05, 0.075), (25, 0, 0), k=0.03)  # gaskin
        sc.cone(L("st"), L("ho"), 0.042, 0.024, k=0.025)
        sc.cone(L("ho"), np.add(L("hh"), (0, -0.012, 0.012)), 0.022, 0.021, k=0.012)
        sc.ell(np.add(L("hh"), (0, 0.014, 0.0)), (0.03, 0.043, 0.023), k=0.015)
    sc.cone(J["tail"], J["tail2"], 0.042, 0.03, k=0.03)
    sc.cone(J["tail2"], J["tail3"], 0.03, 0.022, k=0.02)
    return sc


def wolf_coat(p, n, bone):
    x, y, z = p
    pb = part(bone)
    grey, dark, cream, tawny = (0.42, 0.40, 0.37), (0.22, 0.21, 0.20), (0.74, 0.71, 0.64), (0.48, 0.40, 0.31)
    fur, rough = 1.0, 0.88
    c = grey
    if pb in ("spine", "chest", "neck", "neck2", "hips"):
        c = mix(grey, dark, min((n[2] - 0.3) * 1.5, 0.45))       # grizzled dark saddle
        c = mix(c, cream, (-n[2] - 0.25) * 2.0)                 # pale underside
        if pb in ("neck", "neck2") and n[2] < 0.2:
            c = mix(c, cream, 0.6)
    elif pb in LEG:
        c = mix(tawny, cream, (-n[0] * np.sign(x) - 0.2) * 1.2)  # inner leg pale
        if pb == "upperarm" or pb == "thigh":
            c = mix(grey, c, 0.6)
        if z < 0.05:
            c = mix(c, (0.35, 0.29, 0.22), 0.5)
    elif pb in ("head", "snout"):
        c = mix(tawny, grey, 0.55)
        if n[2] > 0.6 and y < 0.76:
            c = mix(c, dark, 0.35)                              # darker forehead
        if abs(abs(x) - 0.041) < 0.022 and abs(y - 0.776) < 0.022 and abs(z - 0.80) < 0.02:
            c = mix(c, (0.1, 0.08, 0.07), 0.7)                  # dark eye rims
        if y > 0.72 and n[2] < 0.35:
            c = mix(c, cream, 0.75)                             # pale muzzle sides & cheeks
        if y > 0.72 and n[2] > 0.5:
            c = mix(c, (0.38, 0.31, 0.24), 0.5)                 # darker bridge
        if y > 0.9 and z < 0.725:
            c = (0.16, 0.13, 0.11)                              # lips
        if y > 0.925:
            c, fur, rough = (0.05, 0.045, 0.045), 0.0, 0.35     # nose leather
    elif pb == "ear":
        c = mix(dark, tawny, 0.3) if n[1] < 0.2 else mix(cream, tawny, 0.5)
    elif pb in ("tail", "tail_tip"):
        c = mix(grey, dark, (n[2] + 0.1) * 1.2)
        if y < -0.66:
            c = (0.1, 0.09, 0.085)
    return c, fur, rough


def wolf_hair(p, n, bone):
    x, y, z = p
    pb = part(bone)
    down = (0, -0.5, -1.0)
    back = (0, -1.0, -0.25)
    if pb in ("neck", "neck2") or (pb == "chest" and y > 0.2):
        return 0.10, 0.25, 0.55, 0.024, back                 # ruff / mane
    if pb == "head" and y < 0.73 and n[2] < 0.6 and abs(n[0]) > 0.4:
        return 0.05, 0.2, 0.2, 0.02, (0, -1, -0.2)            # cheek ruff
    if pb == "head" and y < 0.76:
        return 0.025, 0.1, 0.1, 0.016, (0, -1, -0.1)          # short head fur
    if pb in ("chest", "spine", "hips"):
        if n[2] > 0.2:
            return 0.055, 0.15, 0.4, 0.022, back
        return 0.045, 0.12, 0.7, 0.022, down
    if pb in ("upperarm", "thigh") and z > 0.3:
        return 0.03, 0.08, 0.6, 0.018, (0, -0.3, -1)
    if pb == "thigh" and z > 0.42:
        return 0.045, 0.12, 0.7, 0.022, (0, -0.6, -1)          # breeches
    if pb in ("tail", "tail_tip"):
        return 0.10, 0.35, 0.25, 0.03, (0, -0.55, -0.85)
    return 0.0, 0, 0, 0, down


WOLF_WALK = {"period": 0.95, "duty": 0.62, "amp_f": 17, "amp_h": 15, "lift": 48,
             "phases": {"hL": 0.0, "fL": -0.25, "hR": -0.5, "fR": -0.75},
             "bob": 0.012, "bob_freq": 2, "spine": 1.5, "yaw": 3, "head": 2.5, "tail": 4}
WOLF_RUN = {"period": 0.46, "duty": 0.36, "amp_f": 36, "amp_h": 32, "lift": 75,
            "phases": {"hL": 0.0, "hR": -0.08, "fR": -0.42, "fL": -0.52},
            "bob": 0.05, "bob_freq": 1, "spine": 9, "yaw": 1, "head": 3, "tail": 6}

WOLF = {
    "name": "Wolf", "J": WOLF_J, "sculpt": wolf_sculpt, "voxel": 0.0075, "tris": 14000,
    "coat": wolf_coat, "hair": wolf_hair, "card_density": 5200,
    "hair_palette": [(0.42, 0.40, 0.37), (0.25, 0.24, 0.22), (0.72, 0.69, 0.62), (0.48, 0.40, 0.31)],
    "fur_scale": 260.0, "fur_stretch": 9.0, "bump": 0.6,
    "eyes": [((0.041, 0.776, 0.80), 0.0115)], "eye_color": (0.42, 0.28, 0.08),
    "graze_pose": {"neck": -40, "neck2": -20, "head": -10, "arm": 4, "drop": 0.01},
    "attack": lambda rig: bite_attack(rig, WOLF, 0.28),
    "clips": lambda rig: std_clips(rig, WOLF, WOLF_WALK, WOLF_RUN),
}

import species_more as more  # noqa: E402  (needs std_clips above)
import species_mega as mega  # noqa: E402
SPECIES = {"wolf": WOLF, "deer": more.DEER, "roe": more.ROE, "bear": more.BEAR, "mammoth": more.MAMMOTH,
           "rhino": mega.RHINO}


# ===================================================================== build

def build(sp):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = fl.FPS
    J = sp["J"]
    body = fl.sculpt_to_mesh(sp["sculpt"](J), sp["name"], sp["voxel"], sp["tris"])
    which, names = fl.write_attributes(body, sp)
    fl.bake_maps(body, sp, OUT, sp.get("tex", 2048))
    cards, roots = (None, None)
    if sp.get("hair"):
        cards, roots = fl.build_cards(body, sp, which, names, OUT)
        fl.card_normals_from_body(cards, roots, body)
    rig = fl.build_rig(sp)
    fl.activate(body)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
    rigid = []
    eye_m = fl.simple_mat(f"M_{sp['name']}_Eye", sp.get("eye_color", (0.2, 0.12, 0.05)), 0.04, 0.9)
    for c, r in sp.get("eyes", []):
        for s in (1, -1):
            e = fl.eye("Eye", (c[0] * s, c[1], c[2]), r, eye_m)
            fl.rigid_to_bone(e, "head")
            rigid.append(e)
    for obj, bone in sp.get("parts", lambda: [])():
        fl.rigid_to_bone(obj, bone)
        rigid.append(obj)
    if rigid:
        fl.join_into(body, rigid)
    if cards:
        fl.transfer_card_weights(cards, roots, body)
        cards.parent = rig
        mod = cards.modifiers.new("Armature", "ARMATURE")
        mod.object = rig
    clips = fl.make_clips(rig, sp)
    path = os.path.join(OUT, f"SK_{sp['name']}.gltf")
    fl.export(body, rig, path)
    tb = sum(len(p.vertices) - 2 for p in body.data.polygons)
    tc = sum(len(p.vertices) - 2 for p in cards.data.polygons) if cards else 0
    print("ANIMAL", sp["name"], "body_tris", tb, "card_tris", tc, "clips", clips)


def main():
    args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    for k in (args or list(SPECIES.keys())):
        build(SPECIES[k])


if __name__ == "__main__":
    main()
