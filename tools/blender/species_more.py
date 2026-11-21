# Red deer hind, roe deer doe, cave bear, woolly mammoth — imported by gen_animals.py.
import math
import numpy as np
import fauna_lib as fl
from fauna_lib import Sculpt, mirror_joints, std_clips, bite_attack


def mix(a, b, t):
    t = min(max(t, 0.0), 1.0)
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def part(bone):
    return bone.split(".")[0]


def X(v, s):
    return (v[0] * s, v[1], v[2])


LEG = ("upperarm", "forearm", "hoof_f", "thigh", "shin", "hoof_h")
TORSO = ("spine", "chest", "hips")


def scaleJ(J, f):
    return {k: (v[0] * f, v[1] * f, v[2] * f) for k, v in J.items()}


# ===================================================================== RED DEER (Cervus elaphus) hind

DEER_J = mirror_joints({
    "nose": (0, 1.10, 1.38), "head": (0, 0.86, 1.53), "neck2": (0, 0.78, 1.51), "neck": (0, 0.60, 1.30),
    "chest": (0, 0.42, 1.12), "spine": (0, 0.0, 1.06), "hips": (0, -0.42, 1.08),
    "tail": (0, -0.56, 1.06), "tail2": (0, -0.63, 0.97), "tail3": (0, -0.66, 0.90),
    "ear.L": (0.06, 0.82, 1.60), "ear_t.L": (0.165, 0.785, 1.69),
    "sh.L": (0.12, 0.42, 0.93), "el.L": (0.11, 0.32, 0.71), "ca.L": (0.085, 0.36, 0.34), "fh.L": (0.08, 0.40, 0.03),
    "hp.L": (0.11, -0.46, 0.97), "st.L": (0.12, -0.27, 0.74), "ho.L": (0.09, -0.56, 0.43), "hh.L": (0.08, -0.50, 0.03),
})


def deer_sculpt(J):
    sc = Sculpt()
    sc.ell((0, 0.17, 0.93), (0.17, 0.36, 0.25), k=0.08)            # ribcage
    sc.ell((0, 0.40, 0.87), (0.13, 0.12, 0.17), (20, 0, 0), k=0.07)  # brisket
    sc.ell((0, -0.13, 0.945), (0.155, 0.28, 0.19), k=0.08)         # belly
    sc.ell((0, -0.05, 1.075), (0.11, 0.46, 0.075), k=0.07)         # topline
    sc.ell((0, -0.42, 1.02), (0.13, 0.15, 0.13), k=0.07)           # pelvis / rump
    for s in (1, -1):
        sc.ell((0.095 * s, -0.40, 0.89), (0.07, 0.145, 0.19), (-15, 0, 0), k=0.06)  # haunch
        sc.ell((0.12 * s, 0.38, 1.0), (0.05, 0.10, 0.18), (25, 0, 0), k=0.06)      # scapula
        sc.ell((0.10 * s, -0.30, 0.80), (0.07, 0.12, 0.08), (-10, 0, 0), k=0.06)   # flank fold
    sc.cone((0, 0.36, 0.99), (0, 0.77, 1.46), 0.165, 0.072, k=0.08)  # neck
    sc.ell((0, 0.55, 1.14), (0.065, 0.09, 0.11), (-40, 0, 0), k=0.05)  # throat
    sc.ell((0, 0.82, 1.55), (0.068, 0.09, 0.068), k=0.035)         # cranium
    sc.ell((0, 0.90, 1.515), (0.06, 0.075, 0.055), k=0.03)         # cheeks
    sc.cone((0, 0.88, 1.53), (0, 1.09, 1.385), 0.058, 0.03, k=0.035)  # long face
    sc.cone((0, 0.80, 1.47), (0, 1.06, 1.35), 0.045, 0.022, k=0.03)   # jaw
    sc.ell((0, 1.098, 1.378), (0.033, 0.025, 0.026), k=0.015)     # muzzle tip
    for s in (1, -1):
        sc.sphere((0.06 * s, 0.895, 1.555), 0.017, k=0.01, sub=True)
        sc.leaf((0.06 * s, 0.82, 1.60), (0.16 * s, 0.785, 1.685), 0.05, 0.012, (0.6 * s, 1, 0.4), k=0.02)  # ears
        L = lambda k: X(J[k + ".L"], s)
        sc.cone(L("sh"), L("el"), 0.075, 0.05, k=0.05)
        sc.ell(np.add(L("el"), (0, 0.01, -0.08)), (0.04, 0.045, 0.09), k=0.04)
        sc.cone(L("el"), L("ca"), 0.042, 0.024, k=0.03)
        sc.cone(L("ca"), np.add(L("fh"), (0, -0.01, 0.045)), 0.024, 0.02, k=0.015)
        sc.ell(np.add(L("fh"), (0, 0.012, 0.022)), (0.024, 0.038, 0.026), (-15, 0, 0), k=0.012)  # hoof
        sc.cone(L("hp"), L("st"), 0.10, 0.055, k=0.05)
        sc.ell(np.add(L("st"), (0, -0.07, -0.07)), (0.04, 0.06, 0.09), (25, 0, 0), k=0.04)
        sc.cone(L("st"), L("ho"), 0.05, 0.024, k=0.03)
        sc.cone(L("ho"), np.add(L("hh"), (0, -0.01, 0.045)), 0.022, 0.02, k=0.015)
        sc.ell(np.add(L("hh"), (0, 0.012, 0.022)), (0.024, 0.038, 0.026), (-15, 0, 0), k=0.012)
    sc.cone(J["tail"], J["tail3"], 0.04, 0.025, k=0.03)
    return sc


def make_cervid_coat(f, pal):
    side, back, belly, rump, legs, face, muzzle, neck = pal

    def coat(p, n, bone):
        x, y, z = p[0] / f, p[1] / f, p[2] / f
        pb = part(bone)
        fur, rough = 1.0, 0.85
        c = side
        if pb in TORSO:
            c = mix(side, back, (n[2] - 0.3) * 2)
            c = mix(c, belly, (-n[2] - 0.35) * 2.2)
            if y < -0.42 and n[1] < -0.25 and z > 0.78:
                c = mix(c, rump, min(1, (-n[1] - 0.25) * 2.5))   # pale rump patch
        elif pb in ("neck", "neck2"):
            c = mix(neck, belly, (-n[2] - 0.5) * 1.5)
        elif pb in LEG:
            c = mix(legs, belly, (-n[0] * np.sign(x) - 0.3) * 1.2)
            if pb in ("upperarm", "thigh"):
                c = mix(side, c, 0.6)
            if z < 0.06:
                c, fur, rough = (0.07, 0.06, 0.055), 0.0, 0.45     # hooves
        elif pb in ("head", "snout"):
            c = face
            if y > 1.02:
                c = mix(face, muzzle, 0.8)
            if y > 1.09 and n[2] > -0.2:
                c, fur, rough = (0.06, 0.05, 0.05), 0.0, 0.3       # rhinarium
            if z < 1.37 and y > 1.04:
                c = mix(c, belly, 0.6)                            # pale chin
            if abs(abs(x) - 0.06) < 0.02 and abs(y - 0.895) < 0.022 and abs(z - 1.555) < 0.02:
                c = mix(c, (0.08, 0.07, 0.06), 0.7)
        elif pb == "ear":
            c = mix(face, (0.25, 0.2, 0.16), 0.3) if n[1] < 0.3 else mix(belly, face, 0.4)
        elif pb in ("tail", "tail_tip"):
            c = rump if n[1] < 0 else back
        return c, fur, rough
    return coat


def make_cervid_hair(f, mane=0.07):
    def hair(p, n, bone):
        x, y, z = p[0] / f, p[1] / f, p[2] / f
        pb = part(bone)
        if pb in ("neck", "neck2"):
            if n[2] < -0.2:
                return mane * f, 0.2, 0.8, 0.026 * f, (0, -0.3, -1)    # throat mane
            return 0.03 * f, 0.1, 0.3, 0.02 * f, (0, -1, -0.3)
        if pb in TORSO and n[2] > 0.0:
            return 0.022 * f, 0.08, 0.4, 0.018 * f, (0, -1, -0.5)
        if pb in TORSO:
            return 0.02 * f, 0.08, 0.6, 0.018 * f, (0, -0.5, -1)
        if pb in ("tail", "tail_tip"):
            return 0.05 * f, 0.2, 0.5, 0.02 * f, (0, -0.3, -1)
        return 0.0, 0, 0, 0, (0, 0, -1)
    return hair


def cervid_clips(sp):
    f = sp["scale"]
    walk = {"period": 1.15 * f ** 0.5, "duty": 0.65, "amp_f": 19, "amp_h": 17, "lift": 55,
            "phases": {"hL": 0.0, "fL": -0.25, "hR": -0.5, "fR": -0.75},
            "bob": 0.012 * f, "bob_freq": 2, "spine": 1.2, "yaw": 2, "head": 4, "tail": 3}
    run = {"period": 0.52 * f ** 0.5, "duty": 0.32, "amp_f": 38, "amp_h": 36, "lift": 85,
           "phases": {"hL": 0.0, "hR": -0.1, "fL": -0.42, "fR": -0.52},
           "bob": 0.07 * f, "bob_freq": 1, "spine": 7, "yaw": 1, "head": 3, "tail": 8}
    return lambda rig: std_clips(rig, sp, walk, run)


def cervid_attack(sp):
    return lambda rig: bite_attack(rig, sp, 0.15 * sp["scale"])


DEER = {
    "name": "Deer", "J": DEER_J, "scale": 1.0, "sculpt": deer_sculpt, "voxel": 0.009, "tris": 15000,
    "coat": make_cervid_coat(1.0, [(0.46, 0.35, 0.25), (0.38, 0.29, 0.21), (0.70, 0.63, 0.52), (0.80, 0.72, 0.56),
                                   (0.36, 0.28, 0.21), (0.44, 0.35, 0.26), (0.25, 0.20, 0.16), (0.34, 0.26, 0.19)]),
    "hair": make_cervid_hair(1.0, 0.08), "card_density": 2600,
    "hair_palette": [(0.46, 0.35, 0.25), (0.34, 0.26, 0.19), (0.70, 0.63, 0.52), (0.40, 0.31, 0.23)],
    "fur_scale": 300.0, "fur_stretch": 7.0, "bump": 0.45,
    "eyes": [((0.055, 0.897, 1.555), 0.0165)], "eye_color": (0.12, 0.07, 0.04),
    "graze_pose": {"neck": -55, "neck2": -25, "head": -10, "arm": 8, "drop": 0.03},
}
DEER["clips"] = cervid_clips(DEER)
DEER["attack"] = cervid_attack(DEER)

# ===================================================================== ROE DEER (Capreolus capreolus) doe

ROE_F = 0.62
ROE = dict(DEER)
ROE.update({
    "name": "Roe", "J": scaleJ(DEER_J, ROE_F), "scale": ROE_F, "sculpt": lambda J: deer_sculpt(DEER_J).scaled(ROE_F),
    "voxel": 0.0065, "tris": 12000,
    "coat": make_cervid_coat(ROE_F, [(0.55, 0.34, 0.20), (0.46, 0.28, 0.17), (0.78, 0.70, 0.58), (0.93, 0.90, 0.84),
                                     (0.44, 0.29, 0.18), (0.50, 0.34, 0.22), (0.12, 0.10, 0.09), (0.50, 0.32, 0.20)]),
    "hair": make_cervid_hair(ROE_F, 0.04), "card_density": 4200,
    "hair_palette": [(0.55, 0.34, 0.20), (0.44, 0.27, 0.16), (0.86, 0.82, 0.74), (0.50, 0.32, 0.19)],
    "fur_scale": 380.0,
    "eyes": [((0.055 * ROE_F, 0.897 * ROE_F, 1.555 * ROE_F), 0.0165 * ROE_F)],
})
ROE["clips"] = cervid_clips(ROE)
ROE["attack"] = cervid_attack(ROE)


# ===================================================================== CAVE BEAR (Ursus spelaeus)

BEAR_J = mirror_joints({
    "nose": (0, 1.46, 1.06), "head": (0, 1.12, 1.19), "neck2": (0, 1.0, 1.17), "neck": (0, 0.82, 1.17),
    "chest": (0, 0.52, 1.20), "spine": (0, 0.0, 1.13), "hips": (0, -0.55, 1.10),
    "tail": (0, -0.78, 1.04), "tail2": (0, -0.86, 0.97), "tail3": (0, -0.88, 0.92),
    "ear.L": (0.13, 1.08, 1.35), "ear_t.L": (0.16, 1.05, 1.44),
    "sh.L": (0.21, 0.58, 0.92), "el.L": (0.20, 0.42, 0.55), "ca.L": (0.20, 0.50, 0.14), "fh.L": (0.20, 0.68, 0.05),
    "hp.L": (0.20, -0.60, 0.92), "st.L": (0.22, -0.38, 0.56), "ho.L": (0.19, -0.60, 0.11), "hh.L": (0.19, -0.33, 0.05),
})


def bear_sculpt(J):
    sc = Sculpt()
    sc.ell((0, 0.25, 0.92), (0.36, 0.55, 0.37), k=0.14)            # ribcage
    sc.ell((0, 0.55, 1.18), (0.27, 0.30, 0.20), k=0.14)            # shoulder hump
    sc.ell((0, -0.22, 0.90), (0.36, 0.48, 0.34), k=0.14)           # belly
    sc.ell((0, -0.55, 0.97), (0.30, 0.30, 0.28), k=0.12)           # rump
    for s in (1, -1):
        sc.ell((0.20 * s, -0.52, 0.80), (0.14, 0.26, 0.30), (-10, 0, 0), k=0.1)   # haunch
        sc.ell((0.22 * s, 0.55, 0.93), (0.13, 0.22, 0.30), (15, 0, 0), k=0.1)     # shoulder
    sc.cone((0, 0.60, 1.06), (0, 1.0, 1.14), 0.31, 0.21, k=0.1)    # neck
    sc.ell((0, 1.08, 1.20), (0.19, 0.20, 0.165), k=0.06)           # cranium
    sc.ell((0, 1.17, 1.28), (0.12, 0.12, 0.09), k=0.06)            # domed forehead (cave bear)
    sc.ell((0, 1.15, 1.12), (0.20, 0.14, 0.13), k=0.06)            # cheeks / jowls
    sc.cone((0, 1.22, 1.13), (0, 1.44, 1.065), 0.11, 0.066, k=0.05)  # muzzle
    sc.cone((0, 1.10, 1.02), (0, 1.40, 1.0), 0.10, 0.05, k=0.05)   # jaw
    sc.ell((0, 1.465, 1.07), (0.055, 0.03, 0.045), k=0.03)         # nose
    for s in (1, -1):
        sc.sphere((0.092 * s, 1.255, 1.215), 0.022, k=0.015, sub=True)
        sc.ell((0.14 * s, 1.07, 1.37), (0.055, 0.025, 0.05), (0, -25 * s, 0), k=0.04)  # round ears
        L = lambda k: X(J[k + ".L"], s)
        sc.cone(L("sh"), L("el"), 0.17, 0.12, k=0.08)
        sc.cone(L("el"), L("ca"), 0.12, 0.085, k=0.06)
        sc.ell(np.add(L("ca"), (0, 0.08, -0.06)), (0.10, 0.14, 0.06), k=0.05)    # front paw (plantigrade)
        sc.cone(L("hp"), L("st"), 0.20, 0.13, k=0.08)
        sc.cone(L("st"), L("ho"), 0.12, 0.08, k=0.06)
        sc.ell((0.19 * s, -0.46, 0.06), (0.09, 0.16, 0.06), k=0.05)           # hind foot
    sc.cone(J["tail"], J["tail2"], 0.06, 0.04, k=0.04)
    return sc


def bear_coat(p, n, bone):
    x, y, z = p
    pb = part(bone)
    base, tip, dark, muz = (0.30, 0.21, 0.14), (0.42, 0.31, 0.21), (0.20, 0.14, 0.10), (0.46, 0.36, 0.26)
    fur, rough = 1.0, 0.9
    c = mix(base, tip, (n[2] - 0.2) * 1.2)
    if pb in LEG:
        c = mix(base, dark, (0.6 - z) * 1.5)
        if z < 0.03:
            c, fur, rough = (0.08, 0.07, 0.065), 0.0, 0.7                # pads
    if pb in ("head", "snout"):
        c = mix(base, tip, 0.3)
        if y > 1.25:
            c = muz
        if y > 1.45:
            c, fur, rough = (0.05, 0.045, 0.045), 0.0, 0.3               # nose
        if abs(abs(x) - 0.092) < 0.03 and abs(y - 1.255) < 0.03 and abs(z - 1.215) < 0.03:
            c = mix(c, (0.08, 0.06, 0.05), 0.6)
    if pb in TORSO and n[2] < -0.4:
        c = mix(c, dark, 0.5)
    return c, fur, rough


def bear_hair(p, n, bone):
    x, y, z = p
    pb = part(bone)
    if pb in ("head", "snout"):
        if y < 1.2:
            return 0.05, 0.25, 0.2, 0.035, (0, -1, -0.3)
        return 0.0, 0, 0, 0, (0, 0, -1)
    if pb in ("neck", "neck2") or (pb == "chest" and n[2] > 0):
        return 0.13, 0.3, 0.6, 0.045, (0, -1, -0.4)
    if pb in TORSO:
        return (0.13 if n[2] < -0.2 else 0.10), 0.2, 0.7, 0.045, (0, -0.7, -1)
    if pb in ("upperarm", "thigh"):
        return 0.10, 0.15, 0.8, 0.04, (0, -0.4, -1)
    if pb in ("forearm", "shin"):
        return 0.08, 0.1, 0.8, 0.035, (0, -0.2, -1)
    if pb in ("tail", "tail_tip"):
        return 0.06, 0.3, 0.5, 0.03, (0, -0.5, -1)
    return 0.0, 0, 0, 0, (0, 0, -1)


def bear_parts():
    J = BEAR_J
    claw = fl.simple_mat("M_Bear_Claw", (0.55, 0.50, 0.42), 0.35)
    out = []
    for s in (1, -1):
        for side, foot, bone, ln in (("f", (0.20 * s, 0.70, 0.06), f"hoof_f.{'L' if s > 0 else 'R'}", 0.075),
                                     ("h", (0.19 * s, -0.32, 0.06), f"hoof_h.{'L' if s > 0 else 'R'}", 0.05)):
            for i in range(5):
                dx = (i - 2) * 0.035 * s
                fx, fy, fz = foot
                y0 = fy - abs(i - 2) * 0.02
                pts = [(fx + dx, y0 - 0.02, fz + 0.02), (fx + dx * 1.05, y0 + ln * 0.6, fz + 0.005), (fx + dx * 1.1, y0 + ln, fz - 0.035)]
                out.append((fl.tube("Claw", pts, 0.012, 0.002, ring=6, n=8, mat=claw), bone))
    return out


def bear_attack(rig):
    n = int(1.1 * fl.FPS)
    for f in range(n + 1):
        t = f / n
        up = math.sin(min(t / 0.5, 1.0) * math.pi * 0.5) if t < 0.5 else max(0.0, 1 - (t - 0.5) / 0.5)
        swipe = math.sin(max(0.0, min((t - 0.3) / 0.3, 1.0)) * math.pi)
        r = fl.zero_pose(rig)
        r["spine"] = (14 * up, 0, 0)
        r["chest"] = (10 * up, 0, 0)
        r["neck"] = (-8 * up, 0, 0)
        r["head"] = (12 * swipe, 0, 0)
        r["snout"] = (-14 * swipe, 0, 0)
        r["upperarm.L"] = (70 * up - 40 * swipe, 0, -15 * swipe)
        r["forearm.L"] = (-30 * up, 0, 0)
        r["upperarm.R"] = (35 * up, 0, 0)
        r["thigh.L"] = (-14 * up, 0, 0)
        r["thigh.R"] = (-14 * up, 0, 0)
        fl.key(rig, f + 1, r, (0, 0.2 * swipe, 0.12 * up))
    return n


def bear_clips(rig):
    walk = {"period": 1.3, "duty": 0.66, "amp_f": 18, "amp_h": 16, "lift": 45,
            "phases": {"hL": 0.0, "fL": -0.22, "hR": -0.5, "fR": -0.72},
            "bob": 0.02, "bob_freq": 2, "spine": 1.5, "yaw": 5, "head": 3, "tail": 2}
    run = {"period": 0.62, "duty": 0.42, "amp_f": 30, "amp_h": 28, "lift": 60,
           "phases": {"hL": 0.0, "hR": -0.12, "fR": -0.45, "fL": -0.55},
           "bob": 0.06, "bob_freq": 1, "spine": 7, "yaw": 2, "head": 3, "tail": 2}
    return std_clips(rig, BEAR, walk, run)


BEAR = {
    "name": "Bear", "J": BEAR_J, "sculpt": bear_sculpt, "voxel": 0.014, "tris": 16000,
    "coat": bear_coat, "hair": bear_hair, "card_density": 1100,
    "hair_palette": [(0.30, 0.21, 0.14), (0.42, 0.31, 0.21), (0.20, 0.14, 0.10), (0.36, 0.26, 0.17)],
    "fur_scale": 140.0, "fur_stretch": 6.0, "bump": 0.7, "strands_per_card": 170,
    "eyes": [((0.088, 1.255, 1.215), 0.017)], "eye_color": (0.18, 0.10, 0.05),
    "parts": bear_parts, "attack": bear_attack, "clips": bear_clips,
    "graze_pose": {"neck": -30, "neck2": -15, "head": -10, "arm": 4, "drop": 0.03},
}


# ===================================================================== WOOLLY MAMMOTH (Mammuthus primigenius)

MAM_J = mirror_joints({
    "head": (0, 1.85, 3.05), "nose": (0, 2.36, 2.0), "trunk2": (0, 2.40, 1.30), "trunk3": (0, 2.34, 0.72),
    "trunk4": (0, 2.26, 0.42),
    "neck2": (0, 1.55, 2.95), "neck": (0, 1.30, 2.85), "chest": (0, 0.95, 2.85), "spine": (0, 0.0, 2.6),
    "hips": (0, -0.85, 2.3), "tail": (0, -1.15, 2.18), "tail2": (0, -1.28, 1.80), "tail3": (0, -1.32, 1.45),
    "ear.L": (0.45, 1.55, 2.95), "ear_t.L": (0.55, 1.45, 2.70),
    "sh.L": (0.48, 1.00, 2.15), "el.L": (0.46, 0.86, 1.30), "ca.L": (0.44, 0.92, 0.40), "fh.L": (0.44, 0.98, 0.06),
    "hp.L": (0.45, -0.85, 1.95), "st.L": (0.48, -0.58, 1.15), "ho.L": (0.44, -0.78, 0.45), "hh.L": (0.44, -0.72, 0.06),
})
TUSK = [(0.24, 2.12, 2.48), (0.36, 2.42, 1.85), (0.62, 2.95, 1.38), (0.68, 3.50, 1.48), (0.42, 3.82, 1.95)]


def mam_sculpt(J):
    sc = Sculpt()
    sc.ell((0, 0.35, 2.05), (0.85, 1.10, 0.95), k=0.3)             # ribcage
    sc.ell((0, 0.95, 2.85), (0.45, 0.50, 0.42), k=0.3)             # shoulder hump
    sc.ell((0, -0.35, 1.95), (0.85, 0.95, 0.85), k=0.3)            # belly
    sc.ell((0, -0.85, 2.05), (0.65, 0.55, 0.55), k=0.25)           # rump (sloping back)
    for s in (1, -1):
        sc.ell((0.42 * s, -0.75, 1.75), (0.30, 0.45, 0.60), k=0.2)
        sc.ell((0.48 * s, 0.90, 2.10), (0.30, 0.45, 0.70), k=0.2)
    sc.ell((0, 1.35, 2.75), (0.58, 0.45, 0.58), k=0.25)            # neck
    sc.ell((0, 1.78, 3.0), (0.50, 0.55, 0.56), k=0.15)             # skull
    sc.ell((0, 1.62, 3.38), (0.32, 0.36, 0.30), k=0.15)            # high dome
    sc.cone((0, 1.95, 2.85), (0, 2.22, 2.45), 0.42, 0.24, k=0.12)  # face / tusk sheaths
    sc.ell((0, 1.90, 2.32), (0.24, 0.28, 0.20), k=0.1)             # lower jaw
    sc.cone((0, 2.18, 2.55), J["nose"], 0.22, 0.17, k=0.08)        # trunk
    sc.cone(J["nose"], J["trunk2"], 0.17, 0.13, k=0.05)
    sc.cone(J["trunk2"], J["trunk3"], 0.13, 0.095, k=0.04)
    sc.cone(J["trunk3"], J["trunk4"], 0.095, 0.07, k=0.03)
    sc.ell(J["trunk4"], (0.08, 0.08, 0.06), k=0.03)
    for s in (1, -1):
        sc.sphere((0.44 * s, 2.0, 2.85), 0.05, k=0.03, sub=True)
        sc.leaf((0.42 * s, 1.55, 2.92), (0.55 * s, 1.45, 2.66), 0.2, 0.04, (s, 0, 0), k=0.06)
        L = lambda k: X(J[k + ".L"], s)
        sc.cone(L("sh"), L("el"), 0.40, 0.30, k=0.12)
        sc.cone(L("el"), L("ca"), 0.28, 0.24, k=0.1)
        sc.cone(L("ca"), L("fh"), 0.24, 0.27, k=0.08)
        sc.ell(np.add(L("fh"), (0, 0.02, 0.04)), (0.28, 0.30, 0.10), k=0.06)
        sc.cone(L("hp"), L("st"), 0.45, 0.30, k=0.15)
        sc.cone(L("st"), L("ho"), 0.27, 0.22, k=0.1)
        sc.cone(L("ho"), L("hh"), 0.22, 0.26, k=0.08)
        sc.ell(np.add(L("hh"), (0, 0.02, 0.04)), (0.27, 0.29, 0.10), k=0.06)
    sc.cone(J["tail"], J["tail2"], 0.12, 0.07, k=0.06)
    sc.cone(J["tail2"], J["tail3"], 0.07, 0.045, k=0.04)
    return sc


def mam_coat(p, n, bone):
    x, y, z = p
    pb = part(bone)
    base, light, dark, skin = (0.30, 0.19, 0.11), (0.42, 0.28, 0.16), (0.18, 0.12, 0.08), (0.20, 0.18, 0.17)
    fur, rough = 1.0, 0.9
    c = mix(base, light, (n[2] - 0.3) * 1.2)
    if pb in LEG:
        c = mix(base, dark, (1.2 - z) * 0.8)
        if z < 0.07:
            c, fur, rough = skin, 0.2, 0.8                                 # feet
    if pb.startswith("snout") or (pb == "head" and y > 2.15):
        c = mix(dark, skin, 0.3)
        if z < 0.55:
            c, fur, rough = skin, 0.3, 0.7                                 # trunk tip skin
    if pb == "ear":
        c = dark
    return c, fur, rough


def mam_hair(p, n, bone):
    x, y, z = p
    pb = part(bone)
    if pb.startswith("snout") or (pb == "head" and y > 2.1):
        return (0.07 if z > 0.6 else 0.0), 0.1, 0.4, 0.05, (0, 0, -1)
    if pb in ("head", "neck2") and n[2] > 0.3:
        return 0.32, 0.4, 0.5, 0.12, (0, -1, 0.2)                          # topknot
    if pb == "head":
        return 0.22, 0.1, 0.9, 0.1, (0, -0.3, -1)
    if pb == "ear":
        return 0.18, 0.1, 0.9, 0.1, (0, -0.3, -1)
    if pb in TORSO or pb in ("neck",):
        if n[2] > 0.5:
            return 0.28, 0.2, 0.7, 0.12, (0, -1, -0.6)
        skirt = 0.4 + max(0.0, 2.3 - z) * 0.6                             # longer lower down
        return min(skirt, 1.05), 0.05, 1.0, 0.13, (0, -0.25, -1)
    if pb in ("upperarm", "thigh"):
        return 0.55, 0.05, 1.0, 0.12, (0, -0.2, -1)
    if pb in ("forearm", "shin"):
        return (0.42 if z > 0.3 else 0.26), 0.05, 1.0, 0.1, (0, -0.1, -1)
    if pb == "tail":
        return 0.12, 0.1, 0.8, 0.06, (0, -0.3, -1)
    if pb == "tail_tip":
        return 0.35, 0.1, 1.0, 0.08, (0, -0.2, -1)
    return 0.0, 0, 0, 0, (0, 0, -1)


def mam_parts():
    ivory = fl.simple_mat("M_Mammoth_Ivory", (0.80, 0.72, 0.58), 0.35)
    out = []
    for s in (1, -1):
        pts = [(x * s, y, z) for x, y, z in TUSK]
        out.append((fl.tube("Tusk", pts, 0.115, 0.028, ring=14, n=30, mat=ivory, power=0.8), "head"))
    return out


def mam_trunk(r, t, amp=1.0):
    w = t * math.tau
    r["snout"] = (3 * amp * math.sin(w), 0, 2 * amp * math.sin(w + 1))
    r["snout2"] = (5 * amp * math.sin(w + 0.6), 0, 6 * amp * math.sin(w + 1.4))
    r["snout3"] = (8 * amp * math.sin(w + 1.2), 0, 9 * amp * math.sin(w + 1.9))
    r["snout4"] = (14 * amp * math.sin(w + 1.8), 0, 10 * amp * math.sin(w + 2.4))


def mam_attack(rig):
    n = int(1.3 * fl.FPS)
    for f in range(n + 1):
        t = f / n
        lower = math.sin(min(t / 0.35, 1.0) * math.pi * 0.5) if t < 0.35 else 0
        toss = math.sin(max(0.0, min((t - 0.35) / 0.35, 1.0)) * math.pi)
        r = fl.zero_pose(rig)
        r["neck"] = (-12 * lower + 16 * toss, 0, 0)
        r["head"] = (-10 * lower + 22 * toss, 0, 6 * toss)
        r["snout"] = (25 * toss, 0, 0)
        r["snout2"] = (35 * toss, 0, 0)
        r["snout3"] = (40 * toss, 0, 0)
        r["snout4"] = (40 * toss, 0, 0)
        r["ear.L"] = (0, 0, 35 * (lower + toss))
        r["ear.R"] = (0, 0, -35 * (lower + toss))
        r["upperarm.L"] = (20 * toss, 0, 0)
        r["forearm.L"] = (-30 * toss, 0, 0)
        fl.key(rig, f + 1, r, (0, 0.45 * toss, 0.08 * toss))
    return n


def mam_clips(rig):
    walk = {"period": 1.9, "duty": 0.68, "amp_f": 14, "amp_h": 12, "lift": 35,
            "phases": {"hL": 0.0, "fL": -0.25, "hR": -0.5, "fR": -0.75},
            "bob": 0.04, "bob_freq": 2, "spine": 1, "yaw": 2, "head": 2.5, "tail": 6}
    run = {"period": 1.05, "duty": 0.5, "amp_f": 21, "amp_h": 19, "lift": 50,
           "phases": {"hL": 0.0, "fL": -0.25, "hR": -0.5, "fR": -0.75},
           "bob": 0.08, "bob_freq": 2, "spine": 2, "yaw": 2, "head": 4, "tail": 10}
    return std_clips(rig, MAMMOTH, walk, run)


MAMMOTH = {
    "name": "Mammoth", "J": MAM_J, "sculpt": mam_sculpt, "voxel": 0.028, "tris": 18000,
    "extra_bones": [("snout2", "nose", "trunk2", "snout"), ("snout3", "trunk2", "trunk3", "snout2"),
                    ("snout4", "trunk3", "trunk4", "snout3")],
    "coat": mam_coat, "hair": mam_hair, "card_density": 190,
    "hair_palette": [(0.30, 0.19, 0.11), (0.42, 0.28, 0.16), (0.18, 0.12, 0.08), (0.36, 0.23, 0.13)],
    "fur_scale": 70.0, "fur_stretch": 5.0, "bump": 0.8, "strands_per_card": 190,
    "eyes": [((0.42, 1.995, 2.85), 0.034)], "eye_color": (0.10, 0.06, 0.04),
    "parts": mam_parts, "attack": mam_attack, "clips": mam_clips,
    "graze_pose": {"neck": -10, "neck2": -6, "head": -12, "arm": 2, "drop": 0.04},
    "idle_extra": lambda r, t: mam_trunk(r, t, 1.0),
    "gait_extra": lambda r, t, g: mam_trunk(r, t, 0.8),
    "graze_extra": lambda r, t: r.update({"snout2": (25, 0, 5 * math.sin(t * math.tau)), "snout3": (35, 0, 0), "snout4": (50 + 10 * math.sin(t * math.tau * 2), 0, 0)}),
    "alert_tail": 30,
}
