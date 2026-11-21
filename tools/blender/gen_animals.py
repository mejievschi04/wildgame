# Procedural rigged + animated quadrupeds (red deer hind, grey wolf).
#   blender -b --python tools/blender/gen_animals.py
# Body: skin-modifier over an anatomical joint graph → subdivided organic mesh, vertex-colour coat
# pattern × scanned leather detail. Rig: named bones, automatic weights. Clips (NLA tracks → glTF):
# idle, walk, run, graze, alert, attack, death. Blender Z-up; animals face +Y (→ Godot -Z).
import bpy, bmesh, math, os
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "models", "animals")
TEX = os.path.join(ROOT, "art_source", "textures", "brown_leather")
os.makedirs(OUT, exist_ok=True)
FPS = 24

# ---------------------------------------------------------------- species definitions
# joints: name -> (x, y, z); skel: list of (parent_joint, child_joint, bone_name, radius_child (rx, ry))

DEER = {
    "name": "Deer",
    "joints": {
        "hips": (0, -0.48, 1.06), "spine": (0, -0.1, 1.08), "chest": (0, 0.3, 1.06), "neck": (0, 0.48, 1.18),
        "neck2": (0, 0.66, 1.5), "head": (0, 0.74, 1.64), "nose": (0, 1.0, 1.52), "tail": (0, -0.66, 1.02), "tail2": (0, -0.72, 0.9),
        "ear.L": (0.07, 0.72, 1.72), "ear_t.L": (0.17, 0.68, 1.86), "ear.R": (-0.07, 0.72, 1.72), "ear_t.R": (-0.17, 0.68, 1.86),
        "sh.L": (0.15, 0.36, 0.96), "el.L": (0.14, 0.38, 0.62), "ca.L": (0.13, 0.36, 0.32), "fh.L": (0.13, 0.39, 0.03),
        "sh.R": (-0.15, 0.36, 0.96), "el.R": (-0.14, 0.38, 0.62), "ca.R": (-0.13, 0.36, 0.32), "fh.R": (-0.13, 0.39, 0.03),
        "hp.L": (0.15, -0.5, 0.98), "st.L": (0.16, -0.36, 0.62), "ho.L": (0.14, -0.6, 0.4), "hh.L": (0.13, -0.53, 0.03),
        "hp.R": (-0.15, -0.5, 0.98), "st.R": (-0.16, -0.36, 0.62), "ho.R": (-0.14, -0.6, 0.4), "hh.R": (-0.13, -0.53, 0.03),
    },
    "radii": {
        "hips": (0.17, 0.2), "spine": (0.19, 0.25), "chest": (0.18, 0.26), "neck": (0.1, 0.15), "neck2": (0.07, 0.08),
        "head": (0.075, 0.09), "nose": (0.035, 0.04), "tail": (0.05, 0.05), "tail2": (0.02, 0.02),
        "ear.L": (0.03, 0.012), "ear_t.L": (0.008, 0.004), "ear.R": (0.03, 0.012), "ear_t.R": (0.008, 0.004),
        "sh.L": (0.1, 0.14), "el.L": (0.055, 0.065), "ca.L": (0.025, 0.028), "fh.L": (0.022, 0.025),
        "sh.R": (0.1, 0.14), "el.R": (0.055, 0.065), "ca.R": (0.025, 0.028), "fh.R": (0.022, 0.025),
        "hp.L": (0.13, 0.17), "st.L": (0.075, 0.1), "ho.L": (0.028, 0.035), "hh.L": (0.022, 0.025),
        "hp.R": (0.13, 0.17), "st.R": (0.075, 0.1), "ho.R": (0.028, 0.035), "hh.R": (0.022, 0.025),
    },
    "coat": {"side": (0.52, 0.31, 0.18), "back": (0.33, 0.2, 0.12), "belly": (0.82, 0.74, 0.62), "legs": (0.42, 0.29, 0.19),
             "dark": (0.07, 0.06, 0.05), "rump": (0.86, 0.8, 0.7)},
}

WOLF = {
    "name": "Wolf",
    "joints": {
        "hips": (0, -0.42, 0.74), "spine": (0, -0.12, 0.76), "chest": (0, 0.2, 0.76), "neck": (0, 0.36, 0.82),
        "neck2": (0, 0.5, 0.92), "head": (0, 0.6, 0.94), "nose": (0, 0.86, 0.88), "tail": (0, -0.56, 0.72), "tail2": (0, -0.85, 0.42),
        "ear.L": (0.06, 0.6, 1.02), "ear_t.L": (0.08, 0.58, 1.13), "ear.R": (-0.06, 0.6, 1.02), "ear_t.R": (-0.08, 0.58, 1.13),
        "sh.L": (0.11, 0.24, 0.66), "el.L": (0.1, 0.26, 0.42), "ca.L": (0.09, 0.25, 0.18), "fh.L": (0.09, 0.3, 0.03),
        "sh.R": (-0.11, 0.24, 0.66), "el.R": (-0.1, 0.26, 0.42), "ca.R": (-0.09, 0.25, 0.18), "fh.R": (-0.09, 0.3, 0.03),
        "hp.L": (0.11, -0.44, 0.68), "st.L": (0.12, -0.32, 0.44), "ho.L": (0.1, -0.5, 0.24), "hh.L": (0.09, -0.44, 0.03),
        "hp.R": (-0.11, -0.44, 0.68), "st.R": (-0.12, -0.32, 0.44), "ho.R": (-0.1, -0.5, 0.24), "hh.R": (-0.09, -0.44, 0.03),
    },
    "radii": {
        "hips": (0.12, 0.15), "spine": (0.13, 0.17), "chest": (0.14, 0.2), "neck": (0.12, 0.15), "neck2": (0.1, 0.11),
        "head": (0.09, 0.09), "nose": (0.035, 0.035), "tail": (0.07, 0.07), "tail2": (0.05, 0.045),
        "ear.L": (0.035, 0.01), "ear_t.L": (0.006, 0.004), "ear.R": (0.035, 0.01), "ear_t.R": (0.006, 0.004),
        "sh.L": (0.075, 0.1), "el.L": (0.045, 0.05), "ca.L": (0.022, 0.025), "fh.L": (0.028, 0.035),
        "sh.R": (0.075, 0.1), "el.R": (0.045, 0.05), "ca.R": (0.022, 0.025), "fh.R": (0.028, 0.035),
        "hp.L": (0.09, 0.12), "st.L": (0.055, 0.075), "ho.L": (0.024, 0.028), "hh.L": (0.028, 0.035),
        "hp.R": (0.09, 0.12), "st.R": (0.055, 0.075), "ho.R": (0.024, 0.028), "hh.R": (0.028, 0.035),
    },
    "coat": {"side": (0.4, 0.37, 0.33), "back": (0.18, 0.17, 0.16), "belly": (0.74, 0.7, 0.62), "legs": (0.46, 0.41, 0.35),
             "dark": (0.08, 0.07, 0.07), "rump": (0.55, 0.5, 0.44)},
}

# Bone chain: (bone, head joint, tail joint, parent bone)
BONES = [
    ("hips", "tail", "hips", None), ("spine", "hips", "spine", "hips"), ("chest", "spine", "chest", "spine"),
    ("neck", "chest", "neck", "chest"), ("neck2", "neck", "neck2", "neck"), ("head", "neck2", "head", "neck2"),
    ("snout", "head", "nose", "head"), ("tail", "tail", "tail2", "hips"),
    ("ear.L", "ear.L", "ear_t.L", "head"), ("ear.R", "ear.R", "ear_t.R", "head"),
]
for s in ("L", "R"):
    BONES += [(f"upperarm.{s}", f"sh.{s}", f"el.{s}", "chest"), (f"forearm.{s}", f"el.{s}", f"ca.{s}", f"upperarm.{s}"),
              (f"hoof_f.{s}", f"ca.{s}", f"fh.{s}", f"forearm.{s}"),
              (f"thigh.{s}", f"hp.{s}", f"st.{s}", "hips"), (f"shin.{s}", f"st.{s}", f"ho.{s}", f"thigh.{s}"),
              (f"hoof_h.{s}", f"ho.{s}", f"hh.{s}", f"shin.{s}")]
# Edges of the skin graph (joint pairs)
EDGES = [("tail2", "tail"), ("tail", "hips"), ("hips", "spine"), ("spine", "chest"), ("chest", "neck"), ("neck", "neck2"),
         ("neck2", "head"), ("head", "nose"), ("head", "ear.L"), ("ear.L", "ear_t.L"), ("head", "ear.R"), ("ear.R", "ear_t.R")]
for s in ("L", "R"):
    EDGES += [("chest", f"sh.{s}"), (f"sh.{s}", f"el.{s}"), (f"el.{s}", f"ca.{s}"), (f"ca.{s}", f"fh.{s}"),
              ("hips", f"hp.{s}"), (f"hp.{s}", f"st.{s}"), (f"st.{s}", f"ho.{s}"), (f"ho.{s}", f"hh.{s}")]


def _lin(c):
    return Vector([pow(max(x, 0.0), 2.2) for x in c])


def coat_color(sp, p, n, joints):
    """p = vertex position, n = vertex normal. Colours authored in sRGB, stored linear."""
    c = sp["coat"]
    back_z = joints["spine"][2]
    leg = p.z < back_z - 0.32
    col = Vector(c["side"])
    if n.z > 0.45 and not leg:  # darker dorsal saddle
        col = col.lerp(Vector(c["back"]), min(1.0, (n.z - 0.45) * 2.5))
    if n.z < -0.3 and not leg:  # pale belly / throat
        col = col.lerp(Vector(c["belly"]), min(1.0, (-n.z - 0.3) * 2.5))
    if leg:
        col = Vector(c["legs"]).lerp(Vector(c["dark"]), max(0.0, 0.22 - p.z) * 2.5)
    if p.y < joints["hips"][1] - 0.05 and n.y < -0.4 and p.z > back_z - 0.4:  # rump patch
        col = col.lerp(Vector(c["rump"]), 0.85)
    if p.y > joints["nose"][1] - 0.05:
        col = Vector(c["dark"])
    if p.z > joints["ear.L"][2] + 0.06:
        col = col.lerp(Vector(c["dark"]), 0.5)
    return (*_lin(col), 1.0)


def material(sp):
    m = bpy.data.materials.new(f"M_{sp['name']}Coat")
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    vc = nt.nodes.new("ShaderNodeVertexColor"); vc.layer_name = "Col"
    det = nt.nodes.new("ShaderNodeTexImage")
    det.image = bpy.data.images.load(os.path.join(TEX, "brown_leather_nor_gl_1k.jpg"))
    det.image.colorspace_settings.name = "Non-Color"
    nm = nt.nodes.new("ShaderNodeNormalMap"); nm.inputs["Strength"].default_value = 0.6
    nt.links.new(det.outputs["Color"], nm.inputs["Color"]); nt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
    nt.links.new(vc.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = 0.85
    return m


def build_body(sp):
    J = {k: Vector(v) for k, v in sp["joints"].items()}
    names = list(J.keys())
    me = bpy.data.meshes.new(sp["name"] + "Body")
    me.from_pydata([J[n] for n in names], [(names.index(a), names.index(b)) for a, b in EDGES], [])
    obj = bpy.data.objects.new(sp["name"], me)
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    skin = obj.modifiers.new("skin", "SKIN")
    skin.use_smooth_shade = True
    for i, n in enumerate(names):
        r = sp["radii"][n]
        obj.data.skin_vertices[0].data[i].radius = r
        obj.data.skin_vertices[0].data[i].use_root = n == "chest"
    sub = obj.modifiers.new("sub", "SUBSURF"); sub.levels = 2; sub.render_levels = 2
    obj.select_set(True)
    bpy.ops.object.modifier_apply(modifier="skin")
    bpy.ops.object.modifier_apply(modifier="sub")
    # Vertex-colour coat
    ca = obj.data.color_attributes.new("Col", "BYTE_COLOR", "CORNER")
    for poly in obj.data.polygons:
        for li in poly.loop_indices:
            vert = obj.data.vertices[obj.data.loops[li].vertex_index]
            ca.data[li].color = coat_color(sp, vert.co, vert.normal, sp["joints"])
    obj.data.materials.append(material(sp))
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.02)
    bpy.ops.object.mode_set(mode="OBJECT")
    for p in obj.data.polygons:
        p.use_smooth = True
    return obj


def build_rig(sp):
    J = {k: Vector(v) for k, v in sp["joints"].items()}
    arm = bpy.data.armatures.new(sp["name"] + "Rig")
    rig = bpy.data.objects.new(sp["name"] + "Rig", arm)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    for name, h, t, parent in BONES:
        b = arm.edit_bones.new(name)
        b.head, b.tail = J[h], J[t]
        if (b.tail - b.head).length < 0.01:
            b.tail = b.head + Vector((0, 0.05, 0))
        b.align_roll(Vector((0, 1, 0)) if abs((b.tail - b.head).normalized().y) < 0.8 else Vector((0, 0, 1)))
    for name, h, t, parent in BONES:
        if parent:
            arm.edit_bones[name].parent = arm.edit_bones[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return rig


# ---------------------------------------------------------------- animation

def key(rig, frame, rots, loc=None):
    for bone, (x, y, z) in rots.items():
        pb = rig.pose.bones[bone]
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = (math.radians(x), math.radians(y), math.radians(z))
        pb.keyframe_insert("rotation_euler", frame=frame)
    if loc is not None:
        pb = rig.pose.bones["hips"]
        pb.location = loc
        pb.keyframe_insert("location", frame=frame)


def all_bones_zero():
    return {b[0]: (0, 0, 0) for b in BONES}


def gait(rig, length_s, swing, lift, phases, bob):
    n = int(length_s * FPS)
    for f in range(n + 1):
        t = f / n
        r = all_bones_zero()
        for side, off in (("L", 0.0), ("R", 0.5)):
            pf = (t + phases["front"] + off) % 1.0
            ph = (t + phases["hind"] + off) % 1.0
            sf = math.sin(pf * math.tau)
            sh = math.sin(ph * math.tau)
            r[f"upperarm.{side}"] = (swing * sf, 0, 0)
            r[f"forearm.{side}"] = (-lift * max(0.0, -math.cos(pf * math.tau)), 0, 0)
            r[f"hoof_f.{side}"] = (lift * 0.6 * max(0.0, -math.cos(pf * math.tau)), 0, 0)
            r[f"thigh.{side}"] = (swing * sh, 0, 0)
            r[f"shin.{side}"] = (lift * 0.8 * max(0.0, -math.cos(ph * math.tau)), 0, 0)
            r[f"hoof_h.{side}"] = (-lift * 0.5 * max(0.0, -math.cos(ph * math.tau)), 0, 0)
        r["neck"] = (3 * math.sin(t * math.tau * 2), 0, 0)
        r["tail"] = (5 * math.sin(t * math.tau * 2), 0, 4 * math.sin(t * math.tau))
        key(rig, f + 1, r, (0, 0, -bob * abs(math.sin(t * math.tau * 2))))
    return n


def clip_idle(rig):
    n = 4 * FPS
    for f in range(0, n + 1, 4):
        t = f / n
        r = all_bones_zero()
        r["chest"] = (1.2 * math.sin(t * math.tau * 2), 0, 0)
        r["head"] = (4 * math.sin(t * math.tau), 0, 6 * math.sin(t * math.tau * 0.5 + 1))
        r["ear.L"] = (0, 0, 10 * max(0, math.sin(t * math.tau * 3)))
        r["tail"] = (0, 0, 8 * math.sin(t * math.tau * 4))
        key(rig, f + 1, r, (0, 0, 0))
    return n


def clip_graze(rig):
    n = 3 * FPS
    for f in range(0, n + 1, 3):
        t = f / n
        r = all_bones_zero()
        r["neck"] = (-48, 0, 0)
        r["neck2"] = (-22 + 6 * math.sin(t * math.tau * 3), 0, 0)
        r["head"] = (-14, 0, 5 * math.sin(t * math.tau))
        r["upperarm.L"] = (8, 0, 0)
        r["upperarm.R"] = (8, 0, 0)
        key(rig, f + 1, r, (0, 0, -0.02))
    return n


def clip_alert(rig):
    n = 2 * FPS
    for f in range(0, n + 1, 2):
        t = f / n
        r = all_bones_zero()
        r["neck"] = (14, 0, 0)
        r["head"] = (6, 0, 12 * math.sin(t * math.tau))
        r["ear.L"] = (20, 0, -10)
        r["ear.R"] = (20, 0, 10)
        r["tail"] = (25, 0, 0)
        key(rig, f + 1, r, (0, 0, 0.02))
    return n


def clip_attack(rig):
    n = int(0.9 * FPS)
    for f in range(n + 1):
        t = f / n
        lunge = math.sin(min(t / 0.45, 1.0) * math.pi) if t < 0.45 else max(0.0, 1 - (t - 0.45) / 0.55) * 0.2
        r = all_bones_zero()
        r["chest"] = (-8 * lunge, 0, 0)
        r["neck"] = (-12 * lunge, 0, 0)
        r["head"] = (18 * lunge, 0, 0)
        r["snout"] = (-15 * lunge, 0, 0)
        for s in ("L", "R"):
            r[f"upperarm.{s}"] = (-30 * lunge, 0, 0)
            r[f"thigh.{s}"] = (25 * lunge, 0, 0)
        key(rig, f + 1, r, (0, 0.25 * lunge, 0.08 * lunge))
    return n


def clip_death(rig, height):
    n = int(1.3 * FPS)
    for f in range(n + 1):
        t = min(f / n / 0.8, 1.0)
        e = t * t * (3 - 2 * t)
        r = all_bones_zero()
        r["hips"] = (0, 88 * e, 0)
        r["neck"] = (-25 * e, 0, 0)
        r["head"] = (-20 * e, 0, 0)
        for s in ("L", "R"):
            r[f"upperarm.{s}"] = (25 * e, 0, 0)
            r[f"thigh.{s}"] = (-20 * e, 0, 0)
            r[f"forearm.{s}"] = (-30 * e, 0, 0)
        key(rig, f + 1, r, (0, 0, -height * 0.72 * e))
    return n


def make_clips(rig, sp):
    rig.animation_data_create()
    height = sp["joints"]["spine"][2]
    clips = {
        "idle": lambda: clip_idle(rig),
        "walk": lambda: gait(rig, 1.15, 22, 35, {"front": 0.25, "hind": 0.0}, 0.015),
        "run": lambda: gait(rig, 0.55, 38, 60, {"front": 0.1, "hind": 0.0}, 0.05),
        "graze": lambda: clip_graze(rig),
        "alert": lambda: clip_alert(rig),
        "attack": lambda: clip_attack(rig),
        "death": lambda: clip_death(rig, height),
    }
    for name, fn in clips.items():
        act = bpy.data.actions.new(name)
        rig.animation_data.action = act
        for pb in rig.pose.bones:
            pb.rotation_mode = "XYZ"
            pb.rotation_euler = (0, 0, 0)
            pb.location = (0, 0, 0)
        frames = fn()
        track = rig.animation_data.nla_tracks.new()
        track.name = name
        strip = track.strips.new(name, 1, act)
        strip.action_frame_end = frames + 1
        rig.animation_data.action = None
    return list(clips.keys())


def main():
    for sp in (DEER, WOLF):
        bpy.ops.wm.read_factory_settings(use_empty=True)
        bpy.context.scene.render.fps = FPS
        body = build_body(sp)
        rig = build_rig(sp)
        bpy.ops.object.select_all(action="DESELECT")
        body.select_set(True)
        rig.select_set(True)
        bpy.context.view_layer.objects.active = rig
        bpy.ops.object.parent_set(type="ARMATURE_AUTO")
        groups = len(body.vertex_groups)
        clips = make_clips(rig, sp)
        tris = sum(len(p.vertices) - 2 for p in body.data.polygons)
        bpy.ops.object.select_all(action="DESELECT")
        body.select_set(True)
        rig.select_set(True)  # only our objects (add-ons may inject scene objects)
        path = os.path.join(OUT, f"SK_{sp['name']}.gltf")
        bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="textures",
                                  use_selection=True, export_yup=True, export_animations=True,
                                  export_animation_mode="NLA_TRACKS", export_skins=True, export_vertex_color="ACTIVE")
        print("ANIMAL", sp["name"], "tris", tris, "groups", groups, "clips", clips)


main()
