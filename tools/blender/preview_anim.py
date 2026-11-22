# Contact sheet of an animation clip (side view, fixed camera, ground grid) for judging motion.
#   blender -b --python tools/blender/preview_anim.py -- out.png model.gltf clip [frames=8] [view=side|front]
import bpy, sys, math, os
import numpy as np
from mathutils import Vector

a = sys.argv[sys.argv.index("--") + 1:]
out, path, clip = a[0], a[1], a[2]
nfr = int(a[3]) if len(a) > 3 else 8
view = a[4] if len(a) > 4 else "side"
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
sc = bpy.context.scene
for o in list(sc.objects):
    if o.type == "MESH" and o.parent is None and not o.find_armature():
        bpy.data.objects.remove(o)
rig = next(o for o in sc.objects if o.type == "ARMATURE")
act = next((x for x in bpy.data.actions if x.name.startswith(clip)), None)
for t in rig.animation_data.nla_tracks:
    t.mute = True
rig.animation_data.action = act
if hasattr(rig.animation_data, "action_slot") and act.slots:
    rig.animation_data.action_slot = act.slots[0]
f0, f1 = act.frame_range
meshes = [o for o in sc.objects if o.type == "MESH"]
for o in meshes:
    if any(m and m.name.endswith("_Fur") for m in o.data.materials):
        o.hide_render = True  # silhouettes read better without cards
bpy.context.view_layer.update()
lo = Vector((1e9,) * 3); hi = Vector((-1e9,) * 3)
for o in meshes:
    for c in o.bound_box:
        w = o.matrix_world @ Vector(c); lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
size = hi - lo; c = (hi + lo) / 2
H = max(size.z, max(size.x, size.y))
# ground with 10 cm grid lines (to judge foot sliding)
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, lo.z))
g = bpy.data.materials.new("g"); g.use_nodes = True
N, L = g.node_tree.nodes, g.node_tree.links
chk = N.new("ShaderNodeTexChecker"); chk.inputs["Scale"].default_value = 200
chk.inputs["Color1"].default_value = (0.25, 0.25, 0.25, 1); chk.inputs["Color2"].default_value = (0.32, 0.32, 0.32, 1)
L.new(chk.outputs["Color"], N["Principled BSDF"].inputs["Base Color"])
bpy.context.object.data.materials.append(g)
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN")); sun.data.energy = 3
sun.rotation_euler = (math.radians(40), 0, math.radians(30)); sc.collection.objects.link(sun)
w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.55, 0.6, 1)
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam)
cam.data.type = "ORTHO"; cam.data.ortho_scale = H * 1.6
d = Vector((1, 0, 0)) if view == "side" else Vector((0, -1, 0))
cam.location = c + d * 10; cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
sc.camera = cam
sc.render.engine = "BLENDER_EEVEE" if "BLENDER_EEVEE" in [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items] else "CYCLES"
if sc.render.engine == "CYCLES":
    sc.cycles.samples = 8
sc.render.resolution_x, sc.render.resolution_y = 300, 420
tiles = []
for i in range(nfr):
    fr = f0 + (f1 - f0) * i / nfr
    sc.frame_set(int(fr), subframe=fr - int(fr))
    p = os.path.splitext(out)[0] + f"_{i}.png"
    sc.render.filepath = p
    bpy.ops.render.render(write_still=True)
    tiles.append(p)
ims = [bpy.data.images.load(t) for t in tiles]
W, Hh = ims[0].size
sheet = np.zeros((Hh, W * len(ims), 4), dtype=np.float32)
for i, im in enumerate(ims):
    sheet[:, i * W:(i + 1) * W] = np.array(im.pixels[:], dtype=np.float32).reshape(Hh, W, 4)
s = bpy.data.images.new("sheet", W * len(ims), Hh); s.pixels[:] = sheet.ravel()
s.filepath_raw = out; s.file_format = "PNG"; s.save()
for t in tiles:
    os.remove(t)
print("SHEET", clip, f0, f1, sc.render.engine)
