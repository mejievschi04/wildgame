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
sp_h = max(Jn["ear_t.L"][2], Jn["head"][2])
k = sp_h / (P[:, 2].max() - P[:, 2].min())
P = P * k
P[:, 2] -= P[:, 2].min()
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
# nose, ears, tail
head_pts = P[P[:, 1] > J["neck2"][1]]
nose = head_pts[np.argmax(head_pts[:, 1])]
J["nose"] = np.array((0.0, nose[1] - 0.01, nose[2]))
for s, sx in (("L", 1), ("R", -1)):
    side = head_pts[np.sign(head_pts[:, 0]) == sx]
    if len(side):
        tip = side[np.argmax(side[:, 2])]
        J[f"ear.{s}"] = tip + (J[f"ear.{s}"] - J[f"ear_t.{s}"])
        J[f"ear_t.{s}"] = tip
back = P[P[:, 1] < J["hips"][1]]
tip = back[np.argmin(back[:, 1])]
J["tail3"] = tip
for j, t in (("tail", 0.0), ("tail2", 0.5)):
    yj = J["hips"][1] + (tip[1] - J["hips"][1]) * (0.12 if t == 0.0 else 0.55)
    sec = section(yj, 0.0, 0.02, xw=abs(tip[0]) + 0.08)
    sec = sec[sec[:, 2] > 0.25 * H] if j == "tail" else sec
    if len(sec) > 10:
        J[j] = np.array((0.0, yj, float(np.median(sec[:, 2]))))
# derived joints are recomputed from the fitted ones
for kk in ("spine2", "tq1", "tq3", "jaw", "jaw_t", "scap.L", "scap.R"):
    J.pop(kk, None)
J = {kk: np.array(v) for kk, v in fl.complete_joints({kk: tuple(v) for kk, v in J.items()}).items()}
print("FIT kz %.2f" % kz, {kk: np.round(J[kk], 2).tolist() for kk in ("hips", "spine", "chest", "neck", "head", "nose", "tail", "tail3")})

sp = dict(base)
sp["J"] = {kk: tuple(float(x) for x in v) for kk, v in J.items()}
sp["mouth"] = None
walk = getattr(ga, species.upper() + "_WALK", None)
run = getattr(ga, species.upper() + "_RUN", None)
if walk is not None:
    sp["clips"] = lambda rig: fl.std_clips(rig, sp, walk, run)
    sp["attack"] = lambda rig: fl.bite_attack(rig, sp, 0.28)

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
fl.isolate_chains(body, rig, [("tail", "tail2", "tail3", "tail_tip")])
clips = fl.make_clips(rig, sp)
bpy.ops.object.select_all(action="DESELECT")
body.select_set(True)
rig.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB", use_selection=True, export_yup=True,
                          export_animations=True, export_animation_mode="NLA_TRACKS", export_skins=True)
print("RIGGED", dst, "bones", len(rig.data.bones), "clips", clips)
