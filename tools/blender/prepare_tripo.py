# Prepares the Tripo AI item models for tools/blender/gen_items.py.
#   blender -b --python tools/blender/prepare_tripo.py [-- item_id ...]
# The raw generations (~1.9 M triangles, ~59 MB each) stay in art_source/models/ (git-ignored); this writes a
# lighter copy of each, still well above the game's budget, to tools/blender/source/ so the item pipeline can be
# re-run from the repository alone.
import bpy, bmesh, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "art_source", "models")
OUT = os.path.join(ROOT, "tools", "blender", "source")
# item -> (raw generation in art_source/models, source copy in tools/blender/source)
MODELS = {
    "stone_axe": ("tripo_stone_axe.glb", "SK_StoneAxe_Tripo.glb"),
    "spear": ("tripo_spear.glb", "SK_Spear_Tripo.glb"),
    "bow": ("tripo_bow.glb", "SK_Bow_Tripo.glb"),
}
TRIS = 60000


def prepare(item):
    raw, out = MODELS[item]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(RAW, raw))
    obj = next(o for o in bpy.data.objects if o.type == "MESH")
    for o in list(bpy.data.objects):
        if o is not obj:
            bpy.data.objects.remove(o, do_unlink=True)
    # glTF splits vertices along every UV seam; Tripo's atlas has so many that the mesh arrives as loose
    # triangles, and decimating loose triangles tears holes. Weld positions first (UVs live on face corners).
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bm.to_mesh(obj.data)
    bm.free()
    n = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    mod = obj.modifiers.new("dec", "DECIMATE")
    mod.ratio = min(TRIS / n, 1.0)
    mod.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier="dec")
    obj.name = os.path.splitext(out)[0]
    obj.select_set(True)
    path = os.path.join(OUT, out)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_image_format="AUTO")
    print("wrote", path, sum(len(p.vertices) - 2 for p in obj.data.polygons), "triangles")


args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
for item in (args or list(MODELS)):
    prepare(item)
