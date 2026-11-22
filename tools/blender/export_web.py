# Web-preview copies of the animal models: one self-contained .glb per species, textures downsized to
# 1024 px (fur atlases 512 px) and stored as JPEG (alpha atlases stay PNG).
#   blender -b --python tools/blender/export_web.py -- <out_dir> [Wolf Bear ...]
import bpy, os, sys, glob

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "assets", "models", "animals")
args = sys.argv[sys.argv.index("--") + 1:]
out = args[0]
names = args[1:] or [os.path.basename(p)[3:-5] for p in sorted(glob.glob(os.path.join(SRC, "SK_*.gltf")))]
os.makedirs(out, exist_ok=True)
for nm in names:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, f"SK_{nm}.gltf"))
    for img in bpy.data.images:
        if img.size[0] == 0:
            continue
        target = 512 if img.name.endswith("_fur") or "fur" in img.name.lower() else 1024
        if img.size[0] > target:
            img.scale(target, target)
    rig = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
    bpy.ops.object.select_all(action="DESELECT")
    rig.select_set(True)
    for o in bpy.context.scene.objects:
        if o.parent == rig:
            o.select_set(True)
    bpy.context.view_layer.objects.active = rig
    path = os.path.join(out, f"{nm}.glb")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_yup=True,
                              export_animations=True, export_animation_mode="ACTIONS", export_skins=True,
                              export_image_format="JPEG", export_jpeg_quality=82)
    print("WEB", nm, round(os.path.getsize(path) / 1e6, 2), "MB", "actions", len(bpy.data.actions))
