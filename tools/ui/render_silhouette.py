"""Renders a side-on silhouette of a game model (white on transparent) for the UI cave-painting art.

  /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -P tools/ui/render_silhouette.py -- in.gltf out.png [yaw_deg]
"""
import sys, math
import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
src, out = argv[0], argv[1]
yaw = math.radians(float(argv[2])) if len(argv) > 2 else 0.0

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
for o in bpy.context.scene.objects:
    if o.parent is None:
        o.rotation_mode = "XYZ"
        o.rotation_euler.z += yaw
bpy.context.view_layer.update()

lo = [1e9] * 3
hi = [-1e9] * 3
dg = bpy.context.evaluated_depsgraph_get()
for o in meshes:
    ev = o.evaluated_get(dg)
    m = ev.to_mesh()
    for v in m.vertices:
        p = o.matrix_world @ v.co
        for i in range(3):
            lo[i] = min(lo[i], p[i])
            hi[i] = max(hi[i], p[i])
    ev.to_mesh_clear()
cx, cy, cz = [(lo[i] + hi[i]) * 0.5 for i in range(3)]
w = hi[0] - lo[0]
h = hi[2] - lo[2]

cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
bpy.context.scene.collection.objects.link(cam)
cam.data.type = "ORTHO"
cam.data.ortho_scale = max(w, h) * 1.04
cam.location = (cx, cy - 50.0, cz)
cam.rotation_euler = (math.radians(90), 0, 0)
cam.data.clip_end = 200
sc = bpy.context.scene
sc.camera = cam
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "FLAT"
sc.display.shading.color_type = "SINGLE"
sc.display.shading.single_color = (1, 1, 1)
sc.render.film_transparent = True
sc.view_settings.view_transform = "Standard"
res = 1024
aspect = w / h
sc.render.resolution_x = res if aspect >= 1 else int(res * aspect)
sc.render.resolution_y = int(res / aspect) if aspect >= 1 else res
sc.render.filepath = out
sc.render.image_settings.file_format = "PNG"
sc.render.image_settings.color_mode = "RGBA"
bpy.ops.render.render(write_still=True)
print("SILHOUETTE", out, sc.render.resolution_x, sc.render.resolution_y)
