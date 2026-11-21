# Renders the application icon (1024 px): stone axe on a rounded charcoal tile with an ochre glow.
#   blender -b --python tools/blender/app_icon.py -- out.png
import bpy, sys, math, os, numpy as np
from mathutils import Vector
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
out = sys.argv[sys.argv.index("--") + 1]
S = 1024
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.join(ROOT, "assets/models/items/SM_Item_stone_axe.gltf"))
objs = [o for o in bpy.context.selected_objects if o.type == "MESH"]
for o in bpy.context.selected_objects:
    if o.parent is None:
        o.rotation_mode = "XYZ"  # glTF import uses quaternions
        o.rotation_euler = (0, math.radians(-45), 0)
bpy.context.view_layer.update()
corners = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
mn = Vector((min(c.x for c in corners), min(c.y for c in corners), min(c.z for c in corners)))
mx = Vector((max(c.x for c in corners), max(c.y for c in corners), max(c.z for c in corners)))
center = (mn + mx) / 2
size = (mx - mn).length
sc = bpy.context.scene
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam)
cam.data.type = "ORTHO"; cam.data.ortho_scale = size * 1.05
d = Vector((0, -1, 0.25)).normalized(); cam.location = center + d * size * 3
cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler(); sc.camera = cam
for rot, e in (((math.radians(40), math.radians(15), math.radians(-30)), 4.0), ((math.radians(-55), 0, math.radians(160)), 2.5)):
    l = bpy.data.objects.new("l", bpy.data.lights.new("l", "SUN")); l.data.energy = e; l.rotation_euler = rot; sc.collection.objects.link(l)
w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.42, 0.32, 1); w.node_tree.nodes["Background"].inputs[1].default_value = 0.6
sc.render.engine = "CYCLES"; sc.cycles.samples = 48; sc.cycles.device = "CPU"
sc.render.film_transparent = True; sc.render.resolution_x = sc.render.resolution_y = S
sc.view_settings.view_transform = "AgX"; sc.view_settings.look = "AgX - Medium High Contrast"
tmp = out + ".axe.png"; sc.render.filepath = tmp; sc.render.image_settings.file_format = "PNG"; sc.render.image_settings.color_mode = "RGBA"
bpy.ops.render.render(write_still=True)
axe = bpy.data.images.load(tmp); px = np.empty(S * S * 4, np.float32); axe.pixels.foreach_get(px); px = px.reshape(S, S, 4)
# Background: rounded square (macOS grid: 824 px tile, 100 px margin), charcoal with warm radial glow.
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
m, r = 100.0, 185.0
dx = np.maximum(np.maximum(m + r - xx, xx - (S - m - r)), 0); dy = np.maximum(np.maximum(m + r - yy, yy - (S - m - r)), 0)
inside = np.clip(r + 0.5 - np.sqrt(dx * dx + dy * dy), 0, 1)
dist = np.sqrt((xx - S * 0.5) ** 2 + (yy - S * 0.42) ** 2) / (S * 0.5)
lin = lambda c: np.array(c, np.float32)
charcoal, pine, ochre = lin((0.09, 0.106, 0.094)), lin((0.204, 0.282, 0.231)), lin((0.77, 0.6, 0.35))
bg = charcoal[None, None, :] * np.ones((S, S, 3), np.float32)
bg = bg + (pine - charcoal)[None, None, :] * np.clip(1 - dist, 0, 1)[..., None] * 0.9
bg = bg + ochre[None, None, :] * (np.clip(1 - dist * 1.4, 0, 1) ** 2)[..., None] * 0.45
a = px[..., 3:4] * inside[..., None]
rgb = px[..., :3] * a + bg * (1 - a)
res = np.concatenate([rgb, inside[..., None]], axis=2)
o = bpy.data.images.new("icon", S, S, alpha=True); o.pixels.foreach_set(res.ravel()); o.filepath_raw = out; o.file_format = "PNG"; o.save()
os.remove(tmp)
print("ICON", out)
