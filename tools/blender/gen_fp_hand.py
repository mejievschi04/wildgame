# First-person right hand for held items, cut from the Homo sapiens model (the player's race):
#   blender -b --python tools/blender/gen_fp_hand.py
# The SapiensM rig is posed with the fingers curled into a fist around a handle, the forearm and hand are cut out
# of the evaluated body with the leather wrist wraps, and a fur cuff (a pelt sleeve with a ragged hem) is added
# around the forearm. The result is placed in the item convention used by HandModels: the handle runs along +Z
# through the fist (thumb side up), the grip centre at the origin, the forearm going back along -Y.
# Output: assets/models/humans/SM_FP_Hand_R.gltf (shares the humans/textures folder).
import bpy, bmesh, math, os, sys
from mathutils import Vector, Matrix, Quaternion

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import human_anim as ha
import fp_hand_skin
import bake_human_combat as bc

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HUM = os.path.join(ROOT, "assets", "models", "humans")
KEEP = {"upperarm_r", "lowerarm_r", "hand_r"} | {f"{f}_{i:02d}_r" for f in ("thumb", "index", "middle", "ring", "pinky") for i in (1, 2, 3)}
FOREARM = 0.44   # metres of arm kept behind the wrist: past the elbow, so the cut end stays out of view

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=os.path.join(HUM, "SK_Human_SapiensM.gltf"), bone_heuristic="BLENDER")
rig = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
rig.animation_data_clear()
body = ha.Body(rig)
rots = ha.relaxed(body, {}, fist_r=float(os.environ.get("FIST", "0.62")), fist_l=0.0, elbow=0)
for n in list(rots):
    if not n.endswith("_r") or not (n in KEEP):
        del rots[n]
bc.pose(rig, rots, (0, 0, 0))
bpy.context.view_layer.update()
pb = rig.pose.bones
M = rig.matrix_world


def aim_tail(bone, target):
    """Rotate a pose bone so its tail points at target (armature space)."""
    present = bone.matrix.to_quaternion()
    desired = (bone.tail - bone.head).rotation_difference(target - bone.head) @ present
    rest = bone.parent.bone.matrix_local.inverted() @ bone.bone.matrix_local
    bone.rotation_quaternion = rest.to_quaternion().inverted() @ bone.parent.matrix.to_quaternion().inverted() @ desired
    bpy.context.view_layer.update()


def wrap_thumb():
    """Close the thumb around the handle (a power grip): the first segment swings across the front of the fist,
    the outer two curl down so the tip rests on the index finger's middle segment."""
    idx1 = pb["index_01_r"].head.copy()
    idx2 = pb["index_02_r"].head.copy()
    idx3 = pb["index_03_r"].head.copy()
    palm_c = (pb["hand_r"].head + pb["middle_01_r"].head) * 0.5
    out = (idx2 - palm_c).normalized()                    # from the palm out over the fingers
    rest_spot = idx2.lerp(idx3, 0.35) + out * 0.014        # on top of the index finger's middle segment
    t1, t2, t3 = pb["thumb_01_r"], pb["thumb_02_r"], pb["thumb_03_r"]
    l2 = (t2.tail - t2.head).length
    l3 = (t3.tail - t3.head).length
    # where the thumb's middle joint goes: on the far side of the handle, before the tip
    knuckle = idx1.lerp(idx2, 0.55) + out * 0.028
    aim_tail(t1, knuckle)
    aim_tail(t2, t2.head + (rest_spot - t2.head).normalized() * l2 * 1.0 + (rest_spot - t2.head) * 0.0)
    aim_tail(t3, rest_spot)


HANDLE_R = 0.020    # radius of a tool handle
SKIN = 0.011        # finger joint centre to the skin of the palm side


def wrap_fingers():
    """A power grip: the handle lies across the palm, diagonally from the base of the index finger to the heel
    of the hand under the little finger, and each finger wraps round it. Each finger's joints are put on a
    circle around the handle axis (chords of the segment lengths) and the phalanges are aimed at them.
    Returns the handle axis (armature space): a point on it under the middle finger and its direction, and the
    palm normal."""
    hand = pb["hand_r"].head
    fdir = (pb["middle_01_r"].head - hand).normalized()
    across = (pb["index_01_r"].head - pb["pinky_01_r"].head).normalized()
    # the relaxed fist curls the fingertips towards the palm: that side is where the handle goes
    curl = pb["middle_03_r"].tail - pb["middle_01_r"].head
    palm_n = across.cross(fdir).normalized()
    if palm_n.dot(curl) < 0:
        palm_n = -palm_n
    axis_dir = (across + fdir * 0.28).normalized()           # index end further out: the grip is diagonal
    centre = pb["middle_01_r"].head + palm_n * (SKIN + HANDLE_R) - fdir * 0.012
    for f in ("index", "middle", "ring", "pinky"):
        bones = [pb[f"{f}_{i:02d}_r"] for i in (1, 2, 3)]
        k = bones[0].head.copy()
        c = centre + axis_dir * (k - centre).dot(axis_dir)    # nearest point of the handle axis
        v0 = k - c
        radius = max(v0.length, HANDLE_R + SKIN)
        sense = 1.0 if axis_dir.cross(v0).dot(fdir) > 0 else -1.0
        angle = 0.0
        for b in bones:
            seg = (b.tail - b.head).length
            angle += 2 * math.asin(min(1.0, seg / (2 * radius))) * 1.04   # a little tighter: skin presses in
            aim_tail(b, c + Quaternion(axis_dir, sense * angle) @ v0)
    return centre, axis_dir, palm_n


handle_centre, handle_dir, palm_normal = wrap_fingers()
wrap_thumb()
wrist = M @ pb["hand_r"].head
elbow = M @ pb["lowerarm_r"].head
# the handle passes through the fist along the axis the fingers were wrapped around
grip = M @ handle_centre
axis = (M.to_3x3() @ handle_dir).normalized()       # handle: from the little finger toward the thumb side
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
    # wraps stop at the wrist: their strap ends reach over the back of the hand and stretch into thin threads
    # once the fingers close
    d = (co - wrist).dot(arm)
    return 0.012 < d < FOREARM and ((co - wrist) - arm * d).length < 0.09


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
if os.environ.get("CUFF") == "1":   # the open pelt tube reads as a black pipe in the view: bare forearm by default
    pieces.append(cuff)
else:
    bpy.data.objects.remove(cuff)

# skin and musculature: landmarks in item space, then subdivide, shape and bake (fp_hand_skin.py)
marks = {"wrist": T @ wrist, "elbow": T @ elbow}
for f in ("thumb", "index", "middle", "ring", "pinky"):
    for i in (1, 2, 3):
        marks[f"{f}{i}"] = T @ (M @ pb[f"{f}_{i:02d}_r"].head)
    marks[f"{f}tip"] = T @ (M @ pb[f"{f}_03_r"].tail)
dorsal = -(T.to_3x3() @ (M.to_3x3() @ palm_normal)).normalized()
thumb_side = (T.to_3x3() @ axis).normalized()
if os.environ.get("PLAIN_SKIN") != "1":
    fp_hand_skin.detail(pieces[0], fp_hand_skin.Frame(marks, dorsal, thumb_side), os.path.join(HUM, "textures"))

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
