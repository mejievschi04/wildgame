# Procedural item models + rendered inventory icons, from CC0 scanned textures.
#   blender -b --python tools/blender/gen_items.py [-- item_id ...]
# Output: assets/models/items/SM_Item_<id>.gltf  and  assets/icons/T_Icon_<id>.png
# Convention (Blender Z-up): handheld tools point along +Z with the grip at the origin.
import bpy, bmesh, math, os, random, sys
from mathutils import Vector, Matrix, Euler

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC_TEX = os.path.join(ROOT, "art_source", "textures")
OUT_MODELS = os.path.join(ROOT, "assets", "models", "items")
OUT_ICONS = os.path.join(ROOT, "assets", "icons")
os.makedirs(OUT_MODELS, exist_ok=True)
os.makedirs(OUT_ICONS, exist_ok=True)

_mats = {}


def tex_path(name, kind):
    d = os.path.join(SRC_TEX, name)
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f"_{kind}_" in f:
                return os.path.join(d, f)
        return None
    # No raw Poly Haven downloads (art_source/ is git-ignored): reuse the copies already exported next to the items.
    d = os.path.join(OUT_MODELS, "textures")
    for f in sorted(os.listdir(d)):
        if f.startswith(name + "_") and f"_{kind}_" in f and not f.endswith(".import"):
            return os.path.join(d, f)
    return None


def pbr(key, tex=None, tint=(1, 1, 1, 1), rough=0.8, color=None, uv_scale=1.0):
    """Principled material. tex = Poly Haven texture id (diff/nor_gl/arm used); color = flat base colour."""
    k = (key, tex, tuple(tint), rough, tuple(color) if color else None, uv_scale)
    if k in _mats:
        return _mats[k]
    m = bpy.data.materials.new(key)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Roughness"].default_value = rough
    if tex:
        mapping = None
        if uv_scale != 1.0:
            tc = nt.nodes.new("ShaderNodeTexCoord")
            mapping = nt.nodes.new("ShaderNodeMapping")
            mapping.inputs["Scale"].default_value = (uv_scale, uv_scale, 1)
            nt.links.new(tc.outputs["UV"], mapping.inputs["Vector"])
        d = nt.nodes.new("ShaderNodeTexImage"); d.image = bpy.data.images.load(tex_path(tex, "diff"), check_existing=True)
        if tint != (1, 1, 1, 1):
            mul = nt.nodes.new("ShaderNodeMix"); mul.data_type = "RGBA"; mul.blend_type = "MULTIPLY"
            mul.inputs["Factor"].default_value = 1.0
            nt.links.new(d.outputs["Color"], mul.inputs["A"]); mul.inputs["B"].default_value = tint
            nt.links.new(mul.outputs["Result"], b.inputs["Base Color"])
        else:
            nt.links.new(d.outputs["Color"], b.inputs["Base Color"])
        npath = tex_path(tex, "nor_gl")
        if npath:
            n = nt.nodes.new("ShaderNodeTexImage"); n.image = bpy.data.images.load(npath, check_existing=True)
            n.image.colorspace_settings.name = "Non-Color"
            nm = nt.nodes.new("ShaderNodeNormalMap")
            nt.links.new(n.outputs["Color"], nm.inputs["Color"]); nt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
        apath = tex_path(tex, "arm")
        if apath:
            a = nt.nodes.new("ShaderNodeTexImage"); a.image = bpy.data.images.load(apath, check_existing=True)
            a.image.colorspace_settings.name = "Non-Color"
            sep = nt.nodes.new("ShaderNodeSeparateColor")
            nt.links.new(a.outputs["Color"], sep.inputs["Color"]); nt.links.new(sep.outputs["Green"], b.inputs["Roughness"])
        if mapping:
            for node in nt.nodes:
                if node.type == "TEX_IMAGE":
                    nt.links.new(mapping.outputs["Vector"], node.inputs["Vector"])
    else:
        b.inputs["Base Color"].default_value = color or tint
    _mats[k] = m
    return m


WOOD = lambda: pbr("M_Willow", "bark_willow_02", (1.1, 1.0, 0.9, 1))
BARK = lambda: pbr("M_PineBark", "knotted_pine_bark")
CUTWOOD = lambda: pbr("M_CutWood", "rough_wood", (1.0, 0.85, 0.65, 1))
FLINT = lambda: pbr("M_Flint", "dark_rock_02", (0.75, 0.75, 0.8, 1), 0.45)
STONE = lambda: pbr("M_Stone", "lichen_rock")
LEATHER = lambda: pbr("M_Leather", "brown_leather", uv_scale=3.0)
THATCH = lambda: pbr("M_Thatch", "thatch_roof_angled")
FIBER = lambda: pbr("M_Fiber", "thatch_roof_angled", (0.75, 0.85, 0.5, 1))


def flat(name, rgb, rough=0.6):
    return pbr(name, None, rough=rough, color=(*rgb, 1))


# ---------------------------------------------------------------- mesh helpers

def new_obj(name, bm, mat):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me); bm.free()
    me.materials.append(mat)
    o = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(o)
    for p in me.polygons:
        p.use_smooth = True
    return o


def tube(path, radii, mat, seg=8, u_rep=1.0, v_scale=2.0, cap=True):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new("UVMap")
    rings = []
    acc = 0.0
    for i, p in enumerate(path):
        if i:
            acc += (path[i] - path[i - 1]).length
        t = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
        ref = Vector((1, 0, 0)) if abs(t.x) < 0.9 else Vector((0, 1, 0))
        s = (ref - t * ref.dot(t)).normalized(); u = t.cross(s)
        rings.append([(bm.verts.new(p + (s * math.cos(2 * math.pi * k / seg) + u * math.sin(2 * math.pi * k / seg)) * radii[i]),
                        k / seg * u_rep, acc * v_scale) for k in range(seg + 1)])
    for i in range(len(rings) - 1):
        for k in range(seg):
            q = [rings[i][k], rings[i][k + 1], rings[i + 1][k + 1], rings[i + 1][k]]
            f = bm.faces.new([v[0] for v in q])
            for l, v in zip(f.loops, q):
                l[uv].uv = (v[1], v[2])
    if cap:
        for ring in (rings[0], rings[-1]):
            vs = [v[0] for v in ring[:-1]]
            f = bm.faces.new(vs if ring is rings[-1] else list(reversed(vs)))
            for l in f.loops:
                l[uv].uv = (0.5 + (l.vert.co - vs[0].co).x * 0.5, 0.5 + (l.vert.co - vs[0].co).y * 0.5)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)
    return new_obj("tube", bm, mat)


def bent(a, b, n, bend, rng=None):
    pts = []
    for i in range(n + 1):
        t = i / n
        p = a.lerp(b, t)
        p += Vector((math.sin(t * math.pi) * bend, 0, 0))
        if rng:
            p += Vector((rng.uniform(-0.004, 0.004), rng.uniform(-0.004, 0.004), 0))
        pts.append(p)
    return pts


def hull(points, mat, uv_size=0.15):
    """Convex hull of points → faceted knapped-stone look. Box-projected UVs."""
    bm = bmesh.new()
    for p in points:
        bm.verts.new(p)
    bmesh.ops.convex_hull(bm, input=bm.verts)
    uv = bm.loops.layers.uv.new("UVMap")
    for f in bm.faces:
        n = f.normal
        ax = max(range(3), key=lambda i: abs(n[i]))
        for l in f.loops:
            c = l.vert.co
            l[uv].uv = ((c.y, c.z), (c.x, c.z), (c.x, c.y))[ax]
            l[uv].uv = (l[uv].uv[0] / uv_size, l[uv].uv[1] / uv_size)
    o = new_obj("hull", bm, mat)
    for p in o.data.polygons:
        p.use_smooth = False
    return o


def blob(center, radii, n, rng, jitter=0.25, squash=None):
    pts = []
    for _ in range(n):
        d = Vector((rng.gauss(0, 1), rng.gauss(0, 1), rng.gauss(0, 1))).normalized()
        r = 1.0 + rng.uniform(-jitter, jitter)
        p = Vector((d.x * radii[0], d.y * radii[1], d.z * radii[2])) * r
        if squash:
            p = squash(p)
        pts.append(center + p)
    return pts


def uv_sphere(r, loc, scale, mat, segs=16, rings=10):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=rings, radius=r, calc_uvs=True)
    bmesh.ops.scale(bm, vec=scale, verts=bm.verts)
    bmesh.ops.translate(bm, vec=loc, verts=bm.verts)
    return new_obj("sphere", bm, mat)


def import_asset(rel, scale=1.0):
    bpy.ops.import_scene.gltf(filepath=os.path.join(ROOT, rel))
    objs = [o for o in bpy.context.selected_objects if o.type == "MESH"]
    for o in objs:
        o.scale = (scale,) * 3
    return objs


# ---------------------------------------------------------------- item builders (return list of objects)

def b_stone(rng):
    return import_asset("assets/models/rocks/SM_Stone_01.gltf", 1.3)


def b_flint(rng):
    return [hull(blob(Vector((0, 0, 0.03)), (0.05, 0.035, 0.03), 40, rng), FLINT())]


def b_stick(rng):
    return [tube(bent(Vector((0, 0, 0)), Vector((0, 0, 0.9)), 8, 0.03, rng), [0.018 - 0.006 * i / 8 for i in range(9)], WOOD())]


def b_wood(rng):
    o = tube([Vector((0, 0, 0)), Vector((0, 0, 0.45))], [0.09, 0.085], BARK(), seg=12, u_rep=2.0, v_scale=2.0)
    o.rotation_euler = (math.radians(90), 0, 0)
    o.location.z = 0.09
    return [o]


def b_fiber(rng):
    out = []
    for i in range(26):
        a = rng.uniform(0, math.tau); r = rng.uniform(0, 0.025)
        base = Vector((math.cos(a) * r, math.sin(a) * r, 0))
        out.append(tube(bent(base, base + Vector((rng.uniform(-0.03, 0.03), rng.uniform(-0.03, 0.03), 0.42)), 4, rng.uniform(-0.02, 0.02)),
                        [0.0025] * 5, FIBER(), seg=4, cap=False))
    out.append(tube([Vector((0, 0, 0.18)), Vector((0, 0, 0.21))], [0.034, 0.034], LEATHER(), seg=10))
    return out


def b_hide(rng):
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=16, y_segments=12, size=0.3, calc_uvs=True)
    for v in bm.verts:
        v.co.x *= 1.25
        v.co.z = 0.02 * math.sin(v.co.x * 9) + 0.015 * math.cos(v.co.y * 13) + rng.uniform(0, 0.006)
        if abs(v.co.x) > 0.3 or abs(v.co.y) > 0.25:
            v.co.x *= 0.92; v.co.y *= 0.92
    o = new_obj("hide", bm, pbr("M_Hide", "brown_leather", (1.0, 0.8, 0.62, 1), uv_scale=2.0))
    return [o]


def b_bone(rng):
    mat = flat("M_Bone", (0.86, 0.82, 0.72), 0.5)
    return [tube([Vector((0, 0, 0.03)), Vector((0, 0, 0.3))], [0.012, 0.01], mat, seg=8),
            uv_sphere(0.022, Vector((0.008, 0, 0.03)), (1, 0.8, 0.8), mat), uv_sphere(0.022, Vector((-0.008, 0, 0.03)), (1, 0.8, 0.8), mat),
            uv_sphere(0.02, Vector((0.007, 0, 0.3)), (1, 0.8, 0.8), mat), uv_sphere(0.02, Vector((-0.007, 0, 0.3)), (1, 0.8, 0.8), mat)]


def b_berries(rng):
    mat = flat("M_Berry", (0.13, 0.015, 0.06), 0.25)
    out = [uv_sphere(0.011, Vector((rng.uniform(-0.03, 0.03), rng.uniform(-0.03, 0.03), 0.011 + rng.uniform(0, 0.02))), (1, 1, 1), mat, 10, 6) for _ in range(12)]
    leaf = flat("M_Leaf", (0.2, 0.32, 0.12), 0.7)
    out.append(uv_sphere(0.03, Vector((0.02, 0.0, 0.004)), (1.6, 0.6, 0.08), leaf, 10, 6))
    return out


def _mushroom(cap_rgb, stem_rgb):
    cap = uv_sphere(0.045, Vector((0, 0, 0.07)), (1, 1, 0.55), flat("M_Cap" + str(cap_rgb), cap_rgb, 0.55))
    stem = tube([Vector((0, 0, 0)), Vector((0, 0, 0.07))], [0.014, 0.011], flat("M_Stem" + str(stem_rgb), stem_rgb, 0.7), seg=10)
    return [cap, stem]


def b_mushroom(rng):
    return _mushroom((0.5, 0.33, 0.18), (0.86, 0.82, 0.72))


def b_mushroom_cooked(rng):
    return _mushroom((0.25, 0.15, 0.08), (0.5, 0.4, 0.28))


def _meat(rng, rgb, thick, rough):
    o = hull(blob(Vector((0, 0, thick)), (0.09, 0.06, thick), 90, rng, 0.12), pbr("M_Meat" + str(rgb), "brown_leather", (*rgb, 1), rough, uv_scale=2.5), 0.08)
    for p in o.data.polygons:
        p.use_smooth = True
    return [o]


def b_meat_raw(rng):
    return _meat(rng, (1.6, 0.35, 0.3), 0.025, 0.35)


def b_meat_cooked(rng):
    return _meat(rng, (0.75, 0.42, 0.22), 0.025, 0.6)


def b_meat_dried(rng):
    return [hull(blob(Vector((0, i * 0.025 - 0.025, 0.006)), (0.1, 0.011, 0.005), 18, rng, 0.2),
                 pbr("M_Jerky", "brown_leather", (0.6, 0.3, 0.2, 1), 0.75, uv_scale=3.0), 0.1) for i in range(3)]


def _skin(rng, full):
    s = 1.0 if full else 0.8
    bag = uv_sphere(0.1, Vector((0, 0, 0.1 * s)), (1.0, 0.7, 1.15 * s), LEATHER(), 20, 12)
    neck = tube([Vector((0, 0, 0.2 * s)), Vector((0, 0, 0.27 * s))], [0.03, 0.025], LEATHER(), seg=12)
    cord = tube([Vector((0, 0, 0.235 * s)), Vector((0, 0, 0.245 * s))], [0.034, 0.034], flat("M_Cord", (0.35, 0.28, 0.18)), seg=12)
    return [bag, neck, cord]


def b_waterskin_empty(rng):
    return _skin(rng, False)


def b_waterskin_raw(rng):
    return _skin(rng, True)


def b_waterskin_boiled(rng):
    return _skin(rng, True)


def b_bandage(rng):
    o = tube([Vector((0, 0, 0)), Vector((0, 0, 0.09))], [0.035, 0.035], flat("M_BandageFiber", (0.78, 0.72, 0.58), 0.9), seg=16, u_rep=2)
    o.rotation_euler = (math.radians(90), 0, 0); o.location.z = 0.035
    return [o]


SOURCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "source")


def import_sketchfab(fname, tex_prefix, keep=lambda o: True):
    """Imports a downloaded .glb, bakes its parent hierarchy into the meshes and drops everything else
    (Sketchfab exports carry fbx root empties, a camera and a sun). Images get stable, unique names so the
    exported textures don't collide with other items in assets/models/items/textures/."""
    before = set(bpy.data.images)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SOURCE, fname))
    bpy.context.view_layer.update()
    meshes = [o for o in bpy.data.objects if o.type == "MESH" and keep(o)]
    for o in meshes:
        mw = o.matrix_world.copy()
        o.parent = None
        o.rotation_mode = "XYZ"  # glTF imports use quaternions; render_icon poses via rotation_euler
        o.matrix_world = mw
    for o in list(bpy.data.objects):
        if o not in meshes:
            bpy.data.objects.remove(o, do_unlink=True)
    for i, im in enumerate(im for im in bpy.data.images if im not in before):
        im.name = f"{tex_prefix}_{i}"
    return meshes


def place_along_z(objs, butt, tip, length, grip_from_butt):
    """Rotates/scales/moves objs so butt->tip runs along +Z, `length` metres long, with the grip point
    (`grip_from_butt` metres up from the butt) at the origin -- the item convention used by HandModels."""
    axis = (tip - butt)
    rot = axis.normalized().rotation_difference(Vector((0, 0, 1))).to_matrix().to_4x4()
    s = length / axis.length
    m = Matrix.Translation((0, 0, -grip_from_butt)) @ Matrix.Scale(s, 4) @ rot @ Matrix.Translation(-butt)
    for o in objs:
        o.matrix_world = m @ o.matrix_world


def decimate(obj, budget, weld=False):
    bpy.context.view_layer.objects.active = obj
    if weld:  # welding UV seams lets collapse go further but smears textures across seams
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-4 * max(obj.dimensions))
        bm.to_mesh(obj.data)
        bm.free()
    for _ in range(5):
        n = sum(len(p.vertices) - 2 for p in obj.data.polygons)
        if n <= budget * 1.1:
            break
        mod = obj.modifiers.new("dec", "DECIMATE")
        mod.ratio = max(budget / n, 0.002)
        mod.use_collapse_triangulate = True
        with bpy.context.temp_override(object=obj, active_object=obj):
            bpy.ops.object.modifier_apply(modifier=mod.name)


def world_bounds(objs):
    cs = [o.matrix_world @ v.co for o in objs for v in o.data.vertices]
    return (Vector((min(c.x for c in cs), min(c.y for c in cs), min(c.z for c in cs))),
            Vector((max(c.x for c in cs), max(c.y for c in cs), max(c.z for c in cs))))


def b_stone_axe(rng):
    # "Stone Axe" by Alex Martire (sketchfab.com/alexmartire), CC-BY-4.0 -- see CREDITS.md.
    # Source is Z-up after import, handle along -Z, cutting edge toward -X. Keep it there: the chop swing
    # (player.gd SWING_STYLES) strikes forward and to the left, so -X is the leading side of the head.
    # The handle ships twice (127k and 69k faces); the lighter copy has holes, so keep the full one.
    handles = []
    def keep(o):
        if "Cabo" in o.name:
            handles.append(o)
        return True
    parts = import_sketchfab("SK_StoneAxe_AlexMartire.glb", "T_AxeSK", keep)
    handles.sort(key=lambda o: -len(o.data.polygons))
    for extra in handles[1:]:
        parts.remove(extra)
        bpy.data.objects.remove(extra, do_unlink=True)
    # The source scales its roughness maps by 0.09-0.22 (reads as wet/varnished in Godot): let the maps drive it.
    for mat in bpy.data.materials:
        for link in (mat.node_tree.links if mat.node_tree else []):
            if link.to_socket.name == "Roughness" and link.from_node.type == "MATH":
                for inp in link.from_node.inputs:
                    if not inp.is_linked:
                        inp.default_value = 1.0
    budgets = {"Cabo": 2600, "Lamina": 2200, "Machado": 900}
    for o in parts:
        decimate(o, next((b for k, b in budgets.items() if k in o.name), 1500))
    hmn, hmx = world_bounds([handles[0]])
    mn, mx = world_bounds(parts)
    cx, cy = (hmn.x + hmx.x) / 2, (hmn.y + hmx.y) / 2
    # Same overall size and grip as the previous axe: 0.70 m long, held 0.20 m above the butt.
    place_along_z(parts, Vector((cx, cy, mn.z)), Vector((cx, cy, mx.z)), 0.70, 0.20)
    return parts


def b_spear(rng):
    # "Prehistoric Spear - Artifacts Low Poly" by jesusmolina (sketchfab.com/jesusmolina), CC-BY-4.0.
    # The source lies diagonally with the flint head toward -X: find the shaft axis from the head.
    parts = import_sketchfab("SK_PrehistoricSpear_JesusMolina.glb", "T_SpearSK")
    head = next(o for o in parts if any("FIshtail" in m.name for m in o.data.materials))
    hc = sum((head.matrix_world @ v.co for v in head.data.vertices), Vector()) / len(head.data.vertices)
    pts = [o.matrix_world @ v.co for o in parts for v in o.data.vertices]
    butt = max(pts, key=lambda p: (p - hc).length)
    d = (hc - butt).normalized()
    tip = max(pts, key=lambda p: (p - butt).dot(d))
    # Same length and grip as the previous spear: 1.91 m, held 0.60 m above the butt.
    place_along_z(parts, butt, butt + d * (tip - butt).dot(d), 1.91, 0.60)
    return parts


def b_club(rng):
    # "Neolithic Stone Club" by Asylum Nox (sketchfab.com/peter.pottiez), CC-BY-4.0.
    # Lies along +/-Y in the source; the head end is found as the thicker one.
    parts = import_sketchfab("SK_StoneClub_AsylumNox.glb", "T_ClubSK")
    # 2k maps are overkill for a hand weapon: downscale to 1k. Copy into fresh generated images so they export
    # as PNG -- a scaled packed JPEG is re-encoded as a JPEG that Godot's importer rejects.
    swap = {}
    for im in list(bpy.data.images):
        if im.name.startswith("T_ClubSK") and im.size[0] > 1024:
            im.scale(1024, 1024)
            fresh = bpy.data.images.new(im.name + "_1k", 1024, 1024, alpha=False)
            fresh.colorspace_settings.name = im.colorspace_settings.name
            fresh.pixels.foreach_set(im.pixels[:])
            fresh.file_format = "PNG"
            swap[im] = fresh
    for mat in bpy.data.materials:
        for node in (mat.node_tree.nodes if mat.node_tree else []):
            if node.type == "TEX_IMAGE" and node.image in swap:
                node.image = swap[node.image]
    # The source drives Metallic from a texture with no factor (glTF then defaults to fully metallic): stone and
    # wood aren't metal, and in Godot it mirrors the sky (the club rendered white).
    for mat in bpy.data.materials:
        bsdf = next((n for n in (mat.node_tree.nodes if mat.node_tree else []) if n.type == "BSDF_PRINCIPLED"), None)
        if bsdf:
            for link in list(bsdf.inputs["Metallic"].links):
                mat.node_tree.links.remove(link)
            bsdf.inputs["Metallic"].default_value = 0.0
    pts = [o.matrix_world @ v.co for o in parts for v in o.data.vertices]
    lo, hi = min(p.y for p in pts), max(p.y for p in pts)
    def spread(a, b):
        sel = [p for p in pts if a <= p.y <= b]
        return max(p.x for p in sel) - min(p.x for p in sel) + max(p.z for p in sel) - min(p.z for p in sel)
    seg = (hi - lo) * 0.12
    head_hi = spread(hi - seg, hi) > spread(lo, lo + seg)
    butt_y, tip_y = (lo, hi) if head_hi else (hi, lo)
    shaft = [p for p in pts if min(butt_y, butt_y + (tip_y - butt_y) * 0.3) <= p.y <= max(butt_y, butt_y + (tip_y - butt_y) * 0.3)]
    cx = (max(p.x for p in shaft) + min(p.x for p in shaft)) / 2
    cz = (max(p.z for p in shaft) + min(p.z for p in shaft)) / 2
    # 0.78 m war club, held 0.14 m above the butt.
    place_along_z(parts, Vector((cx, butt_y, cz)), Vector((cx, tip_y, cz)), 0.78, 0.14)
    return parts


BOW_HALF = 0.66      # half the stave length along Z (1.32 m bow)
BOW_BRACE = 0.14     # how far the tips (and string) sit behind the grip, toward the archer (-Y)
# "Drawn" shape key (blend shape in Godot, driven by player.gd while drawing). Must match the game:
BOW_NOCK = Vector((-0.022, 0.0, 0.03))  # nock x / height; Godot HandModels.NOCK = (x, z, -string_y)
BOW_PULL = 0.45      # = Player.BOW_PULL: how far the nock travels toward the archer at full draw
BOW_FLEX = 0.11      # extra tip travel toward the archer at full draw
BOW_TIP_IN = 0.05    # tips come closer together as the limbs bend


def b_bow(rng):
    """Self bow: one tapering stave bent toward the archer (-Y, i.e. +Z/camera side in Godot), leather grip,
    sinew string. Limbs along +Z, grip at the origin."""
    n = 28
    path, radii = [], []
    for i in range(n + 1):
        t = -1.0 + 2.0 * i / n
        a = abs(t)
        # Stiff handle, working limbs, slight reflex in the last few cm.
        y = -BOW_BRACE * (a ** 1.8) + 0.012 * max(0.0, a - 0.9) * 10
        path.append(Vector((rng.uniform(-0.0015, 0.0015), y, t * BOW_HALF)))
        radii.append(0.0165 - 0.0095 * a ** 1.3 if a > 0.12 else 0.0175)
    stave = tube(path, radii, WOOD(), seg=10, u_rep=1, v_scale=2.5)
    stave.scale = (1.45, 1.0, 1.0)  # limbs are wider than they are thick
    grip = tube([Vector((0, 0, -0.07)), Vector((0, 0, 0.07))], [0.0205, 0.0205], LEATHER(), seg=12)
    grip.scale = (1.35, 1.0, 1.0)
    tip_y = path[-1].y
    sinew = flat("M_Sinew", (0.78, 0.72, 0.6), 0.55)
    # The string needs rings along its length (it bends into a V when drawn), one of them at the nock height.
    sy, top, bot = tip_y - 0.004, BOW_HALF - 0.025, -BOW_HALF + 0.025
    zs = [top + (BOW_NOCK.z - top) * i / 12 for i in range(12)] + [BOW_NOCK.z + (bot - BOW_NOCK.z) * i / 12 for i in range(13)]
    string = tube([Vector((0, sy, z)) for z in zs], [0.0018] * len(zs), sinew, seg=5)
    string.vertex_groups.new(name="string").add(list(range(len(string.data.vertices))), 1.0, "REPLACE")
    nocks = [tube([Vector((0, tip_y, s * (BOW_HALF - 0.04))), Vector((0, tip_y, s * (BOW_HALF - 0.01)))],
                  [0.0085, 0.0075], sinew, seg=8) for s in (1, -1)]
    for n_ in nocks:
        n_.scale = (1.3, 1.0, 1.0)
    return [stave, grip, string] + nocks


def _limb_flex(co):
    """Drawn-state offset of a stave point: limbs bend further back, tips move in. Grip stays put."""
    a = min(abs(co.z) / BOW_HALF, 1.0)
    return Vector((0.0, -BOW_FLEX * a ** 2, -math.copysign(BOW_TIP_IN * a ** 3, co.z)))


def post_bow(obj):
    """Adds the 'Drawn' shape key: limbs flexed, string pulled into a V to the nock BOW_PULL behind rest."""
    obj.shape_key_add(name="Basis")
    key = obj.shape_key_add(name="Drawn", from_mix=False)
    g = obj.vertex_groups["string"].index
    vs = obj.data.vertices
    sv = [v for v in vs if any(e.group == g for e in v.groups)]
    sy = sum(v.co.y for v in sv) / len(sv)
    top = max(v.co.z for v in sv)
    bot = min(v.co.z for v in sv)
    ends = {}
    for z in (top, bot):
        e = Vector((0.0, sy, z))
        ends[z] = e + _limb_flex(e)
    nock = Vector((BOW_NOCK.x, sy - BOW_PULL, BOW_NOCK.z))
    sv_ids = {v.index for v in sv}
    for v in vs:
        if v.index in sv_ids:
            end = ends[top] if v.co.z >= BOW_NOCK.z else ends[bot]
            span = (top if v.co.z >= BOW_NOCK.z else bot) - BOW_NOCK.z
            t = (v.co.z - BOW_NOCK.z) / span if span else 0.0
            radial = v.co - Vector((0.0, sy, v.co.z))
            key.data[v.index].co = nock.lerp(end, t) + radial
        else:
            key.data[v.index].co = v.co + _limb_flex(v.co)
    obj.vertex_groups.remove(obj.vertex_groups["string"])
    key.value = 0.0  # rest pose by default (exported as the morph default weight)
    obj.active_shape_key_index = 0


POST = {"bow": post_bow}


ARROW_LEN = 0.78


def b_arrow(rng):
    """Flint-tipped arrow. Nock at the origin, point at +Z (ARROW_LEN)."""
    shaft = tube([Vector((0, 0, 0)), Vector((0, 0, ARROW_LEN - 0.03))], [0.0045, 0.0045],
                 flat("M_ArrowShaft", (0.58, 0.45, 0.3), 0.7), seg=8, v_scale=4)
    sq = lambda p: Vector((p.x * (1 - max(p.z, 0) / 0.032 * 0.95), p.y, p.z))
    head = hull(blob(Vector((0, 0, ARROW_LEN - 0.012)), (0.011, 0.0035, 0.03), 28, rng, 0.06, sq), FLINT(), 0.05)
    sinew = flat("M_Sinew", (0.78, 0.72, 0.6), 0.55)
    wraps = [tube([Vector((0, 0, z0)), Vector((0, 0, z1))], [0.0058, 0.0058], sinew, seg=8)
             for z0, z1 in ((ARROW_LEN - 0.05, ARROW_LEN - 0.028), (0.02, 0.035), (0.135, 0.15))]
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    for k in range(3):
        a = math.tau * k / 3
        d = Vector((math.cos(a), math.sin(a), 0))
        quad = [d * 0.004 + Vector((0, 0, 0.035)), d * 0.004 + Vector((0, 0, 0.135)),
                d * 0.016 + Vector((0, 0, 0.115)), d * 0.013 + Vector((0, 0, 0.045))]
        f = bm.faces.new([bm.verts.new(p) for p in quad])
        for l, (u, v) in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            l[uv].uv = (u, v)
    fletch = new_obj("fletch", bm, flat("M_Feather", (0.22, 0.2, 0.17), 0.8))
    return [shaft, head, fletch] + wraps


def b_stone_axe_blend(rng):
    """Previous hand-made axe (source/StoneAxe.blend). Not registered; kept for reference."""
    source = os.path.join(os.path.dirname(__file__), "source", "StoneAxe.blend")
    with bpy.data.libraries.load(source) as (available, loaded):
        loaded.objects = [name for name in available.objects if name != "GRIP_RIGHT_HAND"]
    parts = [obj for obj in loaded.objects if obj.type == "MESH"]
    for obj in parts:
        bpy.context.collection.objects.link(obj)
    return parts


def b_flint_knife(rng):
    sq = lambda p: Vector((p.x * (1 - (p.z / 0.13) ** 2 * 0.8 if p.z > 0 else 1), p.y, p.z))
    blade = hull(blob(Vector((0, 0, 0.13)), (0.022, 0.006, 0.075), 44, rng, 0.08, sq), FLINT(), 0.08)
    grip = tube([Vector((0, 0, -0.02)), Vector((0, 0, 0.07))], [0.016, 0.016], LEATHER(), seg=12)
    return [blade, grip]


def b_spear_procedural(rng):
    """Previous procedural spear. Not registered; kept for reference."""
    shaft = tube(bent(Vector((0, 0, -0.6)), Vector((0, 0, 1.2)), 12, 0.015, rng), [0.016] * 13, WOOD(), u_rep=1, v_scale=3)
    sq = lambda p: Vector((p.x * (1 - max(p.z, 0) / 0.07 * 0.9), p.y, p.z))
    tip = hull(blob(Vector((0, 0, 1.25)), (0.02, 0.006, 0.07), 40, rng, 0.08, sq), FLINT(), 0.08)
    wrap = tube([Vector((0, 0, 1.15)), Vector((0, 0, 1.21))], [0.02, 0.02], LEATHER(), seg=10)
    return [shaft, tip, wrap]


def b_torch(rng):
    stick = tube(bent(Vector((0, 0, -0.1)), Vector((0, 0, 0.4)), 6, 0.01, rng), [0.018] * 7, WOOD())
    head = uv_sphere(0.045, Vector((0, 0, 0.42)), (1, 1, 1.6), pbr("M_TorchHead", "thatch_roof_angled", (0.45, 0.38, 0.3, 1)))
    char = uv_sphere(0.035, Vector((0, 0, 0.47)), (1, 1, 1.2), flat("M_Char", (0.05, 0.04, 0.035), 0.9))
    return [stick, head, char]


def b_campfire_kit(rng):
    out = []
    for i in range(5):
        a = math.tau * i / 5
        out.append(hull(blob(Vector((math.cos(a) * 0.09, math.sin(a) * 0.09, 0.03)), (0.045, 0.04, 0.03), 24, rng), STONE()))
    for i in range(3):
        st = tube([Vector((-0.2, 0, 0)), Vector((0.2, 0, 0))], [0.015, 0.012], WOOD(), cap=True)
        st.rotation_euler = (0, 0, math.radians(60 * i)); st.location.z = 0.07 + 0.02 * i
        out.append(st)
    return out


def b_leaf_bed_kit(rng):
    out = []
    for i in range(5):
        st = tube([Vector((-0.3, 0, 0)), Vector((0.3, 0, 0))], [0.014, 0.012], WOOD())
        st.location = (0, (i - 2) * 0.025, 0.015)
        out.append(st)
    bundle = uv_sphere(0.12, Vector((0, 0, 0.08)), (2.2, 0.9, 0.55), pbr("M_LeafBundle", "thatch_roof_angled", (0.8, 0.9, 0.55, 1)))
    out.append(bundle)
    out.append(tube([Vector((0, -0.12, 0.08)), Vector((0, 0.12, 0.08))], [0.004, 0.004], flat("M_Cord", (0.35, 0.28, 0.18)), seg=6))
    return out


# ---------------------------------------------------------------- farming / provisions / tools update

CLAY_M = lambda: flat("M_Clay", (0.56, 0.42, 0.32), 0.75)
FIRED_M = lambda: flat("M_FiredClay", (0.55, 0.3, 0.18), 0.7)
BONE_M = lambda: flat("M_Bone", (0.86, 0.82, 0.72), 0.5)
ROPE_M = lambda: pbr("M_Rope", "thatch_roof_angled", (0.85, 0.75, 0.55, 1), uv_scale=4.0)
GREEN_M = lambda: flat("M_Leaf", (0.27, 0.45, 0.18), 0.8)


def _ring_path(cx, cy, z0, r, turns, n, rise):
    return [Vector((cx + math.cos(t) * r, cy + math.sin(t) * r, z0 + rise * t / math.tau))
            for t in [i / n * math.tau * turns for i in range(n + 1)]]


def b_clay(rng):
    return [uv_sphere(0.07, Vector((0, 0, 0.045)), (1.3, 1.0, 0.7), CLAY_M()),
            uv_sphere(0.05, Vector((0.08, 0.03, 0.035)), (1.1, 1.0, 0.75), CLAY_M())]


def b_reeds(rng):
    out = []
    for i in range(9):
        a = math.tau * i / 9
        off = Vector((math.cos(a) * 0.015, math.sin(a) * 0.015, 0))
        out.append(tube([off + Vector((0, 0, -0.05)), off + Vector((rng.uniform(-0.02, 0.02), rng.uniform(-0.02, 0.02), 0.6))],
                        [0.006, 0.004], flat("M_Reed", (0.62, 0.6, 0.36)), seg=5))
    out.append(tube([Vector((0, 0, 0.2)), Vector((0, 0, 0.24))], [0.028, 0.028], ROPE_M(), seg=10))
    return out


def b_rope(rng):
    return [tube(_ring_path(0, 0, 0.01, 0.07, 3.0, 72, 0.014), [0.011] * 73, ROPE_M(), seg=7, u_rep=1, v_scale=8)]


def _pouch(rng, seed_rgb):
    out = [uv_sphere(0.07, Vector((0, 0, 0.06)), (1.0, 1.0, 0.85), LEATHER()),
           tube([Vector((0, 0, 0.1)), Vector((0, 0, 0.14))], [0.03, 0.02], LEATHER(), seg=10),
           tube([Vector((0, 0, 0.118)), Vector((0, 0, 0.128))], [0.033, 0.033], ROPE_M(), seg=10)]
    for i in range(7):
        a = rng.uniform(0, math.tau)
        out.append(uv_sphere(0.009, Vector((0.09 + math.cos(a) * 0.03, math.sin(a) * 0.04, 0.008)), (1.4, 1.0, 0.8),
                             flat("M_Seed%02x%02x%02x" % tuple(int(c * 255) for c in seed_rgb), seed_rgb, 0.6), segs=6, rings=4))
    return out


def b_seeds_grain(rng): return _pouch(rng, (0.82, 0.68, 0.36))
def b_seeds_flax(rng): return _pouch(rng, (0.45, 0.3, 0.16))
def b_seeds_carrot(rng): return _pouch(rng, (0.38, 0.32, 0.2))


def b_herb(rng):
    out = []
    for i in range(6):
        a = math.tau * i / 6
        top = Vector((math.cos(a) * 0.03, math.sin(a) * 0.03, 0.32 + rng.uniform(-0.03, 0.03)))
        out.append(tube([Vector((0, 0, 0)), top], [0.004, 0.003], GREEN_M(), seg=4))
        out.append(uv_sphere(0.022, top, (1.3, 1.3, 0.45), flat("M_Yarrow", (0.93, 0.88, 0.86)), segs=8, rings=4))
        out.append(uv_sphere(0.018, top * 0.55, (2.4, 0.5, 0.18), GREEN_M(), segs=6, rings=4))
    out.append(tube([Vector((0, 0, 0.05)), Vector((0, 0, 0.08))], [0.018, 0.018], ROPE_M(), seg=8))
    return out


def b_grain(rng):
    out = []
    for i in range(11):
        a = rng.uniform(0, math.tau)
        r = rng.uniform(0.0, 0.025)
        top = Vector((math.cos(a) * r * 2.5, math.sin(a) * r * 2.5, 0.45 + rng.uniform(-0.03, 0.03)))
        out.append(tube([Vector((math.cos(a) * r, math.sin(a) * r, 0)), top], [0.004, 0.003], flat("M_Straw", (0.78, 0.68, 0.38)), seg=4))
        out.append(uv_sphere(0.012, top + Vector((0, 0, 0.035)), (1.0, 1.0, 3.4), flat("M_Ear", (0.85, 0.7, 0.36), 0.6), segs=6, rings=5))
    out.append(tube([Vector((0, 0, 0.15)), Vector((0, 0, 0.18))], [0.026, 0.026], ROPE_M(), seg=8))
    return out


def _carrot(rgb):
    body = tube([Vector((0, 0, 0)), Vector((0, 0, 0.06)), Vector((0, 0, 0.14)), Vector((0, 0, 0.2))], [0.004, 0.016, 0.024, 0.024],
                flat("M_Carrot%02x" % int(rgb[0] * 255), rgb, 0.55), seg=10)
    out = [body]
    for i in range(5):
        a = math.tau * i / 5
        out.append(tube([Vector((0, 0, 0.2)), Vector((math.cos(a) * 0.05, math.sin(a) * 0.05, 0.32))], [0.004, 0.002], GREEN_M(), seg=4))
    return out


def b_wild_carrot(rng): return _carrot((0.86, 0.52, 0.2))
def b_carrot_roasted(rng): return _carrot((0.55, 0.28, 0.12))


def _nuts(rng, rgb, name):
    return [uv_sphere(0.018, Vector((math.cos(a) * 0.03, math.sin(a) * 0.03, 0.017)), (1.0, 0.95, 1.15), flat(name, rgb, 0.45), segs=10, rings=7)
            for a in [math.tau * i / 5 + rng.uniform(-0.2, 0.2) for i in range(5)]]


def b_hazelnuts(rng): return _nuts(rng, (0.5, 0.33, 0.17), "M_Hazel")
def b_nuts_roasted(rng): return _nuts(rng, (0.32, 0.2, 0.1), "M_HazelRoast")


def _fish(rgb, cooked):
    m = flat("M_Fish%02x" % int(rgb[0] * 255), rgb, 0.35 if not cooked else 0.7)
    body = uv_sphere(0.05, Vector((0, 0, 0.04)), (3.2, 1.0, 0.8), m, segs=14, rings=8)
    tail = hull([Vector((-0.15, 0, 0.04)), Vector((-0.22, 0, 0.09)), Vector((-0.22, 0, -0.01)), Vector((-0.2, 0.005, 0.04)),
                 Vector((-0.2, -0.005, 0.04))], m, 0.1)
    fin = hull([Vector((-0.02, 0, 0.08)), Vector((0.06, 0, 0.075)), Vector((0.0, 0, 0.11)), Vector((0.02, 0.004, 0.08))], m, 0.1)
    out = [body, tail, fin]
    if cooked:
        out.append(tube([Vector((-0.25, 0, 0.04)), Vector((0.25, 0, 0.04))], [0.006, 0.006], WOOD(), seg=6))
    return out


def b_fish_raw(rng): return _fish((0.55, 0.6, 0.62), False)
def b_fish_cooked(rng): return _fish((0.55, 0.36, 0.18), True)


def b_flatbread(rng):
    out = [uv_sphere(0.1, Vector((0, 0, 0.015)), (1.0, 1.0, 0.16), flat("M_Bread", (0.82, 0.62, 0.36), 0.75), segs=18, rings=6)]
    for i in range(6):
        a = rng.uniform(0, math.tau)
        r = rng.uniform(0.02, 0.07)
        out.append(uv_sphere(0.012, Vector((math.cos(a) * r, math.sin(a) * r, 0.029)), (1.3, 1.0, 0.25), flat("M_BreadBurn", (0.36, 0.22, 0.12)), segs=6, rings=4))
    return out


def _pot(filled_rgb=None):
    prof = [0.0, 0.03, 0.08, 0.14, 0.19, 0.22]
    radii = [0.06, 0.095, 0.115, 0.11, 0.09, 0.098]
    out = [tube([Vector((0, 0, z)) for z in prof], radii, FIRED_M(), seg=16, cap=False),
           uv_sphere(0.06, Vector((0, 0, 0.003)), (1.0, 1.0, 0.1), FIRED_M(), segs=14, rings=4)]
    if filled_rgb:
        out.append(uv_sphere(0.088, Vector((0, 0, 0.19)), (1.0, 1.0, 0.12), flat("M_Food%02x" % int(filled_rgb[0] * 255), filled_rgb, 0.4), segs=16, rings=5))
    return out


def b_clay_pot(rng): return _pot()
def b_porridge(rng): return _pot((0.82, 0.72, 0.52))
def b_stew(rng): return _pot((0.45, 0.26, 0.14))


def b_poultice(rng):
    return [uv_sphere(0.05, Vector((0, 0, 0.03)), (1.4, 1.0, 0.6), flat("M_Poultice", (0.42, 0.55, 0.3), 0.85), segs=10, rings=6),
            tube([Vector((-0.04, 0, 0.03)), Vector((0.04, 0, 0.03))], [0.032, 0.032], pbr("M_BandageWrap", None, color=(0.78, 0.72, 0.58, 1)), seg=10)]


def b_digging_stick(rng):
    return [tube(bent(Vector((0, 0, -0.35)), Vector((0, 0, 0.55)), 10, 0.012, rng), [0.02] * 9 + [0.012, 0.004], WOOD(), seg=8),
            tube([Vector((0, 0, 0.42)), Vector((0, 0, 0.56))], [0.016, 0.003], flat("M_Charred", (0.08, 0.06, 0.05), 0.8), seg=8)]


def b_sickle(rng):
    out = [tube([Vector((0, 0, -0.12)), Vector((0, 0, 0.12))], [0.02, 0.018], WOOD(), seg=8),
           tube([Vector((0, 0, -0.06)), Vector((0, 0, 0.0))], [0.022, 0.022], ROPE_M(), seg=8)]
    # Curved haft carrying a row of flint microliths along its inner edge.
    pts = [Vector((math.sin(t) * 0.15, 0, 0.12 + (1.0 - math.cos(t)) * 0.15)) for t in [i / 8 * 1.7 for i in range(9)]]
    out.append(tube(pts, [0.016] * 9, WOOD(), seg=7))
    for i in range(1, 8):
        p = pts[i]
        n = Vector((math.cos(i / 8 * 1.7), 0, -math.sin(i / 8 * 1.7)))
        out.append(hull(blob(p - n * 0.02, (0.018, 0.006, 0.014), 14, rng, 0.1), FLINT(), 0.05))
    return out


def b_fishing_spear(rng):
    shaft = tube(bent(Vector((0, 0, -0.7)), Vector((0, 0, 1.05)), 12, 0.012, rng), [0.016] * 13, WOOD(), seg=8)
    out = [shaft, tube([Vector((0, 0, 0.98)), Vector((0, 0, 1.06))], [0.022, 0.022], ROPE_M(), seg=8)]
    for i in range(3):
        a = math.tau * i / 3
        base = Vector((math.cos(a) * 0.012, math.sin(a) * 0.012, 1.0))
        out.append(tube([base, base + Vector((math.cos(a) * 0.035, math.sin(a) * 0.035, 0.24))], [0.007, 0.0015], BONE_M(), seg=6))
        out.append(tube([base + Vector((math.cos(a) * 0.03, math.sin(a) * 0.03, 0.18)), base + Vector((math.cos(a) * 0.018, math.sin(a) * 0.018, 0.16))],
                        [0.004, 0.001], BONE_M(), seg=4))  # barb
    return out


def b_bone_knife(rng):
    sq = lambda p: Vector((p.x * (1 - max(p.z - 0.05, 0) / 0.13 * 0.85), p.y, p.z))
    blade = hull(blob(Vector((0, 0, 0.1)), (0.017, 0.006, 0.08), 40, rng, 0.06, sq), BONE_M(), 0.08)
    grip = tube([Vector((0, 0, -0.04)), Vector((0, 0, 0.04))], [0.017, 0.017], ROPE_M(), seg=10)
    return [blade, grip]


BUILDERS = {
    "clay": b_clay, "reeds": b_reeds, "rope": b_rope, "seeds_grain": b_seeds_grain, "seeds_flax": b_seeds_flax,
    "seeds_carrot": b_seeds_carrot, "herb": b_herb, "grain": b_grain, "wild_carrot": b_wild_carrot,
    "carrot_roasted": b_carrot_roasted, "hazelnuts": b_hazelnuts, "nuts_roasted": b_nuts_roasted, "fish_raw": b_fish_raw,
    "fish_cooked": b_fish_cooked, "flatbread": b_flatbread, "porridge": b_porridge, "stew": b_stew, "poultice": b_poultice,
    "digging_stick": b_digging_stick, "sickle": b_sickle, "fishing_spear": b_fishing_spear, "bone_knife": b_bone_knife,
    "clay_pot": b_clay_pot,
    "stone": b_stone, "flint": b_flint, "stick": b_stick, "wood": b_wood, "fiber": b_fiber, "hide": b_hide, "bone": b_bone,
    "berries": b_berries, "mushroom": b_mushroom, "mushroom_cooked": b_mushroom_cooked, "meat_raw": b_meat_raw,
    "meat_cooked": b_meat_cooked, "meat_dried": b_meat_dried, "waterskin_empty": b_waterskin_empty,
    "waterskin_raw": b_waterskin_raw, "waterskin_boiled": b_waterskin_boiled, "bandage": b_bandage,
    "stone_axe": b_stone_axe, "flint_knife": b_flint_knife, "spear": b_spear, "torch": b_torch,
    "campfire_kit": b_campfire_kit, "leaf_bed_kit": b_leaf_bed_kit,
    "club": b_club, "bow": b_bow, "arrow": b_arrow,
}
LONG = {"stick", "stone_axe", "flint_knife", "spear", "torch", "bone", "fiber", "club", "bow", "arrow",
        "digging_stick", "fishing_spear", "bone_knife", "reeds", "grain", "herb"}


# ---------------------------------------------------------------- export + icon

def export(obj, item_id):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT_MODELS, f"SM_Item_{item_id}.gltf"), export_format="GLTF_SEPARATE",
                              export_texture_dir="textures", use_selection=True, export_image_format="AUTO", export_yup=True)


def render_icon(obj, item_id):
    sc = bpy.context.scene
    pose = obj.copy(); pose.data = obj.data
    sc.collection.objects.link(pose)
    obj.hide_render = True
    if item_id == "bow":  # turn the stave so its curve (YZ plane) faces the camera, then tilt diagonally
        pose.rotation_mode = "ZYX"
        pose.rotation_euler = (0, math.radians(-45), math.radians(90))
    elif item_id == "stone_axe":
        pose.rotation_euler = (0, math.radians(-34), math.radians(-8))
    elif item_id in LONG:
        pose.rotation_euler = (0, math.radians(-50), math.radians(30))
    else:
        pose.rotation_euler = (0, 0, math.radians(25))
    bpy.context.view_layer.update()
    corners = [pose.matrix_world @ Vector(c) for c in pose.bound_box]
    mn = Vector((min(c.x for c in corners), min(c.y for c in corners), min(c.z for c in corners)))
    mx = Vector((max(c.x for c in corners), max(c.y for c in corners), max(c.z for c in corners)))
    center = (mn + mx) / 2
    size = (mx - mn).length
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = size * 0.95
    direction = Vector((0.0, -1.0, 0.75)).normalized()
    if item_id == "stone_axe":
        direction = Vector((0.16, -1.0, 0.18)).normalized()
        rotation = (-direction).to_track_quat("-Z", "Y")
        right, up = rotation @ Vector((1, 0, 0)), rotation @ Vector((0, 1, 0))
        points = [pose.matrix_world @ vertex.co - center for vertex in pose.data.vertices]
        xs, ys = [p.dot(right) for p in points], [p.dot(up) for p in points]
        cam.data.ortho_scale = max(max(xs) - min(xs), max(ys) - min(ys)) * 1.12
        center += right * ((min(xs) + max(xs)) / 2) + up * ((min(ys) + max(ys)) / 2)
    cam.location = center + direction * (size * 3)
    cam.rotation_euler = (-direction).to_track_quat("-Z", "Y").to_euler()
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN")); sun.data.energy = 3.5
    sun.rotation_euler = (math.radians(40), math.radians(15), math.radians(-30)); sc.collection.objects.link(sun)
    rim = bpy.data.objects.new("rim", bpy.data.lights.new("rim", "SUN")); rim.data.energy = 1.6
    rim.rotation_euler = (math.radians(-60), 0, math.radians(160)); sc.collection.objects.link(rim)
    w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.45, 0.42, 0.38, 1)
    w.node_tree.nodes["Background"].inputs[1].default_value = 0.7
    sc.camera = cam
    sc.render.engine = "CYCLES"; sc.cycles.samples = 32; sc.cycles.device = "CPU"
    sc.render.film_transparent = True
    sc.render.resolution_x = sc.render.resolution_y = 256
    sc.render.image_settings.file_format = "PNG"; sc.render.image_settings.color_mode = "RGBA"
    sc.view_settings.view_transform = "AgX"; sc.view_settings.look = "AgX - Medium High Contrast"
    sc.render.filepath = os.path.join(OUT_ICONS, f"T_Icon_{item_id}.png")
    bpy.ops.render.render(write_still=True)


def build(item_id):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _mats.clear()
    rng = random.Random(hash(item_id) & 0xFFFF)
    objs = BUILDERS[item_id](rng)
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    if len(objs) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = f"SM_Item_{item_id}"
    if item_id in POST:
        POST[item_id](obj)
    tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    export(obj, item_id)
    render_icon(obj, item_id)
    print("ITEM", item_id, "tris", tris, "size", [round(x, 3) for x in obj.dimensions])


argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
for iid in (argv or list(BUILDERS.keys())):
    build(iid)
