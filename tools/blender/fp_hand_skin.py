"""Skin and musculature for the first-person hand (used by gen_fp_hand.py).

The cut arm shares the whole-body skin atlas, where a hand gets only a few hundred texels and the forearm is a
smooth tube. Here it gets its own look:
- geometry (one subdivision): forearm muscle bellies (the radial group on the thumb side, the flexors under the
  forearm, the extensors on the back), a slimmer wrist, the thumb's ball and the knuckles;
- a normal map baked from a dense copy: extensor tendons fanning over the back of the hand, veins, wrinkles over
  the finger joints, skin pores;
- an albedo baked from the body texture with tints: tanned back of the hand, paler palm, reddish knuckles and
  fingertips, bluish veins, darker creases;
- its own UV layout and material M_FP_Hand_Skin (HumanNPC._tune_skin treats it as skin).

Everything works in the item space of the hand model; distances are in metres.
"""
import os

import bpy
import numpy as np
from mathutils import Vector, noise
from mathutils.kdtree import KDTree

TEX = 2048
MM = 0.001


def smooth(lo, hi, x):
    t = np.clip((x - lo) / (hi - lo), 0, 1)
    return t * t * (3 - 2 * t)


def seg_dist(P, a, b):
    ab = b - a
    t = np.clip((P - a) @ ab / max(ab @ ab, 1e-12), 0, 1)
    return np.linalg.norm(P - a - t[:, None] * ab, axis=1), t


def poly_dist(P, pts):
    best = np.full(len(P), np.inf)
    along = np.zeros(len(P))
    total = 0.0
    for a, b in zip(pts[:-1], pts[1:]):
        d, t = seg_dist(P, a, b)
        closer = d < best
        best = np.where(closer, d, best)
        along = np.where(closer, total + t * np.linalg.norm(b - a), along)
        total += np.linalg.norm(b - a)
    return best, along / max(total, 1e-9)


class Frame:
    """Anatomical directions and landmarks of the posed hand in item space."""

    def __init__(self, L, dorsal, thumb_side):
        self.L = {k: np.array(v[:]) for k, v in L.items()}
        self.wrist, self.elbow = self.L["wrist"], self.L["elbow"]
        self.arm = (self.elbow - self.wrist) / np.linalg.norm(self.elbow - self.wrist)
        d = np.array(dorsal[:])
        self.dorsal = d - self.arm * (d @ self.arm)
        self.dorsal /= np.linalg.norm(self.dorsal)
        r = np.array(thumb_side[:])
        r = r - self.arm * (r @ self.arm) - self.dorsal * (r @ self.dorsal)
        self.radial = r / np.linalg.norm(r)
        self.length = np.linalg.norm(self.elbow - self.wrist)

    def forearm(self, P):
        """s: 0 at the wrist, 1 at the elbow; radial unit vectors around the forearm axis."""
        rel = P - self.wrist
        s = rel @ self.arm / self.length
        ring = rel - np.outer(rel @ self.arm, self.arm)
        ring /= np.maximum(np.linalg.norm(ring, axis=1, keepdims=True), 1e-9)
        return s, ring

    def direction(self, dorsal, radial):
        v = self.dorsal * dorsal + self.radial * radial
        return v / np.linalg.norm(v)


def broad(F, P, N):
    """Muscle-scale offsets along the normal (metres): kept in the game mesh."""
    s, ring = F.forearm(P)
    on_arm = smooth(0.04, 0.16, s) * (1 - smooth(1.02, 1.15, s))
    out = np.zeros(len(P))
    # (direction (dorsal, radial), amplitude, peak position along the forearm, width along it, angular sharpness)
    for (dd, rr), amp, peak, width, sharp in (((0.55, 0.85), 9.0, 0.74, 0.30, 3),   # brachioradialis + ECRL
                                             ((-0.75, -0.45), 6.5, 0.68, 0.32, 2),  # flexor mass
                                             ((0.85, -0.35), 4.2, 0.62, 0.30, 3),   # extensors
                                             ((-0.9, 0.3), 2.4, 0.55, 0.25, 4)):    # palmaris / FCR
        lobe = np.exp(-((s - peak) / width) ** 2)
        ang = np.clip(ring @ F.direction(dd, rr), 0, 1) ** sharp
        out += amp * MM * lobe * ang
    out -= 1.6 * MM * np.exp(-((s - 0.12) / 0.1) ** 2) * (s > 0.02)          # slimmer wrist
    out *= on_arm
    # the thumb's ball on the palm
    thenar = F.L["thumb1"] * 0.6 + F.L["index1"] * 0.15 + F.wrist * 0.25
    out += 3.0 * MM * np.exp(-(np.linalg.norm(P - thenar, axis=1) / 0.016) ** 2) * (N @ -F.dorsal > 0.1)
    # knuckles
    for f in ("index", "middle", "ring", "pinky"):
        k = F.L[f + "1"]
        dist = np.linalg.norm(P - (k + F.dorsal * 0.004), axis=1)
        out += 3.0 * MM * np.exp(-(dist / 0.010) ** 2) * np.clip(N @ F.dorsal, 0, 1)
    return out


def snap(tree, p):
    co, _, _ = tree.find(Vector(p))
    return np.array(co[:])


def fine(F, P, N, tree):
    """Skin-scale offsets (metres) and tint masks for the dense bake mesh."""
    out = np.zeros(len(P))
    up = np.clip(N @ F.dorsal, 0, 1)
    vein_mask = np.zeros(len(P))
    crease_mask = np.zeros(len(P))
    wrist_d = snap(tree, F.wrist + F.dorsal * 0.05)
    s, ring = F.forearm(P)
    # extensor tendons: from the back of the wrist fanning out to each knuckle
    for k, f in enumerate(("index", "middle", "ring", "pinky")):
        knuck = snap(tree, F.L[f + "1"] + F.dorsal * 0.05)
        start = wrist_d + F.radial * (0.010 - 0.0065 * k) - F.arm * 0.004
        d, t = seg_dist(P, start, knuck)
        out += 0.9 * MM * np.exp(-(d / 0.0042) ** 2) * smooth(0.05, 0.3, t) * (1 - smooth(0.85, 1.0, t)) * up
    # dorsal veins: a network over the back of the hand draining into the cephalic vein on the thumb side
    rng = np.random.default_rng(3)
    mid = (F.L["index1"] + F.L["ring1"]) / 2
    veins = [
        [mid, (mid * 0.5 + wrist_d * 0.5) + F.radial * 0.006, wrist_d + F.radial * 0.016,
         wrist_d + F.radial * 0.020 + F.arm * 0.06, wrist_d + F.radial * 0.017 + F.arm * 0.16],
        [F.L["pinky1"] * 0.7 + F.L["ring1"] * 0.3, (F.L["ring1"] * 0.5 + wrist_d * 0.5) - F.radial * 0.004,
         wrist_d - F.radial * 0.008 + F.arm * 0.02, wrist_d - F.radial * 0.010 + F.arm * 0.10],
        [F.L["index1"] * 0.6 + F.L["thumb1"] * 0.4, (F.L["thumb1"] * 0.5 + wrist_d * 0.5) + F.radial * 0.004,
         wrist_d + F.radial * 0.016],
    ]
    for vein in veins:
        pts = [snap(tree, p + F.dorsal * 0.05) for p in vein]
        wiggle = np.array([snap(tree, a * (1 - u) + b * u + F.radial * rng.uniform(-0.002, 0.002) + F.dorsal * 0.05)
                           for a, b in zip(pts[:-1], pts[1:]) for u in (0.0, 0.5)] + [pts[-1]])
        d, along = poly_dist(P, wiggle)
        width = 0.0026 + 0.0012 * along
        bump = np.exp(-(d / width) ** 2) * (1 - smooth(0.9, 1.0, along) * 0.6)
        out += 0.8 * MM * bump * up
        vein_mask = np.maximum(vein_mask, bump * up)
    # wrinkles over the finger joints (three short grooves across each joint) and the knuckle creases
    for f in ("index", "middle", "ring", "pinky", "thumb"):
        for j in ("2", "3"):
            a, b = F.L[f + str(int(j) - 1)], F.L[f + j]
            c = F.L[f + j]
            fd = (b - a) / np.linalg.norm(b - a)
            rel = P - c
            along = rel @ fd
            lateral = np.linalg.norm(rel - np.outer(along, fd), axis=1)
            groove = sum(np.exp(-((along - o) / 0.0009) ** 2) for o in (-0.0022, 0.0, 0.0022))
            m = groove * np.exp(-(lateral / 0.009) ** 2) * up
            out -= 0.25 * MM * m
            crease_mask = np.maximum(crease_mask, np.clip(m, 0, 1))
    # pores and fine skin texture
    noise_val = np.array([noise.noise(Vector(p * 500.0)) for p in P])
    out += 0.05 * MM * noise_val
    return out, vein_mask, crease_mask, up


def tints(F, P, N, vein_mask, crease_mask, up):
    """Linear RGB multipliers for the body albedo."""
    c = np.ones((len(P), 3))
    palm = np.clip(N @ -F.dorsal, 0, 1)
    c *= (1 - 0.08 * up)[:, None] * np.array((1.0, 0.97, 0.94))[None] ** up[:, None]     # tanned back
    c *= 1 + (0.06 * palm)[:, None] * np.array((1.0, 0.7, 0.6))[None]                      # paler, pinker palm
    red = np.zeros(len(P))
    for f in ("index", "middle", "ring", "pinky", "thumb"):
        for key in (f + "1", f + "2", f + "tip"):
            red = np.maximum(red, np.exp(-(np.linalg.norm(P - F.L[key], axis=1) / 0.011) ** 2))
    c *= 1 + (red * 0.10)[:, None] * np.array((1.0, -0.6, -0.7))[None]                     # knuckles, fingertips
    c *= 1 - (vein_mask * 0.14)[:, None] * np.array((1.0, 0.85, 0.35))[None]               # bluish veins
    c *= (1 - 0.22 * crease_mask)[:, None]
    return np.clip(c, 0, 2)


def offset(obj, amount):
    me = obj.data
    co = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", co)
    n = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("normal", n)
    co = co.reshape(-1, 3) + n.reshape(-1, 3) * amount[:, None]
    me.vertices.foreach_set("co", co.ravel())
    me.update()


def arrays(obj):
    me = obj.data
    co = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("co", co)
    n = np.empty(len(me.vertices) * 3)
    me.vertices.foreach_get("normal", n)
    return co.reshape(-1, 3), n.reshape(-1, 3)


def subdivide(obj, levels):
    bpy.context.view_layer.objects.active = obj
    m = obj.modifiers.new("Subdivision", "SUBSURF")
    m.levels = m.render_levels = levels
    m.uv_smooth = "PRESERVE_BOUNDARIES"
    bpy.ops.object.modifier_apply(modifier=m.name)


def box_blur(img, r):
    for axis in (0, 1):
        pad = [(0, 0)] * img.ndim
        pad[axis] = (r + 1, r)
        c = np.cumsum(np.pad(img, pad, mode="edge"), axis=axis)
        img = (np.take(c, np.arange(2 * r + 1, c.shape[axis]), axis=axis)
               - np.take(c, np.arange(0, c.shape[axis] - 2 * r - 1), axis=axis)) / (2 * r + 1)
    return img


def fill(value, weight, r):
    """Fill the gaps between splatted samples (normalised convolution) and grow the islands by r texels."""
    num = value * weight[..., None] if value.ndim == 3 else value * weight
    w = weight.astype(float)
    for _ in range(2):
        num, w = box_blur(num, r), box_blur(w, r)
    return num / np.maximum(w[..., None] if value.ndim == 3 else w, 1e-6), w > 1e-4


def detail(arm, frame, tex_dir):
    """Subdivide and shape `arm` (the skin part of the hand model), paint its maps and give it its material.

    The maps are painted straight into the new UV layout from a dense subdivided copy (which inherits that
    layout): every corner of the copy writes its colour and skin height into the texel under its UV, the gaps
    are filled, and the normal map is the gradient of the height. No ray-cast bake, so the fingers pressed
    together in the fist cannot pick up each other's surface."""
    F = frame
    scene = bpy.context.scene
    skin = arm.data.materials[0]
    albedo_src = next(n.image for n in skin.node_tree.nodes if n.type == "TEX_IMAGE" and n.image
                      and "albedo" in n.image.name)
    for p in arm.data.polygons:
        p.use_smooth = True
    subdivide(arm, 1)
    P, N = arrays(arm)
    offset(arm, broad(F, P, N))

    # the hand's own UV layout (the old one still samples the body albedo)
    old_uv = arm.data.uv_layers[0].name
    new_uv = arm.data.uv_layers.new(name="FPUV")
    arm.data.uv_layers.active = new_uv
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.006, scale_to_bounds=True)
    bpy.ops.object.mode_set(mode="OBJECT")

    # dense copy: two more levels; skin detail and tints per vertex
    high = arm.copy()
    high.data = arm.data.copy()
    scene.collection.objects.link(high)
    subdivide(high, 2)
    P, N = arrays(high)
    surface = KDTree(len(P))
    for i, p in enumerate(P):
        if N[i] @ F.dorsal > 0.35:
            surface.insert(Vector(p), i)
    surface.balance()
    height, veins, creases, up = fine(F, P, N, surface)
    tint = tints(F, P, N, veins, creases, up)

    me = high.data
    loops = len(me.loops)
    vidx = np.empty(loops, dtype=np.int64)
    me.loops.foreach_get("vertex_index", vidx)
    uv_new = np.empty(loops * 2)
    me.uv_layers["FPUV"].data.foreach_get("uv", uv_new)
    uv_old = np.empty(loops * 2)
    me.uv_layers[old_uv].data.foreach_get("uv", uv_old)
    uv_new, uv_old = uv_new.reshape(-1, 2), uv_old.reshape(-1, 2)
    src = np.array(albedo_src.pixels[:], dtype=np.float32).reshape(albedo_src.size[1], albedo_src.size[0], 4)
    sx = np.clip((uv_old[:, 0] * albedo_src.size[0]).astype(int), 0, albedo_src.size[0] - 1)
    sy = np.clip((uv_old[:, 1] * albedo_src.size[1]).astype(int), 0, albedo_src.size[1] - 1)
    colour = src[sy, sx, :3] * tint[vidx]                       # Blender image rows start at the bottom
    px = np.clip((uv_new[:, 0] * TEX).astype(int), 0, TEX - 1)
    py = np.clip((uv_new[:, 1] * TEX).astype(int), 0, TEX - 1)
    acc_c = np.zeros((TEX, TEX, 3))
    acc_h = np.zeros((TEX, TEX))
    acc_w = np.zeros((TEX, TEX))
    np.add.at(acc_c, (py, px), colour)
    np.add.at(acc_h, (py, px), height[vidx])
    np.add.at(acc_w, (py, px), 1.0)
    hit = acc_w > 0
    acc_c[hit] /= acc_w[hit][:, None]
    acc_h[hit] /= acc_w[hit]
    albedo, mask = fill(acc_c, hit.astype(float), 2)
    h, _ = fill(acc_h, hit.astype(float), 3)
    for _ in range(2):                                           # soften: no splat speckle in the slopes
        h = box_blur(h, 1)
    # metres per texel: 3D area over UV area of the low mesh
    area3 = sum(p.area for p in arm.data.polygons)
    uv_l = np.empty(len(arm.data.loops) * 2)
    arm.data.uv_layers["FPUV"].data.foreach_get("uv", uv_l)
    uv_l = uv_l.reshape(-1, 2)
    area_uv = 0.0
    for poly in arm.data.polygons:
        q = uv_l[poly.loop_start:poly.loop_start + poly.loop_total]
        area_uv += 0.5 * abs(np.dot(q[:, 0], np.roll(q[:, 1], 1)) - np.dot(q[:, 1], np.roll(q[:, 0], 1)))
    texel = np.sqrt(area3 / max(area_uv, 1e-9)) / TEX
    gy, gx = np.gradient(h / texel)                             # rows go up the image (v), columns along u
    n = np.dstack((-gx, -gy, np.ones_like(h)))
    n /= np.linalg.norm(n, axis=2, keepdims=True)
    normal = n * 0.5 + 0.5
    normal[~mask] = (0.5, 0.5, 1.0)
    albedo[~mask] = albedo[mask].mean(axis=0)
    bpy.data.objects.remove(high)

    images = {}
    for kind, data, colour_space in (("albedo", albedo, "sRGB"), ("normal", normal, "Non-Color")):
        img = bpy.data.images.new(f"T_FP_Hand_{kind}", TEX, TEX, alpha=False)
        img.colorspace_settings.name = colour_space
        img.pixels.foreach_set(np.dstack((np.clip(data, 0, 1), np.ones((TEX, TEX)))).astype(np.float32).ravel())
        img.filepath_raw = os.path.join(tex_dir, f"T_FP_Hand_{kind}.png")
        img.file_format = "PNG"
        img.save()
        images[kind] = img
    print(f"FP hand skin: {len(P)} detail vertices, {texel * 1000:.2f} mm per texel")

    # final material on the new UVs only
    arm.data.uv_layers.remove(arm.data.uv_layers[old_uv])
    arm.data.uv_layers["FPUV"].name = old_uv      # same layer name as the wraps: one TEXCOORD_0 after the join
    final = bpy.data.materials.new("M_FP_Hand_Skin")
    final.use_nodes = True
    nt = final.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    a = nt.nodes.new("ShaderNodeTexImage"); a.image = images["albedo"]
    nimg = nt.nodes.new("ShaderNodeTexImage"); nimg.image = images["normal"]
    nmap = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(a.outputs[0], bsdf.inputs["Base Color"])
    nt.links.new(nimg.outputs[0], nmap.inputs["Color"])
    nt.links.new(nmap.outputs[0], bsdf.inputs["Normal"])
    bsdf.inputs["Roughness"].default_value = 0.62
    arm.data.materials.clear()
    arm.data.materials.append(final)
    return images
