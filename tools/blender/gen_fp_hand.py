# First-person hands for held items: a detailed MakeHuman (MPFB, CC0 base mesh) forearm and hand with real fingers,
# closed round the handle of the held tool by collision (each finger curls joint by joint until it touches the
# handle), then textured with baked detail: skin tone matched to the player's body, pores and knuckle wrinkles in
# the normal map, nails, redder knuckles and fingertips, dirt worked into the creases, a wound leather wrist wrap.
#   blender -b --python tools/blender/gen_fp_hand.py [-- --preview out.png] [-- --stage pose]
# Item convention used by HandModels: the handle runs along +Y (glTF) through the fist, index/thumb side toward
# +Y (the tool's head), the grip centre at the origin, the forearm going back along +Z.
# Output: assets/models/humans/SM_FP_Hand_R.gltf and its mirror SM_FP_Hand_L.gltf (+ .bin), textures
# T_FP_Hand_{albedo,normal,rough}.png in humans/textures; the wrap uses Poly Haven's brown_leather (CC0).
import bpy, bmesh, json, math, os, shutil, sys, tempfile
import numpy as np
from mathutils import Matrix, Vector, Quaternion

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
HUM = os.path.join(ROOT, "assets", "models", "humans")
TEXSRC = os.path.join(ROOT, "art_source", "textures")
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
PREVIEW = ARGS[ARGS.index("--preview") + 1] if "--preview" in ARGS else ""
STAGE = ARGS[ARGS.index("--stage") + 1] if "--stage" in ARGS else "all"

HANDLE_R = 0.021     # handle radius the fist closes round (stone axe 0.020, its binding 0.026; club 0.019)
CONTACT = 0.0015     # skin rests this far off the handle
FOREARM = 0.21       # metres of forearm kept behind the wrist, short of the elbow (its bulge in the rest pose)
FOREARM_EXT = 0.30   # ... then carried on straight, widening a little, so the cut end stays out of view
TEX = 2048
def lin(c):
    """sRGB (as picked from a texture) -> linear, which is what shader colours are in."""
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


# Skin of the player's body (T_Human_SapiensM_body averaged over the old hand, sRGB): sun-browned
SKIN = lin((0.469, 0.306, 0.229))
FINGERS = ["index", "middle", "ring", "pinky"]
# Curl ratio of the three joints while closing (knuckle, middle, tip) and their limits (degrees)
RATIO = (0.8, 1.5, 0.9)
THUMB_LIFT = float(ARGS[ARGS.index("--lift") + 1]) if "--lift" in ARGS else 0.017
LIMIT = (95.0, 110.0, 80.0)


# ---------------------------------------------------------------- body

def make_body():
    from bl_ext.blender_org.mpfb.services.humanservice import HumanService
    from bl_ext.blender_org.mpfb.services.targetservice import TargetService
    d = TargetService.get_default_macro_info_dict()
    # a strong man who works with his hands
    d.update({"gender": 1.0, "age": 0.5, "muscle": 0.78, "weight": 0.55, "proportions": 0.6,
              "race": {"african": 0.3, "caucasian": 0.45, "asian": 0.25}})
    body = HumanService.create_human(scale=0.1, macro_detail_dict=d)
    rig = HumanService.add_builtin_rig(body, "game_engine")
    bpy.context.view_layer.objects.active = body
    if body.data.shape_keys:
        body.shape_key_add(name="final", from_mix=True)
        final = body.data.shape_keys.key_blocks["final"]
        for v, k in zip(body.data.vertices, final.data):
            v.co = k.co
        body.shape_key_clear()
    for mod in list(body.modifiers):
        if mod.type == "MASK":
            body.modifiers.remove(mod)
    return body, rig


def bone_head(rig, name):
    return rig.matrix_world @ rig.data.bones[name].head_local


def cut_arm(body, rig):
    """Right forearm + hand only (helpers dropped), each vertex tagged with its dominant bone."""
    gidx = {g.index: g.name for g in body.vertex_groups}
    wrist, elbow = bone_head(rig, "hand_r"), bone_head(rig, "lowerarm_r")
    arm = (elbow - wrist).normalized()
    keep_bones = {"lowerarm_r", "hand_r"} | {f"{f}_0{i}_r" for f in FINGERS + ["thumb"] for i in (1, 2, 3)}
    bm = bmesh.new()
    bm.from_mesh(body.data)
    deform = bm.verts.layers.deform.active
    ok = set()
    for v in bm.verts:
        w = v[deform]
        names = {gidx[i] for i in w.keys()}
        if "body" not in names:
            continue
        best = max(((gidx[i], x) for i, x in w.items() if gidx[i] in keep_bones), key=lambda e: e[1], default=(None, 0))[0]
        p = body.matrix_world @ v.co
        if best and (p - wrist).dot(arm) < FOREARM and (p - wrist).length < FOREARM + 0.05:
            ok.add(v.index)
    kill = [f for f in bm.faces if not all(v.index in ok for v in f.verts)]
    bmesh.ops.delete(bm, geom=kill, context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    me = bpy.data.meshes.new("SM_FP_Hand_R")
    bm.to_mesh(me)
    bm.free()
    hand = bpy.data.objects.new("SM_FP_Hand_R", me)
    bpy.context.scene.collection.objects.link(hand)
    hand.matrix_world = body.matrix_world
    for g in body.vertex_groups:
        hand.vertex_groups.new(name=g.name)
    # vertex groups survive bm.to_mesh through the deform layer
    mod = hand.modifiers.new("arm", "ARMATURE")
    mod.object = rig
    bpy.data.objects.remove(body, do_unlink=True)
    return hand


def dominant(hand):
    gidx = {g.index: g.name for g in hand.vertex_groups}
    out = []
    for v in hand.data.vertices:
        best, bw = None, 0.0
        for g in v.groups:
            n = gidx.get(g.group, "")
            if n.endswith("_r") and g.weight > bw:
                best, bw = n, g.weight
        out.append(best)
    return out


def posed_coords(hand):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = hand.evaluated_get(dg)
    me = ev.to_mesh()
    co = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", co)
    ev.to_mesh_clear()
    co = co.reshape(-1, 3)
    mw = np.array(hand.matrix_world)
    return co @ mw[:3, :3].T + mw[:3, 3]


# ---------------------------------------------------------------- the grip

class Grip:
    def __init__(self, rig, hand):
        self.rig = rig
        H = lambda n: bone_head(rig, n)
        self.wrist, self.elbow = H("hand_r"), H("lowerarm_r")
        self.fdir = (H("middle_01_r") - self.wrist).normalized()
        self.across = (H("index_01_r") - H("pinky_01_r")).normalized()
        self.n = self.across.cross(self.fdir).normalized()          # palm side (right hand)
        dom = dominant(hand)
        co = posed_coords(hand)
        # check the palm side: the finger pads sit a little toward the palm of the knuckle line
        self.axis = (self.across + self.fdir * 0.28).normalized()
        knuck = (H("index_01_r") + H("middle_01_r") + H("ring_01_r") + H("pinky_01_r")) / 4
        # the handle lies in the crease where the fingers meet the palm, pressed into it a little
        c0 = knuck - self.fdir * 0.012
        # against the palm (the fingers are opened off it first if they get in the way, then close on it)
        pts = np.array([c for c, d in zip(co, dom) if d == "hand_r"])
        # only the strip of palm the handle lies across (the thumb's ball and the heel of the hand may bulge round it)
        perp = (self.fdir - self.axis * self.fdir.dot(self.axis)).normalized()
        pts = pts[np.abs((pts - np.array(c0)) @ np.array(perp)) < 0.014]
        h = 0.0
        while True:
            self.point = c0 + self.n * h
            if self.dist(pts).min() >= HANDLE_R + CONTACT or h > 0.12:
                break
            h += 0.001
        print("FPHAND handle off the knuckle line", round(h, 4))

    def dist(self, co):
        """Distance of points (N,3) from the handle axis."""
        a = np.array(self.axis)
        d = co - np.array(self.point)
        d = d - np.outer(d @ a, a)
        return np.linalg.norm(d, axis=1)


def pose_bone_rot(rig, name, axis_world, deg):
    pb = rig.pose.bones[name]
    b = rig.data.bones[name]
    k = (b.matrix_local.to_3x3().inverted() @ axis_world).normalized()
    pb.rotation_mode = "QUATERNION"
    pb.rotation_quaternion = Quaternion(k, math.radians(deg))


def close_chain(rig, hand, grip, chain, axis, ratio, limit, dom, step=2.0):
    """Curls a finger chain round the handle: all joints close together; when a segment touches the handle it and
    the joints before it stop, the rest carry on."""
    # contact is judged on the outer part of each segment, not the joint it shares with the one before
    co0 = posed_coords(hand)
    seg_idx = []
    for i, name in enumerate(chain):
        b = rig.data.bones[name]
        h, t = np.array(rig.matrix_world @ b.head_local), np.array(rig.matrix_world @ b.tail_local)
        d = t - h
        ix = np.array([k for k, dd in enumerate(dom) if dd == name])
        if len(ix):
            along = ((co0[ix] - h) @ d) / max(float(d @ d), 1e-9)
            ix = ix[along > 0.35]
        seg_idx.append(ix)
    ang = [0.0, 0.0, 0.0]
    active = [True, True, True]
    co = posed_coords(hand)
    last = [grip.dist(co[ix]).min() if len(ix) else 1.0 for ix in seg_idx]
    print("FPHAND start", chain[0], [round(x, 4) for x in last], [len(ix) for ix in seg_idx])
    # a finger that already lies in the handle's way opens first, all its joints together, until clear
    for it in range(30):
        if min(last) >= HANDLE_R + CONTACT:
            break
        for i in range(3):
            ang[i] -= 2.0
        for i, name in enumerate(chain):
            pose_bone_rot(rig, name, axis, ang[i])
        bpy.context.view_layer.update()
        co = posed_coords(hand)
        last = [grip.dist(co[ix]).min() if len(ix) else 1.0 for ix in seg_idx]
    for it in range(200):
        if not any(active):
            break
        prev = list(ang)
        for i in range(3):
            if active[i]:
                ang[i] = min(ang[i] + step * ratio[i], limit[i])
                if ang[i] >= limit[i]:
                    active[i] = False
        for i, name in enumerate(chain):
            pose_bone_rot(rig, name, axis, ang[i])
        bpy.context.view_layer.update()
        co = posed_coords(hand)
        hit = -1
        for i in range(3):
            if not len(seg_idx[i]):
                continue
            m = grip.dist(co[seg_idx[i]]).min()
            # touching: within reach of the handle and still closing on it (a thumb that starts against it
            # may slide round it, but never into it)
            if m < HANDLE_R + CONTACT and m < last[i] - 1e-5:
                hit = max(hit, i)
            last[i] = m
        if hit >= 0:
            for i in range(hit + 1):
                if active[i] or ang[i] != prev[i]:
                    ang[i] = prev[i]
                active[i] = False
            for i, name in enumerate(chain):
                pose_bone_rot(rig, name, axis, ang[i])
            bpy.context.view_layer.update()
    return ang


def close_hand(rig, hand, grip):
    dom = dominant(hand)
    for f in FINGERS:
        chain = [f"{f}_0{i}_r" for i in (1, 2, 3)]
        d = (bone_head(rig, chain[1]) - bone_head(rig, chain[0])).normalized()
        axis = d.cross(grip.n).normalized()        # rotating about it swings the tip toward the palm
        a = close_chain(rig, hand, grip, chain, axis, RATIO, LIMIT, dom)
        print("FPHAND", f, [round(x) for x in a])
    # the thumb closes over the fingers: IK brings its tip onto the back of the curled index finger just past the
    # middle joint, where a thumb rests in a power grip; its base (the metacarpal, in the palm) stays stiff so the
    # palm does not crumple
    bpy.context.view_layer.update()
    mw = rig.matrix_world
    pip = mw @ rig.pose.bones["index_02_r"].head
    dip = mw @ rig.pose.bones["index_03_r"].head
    mid = pip * 0.65 + dip * 0.35
    out = mid - grip.point
    out = (out - grip.axis * out.dot(grip.axis)).normalized()
    target_p = mid + out * THUMB_LIFT   # resting on the finger, not sunk into it
    tgt = bpy.data.objects.new("thumb_target", None)
    bpy.context.scene.collection.objects.link(tgt)
    tgt.location = target_p
    chain = ("thumb_01_r", "thumb_02_r", "thumb_03_r")
    for n in chain:
        rig.pose.bones[n].rotation_mode = "QUATERNION"
    base = rig.pose.bones["thumb_01_r"]
    base.ik_stiffness_x = base.ik_stiffness_y = base.ik_stiffness_z = 0.97   # its skin folds if it turns much
    rig.pose.bones["thumb_02_r"].ik_stiffness_y = 0.9   # no twisting along the thumb
    rig.pose.bones["thumb_03_r"].ik_stiffness_y = 0.9
    pb = rig.pose.bones["thumb_03_r"]
    ik = pb.constraints.new("IK")
    ik.target = tgt
    ik.chain_count = 3
    ik.iterations = 800
    bpy.context.view_layer.update()
    mats = {n: rig.pose.bones[n].matrix.copy() for n in chain}
    pb.constraints.remove(ik)
    for n in chain:
        rig.pose.bones[n].matrix = mats[n]
        bpy.context.view_layer.update()
    tip = mw @ rig.pose.bones["thumb_03_r"].tail
    print("FPHAND thumb tip off target", round((tip - target_p).length, 4))
    co = posed_coords(hand)
    dom = dominant(hand)
    th = co[[i for i, d in enumerate(dom) if d and d.startswith("thumb_0") and d != "thumb_01_r"]]
    ix = co[[i for i, d in enumerate(dom) if d and d.startswith("index_")]]
    dd = np.linalg.norm(th[:, None, :] - ix[None, :, :], axis=2)
    print("FPHAND thumb-index closest", round(float(dd.min()), 4), "pairs<2mm", int((dd < 0.002).sum()))


def folded_faces(hand):
    """Faces the pose turned inside out (normal flipped against the rest pose): skin folding over itself."""
    dg = bpy.context.evaluated_depsgraph_get()
    ev = hand.evaluated_get(dg).to_mesh()
    rest = hand.data
    n = {}
    dom = dominant(hand)
    for a, b in zip(rest.polygons, ev.polygons):
        if a.normal.dot(b.normal) < -0.2:
            k = dom[a.vertices[0]]
            n[k] = n.get(k, 0) + 1
    hand.evaluated_get(dg).to_mesh_clear()
    return n


def extend_forearm(hand, wrist, elbow):
    """Extrudes the cut end of the forearm straight on toward the elbow, widening a little as a forearm does."""
    arm = (elbow - wrist).normalized()
    mw = hand.matrix_world
    bm = bmesh.new()
    bm.from_mesh(hand.data)
    edges = [e for e in bm.edges if e.is_boundary and all((mw @ v.co - wrist).dot(arm) > FOREARM * 0.6 for v in e.verts)]
    steps = 7
    for k in range(steps):
        res = bmesh.ops.extrude_edge_only(bm, edges=edges)
        verts = [g for g in res["geom"] if isinstance(g, bmesh.types.BMVert)]
        edges = [g for g in res["geom"] if isinstance(g, bmesh.types.BMEdge) and g.is_boundary]
        c = sum((v.co for v in verts), Vector()) / len(verts)
        local_arm = (mw.inverted().to_3x3() @ arm).normalized()
        for v in verts:
            v.co = c + (v.co - c) * 1.025 + local_arm * (FOREARM_EXT / steps)
    bm.to_mesh(hand.data)
    bm.free()


def bake_pose(hand, rig):
    bpy.context.view_layer.objects.active = hand
    for o in bpy.context.selected_objects:
        o.select_set(False)
    hand.select_set(True)
    bpy.ops.object.modifier_apply(modifier="arm")


def to_item_space(hand, grip):
    """Grip centre to the origin, handle along Blender +Z (glTF +Y), forearm along Blender -Y (glTF +Z)."""
    wrist = grip.wrist
    a = grip.axis
    centre = grip.point + a * a.dot(bone_head(grip.rig, "middle_01_r") - grip.point)
    arm = (grip.elbow - wrist).normalized()
    arm_p = (arm - a * arm.dot(a)).normalized()
    side = a.cross(arm_p).normalized()
    R = Matrix((side, -arm_p, a)).to_4x4()
    hand.data.transform(R @ Matrix.Translation(-centre) @ hand.matrix_world)
    hand.matrix_world = Matrix.Identity(4)
    return R @ Matrix.Translation(-centre)


# ---------------------------------------------------------------- preview

def preview(objs, path, handle=True):
    sc = bpy.context.scene
    if handle:
        bpy.ops.mesh.primitive_cylinder_add(radius=HANDLE_R, depth=0.5, location=(0, 0, 0.1))
        h = bpy.context.object
        m = bpy.data.materials.new("wood"); m.use_nodes = True
        m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.25, 0.15, 0.08, 1)
        h.data.materials.append(m)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.5; sun.rotation_euler = (math.radians(40), math.radians(10), math.radians(140))
    sc.collection.objects.link(sun)
    w = bpy.data.worlds.new("w"); sc.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.5, 0.6, 0.75, 1)
    w.node_tree.nodes["Background"].inputs[1].default_value = 0.6
    sc.render.engine = "CYCLES"; sc.cycles.samples = 32; sc.cycles.device = "CPU"
    sc.render.resolution_x, sc.render.resolution_y = 900, 900
    sc.view_settings.view_transform = "AgX"
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam)
    sc.camera = cam
    cam.data.lens = 50
    views = [("a", (0.38, -0.18, 0.12)), ("b", (-0.3, 0.1, 0.25)), ("c", (0.05, -0.42, -0.05)), ("d", (0.25, 0.35, 0.1))]
    for tag, loc in views:
        cam.location = loc
        d = Vector((0, -0.04, 0.02)) - Vector(loc)
        cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        sc.render.filepath = path.replace(".png", f"_{tag}.png")
        bpy.ops.render.render(write_still=True)


# ---------------------------------------------------------------- main

# ---------------------------------------------------------------- detail maps (per-vertex inputs of the skin shader)

def bone_data(rig, T):
    """Posed finger bones in item space: name -> (head, tail)."""
    out = {}
    mw = rig.matrix_world
    for pb in rig.pose.bones:
        if pb.name.endswith("_r"):
            out[pb.name] = (T @ (mw @ pb.head), T @ (mw @ pb.tail))
    return out


def handle_dist_dir(p):
    """Item space: the handle is the Z axis. Unit vector from the handle out to p (in the XY plane)."""
    d = Vector((p.x, p.y, 0.0))
    return d.normalized() if d.length > 1e-6 else Vector((1, 0, 0))


def detail_attributes(obj, bones, dom_of, palm_n, wrist, arm_dir):
    """Float attributes the skin shader reads: nail, nailtip, wrinkle weight/phase, palm, red, forearm."""
    me = obj.data
    names = ["nail", "nailtip", "wr_w", "wr_ph", "palm", "red", "fore"]
    vals = {n: [0.0] * len(me.vertices) for n in names}
    distal = [f"{f}_03_r" for f in FINGERS + ["thumb"]]
    seg = {}
    for b in distal:
        h, t = bones[b]
        ix = [i for i, d in enumerate(dom_of) if d == b]
        if not ix:
            continue
        dirv = (t - h).normalized()
        c = (h + t) * 0.5
        dorsal = handle_dist_dir(c)
        if b == "thumb_03_r":  # the thumb's pad lies on the index finger: its nail faces away from it
            ih, it = bones["index_02_r"]
            dorsal = c - (ih + it) * 0.5
        dorsal = (dorsal - dirv * dorsal.dot(dirv)).normalized()
        lat = dirv.cross(dorsal)
        rad = float(np.median([((me.vertices[i].co - h) - dirv * (me.vertices[i].co - h).dot(dirv)).length for i in ix]))
        stip = max((me.vertices[i].co - h).dot(dirv) for i in ix)
        seg[b] = (h, dirv, dorsal, lat, rad, stip)
    joints = []
    for f in FINGERS + ["thumb"]:
        for k in (1, 2, 3):
            n = f"{f}_0{k}_r"
            if n in bones and not (f == "thumb" and k == 1):
                h, t = bones[n]
                dirv = (t - h).normalized()
                dorsal = handle_dist_dir(h)
                dorsal = (dorsal - dirv * dorsal.dot(dirv)).normalized()
                joints.append((h, dirv, dorsal, 0.0065 if k == 1 else 0.0052))
    for i, v in enumerate(me.vertices):
        p, nrm, d = v.co, v.normal, dom_of[i]
        if d in seg:
            h, dirv, dorsal, lat, rad, stip = seg[d]
            q = p - h
            s0 = stip * 0.42
            vv = (q.dot(dirv) - s0) / max(stip - s0, 1e-4)
            u = q.dot(lat) / (0.66 * rad)
            top = q.dot(dorsal) / max(rad, 1e-4)
            def sm(a, b, x):
                t = min(max((x - a) / (b - a), 0.0), 1.0)
                return t * t * (3 - 2 * t)
            facing = nrm.dot(dorsal)
            nail = sm(1.0, 0.8, abs(u)) * sm(0.0, 0.14, vv) * sm(0.3, 0.6, top) * sm(0.25, 0.55, facing) * (1.0 if vv < 1.08 else 0.0)
            vals["nail"][i] = nail
            vals["nailtip"][i] = nail * sm(0.82, 0.95, vv)
            vals["red"][i] = max(vals["red"][i], sm(0.2, 0.9, vv) * (1.0 - nail) * 0.8)
        best, bph = 0.0, 0.0
        for h, dirv, dorsal, size in joints:
            q = p - h
            dd = q.length
            if dd > size * 2.6:
                continue
            w = math.exp(-(dd / size) ** 2) * min(max(q.normalized().dot(dorsal) * 2.0, 0.0), 1.0)
            if w > best:
                best, bph = w, q.dot(dirv)
            vals["red"][i] = max(vals["red"][i], 0.6 * math.exp(-(dd / (size * 2.0)) ** 2) * min(max(q.normalized().dot(dorsal) * 2.0, 0.0), 1.0))
        vals["wr_w"][i] = best
        vals["wr_ph"][i] = bph
        along = (p - wrist).dot(arm_dir)
        fore = min(max(along / 0.03, 0.0), 1.0)
        vals["fore"][i] = fore
        pn = nrm.dot(palm_n)
        vals["palm"][i] = min(max((pn - 0.1) / 0.6, 0.0), 1.0) * (0.55 if fore > 0.5 else 1.0)
    for n in names:
        a = me.attributes.get(n) or me.attributes.new(n, "FLOAT", "POINT")
        a.data.foreach_set("value", vals[n])


def dominant_after(obj):
    gidx = {g.index: g.name for g in obj.vertex_groups}
    out = []
    for v in obj.data.vertices:
        best, bw = None, 0.0
        for g in v.groups:
            n = gidx.get(g.group, "")
            if n.endswith("_r") and g.weight > bw:
                best, bw = n, g.weight
        out.append(best)
    return out


# ---------------------------------------------------------------- shaders

def N(nt, kind, **kw):
    n = nt.nodes.new(kind)
    for k, v in kw.items():
        setattr(n, k, v)
    return n


def attr(nt, name):
    a = nt.nodes.new("ShaderNodeAttribute"); a.attribute_name = name
    return a.outputs["Fac"]


def math_node(nt, op, a, b=None, clamp=False):
    m = nt.nodes.new("ShaderNodeMath"); m.operation = op; m.use_clamp = clamp
    for k, x in enumerate([a, b]):
        if x is None:
            continue
        if isinstance(x, (int, float)):
            m.inputs[k].default_value = x
        else:
            nt.links.new(x, m.inputs[k])
    return m.outputs[0]


def mix_col(nt, fac, a, b, blend="MIX"):
    m = nt.nodes.new("ShaderNodeMix"); m.data_type = "RGBA"; m.blend_type = blend; m.clamp_result = True
    for sock, x in (("Factor", fac), ("A", a), ("B", b)):
        if isinstance(x, (int, float)):
            m.inputs[sock].default_value = x
        elif isinstance(x, tuple):
            m.inputs[sock].default_value = (*x, 1.0) if len(x) == 3 else x
        else:
            nt.links.new(x, m.inputs[sock])
    return m.outputs["Result"]


def skin_shader():
    """Procedural detailed skin (the high-res source of the bake)."""
    m = bpy.data.materials.new("M_SkinSource"); m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    tc = N(nt, "ShaderNodeTexCoord")
    obj = tc.outputs["Object"]
    def noise(scale, detail=4.0, rough=0.55):
        n = N(nt, "ShaderNodeTexNoise"); n.inputs["Scale"].default_value = scale
        n.inputs["Detail"].default_value = detail; n.inputs["Roughness"].default_value = rough
        nt.links.new(obj, n.inputs["Vector"])
        return n.outputs["Fac"]
    def voronoi(scale):
        v = N(nt, "ShaderNodeTexVoronoi"); v.inputs["Scale"].default_value = scale
        nt.links.new(obj, v.inputs["Vector"])
        return v.outputs["Distance"]
    # contact shadow of the fist itself and the handle in it, worked out live while baking
    aon = N(nt, "ShaderNodeAmbientOcclusion"); aon.samples = 24
    aon.inputs["Distance"].default_value = 0.018
    ao = aon.outputs["AO"]
    nail, nailtip, wr_w, wr_ph = attr(nt, "nail"), attr(nt, "nailtip"), attr(nt, "wr_w"), attr(nt, "wr_ph")
    palm, red, fore = attr(nt, "palm"), attr(nt, "red"), attr(nt, "fore")
    base = SKIN
    # albedo
    c = mix_col(nt, noise(45, 6), tuple(x * 0.86 for x in base), tuple(x * 1.1 for x in base))
    c = mix_col(nt, math_node(nt, "MULTIPLY", noise(7, 3), 0.5), c, (base[0] * 1.08, base[1] * 0.93, base[2] * 0.9))
    c = mix_col(nt, math_node(nt, "MULTIPLY", palm, 0.75), c, lin((0.6, 0.45, 0.37)))
    c = mix_col(nt, math_node(nt, "MULTIPLY", red, 0.55), c, (base[0] * 1.2, base[1] * 0.78, base[2] * 0.74))
    # freckles and small moles on the back of the hand and the forearm (sun)
    frk = math_node(nt, "LESS_THAN", voronoi(220), 0.16)
    frk = math_node(nt, "MULTIPLY", frk, math_node(nt, "GREATER_THAN", noise(18, 2), 0.56))
    frk = math_node(nt, "MULTIPLY", frk, math_node(nt, "SUBTRACT", 1.0, palm, clamp=True))
    c = mix_col(nt, math_node(nt, "MULTIPLY", frk, 0.35), c, (base[0] * 0.62, base[1] * 0.5, base[2] * 0.42))
    # forearm hair: fine dark streaks along the arm on its back
    hair_n = N(nt, "ShaderNodeTexNoise"); hair_n.inputs["Scale"].default_value = 1.0
    hair_n.inputs["Detail"].default_value = 2.0
    mp = N(nt, "ShaderNodeMapping"); mp.inputs["Scale"].default_value = (900.0, 60.0, 900.0)
    nt.links.new(obj, mp.inputs["Vector"]); nt.links.new(mp.outputs["Vector"], hair_n.inputs["Vector"])
    hair = math_node(nt, "GREATER_THAN", hair_n.outputs["Fac"], 0.64)
    hair = math_node(nt, "MULTIPLY", hair, math_node(nt, "MULTIPLY", fore, math_node(nt, "SUBTRACT", 1.0, palm, clamp=True)))
    c = mix_col(nt, math_node(nt, "MULTIPLY", hair, 0.45), c, lin((0.2, 0.14, 0.1)))
    # nails: pale keratin, whiter free edge, grime under it
    nail_c = mix_col(nt, noise(300, 2), lin((0.62, 0.48, 0.42)), lin((0.7, 0.57, 0.5)))
    nail_c = mix_col(nt, nailtip, nail_c, lin((0.78, 0.7, 0.6)))
    c = mix_col(nt, nail, c, nail_c)
    rim = math_node(nt, "MULTIPLY", nailtip, math_node(nt, "SUBTRACT", 1.0, nailtip))
    # dirt worked into creases, round the nails and in patches (a hunter's hands, not a clean model)
    crev = math_node(nt, "SUBTRACT", 1.0, ao, clamp=True)
    dirt = math_node(nt, "MULTIPLY", crev, 1.4)
    dirt = math_node(nt, "ADD", dirt, math_node(nt, "MULTIPLY", math_node(nt, "GREATER_THAN", noise(9, 5), 0.6), 0.22))
    dirt = math_node(nt, "ADD", dirt, math_node(nt, "MULTIPLY", rim, 2.5))
    dirt = math_node(nt, "MINIMUM", dirt, 0.75)
    c = mix_col(nt, dirt, c, lin((0.2, 0.14, 0.09)))
    c = mix_col(nt, math_node(nt, "MULTIPLY", crev, 0.5), c, (0.0, 0.0, 0.0), "MULTIPLY")
    nt.links.new(c, bsdf.inputs["Base Color"])
    # roughness
    r = math_node(nt, "ADD", 0.5, math_node(nt, "MULTIPLY", noise(60, 3), 0.12))
    r = math_node(nt, "ADD", r, math_node(nt, "MULTIPLY", palm, 0.08))
    r = math_node(nt, "ADD", r, math_node(nt, "MULTIPLY", dirt, 0.35))
    r = math_node(nt, "SUBTRACT", r, math_node(nt, "MULTIPLY", nail, 0.25), clamp=True)
    nt.links.new(r, bsdf.inputs["Roughness"])
    # height: pores, micro grain, knuckle wrinkles, raised nails with a groove round them
    pores = math_node(nt, "SUBTRACT", 1.0, math_node(nt, "DIVIDE", voronoi(950), 0.22), clamp=True)
    h = math_node(nt, "MULTIPLY", pores, -0.3)
    h = math_node(nt, "ADD", h, math_node(nt, "MULTIPLY", noise(1400, 2), 0.25))
    # knuckle folds: a few uneven creases across the joint (the phase is warped so they wander and break up)
    warped = math_node(nt, "ADD", wr_ph, math_node(nt, "MULTIPLY", math_node(nt, "SUBTRACT", noise(180, 3), 0.5), 0.0022))
    wave = math_node(nt, "SINE", math_node(nt, "MULTIPLY", warped, 2 * math.pi / 0.0019))
    wave = math_node(nt, "MULTIPLY", wave, math_node(nt, "GREATER_THAN", noise(120, 2), 0.38))
    h = math_node(nt, "ADD", h, math_node(nt, "MULTIPLY", math_node(nt, "MULTIPLY", wave, wr_w), 0.7))
    groove = math_node(nt, "MULTIPLY", nail, math_node(nt, "SUBTRACT", 1.0, nail))
    h = math_node(nt, "ADD", h, math_node(nt, "MULTIPLY", nail, 1.6))
    h = math_node(nt, "SUBTRACT", h, math_node(nt, "MULTIPLY", groove, 4.0))
    h = math_node(nt, "MULTIPLY", h, math_node(nt, "SUBTRACT", 1.0, math_node(nt, "MULTIPLY", nail, 0.8)))
    bump = N(nt, "ShaderNodeBump"); bump.inputs["Distance"].default_value = 0.00035
    bump.inputs["Strength"].default_value = 1.0
    nt.links.new(h, bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def new_image(name, size, color=True, hdr=False):
    img = bpy.data.images.new(name, size, size, alpha=False, float_buffer=hdr)
    img.colorspace_settings.name = "sRGB" if color else "Non-Color"
    return img


def bake(kind, obj, img, **kw):
    """Bakes on obj itself into img (an image node in its material). No selected-to-active rays: where fingers
    touch, rays cast from one would pick up the other."""
    nt = obj.active_material.node_tree
    node = next((n for n in nt.nodes if n.type == "TEX_IMAGE" and n.image == img), None)
    if node is None:
        node = nt.nodes.new("ShaderNodeTexImage"); node.image = img
    nt.nodes.active = node
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    sc = bpy.context.scene
    sc.render.bake.use_selected_to_active = False
    sc.render.bake.margin = 6   # well under the gap between islands (0.014 = 28 px): no bleeding into a neighbour
    bpy.ops.object.bake(type=kind, **kw)


# ---------------------------------------------------------------- wrist wrap

def make_wrap(hand, wrist, arm_dir, leather):
    """Rawhide strips wound round the wrist: a shell off the skin with a spiral of raised bands, open ends closed."""
    me = hand.data
    keep = set()
    for v in me.vertices:
        a = (v.co - wrist).dot(arm_dir)
        if 0.028 < a < 0.105:
            keep.add(v.index)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if not all(v.index in keep for v in f.verts)], context="FACES")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    wm = bpy.data.meshes.new("SM_FP_Wrap")
    bm.to_mesh(wm)
    bm.free()
    wrap = bpy.data.objects.new("SM_FP_Wrap", wm)
    bpy.context.scene.collection.objects.link(wrap)
    for g in list(wrap.vertex_groups):
        wrap.vertex_groups.remove(g)
    sub = wrap.modifiers.new("s", "SUBSURF"); sub.levels = 2
    bpy.context.view_layer.objects.active = wrap
    bpy.ops.object.modifier_apply(modifier="s")
    # cylindrical frame round the forearm
    centre = sum((v.co for v in wm.vertices), Vector()) / len(wm.vertices)
    ref = (Vector((1, 0, 0)) - arm_dir * arm_dir.x).normalized()
    ref2 = arm_dir.cross(ref)
    wm.calc_normals() if hasattr(wm, "calc_normals") else None
    uv = wm.uv_layers.new(name="UVMap")
    ang = {}
    for v in wm.vertices:
        q = v.co - centre
        a = math.atan2(q.dot(ref2), q.dot(ref))
        along = (v.co - wrist).dot(arm_dir)
        ang[v.index] = (a, along)
        ph = along / 0.017 + a / (2 * math.pi) * 1.0
        band = 0.5 + 0.5 * math.cos(ph * 2 * math.pi)
        band = band ** 0.35
        edge = min((along - 0.028) / 0.008, (0.105 - along) / 0.008, 1.0)
        v.co += v.normal * (0.0022 + 0.0016 * band) * max(edge, 0.35)
    for poly in wm.polygons:
        a0 = ang[wm.loops[poly.loop_start].vertex_index][0]
        for li in poly.loop_indices:
            a, along = ang[wm.loops[li].vertex_index]
            if abs(a - a0) > math.pi:
                a += 2 * math.pi if a < a0 else -2 * math.pi
            uv.data[li].uv = (a / (2 * math.pi) * 1.6, along / 0.08)
    sol = wrap.modifiers.new("t", "SOLIDIFY"); sol.thickness = 0.0025; sol.offset = -1.0
    bpy.ops.object.modifier_apply(modifier="t")
    for p in wm.polygons:
        p.use_smooth = True
    wm.materials.append(leather)
    return wrap


def leather_material():
    m = bpy.data.materials.new("M_FP_Wrap"); m.use_nodes = True
    m.use_backface_culling = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    d = N(nt, "ShaderNodeTexImage"); d.image = bpy.data.images.load(os.path.join(TEXSRC, "brown_leather", "brown_leather_diff_1k.jpg"))
    n = N(nt, "ShaderNodeTexImage"); n.image = bpy.data.images.load(os.path.join(TEXSRC, "brown_leather", "brown_leather_nor_gl_1k.jpg"))
    n.image.colorspace_settings.name = "Non-Color"
    nt.links.new(d.outputs["Color"], b.inputs["Base Color"])
    nm = N(nt, "ShaderNodeNormalMap")
    nm.inputs["Strength"].default_value = 0.45
    nt.links.new(n.outputs["Color"], nm.inputs["Color"]); nt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
    b.inputs["Roughness"].default_value = 0.78
    return m


# ---------------------------------------------------------------- export

def export(objs, name, tmp):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.export_scene.gltf(filepath=os.path.join(tmp, name + ".gltf"), export_format="GLTF_SEPARATE",
                              export_texture_dir="textures", use_selection=True, export_yup=True,
                              export_animations=False, export_skins=False, export_image_format="AUTO")


def install(name, tmp):
    g = json.load(open(os.path.join(tmp, name + ".gltf")))
    os.makedirs(os.path.join(HUM, "textures"), exist_ok=True)
    for im in g.get("images", []):
        src = os.path.join(tmp, im["uri"])
        base = os.path.basename(im["uri"])
        stem = os.path.splitext(base)[0]
        if not os.path.exists(os.path.join(HUM, "textures", base)) or base.startswith("T_FP_Hand"):
            shutil.copy(src, os.path.join(HUM, "textures", base))
        im["uri"] = "textures/" + base
    for b in g.get("buffers", []):
        b["uri"] = name + ".bin"
    json.dump(g, open(os.path.join(HUM, name + ".gltf"), "w"), indent=1)
    shutil.copy(os.path.join(tmp, name + ".bin"), os.path.join(HUM, name + ".bin"))


# ---------------------------------------------------------------- main

def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for o in list(bpy.context.scene.objects):
        bpy.data.objects.remove(o)
    body, rig = make_body()
    hand = cut_arm(body, rig)
    grip = Grip(rig, hand)
    close_hand(rig, hand, grip)
    bake_pose(hand, rig)
    extend_forearm(hand, grip.wrist, grip.elbow)
    T = to_item_space(hand, grip)
    bones = bone_data(rig, T)
    R3 = T.to_3x3().normalized()
    palm_n = (R3 @ grip.n).normalized()
    wrist = T @ grip.wrist
    arm_dir = (R3 @ (grip.elbow - grip.wrist)).normalized()
    for p in hand.data.polygons:
        p.use_smooth = True
    for o in list(bpy.data.objects):
        if o is not hand:
            bpy.data.objects.remove(o, do_unlink=True)
    print("FPHAND verts", len(hand.data.vertices), "dims", [round(x, 3) for x in hand.dimensions])
    if STAGE == "pose":
        sub = hand.modifiers.new("smooth", "SUBSURF"); sub.levels = sub.render_levels = 1
        m = bpy.data.materials.new("skin"); m.use_nodes = True
        m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*SKIN, 1)
        hand.data.materials.append(m)
        if PREVIEW:
            preview([hand], PREVIEW)
        return
    # game mesh: one level of smoothing, its own UVs over the whole texture
    bpy.context.view_layer.objects.active = hand
    sub = hand.modifiers.new("smooth", "SUBSURF"); sub.levels = 1; sub.boundary_smooth = "PRESERVE_CORNERS"
    bpy.ops.object.modifier_apply(modifier="smooth")
    bpy.ops.object.select_all(action="DESELECT")
    hand.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    # islands from a smart projection, then each one unwrapped properly (a planar projection folds over itself
    # on curled fingers: two parts of the hand would share texels) and packed with room between them
    bpy.ops.uv.smart_project(angle_limit=math.radians(50), island_margin=0.014, scale_to_bounds=True)
    bpy.ops.uv.seams_from_islands()
    bpy.context.scene.tool_settings.use_uv_select_sync = True
    for it in range(8):
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.uv.unwrap(method="ANGLE_BASED", margin=0.014)
        bpy.ops.uv.pack_islands(margin=0.014, rotate=True)
        bpy.ops.mesh.select_all(action="DESELECT")
        bpy.ops.uv.select_overlap()
        bpy.ops.object.mode_set(mode="OBJECT")
        over = [p for p in hand.data.polygons if p.select]
        print("FPHAND uv overlapping faces", len(over), "of", len(hand.data.polygons))
        if not over:
            bpy.ops.object.mode_set(mode="EDIT")
            break
        # cut the folding faces loose along all their edges, then unwrap again
        keys = {e for p in over for e in p.edge_keys}
        for e in hand.data.edges:
            if e.key in keys:
                e.use_seam = True
        bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.object.mode_set(mode="OBJECT")
    # bake source: three more levels, detail attributes
    high = hand.copy(); high.data = hand.data.copy(); high.name = "high"
    bpy.context.scene.collection.objects.link(high)
    bpy.context.view_layer.objects.active = high
    sub = high.modifiers.new("smooth", "SUBSURF"); sub.levels = 2
    sub.uv_smooth = "NONE"   # its UVs map exactly onto the game mesh's: the maps are baked on it directly
    bpy.ops.object.modifier_apply(modifier="smooth")
    detail_attributes(high, bones, dominant_after(high), palm_n, wrist, arm_dir)
    print("FPHAND high verts", len(high.data.vertices))
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"; sc.cycles.device = "CPU"
    # maps on the game mesh
    img_alb = new_image("T_FP_Hand_albedo", TEX)
    img_nrm = new_image("T_FP_Hand_normal", TEX, False)
    img_rgh = new_image("T_FP_Hand_rough", 1024, False)
    low_m = bpy.data.materials.new("M_FP_Hand_Skin"); low_m.use_nodes = True
    low_m.use_backface_culling = True
    hand.data.materials.clear(); hand.data.materials.append(low_m)
    lnt = low_m.node_tree
    nodes = {}
    for img in (img_alb, img_nrm, img_rgh):
        t = lnt.nodes.new("ShaderNodeTexImage"); t.image = img; nodes[img.name] = t
    # the handle in the fist casts its contact shadow into the bake; the game mesh is hidden (it coincides)
    bpy.ops.mesh.primitive_cylinder_add(radius=HANDLE_R, depth=0.6, vertices=48)
    stick = bpy.context.object
    # out of the scene, not just hidden: a render-hidden object still blocks the bake's AO rays
    bpy.context.scene.collection.objects.unlink(hand)
    high.data.materials.clear(); high.data.materials.append(skin_shader())
    sc.cycles.samples = 16
    bake("DIFFUSE", high, img_alb, pass_filter={"COLOR"})
    bake("ROUGHNESS", high, img_rgh)
    bake("NORMAL", high, img_nrm, normal_space="TANGENT")
    bpy.context.scene.collection.objects.link(hand)
    bpy.data.objects.remove(stick, do_unlink=True)
    bpy.data.objects.remove(high, do_unlink=True)
    # the exported material: baked maps on a plain principled skin
    b = lnt.nodes["Principled BSDF"]
    lnt.links.new(nodes["T_FP_Hand_albedo"].outputs["Color"], b.inputs["Base Color"])
    lnt.links.new(nodes["T_FP_Hand_rough"].outputs["Color"], b.inputs["Roughness"])
    nm = lnt.nodes.new("ShaderNodeNormalMap")
    lnt.links.new(nodes["T_FP_Hand_normal"].outputs["Color"], nm.inputs["Color"])
    lnt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
    tmp = tempfile.mkdtemp()
    for img in (img_alb, img_nrm, img_rgh):
        img.filepath_raw = os.path.join(tmp, img.name + ".png")
        img.file_format = "PNG"
        img.save()
    wrap = make_wrap(hand, wrist, arm_dir, leather_material())
    for o in (hand, wrap):
        for g in list(o.vertex_groups):
            o.vertex_groups.remove(g)
        for a in [a.name for a in o.data.attributes if a.name in ("nail", "nailtip", "wr_w", "wr_ph", "palm", "red", "fore")]:
            o.data.attributes.remove(o.data.attributes[a])
    if PREVIEW:
        preview([hand, wrap], PREVIEW)
        bpy.data.objects.remove(bpy.data.objects["Cylinder"], do_unlink=True) if "Cylinder" in bpy.data.objects else None
    hand.name = "SM_FP_Hand_R"
    export([hand, wrap], "SM_FP_Hand_R", tmp)
    install("SM_FP_Hand_R", tmp)
    # the left hand (the bow hand): mirrored across the handle (item x), faces turned back outward
    for o in (hand, wrap):
        o.data.transform(Matrix.Scale(-1, 4, (1, 0, 0)))
        o.data.flip_normals()
    hand.name = "SM_FP_Hand_L"
    export([hand, wrap], "SM_FP_Hand_L", tmp)
    install("SM_FP_Hand_L", tmp)
    print("FPHAND done tris", sum(len(p.vertices) - 2 for p in hand.data.polygons) + sum(len(p.vertices) - 2 for p in wrap.data.polygons))


main()
