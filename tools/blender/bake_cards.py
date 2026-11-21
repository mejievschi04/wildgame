# Renders foliage card atlases (RGBA albedo) from CC0 scanned plants:
#   blender -b --python tools/blender/bake_cards.py
# Output: assets/models/trees/textures/T_<Name>Card_D.png
import bpy, bmesh, os, mathutils

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "art_source", "models")
OUT = os.path.join(ROOT, "assets", "models", "trees", "textures")
os.makedirs(OUT, exist_ok=True)

# name, source, object, keep-region (fractions of bbox: xmin, xmax, zmin, zmax), resolution
CARDS = [
    ("FirTwig", "fir_sapling", "fir_sapling_a", (0.55, 1.0, 0.30, 0.62), (1024, 1024)),
    ("PineTwig", "pine_sapling_small", "pine_sapling_small_a", (0.52, 1.0, 0.55, 0.85), (1024, 1024)),
    ("Leaves", "shrub_04", "shrub_04", (0.0, 1.0, 0.0, 1.0), (1024, 256)),
]


def load(src):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    d = os.path.join(SRC, src)
    bpy.ops.import_scene.gltf(filepath=os.path.join(d, [f for f in os.listdir(d) if f.endswith(".gltf")][0]))


def albedo_emission(obj):
    # Unlit albedo: replace each material's output with Emission(base color) and keep its alpha.
    for slot in obj.material_slots:
        m = slot.material
        nt = m.node_tree
        bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
        out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
        emis = nt.nodes.new("ShaderNodeEmission")
        mix = nt.nodes.new("ShaderNodeMixShader")
        transp = nt.nodes.new("ShaderNodeBsdfTransparent")
        col_in = bsdf.inputs["Base Color"]
        if col_in.links:
            nt.links.new(col_in.links[0].from_socket, emis.inputs["Color"])
        else:
            emis.inputs["Color"].default_value = col_in.default_value
        a_in = bsdf.inputs["Alpha"]
        if a_in.links:
            nt.links.new(a_in.links[0].from_socket, mix.inputs["Fac"])
        else:
            mix.inputs["Fac"].default_value = 1.0
        nt.links.new(transp.outputs[0], mix.inputs[1])
        nt.links.new(emis.outputs[0], mix.inputs[2])
        nt.links.new(mix.outputs[0], out.inputs["Surface"])


for name, src, objname, region, res in CARDS:
    load(src)
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    keep = next(o for o in objs if o.name == objname)
    for o in objs:
        if o != keep:
            bpy.data.objects.remove(o)
    bpy.context.view_layer.objects.active = keep
    keep.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    vs = [v.co for v in keep.data.vertices]
    mn = mathutils.Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
    mx = mathutils.Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
    size = mx - mn
    x0, x1 = mn.x + size.x * region[0], mn.x + size.x * region[1]
    z0, z1 = mn.z + size.z * region[2], mn.z + size.z * region[3]
    bm = bmesh.new()
    bm.from_mesh(keep.data)
    kill = [f for f in bm.faces if not (x0 <= f.calc_center_median().x <= x1 and z0 <= f.calc_center_median().z <= z1)]
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bm.to_mesh(keep.data)
    bm.free()
    vs = [v.co for v in keep.data.vertices]
    mn = mathutils.Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
    mx = mathutils.Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
    albedo_emission(keep)
    # Ortho camera looking down -Z; card U runs along X (branch base at the left edge).
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    w, h = mx.x - mn.x, mx.y - mn.y
    aspect = res[0] / res[1]
    cam_data.ortho_scale = max(w, h * aspect) * 1.02
    cam = bpy.data.objects.new("cam", cam_data)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = ((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, mx.z + 2.0)
    cam.rotation_euler = (0, 0, 0)
    sc = bpy.context.scene
    sc.camera = cam
    sc.render.engine = "CYCLES"
    sc.cycles.samples = 16
    sc.cycles.device = "CPU"
    sc.render.film_transparent = True
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    sc.view_settings.view_transform = "Standard"
    sc.render.filepath = os.path.join(OUT, f"T_{name}Card_D.png")
    bpy.ops.render.render(write_still=True)
    print("CARD", name, "region size", [round(x, 2) for x in (mx - mn)])
