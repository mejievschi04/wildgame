# First-person right hand for held items, cut from the Homo sapiens model (the player's race):
#   blender -b --python tools/blender/gen_fp_hand.py
# The SapiensM rig is posed with the fingers curled into a fist around a handle, the forearm and hand are cut out
# of the evaluated body with the leather wrist wraps, and a fur cuff (a pelt sleeve with a ragged hem) is added
# around the forearm. The result is placed in the item convention used by HandModels: the handle runs along +Z
# through the fist (thumb side up), the grip centre at the origin, the forearm going back along -Y.
# Output: assets/models/humans/SM_FP_Hand_R.gltf (shares the humans/textures folder).
import bpy, bmesh, math, os, sys
from mathutils import Vector, Matrix

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import human_anim as ha
import bake_human_combat as bc

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HUM = os.path.join(ROOT, "assets", "models", "humans")
KEEP = {"lowerarm_r", "hand_r"} | {f"{f}_{i:02d}_r" for f in ("thumb", "index", "middle", "ring", "pinky") for i in (1, 2, 3)}
FOREARM = 0.24   # metres of forearm kept behind the wrist

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.join(HUM, "SK_Human_SapiensM.gltf"), bone_heuristic="BLENDER")
rig = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
rig.animation_data_clear()
body = ha.Body(rig)
rots = ha.relaxed(body, {}, fist_r=float(os.environ.get("FIST", "0.62")), fist_l=0.0, elbow=0)
for n in list(rots):
    if not n.endswith("_r") or not (n in KEEP):
        del rots[n]
for n in [k for k in rots if k.startswith("thumb")]:      # thumb wraps over the fingers
    rots[n] = rots[n] + [(ha.Z, float(os.environ.get("THUMB_Z", "30"))), (ha.X, float(os.environ.get("THUMB_X", "0")))]
bc.pose(rig, rots, (0, 0, 0))
bpy.context.view_layer.update()
pb = rig.pose.bones
M = rig.matrix_world
wrist = M @ pb["hand_r"].head
elbow = M @ pb["lowerarm_r"].head
knuckle_i = M @ pb["index_01_r"].head
knuckle_p = M @ pb["pinky_01_r"].head
mid_tip = M @ pb["middle_03_r"].tail
mid_base = M @ pb["middle_01_r"].head
# the fist's hole: halfway between the palm and the middle finger's second segment
palm = wrist.lerp(mid_base, 0.78)
grip = (palm + (M @ pb["middle_02_r"].head)) * 0.5
axis = (knuckle_i - knuckle_p).normalized()         # handle: from the little finger toward the thumb side
arm = (elbow - wrist)
arm = (arm - axis * arm.dot(axis)).normalized()     # forearm, perpendicular to the handle
side = axis.cross(arm).normalized()
# rows: world → item space (x = side, y = -arm, z = axis)
R = Matrix((side, -arm, axis)).to_4x4()
T = R @ Matrix.Translation(-grip)


def cut(obj, keep_fn):
    deps = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(deps)
    me = bpy.data.meshes.new_from_object(ev, preserve_all_data_layers=True, depsgraph=deps)
    me.transform(obj.matrix_world)
    groups = {g.index: g.name for g in obj.vertex_groups}
    bm = bmesh.new(); bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    src = obj.data
    kill = []
    for f in bm.faces:
        ok = True
        for v in f.verts:
            if not keep_fn(v.co, src.vertices[v.index], groups):
                ok = False
                break
        if not ok:
            kill.append(f)
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.to_mesh(me); bm.free()
    me.transform(T)
    o = bpy.data.objects.new(obj.name + "_FP", me)
    bpy.context.scene.collection.objects.link(o)
    return o


def arm_part(co, v, groups):
    best, bw = None, 0.0
    for g in v.groups:
        if g.weight > bw:
            best, bw = groups.get(g.group), g.weight
    if best not in KEEP:
        return False
    return (co - wrist).dot(arm) < FOREARM


def near_forearm(co, v, groups):
    d = (co - wrist).dot(arm)
    return -0.04 < d < FOREARM and ((co - wrist) - arm * d).length < 0.09


human = bpy.data.objects["Human"]
pieces = [cut(human, arm_part)]
for o in [o for o in bpy.context.scene.objects if o.type == "MESH" and o.name.startswith("Wrap")]:
    p = cut(o, near_forearm)
    if len(p.data.polygons):
        pieces.append(p)
    else:
        bpy.data.objects.remove(p)

# fur cuff: a pelt sleeve from mid-forearm back, fitted to the arm, with a ragged hem
fur_mat = next((m for m in bpy.data.materials if m.name.startswith("M_FurBase")), None)
arm_obj = pieces[0]
Tinv = T.inverted()
arm_pts = [Tinv @ v.co for v in arm_obj.data.vertices]
bm = bmesh.new()
segs, rings = 24, 5
for j in range(rings):
    t = j / (rings - 1)
    d = 0.10 + 0.15 * t
    c = wrist + arm * d
    near = [p for p in arm_pts if abs((p - wrist).dot(arm) - d) < 0.02]
    for i in range(segs):
        a = i / segs * math.tau
        u = side * math.cos(a) + axis * math.sin(a)
        reach = max([(p - c).dot(u) for p in near] or [0.05])
        rr = reach + 0.008 + 0.004 * t
        p = c + u * rr
        if j == 0:
            p += arm * (0.012 * math.sin(i * 2.3) * math.sin(i * 0.9))   # ragged hem
        bm.verts.new(p)
bm.verts.ensure_lookup_table()
uvl = bm.loops.layers.uv.new("UVMap")
for j in range(rings - 1):
    for i in range(segs):
        a, b = j * segs + i, j * segs + (i + 1) % segs
        f = bm.faces.new((bm.verts[a], bm.verts[a + segs], bm.verts[b + segs], bm.verts[b]))
        for lp, uv in zip(f.loops, [(i / segs, j / rings), (i / segs, (j + 1) / rings), ((i + 1) / segs, (j + 1) / rings), ((i + 1) / segs, j / rings)]):
            lp[uvl].uv = (uv[0] * 2.0, uv[1])
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
for f in bm.faces:   # recalc on an open tube may pick inward: force outward from the arm axis
    c = f.calc_center_median()
    radial = (c - wrist) - arm * (c - wrist).dot(arm)
    if f.normal.dot(radial) < 0:
        f.normal_flip()
me = bpy.data.meshes.new("Cuff"); bm.to_mesh(me); bm.free()
me.transform(T)
cuff = bpy.data.objects.new("Cuff_FP", me)
bpy.context.scene.collection.objects.link(cuff)
if fur_mat:
    cuff.data.materials.append(fur_mat)
pieces.append(cuff)

for o in pieces:
    for p in o.data.polygons:
        p.use_smooth = True
bpy.ops.object.select_all(action="DESELECT")
for o in pieces:
    o.select_set(True)
bpy.context.view_layer.objects.active = pieces[0]
bpy.ops.object.join()
out = bpy.context.view_layer.objects.active
out.name = "SM_FP_Hand_R"
path = os.path.join(HUM, "SM_FP_Hand_R.gltf")
bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="textures",
                          use_selection=True, export_yup=True, export_animations=False, export_skins=False)
print("FPHAND", path, "tris", sum(len(p.vertices) - 2 for p in out.data.polygons),
      "grip->wrist", round((wrist - grip).length, 3))
