"""Rigs an outside quadruped mesh (e.g. a straightened AI sculpt) with the rig-v2 skeleton of a species and bakes
that species' clips onto it. The species joint table is fitted to the mesh: overall length / height, each leg moved
onto its own paw (fading to nothing at the shoulder / hip), the head moved onto the nose, ears onto the ear tips.

  Blender -b --factory-startup -P tools/blender/rig_custom.py -- in.glb out.glb species [yaw_deg]

The mesh is expected head towards +X (glTF import) or set yaw_deg so it ends up head towards +Y in Blender.
"""
import bpy, sys, os, math
import numpy as np
from mathutils import Vector, Matrix

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fauna_lib as fl
import gen_animals as ga
import species_more as more

# per species: (walk, run, attack(rig, sp)) for the clips; the clips are rebuilt on the fitted joints
GAITS = {
    "wolf": (ga.WOLF_WALK, ga.WOLF_RUN, lambda rig, sp: fl.bite_attack(rig, sp, 0.28)),
    # a mammoth never folds its legs like a horse: pillar legs, small lift, little fold even at a run
    "mammoth": (dict(more.MAM_WALK, fold_f=28, fold_h=12, ik_lift=0.09, reach=0.42),
                dict(more.MAM_RUN, fold_f=38, fold_h=16, ik_lift=0.13, reach=0.55),
                lambda rig, sp: more.mam_attack(rig)),
}

argv = sys.argv[sys.argv.index("--") + 1:]
src, dst, species = argv[0], argv[1], argv[2]
yaw = float(argv[3]) if len(argv) > 3 else 90.0
base = ga.SPECIES[species]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.render.fps = fl.FPS
bpy.ops.import_scene.gltf(filepath=src)
body = [o for o in bpy.context.scene.objects if o.type == "MESH"][0]
body.data.transform(body.matrix_world)
body.matrix_world = Matrix.Identity(4)
body.parent = None
for o in list(bpy.context.scene.objects):
    if o != body:
        bpy.data.objects.remove(o)
body.data.transform(Matrix.Rotation(math.radians(yaw), 4, "Z"))
P = np.array([v.co[:] for v in body.data.vertices])

# --- scale / place the mesh: same height as the species (ear tips), feet on z = 0, spine on x = 0
J0 = fl.complete_joints(base["J"])
Jn = {k: np.array(v) for k, v in J0.items()}
# overall height the mesh is scaled to: the ear tips, or the top of the skull / hump for species without tall ears
SPECIES_TOP = {"mammoth": 3.35}
sp_h = SPECIES_TOP.get(species, max(Jn["ear_t.L"][2], Jn["head"][2]))
k = sp_h / (P[:, 2].max() - P[:, 2].min())
P = P * k
z_shift = P[:, 2].min()
P[:, 2] -= z_shift
H = P[:, 2].max()
L = P[:, 1].max() - P[:, 1].min()


def kmeans(X, n, seed=1, iters=40, tries=12):
    rng = np.random.default_rng(seed)
    best, best_c, best_l = 1e18, None, None
    for _ in range(tries):
        C = X[rng.choice(len(X), n, replace=False)]
        for _ in range(iters):
            lab = np.argmin(((X[:, None, :] - C[None]) ** 2).sum(-1), axis=1)
            C = np.array([X[lab == i].mean(0) if np.any(lab == i) else C[i] for i in range(n)])
        inertia = ((X - C[lab]) ** 2).sum()
        if inertia < best:
            best, best_c, best_l = inertia, C, lab
    return best_c, best_l


# paws: the four clusters of ground contact (the tail tip, if it reaches the ground, is the rearmost extra cluster)
low = P[P[:, 2] < 0.03 * H][:, :2]
C, lab = kmeans(low, 5)
sizes = np.array([np.sum(lab == i) for i in range(5)])
order = np.argsort(C[:, 1])                      # back to front
if sizes[order[0]] < 0.5 * np.median(sizes) or C[order[0], 1] < P[:, 1].min() + 0.06 * L:
    paws = C[order[1:]]                          # drop the tail tip
else:
    C, lab = kmeans(low, 4)
    paws = C[np.argsort(C[:, 1])]
hind, front = paws[:2], paws[2:]
spine_x = paws[:, 0].mean()
P[:, 0] -= spine_x
paws[:, 0] -= spine_x
hind, front = paws[:2], paws[2:]
feet = {"hh.L": hind[np.argmax(hind[:, 0])], "hh.R": hind[np.argmin(hind[:, 0])],
        "fh.L": front[np.argmax(front[:, 0])], "fh.R": front[np.argmin(front[:, 0])]}
for v, p in zip(body.data.vertices, P):
    v.co = p
body.data.update()
print("FIT scale %.3f  height %.3f  length %.3f  paws" % (k, H, L), {kk: np.round(v, 2).tolist() for kk, v in feet.items()})

# y: piecewise-linear map tail tip -> hind feet -> front feet -> nose
src_y = [Jn["tail3"][1], (Jn["hh.L"][1] + Jn["hh.R"][1]) / 2, (Jn["fh.L"][1] + Jn["fh.R"][1]) / 2, Jn["nose"][1]]
dst_y = [P[:, 1].min(), (feet["hh.L"][1] + feet["hh.R"][1]) / 2, (feet["fh.L"][1] + feet["fh.R"][1]) / 2, P[:, 1].max()]
if species in SPECIES_TOP:
    # tusks / trunk make the mesh's own front and back unreliable anchors: scale by the feet alone
    ky = (dst_y[2] - dst_y[1]) / (src_y[2] - src_y[1])
    dst_y[0] = dst_y[1] + (src_y[0] - src_y[1]) * ky
    dst_y[3] = dst_y[2] + (src_y[3] - src_y[2]) * ky


def ymap(y):
    return float(np.interp(y, src_y, dst_y, left=dst_y[0] + (y - src_y[0]), right=dst_y[-1] + (y - src_y[-1])))
J = {kk: np.array((v[0], ymap(v[1]), v[2])) for kk, v in Jn.items()}
# legs: each chain slides onto its own foot (full at the ground, nothing at the shoulder / hip)
for foot, chain in (("fh", ["sh", "el", "ca", "fh", "toe_f"]), ("hh", ["hp", "st", "ho", "hh", "toe_h"])):
    for s in ("L", "R"):
        f = feet[f"{foot}.{s}"]
        d = np.array((f[0] - J[f"{foot}.{s}"][0], f[1] - J[f"{foot}.{s}"][1], 0.0))
        top = J[f"{chain[0]}.{s}"][2]
        for j in chain:
            key = f"{j}.{s}"
            w = 1.0 - min(max(J[key][2] / max(top, 1e-6), 0.0), 1.0)
            J[key] = J[key] + d * w
        # the shoulder / hip sits above its foot sideways, a little inside
        J[f"{chain[0]}.{s}"][0] = 0.5 * J[f"{chain[0]}.{s}"][0] + 0.5 * f[0] * 0.8
# landmarks from tools/blender/symmetrize_quadruped.py: the tail's own centre line and the back of the buttocks.
# The hips go a little in front of the buttocks (not above the hind paws, which an AI pose may have stepped
# forward), and the tail bones follow the tail instead of running through a thigh.
LM = None
if os.path.exists(src + ".json"):
    import json
    with open(src + ".json") as f:
        LM = json.load(f)
    R90 = np.array([[math.cos(math.radians(yaw)), -math.sin(math.radians(yaw)), 0],
                    [math.sin(math.radians(yaw)), math.cos(math.radians(yaw)), 0], [0, 0, 1]])
    def lm(p):
        q = R90 @ np.array(p) * k
        return q - np.array((spine_x, 0.0, z_shift))
    tl = [lm(p) for p in LM["tail"]]
    for name, i in (("tail", 0), ("tq1", 2), ("tail2", 4), ("tq3", 6), ("tail3", 8)):
        J[name] = tl[i]
    hip_y = tl[0][1] + (Jn["hips"][1] - Jn["tail"][1])     # the species' own hips-to-tail-root distance
    for kk in ("hips", "hp.L", "hp.R"):
        J[kk][1] = hip_y
    print("FIT landmarks: tail root", np.round(tl[0], 3), "tip", np.round(tl[-1], 3), "hips y", round(hip_y, 3))

# body centre line: each spine / neck / head joint goes into the body's own cross-section at that point
def section(y, zmin, half=0.025, xw=None):
    sel = P[(np.abs(P[:, 1] - y) < half * L) & (P[:, 2] > zmin)]
    if xw is not None:
        sel = sel[np.abs(sel[:, 0]) < xw]
    return sel


kz = []
for j, frac, zmin in (("hips", 0.68, 0.42), ("spine", 0.7, 0.42), ("chest", 0.68, 0.42),
                      ("neck", 0.6, 0.45), ("neck2", 0.58, 0.5), ("head", 0.55, 0.55)):
    sec = section(J[j][1], zmin * H)
    if len(sec) > 20:
        top, bot = sec[:, 2].max(), sec[:, 2].min()
        z = bot + frac * (top - bot)
        if j in ("hips", "spine", "chest"):
            kz.append(z / Jn[j][2])
        J[j] = np.array((0.0, J[j][1], z))
kz = float(np.mean(kz)) if kz else 1.0
for kk in list(J.keys()):
    base_k = kk.split(".")[0]
    if base_k in ("sh", "el", "hp", "st", "ca", "ho"):
        J[kk][2] = Jn[kk][2] * kz if base_k in ("sh", "hp") else J[kk][2] * (1 + (kz - 1) * 0.5)
# legs, from the mesh itself: track each leg's centre line up from its paw (slice by slice, following the
# nearest blob of the leg) until it merges into the body, then put the joints where this leg really bends:
#   front: carpus low on the line, elbow at the top of the free leg;
#   hind:  hock = the rear-most point of the lower line, stifle = the front-most point of the upper line.
SZ = Jn["hp.L"][2] / 0.6          # size relative to a wolf; tracking distances below are wolf-sized


def track_leg(paw, zmax, step=0.008 * SZ):
    path = []
    cur = np.array(paw[:2], dtype=float)
    z = 0.01
    while z < zmax:
        sl = P[np.abs(P[:, 2] - z) < step * 0.75]
        sl = sl[np.linalg.norm(sl[:, :2] - cur, axis=1) < 0.09 * SZ]
        if len(sl) < 6:
            break
        width = np.ptp(sl[:, 1])
        if width > 0.22 * SZ:       # reached the chest / belly
            break
        c = sl[:, :2].mean(0)
        cur = 0.6 * cur + 0.4 * c
        path.append((cur[0], cur[1], z))
        z += step
    return np.array(path)


legfit = {}
for s, sx in (("L", 1), ("R", -1)):
    for leg, foot in (("f", "fh"), ("h", "hh")):
        top_j = "sh" if leg == "f" else "hp"
        path = track_leg(feet[f"{foot}.{s}"], J[f"{top_j}.{s}"][2] * 0.85)
        if len(path) < 8:
            continue
        ztop = path[-1, 2]
        def at(zf):
            i = int(np.argmin(np.abs(path[:, 2] - zf)))
            return path[i]
        if leg == "f":
            ca = at(J[f"ca.{s}"][2])
            el = at(min(ztop, J[f"el.{s}"][2]))
            J[f"ca.{s}"] = np.array((ca[0], ca[1], J[f"ca.{s}"][2]))
            J[f"el.{s}"] = np.array((el[0], el[1] - 0.02 * SZ, el[2]))
            J[f"sh.{s}"][1] = J[f"el.{s}"][1] + 0.06 * SZ       # shoulder a little in front of / above the elbow
        else:
            low = path[(path[:, 2] > 0.08 * SZ) & (path[:, 2] < 0.6 * ztop)]
            ho = low[np.argmin(low[:, 1])] if len(low) else at(J[f"ho.{s}"][2])
            up = path[path[:, 2] > ho[2] + 0.06 * SZ]
            st = up[np.argmax(up[:, 1])] if len(up) else at(J[f"st.{s}"][2])
            J[f"ho.{s}"] = np.array((ho[0], ho[1] - 0.012 * SZ, ho[2]))
            J[f"st.{s}"] = np.array((st[0], st[1] + 0.01 * SZ, max(st[2], ho[2] + 0.1 * SZ)))
        f = feet[f"{foot}.{s}"]
        J[f"{foot}.{s}"] = np.array((f[0], f[1] - 0.01 * SZ, J[f"{foot}.{s}"][2]))
        J[f"toe_{leg}.{s}"] = J[f"{foot}.{s}"] + np.array((0, 0.06 * SZ, 0))
        legfit[leg + s] = (round(float(ztop), 3), len(path))
print("FIT legs tracked (top z, samples):", legfit, {kk: np.round(J[kk], 3).tolist() for kk in ("el.L", "ca.L", "st.L", "ho.L")})

# nose, ears, tail
head_pts = P[P[:, 1] > J["neck2"][1]]
if "trunk2" in J:
    # trunk: its tip is the lowest point near the midline in front of the front feet; track it up to the face
    front_y = max(feet["fh.L"][1], feet["fh.R"][1])
    cand = P[(P[:, 1] > front_y + 0.15 * SZ) & (np.abs(P[:, 0]) < 0.05 * SZ)]
    tipp = cand[np.argmin(cand[:, 2])]
    path, cur, z = [], np.array(tipp[[0, 1]], float), tipp[2] + 0.01 * SZ
    while z < H:
        sl = P[(np.abs(P[:, 2] - z) < 0.006 * SZ) & (np.linalg.norm(P[:, :2] - cur, axis=1) < 0.1 * SZ)]
        if len(sl) < 6 or np.ptp(sl[:, 0]) > 0.2 * SZ:
            break
        cur = 0.6 * cur + 0.4 * sl[:, :2].mean(0)
        path.append((0.0, cur[1], z))
        z += 0.008 * SZ
    path = np.array(path)
    if len(path) > 10:
        n = len(path) - 1
        J["trunk4"] = path[int(n * 0.06)]
        J["trunk3"] = path[int(n * 0.38)]
        J["trunk2"] = path[int(n * 0.7)]
        J["nose"] = path[n]
        print("FIT trunk tip", np.round(tipp, 3), "top", np.round(path[n], 3), "samples", len(path))
    # small ears on the sides of the skull, hanging (the species table assumes a different head height)
    hs = section(J["neck2"][1], 0.5 * H, 0.03)
    if len(hs) > 20:
        half_w = 0.8 * np.abs(hs[:, 0]).max()
        for s_, sx in (("L", 1), ("R", -1)):
            J[f"ear.{s_}"] = np.array((sx * half_w, J["neck2"][1], J["neck2"][2] + 0.05 * SZ))
            J[f"ear_t.{s_}"] = J[f"ear.{s_}"] + np.array((sx * 0.04 * SZ, -0.04 * SZ, -0.12 * SZ))
else:
    nose = head_pts[np.argmax(head_pts[:, 1])]
    J["nose"] = np.array((0.0, nose[1] - 0.01, nose[2]))
for s, sx in (("L", 1), ("R", -1)) if species not in ("mammoth",) else ():
    side = head_pts[np.sign(head_pts[:, 0]) == sx]
    if len(side):
        tip = side[np.argmax(side[:, 2])]
        J[f"ear.{s}"] = tip + (J[f"ear.{s}"] - J[f"ear_t.{s}"])
        J[f"ear_t.{s}"] = tip
back = P[P[:, 1] < J["hips"][1]]
tip = back[np.argmin(back[:, 1])]
if LM is None:
    J["tail3"] = tip
for j, t in ((("tail", 0.0), ("tail2", 0.5)) if LM is None else ()):
    yj = J["hips"][1] + (tip[1] - J["hips"][1]) * (0.12 if t == 0.0 else 0.55)
    sec = section(yj, 0.0, 0.02, xw=abs(tip[0]) + 0.08)
    sec = sec[sec[:, 2] > 0.25 * H] if j == "tail" else sec
    if len(sec) > 10:
        J[j] = np.array((0.0, yj, float(np.median(sec[:, 2]))))
# derived joints are recomputed from the fitted ones
for kk in ("spine2", "jaw", "jaw_t", "scap.L", "scap.R") + (("tq1", "tq3") if LM is None else ()):
    J.pop(kk, None)
J = {kk: np.array(v) for kk, v in fl.complete_joints({kk: tuple(v) for kk, v in J.items()}).items()}
print("FIT kz %.2f" % kz, {kk: np.round(J[kk], 2).tolist() for kk in ("hips", "spine", "chest", "neck", "head", "nose", "tail", "tail3")})

sp = dict(base)
sp["J"] = {kk: tuple(float(x) for x in v) for kk, v in J.items()}
sp["mouth"] = None
walk, run, attack = GAITS.get(species, (None, None, None))
sp["speeds"] = ga.game_speeds(sp)          # IK gait timed to the game speed (planted feet)
if walk is not None:
    # a heavy fur ruff creases if the shoulder blade and spine swing as far as on the procedural bodies
    walk = dict(walk, scap=4, spine=walk.get("spine", 0) * 0.5, yaw=walk.get("yaw", 0) * 0.5)
    run = dict(run, scap=6, spine=run.get("spine", 0) * 0.45, yaw=run.get("yaw", 0) * 0.5,
               fold_f=min(60, run.get("fold_f", 60)))
    sp["clips"] = lambda rig: fl.std_clips(rig, sp, walk, run)
    sp["attack"] = lambda rig: attack(rig, sp)

textured = any(m and m.use_nodes and any(n.type == "TEX_IMAGE" and n.image for n in m.node_tree.nodes)
               for m in body.data.materials)
if textured:
    # a textured scan (e.g. Tripo): keep its own material, named for the species so the game treats it as a coat
    for m in body.data.materials:
        m.name = f"M_{base['name']}_Textured"
        bsdf = next((n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf:
            bsdf.inputs["Metallic"].default_value = 0.0
else:
    mat = bpy.data.materials.new("M_Clay")
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.45, 0.42, 0.38, 1)
    body.data.materials.clear()
    body.data.materials.append(mat)
for poly in body.data.polygons:
    poly.use_smooth = True

rig = fl.build_rig(sp)
fl.activate(body)
rig.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.parent_set(type="ARMATURE_AUTO")
# soften the hand-over between bones (AI fur ruffs tear where auto weights change abruptly)
fl.smooth_weights(body, int(os.environ.get("RIG_SMOOTH", "1")))
if float(os.environ.get("RIG_FIRM", "0")) > 0:
    fl.firm_weights(body, 3, float(os.environ.get("RIG_FIRM", "0")))
fl.isolate_chains(body, rig, [("tail", "tail2", "tail3", "tail_tip")])
# lower legs keep off the trunk; a wide hand-over so thick limbs bend without a crack at the elbow / stifle
fl.isolate_chains(body, rig, [(f"forearm.{s}", f"hoof_f.{s}", f"hoof_f_toe.{s}") for s in ("L", "R")]
                  + [(f"shin.{s}", f"hoof_h.{s}", f"hoof_h_toe.{s}") for s in ("L", "R")], lo=0.3, hi=0.8)
clips = fl.make_clips(rig, sp)
bpy.ops.object.select_all(action="DESELECT")
body.select_set(True)
rig.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB", use_selection=True, export_yup=True,
                          export_animations=True, export_animation_mode="NLA_TRACKS", export_skins=True)
print("RIGGED", dst, "bones", len(rig.data.bones), "clips", clips)
