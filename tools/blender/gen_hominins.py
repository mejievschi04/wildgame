# Prehistoric human races from the concept sheet (docs: PHASE3B_TRIBES / hominin concept).
#   blender -b --python tools/blender/gen_hominins.py -- [SapiensM SapiensF ...]
# MPFB body + species morph targets → 5 facial-expression blend shapes (MakeHuman expression units) →
# baked skin (pores, mottling, dirt, face paint, brows, lips) on the MakeHuman UVs → iris eyes →
# strand-card hair/beard that drapes over the body (BVH collision) → hide/fur garments from the concept
# (mantle, crossed straps, belt, strip kilt/skirt, fur boots, wrist wraps, tooth necklace) → game_engine rig,
# clips and severable parts reused from gen_humans.py. Output: assets/models/humans/SK_Human_<variant>.gltf
import bpy, bmesh, math, os, sys, random
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_humans as gh
import fauna_lib as fl
from bl_ext.blender_org.mpfb.services.humanservice import HumanService
from bl_ext.blender_org.mpfb.services.targetservice import TargetService

ROOT = gh.ROOT
OUT = gh.OUT
TARGETS = os.path.dirname(os.path.dirname(TargetService.target_full_path("forehead-nubian-incr")))
MPFB_TEX = os.path.join(os.path.dirname(TARGETS), "textures")
lin = fl.lin
BONE_NAMES = set()  # filled per build from the rig

# Facial expressions of the concept sheet (neutral = rest). MakeHuman expression units, both sides.
EXPRESSIONS = {
    "focused": {"eyebrows-*-down": 0.45, "eye-*-slit": 0.35, "mouth-compression": 0.45},
    "angry": {"eyebrows-*-down": 1.0, "eye-*-slit": 0.45, "nose-*-elevation": 0.7, "mouth-upward-retraction": 0.6,
              "mouth-open": 0.35, "mouth-retraction": 0.3},
    "surprised": {"eyebrows-*-up": 1.0, "eye-*-opened-up": 0.9, "mouth-open": 0.7},
    "pain": {"eyebrows-*-inner-up": 1.0, "eye-*-closure": 0.55, "nose-*-elevation": 0.5, "mouth-retraction": 0.8,
             "mouth-open": 0.3, "neck-platysma": 0.5},
    "happy": {"mouth-corner-puller": 1.0, "mouth-parling": 0.35, "eye-*-slit": 0.3, "eyebrows-*-extern-up": 0.25},
}


# ============================================================== body

def make_body(spec, sex):
    d = TargetService.get_default_macro_info_dict()
    m = dict(spec["macro"][sex])
    race = m.pop("race")
    d.update(m)
    d["race"] = race
    bm = HumanService.create_human(scale=0.1, macro_detail_dict=d)
    for name, w in spec.get("morphs", {}).items():
        TargetService.load_target(bm, TargetService.target_full_path(name), weight=w, name=name)
    rig = HumanService.add_builtin_rig(bm, "game_engine")
    bpy.context.view_layer.objects.active = bm
    if bm.data.shape_keys:  # bake macros + species morphs
        bm.shape_key_add(name="final", from_mix=True)
        final = bm.data.shape_keys.key_blocks["final"]
        for v, k in zip(bm.data.vertices, final.data):
            v.co = k.co
        bm.shape_key_clear()
    add_expressions(bm, spec["face_units"])
    eyes = []
    gidx = {g.index: g.name for g in bm.vertex_groups}
    for side in ("l", "r"):
        gi = next(g.index for g in bm.vertex_groups if g.name == f"helper-{side}-eye")
        pts = [v.co.copy() for v in bm.data.vertices if any(g.group == gi and g.weight > 0.5 for g in v.groups)]
        c = sum(pts, Vector()) / len(pts)
        r = max((p - c).length for p in pts)
        eyes.append((c, r))
    bmh = bmesh.new()
    bmh.from_mesh(bm.data)
    deform = bmh.verts.layers.deform.active
    kill = [v for v in bmh.verts if not ({gidx[i] for i in v[deform].keys()} & {"body"})]
    bmesh.ops.delete(bmh, geom=kill, context="VERTS")
    bmh.to_mesh(bm.data)
    bmh.free()
    for mod in list(bm.modifiers):
        if mod.type == "MASK":
            bm.modifiers.remove(mod)
    for p in bm.data.polygons:
        p.use_smooth = True
    return bm, rig, eyes


def add_expressions(bm, race):
    units = os.path.join(TARGETS, "expression", "units", race)
    names = sorted(f[:-10] for f in os.listdir(units) if f.endswith(".target.gz"))
    if not bm.data.shape_keys:
        bm.shape_key_add(name="Basis", from_mix=False)
    for n in names:
        TargetService.load_target(bm, os.path.join(units, n + ".target.gz"), weight=0.0, name="u_" + n)
    keys = bm.data.shape_keys.key_blocks
    for expr, mix in EXPRESSIONS.items():
        for k in keys:
            k.value = 0.0
        for unit, w in mix.items():
            for side in (("left", "right") if "*" in unit else ("",)):
                kn = "u_" + unit.replace("*", side)
                if kn in keys:
                    keys[kn].value = w
        bm.shape_key_add(name="expr_" + expr, from_mix=True)
    for k in list(bm.data.shape_keys.key_blocks):
        if k.name.startswith("u_"):
            bm.shape_key_remove(k)
    for k in bm.data.shape_keys.key_blocks:
        k.value = 0.0


def keyless_copy(obj, name):
    c = obj.copy()
    c.data = obj.data.copy()
    c.name = name
    bpy.context.scene.collection.objects.link(c)
    if c.data.shape_keys:
        c.shape_key_clear()
    return c


def landmarks(rig):
    b = rig.data.bones
    L = lambda n: b[n].head_local.copy()
    return {"hip": L("thigh_l"), "knee": L("calf_l"), "ankle": L("foot_l"), "shoulder": L("upperarm_l"),
            "neck": L("neck_01"), "head": L("head"), "chest": L("spine_03"), "waist": L("spine_01"),
            "wrist_l": L("hand_l"), "wrist_r": L("hand_r"), "elbow_l": L("lowerarm_l"), "elbow_r": L("lowerarm_r")}


def head_frame(body):
    """Bounds of the head (vertices dominated by the head bone) → normalised face coordinates."""
    gn = {g.index: g.name for g in body.vertex_groups}
    hv = [v.co for v in body.data.vertices if gh.dominant_bone(v, gn, {"head", "neck_01"}) == "head"]
    xs, ys, zs = [c.x for c in hv], [c.y for c in hv], [c.z for c in hv]
    return {"x": (min(xs), max(xs)), "y": (min(ys), max(ys)), "z": (min(zs), max(zs))}


def hcoords(c, hf):
    """xx: |x| / half width, yy: 0 front (face, -Y) … 1 back, zz: 0 chin/neck … 1 crown."""
    w = (hf["x"][1] - hf["x"][0]) / 2
    return abs(c.x) / w, (c.y - hf["y"][0]) / (hf["y"][1] - hf["y"][0]), (c.z - hf["z"][0]) / (hf["z"][1] - hf["z"][0])


def in_scalp(xx, yy, zz):
    return zz >= 0.78 - 0.5 * yy and not (yy < 0.2 and zz < 0.79)


def in_beard(xx, yy, zz):
    if yy > 0.62 or zz > 0.47 or zz < 0.02:
        return False
    if xx < 0.28 and 0.22 < zz < 0.33 and yy < 0.12:   # lips stay clear
        return False
    return not (zz > 0.40 and xx < 0.5)                # cheeks above the moustache line stay bare


# ============================================================== skin

def skin_attributes(body, spec, sex, lm, hf):
    gn = {g.index: g.name for g in body.vertex_groups}
    bones = {b for b in gh.TORSO | gh.UPPERARM | gh.LEGS_UP | gh.LEGS_LOW | gh.FEET |
             {"head", "lowerarm_l", "lowerarm_r", "hand_l", "hand_r"}}
    me = body.data
    n = len(me.vertices)
    tone = np.zeros((n, 4)); dirt = np.zeros(n); paint = np.zeros(n); brow = np.zeros(n); oily = np.zeros(n); wrinkle = np.zeros(n)
    scalp = np.zeros(n); beardz = np.zeros(n)
    base = Vector(spec["skin"][sex]); red = Vector(spec.get("skin_red", (0.62, 0.30, 0.24)))
    age = spec["macro"][sex]["age"]
    for v in me.vertices:
        c = v.co
        b = gh.dominant_bone(v, gn, bones) or "pelvis"
        t = base.copy()
        if b == "head":
            xx, yy, zz = hcoords(c, hf)
            if yy < 0.45 and 0.3 < zz < 0.6 and xx > 0.25:
                t = t.lerp(red, 0.18)                                             # flushed cheeks
            if yy < 0.12 and 0.38 < zz < 0.55 and xx < 0.2:
                t = t.lerp(red, 0.22); oily[v.index] = 1                          # nose
            if yy > 0.25 and xx > 0.85:
                t = t.lerp(red, 0.25)                                             # ears
            if yy < 0.3 and 0.62 < zz < 0.68 and 0.12 < xx < 0.62:
                brow[v.index] = 1.0 - abs(zz - 0.65) / 0.03                       # eyebrows
            if yy < 0.35 and zz > 0.68:
                oily[v.index] = 0.6; wrinkle[v.index] = age                       # forehead
            paint[v.index] = spec["paint"](xx, yy, zz, c.x)
            scalp[v.index] = 1.0 if in_scalp(xx, yy, zz) else 0.0
            if spec["beard"][sex] > 0 and in_beard(xx, yy, zz):
                beardz[v.index] = 1.0
        if b in ("hand_l", "hand_r") or b.startswith(("index", "middle", "ring", "pinky", "thumb")):
            dirt[v.index] = 0.5
        if b in gh.FEET:
            dirt[v.index] = 0.9
        if b in gh.LEGS_LOW:
            dirt[v.index] = max(dirt[v.index], 0.6 * max(0.0, 1 - (c.z - lm["ankle"].z) / 0.35))
        if b in ("calf_l", "calf_r") and abs(c.z - lm["knee"].z) < 0.06 and c.y < 0:
            t = t.lerp(red, 0.15)                                                 # knees
        tone[v.index, :3] = lin(tuple(t)); tone[v.index, 3] = 1
    nb = [[] for _ in range(n)]
    for e in me.edges:
        a_, b_ = e.vertices
        nb[a_].append(b_); nb[b_].append(a_)

    def smooth(arr, it):
        for _ in range(it):
            arr = np.array([0.5 * arr[i] + 0.5 * (arr[nb[i]].mean() if nb[i] else arr[i]) for i in range(n)])
        return arr
    paint = smooth(paint, 2); scalp = smooth(scalp, 3); beardz = smooth(beardz, 3); brow = smooth(brow, 2)
    ca = me.color_attributes.new("Tone", "FLOAT_COLOR", "POINT")
    ca.data.foreach_set("color", tone.astype(np.float32).ravel())
    for nm, arr in (("dirt", dirt), ("paint", paint), ("brow", np.clip(brow, 0, 1)), ("oily", oily), ("wrinkle", wrinkle),
                    ("m_scalp", scalp), ("beardz", beardz)):
        at = me.attributes.new(nm, "FLOAT", "POINT")
        at.data.foreach_set("value", arr.astype(np.float32))


def skin_bake_material(spec, sex):
    m = bpy.data.materials.new("M_SkinBake")
    m.use_nodes = True
    N, L = m.node_tree.nodes, m.node_tree.links
    b = N["Principled BSDF"]
    tone = N.new("ShaderNodeVertexColor"); tone.layer_name = "Tone"
    A = {}
    for nm in ("dirt", "paint", "brow", "oily", "wrinkle", "m_scalp", "beardz"):
        a = N.new("ShaderNodeAttribute"); a.attribute_name = nm; A[nm] = a
    tc = N.new("ShaderNodeTexCoord")
    uv = N.new("ShaderNodeUVMap"); uv.uv_map = "UVMap"

    def noise(scale, detail=4.0, rough=0.6, coords=None, dims="3D"):
        nz = N.new("ShaderNodeTexNoise"); nz.inputs["Scale"].default_value = scale
        nz.inputs["Detail"].default_value = detail; nz.inputs["Roughness"].default_value = rough
        L.new((coords or tc.outputs["Object"]), nz.inputs["Vector"])
        return nz

    def mixc(fac_socket, a_sock, b_col, fac_mul=None):
        mx = N.new("ShaderNodeMix"); mx.data_type = "RGBA"
        if fac_mul is not None:
            mm = N.new("ShaderNodeMath"); mm.operation = "MULTIPLY"; mm.inputs[1].default_value = fac_mul
            L.new(fac_socket, mm.inputs[0]); fac_socket = mm.outputs[0]
        L.new(fac_socket, mx.inputs["Factor"])
        L.new(a_sock, mx.inputs[6])
        if isinstance(b_col, tuple):
            mx.inputs[7].default_value = (*lin(b_col), 1)
        else:
            L.new(b_col, mx.inputs[7])
        return mx.outputs[2]

    # mottled base: low-frequency colour variation
    mot = noise(18.0, 3.0)
    mr = N.new("ShaderNodeMapRange"); L.new(mot.outputs["Fac"], mr.inputs["Value"])
    mr.inputs["To Min"].default_value = 0.9; mr.inputs["To Max"].default_value = 1.08
    mul = N.new("ShaderNodeMix"); mul.data_type = "RGBA"; mul.blend_type = "MULTIPLY"; mul.inputs["Factor"].default_value = 1.0
    L.new(tone.outputs["Color"], mul.inputs[6])
    cm = N.new("ShaderNodeCombineColor")
    for i in range(3):
        L.new(mr.outputs["Result"], cm.inputs[i])
    L.new(cm.outputs["Color"], mul.inputs[7])
    col = mul.outputs[2]
    # dirt: grimy brown, broken up by noise
    dn = noise(40.0, 6.0, 0.7)
    dm = N.new("ShaderNodeMath"); dm.operation = "MULTIPLY"
    L.new(A["dirt"].outputs["Fac"], dm.inputs[0]); L.new(dn.outputs["Fac"], dm.inputs[1])
    col = mixc(dm.outputs[0], col, (0.24, 0.18, 0.12), 1.2)
    # lips & eyelids from MPFB's UV masks
    for img, colr, k in (("mpfb_lips.jpg", spec.get("lips", (0.42, 0.22, 0.20)), 0.55), ("mpfb_eyelids.jpg", (0.30, 0.20, 0.17), 0.25)):
        p = os.path.join(MPFB_TEX, img)
        if os.path.exists(p):
            t = N.new("ShaderNodeTexImage"); t.image = bpy.data.images.load(p, check_existing=True)
            t.image.colorspace_settings.name = "Non-Color"
            L.new(uv.outputs["UV"], t.inputs["Vector"])
            col = mixc(t.outputs["Color"], col, colr, k)
    # eyebrows (hair colour) with hair-like streaks
    bn = noise(900.0, 2.0, 0.5)
    bm_ = N.new("ShaderNodeMath"); bm_.operation = "MULTIPLY"
    L.new(A["brow"].outputs["Fac"], bm_.inputs[0]); L.new(bn.outputs["Fac"], bm_.inputs[1])
    col = mixc(bm_.outputs[0], col, tuple(x * 0.7 for x in spec["hair"][sex]), 1.6)
    # face paint: chalky, brushed edges
    pn = noise(70.0, 5.0, 0.7)
    pm = N.new("ShaderNodeMapRange"); L.new(pn.outputs["Fac"], pm.inputs["Value"])
    pm.inputs["From Min"].default_value = 0.25; pm.inputs["From Max"].default_value = 0.45
    pf = N.new("ShaderNodeMath"); pf.operation = "MULTIPLY_ADD"          # mask + (noise-0.5)*0.3
    L.new(pn.outputs["Fac"], pf.inputs[0]); pf.inputs[1].default_value = 0.3; pf.inputs[2].default_value = -0.15
    pf2 = N.new("ShaderNodeMath"); pf2.operation = "ADD"
    L.new(A["paint"].outputs["Fac"], pf2.inputs[0]); L.new(pf.outputs[0], pf2.inputs[1])
    pc = N.new("ShaderNodeMapRange"); pc.clamp = True
    L.new(pf2.outputs[0], pc.inputs["Value"]); pc.inputs["From Min"].default_value = 0.38; pc.inputs["From Max"].default_value = 0.55
    col = mixc(pc.outputs["Result"], col, spec.get("paint_color", (0.86, 0.83, 0.76)), 0.95)
    # hair-coloured scalp and beard base (no skin shows between the strand cards)
    hn = noise(500.0, 3.0, 0.6)
    hc = N.new("ShaderNodeMapRange"); L.new(hn.outputs["Fac"], hc.inputs["Value"])
    hc.inputs["To Min"].default_value = 0.55; hc.inputs["To Max"].default_value = 1.25
    hcol = N.new("ShaderNodeCombineColor")
    hcm = N.new("ShaderNodeMix"); hcm.data_type = "RGBA"; hcm.blend_type = "MULTIPLY"; hcm.inputs["Factor"].default_value = 1.0
    hcm.inputs[6].default_value = (*lin(tuple(x * 0.6 for x in spec["hair"][sex])), 1)
    for i in range(3):
        L.new(hc.outputs["Result"], hcol.inputs[i])
    L.new(hcol.outputs["Color"], hcm.inputs[7])
    for key, k in (("m_scalp", 0.97), ("beardz", 0.85)):
        e = N.new("ShaderNodeMath"); e.operation = "MULTIPLY_ADD"
        L.new(hn.outputs["Fac"], e.inputs[0]); e.inputs[1].default_value = 0.5; e.inputs[2].default_value = -0.25
        e2 = N.new("ShaderNodeMath"); e2.operation = "ADD"; L.new(A[key].outputs["Fac"], e2.inputs[0]); L.new(e.outputs[0], e2.inputs[1])
        e3 = N.new("ShaderNodeMapRange"); e3.clamp = True; L.new(e2.outputs[0], e3.inputs["Value"])
        e3.inputs["From Min"].default_value = 0.35; e3.inputs["From Max"].default_value = 0.65
        col = mixc(e3.outputs["Result"], col, hcm.outputs[2], k)
    L.new(col, b.inputs["Base Color"])
    # pores + forehead wrinkles → bump
    pore = noise(1400.0, 2.0, 0.5)
    wave = N.new("ShaderNodeTexWave"); wave.wave_type = "BANDS"; wave.bands_direction = "Z"
    wave.inputs["Scale"].default_value = 90.0; wave.inputs["Distortion"].default_value = 3.0
    L.new(tc.outputs["Object"], wave.inputs["Vector"])
    wm = N.new("ShaderNodeMath"); wm.operation = "MULTIPLY"
    L.new(wave.outputs["Fac"], wm.inputs[0]); L.new(A["wrinkle"].outputs["Fac"], wm.inputs[1])
    wm2 = N.new("ShaderNodeMath"); wm2.operation = "MULTIPLY"; wm2.inputs[1].default_value = 0.25
    L.new(wm.outputs[0], wm2.inputs[0]); wm = wm2
    hs = N.new("ShaderNodeMath"); hs.operation = "MULTIPLY_ADD"
    L.new(pore.outputs["Fac"], hs.inputs[0]); hs.inputs[1].default_value = 0.6; L.new(wm.outputs[0], hs.inputs[2])
    bump = N.new("ShaderNodeBump"); bump.inputs["Strength"].default_value = 0.35; bump.inputs["Distance"].default_value = 0.0015
    bump.inputs["Strength"].default_value = 0.22
    L.new(hs.outputs[0], bump.inputs["Height"]); L.new(bump.outputs["Normal"], b.inputs["Normal"])
    # roughness: skin 0.55, oily zones 0.4, dirt 0.75
    r1 = N.new("ShaderNodeMath"); r1.operation = "MULTIPLY_ADD"
    L.new(A["oily"].outputs["Fac"], r1.inputs[0]); r1.inputs[1].default_value = -0.08; r1.inputs[2].default_value = 0.62
    r2 = N.new("ShaderNodeMath"); r2.operation = "MULTIPLY_ADD"
    L.new(A["dirt"].outputs["Fac"], r2.inputs[0]); r2.inputs[1].default_value = 0.2; L.new(r1.outputs[0], r2.inputs[2])
    r3 = N.new("ShaderNodeMath"); r3.operation = "MULTIPLY_ADD"
    L.new(A["m_scalp"].outputs["Fac"], r3.inputs[0]); r3.inputs[1].default_value = 0.4; L.new(r2.outputs[0], r3.inputs[2])
    L.new(r3.outputs[0], b.inputs["Roughness"])
    return m


def bake_skin(body, spec, sex, name, size=2048):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"; sc.cycles.device = "CPU"; sc.cycles.samples = 16
    fl.activate(body)
    body.data.uv_layers.active = body.data.uv_layers["UVMap"]
    mat = skin_bake_material(spec, sex)
    body.data.materials.clear(); body.data.materials.append(mat)
    nt = mat.node_tree
    tex = nt.nodes.new("ShaderNodeTexImage"); nt.nodes.active = tex
    imgs = {}
    for kind, data in (("albedo", False), ("normal", True), ("rough", True), ("ao", True)):
        img = fl.new_image(f"T_{name}_skin_{kind}", size if kind != "ao" else size // 2, data)
        tex.image = img
        if kind == "albedo":
            bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, margin=16, use_clear=True)
        elif kind == "normal":
            bpy.ops.object.bake(type="NORMAL", normal_space="TANGENT", margin=16, use_clear=True)
        elif kind == "rough":
            bpy.ops.object.bake(type="ROUGHNESS", margin=16, use_clear=True)
        else:
            sc.cycles.samples = 64
            bpy.ops.object.bake(type="AO", margin=16, use_clear=True)
        imgs[kind] = img
    ao = np.kron(np.array(imgs["ao"].pixels[:]).reshape(size // 2, size // 2, 4)[..., 0], np.ones((2, 2)))
    al = np.array(imgs["albedo"].pixels[:]).reshape(size, size, 4)
    al[..., :3] *= (0.55 + 0.45 * ao)[..., None]
    imgs["albedo"].pixels[:] = al.ravel()
    tdir = os.path.join(OUT, "textures"); os.makedirs(tdir, exist_ok=True)
    paths = {}
    for kind in ("albedo", "normal", "rough"):
        p = os.path.join(tdir, f"T_{name}_skin_{kind}.png")
        imgs[kind].filepath_raw = p; imgs[kind].file_format = "PNG"; imgs[kind].save()
        paths[kind] = p
    fm = bpy.data.materials.new(f"M_{name}_Skin")
    fm.use_nodes = True; fm.use_backface_culling = True
    N, L = fm.node_tree.nodes, fm.node_tree.links
    b = N["Principled BSDF"]
    ta = N.new("ShaderNodeTexImage"); ta.image = bpy.data.images.load(paths["albedo"])
    tn = N.new("ShaderNodeTexImage"); tn.image = bpy.data.images.load(paths["normal"]); tn.image.colorspace_settings.name = "Non-Color"
    tr = N.new("ShaderNodeTexImage"); tr.image = bpy.data.images.load(paths["rough"]); tr.image.colorspace_settings.name = "Non-Color"
    nmn = N.new("ShaderNodeNormalMap")
    L.new(ta.outputs["Color"], b.inputs["Base Color"])
    L.new(tn.outputs["Color"], nmn.inputs["Color"]); L.new(nmn.outputs["Normal"], b.inputs["Normal"])
    L.new(tr.outputs["Color"], b.inputs["Roughness"])
    b.inputs["Specular IOR Level"].default_value = 0.45
    body.data.materials.clear(); body.data.materials.append(fm)
    for nm in ("dirt", "paint", "brow", "oily", "wrinkle", "m_scalp", "beardz"):
        if nm in body.data.attributes:
            body.data.attributes.remove(body.data.attributes[nm])
    body.data.color_attributes.remove(body.data.color_attributes["Tone"])


# ============================================================== eyes

def iris_texture(name, iris_rgb, size=256):
    yy, xx = np.mgrid[0:size, 0:size] / (size - 1) * 2 - 1
    r = np.sqrt(xx ** 2 + yy ** 2)
    ang = np.arctan2(yy, xx)
    img = np.zeros((size, size, 4)); img[..., 3] = 1
    sclera = np.array([0.86, 0.82, 0.78])
    col = np.broadcast_to(sclera, (size, size, 3)).copy()
    col *= (1 - 0.12 * np.clip((r - 0.6) / 0.4, 0, 1))[..., None]               # shaded toward the edge
    iris = np.array(iris_rgb)
    streak = 0.75 + 0.25 * np.sin(ang * 37) * np.sin(ang * 11 + r * 9)
    ir = (r < 0.42)
    icol = iris[None, None, :] * (0.65 + 0.5 * (r / 0.42))[..., None] * streak[..., None]
    col = np.where(ir[..., None], icol, col)
    col = np.where(((r > 0.39) & (r < 0.43))[..., None], col * 0.35, col)        # limbal ring
    col = np.where((r < 0.15)[..., None], 0.02, col)                             # pupil
    img[..., :3] = np.clip(col, 0, 1)
    im = bpy.data.images.new(name, size, size)
    im.pixels[:] = img.ravel()
    p = os.path.join(OUT, "textures", name + ".png")
    im.filepath_raw = p; im.file_format = "PNG"; im.save()
    return p


def make_eyes(eyes, name, iris_rgb):
    path = iris_texture(f"T_{name}_eye", iris_rgb)
    m = bpy.data.materials.new(f"M_{name}_Eye")
    m.use_nodes = True
    N = m.node_tree.nodes
    t = N.new("ShaderNodeTexImage"); t.image = bpy.data.images.load(path)
    m.node_tree.links.new(t.outputs["Color"], N["Principled BSDF"].inputs["Base Color"])
    N["Principled BSDF"].inputs["Roughness"].default_value = 0.04
    N["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.8
    out = []
    for c, r in eyes:
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=20, v_segments=14, radius=r * 0.97)
        uvl = bm.loops.layers.uv.new("UVMap")
        for f in bm.faces:
            for lp in f.loops:
                p = lp.vert.co
                lp[uvl].uv = (0.5 + p.x / (2 * r * 0.97) * 1.9, 0.5 + p.z / (2 * r * 0.97) * 1.9)  # iris faces -Y
        bmesh.ops.translate(bm, verts=bm.verts, vec=c)
        me = bpy.data.meshes.new("Eye"); bm.to_mesh(me); bm.free()
        o = bpy.data.objects.new("Eye", me); bpy.context.scene.collection.objects.link(o)
        for p in o.data.polygons:
            p.use_smooth = True
        o.data.materials.append(m)
        fl.rigid_to_bone(o, "head")
        out.append(o)
    return out


# ============================================================== strand cards (hair, beard, fur trims) with body collision

def bvh_of(objs):
    bm = bmesh.new()
    for o in objs:
        tmp = bmesh.new(); tmp.from_mesh(o.data)
        tmp.transform(o.matrix_world)
        me = bpy.data.meshes.new("tmp"); tmp.to_mesh(me); tmp.free()
        bm.from_mesh(me); bpy.data.meshes.remove(me)
    bm.verts.ensure_lookup_table(); bm.faces.ensure_lookup_table()
    tree = BVHTree.FromBMesh(bm)
    return tree, bm


def hair_atlas(name, palette, w=1024, h=1024):
    """Human hair: thin, gently wavy strands with gaps, tapering to transparent tips."""
    rng = np.random.default_rng(abs(hash(name)) % 2**32)
    img = np.zeros((h, w, 4), dtype=np.float32)
    cw = w // 4
    rows = np.arange(h)
    for c in range(4):
        base = np.array(palette[c], float)
        for _ in range(90 if c < 2 else 60):
            x0 = c * cw + rng.uniform(4, cw - 4)
            y0 = int(h * rng.uniform(0.0, 0.3))                  # staggered roots: no solid band at v=0
            L = int((h - y0) * rng.uniform(0.75, 1.0))
            ys = rows[y0:y0 + L]; t = (ys - y0) / L
            xc = x0 + rng.uniform(-0.04, 0.04) * cw * t + 2.5 * np.sin(t * rng.uniform(5, 12) + rng.uniform(0, 6))
            wd = rng.uniform(0.9, 1.8) * (1 - 0.6 * t)
            colr = base * rng.uniform(0.75, 1.3)
            shade = (0.7 + 0.45 * t)[:, None] * colr[None, :]
            fade = np.clip((1 - t) * 1.4, 0, 1) * 0.95
            for dx in range(-3, 4):
                xs = np.clip(np.round(xc).astype(int) + dx, c * cw, c * cw + cw - 1)
                cov = np.clip(wd - np.abs(xs - xc) + 0.5, 0, 1) * fade
                old = img[ys, xs, 3]
                a = np.maximum(old, cov)
                img[ys, xs, :3] = np.where((cov > old)[:, None], shade, img[ys, xs, :3])
                img[ys, xs, 3] = a
    mean = np.mean(np.array(palette, float), 0)
    img[..., :3] = np.where(img[..., 3:4] > 0.02, img[..., :3], mean * 0.8)
    im = bpy.data.images.new(f"T_{name}_hair", w, h, alpha=True)
    im.pixels[:] = img.ravel()
    p = os.path.join(OUT, "textures", f"T_{name}_hair.png")
    im.filepath_raw = p; im.file_format = "PNG"; im.save()
    return p


def strand_cards(name, src, region, style, palette, collide, weight_src, density, seed=1):
    """region(co, normal) → spec dict or None: length, width, lift, droop, flow (vec), segs."""
    rng = np.random.default_rng(seed)
    me = src.data
    me.calc_loop_triangles()
    P = np.array([v.co[:] for v in me.vertices]); Nn = np.array([v.normal[:] for v in me.vertices])
    tris = np.array([t.vertices[:] for t in me.loop_triangles])
    a, b, c = P[tris[:, 0]], P[tris[:, 1]], P[tris[:, 2]]
    area = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    cent = (a + b + c) / 3
    keep = np.array([region(Vector(cent[i]), Vector(Nn[tris[i, 0]])) is not None for i in range(len(tris))])
    cnt = rng.poisson(area * density * keep)
    tree, _ = collide
    kd = KDTree(len(weight_src.data.vertices))
    for v in weight_src.data.vertices:
        kd.insert(v.co, v.index)
    kd.balance()
    bones = BONE_NAMES
    vg = [g.name for g in weight_src.vertex_groups if g.name in bones]
    col_of = {g.index: vg.index(g.name) for g in weight_src.vertex_groups if g.name in bones}
    W = np.zeros((len(weight_src.data.vertices), len(vg)))
    for v in weight_src.data.vertices:
        for g in v.groups:
            if g.group in col_of:
                W[v.index, col_of[g.group]] = g.weight
    verts, faces, uvs, vweights = [], [], [], []
    for ti in np.nonzero(cnt)[0]:
        for _ in range(cnt[ti]):
            u, w = rng.random(), rng.random()
            if u + w > 1:
                u, w = 1 - u, 1 - w
            bc = np.array([1 - u - w, u, w])
            p = Vector(bc @ P[tris[ti]]); n = Vector(bc @ Nn[tris[ti]]).normalized()
            st = region(p, n)
            if st is None:
                continue
            S = st.get("segs", 4)
            Ln = st["length"] * rng.uniform(0.75, 1.15)
            flow = Vector(st["flow"]); flow = (flow - n * flow.dot(n))
            flow = flow.normalized() if flow.length > 1e-4 else Vector((0, 1, -1)).normalized()
            d0 = (flow * (1 - st["lift"]) + n * st["lift"]).normalized()
            side = n.cross(d0)
            if side.length < 1e-4:
                side = Vector((1, 0, 0))
            side.normalize()
            wd = st["width"] * rng.uniform(0.8, 1.2)
            layer = st.get("layer", 0.006) * rng.uniform(0.6, 1.6)
            col = int(rng.integers(0, 4))
            u0, u1 = col / 4 + 0.004, (col + 1) / 4 - 0.004
            if rng.random() < 0.5:
                u0, u1 = u1, u0
            base = len(verts)
            q = p - n * 0.002
            pts = [q]
            d = d0
            for i in range(1, S + 1):
                d = (d0 + Vector((0, 0, -1)) * st["droop"] * (0.35 + 0.65 * i / S)).normalized()
                q = q + d * Ln / S
                if style.get("avoid"):
                    q = style["avoid"](q)
                loc, nrm, _, dist = tree.find_nearest(q)
                if loc is not None:
                    off = (q - loc).dot(nrm)
                    want = layer + 0.002
                    if off < want:
                        q = q + nrm * (want - off)
                    elif st.get("hug") and off < st["hug"] and q.z > st.get("hug_min_z", -1e9):
                        q = loc + nrm * want                   # lie along the scalp while over the head
                pts.append(q.copy())
            for i, q in enumerate(pts):
                verts += [q - side * wd / 2, q + side * wd / 2]
                uvs += [(u0, i / S), (u1, i / S)]
                # skin weights: root follows its surface point, the rest blend toward the body under the strand
                t = (i / S) ** 1.3
                _, ia, _ = kd.find(pts[0])
                _, ib, _ = kd.find(q)
                wv = W[ia] * (1 - t * st.get("follow", 1.0)) + W[ib] * t * st.get("follow", 1.0)
                vweights += [wv, wv]
            e1, e2 = verts[base + 1] - verts[base], verts[base + 2] - verts[base]
            outward = e1.cross(e2).dot(n) > 0
            for i in range(S):
                k = base + i * 2
                faces.append((k, k + 1, k + 3, k + 2) if outward else (k, k + 2, k + 3, k + 1))
    me2 = bpy.data.meshes.new(name)
    me2.from_pydata([tuple(v) for v in verts], [], faces)
    uvl = me2.uv_layers.new(name="UVMap")
    for poly in me2.polygons:
        for li in poly.loop_indices:
            uvl.data[li].uv = uvs[me2.loops[li].vertex_index]
    me2.update()
    obj = bpy.data.objects.new(name, me2)
    bpy.context.scene.collection.objects.link(obj)
    for poly in obj.data.polygons:
        poly.use_smooth = True
    groups = {g: obj.vertex_groups.new(name=g) for g in vg}
    WV = np.array(vweights) if vweights else np.zeros((0, len(vg)))
    for vi in range(len(WV)):
        top = np.argsort(WV[vi])[::-1][:4]
        s = WV[vi][top].sum()
        for gi in top:
            if WV[vi][gi] > 0.01 and s > 0:
                groups[vg[gi]].add([vi], float(WV[vi][gi] / s), "REPLACE")
    # shade like the surface underneath (soft volumetric hair)
    nrm = []
    for v in obj.data.vertices:
        loc, nr, _, _ = tree.find_nearest(v.co)
        nrm.append(tuple(nr) if nr is not None else (0, 0, 1))
    loops = [obj.data.loops[i].vertex_index for i in range(len(obj.data.loops))]
    obj.data.normals_split_custom_set([nrm[i] for i in loops])
    sp = {"name": name, "hair_palette": palette, "strands_per_card": style.get("strands", 160)}
    atlas = hair_atlas(name, palette) if style.get("hair") else fl.strand_atlas(sp, OUT)
    obj.data.materials.append(fl.fur_material(sp, atlas))
    return obj


# ============================================================== garments

def band_dist(c, a, b):
    """Distance in the x-z plane from c to segment a-b (a, b = (x, z))."""
    p = np.array([c.x, c.z]); a = np.array(a); b = np.array(b)
    ab = b - a
    t = np.clip((p - a) @ ab / (ab @ ab), 0, 1)
    return np.linalg.norm(p - (a + t * ab))


def leather(name, tint, scale=2.0):
    return gh.mat_hide(name, tint, scale)


def necklace(body, lm, teeth=True, beads=False, name="Necklace"):
    """Leather cord resting on the shoulders/upper chest, dipping in front, with hanging teeth."""
    tree, _ = bvh_of([body])
    cz = lm["neck"].z - 0.025
    center = Vector((0, lm["neck"].y, cz))
    pts = []
    for i in range(48):
        a = i / 48 * math.tau
        dirv = Vector((math.sin(a), -math.cos(a), 0))  # a=0 → front (-Y)
        front = max(0.0, math.cos(a))
        target = center + dirv * 0.2 + Vector((0, 0, -0.075 * front ** 3))
        loc, nrm, _, _ = tree.find_nearest(target)
        pts.append(loc + nrm * 0.006)
    pts.append(pts[0])
    cord_m = gh.mat_flat("M_Cord", (0.16, 0.11, 0.07), 0.8)
    parts = [(fl.tube("Cord", [tuple(p) for p in pts], 0.0035, 0.0035, ring=6, n=96, mat=cord_m), "neck_01")]
    if teeth:
        ivory = gh.mat_flat("M_Tooth", (0.80, 0.74, 0.62), 0.35)
        for k in range(-3, 4):
            i = (k * 2) % 48
            p = pts[i]
            ln = 0.035 - abs(k) * 0.004
            loc, nrm, _, _ = tree.find_nearest(p + Vector((0, 0, -ln)))
            tip = loc + nrm * 0.008
            parts.append((fl.tube("Tooth", [tuple(p), tuple(p.lerp(tip, 0.5) + nrm * 0.004), tuple(tip)], 0.0065, 0.0012,
                                  ring=6, n=6, mat=ivory, power=0.7), "spine_03"))
    return parts


def ribbon(name, tree, pts, width, mat, lift=0.006, thick=0.005, closed=False):
    """Flat leather band laid on the surface along pts (projected onto the body), thickened."""
    P = []
    for p in pts:
        loc, nrm, _, _ = tree.find_nearest(Vector(p))
        P.append((loc, nrm))
    verts, faces = [], []
    n = len(P)
    for i, (loc, nrm) in enumerate(P):
        a = P[max(i - 1, 0)][0] if not closed else P[(i - 1) % n][0]
        b = P[min(i + 1, n - 1)][0] if not closed else P[(i + 1) % n][0]
        tan = (b - a).normalized()
        side = nrm.cross(tan).normalized()
        c = loc + nrm * lift
        verts += [c - side * width / 2, c + side * width / 2]
    segs = n if closed else n - 1
    for i in range(segs):
        k, k2 = i * 2, ((i + 1) % n) * 2
        faces.append((k, k + 1, k2 + 1, k2))
    me = bpy.data.meshes.new(name); me.from_pydata([tuple(v) for v in verts], [], faces); me.update()
    o = bpy.data.objects.new(name, me); bpy.context.scene.collection.objects.link(o)
    o.data.materials.append(mat)
    for p in o.data.polygons:
        p.use_smooth = True
    fl.activate(o)
    sol = o.modifiers.new("solid", "SOLIDIFY"); sol.thickness = thick; sol.offset = 1.0
    bpy.ops.object.modifier_apply(modifier="solid")
    # UVs along the band so the leather grain runs with it
    bm = bmesh.new(); bm.from_mesh(o.data); uvl = bm.loops.layers.uv.new("UVMap")
    for f in bm.faces:
        for lp in f.loops:
            lp[uvl].uv = (lp.vert.co.x * 6 + lp.vert.co.z * 6, lp.vert.co.y * 6 + lp.vert.co.z * 3)
    bm.to_mesh(o.data); bm.free()
    return o


def ring_pts(center, rx, ry, z, n=40, dip=0.0):
    return [(center.x + math.sin(a) * rx, center.y - math.cos(a) * ry, z - dip * max(0.0, math.cos(a)) ** 3)
            for a in (i / n * math.tau for i in range(n))]


def line_pts(a, b, n=30):
    return [tuple(Vector(a).lerp(Vector(b), i / (n - 1))) for i in range(n)]


def bone_weights_rigid(obj, ref, bones):
    """Give a rigid accessory the skin weights of the nearest body vertex (per vertex)."""
    kd = KDTree(len(ref.data.vertices))
    for v in ref.data.vertices:
        kd.insert(v.co, v.index)
    kd.balance()
    names = {g.index: g.name for g in ref.vertex_groups}
    groups = {}
    for v in obj.data.vertices:
        _, i, _ = kd.find(v.co)
        ws = sorted(((g.weight, names[g.group]) for g in ref.data.vertices[i].groups if names[g.group] in bones), reverse=True)[:4]
        tot = sum(w for w, _ in ws) or 1
        for w, nm in ws:
            if nm not in groups:
                groups[nm] = obj.vertex_groups.new(name=nm)
            groups[nm].add([v.index], w / tot, "REPLACE")


def garments_sapiens(body, sex, lm, spec):
    t = spec["leather"]
    hide = leather("M_Hide", t); dark = leather("M_HideDark", tuple(x * 0.6 for x in t)); strap = leather("M_Strap", tuple(x * 0.45 for x in t), 4.0)
    furbase = gh.mat_flat("M_FurBase", spec["fur_palette"][0], 0.95)
    hip, knee, ankle, sh, neck, chest, waist = (lm[k].z for k in ("hip", "knee", "ankle", "shoulder", "neck", "chest", "waist"))
    BODY = gh.TORSO | gh.UPPERARM | gh.LEGS_UP
    out = {}
    # strip kilt / skirt with a jagged hem
    hem = knee + (0.16 if sex == "M" else 0.07)
    jag = lambda c: hem + 0.045 * abs(math.sin(math.atan2(c.x, c.y) * 7))
    def kilt(c):
        if not (jag(c) < c.z < hip + 0.10):
            return False
        ang = math.atan2(c.x, c.y)
        return c.z > hem + 0.13 or math.sin(ang * 16) > -0.55        # hide strips with slits
    out["kilt"] = gh.cut_garment(body, "Kilt", BODY, hide, 0.007, 0.018, keep_fn=kilt, flare_z=hip + 0.02, flare=0.22, smooth=10)
    tree, _ = bvh_of([body])
    wc = Vector((0, lm["hip"].y, 0))
    out["belt"] = ribbon("Belt", tree, ring_pts(wc, 0.25, 0.25, hip + 0.11, 48), 0.04, strap, lift=0.02, closed=True)
    # fur boots
    out["boots"] = gh.cut_garment(body, "Boots", gh.FEET | gh.LEGS_LOW, furbase, 0.01, 0.016, z_max=ankle + 0.24, smooth=3)
    # wrist wraps
    def wrist(c):
        return min((c - lm["wrist_l"]).length, (c - lm["wrist_r"]).length) < 0.075
    for side in ("l", "r"):
        e, w = lm["elbow_" + side], lm["wrist_" + side]
        ax = (e - w).normalized()
        u = ax.orthogonal().normalized(); v = ax.cross(u)
        for k, off in enumerate((0.03, 0.065)):
            c = w + ax * off
            pts = [tuple(c + (u * math.cos(t) + v * math.sin(t)) * 0.1) for t in (i / 24 * math.tau for i in range(24))]
            out[f"wrap_{side}{k}"] = ribbon(f"Wrap", tree, pts, 0.022, strap, lift=0.004, closed=True)
    if sex == "M":
        # fur mantle on the shoulders, open over the chest; crossed straps on the bare torso
        def mantle(c):
            low = sh - 0.10 + (0.07 if (c.y < 0 and abs(c.x) < 0.13) else 0.0)
            return low < c.z < neck + 0.03
        out["mantle"] = gh.cut_garment(body, "Mantle", gh.TORSO | gh.UPPERARM, furbase, 0.012, 0.02, keep_fn=mantle, smooth=10)
        yf = min(v.co.y for v in body.data.vertices if abs(v.co.z - chest) < 0.03) - 0.05   # in front of the chest
        yb = max(v.co.y for v in body.data.vertices if abs(v.co.z - chest) < 0.03) + 0.05
        for i, sx in enumerate((1, -1)):
            front = line_pts((0.13 * sx, yf, sh + 0.02), (-0.12 * sx, yf, hip + 0.12), 36)
            back = line_pts((-0.12 * sx, yb, hip + 0.12), (0.13 * sx, yb, sh + 0.02), 36)
            out[f"strap{i}"] = ribbon("Strap", tree, front + back, 0.034, strap, lift=0.006)
    else:
        out["top"] = gh.cut_garment(body, "Top", gh.TORSO, hide, 0.008, 0.014, keep_fn=lambda c: chest - 0.07 < c.z < chest + 0.13, smooth=6)
        def shoulder(c):
            return c.x > 0.02 and sh - 0.07 < c.z < neck + 0.02
        out["mantle"] = gh.cut_garment(body, "Mantle", gh.TORSO | gh.UPPERARM, furbase, 0.012, 0.02, keep_fn=shoulder, smooth=8)
    return out


# ============================================================== species (concept sheet)

def soft(d, w):
    """1 at the stroke centre falling smoothly to 0 at distance w (no hard vertex steps)."""
    t = max(0.0, 1 - d / w)
    return t * t * (3 - 2 * t)


def paint_sapiens(xx, yy, zz, x):
    v = 0.0
    if yy < 0.45 and 0.33 < zz < 0.59:                                      # two strokes down each cheek
        fade = soft(abs(zz - 0.46), 0.14)
        for cx in (0.42, 0.62):
            v = max(v, soft(abs(xx - (cx + (0.56 - zz) * 0.25)), 0.075) * fade)
    if yy < 0.32 and 0.71 < zz < 0.82 and xx < 0.4:                           # forehead slash
        v = max(v, soft(abs(zz - (0.765 + x * 0.6)), 0.03) * soft(xx, 0.4))
    return max(0.0, min(1.0, v))


SAPIENS = {
    "macro": {
        "M": {"gender": 1.0, "age": 0.5, "muscle": 0.78, "weight": 0.42, "height": 0.62, "proportions": 0.7,
              "race": {"african": 0.25, "asian": 0.15, "caucasian": 0.6}},
        "F": {"gender": 0.0, "age": 0.45, "muscle": 0.62, "weight": 0.42, "height": 0.55, "proportions": 0.7,
              "race": {"african": 0.25, "asian": 0.15, "caucasian": 0.6}},
    },
    "morphs": {"chin-prominent-incr": 0.3, "head-square": 0.25},
    "face_units": "caucasian",
    "skin": {"M": (0.56, 0.39, 0.28), "F": (0.60, 0.43, 0.32)},
    "hair": {"M": (0.17, 0.11, 0.07), "F": (0.20, 0.13, 0.08)},
    "hair_palette": [(0.20, 0.13, 0.08), (0.30, 0.20, 0.12), (0.12, 0.08, 0.05), (0.40, 0.27, 0.16)],
    "fur_palette": [(0.30, 0.21, 0.13), (0.42, 0.31, 0.20), (0.20, 0.14, 0.09), (0.52, 0.40, 0.27)],
    "leather": (0.85, 0.66, 0.48),
    "iris": (0.30, 0.18, 0.08),
    "paint": paint_sapiens,
    "hair_len": {"M": 0.34, "F": 0.46}, "beard": {"M": 0.07, "F": 0.0},
    "garments": garments_sapiens, "necklace": True,
}
SPECIES = {"Sapiens": SAPIENS}


def build(variant):
    spec_name, sex = variant[:-1], variant[-1]
    spec = SPECIES[spec_name]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for o in list(bpy.context.scene.objects):
        bpy.data.objects.remove(o)
    bpy.context.scene.render.fps = gh.FPS
    body, rig, eyes = make_body(spec, sex)
    lm = landmarks(rig)
    BONE_NAMES.clear(); BONE_NAMES.update(b.name for b in rig.data.bones)
    ref = keyless_copy(body, "BodyRef")          # garments, collisions and weights read this (no shape keys)
    hf = head_frame(ref)
    skin_attributes(body, spec, sex, lm, hf)
    bake_skin(body, spec, sex, f"Human_{variant}")
    pieces = []
    eye_objs = make_eyes(eyes, f"Human_{variant}", spec["iris"])
    gar = spec["garments"](ref, sex, lm, spec)
    pieces += list(gar.values())
    collide = bvh_of([ref] + pieces)
    # head hair: scalp from a hairline (low at the back, high on the forehead), drapes over shoulders
    hl = spec["hair_len"][sex]
    crown = Vector((0, (hf["y"][0] + hf["y"][1]) / 2 + 0.01, hf["z"][1]))

    def scalp(c, n):
        xx, yy, zz = hcoords(c, hf)
        if c.z < hf["z"][0] or not in_scalp(xx, yy, zz):
            return None
        out = (c - crown); out.z = 0
        front = yy < 0.4
        if front:   # swept back and to the sides, clear of the face
            flow = Vector((math.copysign(0.8, c.x), 1.0, 0.2))
        else:
            flow = (out.normalized() if out.length > 1e-3 else Vector((0, 1, 0))) * 0.6 + Vector((0, 0.5, -0.6))
        return {"length": hl * (0.75 if front else 1.0), "width": 0.013, "lift": 0.0, "droop": 0.9 if not front else 0.7,
                "flow": tuple(flow), "segs": 7, "layer": 0.003 + 0.006 * (1 - zz), "follow": 0.9,
                "hug": 0.15, "hug_min_z": hf["z"][0] + 0.45 * (hf["z"][1] - hf["z"][0])}
    hair_pal = [tuple(x * k for x in spec["hair"][sex]) for k in (1.0, 1.35, 0.75, 1.6)]
    face_y = hf["y"][0]
    def avoid(q):   # keep strands off the face: anything in front of it slides out to the side
        zz = (q.z - hf["z"][0]) / (hf["z"][1] - hf["z"][0])
        if q.y < face_y + 0.06 and -0.1 < zz < 0.8 and abs(q.x) < 0.085:
            q = Vector((math.copysign(0.085, q.x if abs(q.x) > 1e-4 else 1.0), q.y, q.z))
        return q
    pieces.append(strand_cards(f"Human_{variant}Hair", ref, scalp, {"hair": True, "avoid": avoid}, hair_pal, collide, ref, 38000, seed=3))
    if spec["beard"][sex] > 0:
        bl = spec["beard"][sex]

        def beard(c, n):
            xx, yy, zz = hcoords(c, hf)
            if not in_beard(xx, yy, zz):
                return None
            return {"length": bl * (0.6 if zz > 0.3 else 1.0), "width": 0.010, "lift": 0.3, "droop": 0.8,
                    "flow": (0, -0.3, -1), "segs": 3, "layer": 0.004, "follow": 0.2}
        pieces.append(strand_cards(f"Human_{variant}Beard", ref, beard, {"hair": True}, hair_pal, collide, ref, 32000, seed=5))
    # fur on the fur garments (mantle, boots)
    for key in ("mantle", "boots"):
        if key not in gar:
            continue
        g = gar[key]
        ln = 0.09 if key == "mantle" else 0.045

        def fur(c, n, ln=ln):
            return {"length": ln, "width": 0.03, "lift": 0.3, "droop": 0.8, "flow": (0, 0.2, -1), "segs": 3, "layer": 0.004, "follow": 0.0}
        pieces.append(strand_cards(f"Human_{variant}{key.title()}Fur", g, fur, {"strands": 170}, spec["fur_palette"],
                                   collide, ref, 5000 if key == "mantle" else 1800, seed=7))
    extra = []
    if spec.get("necklace"):
        for o, bone in necklace(ref, lm):
            fl.rigid_to_bone(o, bone)
            extra.append(o)
    for o in pieces:
        if not o.vertex_groups:
            bone_weights_rigid(o, ref, BONE_NAMES)
    for o in eye_objs + extra:
        o.parent = rig
        m = o.modifiers.new("Armature", "ARMATURE"); m.object = rig
    pieces += eye_objs + extra
    for p in pieces:
        p.parent = rig
        if not any(m.type == "ARMATURE" for m in p.modifiers):
            m = p.modifiers.new("Armature", "ARMATURE"); m.object = rig
        if p.data.shape_keys:
            p.shape_key_clear()
    bpy.data.objects.remove(ref)
    gh.export_parts(variant, [body] + [p for p in pieces if "Hair" not in p.name or True], {b.name for b in rig.data.bones})
    clips = gh.make_clips(rig)
    bpy.ops.object.select_all(action="DESELECT")
    for o in [body, rig] + pieces:
        o.select_set(True)
    bpy.context.view_layer.objects.active = rig
    path = os.path.join(OUT, f"SK_Human_{variant}.gltf")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="textures",
                              use_selection=True, export_yup=True, export_animations=True,
                              export_animation_mode="NLA_TRACKS", export_skins=True, export_morph=True)
    tris = {o.name: sum(len(p.vertices) - 2 for p in o.data.polygons) for o in [body] + pieces}
    print("HOMININ", variant, "tris", sum(tris.values()), {k: v for k, v in tris.items() if v > 1500},
          "shape_keys", [k.name for k in body.data.shape_keys.key_blocks], "clips", clips)


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    for v in (argv or ["SapiensM", "SapiensF"]):
        build(v)
