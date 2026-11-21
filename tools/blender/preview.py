# Quick lookdev render of exported assets in a row:  blender -b --python tools/blender/preview.py -- out.png a.gltf b.gltf ...
import bpy, sys, math
args = sys.argv[sys.argv.index("--") + 1:]
out, paths = args[0], args[1:]
bpy.ops.wm.read_factory_settings(use_empty=True)
x = 0.0
for p in paths:
    bpy.ops.import_scene.gltf(filepath=p)
    objs = [o for o in bpy.context.selected_objects if o.type == "MESH"]
    w = max(max(o.dimensions.x, o.dimensions.y) for o in objs)
    for o in objs:
        o.location.x += x + w / 2
    x += w + 1.0
bpy.ops.mesh.primitive_plane_add(size=200, location=(x / 2, 0, 0))
g = bpy.data.materials.new("ground"); g.use_nodes = True
g.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.12, 0.11, 0.08, 1)
bpy.context.object.data.materials.append(g)
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 4.0; sun.rotation_euler = (math.radians(50), 0, math.radians(35))
bpy.context.scene.collection.objects.link(sun)
w = bpy.data.worlds.new("w"); bpy.context.scene.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.68, 0.85, 1); w.node_tree.nodes["Background"].inputs[1].default_value = 0.8
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); bpy.context.scene.collection.objects.link(cam)
h = max(o.dimensions.z for o in bpy.context.scene.objects if o.type == "MESH" and o.name != "Plane")
dist = max(x, h * 1.6) * 0.95
cam.location = (x / 2, -dist, h * 0.45); cam.rotation_euler = (math.radians(88), 0, 0); cam.data.lens = 35
sc = bpy.context.scene; sc.camera = cam; sc.render.engine = "CYCLES"; sc.cycles.samples = 24; sc.cycles.device = "CPU"
sc.render.resolution_x, sc.render.resolution_y = 1400, 700
sc.view_settings.view_transform = "AgX"
sc.render.filepath = out
bpy.ops.render.render(write_still=True)
