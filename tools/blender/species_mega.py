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
