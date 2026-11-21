# Batch-converts raw Poly Haven glTFs (art_source/models) into game-ready assets/models/<cat>/SM_*.gltf
#   blender -b --python tools/blender/process_props.py [-- only_id ...]
# - optional split per object ("each"), decimation to a triangle budget (Godot adds LODs on import)
# - origin at bottom-centre, +Y up (glTF), textures shared per category (assets/models/<cat>/textures)
import bpy, bmesh, os, sys, math, mathutils

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "art_source", "models")
OUT = os.path.join(ROOT, "assets", "models")

# (source id, output name pattern, mode "merge"|"each", triangle budget, uniform scale, category)
ASSETS = [
    ("boulder_01", "SM_Boulder_01", "merge", 6000, 1.0, "rocks"),
    ("rock_moss_set_01", "SM_RockMoss_A{i}", "each", 2500, 1.0, "rocks"),
    ("rock_moss_set_02", "SM_RockMoss_B{i}", "each", 2500, 1.0, "rocks"),
    ("rock_07", "SM_Stone_07", "merge", 900, 1.0, "rocks"),
    ("rock_09", "SM_Stone_09", "merge", 600, 1.0, "rocks"),
    ("stone_01", "SM_Stone_01", "merge", 900, 1.0, "rocks"),
    ("tree_stump_01", "SM_Stump_01", "merge", 4000, 1.0, "trees"),
    ("tree_stump_02", "SM_Stump_02", "merge", 4000, 1.0, "trees"),
    ("dead_tree_trunk", "SM_DeadTrunk_01", "merge", 5000, 1.0, "trees"),
    ("dry_branches_medium_01", "SM_Branches_{i}", "each", 3000, 1.0, "ground"),
    ("fern_02", "SM_Fern_{i}", "each", 2000, 1.0, "plants"),
    ("shrub_03", "SM_Shrub03_{i}", "each", 2500, 1.0, "plants"),
    ("shrub_04", "SM_Shrub04_01", "merge", 6000, 1.0, "plants"),
    ("grass_medium_01", "SM_Grass_{i}", "each", 500, 1.0, "plants"),
    ("wicker_basket_01", "SM_WickerBasket_01", "merge", 4000, 1.0, "props"),
    ("stone_fire_pit", "SM_StoneFirePit_01", "merge", 4000, 1.0, "props"),
]


def tri_count(obj):
    return sum(len(p.vertices) - 2 for p in obj.data.polygons)


def prepare(obj, budget, scale):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    # glTF import splits vertices at UV seams; weld them so decimation can collapse across seams.
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0002)
    bm.to_mesh(obj.data)
    bm.free()
    # Iterate: UV seams limit how much one collapse pass can remove.
    for _ in range(5):
        n = tri_count(obj)
        if n <= budget * 1.1:
            break
        mod = obj.modifiers.new("dec", "DECIMATE")
        mod.ratio = max(budget / n, 0.002)
        mod.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier=mod.name)
    if scale != 1.0:
        obj.scale = (scale,) * 3
        bpy.ops.object.transform_apply(scale=True)
    # origin at bottom centre (Blender is Z-up)
    vs = [v.co for v in obj.data.vertices]
    mn = mathutils.Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
    mx = mathutils.Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
    pivot = mathutils.Vector(((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mn.z))
    obj.data.transform(mathutils.Matrix.Translation(-pivot))
    obj.location = (0, 0, 0)
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(50))
    except Exception:
        bpy.ops.object.shade_smooth()
    return tri_count(obj), mx - mn


def export(obj, name, cat):
    d = os.path.join(OUT, cat)
    os.makedirs(d, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    obj.name = name
    bpy.ops.export_scene.gltf(filepath=os.path.join(d, name + ".gltf"), export_format="GLTF_SEPARATE",
                              export_texture_dir="textures", use_selection=True, export_image_format="AUTO",
                              export_apply=True, export_yup=True)
    # Foliage: alpha blending sorts badly in games → force alpha scissor (MASK).
    import json
    gp = os.path.join(d, name + ".gltf")
    g = json.load(open(gp))
    for m in g.get("materials", []):
        if m.get("alphaMode") == "BLEND":
            m["alphaMode"] = "MASK"
            m["alphaCutoff"] = 0.5
    json.dump(g, open(gp, "w"), indent=1)


def run(only):
    for src, pattern, mode, budget, scale, cat in ASSETS:
        if only and src not in only:
            continue
        bpy.ops.wm.read_factory_settings(use_empty=True)
        path = [os.path.join(SRC, src, f) for f in os.listdir(os.path.join(SRC, src)) if f.endswith(".gltf")][0]
        bpy.ops.import_scene.gltf(filepath=path)
        meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
        # Drop lower LODs shipped inside some sources.
        meshes = [o for o in meshes if "LOD" not in o.name or o.name.endswith("LOD0")]
        if mode == "merge" and len(meshes) > 1:
            bpy.ops.object.select_all(action="DESELECT")
            for o in meshes:
                o.select_set(True)
            bpy.context.view_layer.objects.active = meshes[0]
            bpy.ops.object.join()
            meshes = [bpy.context.view_layer.objects.active]
        meshes.sort(key=lambda o: o.name)
        for i, o in enumerate(meshes):
            name = pattern.format(i=f"{i + 1:02d}")
            t, size = prepare(o, budget, scale)
            export(o, name, cat)
            print("EXPORTED", cat, name, "tris", t, "size(xyz,Zup)", [round(x, 2) for x in size])


argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
run(set(argv))
