"""Makes a clean, symmetric standing quadruped from a lopsided sculpt, in voxel space:

1. every slice along the length is shifted sideways onto one axis (bent spine, head set to one side, turned muzzle);
2. the closed mesh is voxelised (ray parity), the better half of the volume is mirrored onto the other;
3. the old tail is cleared from the volume and a new bushy tail (SDF) is grown, hanging free of the hind legs;
4. the surface is rebuilt with surface nets (same mesher as the procedural animals) and decimated.

  Blender -b --factory-startup -P tools/blender/symmetrize_quadruped.py -- in.glb out.glb keep=+|- [cut=0.19]
      [cut_w=0.05] [tail=1] [tail_len=0.32] [tail_r=0.055] [droop=72] [voxel=0.0045] [blur=1.0] [tris=40000]

Input axes (as after tools/blender/straighten_mesh.py): X = length (nose at +X), Y = side, Z = up; the mesh must be
closed. keep=+ keeps the +Y half (the animal's left). Lengths are fractions of the body length.
"""
import bpy, bmesh, sys, os, math
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fauna_lib as fl

a = sys.argv[sys.argv.index("--") + 1:]
src, dst = a[0], a[1]
O = {"keep": "+", "cut": "0.19", "cut_w": "0.08", "tail": "1", "tail_len": "0.32", "tail_r": "0.055", "droop": "72",
     "voxel": "0.0045", "blur": "1.0", "tris": "40000"}
for kv in a[2:]:
    k, v = kv.split("=")
    O[k] = v

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
o = max((x for x in bpy.context.scene.objects if x.type == "MESH"), key=lambda x: len(x.data.vertices))
o.data.transform(o.matrix_world)
P = np.array([v.co[:] for v in o.data.vertices])
tris = []
for poly in o.data.polygons:
    vs = list(poly.vertices)
    for i in range(1, len(vs) - 1):
        tris.append((vs[0], vs[i], vs[i + 1]))
for x in list(bpy.context.scene.objects):
    bpy.data.objects.remove(x)

P[:, 2] -= P[:, 2].min()
lo, hi = P.min(0), P.max(0)
L = hi[0] - lo[0]
H = hi[2]

# 1. slice-by-slice midline
# (band 0.55-0.8 H: trunk, neck, head and muzzle, but not the ears; a 3-wide median keeps the muzzle tip)
n = 60
xs, cs = [], []
for i in range(n):
    xa = lo[0] + L * (i + 0.5) / n
    s_ = P[(np.abs(P[:, 0] - xa) < 0.5 * L / n) & (P[:, 2] > 0.55 * H) & (P[:, 2] < 0.8 * H)]
    if len(s_) > 4:
        xs.append(xa)
        cs.append(0.5 * (s_[:, 1].min() + s_[:, 1].max()))
cs = np.array(cs)
cs = np.array([np.median(cs[max(0, i - 1):i + 2]) for i in range(len(cs))])
P[:, 1] -= np.interp(P[:, 0], xs, cs)
print("MIDLINE shifts (m):", [round(float(c), 3) for c in cs[::4]])

# 2. voxelise. AI sculpts have self-intersecting shells (fur ruffs, a muzzle pushed into the cheeks) that break a
# parity test, so first rebuild the surface with Blender's voxel remesh (OpenVDB fills from the outside), then cast.
h = float(O["voxel"]) * L
_me = bpy.data.meshes.new("src")
_me.from_pydata([tuple(p) for p in P], [], tris)
_ob = bpy.data.objects.new("src", _me)
bpy.context.scene.collection.objects.link(_ob)
fl.activate(_ob)
_rm = _ob.modifiers.new("rm", "REMESH")
_rm.mode = "VOXEL"
_rm.voxel_size = h * 0.7
bpy.ops.object.modifier_apply(modifier="rm")
P = np.array([v.co[:] for v in _me.vertices])
tris = []
for poly in _me.polygons:
    vs = list(poly.vertices)
    for i in range(1, len(vs) - 1):
        tris.append((vs[0], vs[i], vs[i + 1]))
bpy.data.objects.remove(_ob)
print("REMESHED", len(P), "verts")
pad = 4 * h
ylim = np.abs(P[:, 1]).max() + pad
gx = np.arange(lo[0] - pad - 0.25 * L, hi[0] + pad, h)          # room behind for the new tail
ny = int(math.ceil(2 * ylim / h)) | 1                            # odd, so y = 0 is a grid line
gy = (np.arange(ny) - ny // 2) * h
gz = np.arange(-2 * h, H + pad, h)
bvh = BVHTree.FromPolygons([Vector(p) for p in P], tris, all_triangles=True)
G = np.zeros((len(gx), len(gy), len(gz)), dtype=np.float32)
x0 = gx[0] - h
eps = 1e-5
for j, yv in enumerate(gy):
    for k, zv in enumerate(gz):
        hits = []
        org = Vector((x0, yv + 1e-4, zv + 1.3e-4))
        while True:
            loc, nrm, idx, d = bvh.ray_cast(org, Vector((1, 0, 0)))
            if loc is None:
                break
            hits.append(loc.x)
            org = Vector((loc.x + eps, org.y, org.z))
        if len(hits) < 2:
            continue
        cnt = np.searchsorted(np.array(hits), gx)          # crossings before each sample
        G[:, j, k] = (cnt % 2 == 1)
print("VOXELS grid", G.shape, "filled", int(G.sum()))

# mirror the kept half (index ny//2 is y = 0)
c = ny // 2
if O["keep"] == "+":
    G[:, :c, :] = G[:, c + 1:, :][:, ::-1, :]
else:
    G[:, c + 1:, :] = G[:, :c, :][:, ::-1, :]

# 3. clear the old tail: behind the rump, near the midline
x_cut = lo[0] + float(O["cut"]) * L
mask = (gx[:, None, None] < x_cut) & (np.abs(gy)[None, :, None] < float(O["cut_w"]) * L)
G[np.broadcast_to(mask, G.shape)] = 0
print("TAIL CUT at x =", round(x_cut, 3))


def blur1(A, axis, s):
    r = max(1, int(math.ceil(2.5 * s)))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / s) ** 2)
    k /= k.sum()
    A = np.moveaxis(A, axis, -1)
    Ap = np.pad(A, [(0, 0)] * (A.ndim - 1) + [(r, r)], mode="edge")
    out = np.zeros_like(A)
    for i, w in enumerate(k):
        out += w * Ap[..., i:i + A.shape[-1]]
    return np.moveaxis(out, -1, axis)


# smooth occupancy -> approximate signed distance (negative inside)
B = G
if float(O["blur"]) > 0:
    for ax in range(3):
        B = blur1(B, ax, float(O["blur"]))
F = (0.5 - B) * 3.0 * h

# new tail as an SDF, blended into the rump
if O["tail"] == "1":
    xi = np.searchsorted(gx, x_cut + 0.03 * L)
    col = np.nonzero(G[xi:xi + 3, c - 2:c + 3, :].any(axis=(0, 1)))[0]
    zr = gz[col.max()] - 0.04 * L if len(col) else 0.75 * H
    root = np.array((x_cut + 0.04 * L, 0.0, zr))
    TL = float(O["tail_len"]) * L
    R = float(O["tail_r"]) * L
    droop = math.radians(float(O["droop"]))
    pts = [root]
    step = TL / 8
    for i in range(1, 9):
        t = i / 8
        ang = droop * (0.3 + 0.7 * t)
        pts.append(pts[-1] + step * np.array((-math.cos(ang), 0.0, -math.sin(ang))))
    rad = [R * (0.7 + 0.75 * math.sin(math.pi * min(1.0, 0.2 + i / 8))) for i in range(9)]
    rad[-1] = R * 0.4
    lo_t = np.min(pts, 0) - 2.5 * R
    hi_t = np.max(pts, 0) + 2.5 * R
    ii = np.nonzero((gx >= lo_t[0]) & (gx <= hi_t[0]))[0]
    jj = np.nonzero((gy >= lo_t[1]) & (gy <= hi_t[1]))[0]
    kk = np.nonzero((gz >= lo_t[2]) & (gz <= hi_t[2]))[0]
    X, Y, Z = np.meshgrid(gx[ii], gy[jj], gz[kk], indexing="ij")
    Q = np.stack([X.ravel(), Y.ravel(), Z.ravel()], 1)
    D = np.full(len(Q), 1e3)
    for i in range(8):
        D = fl.smin(D, fl.sd_cone(Q, np.array(pts[i]), np.array(pts[i + 1]), rad[i], rad[i + 1]), 0.02 * L)
    sub = F[np.ix_(ii, jj, kk)].ravel()
    F[np.ix_(ii, jj, kk)] = fl.smin(sub, D, 0.03 * L).reshape(len(ii), len(jj), len(kk))
    print("TAIL root", np.round(root, 3), "tip", np.round(pts[-1], 3), "len", round(TL, 3), "r", round(R, 3))
    import json
    with open(dst + ".json", "w") as f:   # landmarks for tools/blender/rig_custom.py (same axes as the output)
        json.dump({"tail": [list(map(float, q)) for q in pts], "buttock_x": float(x_cut)}, f)

# 4. surface
verts, faces = fl.surface_nets(F.astype(np.float64), np.array((gx[0], gy[0], gz[0])), h)
obj = fl.mesh_from_arrays("Body", verts, faces)
bm = bmesh.new()
bm.from_mesh(obj.data)
bm.verts.ensure_lookup_table()
seen, best = set(), []
for v in bm.verts:
    if v.index in seen:
        continue
    comp, stack = [], [v]
    while stack:
        q = stack.pop()
        if q.index in seen:
            continue
        seen.add(q.index)
        comp.append(q)
        stack.extend(e.other_vert(q) for e in q.link_edges)
    if len(comp) > len(best):
        best = comp
keep = set(v.index for v in best)
bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.index not in keep], context="VERTS")
bm.to_mesh(obj.data)
bm.free()
fl.activate(obj)
nt = sum(len(p.vertices) - 2 for p in obj.data.polygons)
dec = obj.modifiers.new("dec", "DECIMATE")
dec.ratio = min(1.0, float(O["tris"]) / max(nt, 1))
dec.use_symmetry = True
dec.symmetry_axis = "Y"
bpy.ops.object.modifier_apply(modifier="dec")
for p in obj.data.polygons:
    p.use_smooth = True
bm = bmesh.new()
bm.from_mesh(obj.data)
print("RESULT tris", sum(len(f.verts) - 2 for f in bm.faces), "open edges", sum(1 for e in bm.edges if e.is_boundary),
      "size", np.round(np.ptp(np.array([v.co[:] for v in bm.verts]), 0), 3))
bm.free()
bpy.ops.object.select_all(action="DESELECT")
obj.select_set(True)
bpy.ops.export_scene.gltf(filepath=dst, use_selection=True, export_format="GLB")
print("WROTE", dst)
