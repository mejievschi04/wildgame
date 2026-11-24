"""Puts a rigged quadruped sculpt into a symmetric standing stance and saves the posed mesh (no rig) for re-rigging.

  Blender -b --factory-startup -P tools/blender/neutral_stance.py -- rigged.glb out.glb [narrow=0.85]

AI sculpts come mid-stride: paws staggered and splayed. Each paw is moved to its pair's mean position (front pair,
hind pair; same distance from the midline on both sides, times `narrow`). The move spreads up the leg with the leg's
own skin weights and fades out towards the shoulder / hip, so the leg leans to the new foot instead of tearing.
"""
import bpy, sys, math
import numpy as np
from mathutils import Vector

a = sys.argv[sys.argv.index("--") + 1:]
src, dst = a[0], a[1]
narrow = float(a[2].split("=")[1]) if len(a) > 2 else 0.85

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
rig = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
body = max((o for o in bpy.context.scene.objects if o.type == "MESH"), key=lambda o: len(o.data.vertices))
if rig.animation_data:
    for t in rig.animation_data.nla_tracks:
        t.mute = True
    rig.animation_data.action = None
for pb in rig.pose.bones:
    pb.matrix_basis.identity()
bpy.context.view_layer.update()


def joint(bone, end="tail"):
    b = rig.data.bones[bone]
    return np.array((rig.matrix_world @ (b.tail_local if end == "tail" else b.head_local))[:])


P = np.array([(body.matrix_world @ v.co)[:] for v in body.data.vertices])
gid = {g.name: g.index for g in body.vertex_groups}
W = {}
for name in gid:
    W[name] = np.zeros(len(P))
for i, v in enumerate(body.data.vertices):
    for g in v.groups:
        W[body.vertex_groups[g.group].name][i] = g.weight

legs = {"f": ("scapula", "upperarm", "forearm", "hoof_f", "hoof_f_toe"), "h": ("thigh", "shin", "hoof_h", "hoof_h_toe")}
D = np.zeros_like(P)
for leg, chain in legs.items():
    foot_bone = "hoof_f" if leg == "f" else "hoof_h"
    feet = {s: joint(f"{foot_bone}.{s}") for s in ("L", "R")}
    ymean = (feet["L"][1] + feet["R"][1]) / 2
    xspan = (abs(feet["L"][0]) + abs(feet["R"][0])) / 2 * narrow
    for s, sx in (("L", 1), ("R", -1)):
        target = np.array((sx * xspan, ymean, feet[s][2]))
        d = target - feet[s]
        d[2] = 0.0
        top = joint(f"{chain[1]}.{s}", "head")[2]          # shoulder / hip joint height
        w = sum(W.get(f"{b}.{s}", 0) for b in chain)
        fall = np.clip(1.0 - P[:, 2] / max(top, 1e-6), 0.0, 1.0)
        fall = fall * fall * (3 - 2 * fall)
        D += np.outer(np.clip(w, 0, 1) * fall, d)
        print("STANCE", leg + s, "foot moved by", np.round(d, 3))

for o in list(bpy.context.scene.objects):
    if o != body:
        bpy.data.objects.remove(o)
body.modifiers.clear()
body.parent = None
inv = body.matrix_world.inverted()
for v, p in zip(body.data.vertices, P + D):
    v.co = inv @ Vector(p)
body.vertex_groups.clear()
body.data.update()
bpy.ops.object.select_all(action="DESELECT")
body.select_set(True)
bpy.ops.export_scene.gltf(filepath=dst, use_selection=True, export_format="GLB", export_yup=True)
print("WROTE", dst)
