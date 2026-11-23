"""Skeleton over a see-through body (side, front, top), to check that a rig sits inside its mesh.
  Blender -b --factory-startup -P tools/blender/preview_skeleton.py -- model.glb|gltf out_prefix
"""
import bpy, sys, math
from mathutils import Vector
a = sys.argv[sys.argv.index("--") + 1:]
path, out = a[0], a[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=path)
sc = bpy.context.scene
rig = next(o for o in sc.objects if o.type == "ARMATURE")
if rig.animation_data:
    for t in rig.animation_data.nla_tracks:
        t.mute = True
    rig.animation_data.action = None
for pb in rig.pose.bones:
    pb.rotation_mode = "XYZ"; pb.rotation_euler = (0, 0, 0); pb.location = (0, 0, 0); pb.rotation_quaternion = (1, 0, 0, 0)
bpy.context.view_layer.update()
meshes = [o for o in sc.objects if o.type == "MESH"]
ghost = bpy.data.materials.new("ghost"); ghost.use_nodes = True
ghost.diffuse_color = (0.75, 0.72, 0.68, 0.25)
for o in meshes:
    o.data.materials.clear(); o.data.materials.append(ghost)
bone_m = bpy.data.materials.new("bone"); bone_m.diffuse_color = (1.0, 0.45, 0.05, 1)
joint_m = bpy.data.materials.new("joint"); joint_m.diffuse_color = (0.9, 0.1, 0.05, 1)
lo = Vector((1e9,) * 3); hi = Vector((-1e9,) * 3)
for b in rig.pose.bones:
    for w in (rig.matrix_world @ b.head, rig.matrix_world @ b.tail):
        lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
pad = (hi - lo) * 0.12
lo -= pad; hi += pad
size = (hi - lo).length
r = size * 0.006
for b in rig.pose.bones:
    h = rig.matrix_world @ b.head; t = rig.matrix_world @ b.tail
    d = t - h
    bpy.ops.mesh.primitive_cylinder_add(vertices=8, radius=r, depth=max(d.length, 1e-4), location=(h + t) / 2)
    cy = bpy.context.object
    cy.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
    cy.data.materials.append(bone_m)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=10, ring_count=6, radius=r * 2.0, location=h)
    bpy.context.object.data.materials.append(joint_m)
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "STUDIO"
sc.display.shading.color_type = "MATERIAL"
sc.display.shading.show_xray = True
sc.display.shading.xray_alpha = 0.35
sc.render.resolution_x = 900; sc.render.resolution_y = 600
cam = bpy.data.objects.new("c", bpy.data.cameras.new("c")); sc.collection.objects.link(cam); sc.camera = cam
cam.data.type = "ORTHO"
ctr = (lo + hi) / 2
ext = hi - lo
for name, off, rot, scale in (("side", (10, 0, 0), (math.pi / 2, 0, math.pi / 2), max(ext.y, ext.z) * 1.15),
                              ("front", (0, -10, 0), (math.pi / 2, 0, 0), max(ext.x, ext.z) * 1.25),
                              ("top", (0, 0, 10), (0, 0, 0), max(ext.x, ext.y) * 1.15)):
    cam.location = ctr + Vector(off); cam.rotation_euler = rot; cam.data.ortho_scale = scale
    sc.render.filepath = f"{out}_{name}.png"
    bpy.ops.render.render(write_still=True)
