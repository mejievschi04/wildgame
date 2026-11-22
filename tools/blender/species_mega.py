# Pleistocene megafauna, step by step — imported by gen_animals.py.
import math
import numpy as np
import fauna_lib as fl
from fauna_lib import Sculpt, mirror_joints, std_clips


def mix(a, b, t):
    t = min(max(t, 0.0), 1.0)
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def part(bone):
    return bone.split(".")[0]


def X(v, s):
    return (v[0] * s, v[1], v[2])


LEG = ("upperarm", "forearm", "hoof_f", "thigh", "shin", "hoof_h")
TORSO = ("spine", "chest", "hips")


def horn_attack(rig, lunge=0.5, dur=1.1):
    """Head low, then an upward toss — horns/tusks; used by rhino and bison."""
    n = int(dur * fl.FPS)
    for f in range(n + 1):
        t = f / n
        low = math.sin(min(t / 0.35, 1.0) * math.pi * 0.5) if t < 0.35 else max(0.0, 1 - (t - 0.35) / 0.25)
        toss = math.sin(max(0.0, min((t - 0.35) / 0.35, 1.0)) * math.pi)
        r = fl.zero_pose(rig)
        r["neck"] = (-14 * low + 12 * toss, 0, 0)
        r["head"] = (-12 * low + 26 * toss, 0, 8 * toss)
        r["ear.L"] = (-30 * (low + toss), 0, 0)
        r["ear.R"] = (-30 * (low + toss), 0, 0)
        for s in ("L", "R"):
            r[f"upperarm.{s}"] = (-10 * low + 12 * toss, 0, 0)
            r[f"thigh.{s}"] = (14 * low, 0, 0)
        r["tail"] = (35 * (low + toss), 0, 0)
        fl.key(rig, f + 1, r, (0, lunge * (0.3 * low + toss), 0.05 * toss))
    return n


# ===================================================================== WOOLLY RHINO (Coelodonta antiquitatis)

RHINO_J = mirror_joints({
    "nose": (0, 1.76, 0.84), "head": (0, 1.15, 1.17), "neck2": (0, 1.05, 1.2), "neck": (0, 0.85, 1.30),
    "chest": (0, 0.55, 1.45), "spine": (0, 0.0, 1.36), "hips": (0, -0.75, 1.30),
    "tail": (0, -1.0, 1.25), "tail2": (0, -1.1, 1.02), "tail3": (0, -1.12, 0.86),
    "ear.L": (0.12, 1.10, 1.42), "ear_t.L": (0.17, 1.02, 1.57),
    "sh.L": (0.30, 0.55, 1.0), "el.L": (0.30, 0.42, 0.56), "ca.L": (0.28, 0.50, 0.22), "fh.L": (0.28, 0.55, 0.05),
    "hp.L": (0.30, -0.75, 1.05), "st.L": (0.32, -0.50, 0.62), "ho.L": (0.28, -0.75, 0.30), "hh.L": (0.28, -0.68, 0.05),
})
RHINO_EYE = (0.205, 1.35, 1.03)


def rhino_sculpt(J):
    sc = Sculpt()
    sc.ell((0, 0.15, 1.05), (0.55, 0.75, 0.50), k=0.18)           # barrel ribcage
    sc.ell((0, 0.55, 1.45), (0.32, 0.38, 0.22), k=0.16)           # shoulder hump
    sc.ell((0, -0.35, 1.0), (0.55, 0.60, 0.48), k=0.18)           # belly
    sc.ell((0, -0.75, 1.10), (0.42, 0.38, 0.38), k=0.14)          # rump
    for s in (1, -1):
        sc.ell((0.28 * s, -0.70, 0.95), (0.20, 0.32, 0.38), (-8, 0, 0), k=0.1)
        sc.ell((0.32 * s, 0.50, 1.0), (0.20, 0.30, 0.42), (12, 0, 0), k=0.1)
    sc.cone((0, 0.55, 1.22), (0, 1.05, 1.16), 0.42, 0.30, k=0.12)  # thick neck
    sc.ell((0, 1.12, 1.20), (0.25, 0.28, 0.24), k=0.08)           # cranium
    sc.cone((0, 1.05, 1.15), (0, 1.70, 0.83), 0.28, 0.13, k=0.08)  # long, low-carried head
    sc.ell((0, 1.60, 0.90), (0.15, 0.15, 0.13), k=0.06)           # nasal boss (horn base)
    sc.ell((0, 1.70, 0.77), (0.12, 0.08, 0.07), k=0.08)           # broad grazing lips
    sc.ell((0, 1.40, 0.82), (0.18, 0.30, 0.12), k=0.06)           # jaw
    for s in (1, -1):
        sc.sphere((0.215 * s, RHINO_EYE[1], RHINO_EYE[2]), 0.03, k=0.02, sub=True)
        sc.leaf((0.12 * s, 1.10, 1.40), (0.17 * s, 1.02, 1.57), 0.09, 0.025, (0.3 * s, -1, 0.2), k=0.04)
        L = lambda k: X(J[k + ".L"], s)
        sc.cone(L("sh"), L("el"), 0.22, 0.16, k=0.08)
        sc.cone(L("el"), L("ca"), 0.15, 0.12, k=0.06)
        sc.cone(L("ca"), L("fh"), 0.12, 0.14, k=0.05)
        sc.ell(np.add(L("fh"), (0, 0.03, 0.02)), (0.14, 0.15, 0.06), k=0.04)
        sc.cone(L("hp"), L("st"), 0.25, 0.17, k=0.09)
        sc.cone(L("st"), L("ho"), 0.15, 0.11, k=0.06)
        sc.cone(L("ho"), L("hh"), 0.11, 0.13, k=0.05)
        sc.ell(np.add(L("hh"), (0, 0.03, 0.02)), (0.13, 0.14, 0.06), k=0.04)
    sc.cone(J["tail"], J["tail2"], 0.06, 0.03, k=0.04)
    sc.cone(J["tail2"], J["tail3"], 0.03, 0.02, k=0.02)
    return sc


def rhino_coat(p, n, bone):
    x, y, z = p
    pb = part(bone)
    base, light, dark, skin = (0.38, 0.25, 0.15), (0.50, 0.36, 0.22), (0.22, 0.15, 0.10), (0.17, 0.15, 0.14)
    fur, rough = 1.0, 0.9
    c = mix(base, light, (n[2] - 0.3) * 1.2)
    if pb in LEG:
        c = mix(base, dark, (0.9 - z) * 1.2)
        if z < 0.06:
            c, fur, rough = skin, 0.1, 0.8
    if pb in ("head", "snout"):
        c = mix(base, light, 0.4)
        if y > 1.55:
            c, fur, rough = mix(skin, dark, 0.5), 0.4, 0.75               # bare muzzle
        elif y > 1.45:
            c = mix(c, skin, 0.5)
        if abs(abs(x) - RHINO_EYE[0]) < 0.04 and abs(y - RHINO_EYE[1]) < 0.04 and abs(z - RHINO_EYE[2]) < 0.04:
            c = mix(c, (0.07, 0.06, 0.05), 0.6)
    if pb == "ear":
        c = dark if z > 1.47 else mix(base, light, 0.4)
    return c, fur, rough


def rhino_hair(p, n, bone):
    x, y, z = p
    pb = part(bone)
    if pb == "ear" and z < 1.47:
        return 0.14, 0.3, 0.5, 0.06, (0, -1, 0)
    if pb in ("head", "snout"):
        if y < 1.3 and n[2] > 0.2:
            return 0.14, 0.3, 0.5, 0.06, (0, -1, 0)                      # forelock
        if y < 1.48 and n[2] > -0.3:
            return 0.07, 0.15, 0.4, 0.045, (0, -1, -0.2)                 # short face fur
        if n[2] < -0.4 and y < 1.5:
            return 0.22, 0.1, 0.9, 0.06, (0, -0.2, -1)                   # chin beard
        return 0.0, 0, 0, 0, (0, 0, -1)
    if pb in ("neck", "neck2"):
        return (0.30 if n[2] < 0 else 0.22), 0.15, 0.8, 0.07, (0, -0.6, -1)
    if pb in TORSO:
        if n[2] > 0.5:
            return 0.22, 0.25, 0.6, 0.07, (0, -1, -0.5)
        return min(0.25 + max(0.0, 1.3 - z) * 0.35, 0.5), 0.05, 1.0, 0.075, (0, -0.3, -1)
    if pb in ("upperarm", "thigh"):
        return 0.28, 0.05, 1.0, 0.065, (0, -0.2, -1)
    if pb in ("forearm", "shin"):
        return (0.18 if z > 0.2 else 0.1), 0.05, 1.0, 0.055, (0, -0.1, -1)
    if pb == "tail_tip":
        return 0.15, 0.1, 1.0, 0.04, (0, -0.2, -1)
    return 0.0, 0, 0, 0, (0, 0, -1)


def rhino_parts():
    keratin = fl.simple_mat("M_Rhino_Horn", (0.24, 0.20, 0.16), 0.5)
    front = fl.tube("Horn", [(0, 1.59, 0.96), (0, 1.74, 1.24), (0, 1.94, 1.53), (0, 2.18, 1.78)],
                    0.095, 0.012, ring=12, n=20, mat=keratin, power=0.9)
    rear = fl.tube("Horn2", [(0, 1.40, 1.12), (0, 1.45, 1.27), (0, 1.52, 1.40)], 0.075, 0.01, ring=10, n=10, mat=keratin)
    for h in (front, rear):  # rhino horns are laterally flattened
        for v in h.data.vertices:
            v.co.x *= 0.55
    return [(front, "head"), (rear, "head")]


def rhino_clips(rig):
    walk = {"period": 1.5, "duty": 0.66, "amp_f": 15, "amp_h": 13, "lift": 38,
            "phases": {"hL": 0.0, "fL": -0.25, "hR": -0.5, "fR": -0.75},
            "bob": 0.025, "bob_freq": 2, "spine": 1, "yaw": 3, "head": 3, "tail": 5}
    run = {"period": 0.72, "duty": 0.45, "amp_f": 27, "amp_h": 25, "lift": 52,
           "phases": {"hL": 0.0, "hR": -0.12, "fR": -0.45, "fL": -0.55},
           "bob": 0.06, "bob_freq": 1, "spine": 4, "yaw": 1, "head": 3, "tail": 12}
    return std_clips(rig, RHINO, walk, run)


RHINO = {
    "name": "Rhino", "J": RHINO_J, "sculpt": rhino_sculpt, "voxel": 0.016, "tris": 16000,
    "coat": rhino_coat, "hair": rhino_hair, "card_density": 480,
    "hair_palette": [(0.38, 0.25, 0.15), (0.50, 0.36, 0.22), (0.22, 0.15, 0.10), (0.44, 0.30, 0.18)],
    "fur_scale": 110.0, "fur_stretch": 6.0, "bump": 0.75, "strands_per_card": 180,
    "eyes": [((0.205, 1.35, 1.03), 0.022)], "eye_color": (0.10, 0.06, 0.04),
    "parts": rhino_parts, "attack": lambda rig: horn_attack(rig, 0.6), "clips": rhino_clips,
    "graze_pose": {"neck": -18, "neck2": -8, "head": -14, "arm": 3, "drop": 0.03},
}


# ===================================================================== STEPPE BISON (Bison priscus)

BISON_J = mirror_joints({
    "nose": (0, 1.63, 0.94), "head": (0, 1.20, 1.30), "neck2": (0, 1.08, 1.35), "neck": (0, 0.90, 1.45),
    "chest": (0, 0.55, 1.62), "spine": (0, 0.0, 1.45), "hips": (0, -0.70, 1.35),
    "tail": (0, -0.92, 1.30), "tail2": (0, -1.0, 1.02), "tail3": (0, -1.02, 0.76),
    "ear.L": (0.17, 1.15, 1.42), "ear_t.L": (0.28, 1.10, 1.44),
    "sh.L": (0.22, 0.55, 1.15), "el.L": (0.22, 0.42, 0.72), "ca.L": (0.19, 0.48, 0.33), "fh.L": (0.18, 0.52, 0.04),
    "hp.L": (0.22, -0.72, 1.18), "st.L": (0.24, -0.48, 0.80), "ho.L": (0.19, -0.76, 0.45), "hh.L": (0.18, -0.70, 0.04),
})
BISON_EYE = (0.215, 1.31, 1.29)


def bison_sculpt(J):
    sc = Sculpt()
    sc.ell((0, 0.20, 1.20), (0.40, 0.62, 0.48), k=0.15)           # ribcage
    sc.ell((0, 0.50, 1.70), (0.30, 0.42, 0.35), k=0.15)           # great shoulder hump
    sc.ell((0, 0.20, 1.60), (0.24, 0.40, 0.22), k=0.14)
    sc.ell((0, -0.35, 1.15), (0.36, 0.48, 0.38), k=0.15)          # belly
    sc.ell((0, -0.70, 1.25), (0.30, 0.30, 0.28), k=0.12)          # slim hindquarters
    for s in (1, -1):
        sc.ell((0.20 * s, -0.66, 1.08), (0.14, 0.26, 0.32), (-10, 0, 0), k=0.09)
        sc.ell((0.25 * s, 0.50, 1.12), (0.16, 0.28, 0.40), (12, 0, 0), k=0.09)
    sc.cone((0, 0.60, 1.38), (0, 1.05, 1.30), 0.40, 0.30, k=0.12)  # deep neck
    sc.ell((0, 1.18, 1.32), (0.24, 0.24, 0.24), k=0.08)           # broad skull
    sc.cone((0, 1.20, 1.25), (0, 1.60, 0.98), 0.22, 0.12, k=0.07)  # face
    sc.ell((0, 1.61, 0.95), (0.12, 0.08, 0.10), k=0.05)           # muzzle
    sc.ell((0, 1.38, 1.02), (0.15, 0.26, 0.10), k=0.06)           # jaw
    for s in (1, -1):
        sc.sphere((0.228 * s, BISON_EYE[1], BISON_EYE[2]), 0.028, k=0.02, sub=True)
        sc.leaf((0.17 * s, 1.15, 1.42), (0.28 * s, 1.10, 1.44), 0.07, 0.02, (0, -1, 0.3), k=0.03)
        L = lambda k: X(J[k + ".L"], s)
        sc.cone(L("sh"), L("el"), 0.17, 0.11, k=0.07)
        sc.ell(np.add(L("el"), (0, 0.01, -0.1)), (0.07, 0.08, 0.12), k=0.05)
        sc.cone(L("el"), L("ca"), 0.09, 0.055, k=0.05)
        sc.cone(L("ca"), np.add(L("fh"), (0, -0.01, 0.06)), 0.055, 0.048, k=0.03)
        sc.ell(np.add(L("fh"), (0, 0.02, 0.03)), (0.06, 0.08, 0.045), (-12, 0, 0), k=0.025)
        sc.cone(L("hp"), L("st"), 0.20, 0.12, k=0.08)
        sc.ell(np.add(L("st"), (0, -0.09, -0.09)), (0.07, 0.10, 0.13), (25, 0, 0), k=0.05)
        sc.cone(L("st"), L("ho"), 0.10, 0.05, k=0.05)
        sc.cone(L("ho"), np.add(L("hh"), (0, -0.01, 0.06)), 0.05, 0.047, k=0.03)
        sc.ell(np.add(L("hh"), (0, 0.02, 0.03)), (0.058, 0.078, 0.045), (-12, 0, 0), k=0.025)
    sc.cone(J["tail"], J["tail2"], 0.05, 0.03, k=0.04)
    sc.cone(J["tail2"], J["tail3"], 0.03, 0.02, k=0.02)
    return sc


def bison_coat(p, n, bone):
    x, y, z = p
    pb = part(bone)
    front, rear, dark, muzzle = (0.24, 0.16, 0.10), (0.46, 0.33, 0.21), (0.13, 0.09, 0.07), (0.24, 0.21, 0.19)
    fur, rough = 1.0, 0.9
    c = mix(rear, front, (y + 0.15) * 1.6)                                  # dark forequarters, tawny rear
    if pb in LEG:
        c = mix(c, dark, (0.8 - z) * 1.4)
        if z < 0.06:
            c, fur, rough = (0.07, 0.06, 0.055), 0.0, 0.45
    if pb in ("head", "snout"):
        c = front
        if y > 1.50:
            c = mix(front, muzzle, 0.7)
        if y > 1.62 and n[2] > -0.3:
            c, fur, rough = (0.06, 0.055, 0.05), 0.0, 0.3
        if abs(abs(x) - BISON_EYE[0]) < 0.04 and abs(y - BISON_EYE[1]) < 0.04 and abs(z - BISON_EYE[2]) < 0.04:
            c = mix(c, (0.05, 0.04, 0.035), 0.7)
    if pb in ("ear", "neck", "neck2"):
        c = front
    if pb == "tail_tip":
        c = dark
    return c, fur, rough


def bison_hair(p, n, bone):
    x, y, z = p
    pb = part(bone)
    if pb in ("head", "snout"):
        if n[2] < -0.3 and y < 1.5:
            return 0.36, 0.1, 0.9, 0.07, (0, -0.2, -1)                    # beard
        if y < 1.40 and n[2] > -0.1:
            return 0.17, 0.35, 0.4, 0.06, (0, -0.6, 0.3)                  # woolly crown
        if y < 1.42:
            return 0.2, 0.2, 0.7, 0.06, (0, -0.5, -1)                     # cheeks blend into the mane
        return 0.0, 0, 0, 0, (0, 0, -1)
    if pb in ("ear",):
        return 0.12, 0.3, 0.5, 0.05, (0, -1, 0)
    if pb in ("neck", "neck2") or (pb == "chest" and y > 0.2):
        return (0.34 if n[2] < 0 else 0.26), 0.25, 0.7, 0.07, (0, -0.5, -1)  # mane
    if pb in TORSO:
        if y > 0.05:
            return 0.2, 0.2, 0.7, 0.06, (0, -0.8, -1)
        return 0.045, 0.05, 0.3, 0.035, (0, -1, -0.4)                    # short summer coat behind
    if pb == "upperarm":
        return 0.24, 0.1, 0.9, 0.06, (0, -0.2, -1)                        # forelimb chaps
    if pb == "forearm" and z > 0.45:
        return 0.16, 0.05, 1.0, 0.05, (0, -0.1, -1)
    if pb == "tail_tip":
        return 0.2, 0.1, 1.0, 0.04, (0, -0.2, -1)
    return 0.0, 0, 0, 0, (0, 0, -1)


def bison_parts():
    horn = fl.simple_mat("M_Bison_Horn", (0.13, 0.12, 0.11), 0.4)
    out = []
    for s in (1, -1):
        pts = [(0.15 * s, 1.27, 1.42), (0.31 * s, 1.29, 1.45), (0.43 * s, 1.33, 1.56), (0.47 * s, 1.40, 1.70), (0.43 * s, 1.47, 1.80)]
        out.append((fl.tube("Horn", pts, 0.065, 0.01, ring=12, n=20, mat=horn, power=0.8), "head"))
    return out


def bison_clips(rig):
    walk = {"period": 1.3, "duty": 0.65, "amp_f": 17, "amp_h": 15, "lift": 45,
            "phases": {"hL": 0.0, "fL": -0.25, "hR": -0.5, "fR": -0.75},
            "bob": 0.02, "bob_freq": 2, "spine": 1, "yaw": 2, "head": 3, "tail": 5}
    run = {"period": 0.6, "duty": 0.38, "amp_f": 32, "amp_h": 30, "lift": 70,
           "phases": {"hL": 0.0, "hR": -0.12, "fR": -0.45, "fL": -0.55},
           "bob": 0.06, "bob_freq": 1, "spine": 5, "yaw": 1, "head": 4, "tail": 14}
    return std_clips(rig, BISON, walk, run)


BISON = {
    "name": "Bison", "J": BISON_J, "sculpt": bison_sculpt, "voxel": 0.013, "tris": 16000,
    "coat": bison_coat, "hair": bison_hair, "card_density": 650,
    "hair_palette": [(0.24, 0.16, 0.10), (0.34, 0.24, 0.15), (0.14, 0.10, 0.07), (0.46, 0.33, 0.21)],
    "fur_scale": 140.0, "fur_stretch": 6.0, "bump": 0.7, "strands_per_card": 180,
    "eyes": [(BISON_EYE, 0.02)], "eye_color": (0.08, 0.05, 0.03),
    "parts": bison_parts, "attack": lambda rig: horn_attack(rig, 0.5), "clips": bison_clips,
    "graze_pose": {"neck": -30, "neck2": -12, "head": -10, "arm": 5, "drop": 0.03},
}


# ===================================================================== WILD HORSE (Equus ferus, Przewalski-type)

HORSE_J = mirror_joints({
    "nose": (0, 1.27, 1.10), "head": (0, 0.92, 1.52), "neck2": (0, 0.85, 1.50), "neck": (0, 0.66, 1.32),
    "chest": (0, 0.45, 1.18), "spine": (0, 0.0, 1.12), "hips": (0, -0.50, 1.15),
    "tail": (0, -0.66, 1.12), "tail2": (0, -0.76, 0.90), "tail3": (0, -0.80, 0.66),
    "ear.L": (0.05, 0.90, 1.60), "ear_t.L": (0.075, 0.875, 1.73),
    "sh.L": (0.16, 0.45, 1.00), "el.L": (0.15, 0.36, 0.78), "ca.L": (0.13, 0.40, 0.40), "fh.L": (0.12, 0.44, 0.04),
    "hp.L": (0.15, -0.52, 1.05), "st.L": (0.17, -0.32, 0.80), "ho.L": (0.13, -0.58, 0.48), "hh.L": (0.12, -0.52, 0.04),
})
HORSE_EYE = (0.09, 1.0, 1.465)


def horse_sculpt(J):
    sc = Sculpt()
    sc.ell((0, 0.15, 0.98), (0.24, 0.42, 0.30), k=0.1)            # ribcage
    sc.ell((0, 0.44, 0.92), (0.17, 0.14, 0.20), (20, 0, 0), k=0.08)  # brisket
    sc.ell((0, -0.15, 0.98), (0.24, 0.36, 0.27), k=0.1)           # round belly
    sc.ell((0, -0.05, 1.16), (0.14, 0.50, 0.08), k=0.08)          # topline
    sc.ell((0, -0.50, 1.08), (0.20, 0.22, 0.17), k=0.08)          # croup
    for s in (1, -1):
        sc.ell((0.13 * s, -0.46, 0.95), (0.10, 0.20, 0.24), (-12, 0, 0), k=0.07)
        sc.ell((0.15 * s, 0.40, 1.05), (0.07, 0.13, 0.22), (25, 0, 0), k=0.07)
        sc.ell((0.13 * s, -0.32, 0.85), (0.09, 0.14, 0.10), (-10, 0, 0), k=0.07)
    sc.cone((0, 0.42, 1.05), (0, 0.86, 1.47), 0.23, 0.13, k=0.08)  # neck
    sc.ell((0, 0.63, 1.37), (0.09, 0.22, 0.12), (-40, 0, 0), k=0.07)  # crest
    sc.ell((0, 0.95, 1.41), (0.10, 0.14, 0.14), k=0.05)           # jowls
    sc.cone((0, 0.94, 1.47), (0, 1.24, 1.13), 0.092, 0.072, k=0.05)  # long head
    sc.cone((0, 0.92, 1.36), (0, 1.20, 1.07), 0.07, 0.05, k=0.05)   # jaw
    sc.ell((0, 1.26, 1.10), (0.08, 0.075, 0.08), k=0.04)          # muzzle
    for s in (1, -1):
        sc.sphere((0.098 * s, HORSE_EYE[1], HORSE_EYE[2]), 0.022, k=0.012, sub=True)
        sc.leaf((0.05 * s, 0.90, 1.58), (0.075 * s, 0.875, 1.73), 0.035, 0.012, (s * 0.3, 1, 0), k=0.02)
        L = lambda k: X(J[k + ".L"], s)
        sc.cone(L("sh"), L("el"), 0.10, 0.07, k=0.06)
        sc.ell(np.add(L("el"), (0, 0.01, -0.09)), (0.05, 0.06, 0.11), k=0.04)
        sc.cone(L("el"), L("ca"), 0.065, 0.036, k=0.04)
        sc.cone(L("ca"), np.add(L("fh"), (0, -0.01, 0.08)), 0.034, 0.03, k=0.02)
        sc.sphere(np.add(L("fh"), (0, -0.01, 0.085)), 0.04, k=0.02)                      # fetlock
        sc.cone(np.add(L("fh"), (0, 0.0, 0.07)), np.add(L("fh"), (0, 0.02, 0.0)), 0.038, 0.055, k=0.02)  # hoof
        sc.cone(L("hp"), L("st"), 0.13, 0.075, k=0.06)
        sc.ell(np.add(L("st"), (0, -0.08, -0.08)), (0.05, 0.07, 0.11), (25, 0, 0), k=0.04)
        sc.cone(L("st"), L("ho"), 0.07, 0.036, k=0.04)
        sc.cone(L("ho"), np.add(L("hh"), (0, -0.01, 0.08)), 0.034, 0.03, k=0.02)
        sc.sphere(np.add(L("hh"), (0, -0.01, 0.085)), 0.04, k=0.02)
        sc.cone(np.add(L("hh"), (0, 0.0, 0.07)), np.add(L("hh"), (0, 0.02, 0.0)), 0.038, 0.055, k=0.02)
    sc.cone(J["tail"], J["tail2"], 0.05, 0.035, k=0.04)
    return sc


def horse_coat(p, n, bone):
    x, y, z = p
    pb = part(bone)
    dun, pale, dark, mealy = (0.62, 0.50, 0.34), (0.80, 0.72, 0.58), (0.14, 0.11, 0.09), (0.82, 0.76, 0.64)
    fur, rough = 1.0, 0.85
    c = mix(dun, pale, (-n[2] - 0.35) * 2.0)
    if pb in TORSO and abs(x) < 0.03 and n[2] > 0.8:
        c = mix(c, dark, 0.7)                                                # dorsal stripe
    if pb in LEG:
        c = mix(c, dark, (0.62 - z) * 3.0)                                   # dark points
        if z < 0.07:
            c, fur, rough = (0.10, 0.09, 0.08), 0.0, 0.5
    if 0.40 < y < 0.93 and z > 1.15 and n[2] > 0.5 and abs(x) < 0.06:
        c = dark                                                             # mane base
    if pb in ("head", "snout"):
        c = dun
        if y > 1.12:
            c = mealy                                                        # mealy muzzle
        if y > 1.28 or (y > 1.2 and z < 1.06):
            c, fur, rough = (0.12, 0.10, 0.09), 0.3, 0.4
        if abs(abs(x) - HORSE_EYE[0]) < 0.03 and abs(y - HORSE_EYE[1]) < 0.03 and abs(z - HORSE_EYE[2]) < 0.03:
            c = mix(c, mealy, 0.5)                                           # pale eye ring
    if pb == "ear":
        c = mix(dun, dark, (z - 1.62) * 8)
    if pb in ("tail", "tail_tip"):
        c = dark
    return c, fur, rough


def horse_hair(p, n, bone):
    x, y, z = p
    pb = part(bone)
    if 0.40 < y < 0.93 and z > 1.2 and n[2] > 0.2 and abs(x) < 0.085:
        return 0.15, 0.92, 0.05, 0.03, (0, -0.2, 1)                          # short erect mane, poll→withers
    if pb == "head" and y < 0.98 and n[2] > 0.5:
        return 0.08, 0.6, 0.2, 0.03, (0, 1, 0.3)                             # forelock
    if pb in ("tail", "tail_tip") and abs(x) < 0.06 and y < -0.64:
        return 0.62, 0.05, 1.0, 0.05, (0, -0.15, -1)                         # long tail
    if pb in TORSO or pb in ("neck",):
        return 0.03, 0.08, 0.5, 0.02, (0, -1, -0.5)                          # winter coat
    return 0.0, 0, 0, 0, (0, 0, -1)


def horse_clips(rig):
    walk = {"period": 1.1, "duty": 0.62, "amp_f": 20, "amp_h": 18, "lift": 55,
            "phases": {"hL": 0.0, "fL": -0.25, "hR": -0.5, "fR": -0.75},
            "bob": 0.015, "bob_freq": 2, "spine": 1, "yaw": 2, "head": 5, "tail": 4}
    run = {"period": 0.48, "duty": 0.32, "amp_f": 40, "amp_h": 36, "lift": 85,
           "phases": {"hL": 0.0, "hR": -0.1, "fL": -0.42, "fR": -0.52},
           "bob": 0.07, "bob_freq": 1, "spine": 5, "yaw": 1, "head": 6, "tail": 12}
    return std_clips(rig, HORSE, walk, run)


def horse_kick(rig):
    n = int(0.9 * fl.FPS)
    for f in range(n + 1):
        t = f / n
        k = math.sin(min(t / 0.5, 1.0) * math.pi)
        r = fl.zero_pose(rig)
        r["spine"] = (-10 * k, 0, 0)
        r["neck"] = (-15 * k, 0, 0)
        for s in ("L", "R"):
            r[f"thigh.{s}"] = (-45 * k, 0, 0)
            r[f"shin.{s}"] = (25 * k, 0, 0)
            r[f"upperarm.{s}"] = (10 * k, 0, 0)
        r["tail"] = (40 * k, 0, 0)
        fl.key(rig, f + 1, r, (0, 0.05 * k, 0.04 * k))
    return n


HORSE = {
    "name": "Horse", "J": HORSE_J, "sculpt": horse_sculpt, "voxel": 0.010, "tris": 16000,
    "coat": horse_coat, "hair": horse_hair, "card_density": 1500,
    "hair_palette": [(0.62, 0.50, 0.34), (0.14, 0.11, 0.09), (0.80, 0.72, 0.58), (0.50, 0.40, 0.27)],
    "fur_scale": 260.0, "fur_stretch": 8.0, "bump": 0.4,
    "eyes": [(HORSE_EYE, 0.019)], "eye_color": (0.08, 0.05, 0.03),
    "attack": horse_kick, "clips": horse_clips,
    "graze_pose": {"neck": -50, "neck2": -20, "head": -12, "arm": 8, "drop": 0.03},
}


# ===================================================================== CAVE LION (Panthera spelaea)

LION_J = mirror_joints({
    "nose": (0, 1.30, 1.03), "head": (0, 1.03, 1.12), "neck2": (0, 0.92, 1.10), "neck": (0, 0.75, 1.10),
    "chest": (0, 0.50, 1.08), "spine": (0, 0.0, 1.02), "hips": (0, -0.50, 1.05),
    "tail": (0, -0.66, 1.02), "tail2": (0, -0.92, 0.66), "tail3": (0, -1.12, 0.40),
    "ear.L": (0.10, 0.98, 1.22), "ear_t.L": (0.12, 0.96, 1.31),
    "sh.L": (0.15, 0.52, 0.88), "el.L": (0.14, 0.38, 0.58), "ca.L": (0.13, 0.44, 0.16), "fh.L": (0.13, 0.52, 0.04),
    "hp.L": (0.14, -0.52, 0.92), "st.L": (0.16, -0.32, 0.62), "ho.L": (0.13, -0.62, 0.30), "hh.L": (0.13, -0.52, 0.04),
})
LION_EYE = (0.075, 1.17, 1.14)


def lion_sculpt(J):
    sc = Sculpt()
    sc.ell((0, 0.20, 0.82), (0.25, 0.42, 0.31), k=0.1)            # deep chest
    sc.ell((0, 0.48, 0.80), (0.17, 0.14, 0.20), (20, 0, 0), k=0.08)
    sc.ell((0, -0.20, 0.84), (0.21, 0.36, 0.24), k=0.1)           # waist
    sc.ell((0, -0.30, 0.71), (0.12, 0.22, 0.08), k=0.08)          # primordial pouch
    sc.ell((0, -0.05, 1.00), (0.14, 0.50, 0.07), k=0.08)          # supple back
    sc.ell((0, -0.50, 0.96), (0.15, 0.18, 0.14), k=0.08)          # pelvis
    for s in (1, -1):
        sc.ell((0.12 * s, -0.45, 0.82), (0.10, 0.18, 0.22), (-12, 0, 0), k=0.07)
        sc.ell((0.14 * s, 0.45, 0.92), (0.08, 0.14, 0.22), (25, 0, 0), k=0.07)
        sc.ell((0.11 * s, -0.32, 0.74), (0.08, 0.12, 0.09), k=0.07)
    sc.cone((0, 0.45, 0.95), (0, 0.92, 1.08), 0.22, 0.135, k=0.08)  # powerful neck
    sc.ell((0, 1.00, 1.13), (0.14, 0.16, 0.12), k=0.05)           # low, broad cranium
    sc.ell((0, 1.08, 1.08), (0.19, 0.10, 0.10), k=0.04)           # wide zygomatic arches
    sc.ell((0, 1.17, 1.13), (0.06, 0.13, 0.04), (15, 0, 0), k=0.04)  # nose bridge
    sc.cone((0, 1.10, 1.07), (0, 1.30, 1.02), 0.10, 0.075, k=0.04)  # broad muzzle
    sc.ell((0.05, 1.26, 0.99), (0.06, 0.06, 0.05), k=0.03)        # whisker pads
    sc.ell((-0.05, 1.26, 0.99), (0.06, 0.06, 0.05), k=0.03)
    sc.cone((0, 1.00, 0.98), (0, 1.25, 0.95), 0.08, 0.05, k=0.04)  # jaw
    sc.ell((0, 1.25, 0.94), (0.05, 0.04, 0.04), k=0.03)           # chin
    sc.ell((0, 1.315, 1.045), (0.045, 0.025, 0.03), k=0.02)       # nose leather
    for s in (1, -1):
        sc.sphere((0.083 * s, LION_EYE[1], LION_EYE[2]), 0.022, k=0.012, sub=True)
        sc.leaf((0.10 * s, 0.98, 1.21), (0.12 * s, 0.96, 1.31), 0.06, 0.015, (0, 1, 0), k=0.02)
        L = lambda k: X(J[k + ".L"], s)
        sc.cone(L("sh"), L("el"), 0.12, 0.085, k=0.06)
        sc.ell(np.add(L("el"), (0, 0.01, -0.1)), (0.065, 0.07, 0.13), k=0.04)
        sc.cone(L("el"), L("ca"), 0.08, 0.058, k=0.04)
        sc.cone(L("ca"), np.add(L("fh"), (0, -0.03, 0.02)), 0.052, 0.05, k=0.03)
        sc.ell(np.add(L("fh"), (0, 0.0, 0.0)), (0.068, 0.08, 0.045), k=0.03)
        sc.cone(L("hp"), L("st"), 0.15, 0.09, k=0.06)
        sc.ell(np.add(L("st"), (0, -0.08, -0.08)), (0.05, 0.07, 0.11), (25, 0, 0), k=0.04)
        sc.cone(L("st"), L("ho"), 0.07, 0.04, k=0.04)
        sc.cone(L("ho"), np.add(L("hh"), (0, -0.03, 0.02)), 0.04, 0.04, k=0.03)
        sc.ell(np.add(L("hh"), (0, 0.0, 0.0)), (0.055, 0.065, 0.038), k=0.03)
    sc.cone(J["tail"], J["tail2"], 0.045, 0.03, k=0.03)
    sc.cone(J["tail2"], J["tail3"], 0.03, 0.022, k=0.02)
    return sc


def lion_coat(p, n, bone):
    x, y, z = p
    pb = part(bone)
    tawny, back, cream, white = (0.66, 0.50, 0.32), (0.56, 0.42, 0.27), (0.82, 0.74, 0.60), (0.90, 0.87, 0.80)
    fur, rough = 1.0, 0.85
    c = mix(tawny, back, (n[2] - 0.4) * 1.8)
    c = mix(c, cream, (-n[2] - 0.3) * 2.0)
    if pb in LEG:
        c = mix(tawny, cream, (-n[0] * np.sign(x) - 0.2) * 1.2)
        if z < 0.03:
            c, fur, rough = (0.15, 0.12, 0.10), 0.0, 0.7
    if pb in ("head", "snout"):
        c = tawny
        if y > 1.22 and z < 1.03:
            c = white                                                       # white muzzle & chin
        if abs(abs(x) - 0.07) < 0.03 and 1.12 < y < 1.2 and 1.1 < z < 1.125:
            c = mix(c, white, 0.6)                                          # pale patch under the eye
        if y > 1.30 and z > 1.025 and n[2] > -0.2:
            c, fur, rough = (0.42, 0.29, 0.26), 0.0, 0.35                  # nose leather
        if z < 0.99 and y > 1.15:
            c = mix(c, (0.15, 0.12, 0.10), 0.5)                             # lip line
        if abs(abs(x) - LION_EYE[0]) < 0.025 and abs(y - LION_EYE[1]) < 0.025 and abs(z - LION_EYE[2]) < 0.02:
            c = mix(c, (0.12, 0.09, 0.07), 0.7)
    if pb == "ear":
        c = ((0.22, 0.17, 0.13) if n[1] < 0.2 else cream) if z > 1.24 else tawny
    if pb == "tail_tip" and y < -1.0:
        c = (0.09, 0.075, 0.06)
    return c, fur, rough


def lion_hair(p, n, bone):
    x, y, z = p
    pb = part(bone)
    if pb in ("neck", "neck2") or (pb == "head" and y < 1.06 and n[2] < 0.6):
        return 0.075, 0.25, 0.4, 0.03, (0, -1, -0.3)                       # winter ruff
    if pb == "head" and abs(n[0]) > 0.6 and y < 1.12:
        return 0.05, 0.2, 0.2, 0.025, (0, -1, -0.2)                        # cheek fur
    if pb in TORSO:
        if n[2] < -0.5:
            return 0.07, 0.1, 0.9, 0.03, (0, -0.4, -1)                     # belly fringe
        return 0.035, 0.08, 0.5, 0.022, (0, -1, -0.4)                      # dense coat
    if pb in ("upperarm", "thigh") and z > 0.45:
        return 0.03, 0.08, 0.6, 0.02, (0, -0.3, -1)
    if pb == "tail_tip" and y < -1.02:
        return 0.13, 0.2, 0.6, 0.04, (0, -0.6, -1)                         # black tuft
    return 0.0, 0, 0, 0, (0, 0, -1)


def lion_pounce(rig):
    n = int(0.85 * fl.FPS)
    for f in range(n + 1):
        t = f / n
        k = math.sin(min(t / 0.45, 1.0) * math.pi) if t < 0.45 else max(0.0, 1 - (t - 0.45) / 0.55) * 0.25
        r = fl.zero_pose(rig)
        r["spine"] = (10 * k, 0, 0)
        r["chest"] = (8 * k, 0, 0)
        r["neck"] = (-12 * k, 0, 0)
        r["head"] = (18 * k, 0, 0)
        r["snout"] = (-15 * k, 0, 0)
        r["ear.L"] = (-35 * k, 0, 0)
        r["ear.R"] = (-35 * k, 0, 0)
        for s in ("L", "R"):
            r[f"upperarm.{s}"] = (55 * k, 0, 0)
            r[f"forearm.{s}"] = (-35 * k, 0, 0)
            r[f"thigh.{s}"] = (-25 * k, 0, 0)
        r["tail"] = (20 * k, 0, 0)
        fl.key(rig, f + 1, r, (0, 0.6 * k, 0.15 * k))
    return n


def lion_clips(rig):
    walk = {"period": 1.1, "duty": 0.62, "amp_f": 18, "amp_h": 16, "lift": 50,
            "phases": {"hL": 0.0, "fL": -0.25, "hR": -0.5, "fR": -0.75},
            "bob": 0.012, "bob_freq": 2, "spine": 1.5, "yaw": 4, "head": 2, "tail": 6}
    run = {"period": 0.5, "duty": 0.35, "amp_f": 38, "amp_h": 34, "lift": 80,
           "phases": {"hL": 0.0, "hR": -0.08, "fR": -0.42, "fL": -0.52},
           "bob": 0.05, "bob_freq": 1, "spine": 12, "yaw": 1, "head": 2, "tail": 10}
    return std_clips(rig, LION, walk, run)


LION = {
    "name": "Lion", "J": LION_J, "sculpt": lion_sculpt, "voxel": 0.010, "tris": 16000,
    "coat": lion_coat, "hair": lion_hair, "card_density": 1800,
    "hair_palette": [(0.66, 0.50, 0.32), (0.62, 0.47, 0.30), (0.82, 0.74, 0.60), (0.12, 0.10, 0.08)],
    "fur_scale": 240.0, "fur_stretch": 8.0, "bump": 0.45,
    "eyes": [(LION_EYE, 0.018)], "eye_color": (0.55, 0.42, 0.14),
    "attack": lion_pounce, "clips": lion_clips,
    "graze_pose": {"neck": -30, "neck2": -15, "head": -8, "arm": 4, "drop": 0.02},
}


# ===================================================================== WILD BOAR (Sus scrofa)

BOAR_J = mirror_joints({
    "nose": (0, 0.98, 0.48), "head": (0, 0.62, 0.72), "neck2": (0, 0.52, 0.75), "neck": (0, 0.42, 0.78),
    "chest": (0, 0.28, 0.80), "spine": (0, -0.05, 0.74), "hips": (0, -0.40, 0.70),
    "tail": (0, -0.52, 0.68), "tail2": (0, -0.56, 0.52), "tail3": (0, -0.57, 0.42),
    "ear.L": (0.07, 0.58, 0.86), "ear_t.L": (0.11, 0.55, 0.96),
    "sh.L": (0.12, 0.32, 0.55), "el.L": (0.11, 0.24, 0.36), "ca.L": (0.10, 0.28, 0.12), "fh.L": (0.10, 0.31, 0.02),
    "hp.L": (0.11, -0.42, 0.58), "st.L": (0.12, -0.28, 0.38), "ho.L": (0.10, -0.46, 0.18), "hh.L": (0.10, -0.42, 0.02),
})
BOAR_EYE = (0.095, 0.72, 0.69)


def boar_sculpt(J):
    sc = Sculpt()
    sc.ell((0, 0.12, 0.60), (0.20, 0.36, 0.24), k=0.08)
    sc.ell((0, 0.30, 0.74), (0.17, 0.20, 0.16), k=0.08)           # high withers
    sc.ell((0, -0.15, 0.58), (0.19, 0.30, 0.21), k=0.08)
    sc.ell((0, -0.40, 0.62), (0.15, 0.15, 0.14), k=0.07)          # sloping rump
    for s in (1, -1):
        sc.ell((0.10 * s, -0.38, 0.52), (0.08, 0.14, 0.17), (-10, 0, 0), k=0.06)
        sc.ell((0.13 * s, 0.30, 0.55), (0.09, 0.14, 0.20), (15, 0, 0), k=0.06)
    sc.cone((0, 0.30, 0.66), (0, 0.55, 0.70), 0.22, 0.17, k=0.08)  # no-neck
    sc.cone((0, 0.55, 0.70), (0, 0.95, 0.50), 0.16, 0.06, k=0.05)  # wedge head
    sc.ell((0, 0.62, 0.66), (0.14, 0.12, 0.12), k=0.05)           # cheeks
    sc.cone((0, 0.58, 0.58), (0, 0.90, 0.45), 0.08, 0.04, k=0.04)  # jaw
    sc.ell((0, 0.98, 0.48), (0.065, 0.03, 0.055), k=0.025)        # snout disc
    for s in (1, -1):
        sc.sphere((0.10 * s, BOAR_EYE[1], BOAR_EYE[2]), 0.016, k=0.01, sub=True)
        sc.leaf((0.07 * s, 0.58, 0.85), (0.11 * s, 0.55, 0.96), 0.05, 0.012, (s * 0.4, 1, 0.2), k=0.02)
        L = lambda k: X(J[k + ".L"], s)
        sc.cone(L("sh"), L("el"), 0.08, 0.05, k=0.05)
        sc.cone(L("el"), L("ca"), 0.045, 0.03, k=0.03)
        sc.cone(L("ca"), np.add(L("fh"), (0, -0.01, 0.03)), 0.028, 0.026, k=0.015)
        sc.ell(np.add(L("fh"), (0, 0.01, 0.015)), (0.03, 0.04, 0.025), (-15, 0, 0), k=0.012)
        sc.cone(L("hp"), L("st"), 0.09, 0.05, k=0.05)
        sc.cone(L("st"), L("ho"), 0.045, 0.028, k=0.03)
        sc.cone(L("ho"), np.add(L("hh"), (0, -0.01, 0.03)), 0.026, 0.025, k=0.015)
        sc.ell(np.add(L("hh"), (0, 0.01, 0.015)), (0.029, 0.038, 0.024), (-15, 0, 0), k=0.012)
    sc.cone(J["tail"], J["tail2"], 0.025, 0.015, k=0.02)
    sc.cone(J["tail2"], J["tail3"], 0.015, 0.012, k=0.01)
    return sc


def boar_coat(p, n, bone):
    x, y, z = p
    pb = part(bone)
    base, tip, black, disc = (0.22, 0.19, 0.16), (0.38, 0.33, 0.27), (0.10, 0.09, 0.08), (0.36, 0.29, 0.27)
    fur, rough = 1.0, 0.9
    c = mix(base, tip, (n[2] - 0.2) * 0.8)
    if abs(x) < 0.05 and n[2] > 0.6:
        c = mix(base, black, 0.6)                                           # dark dorsal crest
    if pb in LEG:
        c = mix(base, black, (0.45 - z) * 3)
        if z < 0.04:
            c, fur, rough = (0.07, 0.06, 0.055), 0.0, 0.5
    if pb in ("head", "snout"):
        c = mix(base, tip, 0.3)
        if y > 0.80 and abs(x) > 0.05 and z < 0.6:
            c = mix(c, (0.55, 0.50, 0.44), 0.4)                             # pale cheek band
        if y > 0.955:
            c, fur, rough = disc, 0.0, 0.4
        if abs(abs(x) - BOAR_EYE[0]) < 0.02 and abs(y - BOAR_EYE[1]) < 0.02 and abs(z - BOAR_EYE[2]) < 0.02:
            c = black
    if pb == "ear":
        c = black if z > 0.88 else base
    return c, fur, rough


def boar_hair(p, n, bone):
    x, y, z = p
    pb = part(bone)
    if abs(x) < 0.05 and n[2] > 0.6 and -0.35 < y < 0.62:
        return 0.085, 0.8, 0.2, 0.022, (0, -0.4, 1)                         # erect dorsal crest
    if pb == "ear" and z < 0.88:
        return 0.04, 0.2, 0.3, 0.018, (0, -1, -0.3)
    if pb in ("head", "snout"):
        return (0.04 if y < 0.85 else 0.0), 0.2, 0.3, 0.018, (0, -1, -0.3)
    if pb in TORSO or pb in ("neck", "neck2"):
        return 0.055, 0.2, 0.6, 0.02, (0, -0.7, -1)                         # bristles
    if pb in ("upperarm", "thigh"):
        return 0.04, 0.1, 0.7, 0.018, (0, -0.3, -1)
    if pb == "tail_tip":
        return 0.07, 0.1, 0.9, 0.02, (0, 0, -1)
    return 0.0, 0, 0, 0, (0, 0, -1)


def boar_parts():
    ivory = fl.simple_mat("M_Boar_Tusk", (0.78, 0.72, 0.60), 0.35)
    return [(fl.tube("Tusk", [(0.05 * s, 0.86, 0.465), (0.08 * s, 0.885, 0.53), (0.07 * s, 0.86, 0.58)], 0.012, 0.003,
                     ring=7, n=8, mat=ivory), "head") for s in (1, -1)]


def boar_clips(rig):
    walk = {"period": 0.8, "duty": 0.62, "amp_f": 18, "amp_h": 16, "lift": 45,
            "phases": {"hL": 0.0, "fL": -0.25, "hR": -0.5, "fR": -0.75},
            "bob": 0.01, "bob_freq": 2, "spine": 1, "yaw": 3, "head": 3, "tail": 8}
    run = {"period": 0.42, "duty": 0.45, "amp_f": 30, "amp_h": 28, "lift": 55,
           "phases": {"hL": 0.0, "hR": -0.12, "fR": -0.45, "fL": -0.55},
           "bob": 0.035, "bob_freq": 1, "spine": 5, "yaw": 1, "head": 3, "tail": 15}
    return std_clips(rig, BOAR, walk, run)


BOAR = {
    "name": "Boar", "J": BOAR_J, "sculpt": boar_sculpt, "voxel": 0.007, "tris": 14000,
    "coat": boar_coat, "hair": boar_hair, "card_density": 2600,
    "hair_palette": [(0.22, 0.19, 0.16), (0.38, 0.33, 0.27), (0.10, 0.09, 0.08), (0.30, 0.26, 0.21)],
    "fur_scale": 280.0, "fur_stretch": 7.0, "bump": 0.6,
    "eyes": [(BOAR_EYE, 0.014)], "eye_color": (0.10, 0.06, 0.03),
    "parts": boar_parts, "attack": lambda rig: horn_attack(rig, 0.4, 0.8), "clips": boar_clips,
    "graze_pose": {"neck": -25, "neck2": -12, "head": -20, "arm": 4, "drop": 0.02},
}
