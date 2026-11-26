# Prepares the Tripo AI models for tools/blender/gen_items.py (and the tower for gen_buildings.py).
#   blender -b --python tools/blender/prepare_tripo.py [-- item_id ...]
# The raw generations (~1.9 M triangles, ~59 MB each) stay in art_source/models/ (git-ignored); this writes a
# lighter copy of each, still well above the game's budget, to tools/blender/source/ so the item pipeline can be
# re-run from the repository alone.
import bpy, bmesh, json, os, sys
import numpy as np
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RAW = os.path.join(ROOT, "art_source", "models")
OUT = os.path.join(ROOT, "tools", "blender", "source")
# item -> (raw generation in art_source/models, source copy in tools/blender/source)
MODELS = {
    "stone_axe": ("tripo_stone_axe.glb", "SK_StoneAxe_Tripo.glb"),
    "spear": ("tripo_spear.glb", "SK_Spear_Tripo.glb"),
    "bow": ("tripo_bow.glb", "SK_Bow_Tripo.glb"),
    "tower": ("tripo_tower.glb", "SK_Tower_Tripo.glb"),  # lookout tower for gen_buildings.py (4.9 M tris raw)
    "hide_hut": ("tripo_hide_hut.glb", "SK_HideHut_Tripo.glb"),  # hide-and-pole dome hut (1 M tris raw)
}
TRIS = 60000
TRIS_FOR = {"tower": 45000, "hide_hut": 35000}


def cut_smoke(obj, path):
    """The hut generation has a sculpted smoke plume fused to the roof crown: delete everything above the
    crown's pole tips and the light grey (smoke-coloured) faces just below them. The game draws real smoke;
    its source (the middle of the cut, model space) goes to a JSON next to the output."""
    me = obj.data
    img = next(n.image for n in me.materials[0].node_tree.nodes if n.type == "TEX_IMAGE" and "base" in n.image.name)
    w, h = img.size
    px = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(px)
    px = px.reshape(h, w, 4)
    uv = me.uv_layers.active.data
    top = max(v.co.z for v in me.vertices)
    crown, cap = top * 0.71, top * 0.848  # the poles end at ~0.705 of the raw height, the plume tops at 1.0
    bm = bmesh.new()
    bm.from_mesh(me)
    uvl = bm.loops.layers.uv.active
    kill, src = [], []
    for f in bm.faces:
        c = f.calc_center_median()
        if c.z < crown:
            continue
        u = sum(l[uvl].uv.x for l in f.loops) / len(f.loops)
        v = sum(l[uvl].uv.y for l in f.loops) / len(f.loops)
        r, g, b = px[min(h - 1, int(v % 1.0 * h)), min(w - 1, int(u % 1.0 * w)), :3]
        grey = max(r, g, b) - min(r, g, b) < 0.08 and (r + g + b) / 3 > 0.38
        if c.z > cap or grey:
            kill.append(f)
            if c.z < cap + 0.04 * top:
                src.append(c)
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.to_mesh(me)
    bm.free()
    mid = sum(src, Vector()) / max(1, len(src))
    json.dump({"smoke": [mid.x, mid.y, min((c.z for c in src), default=crown)], "height": top},
              open(os.path.splitext(path)[0] + ".json", "w"))
    print("cut", len(kill), "smoke faces; source", tuple(round(x, 3) for x in mid))


CUTS = {"hide_hut": cut_smoke}


def prepare(item):
    raw, out = MODELS[item]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(RAW, raw))
    obj = next(o for o in bpy.data.objects if o.type == "MESH")
    for o in list(bpy.data.objects):
        if o is not obj:
            bpy.data.objects.remove(o, do_unlink=True)
    path = os.path.join(OUT, out)
    if item in CUTS:
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
        CUTS[item](obj, path)
    # glTF splits vertices along every UV seam; Tripo's atlas has so many that the mesh arrives as loose
    # triangles, and decimating loose triangles tears holes. Weld positions first (UVs live on face corners).
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bm.to_mesh(obj.data)
    bm.free()
    n = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    mod = obj.modifiers.new("dec", "DECIMATE")
    mod.ratio = min(TRIS_FOR.get(item, TRIS) / n, 1.0)
    mod.use_collapse_triangulate = True
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier="dec")
    obj.name = os.path.splitext(out)[0]
    obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_image_format="AUTO")
    print("wrote", path, sum(len(p.vertices) - 2 for p in obj.data.polygons), "triangles")


args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
for item in (args or list(MODELS)):
    prepare(item)
