# Procedural game trees built from CC0 scanned textures (bark + baked twig/leaf cards).
#   blender -b --python tools/blender/gen_trees.py
# Output: assets/models/trees/SM_Spruce_0N.gltf, SM_Pine_0N.gltf, SM_Alder_0N.gltf (+ shared textures)
# Conventions: Blender Z-up, origin at trunk base, metres. Foliage cards carry custom normals
# pointing away from the crown centre (soft "volumetric" lighting in-engine).
import bpy, bmesh, math, os, random, json
from mathutils import Vector, Matrix

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "models", "trees")
TEX = os.path.join(OUT, "textures")


# ---------------------------------------------------------------- materials

def image(name):
    return bpy.data.images.load(os.path.join(TEX, name), check_existing=True)


def bark_material(name, prefix):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    d = nt.nodes.new("ShaderNodeTexImage"); d.image = image(f"T_{prefix}_diff.jpg")
    n = nt.nodes.new("ShaderNodeTexImage"); n.image = image(f"T_{prefix}_nor_gl.jpg"); n.image.colorspace_settings.name = "Non-Color"
    a = nt.nodes.new("ShaderNodeTexImage"); a.image = image(f"T_{prefix}_arm.jpg"); a.image.colorspace_settings.name = "Non-Color"
    nm = nt.nodes.new("ShaderNodeNormalMap")
    sep = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(d.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(n.outputs["Color"], nm.inputs["Color"])
    nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    nt.links.new(a.outputs["Color"], sep.inputs["Color"])
    nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
    nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
    return m


def card_material(name, tex):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    t = nt.nodes.new("ShaderNodeTexImage"); t.image = image(tex)
    nt.links.new(t.outputs["Color"], bsdf.inputs["Base Color"])
    nt.links.new(t.outputs["Alpha"], bsdf.inputs["Alpha"])
    bsdf.inputs["Roughness"].default_value = 0.85
    m.use_backface_culling = False
    return m


# ---------------------------------------------------------------- geometry builder

class Builder:
    def __init__(self):
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.new("UVMap")
        self.normals = {}  # face index -> per-loop custom normal (foliage only)

    def tube(self, path, radii, segments, mat_index, u_repeat, v_scale):
        """Generalised cylinder along a list of points. UV u wraps around, v follows length."""
        rings = []
        acc = 0.0
        for i, p in enumerate(path):
            if i > 0:
                acc += (path[i] - path[i - 1]).length
            t = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
            # Stable frame: project a fixed reference axis onto the plane ⟂ tangent (no ring twisting).
            ref = Vector((1, 0, 0)) if abs(t.x) < 0.9 else Vector((0, 1, 0))
            side = (ref - t * ref.dot(t)).normalized()
            up = t.cross(side).normalized()
            ring = []
            for s in range(segments + 1):
                a = 2 * math.pi * s / segments
                ring.append((self.bm.verts.new(p + (side * math.cos(a) + up * math.sin(a)) * radii[i]), s / segments * u_repeat, acc * v_scale))
            rings.append(ring)
        for i in range(len(rings) - 1):
            for s in range(segments):
                q = [rings[i][s], rings[i][s + 1], rings[i + 1][s + 1], rings[i + 1][s]]
                f = self.bm.faces.new([v[0] for v in q])
                f.material_index = mat_index
                f.smooth = True
                for loop, v in zip(f.loops, q):
                    loop[self.uv].uv = (v[1], v[2])

# Foliage card + mesh finalisation (attached to Builder below).
def _card(self, base, direction, side, length, width, mat_index, crown_center, uv_rect=(0, 0, 1, 1), bend=0.0):
    u0, v0, u1, v1 = uv_rect
    mid = base + direction * length * 0.5 + Vector((0, 0, -bend * 0.25))
    tip = base + direction * length + Vector((0, 0, -bend))
    pts = [(base - side * width * 0.15, u0, v0), (base + side * width * 0.15, u0, v1),
           (mid + side * width * 0.5, (u0 + u1) / 2, v1), (tip + side * width * 0.35, u1, v1),
           (tip - side * width * 0.35, u1, v0), (mid - side * width * 0.5, (u0 + u1) / 2, v0)]
    verts = [self.bm.verts.new(p[0]) for p in pts]
    for tri in [(0, 1, 2), (0, 2, 5), (5, 2, 3), (5, 3, 4)]:
        f = self.bm.faces.new([verts[i] for i in tri])
        f.material_index = mat_index
        f.smooth = True
        self.bm.faces.index_update()
        ns = {}
        for k, (loop, i) in enumerate(zip(f.loops, tri)):
            loop[self.uv].uv = (pts[i][1], pts[i][2])
            n = pts[i][0] - crown_center
            n = Vector((n.x, n.y, n.z * 0.4)).normalized() * 0.7 + Vector((0, 0, 0.55))
            ns[k] = n.normalized()
        self.normals[f.index] = ns


def _finish(self, name, materials):
    self.bm.faces.index_update()
    mesh = bpy.data.meshes.new(name)
    self.bm.to_mesh(mesh)
    for m in materials:
        mesh.materials.append(m)
    mesh.update()
    vnorm = [v.normal.copy() for v in mesh.vertices]
    out = []
    for poly in mesh.polygons:
        ns = self.normals.get(poly.index)
        for k, li in enumerate(poly.loop_indices):
            out.append(ns[k] if ns else vnorm[mesh.loops[li].vertex_index])
    mesh.normals_split_custom_set(out)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    self.bm.free()
    return obj


Builder.card = _card
Builder.finish = _finish


def horiz(angle):
    return Vector((math.cos(angle), math.sin(angle), 0))


def trunk_path(height, lean, rng, steps):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        pts.append(Vector((lean.x * t * t + rng.uniform(-0.02, 0.02), lean.y * t * t + rng.uniform(-0.02, 0.02), height * t)))
    return pts


# ---------------------------------------------------------------- species

def spruce(seed):
    rng = random.Random(seed)
    b = Builder()
    H = rng.uniform(13.0, 16.5)
    r0 = rng.uniform(0.26, 0.34)
    path = trunk_path(H, Vector((rng.uniform(-0.3, 0.3), rng.uniform(-0.3, 0.3), 0)), rng, 14)
    radii = [r0 * (1.25 if i == 0 else 1.0) * (1 - i / 14) ** 0.85 + 0.025 for i in range(15)]
    b.tube(path, radii, 10, 0, 2.0, 0.9)
    crown_base = rng.uniform(1.4, 2.6)
    z = crown_base
    while z < H - 0.6:
        rel = (z - crown_base) / (H - crown_base)
        n = rng.randint(5, 7)
        a0 = rng.uniform(0, 2 * math.pi)
        L = 0.45 + 2.9 * (1 - rel) ** 1.05
        center = Vector((0, 0, z + 1.0))
        for k in range(n):
            ang = a0 + 2 * math.pi * k / n + rng.uniform(-0.25, 0.25)
            droop = math.radians(rng.uniform(-28, -8) * (1 - rel * 0.6))
            d = (horiz(ang) * math.cos(droop) + Vector((0, 0, math.sin(droop)))).normalized()
            base = Vector((path[0].x, path[0].y, 0)) * 0 + Vector((path[min(int(z / H * 14), 14)].x, path[min(int(z / H * 14), 14)].y, z))
            Lk = L * rng.uniform(0.85, 1.1)
            side = horiz(ang + math.pi / 2)
            b.card(base, d, side, Lk, Lk * 0.85, 1, center, bend=Lk * 0.12)
            up_side = d.cross(side).normalized()
            b.card(base, d, up_side, Lk * 0.9, Lk * 0.5, 1, center, bend=Lk * 0.08)
        z += rng.uniform(0.38, 0.5)
    top = Vector((path[-1].x, path[-1].y, H - 1.2))
    for k in range(3):
        b.card(top, Vector((0, 0, 1)), horiz(k * math.pi / 3), 1.6, 0.9, 1, top - Vector((0, 0, 1)))
    return b, H


def pine(seed):
    rng = random.Random(seed)
    b = Builder()
    H = rng.uniform(15.0, 18.0)
    r0 = rng.uniform(0.24, 0.32)
    path = trunk_path(H, Vector((rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5), 0)), rng, 16)
    radii = [r0 * (1.2 if i == 0 else 1.0) * (1 - i / 16) ** 0.7 + 0.03 for i in range(17)]
    b.tube(path, radii, 10, 0, 2.0, 0.9)
    crown0 = H * rng.uniform(0.58, 0.66)
    center = Vector((path[-1].x, path[-1].y, (crown0 + H) / 2))
    z = crown0
    while z < H - 0.3:
        rel = (z - crown0) / (H - crown0)
        L = 0.5 + 1.9 * math.sin(math.pi * min(0.15 + rel * 0.95, 1.0)) ** 0.7
        tz = min(int(z / H * 16), 16)
        base = Vector((path[tz].x, path[tz].y, z))
        for k in range(rng.randint(3, 5)):
            ang = rng.uniform(0, 2 * math.pi)
            rise = math.radians(rng.uniform(0, 25))
            d = (horiz(ang) * math.cos(rise) + Vector((0, 0, math.sin(rise)))).normalized()
            Lk = L * rng.uniform(0.75, 1.1)
            limb = [base, base + d * Lk * 0.5 + Vector((0, 0, 0.1)), base + d * Lk]
            b.tube(limb, [0.05, 0.035, 0.02], 5, 0, 1.0, 1.0)
            for c in range(4):
                p = base + d * Lk * (0.25 + 0.25 * c)
                side = horiz(ang + math.pi / 2 + rng.uniform(-0.5, 0.5))
                cd = (d * 0.6 + Vector((0, 0, rng.uniform(0.3, 0.9)))).normalized()
                s = rng.uniform(1.4, 2.1)
                b.card(p - cd * s * 0.35, cd, side, s, s * 0.95, 1, center)
                b.card(p - cd * s * 0.35, cd, cd.cross(side).normalized(), s * 0.9, s * 0.7, 1, center)
        z += rng.uniform(0.4, 0.6)
    top = Vector((path[-1].x, path[-1].y, H - 1.0))
    for k in range(3):
        b.card(top, Vector((0, 0, 1)), horiz(k * math.pi / 3), 1.6, 1.2, 1, center)
    return b, H


def alder(seed):
    rng = random.Random(seed)
    b = Builder()
    H = rng.uniform(10.0, 13.0)
    r0 = rng.uniform(0.2, 0.27)
    split = H * rng.uniform(0.32, 0.4)
    path = trunk_path(split + 1.0, Vector((rng.uniform(-0.15, 0.15), rng.uniform(-0.15, 0.15), 0)), rng, 6)
    b.tube(path, [r0 * (1.2 if i == 0 else 1.0) * (1 - i / 9) + 0.04 for i in range(7)], 10, 0, 1.5, 0.9)
    rx, rz = rng.uniform(2.6, 3.4), (H - split) / 2
    crown = Vector((path[-1].x, path[-1].y, split + rz + 0.3))
    for k in range(rng.randint(3, 5)):
        ang = rng.uniform(0, 2 * math.pi)
        tilt = math.radians(rng.uniform(18, 34))
        d = (horiz(ang) * math.sin(tilt) + Vector((0, 0, math.cos(tilt)))).normalized()
        start = path[-2].copy()
        L = rz * rng.uniform(1.2, 1.6)
        limb = [start, start + d * L * 0.5 + horiz(ang) * 0.2, start + d * L]
        b.tube(limb, [r0 * 0.45, r0 * 0.28, 0.03], 6, 0, 1.0, 1.0)
    for i in range(rng.randint(170, 200)):
        u = rng.uniform(0, 2 * math.pi)
        v = math.acos(rng.uniform(-0.55, 1.0))
        r = rng.uniform(0.35, 1.0) ** 0.6
        p = crown + Vector((math.cos(u) * math.sin(v) * rx * r, math.sin(u) * math.sin(v) * rx * r, math.cos(v) * rz * r))
        d = (p - crown)
        d = Vector((d.x, d.y, d.z * 0.5 + 0.3)).normalized()
        side = d.cross(Vector((0, 0, 1)))
        side = side.normalized() if side.length > 0.01 else Vector((1, 0, 0))
        q = rng.randint(0, 3)
        rect = (q / 4, 0.0, (q + 1) / 4, 1.0)
        s = rng.uniform(1.1, 1.6)
        b.card(p - d * s * 0.5, d, side, s, s, 1, crown, uv_rect=rect)
        b.card(p - d * s * 0.5, d, d.cross(side).normalized(), s, s * 0.8, 1, crown, uv_rect=rect)
    return b, H


def jungle(seed):
    """Tropical canopy tree: buttress roots, a tall straight bole, a few heavy limbs spreading into a broad,
    layered umbrella crown of big-leaf sprays, lianas hanging from the limbs and epiphytes on the trunk."""
    rng = random.Random(seed)
    b = Builder()
    H = rng.uniform(17.0, 22.0)
    r0 = rng.uniform(0.36, 0.46)
    split = H * rng.uniform(0.6, 0.7)
    path = trunk_path(split + 0.5, Vector((rng.uniform(-0.25, 0.25), rng.uniform(-0.25, 0.25), 0)), rng, 10)
    b.tube(path, [r0 * (1.25 if i == 0 else 1.0) * (1 - i / 16) + 0.05 for i in range(11)], 12, 0, 2.5, 0.8)
    # buttress roots: thin flanges running out and down from the bole
    for k in range(rng.randint(4, 6)):
        ang = 2 * math.pi * k / 5 + rng.uniform(-0.3, 0.3)
        out = horiz(ang)
        top = Vector((0, 0, rng.uniform(1.8, 2.8)))
        foot = out * rng.uniform(1.6, 2.4) + Vector((0, 0, -0.15))
        for j in range(3):  # stacked thin tubes read as a flat flange
            o = j / 2.0
            b.tube([top * (1 - o * 0.6) + out * 0.2, (top * (1 - o * 0.6) + foot) * 0.5 + out * 0.25, foot * (0.75 + 0.25 * o)],
                   [0.07, 0.06, 0.04], 5, 0, 1.0, 1.0)
    crown_h = H - split
    clusters = []
    for k in range(rng.randint(4, 6)):
        ang = 2 * math.pi * k / 5 + rng.uniform(-0.4, 0.4)
        rise = math.radians(rng.uniform(20, 38))
        d = (horiz(ang) * math.cos(rise) + Vector((0, 0, math.sin(rise)))).normalized()
        start = path[-2].copy()
        L = rng.uniform(4.0, 6.0)
        mid = start + d * L * 0.55 + Vector((0, 0, 0.4))
        end = start + d * L + Vector((0, 0, crown_h * 0.25))
        b.tube([start, mid, end], [r0 * 0.5, r0 * 0.33, 0.06], 7, 0, 1.0, 1.0)
        clusters.append(end)
        # lianas hanging from the limb
        for v in range(rng.randint(1, 2)):
            a = mid.lerp(end, rng.uniform(0.0, 0.8))
            drop = rng.uniform(4.0, a.z - 0.5)
            sway = horiz(rng.uniform(0, 2 * math.pi)) * rng.uniform(0.2, 0.6)
            b.tube([a, a + sway * 0.5 + Vector((0, 0, -drop * 0.5)), a + sway + Vector((0, 0, -drop))], [0.035, 0.03, 0.025], 4, 0, 0.3, 2.0)
    clusters.append(Vector((path[-1].x, path[-1].y, H - crown_h * 0.35)))
    center = Vector((path[-1].x, path[-1].y, H - crown_h * 0.45))
    # layered umbrella: flattened leaf clumps at the limb ends
    for c in clusters:
        rx, rz = rng.uniform(2.4, 3.2), rng.uniform(1.0, 1.5)
        for i in range(rng.randint(46, 60)):
            u = rng.uniform(0, 2 * math.pi)
            v = math.acos(rng.uniform(-0.3, 1.0))
            r = rng.uniform(0.3, 1.0) ** 0.6
            p = c + Vector((math.cos(u) * math.sin(v) * rx * r, math.sin(u) * math.sin(v) * rx * r, math.cos(v) * rz * r))
            d = (p - c)
            d = Vector((d.x, d.y, d.z * 0.4 + 0.25)).normalized()
            side = d.cross(Vector((0, 0, 1)))
            side = side.normalized() if side.length > 0.01 else Vector((1, 0, 0))
            q = rng.randint(0, 3)
            rect = (q / 4, 0.0, (q + 1) / 4, 1.0)
            sz = rng.uniform(1.5, 2.2)
            b.card(p - d * sz * 0.5, d, side, sz, sz, 1, center, uv_rect=rect, bend=sz * 0.15)
            b.card(p - d * sz * 0.5, d, d.cross(side).normalized(), sz, sz * 0.8, 1, center, uv_rect=rect)
    # epiphytes and young shoots on the bole
    for i in range(rng.randint(10, 16)):
        z = rng.uniform(1.0, split - 1.0)
        ang = rng.uniform(0, 2 * math.pi)
        p = Vector((path[int(z / split * 10)].x, path[int(z / split * 10)].y, z)) + horiz(ang) * r0 * 0.9
        d = (horiz(ang) + Vector((0, 0, 0.4))).normalized()
        q = rng.randint(0, 3)
        b.card(p, d, horiz(ang + math.pi / 2), 1.0, 0.9, 1, p - horiz(ang), uv_rect=(q / 4, 0.0, (q + 1) / 4, 1.0), bend=0.2)
    return b, H


def palm(seed):
    """A palm: a slender, gently curving ringed trunk and a crown of long arching pinnate fronds."""
    rng = random.Random(seed)
    b = Builder()
    H = rng.uniform(8.0, 12.0)
    lean = horiz(rng.uniform(0, 2 * math.pi)) * rng.uniform(0.8, 2.0)
    steps = 14
    path = [Vector((lean.x * (i / steps) ** 2, lean.y * (i / steps) ** 2, H * i / steps)) for i in range(steps + 1)]
    radii = [0.2 * (1.35 if i == 0 else 1.0) * (1 - 0.35 * i / steps) + (0.012 if i % 2 else 0.0) for i in range(steps + 1)]
    b.tube(path, radii, 10, 0, 1.5, 1.6)
    top = path[-1]
    center = top + Vector((0, 0, -0.6))
    n = rng.randint(13, 17)
    for k in range(n):
        ang = 2 * math.pi * k / n + rng.uniform(-0.15, 0.15)
        up = math.radians(rng.uniform(5, 55) if k % 3 else rng.uniform(40, 70))
        d = (horiz(ang) * math.cos(up) + Vector((0, 0, math.sin(up)))).normalized()
        L = rng.uniform(3.6, 4.8)
        side = horiz(ang + math.pi / 2)
        # two segments per frond so it arches over and droops
        b.card(top, d, side, L * 0.55, 1.5, 1, center, uv_rect=(0.0, 0.0, 0.55, 1.0), bend=0.15)
        tip_d = (horiz(ang) * math.cos(up - 0.9) + Vector((0, 0, math.sin(up - 0.9)))).normalized()
        b.card(top + d * L * 0.53 + Vector((0, 0, -0.06)), tip_d, side, L * 0.47, 1.3, 1, center,
               uv_rect=(0.53, 0.0, 1.0, 1.0), bend=0.4)
    return b, H


# ---------------------------------------------------------------- export

def export(obj, name):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    path = os.path.join(OUT, name + ".gltf")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="textures",
                              use_selection=True, export_image_format="AUTO", export_yup=True, export_normals=True)
    g = json.load(open(path))
    for m in g.get("materials", []):
        if m.get("name", "").endswith("Foliage"):
            m["alphaMode"] = "MASK"
            m["alphaCutoff"] = 0.4
            m["doubleSided"] = True
    json.dump(g, open(path, "w"), indent=1)


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    mats = {
        "spruce": [bark_material("M_PineBark", "PineBark"), card_material("M_SpruceFoliage", "T_FirTwigCard_D.png")],
        "pine": [bark_material("M_PineBark2", "PineBark"), card_material("M_PineFoliage", "T_PineTwigCard_D.png")],
        "alder": [bark_material("M_AlderBark", "AlderBark"), card_material("M_AlderFoliage", "T_LeavesCard_D.png")],
        "jungle": [bark_material("M_JungleBark", "AlderBark"), card_material("M_JungleFoliage", "T_JungleLeafCard_D.png")],
        "palm": [bark_material("M_PalmBark", "PineBark"), card_material("M_PalmFoliage", "T_PalmFrondCard_D.png")],
    }
    makers = {"spruce": ("SM_Spruce", spruce, 3), "pine": ("SM_Pine", pine, 2), "alder": ("SM_Alder", alder, 2),
              "jungle": ("SM_Jungle", jungle, 2), "palm": ("SM_Palm", palm, 2)}
    import sys
    only = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    for key, (prefix, fn, count) in makers.items():
        if only and key not in only:
            continue
        for i in range(count):
            for o in list(bpy.context.scene.objects):
                bpy.data.objects.remove(o)
            b, H = fn(1000 * (i + 1) + len(key))
            name = f"{prefix}_{i + 1:02d}"
            obj = b.finish(name, mats[key])
            tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
            export(obj, name)
            print("TREE", name, "height", round(H, 1), "tris", tris)


main()
