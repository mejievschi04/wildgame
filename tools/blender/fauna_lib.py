# Fauna pipeline library (used by gen_animals.py).
#   anatomy:  signed-distance sculpt (smooth union of tapered capsules + ellipsoids, subtractions)
#             → surface-nets mesh → smoothed + decimated game mesh
#   look:     per-vertex coat/fur/roughness attributes → Cycles bake (albedo × AO, fur-strand normal,
#             roughness) to 2k PBR maps; long hair as alpha fur cards with a generated strand atlas
#   motion:   named-bone rig (auto weights; cards inherit their root's weights), procedural gait clips
# Blender Z-up, animals face +Y (→ Godot -Z after glTF export).
import bpy, bmesh, math, os, random
import numpy as np
from mathutils import Vector, Matrix, Euler

FPS = 24


def V(*a):
    return np.array(a[0] if len(a) == 1 else a, dtype=np.float64)


# ============================================================== SDF sculpt

class Sculpt:
    """Ordered list of SDF operations. Each op: ('add'|'sub', kind, params, k_blend)."""

    def __init__(self):
        self.ops = []

    def cone(self, a, b, ra, rb, k=0.04):
        self.ops.append(("add", "cone", (V(a), V(b), ra, rb), k))

    def ell(self, c, r, rot=(0, 0, 0), k=0.04, sub=False):
        R = np.array(Euler([math.radians(x) for x in rot], "XYZ").to_matrix())
        self.ops.append(("sub" if sub else "add", "ell", (V(c), V(r), R), k))

    def leaf(self, a, b, width, thick, normal, k=0.02):
        """Flat ellipsoid spanning a→b (ears, flaps). `normal` = flat side direction."""
        a, b, nrm = V(a), V(b), V(normal)
        y = b - a; L = np.linalg.norm(y); y /= L
        x = nrm - y * np.dot(nrm, y); x /= np.linalg.norm(x)
        z = np.cross(x, y)
        R = np.stack([x, y, z], axis=1)
        self.ops.append(("add", "ell", ((a + b) * 0.5, V(thick, L * 0.5, width), R), k))

    def sphere(self, c, r, k=0.02, sub=False):
        self.ops.append(("sub" if sub else "add", "ell", (V(c), V(r, r, r), np.eye(3)), k))

    def scaled(self, f):
        """Uniformly scaled copy (same anatomy, different size: roe from red deer, etc.)."""
        out = Sculpt()
        for op, kind, p, k in self.ops:
            if kind == "cone":
                q = (p[0] * f, p[1] * f, p[2] * f, p[3] * f)
            else:
                q = (p[0] * f, p[1] * f, p[2])
            out.ops.append((op, kind, q, k * f))
        return out

    # ---- evaluation
    @staticmethod
    def _bbox(kind, p, k):
        if kind == "cone":
            a, b, ra, rb = p
            m = max(ra, rb) + k
            return np.minimum(a, b) - m, np.maximum(a, b) + m
        c, r, R = p
        ext = np.abs(R) @ r  # world AABB half extents of the rotated ellipsoid
        return c - ext - k, c + ext + k

    def bounds(self):
        lo, hi = np.full(3, 1e9), np.full(3, -1e9)
        for op, kind, p, k in self.ops:
            if op == "add":
                a, b = self._bbox(kind, p, 0.0)
                lo, hi = np.minimum(lo, a), np.maximum(hi, b)
        return lo, hi

    def evaluate(self, h):
        lo, hi = self.bounds()
        lo, hi = lo - 4 * h, hi + 4 * h
        n = np.ceil((hi - lo) / h).astype(int) + 1
        axes = [lo[i] + np.arange(n[i]) * h for i in range(3)]
        F = np.full(n, 1e3, dtype=np.float64)
        for op, kind, p, k in self.ops:
            margin = k + 4 * h
            a, b = self._bbox(kind, p, margin)
            i0 = [max(0, int((a[i] - lo[i]) / h)) for i in range(3)]
            i1 = [min(n[i], int((b[i] - lo[i]) / h) + 2) for i in range(3)]
            if any(i1[i] <= i0[i] for i in range(3)):
                continue
            X, Y, Z = np.meshgrid(axes[0][i0[0]:i1[0]], axes[1][i0[1]:i1[1]], axes[2][i0[2]:i1[2]], indexing="ij")
            P = np.stack([X.ravel(), Y.ravel(), Z.ravel()], axis=1)
            d = sd_cone(P, *p) if kind == "cone" else sd_ell(P, *p)
            blk = F[i0[0]:i1[0], i0[1]:i1[1], i0[2]:i1[2]]
            cur = blk.ravel()
            res = smin(cur, d, k) if op == "add" else -smin(-cur, d, k)
            F[i0[0]:i1[0], i0[1]:i1[1], i0[2]:i1[2]] = res.reshape(blk.shape)
        return F, lo


def sd_cone(P, a, b, r1, r2):
    """Inigo Quilez's exact round cone (tapered capsule)."""
    ba = b - a
    l2 = ba @ ba
    rr = r1 - r2
    a2 = l2 - rr * rr
    il2 = 1.0 / l2
    pa = P - a
    y = pa @ ba
    z = y - l2
    xv = pa * l2 - np.outer(y, ba)
    x2 = np.einsum("ij,ij->i", xv, xv)
    y2 = y * y * l2
    z2 = z * z * l2
    k = np.sign(rr) * rr * rr * x2
    d3 = (np.sqrt(np.maximum(x2 * a2 * il2, 0)) + y * rr) * il2 - r1
    d2 = np.where(np.sign(y) * a2 * y2 < k, np.sqrt(x2 + y2) * il2 - r1, d3)
    return np.where(np.sign(z) * a2 * z2 > k, np.sqrt(x2 + z2) * il2 - r2, d2)


def sd_ell(P, c, r, R):
    q = (P - c) @ R
    k0 = np.linalg.norm(q / r, axis=1)
    k1 = np.linalg.norm(q / (r * r), axis=1)
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)


def smin(a, b, k):
    if k <= 0:
        return np.minimum(a, b)
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b * (1 - h) + a * h - k * h * (1 - h)


# ============================================================== surface nets

_CORNERS = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1)]
_EDGES = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]


def surface_nets(F, origin, h):
    nx, ny, nz = F.shape
    cs = [F[i:nx - 1 + i, j:ny - 1 + j, k:nz - 1 + k] for (i, j, k) in _CORNERS]
    acc = np.zeros((nx - 1, ny - 1, nz - 1, 3))
    cnt = np.zeros((nx - 1, ny - 1, nz - 1))
    for e0, e1 in _EDGES:
        f0, f1 = cs[e0], cs[e1]
        m = (f0 < 0) != (f1 < 0)
        t = np.where(m, f0 / np.where(m, f0 - f1, 1.0), 0.0)
        c0, c1 = np.array(_CORNERS[e0], float), np.array(_CORNERS[e1], float)
        pos = c0[None, None, None, :] + t[..., None] * (c1 - c0)[None, None, None, :]
        acc += np.where(m[..., None], pos, 0.0)
        cnt += m
    active = cnt > 0
    idx = -np.ones(active.shape, dtype=np.int64)
    idx[active] = np.arange(active.sum())
    ijk = np.argwhere(active)
    verts = origin + (ijk + acc[active] / cnt[active][:, None]) * h
    faces = []
    inside = F < 0
    for axis in range(3):
        b, c = (axis + 1) % 3, (axis + 2) % 3
        sl0 = [slice(None)] * 3
        sl1 = [slice(None)] * 3
        sl0[axis] = slice(0, -1)
        sl1[axis] = slice(1, None)
        change = inside[tuple(sl0)] != inside[tuple(sl1)]
        flip = inside[tuple(sl0)]
        # need neighbouring cells at -1 along b and c
        lim = [slice(None)] * 3
        lim[b] = slice(1, None)
        lim[c] = slice(1, None)
        ch = np.zeros_like(change)
        ch[tuple(lim)] = change[tuple(lim)]
        sl_b = [slice(None)] * 3
        sl_b[b] = slice(0, -1)  # last grid line along b has no cell
        sl_b[c] = slice(0, -1)
        ch2 = np.zeros_like(ch)
        ch2[tuple(sl_b)] = ch[tuple(sl_b)]
        pts = np.argwhere(ch2)
        if len(pts) == 0:
            continue
        def cell(db, dc):
            q = pts.copy()
            q[:, b] += db
            q[:, c] += dc
            return idx[q[:, 0], q[:, 1], q[:, 2]]
        q0, q1, q2, q3 = cell(-1, -1), cell(0, -1), cell(0, 0), cell(-1, 0)
        fl = flip[pts[:, 0], pts[:, 1], pts[:, 2]]
        quad = np.where(fl[:, None], np.stack([q0, q3, q2, q1], 1), np.stack([q0, q1, q2, q3], 1))
        faces.append(quad)
    faces = np.concatenate(faces)
    faces = faces[(faces >= 0).all(axis=1)]
    return verts, faces


def mesh_from_arrays(name, verts, faces):
    me = bpy.data.meshes.new(name)
    me.vertices.add(len(verts))
    me.vertices.foreach_set("co", verts.astype(np.float32).ravel())
    n = len(faces)
    me.loops.add(n * 4)
    me.loops.foreach_set("vertex_index", faces.astype(np.int32).ravel())
    me.polygons.add(n)
    me.polygons.foreach_set("loop_start", np.arange(0, n * 4, 4, dtype=np.int32))
    me.polygons.foreach_set("loop_total", np.full(n, 4, dtype=np.int32))
    me.update(calc_edges=True)
    me.validate()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def activate(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def sculpt_to_mesh(sc, name, voxel, target_tris):
    F, lo = sc.evaluate(voxel)
    verts, faces = surface_nets(F, lo, voxel)
    obj = mesh_from_arrays(name, verts, faces)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    # keep only the largest connected piece (drops stray specks)
    bm.verts.ensure_lookup_table()
    seen, best = set(), []
    for v in bm.verts:
        if v.index in seen:
            continue
        comp, stack = [], [v]
        seen.add(v.index)
        while stack:
            u = stack.pop()
            comp.append(u)
            for e in u.link_edges:
                w = e.other_vert(u)
                if w.index not in seen:
                    seen.add(w.index)
                    stack.append(w)
        if len(comp) > len(best):
            best = comp
    keep = set(x.index for x in best)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.index not in keep], context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    activate(obj)
    sm = obj.modifiers.new("smooth", "SMOOTH"); sm.factor = 0.6; sm.iterations = 3
    bpy.ops.object.modifier_apply(modifier="smooth")
    tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    dec = obj.modifiers.new("dec", "DECIMATE"); dec.ratio = min(1.0, target_tris / max(tris, 1))
    bpy.ops.object.modifier_apply(modifier="dec")
    bpy.ops.object.shade_smooth()
    return obj


# ============================================================== tubes (tusks, horns, antlers, claws)

def catmull(points, n):
    P = [Vector(p) for p in points]
    P = [P[0] * 2 - P[1]] + P + [P[-1] * 2 - P[-2]]
    out = []
    segs = len(P) - 3
    for i in range(n):
        t = i / (n - 1) * segs
        s = min(int(t), segs - 1)
        u = t - s
        p0, p1, p2, p3 = P[s], P[s + 1], P[s + 2], P[s + 3]
        out.append(0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u + (-p0 + 3 * p1 - 3 * p2 + p3) * u ** 3))
    return out


def tube(name, points, r0, r1, ring=12, n=24, mat=None, power=1.0):
    pts = catmull(points, n)
    verts, faces = [], []
    prev_x = None
    for i, p in enumerate(pts):
        t = i / (n - 1)
        tan = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized()
        x = (prev_x - tan * prev_x.dot(tan)).normalized() if prev_x else tan.orthogonal().normalized()
        prev_x = x
        y = tan.cross(x)
        r = r0 + (r1 - r0) * (t ** power)
        for j in range(ring):
            a = j / ring * math.tau
            verts.append(p + (x * math.cos(a) + y * math.sin(a)) * r)
    for i in range(n - 1):
        for j in range(ring):
            a, b = i * ring + j, i * ring + (j + 1) % ring
            faces.append((a, b, b + ring, a + ring))
    tip = len(verts); verts.append(pts[-1] + (pts[-1] - pts[-2]).normalized() * r1)
    base = len(verts); verts.append(pts[0])
    for j in range(ring):
        faces.append(((n - 1) * ring + j, (n - 1) * ring + (j + 1) % ring, tip))
        faces.append(((j + 1) % ring, j, base))
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    for p in obj.data.polygons:
        p.use_smooth = True
    if mat:
        obj.data.materials.append(mat)
    return obj


def eye(name, c, r, mat):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=14, v_segments=10, radius=r)
    bmesh.ops.translate(bm, verts=bm.verts, vec=Vector(c))
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    for p in obj.data.polygons:
        p.use_smooth = True
    obj.data.materials.append(mat)
    return obj


def simple_mat(name, color, rough, spec=0.5):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*lin(color), 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Specular IOR Level"].default_value = spec
    return m


def lin(c):
    return tuple(pow(max(x, 0.0), 2.2) for x in c)


# ============================================================== skeleton

def bone_table(sp):
    """[(bone, head_joint, tail_joint, parent)] — standard quadruped + species extras."""
    B = [("hips", "tail", "hips", None), ("spine", "hips", "spine", "hips"), ("chest", "spine", "chest", "spine"),
         ("neck", "chest", "neck", "chest"), ("neck2", "neck", "neck2", "neck"), ("head", "neck2", "head", "neck2"),
         ("snout", "head", "nose", "head"), ("tail", "tail", "tail2", "hips"), ("tail_tip", "tail2", "tail3", "tail"),
         ("ear.L", "ear.L", "ear_t.L", "head"), ("ear.R", "ear.R", "ear_t.R", "head")]
    for s in ("L", "R"):
        B += [(f"upperarm.{s}", f"sh.{s}", f"el.{s}", "chest"), (f"forearm.{s}", f"el.{s}", f"ca.{s}", f"upperarm.{s}"),
              (f"hoof_f.{s}", f"ca.{s}", f"fh.{s}", f"forearm.{s}"),
              (f"thigh.{s}", f"hp.{s}", f"st.{s}", "hips"), (f"shin.{s}", f"st.{s}", f"ho.{s}", f"thigh.{s}"),
              (f"hoof_h.{s}", f"ho.{s}", f"hh.{s}", f"shin.{s}")]
    return B + sp.get("extra_bones", [])


def mirror_joints(J):
    out = {}
    for k, v in J.items():
        if k.endswith(".L"):
            out[k] = v
            out[k[:-2] + ".R"] = (-v[0], v[1], v[2])
        else:
            out[k] = v
    return out


def build_rig(sp):
    J = {k: Vector(v) for k, v in sp["J"].items()}
    arm = bpy.data.armatures.new(sp["name"] + "Rig")
    rig = bpy.data.objects.new(sp["name"] + "Rig", arm)
    bpy.context.scene.collection.objects.link(rig)
    activate(rig)
    bpy.ops.object.mode_set(mode="EDIT")
    for name, h, t, parent in bone_table(sp):
        b = arm.edit_bones.new(name)
        b.head, b.tail = J[h], J[t]
        if (b.tail - b.head).length < 0.01:
            b.tail = b.head + Vector((0, 0.05, 0))
        d = (b.tail - b.head).normalized()
        b.align_roll(Vector((0, 1, 0)) if abs(d.y) < 0.8 else Vector((0, 0, 1)))
    for name, h, t, parent in bone_table(sp):
        if parent:
            arm.edit_bones[name].parent = arm.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return rig


def nearest_bone(sp, P):
    """Per point: index into bone_table of the nearest bone segment, and that table."""
    J = {k: np.array(v) for k, v in sp["J"].items()}
    table = bone_table(sp)
    best = np.full(len(P), 1e9)
    which = np.zeros(len(P), dtype=int)
    for i, (name, h, t, _) in enumerate(table):
        if name == "hips":
            continue
        a, b = J[h], J[t]
        ab = b - a
        tt = np.clip(((P - a) @ ab) / max(ab @ ab, 1e-9), 0, 1)
        d = np.linalg.norm(P - (a + np.outer(tt, ab)), axis=1)
        m = d < best
        best[m] = d[m]
        which[m] = i
    return which, table


# ============================================================== coat attributes & bake

def mesh_arrays(obj):
    me = obj.data
    n = len(me.vertices)
    co = np.zeros(n * 3); me.vertices.foreach_get("co", co)
    no = np.zeros(n * 3); me.vertices.foreach_get("normal", no)
    return co.reshape(-1, 3), no.reshape(-1, 3)


def write_attributes(obj, sp):
    """Species coat(p, n, bone) → (rgb sRGB, fur 0..1, roughness). Stored as point attributes."""
    P, N = mesh_arrays(obj)
    which, table = nearest_bone(sp, P)
    names = [b[0] for b in table]
    col = np.zeros((len(P), 4))
    fur = np.zeros(len(P))
    rough = np.zeros(len(P))
    legw = np.zeros(len(P))
    rnd = random.Random(sp["name"])
    for i in range(len(P)):
        bone = names[which[i]]
        c, f, r = sp["coat"](P[i], N[i], bone)
        col[i, :3] = lin(c)
        col[i, 3] = 1
        fur[i], rough[i] = f, r
        legw[i] = 1.0 if bone.split(".")[0] in ("upperarm", "forearm", "hoof_f", "thigh", "shin", "hoof_h") else 0.0
    me = obj.data
    ca = me.color_attributes.new("Coat", "FLOAT_COLOR", "POINT")
    ca.data.foreach_set("color", col.astype(np.float32).ravel())
    for nm, arr in (("fur", fur), ("rough", rough), ("legw", legw)):
        at = me.attributes.new(nm, "FLOAT", "POINT")
        at.data.foreach_set("value", arr.astype(np.float32))
    return which, names


def bake_material(sp):
    """Shader whose outputs get baked: strand-modulated coat colour, fur bump normal, roughness."""
    m = bpy.data.materials.new(f"M_{sp['name']}_Bake")
    m.use_nodes = True
    nt = m.node_tree
    N, L = nt.nodes, nt.links
    b = N["Principled BSDF"]
    coat = N.new("ShaderNodeVertexColor"); coat.layer_name = "Coat"
    furA = N.new("ShaderNodeAttribute"); furA.attribute_name = "fur"
    roughA = N.new("ShaderNodeAttribute"); roughA.attribute_name = "rough"
    legA = N.new("ShaderNodeAttribute"); legA.attribute_name = "legw"
    tc = N.new("ShaderNodeTexCoord")
    s = sp.get("fur_scale", 220.0)
    st = sp.get("fur_stretch", 9.0)

    def strands(scale_vec):
        mp = N.new("ShaderNodeMapping"); mp.inputs["Scale"].default_value = scale_vec
        L.new(tc.outputs["Object"], mp.inputs["Vector"])
        nz = N.new("ShaderNodeTexNoise"); nz.inputs["Scale"].default_value = 1.0
        nz.inputs["Detail"].default_value = 6.0; nz.inputs["Roughness"].default_value = 0.7
        L.new(mp.outputs["Vector"], nz.inputs["Vector"])
        return nz

    body = strands((s, s / st, s))      # hair flows along body (Y)
    legs = strands((s, s, s / st))      # hair flows down the legs (Z)
    mixh = N.new("ShaderNodeMix"); mixh.data_type = "FLOAT"
    L.new(legA.outputs["Fac"], mixh.inputs["Factor"])
    L.new(body.outputs["Fac"], mixh.inputs[2]); L.new(legs.outputs["Fac"], mixh.inputs[3])
    # clumps: coarse voronoi, stretched the same way
    mpc = N.new("ShaderNodeMapping"); mpc.inputs["Scale"].default_value = (s * 0.12, s * 0.12 / st * 2, s * 0.12)
    L.new(tc.outputs["Object"], mpc.inputs["Vector"])
    vor = N.new("ShaderNodeTexVoronoi"); vor.feature = "F1"
    L.new(mpc.outputs["Vector"], vor.inputs["Vector"])
    height = N.new("ShaderNodeMath"); height.operation = "MULTIPLY_ADD"
    L.new(mixh.outputs[0], height.inputs[0]); height.inputs[1].default_value = 0.7
    L.new(vor.outputs["Distance"], height.inputs[2])
    hf = N.new("ShaderNodeMath"); hf.operation = "MULTIPLY"
    L.new(height.outputs[0], hf.inputs[0]); L.new(furA.outputs["Fac"], hf.inputs[1])
    bump = N.new("ShaderNodeBump"); bump.inputs["Strength"].default_value = sp.get("bump", 0.55)
    bump.inputs["Distance"].default_value = 0.004
    L.new(hf.outputs[0], bump.inputs["Height"]); L.new(bump.outputs["Normal"], b.inputs["Normal"])
    # colour: dark roots / light tips from the same strand signal, only where furred
    ramp = N.new("ShaderNodeMapRange")
    L.new(mixh.outputs[0], ramp.inputs["Value"])
    ramp.inputs["From Min"].default_value = 0.3; ramp.inputs["From Max"].default_value = 0.75
    ramp.inputs["To Min"].default_value = 1.0 - sp.get("strand_contrast", 0.45)
    ramp.inputs["To Max"].default_value = 1.0 + sp.get("strand_contrast", 0.45) * 0.5
    blendf = N.new("ShaderNodeMix"); blendf.data_type = "FLOAT"
    L.new(furA.outputs["Fac"], blendf.inputs["Factor"])
    blendf.inputs[2].default_value = 1.0
    L.new(ramp.outputs["Result"], blendf.inputs[3])
    mulc = N.new("ShaderNodeMix"); mulc.data_type = "RGBA"; mulc.blend_type = "MULTIPLY"
    mulc.inputs["Factor"].default_value = 1.0
    L.new(coat.outputs["Color"], mulc.inputs[6])
    comb = N.new("ShaderNodeCombineColor")
    for i in range(3):
        L.new(blendf.outputs[0], comb.inputs[i])
    L.new(comb.outputs["Color"], mulc.inputs[7])
    L.new(mulc.outputs[2], b.inputs["Base Color"])
    L.new(roughA.outputs["Fac"], b.inputs["Roughness"])
    return m


def new_image(name, size, data=False, alpha=False):
    img = bpy.data.images.new(name, size, size, alpha=alpha, float_buffer=False)
    if data:
        img.colorspace_settings.name = "Non-Color"
    return img


def bake_maps(obj, sp, out_dir, size=2048):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 16
    activate(obj)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.006, area_weight=0.0)
    bpy.ops.object.mode_set(mode="OBJECT")
    mat = bake_material(sp)
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage")
    nt.nodes.active = tex
    nm = sp["name"]
    imgs = {}
    for kind, data in (("albedo", False), ("normal", True), ("rough", True), ("ao", True)):
        img = new_image(f"T_{nm}_{kind}", size if kind != "ao" else size // 2, data)
        tex.image = img
        if kind == "albedo":
            bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, margin=12, use_clear=True)
        elif kind == "normal":
            bpy.ops.object.bake(type="NORMAL", normal_space="TANGENT", margin=12, use_clear=True)
        elif kind == "rough":
            bpy.ops.object.bake(type="ROUGHNESS", margin=12, use_clear=True)
        else:
            sc.cycles.samples = 64
            bpy.ops.object.bake(type="AO", margin=12, use_clear=True)
        imgs[kind] = img
    # albedo × softened AO (cavities, belly shadow) — baked in so it reads in any lighting
    ao = np.array(imgs["ao"].pixels[:]).reshape(size // 2, size // 2, 4)[..., 0]
    ao = np.kron(ao, np.ones((2, 2)))
    al = np.array(imgs["albedo"].pixels[:]).reshape(size, size, 4)
    k = sp.get("ao_strength", 0.55)
    al[..., :3] *= (1 - k + k * ao)[..., None]
    imgs["albedo"].pixels[:] = al.ravel()
    paths = {}
    tdir = os.path.join(out_dir, "textures")
    os.makedirs(tdir, exist_ok=True)
    for kind in ("albedo", "normal", "rough"):
        img = imgs[kind]
        p = os.path.join(tdir, f"T_{nm}_{kind}.png")
        img.filepath_raw = p
        img.file_format = "PNG"
        img.save()
        paths[kind] = p
    # final PBR material reading the baked maps
    fm = bpy.data.materials.new(f"M_{nm}_Coat")
    fm.use_nodes = True
    N, L = fm.node_tree.nodes, fm.node_tree.links
    b = N["Principled BSDF"]
    ta = N.new("ShaderNodeTexImage"); ta.image = bpy.data.images.load(paths["albedo"])
    tn = N.new("ShaderNodeTexImage"); tn.image = bpy.data.images.load(paths["normal"]); tn.image.colorspace_settings.name = "Non-Color"
    tr = N.new("ShaderNodeTexImage"); tr.image = bpy.data.images.load(paths["rough"]); tr.image.colorspace_settings.name = "Non-Color"
    nmn = N.new("ShaderNodeNormalMap")
    L.new(ta.outputs["Color"], b.inputs["Base Color"])
    L.new(tn.outputs["Color"], nmn.inputs["Color"]); L.new(nmn.outputs["Normal"], b.inputs["Normal"])
    L.new(tr.outputs["Color"], b.inputs["Roughness"])
    b.inputs["Specular IOR Level"].default_value = 0.35
    obj.data.materials.clear()
    obj.data.materials.append(fm)
    for nmattr in ("fur", "rough", "legw"):
        obj.data.attributes.remove(obj.data.attributes[nmattr])
    obj.data.color_attributes.remove(obj.data.color_attributes["Coat"])
    return paths


# ============================================================== fur cards

def strand_atlas(sp, out_dir, w=1024, h=1024):
    """4 columns of hair strands (RGBA, roots at v=0) tinted with the species hair palette."""
    rng = np.random.default_rng(abs(hash(sp["name"])) % 2**32)
    img = np.zeros((h, w, 4), dtype=np.float32)
    cw = w // 4
    pal = [np.array(c, dtype=float) for c in sp["hair_palette"]]  # byte image: sRGB values
    rows = np.arange(h)
    for c in range(4):
        for _ in range(sp.get("strands_per_card", 150)):
            x0 = c * cw + rng.uniform(6, cw - 6)
            L = int(h * rng.uniform(0.6, 1.0))
            w0 = rng.uniform(1.6, 3.4)
            bend = rng.uniform(-0.06, 0.06) * cw
            wav = rng.uniform(0, 3)
            ys = rows[:L]
            t = ys / L
            xc = x0 + bend * t * t + wav * np.sin(t * rng.uniform(4, 9))
            wd = w0 * (1 - 0.8 * t)
            bright = rng.uniform(0.7, 1.25)
            colr = pal[c] * bright
            shade = (0.6 + 0.5 * t)[:, None] * colr[None, :]
            fade = 1 - t ** 3
            for dx in range(-4, 5):
                xs = np.clip(np.round(xc).astype(int) + dx, c * cw, c * cw + cw - 1)
                cov = np.clip(wd - np.abs(xs - xc) + 0.5, 0, 1) * fade
                old = img[ys, xs, 3]
                upd = cov > old * 0.6
                a = np.maximum(old, cov)
                img[ys[upd], xs[upd], :3] = shade[upd] * cov[upd, None] + img[ys[upd], xs[upd], :3] * (1 - cov[upd, None])
                img[ys, xs, 3] = a
    # bleed colour into transparent texels so mip/filtering doesn't darken edges
    alpha = img[..., 3:4]
    avg = img[..., :3].sum((0, 1)) / max(alpha.sum(), 1)
    img[..., :3] = np.where(alpha > 0.02, img[..., :3], np.mean(np.stack(pal), 0) * 0.8)
    im = bpy.data.images.new(f"T_{sp['name']}_fur", w, h, alpha=True)
    im.pixels[:] = img.ravel()
    p = os.path.join(out_dir, "textures", f"T_{sp['name']}_fur.png")
    im.filepath_raw = p
    im.file_format = "PNG"
    im.save()
    return p


def fur_material(sp, path):
    m = bpy.data.materials.new(f"M_{sp['name']}_Fur")
    m.use_nodes = True
    m.use_backface_culling = False
    N, L = m.node_tree.nodes, m.node_tree.links
    b = N["Principled BSDF"]
    t = N.new("ShaderNodeTexImage"); t.image = bpy.data.images.load(path)
    L.new(t.outputs["Color"], b.inputs["Base Color"])
    rnd = N.new("ShaderNodeMath"); rnd.operation = "ROUND"  # → glTF alphaMode MASK
    L.new(t.outputs["Alpha"], rnd.inputs[0])
    L.new(rnd.outputs[0], b.inputs["Alpha"])
    b.inputs["Roughness"].default_value = 0.8
    b.inputs["Specular IOR Level"].default_value = 0.3
    return m


def build_cards(body, sp, which, names, out_dir):
    """Hair cards rooted on the body surface. Returns (object, per-card root (tri verts, bary))."""
    hair = sp["hair"]
    me = body.data
    me.calc_loop_triangles()
    P, N = mesh_arrays(body)
    tris = np.zeros(len(me.loop_triangles) * 3, dtype=np.int64)
    me.loop_triangles.foreach_get("vertices", tris)
    tris = tris.reshape(-1, 3)
    # per-vertex hair spec
    lens = np.zeros(len(P))
    for i in range(len(P)):
        lens[i] = hair(P[i], N[i], names[which[i]])[0]
    a, b, c = P[tris[:, 0]], P[tris[:, 1]], P[tris[:, 2]]
    area = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    tl = lens[tris].mean(1)
    rng = np.random.default_rng(7)
    expect = area * sp["card_density"] * (tl > 0.01)
    cnt = rng.poisson(expect)
    roots = []
    for ti in np.nonzero(cnt)[0]:
        for _ in range(cnt[ti]):
            u, v = rng.random(), rng.random()
            if u + v > 1:
                u, v = 1 - u, 1 - v
            roots.append((ti, np.array([1 - u - v, u, v])))
    verts, faces, uvs = [], [], []
    root_info = []
    up = np.array([0, 0, 1.0])
    for ti, bc in roots:
        tv = tris[ti]
        p = bc @ P[tv]
        n = bc @ N[tv]
        n /= np.linalg.norm(n)
        vi = tv[np.argmax(bc)]
        L, lift, droop, width, flow = hair(p, n, names[which[vi]])
        if L < 0.01:
            continue
        S = 2 if L < 0.07 else 3
        L *= rng.uniform(0.7, 1.2)
        flow = np.array(flow, float)
        f = flow - n * (flow @ n)
        if np.linalg.norm(f) < 1e-3:
            f = np.array([0, -1.0, 0]) - n * (-n[1])
        f /= np.linalg.norm(f)
        d0 = f * (1 - lift) + n * lift
        d0 /= np.linalg.norm(d0)
        side = np.cross(n, d0)
        if np.linalg.norm(side) < 1e-3:
            side = np.cross(up, d0)
        side /= np.linalg.norm(side)
        ang = rng.uniform(-0.35, 0.35)
        side = side * math.cos(ang) + n * math.sin(ang)
        wd = width * rng.uniform(0.8, 1.25)
        rgb = np.array(sp["coat"](p, n, names[which[vi]])[0])
        dist = [np.linalg.norm(rgb - np.array(c)) for c in sp["hair_palette"]]
        col = int(np.argmin(dist)) if rng.random() > 0.2 else int(np.argsort(dist)[1])
        u0, u1 = col / 4 + 0.004, (col + 1) / 4 - 0.004
        if rng.random() < 0.5:
            u0, u1 = u1, u0
        base = len(verts)
        q = p - n * 0.15 * wd
        d = d0
        for i in range(S + 1):
            if i > 0:
                d = d0 + np.array([0, 0, -1.0]) * droop * (i / S)
                d /= np.linalg.norm(d)
                q = q + d * L / S
            verts += [q - side * wd / 2, q + side * wd / 2]
            uvs += [(u0, i / S), (u1, i / S)]
        # wind each card so its front face looks away from the body (lighting/backface rules)
        e1 = verts[base + 1] - verts[base]
        e2 = verts[base + 2] - verts[base]
        outward = np.dot(np.cross(e1, e2), n) > 0
        for i in range(S):
            k = base + i * 2
            faces.append((k, k + 1, k + 3, k + 2) if outward else (k, k + 2, k + 3, k + 1))
        root_info.append((tv, bc, base, 2 * (S + 1)))
    me2 = bpy.data.meshes.new(sp["name"] + "Fur")
    me2.from_pydata([tuple(v) for v in verts], [], faces)
    uvl = me2.uv_layers.new(name="UVMap")
    for poly in me2.polygons:
        for li in poly.loop_indices:
            uvl.data[li].uv = uvs[me2.loops[li].vertex_index]
    me2.update()
    obj = bpy.data.objects.new(sp["name"] + "Fur", me2)
    bpy.context.scene.collection.objects.link(obj)
    for poly in obj.data.polygons:
        poly.use_smooth = True
    obj.data.materials.append(fur_material(sp, strand_atlas(sp, out_dir)))
    return obj, root_info


def card_normals_from_body(cards, root_info, body):
    """Shade cards with the body's normal at their root (soft, volumetric fur lighting)."""
    P, N = mesh_arrays(body)
    me = cards.data
    nrm = np.zeros((len(me.vertices), 3))
    for tv, bc, base, cnt in root_info:
        n = bc @ N[tv]
        nrm[base:base + cnt] = n / np.linalg.norm(n)
    loops = np.zeros(len(me.loops), dtype=np.int64)
    me.loops.foreach_get("vertex_index", loops)
    me.normals_split_custom_set([tuple(nrm[i]) for i in loops])


def transfer_card_weights(cards, root_info, body):
    vg_names = [g.name for g in body.vertex_groups]
    nv = len(body.data.vertices)
    W = np.zeros((nv, len(vg_names)))
    for v in body.data.vertices:
        for g in v.groups:
            W[v.index, g.group] = g.weight
    groups = {n: cards.vertex_groups.new(name=n) for n in vg_names}
    for tv, bc, base, cnt in root_info:
        w = bc @ W[tv]
        top = np.argsort(w)[::-1][:4]
        s = w[top].sum()
        if s <= 0:
            continue
        ids = list(range(base, base + cnt))
        for gi in top:
            if w[gi] > 0.01:
                groups[vg_names[gi]].add(ids, float(w[gi] / s), "REPLACE")


def rigid_to_bone(obj, bone):
    g = obj.vertex_groups.new(name=bone)
    g.add(list(range(len(obj.data.vertices))), 1.0, "REPLACE")


def join_into(target, objs):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    target.select_set(True)
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.join()


# ============================================================== animation

def key(rig, frame, rots, loc=None):
    for bone, (x, y, z) in rots.items():
        if bone not in rig.pose.bones:
            continue
        pb = rig.pose.bones[bone]
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = (math.radians(x), math.radians(y), math.radians(z))
        pb.keyframe_insert("rotation_euler", frame=frame)
    if loc is not None:
        pb = rig.pose.bones["hips"]
        pb.location = loc
        pb.keyframe_insert("location", frame=frame)


def zero_pose(rig):
    return {b.name: (0, 0, 0) for b in rig.pose.bones}


def smooth01(x):
    x = min(max(x, 0.0), 1.0)
    return x * x * (3 - 2 * x)


def leg_cycle(u, duty, amp, lift):
    """u: phase 0..1 of this leg. Returns (swing angle deg, flex 0..1)."""
    if u < duty:  # stance: hoof planted, leg sweeps back
        s = u / duty
        return amp * (1 - 2 * s), 0.0
    s = (u - duty) / (1 - duty)  # swing: lift and bring forward
    return amp * (-1 + 2 * smooth01(s)), math.sin(math.pi * s) * lift


def gait(rig, sp, g):
    """g: period, duty, amp, lift (deg), phases {leg: offset}, bob, spine, head, tail."""
    n = max(8, int(round(g["period"] * FPS)))
    for f in range(n + 1):
        t = f / n
        r = zero_pose(rig)
        for s in ("L", "R"):
            for leg in ("f", "h"):
                u = (t + g["phases"][f"{leg}{s}"]) % 1.0
                ang, flex = leg_cycle(u, g["duty"], g["amp_" + leg], 1.0)
                L = g["lift"] * flex
                if leg == "f":
                    r[f"upperarm.{s}"] = (ang, 0, 0)
                    r[f"forearm.{s}"] = (-0.35 * L - 0.25 * ang, 0, 0)
                    r[f"hoof_f.{s}"] = (-1.0 * L, 0, 0)
                else:
                    r[f"thigh.{s}"] = (ang, 0, 0)
                    r[f"shin.{s}"] = (-0.75 * L, 0, 0)
                    r[f"hoof_h.{s}"] = (0.9 * L, 0, 0)
        w = t * math.tau
        r["spine"] = (g.get("spine", 0) * math.sin(w), 0, g.get("yaw", 0) * math.sin(w))
        r["chest"] = (-g.get("spine", 0) * 0.6 * math.sin(w), 0, -g.get("yaw", 0) * math.sin(w))
        r["neck"] = (g.get("head", 0) * math.sin(2 * w + 0.6), 0, 0)
        r["head"] = (-g.get("head", 0) * 0.6 * math.sin(2 * w + 0.6), 0, 0)
        r["tail"] = (g.get("tail", 4) * math.sin(2 * w), 0, g.get("tail", 4) * math.sin(w))
        r["tail_tip"] = (0, 0, g.get("tail", 4) * 1.4 * math.sin(w - 0.8))
        sp.get("gait_extra", lambda r, t, g: None)(r, t, g)
        bob = g["bob"] * (0.5 + 0.5 * math.cos(w * g.get("bob_freq", 2)))
        key(rig, f + 1, r, (0, 0, -bob))
    return n


def make_clips(rig, sp):
    rig.animation_data_create()
    clips = sp["clips"](rig)
    for name, fn in clips.items():
        act = bpy.data.actions.new(name)
        rig.animation_data.action = act
        for pb in rig.pose.bones:
            pb.rotation_mode = "XYZ"
            pb.rotation_euler = (0, 0, 0)
            pb.location = (0, 0, 0)
        frames = fn()
        track = rig.animation_data.nla_tracks.new()
        track.name = name
        strip = track.strips.new(name, 1, act)
        strip.action_frame_end = frames + 1
        rig.animation_data.action = None
    return list(clips.keys())


def loop_clip(rig, seconds, step, fn):
    n = int(seconds * FPS)
    for f in list(range(0, n, step)) + [n]:
        r = zero_pose(rig)
        loc = fn(r, f / n)
        key(rig, f + 1, r, loc if loc is not None else (0, 0, 0))
    return n


# ===================================================================== shared clips

def std_clips(rig, sp, walk, run, extra=None):
    J = sp["J"]
    height = J["spine"][2]

    def idle():
        def f(r, t):
            w = t * math.tau
            r["chest"] = (1.0 * math.sin(w * 2), 0, 0)
            r["neck"] = (3 * math.sin(w), 0, 4 * math.sin(w + 1))
            r["head"] = (2 * math.sin(w * 2), 0, 8 * math.sin(w + 0.5))
            r["ear.L"] = (0, 0, 12 * max(0, math.sin(w * 3)) ** 4)
            r["ear.R"] = (0, 0, -10 * max(0, math.sin(w * 2 + 2)) ** 4)
            r["tail"] = (0, 0, 6 * math.sin(w * 2))
            r["tail_tip"] = (0, 0, 8 * math.sin(w * 2 - 0.7))
            sp.get("idle_extra", lambda r, t: None)(r, t)
        return loop_clip(rig, 4.0, 2, f)

    def graze():
        g = sp.get("graze_pose", {"neck": -48, "neck2": -22, "head": -14})

        def f(r, t):
            w = t * math.tau
            r["neck"] = (g["neck"], 0, 3 * math.sin(w))
            r["neck2"] = (g["neck2"] + 5 * math.sin(w * 3), 0, 0)
            r["head"] = (g["head"], 0, 6 * math.sin(w * 2))
            for s in ("L", "R"):
                r[f"upperarm.{s}"] = (g.get("arm", 6), 0, 0)
            r["tail"] = (0, 0, 6 * math.sin(w * 2))
            sp.get("graze_extra", lambda r, t: None)(r, t)
            return (0, 0, -g.get("drop", 0.02))
        return loop_clip(rig, 3.0, 2, f)

    def alert():
        def f(r, t):
            w = t * math.tau
            r["neck"] = (14, 0, 0)
            r["head"] = (6, 0, 14 * math.sin(w))
            r["ear.L"] = (18, 0, -12)
            r["ear.R"] = (18, 0, 12)
            r["tail"] = (sp.get("alert_tail", 20), 0, 0)
            return (0, 0, 0.015)
        return loop_clip(rig, 2.0, 2, f)

    def attack():
        return sp["attack"](rig)

    def death():
        n = int(1.4 * FPS)
        for f in range(n + 1):
            t = min(f / n / 0.8, 1.0)
            e = t * t * (3 - 2 * t)
            r = zero_pose(rig)
            r["hips"] = (0, 86 * e, 0)
            r["neck"] = (-20 * e, 0, 0)
            r["head"] = (-15 * e, 0, 0)
            for s in ("L", "R"):
                r[f"upperarm.{s}"] = (20 * e, 0, 0)
                r[f"thigh.{s}"] = (-18 * e, 0, 0)
                r[f"forearm.{s}"] = (-25 * e, 0, 0)
            r["tail"] = (-20 * e, 0, 0)
            key(rig, f + 1, r, (0, 0, -height * 0.70 * e))
        return n

    clips = {"idle": idle, "walk": lambda: gait(rig, sp, walk), "run": lambda: gait(rig, sp, run),
             "graze": graze, "alert": alert, "attack": attack, "death": death}
    clips.update(extra or {})
    return clips


def bite_attack(rig, sp, lunge_m=0.25):
    n = int(0.9 * FPS)
    for f in range(n + 1):
        t = f / n
        k = math.sin(min(t / 0.45, 1.0) * math.pi) if t < 0.45 else max(0.0, 1 - (t - 0.45) / 0.55) * 0.2
        r = zero_pose(rig)
        r["chest"] = (-8 * k, 0, 0)
        r["neck"] = (-10 * k, 0, 0)
        r["head"] = (16 * k, 0, 0)
        r["snout"] = (-12 * k, 0, 0)
        r["ear.L"] = (-25 * k, 0, 0)
        r["ear.R"] = (-25 * k, 0, 0)
        for s in ("L", "R"):
            r[f"upperarm.{s}"] = (-28 * k, 0, 0)
            r[f"thigh.{s}"] = (22 * k, 0, 0)
        key(rig, f + 1, r, (0, lunge_m * k, 0.06 * k))
    return n



# ============================================================== export

def export(body, rig, path):
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    rig.select_set(True)
    for o in bpy.context.scene.objects:
        if o.parent == rig:
            o.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="textures",
                              use_selection=True, export_yup=True, export_animations=True,
                              export_animation_mode="NLA_TRACKS", export_skins=True,
                              export_image_format="AUTO")
