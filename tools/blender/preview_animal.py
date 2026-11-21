# Lookdev render of an exported animal from several angles, optionally posed at a clip frame.
#   blender -b --python tools/blender/preview_animal.py -- out.png model.gltf [clip] [frame]
import bpy, sys, math
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
out, path = args[0], args[1]
clip = args[2] if len(args) > 2 else ""
frame = int(args[3]) if len(args) > 3 else 1
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
sc = bpy.context.scene
rig = next((o for o in sc.objects if o.type == "ARMATURE"), None)
if rig and rig.animation_data:
    acts = {a.name: a for a in bpy.data.actions}
    for t in rig.animation_data.nla_tracks:
        t.mute = True
    if clip:
        act = next((a for n, a in acts.items() if n.startswith(clip)), None)
        rig.animation_data.action = act
        if act and hasattr(rig.animation_data, "action_slot") and act.slots:
            rig.animation_data.action_slot = act.slots[0]
sc.frame_set(frame)
for o in list(sc.objects):
    if o.type == "MESH" and o.parent is None and not o.find_armature():
        bpy.data.objects.remove(o)  # stray add-on objects (MPFB injects an Icosphere)
meshes = [o for o in sc.objects if o.type == "MESH"]
for o in meshes:
    if "Fur" in o.name or any("Fur" in (m.name if m else "") for m in o.data.materials):
        o.visible_shadow = False  # matches the game: fur cards don't cast shadows
bpy.context.view_layer.update()
lo = Vector((1e9,) * 3); hi = Vector((-1e9,) * 3)
for o in meshes:
    for c in o.bound_box:
        w = o.matrix_world @ Vector(c)
        lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
size = (hi - lo)
center = (hi + lo) / 2
bpy.ops.mesh.primitive_plane_add(size=400, location=(0, 0, lo.z))
g = bpy.data.materials.new("ground"); g.use_nodes = True
gb = g.node_tree.nodes["Principled BSDF"]; gb.inputs["Base Color"].default_value = (0.16, 0.14, 0.1, 1); gb.inputs["Roughness"].default_value = 1
bpy.context.object.data.materials.append(g)
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 2.2; sun.data.angle = math.radians(4); sun.rotation_euler = (math.radians(45), math.radians(10), math.radians(-40))
sc.collection.objects.link(sun)
w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
sky = w.node_tree.nodes.new("ShaderNodeTexSky")
w.node_tree.links.new(sky.outputs[0], w.node_tree.nodes["Background"].inputs[0])
w.node_tree.nodes["Background"].inputs[1].default_value = 0.12
L = max(size.x, size.y, size.z)
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam)
cam.data.lens = 50
sc.camera = cam
sc.render.engine = "CYCLES"; sc.cycles.samples = 48; sc.cycles.device = "CPU"
sc.render.resolution_x, sc.render.resolution_y = 900, 620
sc.view_settings.view_transform = "AgX"
sc.render.film_transparent = False
import os
base, ext = os.path.splitext(out)
views = [("side", (1, 0.05, 0.12)), ("front34", (0.75, 0.75, 0.2)), ("back34", (-0.7, -0.75, 0.3))]
files = []
for name, d in views:
    dv = Vector(d).normalized()
    cam.location = center + dv * L * 2.3
    cam.rotation_euler = (center - cam.location).to_track_quat("-Z", "Y").to_euler()
    sc.render.filepath = f"{base}_{name}{ext}"
    bpy.ops.render.render(write_still=True)
    files.append(sc.render.filepath)
print("RENDERED", files)
