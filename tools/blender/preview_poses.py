# Lookdev of a rigged glTF in several clips:  blender -b --python tools/blender/preview_poses.py -- out.png model.gltf clip:frame ...
import bpy, sys, math
args = sys.argv[sys.argv.index("--") + 1:]
out, model, poses = args[0], args[1], args[2:]
bpy.ops.wm.read_factory_settings(use_empty=True)
for o in list(bpy.context.scene.objects):
    bpy.data.objects.remove(o)
x = 0.0
for spec in poses:
    clip, frame = spec.split(":")
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=model)
    new = [o for o in bpy.data.objects if o not in before]
    arm = next(o for o in new if o.type == "ARMATURE")
    root = arm
    while root.parent:
        root = root.parent
    root.location.x = x
    root.rotation_mode = "XYZ"
    root.rotation_euler.z = math.radians(35)
    act = bpy.data.actions.get(clip) or next(a for a in bpy.data.actions if a.name.startswith(clip))
    ad = arm.animation_data or arm.animation_data_create()
    for t in list(ad.nla_tracks):
        t.mute = True
    ad.action = act
    if hasattr(ad, "action_slot") and len(act.slots) > 0:
        ad.action_slot = act.slots[0]
    arm["frame"] = int(frame)
    x += 1.3
sc = bpy.context.scene
sc.frame_set(int(poses[0].split(":")[1]))
for o in bpy.data.objects:
    if o.type == "ARMATURE" and "frame" in o:
        pass
bpy.ops.mesh.primitive_plane_add(size=50, location=(x / 2, 0, 0))
sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN")); sun.data.energy = 3.5
sun.rotation_euler = (math.radians(50), 0, math.radians(30)); sc.collection.objects.link(sun)
w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.55, 0.62, 0.7, 1)
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam)
cam.location = (x / 2 - 0.65, -5.2, 1.2); cam.rotation_euler = (math.radians(88), 0, 0); cam.data.lens = 40
sc.camera = cam; sc.render.engine = "CYCLES"; sc.cycles.samples = 24; sc.cycles.device = "CPU"
sc.render.resolution_x, sc.render.resolution_y = 1500, 700
sc.view_settings.view_transform = "AgX"; sc.render.filepath = out
bpy.ops.render.render(write_still=True)
