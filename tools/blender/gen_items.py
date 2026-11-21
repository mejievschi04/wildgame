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
    for f in sorted(os.listdir(d)):
        if f"_{kind}_" in f:
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


def b_stone_axe(rng):
    handle = tube(bent(Vector((0, 0, -0.1)), Vector((0, 0, 0.5)), 8, 0.02, rng), [0.017] * 4 + [0.019] * 5, WOOD())
    sq = lambda p: Vector((p.x * (1.0 if p.x < 0 else 0.55 + 0.45 * (1 - abs(p.z) / 0.05)), p.y * (1 - max(p.x, 0) / 0.11), p.z))
    head = hull(blob(Vector((0.035, 0, 0.44)), (0.08, 0.026, 0.045), 50, rng, 0.12, sq), STONE(), 0.12)
    wrap = tube([Vector((0, 0, 0.41)), Vector((0, 0, 0.47))], [0.024, 0.024], LEATHER(), seg=10)
    return [handle, head, wrap]


def b_flint_knife(rng):
    sq = lambda p: Vector((p.x * (1 - (p.z / 0.13) ** 2 * 0.8 if p.z > 0 else 1), p.y, p.z))
    blade = hull(blob(Vector((0, 0, 0.13)), (0.022, 0.006, 0.075), 44, rng, 0.08, sq), FLINT(), 0.08)
    grip = tube([Vector((0, 0, -0.02)), Vector((0, 0, 0.07))], [0.016, 0.016], LEATHER(), seg=12)
    return [blade, grip]


def b_spear(rng):
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


BUILDERS = {
    "stone": b_stone, "flint": b_flint, "stick": b_stick, "wood": b_wood, "fiber": b_fiber, "hide": b_hide, "bone": b_bone,
    "berries": b_berries, "mushroom": b_mushroom, "mushroom_cooked": b_mushroom_cooked, "meat_raw": b_meat_raw,
    "meat_cooked": b_meat_cooked, "meat_dried": b_meat_dried, "waterskin_empty": b_waterskin_empty,
    "waterskin_raw": b_waterskin_raw, "waterskin_boiled": b_waterskin_boiled, "bandage": b_bandage,
    "stone_axe": b_stone_axe, "flint_knife": b_flint_knife, "spear": b_spear, "torch": b_torch,
    "campfire_kit": b_campfire_kit, "leaf_bed_kit": b_leaf_bed_kit,
}
LONG = {"stick", "stone_axe", "flint_knife", "spear", "torch", "bone", "fiber"}


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
    if item_id in LONG:
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
    tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    export(obj, item_id)
    render_icon(obj, item_id)
    print("ITEM", item_id, "tris", tris, "size", [round(x, 3) for x in obj.dimensions])


argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
for iid in (argv or list(BUILDERS.keys())):
    build(iid)
