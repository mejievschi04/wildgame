# Prehistoric human NPCs from MPFB (MakeHuman) bodies + hide clothing cut from body regions + procedural clips.
#   blender -b --python tools/blender/gen_humans.py [-- variant ...]
# Output: assets/models/humans/SK_Human_<variant>.gltf (game_engine rig, clips: idle, walk, run, alert,
#         gesture, attack, sit, death). Blender Z-up; MPFB characters face -Y (Godot: rotate 180°).
import bpy, bmesh, math, os, sys
from mathutils import Vector, Quaternion, Matrix
from bl_ext.blender_org.mpfb.services.humanservice import HumanService
from bl_ext.blender_org.mpfb.services.targetservice import TargetService

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "models", "humans")
TEX = os.path.join(ROOT, "art_source", "textures")
os.makedirs(OUT, exist_ok=True)
FPS = 24

# name: macro details, skin tone (sRGB), hair (sRGB), clothing tint, beard
VARIANTS = {
    "M1": ({"gender": 1.0, "age": 0.5, "muscle": 0.72, "weight": 0.45, "height": 0.55}, (0.62, 0.45, 0.34), (0.09, 0.07, 0.05), (0.9, 0.75, 0.6), True),
    "M2": ({"gender": 1.0, "age": 0.75, "muscle": 0.55, "weight": 0.5, "height": 0.45}, (0.55, 0.38, 0.27), (0.25, 0.22, 0.2), (0.7, 0.58, 0.46), True),
    "M3": ({"gender": 0.95, "age": 0.4, "muscle": 0.8, "weight": 0.4, "height": 0.6}, (0.5, 0.35, 0.25), (0.05, 0.04, 0.03), (0.6, 0.48, 0.4), False),
    "F1": ({"gender": 0.0, "age": 0.45, "muscle": 0.55, "weight": 0.45, "height": 0.45}, (0.64, 0.47, 0.36), (0.12, 0.08, 0.05), (1.0, 0.85, 0.7), False),
    "F2": ({"gender": 0.0, "age": 0.7, "muscle": 0.45, "weight": 0.55, "height": 0.4}, (0.56, 0.4, 0.3), (0.3, 0.27, 0.24), (0.8, 0.68, 0.55), False),
}

TORSO = {"pelvis", "spine_01", "spine_02", "spine_03", "clavicle_l", "clavicle_r", "neck_01"}
UPPERARM = {"upperarm_l", "upperarm_r"}
LEGS_UP = {"thigh_l", "thigh_r"}
LEGS_LOW = {"calf_l", "calf_r"}
FEET = {"foot_l", "foot_r", "ball_l", "ball_r"}


def lin(c):
    return tuple(pow(x, 2.2) for x in c) + (1.0,)


def tex_path(name, kind):
    d = os.path.join(TEX, name)
    for f in sorted(os.listdir(d)):
        if f"_{kind}_" in f:
            return os.path.join(d, f)


def mat_skin(tone):
    m = bpy.data.materials.new("M_Skin")
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = lin(tone)
    b.inputs["Roughness"].default_value = 0.55
    return m


def mat_flat(name, rgb, rough=0.8):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = lin(rgb)
    b.inputs["Roughness"].default_value = rough
    return m


def mat_hide(name, tint, uv_scale=2.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    tc = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping"); mp.inputs["Scale"].default_value = (uv_scale, uv_scale, 1)
    nt.links.new(tc.outputs["UV"], mp.inputs["Vector"])
    d = nt.nodes.new("ShaderNodeTexImage"); d.image = bpy.data.images.load(tex_path("brown_leather", "diff"), check_existing=True)
    n = nt.nodes.new("ShaderNodeTexImage"); n.image = bpy.data.images.load(tex_path("brown_leather", "nor_gl"), check_existing=True)
    n.image.colorspace_settings.name = "Non-Color"
    for t in (d, n):
        nt.links.new(mp.outputs["Vector"], t.inputs["Vector"])
    mul = nt.nodes.new("ShaderNodeMix"); mul.data_type = "RGBA"; mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    nt.links.new(d.outputs["Color"], mul.inputs["A"]); mul.inputs["B"].default_value = (*tint, 1)
    nt.links.new(mul.outputs["Result"], b.inputs["Base Color"])
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(n.outputs["Color"], nm.inputs["Color"]); nt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
    b.inputs["Roughness"].default_value = 0.75
    return m


# ---------------------------------------------------------------- body

def make_body(macro):
    d = TargetService.get_default_macro_info_dict()
    d.update(macro)
    bm = HumanService.create_human(scale=0.1, macro_detail_dict=d)
    rig = HumanService.add_builtin_rig(bm, "game_engine")
    bpy.context.view_layer.objects.active = bm
    # Bake shape keys (macro morphs) into the mesh.
    if bm.data.shape_keys:
        bm.shape_key_add(name="final", from_mix=True)
        keys = bm.data.shape_keys.key_blocks
        final = keys["final"]
        for v, k in zip(bm.data.vertices, final.data):
            v.co = k.co
        bm.shape_key_clear()
    # Delete helper geometry except the eyes.
    keep = {"body", "helper-l-eye", "helper-r-eye"}
    gidx = {g.index: g.name for g in bm.vertex_groups}
    bmh = bmesh.new()
    bmh.from_mesh(bm.data)
    deform = bmh.verts.layers.deform.active
    kill = []
    for v in bmh.verts:
        names = {gidx[i] for i in v[deform].keys()} if deform else set()
        if not names & keep:
            kill.append(v)
    bmesh.ops.delete(bmh, geom=kill, context="VERTS")
    bmh.to_mesh(bm.data)
    bmh.free()
    for mod in list(bm.modifiers):
        if mod.type == "MASK":
            bm.modifiers.remove(mod)
    return bm, rig


def dominant_bone(v, gnames, bone_names):
    best, w = None, 0.0
    for g in v.groups:
        n = gnames.get(g.group)
        if n in bone_names and g.weight > w:
            best, w = n, g.weight
    return best


def assign_body_materials(bm, skin, eye_mat):
    bm.data.materials.clear()
    bm.data.materials.append(skin)
    bm.data.materials.append(eye_mat)
    gnames = {g.index: g.name for g in bm.vertex_groups}
    eye_groups = {"helper-l-eye", "helper-r-eye"}
    for p in bm.data.polygons:
        v = bm.data.vertices[p.vertices[0]]
        names = {gnames[g.group] for g in v.groups if g.weight > 0.5}
        p.material_index = 1 if names & eye_groups else 0
        p.use_smooth = True


def cut_garment(bm, name, bone_set, material, thickness, push, z_min=None, z_max=None, keep_fn=None, flare_z=None, flare=0.0, smooth=0):
    """Duplicate faces whose dominant bone is in bone_set (optionally clipped by height), thicken and push out."""
    bone_names = {b for b in TORSO | UPPERARM | LEGS_UP | LEGS_LOW | FEET | {"head", "lowerarm_l", "lowerarm_r", "hand_l", "hand_r"}}
    g = bm.copy()
    g.data = bm.data.copy()
    g.name = name
    bpy.context.scene.collection.objects.link(g)
    gnames = {x.index: x.name for x in g.vertex_groups}
    bmg = bmesh.new()
    bmg.from_mesh(g.data)
    deform = bmg.verts.layers.deform.active
    kill = []
    for f in bmg.faces:
        keep = True
        for v in f.verts:
            dw = v[deform]
            best, w = None, 0.0
            for gi, wt in dw.items():
                n = gnames.get(gi)
                if n in bone_names and wt > w:
                    best, w = n, wt
            if best not in bone_set:
                keep = False
            if z_min is not None and v.co.z < z_min:
                keep = False
            if z_max is not None and v.co.z > z_max:
                keep = False
            if keep_fn is not None and not keep_fn(v.co):
                keep = False
        if not keep:
            kill.append(f)
    bmesh.ops.delete(bmg, geom=kill, context="FACES")
    for v in bmg.verts:
        v.co += v.normal * push
        if flare_z is not None and v.co.z < flare_z:
            # Loose hem: push outward from the body's vertical axis below the hips.
            radial = Vector((v.co.x, v.co.y + 0.02, 0.0))
            if radial.length > 0.001:
                v.co += radial.normalized() * (flare_z - v.co.z) * flare
    bmg.to_mesh(g.data)
    bmg.free()
    g.data.materials.clear()
    g.data.materials.append(material)
    for p in g.data.polygons:
        p.use_smooth = True
    if smooth > 0:
        # Hide anatomy under the hide: relax the garment surface before thickening.
        sm = g.modifiers.new("smooth", "SMOOTH")
        sm.factor = 0.9
        sm.iterations = smooth
        g.modifiers.move(g.modifiers.find("smooth"), 0)
        bpy.context.view_layer.objects.active = g
        bpy.ops.object.modifier_apply(modifier="smooth")
        bmg2 = bmesh.new(); bmg2.from_mesh(g.data)
        for v in bmg2.verts:
            v.co += v.normal * 0.006
        bmg2.to_mesh(g.data); bmg2.free()
    sol = g.modifiers.new("solid", "SOLIDIFY")
    sol.thickness = thickness
    sol.offset = 1.0
    # Solidify must run before the armature deform.
    g.modifiers.move(g.modifiers.find("solid"), 0)
    bpy.context.view_layer.objects.active = g
    bpy.ops.object.modifier_apply(modifier="solid")
    return g


def make_hair(bm, hair_mat, beard):
    parts = []
    head_top = max(v.co.z for v in bm.data.vertices)
    head_vs = [v.co for v in bm.data.vertices if v.co.z > head_top - 0.25]
    cy = sum(c.y for c in head_vs) / len(head_vs)  # head centre (front is -Y)
    # Crown + back of the head down to the nape; the face stays clear.
    scalp_fn = lambda c: c.z > head_top - 0.065 or (c.y > cy - 0.02 and c.z > head_top - 0.2)
    parts.append(cut_garment(bm, "Hair", {"head", "neck_01"}, hair_mat, 0.014, 0.012, keep_fn=scalp_fn))
    if beard:
        beard_fn = lambda c: c.y < cy - 0.03 and head_top - 0.255 < c.z < head_top - 0.2
        parts.append(cut_garment(bm, "Beard", {"head"}, hair_mat, 0.006, 0.005, keep_fn=beard_fn))
    return parts


# ---------------------------------------------------------------- animation (rotations in armature space)

def pose_rot(rig, bone, axis, deg):
    """Quaternion for pose bone so that it rotates `deg` about an ARMATURE-space axis (rest frame)."""
    rest = rig.data.bones[bone].matrix_local.to_quaternion()
    q = Quaternion(Vector(axis), math.radians(deg))
    return rest.inverted() @ q @ rest


def key_pose(rig, frame, rots, root_z=0.0):
    for pb in rig.pose.bones:
        pb.rotation_mode = "QUATERNION"
    for bone, parts in rots.items():
        if bone not in rig.pose.bones:
            continue
        q = Quaternion()
        for axis, deg in parts:
            q = pose_rot(rig, bone, axis, deg) @ q
        pb = rig.pose.bones[bone]
        pb.rotation_quaternion = q
        pb.keyframe_insert("rotation_quaternion", frame=frame)
    pv = rig.pose.bones["pelvis"]
    pv.location = (0, 0, 0)
    pv.keyframe_insert("location", frame=frame)
    rt = rig.pose.bones["Root"]
    rt.location = (0, 0, root_z)
    rt.keyframe_insert("location", frame=frame)


X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)
FWD = -1.0  # characters face -Y: a "forward" leg swing is a negative rotation about +X
ARMS_DOWN = 40.0  # bring arms from the rest A-pose down to the sides


def base_pose():
    return {
        "upperarm_l": [(Y, ARMS_DOWN * 0.9)], "upperarm_r": [(Y, -ARMS_DOWN * 0.9)],
        "lowerarm_l": [(X, FWD * -12)], "lowerarm_r": [(X, FWD * -12)],
    }


def merge(a, b):
    out = {k: list(v) for k, v in a.items()}
    for k, v in b.items():
        out.setdefault(k, []).extend(v)
    return out


def clip_walk(rig, length, stride, arm, bob, lean=0.0):
    n = int(length * FPS)
    for f in range(n + 1):
        t = f / n * math.tau
        s = math.sin(t)
        r = {
            "thigh_l": [(X, FWD * stride * s)], "thigh_r": [(X, -FWD * stride * s)],
            "calf_l": [(X, -FWD * stride * 1.3 * max(0.0, -math.cos(t)))], "calf_r": [(X, -FWD * stride * 1.3 * max(0.0, math.cos(t)))],
            "foot_l": [(X, FWD * 8 * max(0.0, -math.cos(t)))], "foot_r": [(X, FWD * 8 * max(0.0, math.cos(t)))],
            "upperarm_l": [(X, -FWD * arm * s)], "upperarm_r": [(X, FWD * arm * s)],
            "pelvis": [(Z, 5 * s)], "spine_02": [(Z, -4 * s), (X, FWD * lean)], "head": [(Z, -2 * s)],
        }
        key_pose(rig, f + 1, merge(base_pose(), r), -bob * abs(math.cos(t)))
    return n


def clip_idle(rig):
    n = 4 * FPS
    for f in range(0, n + 1, 4):
        t = f / n * math.tau
        r = {"spine_03": [(X, 1.5 * math.sin(t * 2))], "head": [(Z, 8 * math.sin(t)), (X, 3 * math.sin(t * 0.5))],
             "upperarm_l": [(X, 2 * math.sin(t))], "upperarm_r": [(X, -2 * math.sin(t))]}
        key_pose(rig, f + 1, merge(base_pose(), r))
    return n


def clip_alert(rig):
    n = 2 * FPS
    for f in range(0, n + 1, 2):
        t = f / n * math.tau
        r = {"spine_02": [(X, FWD * 6)], "head": [(Z, 18 * math.sin(t)), (X, -FWD * 4)],
             "thigh_l": [(X, FWD * 10)], "calf_l": [(X, -FWD * 15)], "thigh_r": [(X, -FWD * 6)],
             "upperarm_r": [(X, FWD * 25)], "lowerarm_r": [(X, FWD * 40)]}
        key_pose(rig, f + 1, merge(base_pose(), r), -0.03)
    return n


def clip_gesture(rig):
    """Open palm raised: the universal 'peaceful' sign."""
    n = int(1.6 * FPS)
    for f in range(n + 1):
        k = math.sin(min(f / n, 1.0) * math.pi)
        r = {"upperarm_r": [(Y, ARMS_DOWN * 0.9 * k), (X, FWD * 70 * k)], "lowerarm_r": [(X, FWD * 60 * k)],
             "hand_r": [(Y, 10 * k)], "head": [(X, -FWD * 6 * k)]}
        key_pose(rig, f + 1, merge(base_pose(), r))
    return n


def clip_attack(rig):
    """Spear thrust: draw back, lunge."""
    n = int(1.0 * FPS)
    for f in range(n + 1):
        t = f / n
        back = math.sin(min(t / 0.4, 1.0) * math.pi * 0.5) if t < 0.4 else max(0.0, 1 - (t - 0.4) / 0.15)
        lunge = 0.0 if t < 0.4 else math.sin(min((t - 0.4) / 0.6, 1.0) * math.pi)
        r = {"upperarm_r": [(X, FWD * (-30 * back + 70 * lunge))], "lowerarm_r": [(X, FWD * (70 * back + 10 * lunge))],
             "upperarm_l": [(X, FWD * (30 * back + 60 * lunge))], "lowerarm_l": [(X, FWD * 40)],
             "spine_02": [(Z, 18 * back - 12 * lunge), (X, FWD * 12 * lunge)],
             "thigh_l": [(X, FWD * 25 * lunge)], "calf_l": [(X, -FWD * 20 * lunge)], "thigh_r": [(X, -FWD * 15 * lunge)]}
        key_pose(rig, f + 1, merge(base_pose(), r), -0.06 * lunge)
    return n


def clip_sit(rig):
    """Crouched rest by the fire."""
    n = 3 * FPS
    for f in range(0, n + 1, 3):
        t = f / n * math.tau
        r = {"thigh_l": [(X, FWD * 95)], "thigh_r": [(X, FWD * 95)], "calf_l": [(X, -FWD * 140)], "calf_r": [(X, -FWD * 140)],
             "foot_l": [(X, FWD * 40)], "foot_r": [(X, FWD * 40)],
             "spine_02": [(X, FWD * 18)], "head": [(X, -FWD * 8 + 2 * math.sin(t))],
             "upperarm_l": [(X, FWD * 35)], "upperarm_r": [(X, FWD * 35)], "lowerarm_l": [(X, FWD * 50)], "lowerarm_r": [(X, FWD * 50)]}
        key_pose(rig, f + 1, merge(base_pose(), r), -0.55)
    return n


def clip_death(rig):
    n = int(1.4 * FPS)
    for f in range(n + 1):
        e = min(f / n / 0.8, 1.0)
        e = e * e * (3 - 2 * e)
        r = {"pelvis": [(X, -FWD * 80 * e)], "spine_02": [(X, -FWD * 10 * e)], "head": [(X, -FWD * 15 * e)],
             "thigh_l": [(X, FWD * 20 * e)], "calf_l": [(X, -FWD * 30 * e)], "upperarm_l": [(Y, 30 * e)], "upperarm_r": [(Y, -30 * e)]}
        key_pose(rig, f + 1, merge(base_pose(), r), -0.85 * e)
    return n


def make_clips(rig):
    rig.animation_data_create()
    clips = {
        "idle": lambda: clip_idle(rig),
        "walk": lambda: clip_walk(rig, 1.1, 24, 16, 0.02),
        "run": lambda: clip_walk(rig, 0.66, 38, 30, 0.05, lean=8),
        "alert": lambda: clip_alert(rig),
        "gesture": lambda: clip_gesture(rig),
        "attack": lambda: clip_attack(rig),
        "sit": lambda: clip_sit(rig),
        "death": lambda: clip_death(rig),
    }
    for name, fn in clips.items():
        act = bpy.data.actions.new(name)
        rig.animation_data.action = act
        for pb in rig.pose.bones:
            pb.rotation_mode = "QUATERNION"
            pb.rotation_quaternion = Quaternion()
            pb.location = (0, 0, 0)
        frames = fn()
        tr = rig.animation_data.nla_tracks.new()
        tr.name = name
        st = tr.strips.new(name, 1, act)
        st.action_frame_end = frames + 1
        rig.animation_data.action = None
    return list(clips)


# Severable parts (GDD combat): region -> bones whose faces belong to the detached piece.
FINGERS = lambda side: {f"{f}_{i:02d}_{side}" for f in ("index", "middle", "pinky", "ring", "thumb") for i in (1, 2, 3)}
PARTS = {
    "head": {"head"},
    "arm_l": {"lowerarm_l", "hand_l"} | FINGERS("l"),
    "arm_r": {"lowerarm_r", "hand_r"} | FINGERS("r"),
    "leg_l": {"calf_l", "foot_l", "ball_l"},
    "leg_r": {"calf_r", "foot_r", "ball_r"},
}


def export_parts(variant, objs, bone_names):
    """Static rest-pose meshes of each severable part (body + clothing + hair), cut surface capped with flesh."""
    flesh = mat_flat("M_Flesh", (0.45, 0.06, 0.05), 0.35)
    all_bones = set()
    for b in PARTS.values():
        all_bones |= b
    for region, bones in PARTS.items():
        pieces = []
        for src in objs:
            o = src.copy()
            o.data = src.data.copy()
            bpy.context.scene.collection.objects.link(o)
            o.parent = None
            for m in list(o.modifiers):
                o.modifiers.remove(m)
            gnames = {g.index: g.name for g in o.vertex_groups}
            bm = bmesh.new()
            bm.from_mesh(o.data)
            deform = bm.verts.layers.deform.active
            kill = []
            for f in bm.faces:
                keep = True
                for v in f.verts:
                    best, w = None, 0.0
                    if deform:
                        for gi, wt in v[deform].items():
                            gn = gnames.get(gi)
                            if gn in bone_names and wt > w:
                                best, w = gn, wt
                    if best not in bones:
                        keep = False
                        break
                if not keep:
                    kill.append(f)
            bmesh.ops.delete(bm, geom=kill, context="FACES")
            if len(bm.faces) == 0:
                bm.free()
                bpy.data.objects.remove(o)
                continue
            n_before = len(bm.faces)
            bmesh.ops.holes_fill(bm, edges=bm.edges, sides=0)
            bm.to_mesh(o.data)
            bm.free()
            if src.name == objs[0].name:  # cap only the body (clothing shells stay open)
                if flesh.name not in [m.name for m in o.data.materials if m]:
                    o.data.materials.append(flesh)
                fi = [m.name for m in o.data.materials].index(flesh.name)
                for p in o.data.polygons[n_before:]:
                    p.material_index = fi
            o.vertex_groups.clear()
            pieces.append(o)
        if not pieces:
            continue
        bpy.ops.object.select_all(action="DESELECT")
        for o in pieces:
            o.select_set(True)
        bpy.context.view_layer.objects.active = pieces[0]
        if len(pieces) > 1:
            bpy.ops.object.join()
        part = bpy.context.view_layer.objects.active
        part.name = f"SM_Part_{variant}_{region}"
        path = os.path.join(OUT, "parts", f"SM_Part_{variant}_{region}.gltf")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="../textures",
                                  use_selection=True, export_yup=True, export_animations=False, export_skins=False)
        bpy.data.objects.remove(part)
    print("PARTS", variant, list(PARTS))


def build(variant):
    macro, tone, hair, tint, beard = VARIANTS[variant]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for o in list(bpy.context.scene.objects):
        bpy.data.objects.remove(o)
    bpy.context.scene.render.fps = FPS
    bm, rig = make_body(macro)
    assign_body_materials(bm, mat_skin(tone), mat_flat("M_Eye", (0.08, 0.06, 0.05), 0.15))
    hide = mat_hide("M_Tunic", tint)
    dark = mat_hide("M_Leggings", tuple(x * 0.6 for x in tint))
    wrap = mat_hide("M_Wraps", tuple(x * 0.5 for x in tint), 4.0)
    hair_mat = mat_flat("M_Hair", hair, 0.9)
    hip_z = rig.data.bones["thigh_l"].head_local.z
    pieces = [
        cut_garment(bm, "Tunic", TORSO | UPPERARM | LEGS_UP, hide, 0.01, 0.022, z_min=hip_z - 0.1, flare_z=hip_z + 0.08, flare=0.25, smooth=18),
        cut_garment(bm, "Leggings", LEGS_UP | LEGS_LOW, dark, 0.006, 0.008, z_max=hip_z + 0.03, smooth=4),
        cut_garment(bm, "Wraps", FEET | LEGS_LOW, wrap, 0.008, 0.012, z_max=0.2),
    ] + make_hair(bm, hair_mat, beard)
    for p in pieces:
        p.parent = rig
    export_parts(variant, [bm] + pieces, {b.name for b in rig.data.bones})
    clips = make_clips(rig)
    bpy.ops.object.select_all(action="DESELECT")
    for o in [bm, rig] + pieces:
        o.select_set(True)
    bpy.context.view_layer.objects.active = rig
    path = os.path.join(OUT, f"SK_Human_{variant}.gltf")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="textures",
                              use_selection=True, export_yup=True, export_animations=True,
                              export_animation_mode="NLA_TRACKS", export_skins=True)
    tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in [bm] + pieces)
    print("HUMAN", variant, "tris", tris, "clips", clips, "height", round(bm.dimensions.z, 2))


argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
for v in (argv or list(VARIANTS)):
    build(v)
