# Head close-ups of a human model: one render per facial expression (blend shapes), tiled into a sheet.
#   blender -b --python tools/blender/preview_face.py -- out.png SK_Human_X.gltf
import bpy, sys, math, os
import numpy as np
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
out, path = args[0], args[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
sc = bpy.context.scene
for o in list(sc.objects):
    if o.type == "MESH" and o.parent is None and not o.find_armature():
        bpy.data.objects.remove(o)
rig = next(o for o in sc.objects if o.type == "ARMATURE")
if rig.animation_data:
    for t in rig.animation_data.nla_tracks:
        t.mute = True
    rig.animation_data.action = None
for pb in rig.pose.bones:
    pb.rotation_quaternion = (1, 0, 0, 0); pb.location = (0, 0, 0)
bpy.context.view_layer.update()
hb = rig.pose.bones["head"]
head = rig.matrix_world @ hb.head
top = rig.matrix_world @ hb.tail
c = head + (top - head) * 0.55
# glTF import: character faces -Y in Blender (+Z glTF)?  find face direction from the eye objects
eyes = [o for o in sc.objects if o.type == "MESH" and "Eye" in o.name]
hide = os.environ.get("HIDE", "")
if hide:
    for o in list(sc.objects):
        if o.type == "MESH" and hide in o.name:
            bpy.data.objects.remove(o)
meshes = [o for o in sc.objects if o.type == "MESH"]
print("MESHES", [o.name for o in meshes])
body = next((o for o in meshes if o.data.shape_keys), max(meshes, key=lambda o: len(o.data.vertices)))
fwd = Vector((0, -1, 0))
if eyes:
    e = sum((o.matrix_world @ (sum((v.co for v in o.data.vertices), Vector()) / len(o.data.vertices)) for o in eyes), Vector()) / len(eyes)
    d = e - c; d.z = 0
    if d.length > 1e-3:
        fwd = d.normalized()
sun = bpy.data.objects.new("key", bpy.data.lights.new("key", "AREA")); sun.data.energy = 60; sun.data.size = 0.6
sun.location = c + fwd * 0.8 + Vector((0.5, 0, 0.5)); sun.rotation_euler = (c - sun.location).to_track_quat("-Z", "Y").to_euler()
fill = bpy.data.objects.new("fill", bpy.data.lights.new("fill", "AREA")); fill.data.energy = 18; fill.data.size = 1.0
fill.location = c + fwd * 0.8 + Vector((-0.6, 0, 0.1)); fill.rotation_euler = (c - fill.location).to_track_quat("-Z", "Y").to_euler()
rim = bpy.data.objects.new("rim", bpy.data.lights.new("rim", "AREA")); rim.data.energy = 30; rim.data.size = 0.5
rim.location = c - fwd * 0.7 + Vector((0, 0, 0.5)); rim.rotation_euler = (c - rim.location).to_track_quat("-Z", "Y").to_euler()
for l in (sun, fill, rim):
    sc.collection.objects.link(l)
w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.05, 0.05, 0.05, 1)
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam)
cam.data.lens = 85; sc.camera = cam
sc.render.engine = "CYCLES"; sc.cycles.samples = 40; sc.cycles.device = "CPU"
sc.render.resolution_x, sc.render.resolution_y = 420, 520
sc.view_settings.view_transform = "AgX"
keys = body.data.shape_keys.key_blocks if body.data.shape_keys else []
names = ["neutral"] + [k.name for k in keys if k.name.startswith("expr_")]
tiles = []
for i, nm in enumerate(names):
    for k in keys:
        k.value = 1.0 if k.name == nm else 0.0
    side = Vector((fwd.y, -fwd.x, 0)) * (0.35 if i == 0 else 0.12)
    cam.location = c + fwd * 0.75 + side + Vector((0, 0, 0.03))
    cam.rotation_euler = (c - cam.location).to_track_quat("-Z", "Y").to_euler()
    f = os.path.splitext(out)[0] + f"_{nm}.png"
    sc.render.filepath = f
    bpy.ops.render.render(write_still=True)
    tiles.append(f)
# tile into one sheet
ims = [bpy.data.images.load(t) for t in tiles]
W, H = ims[0].size
cols = 3
rows = math.ceil(len(ims) / cols)
sheet = np.zeros((rows * H, cols * W, 4), dtype=np.float32)
for i, im in enumerate(ims):
    px = np.array(im.pixels[:], dtype=np.float32).reshape(H, W, 4)
    r, cidx = i // cols, i % cols
    sheet[(rows - 1 - r) * H:(rows - r) * H, cidx * W:(cidx + 1) * W] = px
s = bpy.data.images.new("sheet", cols * W, rows * H)
s.pixels[:] = sheet.ravel()
s.filepath_raw = out; s.file_format = "PNG"; s.save()
print("FACES", names)
