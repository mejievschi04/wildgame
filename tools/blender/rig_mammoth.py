"""Clean up and rig the supplied textured mammoth (Sketchfab "3D High-poly Baby Woolly Mammoth", CC BY 4.0):
blender -b --python rig_mammoth.py -- 3d_high-poly_baby_woolly_mammoth.glb SK_Mammoth_Textured.glb

The sculpt is straightened and mirrored into a symmetric standing pose (clean_body), decimated, then rigged with
the fauna_lib rig v2 and procedural clips timed to the game speeds in data/animals.json."""
import argparse
import math
import os
from pathlib import Path
import sys
import tempfile

import bpy
import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fauna_lib as fl
from gen_animals import game_speeds
from species_more import MAMMOTH, MAM_RUN, MAM_WALK, mam_trunk
from lion_coat import box_blur

# Tris kept from the 57k source after mirroring.
DECIMATE = 0.5

# Landmarks measured on the imported mesh after orienting it and setting its height to 3.6 m.
JOINTS = {
    "hips": (0.08, -0.91, 2.05), "spine": (0.02, -0.32, 2.45),
    "chest": (-0.04, 0.79, 2.53), "neck": (-0.10, 1.16, 2.63),
    "neck2": (-0.18, 1.50, 2.70), "head": (-0.29, 1.92, 2.63),
    "nose": (-0.33, 2.35, 1.94), "trunk2": (-0.37, 2.40, 1.30),
    "trunk3": (-0.37, 2.49, 0.70), "trunk4": (-0.34, 2.22, 0.40),
    "tail": (0.15, -1.32, 2.04), "tail2": (0.23, -1.49, 1.35), "tail3": (0.30, -1.70, 0.78),
    "ear.L": (0.12, 1.55, 2.70), "ear_t.L": (0.35, 1.40, 2.45),
    "ear.R": (-0.55, 1.50, 2.70), "ear_t.R": (-0.75, 1.37, 2.45),
    "sh.L": (0.36, 0.91, 1.91), "el.L": (0.31, 0.83, 1.02),
    "ca.L": (0.19, 0.92, 0.36), "fh.L": (0.18, 0.96, 0.06),
    "sh.R": (-0.44, 0.93, 1.91), "el.R": (-0.40, 0.78, 1.02),
    "ca.R": (-0.39, 0.95, 0.36), "fh.R": (-0.38, 0.98, 0.06),
    "hp.L": (0.42, -1.02, 1.88), "st.L": (0.47, -0.89, 1.06),
    "ho.L": (0.43, -1.00, 0.37), "hh.L": (0.42, -0.96, 0.06),
    "hp.R": (-0.36, -0.94, 1.88), "st.R": (-0.33, -0.68, 1.06),
    "ho.R": (-0.17, -0.83, 0.37), "hh.R": (-0.15, -0.74, 0.06),
}


def import_body(path):
    bpy.ops.import_scene.gltf(filepath=str(path))
    body, = (o for o in bpy.context.scene.objects if o.type == "MESH")
    world = body.matrix_world.copy()
    body.parent = None
    body.matrix_world = Matrix.Identity(4)
    body.data.transform(Matrix.Rotation(-np.pi / 2, 4, "Z") @ world)
    p = np.array([v.co[:] for v in body.data.vertices])
    p[:, 2] -= p[:, 2].min()
    p *= 3.6 / p[:, 2].max()
    feet = p[p[:, 2] < 0.12, :2]
    p[:, :2] -= (feet.max(axis=0) + feet.min(axis=0)) / 2
    body.data.vertices.foreach_set("co", p.ravel())
    body.data.update()
    body.name = body.data.name = "Mammoth"
    for mat in body.data.materials:
        mat.name = "M_Mammoth_Textured"
    return body, p


def smoothstep(lo, hi, value):
    t = np.clip((value - lo) / (hi - lo), 0, 1)
    return t * t * (3 - 2 * t)


def components(body, points):
    """Connected part of every vertex (UV seams welded): the body, two tusks, two eyes."""
    _, first, index = np.unique(points.round(5), axis=0, return_index=True, return_inverse=True)
    edges = np.empty(len(body.data.edges) * 2, dtype=np.int32)
    body.data.edges.foreach_get("vertices", edges)
    edges = index[edges.reshape(-1, 2)]
    parent = np.arange(len(first))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, j in edges:
        parent[root(i)] = root(j)
    welded = np.array([root(i) for i in range(len(first))])
    return welded[index]


def midline_shift(p, main):
    """Sideways shift per length slice that puts the bent body (rump at +0.1, head turned to -0.3) on x = 0."""
    b = p[main]
    ys, mids = [], []
    for y in np.arange(-1.45, 2.5, 0.1):
        s = b[(abs(b[:, 1] - y) < 0.05) & (b[:, 2] > 1.98) & (b[:, 2] < 2.88)]
        if len(s) > 8:
            ys.append(y)
            mids.append((s[:, 0].min() + s[:, 0].max()) / 2)
    mids = np.array(mids)
    mids = np.array([np.median(mids[max(0, i - 1):i + 2]) for i in range(len(mids))])
    mids = np.convolve(np.pad(mids, 2, mode="edge"), np.ones(5) / 5, mode="valid")
    return lambda y: -np.interp(y, ys, mids)


def clean_body(body, p):
    """The source sculpt is lopsided: bent spine, head turned aside, tail hanging off to one side, a hind foot
    stepping under the belly. Straighten it, centre the tail, then keep the clean left half (+X) and mirror it.
    UVs stay; the mirrored half reuses the same texture."""
    part = components(body, p)
    ids, counts = np.unique(part, return_counts=True)
    main = part == ids[np.argmax(counts)]
    shift = midline_shift(p, main)
    p = p.copy()
    p[main, 0] += shift(p[main, 1])
    for i in ids[counts != counts.max()]:
        sel = part == i
        p[sel, 0] += shift(p[sel, 1].min())          # tusks and eyes move rigidly with the head
    # Tail: hangs 0.04-0.19 m to the left of the rump. Slide it onto the midline, fading into the rump.
    tail = np.array([JOINTS["tail"], JOINTS["tail2"], JOINTS["tail3"]], dtype=float)
    tail[:, 0] += shift(tail[:, 1])
    order = np.argsort(tail[:, 2])
    d = np.full(len(p), np.inf)
    for a, b in zip(tail[:-1], tail[1:]):
        ab = b - a
        t = np.clip((p - a) @ ab / (ab @ ab), 0, 1)
        d = np.minimum(d, np.linalg.norm(p - a - t[:, None] * ab, axis=1))
    w = (1 - smoothstep(0.10, 0.24, d)) * (1 - smoothstep(-1.36, -1.22, p[:, 1])) * main
    p[:, 0] -= w * np.interp(p[:, 2], tail[order, 2], tail[order, 0])
    # Trunk: below the mouth it still hangs 5-9 cm to the right; centre each height slice of it.
    zs, cs = [], []
    for z in np.arange(0.35, 1.9, 0.1):
        s = p[main & (abs(p[:, 2] - z) < 0.05) & (p[:, 1] > 1.75)]
        s = s[s[:, 1] > s[:, 1].max() - 0.45]
        zs.append(z)
        cs.append((s[:, 0].min() + s[:, 0].max()) / 2)
    cs = np.convolve(np.pad(cs, 1, mode="edge"), np.ones(3) / 3, mode="valid")
    w = (1 - smoothstep(1.75, 1.95, p[:, 2])) * smoothstep(1.85, 2.0, p[:, 1]) * main
    p[:, 0] -= w * np.interp(p[:, 2], zs, cs)
    # Tusk tips curl in to the midline; keep the kept tusk clear of its mirror image.
    for i in ids[counts != counts.max()]:
        sel = part == i
        if p[sel, 0].mean() > 0:
            p[sel, 0] += max(0.0, 0.03 - p[sel, 0].min())
    body.data.vertices.foreach_set("co", p.ravel())
    body.data.update()

    import bmesh
    bm = bmesh.new()
    bm.from_mesh(body.data)
    bm.verts.ensure_lookup_table()
    small = [v for v in bm.verts if not main[v.index]]
    drop = {v for v in small if part[v.index] in {i for i in ids if p[part == i, 0].mean() < 0}}
    bmesh.ops.delete(bm, geom=list(drop), context="VERTS")
    body_geom = list(bm.verts) + list(bm.edges) + list(bm.faces)
    # Only the body crosses x = 0, so bisecting everything only cuts the body.
    bmesh.ops.bisect_plane(bm, geom=body_geom, dist=1e-5, plane_co=(0, 0, 0), plane_no=(1, 0, 0), clear_inner=True)
    for v in bm.verts:
        if abs(v.co.x) < 1e-4:
            v.co.x = 0.0
    bm.to_mesh(body.data)
    bm.free()
    mirror = body.modifiers.new("mirror", "MIRROR")
    mirror.use_axis[0] = True
    mirror.use_clip = True
    mirror.use_mirror_merge = True
    mirror.merge_threshold = 1e-4
    decimate = body.modifiers.new("decimate", "DECIMATE")
    decimate.ratio = DECIMATE
    decimate.use_symmetry = True
    decimate.symmetry_axis = "X"
    bpy.context.view_layer.objects.active = body
    for m in ("mirror", "decimate"):
        bpy.ops.object.modifier_apply(modifier=m)
    for poly in body.data.polygons:
        poly.use_smooth = True
    out = np.empty(len(body.data.vertices) * 3)
    body.data.vertices.foreach_get("co", out)
    return out.reshape(-1, 3), shift


def symmetric_joints(shift, p):
    """JOINTS were measured on the lopsided sculpt. Move them with the straightening, put the midline on x = 0,
    re-measure the lower leg columns of the kept left side and mirror them to the right."""
    J = {}
    for name, (x, y, z) in JOINTS.items():
        if name.endswith(".R"):
            continue
        x = 0.0 if "." not in name else x + float(shift(y))
        J[name] = (x, y, z)
    # Pillar legs: every joint of a leg on the column measured at the lower leg, so the leg swings in a
    # fore-aft plane (the gait IK works in that plane; a slanted chain would wobble sideways and skate).
    for chain in (("sh.L", "el.L", "ca.L", "fh.L"), ("hp.L", "st.L", "ho.L", "hh.L")):
        xs = []
        for name in chain[2:]:
            x, y, z = J[name]
            ring = p[(abs(p[:, 2] - max(z, 0.08)) < 0.04) & (abs(p[:, 1] - y) < 0.3) & (p[:, 0] > 0.12)]
            xs.append((ring[:, 0].min() + ring[:, 0].max()) / 2)
        column = float(np.mean(xs))
        for name in chain:
            J[name] = (column,) + tuple(J[name][1:])
    for name in [n for n in J if n.endswith(".L")]:
        x, y, z = J[name]
        J[name[:-1] + "R"] = (-x, y, z)
    return J


def bind(body, points, rig, species):
    # Weld UV seams for weight calculation only. Keep the original UVs and mesh topology.
    _, first, index = np.unique(points.round(5), axis=0, return_index=True, return_inverse=True)
    p = points[first]
    edges = np.empty(len(body.data.edges) * 2, dtype=np.int32)
    body.data.edges.foreach_get("vertices", edges)
    edges = np.unique(np.sort(index[edges.reshape(-1, 2)], axis=1), axis=0)
    a, b = edges[edges[:, 0] != edges[:, 1]].T
    parent = list(range(len(p)))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i, j in zip(a, b):
        parent[root(i)] = root(j)
    component = np.array([root(i) for i in range(len(p))])
    ids, counts = np.unique(component, return_counts=True)
    rigid = component != ids[np.argmax(counts)]
    assert len(ids) == 5, "Expected body, two tusks and two eyes"

    joints = fl.complete_joints(species["J"])
    x, y, z = p.T
    leg = 1 - smoothstep(1.03, 2.20, z)
    trunk = smoothstep(1.55, 2.12, y) * (1 - smoothstep(1.85, 2.63, z))
    trunk *= 1 - smoothstep(0.24, 0.54, abs(x))
    tail = (1 - smoothstep(-1.53, -1.31, y)) * (1 - smoothstep(0.09, 0.27, abs(x)))
    weights = []
    groups = []
    for name, start, end, _ in fl.bone_table(species):
        head, tip = np.array(joints[start]), np.array(joints[end])
        axis = tip - head
        t = np.clip((p - head) @ axis / (axis @ axis), 0, 1)
        d2 = np.sum((p - head - t[:, None] * axis) ** 2, axis=1)
        gate, width = 1, 0.37
        if name.startswith("snout"):
            gate, width = trunk, 0.23
        elif name.startswith("tail"):
            gate, width = tail, 0.19
        elif name.startswith("ear."):
            gate, width = 0.55, 0.14
        elif name == "jaw":
            gate = 0
        elif "." in name:
            side = 1 if name.endswith(".L") else -1
            gate = leg * smoothstep(-0.11, 0.11, side * x)
            gate *= (smoothstep(0.04, 0.62, y) if name.startswith(("scapula", "upperarm", "forearm", "hoof_f"))
                     else 1 - smoothstep(-0.56, -0.02, y))
            width = 0.26
        else:
            gate = (1 - 0.999 * trunk) * (1 - 0.98 * tail)
            gate *= 0.02 + smoothstep(0.65, 1.50, z)
            if name == "head":
                # Give the broad cheeks and forehead the same stable pivot as the eyes and tusks.
                d2 = x ** 2 * 0.36 + (y - 1.93) ** 2 + (z - 2.68) ** 2 * 0.5
                width = 0.53
        weights.append(gate * np.exp(-d2 / width**2))
        groups.append(body.vertex_groups.new(name=name))
    w = np.array(weights).T
    w /= w.sum(axis=1, keepdims=True)
    edges_from, edges_to = np.r_[a, b], np.r_[b, a]
    degree = np.maximum(np.bincount(edges_from, minlength=len(p)), 1)
    for _ in range(4):
        avg = np.zeros_like(w)
        np.add.at(avg, edges_from, w[edges_to])
        w = 0.55 * w + 0.45 * avg / degree[:, None]
    w[rigid] = 0
    w[rigid, body.vertex_groups["head"].index] = 1
    main = np.argsort(w, axis=1)[:, -4:]
    values = np.take_along_axis(w, main, axis=1)
    values /= values.sum(axis=1, keepdims=True)
    for vertex, row in enumerate(index):
        for group, weight in zip(main[row], values[row]):
            if weight > 0:
                groups[group].add([vertex], float(weight), "REPLACE")
    body.parent = rig
    body.modifiers.new("Mammoth skin", "ARMATURE").object = rig


def ground_fall(body, rig):
    """Keep the falling mesh above the ground and settle it onto its side."""
    scene = bpy.context.scene
    data = rig.animation_data
    hips = rig.pose.bones["hips"]
    local_up = hips.bone.matrix_local.to_3x3().inverted() @ Vector((0, 0, 1))
    coords = np.empty(len(body.data.vertices) * 3, dtype=np.float32)
    data.use_nla = False
    action = data.nla_tracks["death"].strips[0].action
    data.action = action
    data.action_slot = action.slots[0]
    first, last = map(int, action.frame_range)
    locations = []
    for frame in range(first, last + 1):
        scene.frame_set(frame)
        posed = body.evaluated_get(bpy.context.evaluated_depsgraph_get())
        posed.data.vertices.foreach_get("co", coords)
        clearance = float(coords[2::3].min())
        settle = smoothstep(0.65, 0.85, (frame - first) / (last - first))
        correction = max(0.0, -clearance) - max(0.0, clearance) * settle
        locations.append(hips.location + local_up * correction)
    for frame, location in enumerate(locations, first):
        hips.location = location
        hips.keyframe_insert("location", frame=frame)
    data.action = None
    data.use_nla = True
    scene.frame_set(1)


# ----------------------------------------------------------------------------------------------- look

# sRGB: one coffee brown in four near-identical tones, so the coat reads as a single colour with no patches
COFFEE = (0.33, 0.21, 0.12)
HAIR_PALETTE = [COFFEE, (0.345, 0.22, 0.125), (0.315, 0.20, 0.115), (0.335, 0.215, 0.12)]
TORSO = ("hips", "spine", "spine2", "chest", "neck", "neck2", "scapula")


def mammoth_material(body):
    """The source material has no metallic factor, so glTF reads it as metal (dark, glossy). Make it a matte
    hide in the coat's coffee brown."""
    for mat in body.data.materials:
        nodes = mat.node_tree.nodes
        bsdf = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
        bsdf.inputs["Metallic"].default_value = 0.0
        bsdf.inputs["Roughness"].default_value = 0.88
        bsdf.inputs["Specular IOR Level"].default_value = 0.3
        link = bsdf.inputs["Base Color"].links
        if not link:
            continue
        img = link[0].from_node.image
        w, h = img.size
        px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
        rgb = px[..., :3]
        # One coffee brown over the whole hide: keep only the fine detail (each texel against its
        # neighbourhood), drop the light and dark patches. The tusks and eyes share the texture: leave them.
        lum = rgb @ np.array((0.2126, 0.7152, 0.0722), dtype=np.float32)
        detail = np.clip(lum / np.maximum(box_blur(box_blur(lum, 6), 6), 1e-3), 0.72, 1.3)
        hide = np.array(COFFEE, dtype=np.float32) * 0.85 * detail[..., None]
        tusks, eyes = part_masks(body, w, h)
        # eyes: the source paints them red; a mammoth's eye is a very dark brown, with the texture's sheen kept
        eye = np.array((0.055, 0.035, 0.025), dtype=np.float32) * np.clip(lum / max(float(lum[eyes].mean()), 1e-3), 0.6, 2.5)[..., None] \
            if eyes.any() else rgb
        px[..., :3] = np.where(tusks[..., None], rgb, np.where(eyes[..., None], np.clip(eye, 0, 1), np.clip(hide, 0, 1)))
        img.pixels.foreach_set(px.ravel())
        img.pack()


def part_masks(body, w, h):
    """Texels under the separate small parts, image rows bottom-up like Image.pixels: (tusks, eyes). The two
    largest small parts are the tusks, the others the eyes."""
    me = body.data
    me.calc_loop_triangles()
    P = np.array([v.co[:] for v in me.vertices])
    part = components(body, P)
    ids, counts = np.unique(part, return_counts=True)
    main_part = ids[np.argmax(counts)]
    uv = me.uv_layers[0].data
    small = sorted((c, i) for i, c in zip(ids, counts) if i != main_part)
    tusk_ids = {i for _, i in small[-2:]}
    tusks = np.zeros((h, w), bool)
    eyes = np.zeros((h, w), bool)
    for tri in me.loop_triangles:
        owner = part[tri.vertices[0]]
        if owner == main_part:
            continue
        mask = tusks if owner in tusk_ids else eyes
        q = np.array([uv[i].uv[:] for i in tri.loops]) * (w, h)
        x0, y0 = np.floor(q.min(0)).astype(int) - 1
        x1, y1 = np.ceil(q.max(0)).astype(int) + 1
        x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, w - 1), min(y1, h - 1)
        ys, xs = np.mgrid[y0:y1 + 1, x0:x1 + 1] + 0.5
        (ax, ay), (bx, by), (cx, cy) = q
        d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(d) < 1e-9:
            continue
        l0 = ((by - cy) * (xs - cx) + (cx - bx) * (ys - cy)) / d
        l1 = ((cy - ay) * (xs - cx) + (ax - cx) * (ys - cy)) / d
        inside = (l0 >= -0.05) & (l1 >= -0.05) & (1 - l0 - l1 >= -0.05)
        mask[y0:y1 + 1, x0:x1 + 1] |= inside
    return tusks, eyes


def tex_hair(p, n, bone):
    """Hair per skin point of the textured mammoth (y forward, z up, 3.6 m tall):
    (length, lift, droop, card width, flow direction). Hanging locks stop 8 cm above the ground."""
    spec = _tex_hair(p, n, bone)
    return (min(spec[0], max(0.0, (p[2] - 0.08) / 1.2)),) + tuple(spec[1:])


def _tex_hair(p, n, bone):
    x, y, z = p
    b = bone.split(".")[0]
    none = (0.0, 0.0, 0.0, 0.0, (0, 0, -1))
    if b.startswith("snout") or b == "jaw" or b.startswith("hoof"):
        return none
    if b == "head":
        if y > 2.02 or z < 2.35:                                      # face, trunk root, cheeks: bare
            return none
        return 0.30, 0.35, 0.55, 0.10, (0, -1, -0.3)                  # crown tuft swept back
    if b == "ear":
        return 0.14, 0.1, 0.9, 0.08, (0, -0.3, -1)
    if b in TORSO:
        if n[2] > 0.55:                                               # back and hump
            return 0.30, 0.22, 0.65, 0.12, (0, -1, -0.5)
        skirt = 0.32 + max(0.0, 2.25 - z) * 0.6                       # longest under the chest and belly
        return min(skirt, 0.95), 0.05, 1.0, 0.13, (0, -0.25, -1)
    if b in ("upperarm", "thigh"):
        return 0.48, 0.05, 1.0, 0.12, (0, -0.2, -1)
    if b in ("forearm", "shin"):
        return (0.34 if z > 0.55 else 0.16), 0.05, 1.0, 0.10, (0, -0.1, -1)
    if b == "tail_tip":
        return 0.32, 0.1, 1.0, 0.07, (0, -0.2, -1)
    if b.startswith("tail"):
        return 0.10, 0.1, 0.8, 0.06, (0, -0.3, -1)
    return none


_TONE = np.random.default_rng(11)


def tex_coat(p, n, bone):
    """Hair colour column, picked per card: tones chosen by body zone clump into patches, a random pick per
    card mixes them strand by strand (only the lowest legs lean darker)."""
    return (HAIR_PALETTE[_TONE.integers(len(HAIR_PALETTE))],)


def add_hair(body, rig, out_dir):
    """Woolly coat: hair cards rooted on the hide (not on the tusks or eyes), skinned like the hide under them."""
    import bmesh
    skin = body.copy()
    skin.data = body.data.copy()
    bpy.context.scene.collection.objects.link(skin)
    P = np.array([v.co[:] for v in skin.data.vertices])
    part = components(skin, P)
    ids, counts = np.unique(part, return_counts=True)
    bm = bmesh.new()
    bm.from_mesh(skin.data)
    bm.verts.ensure_lookup_table()
    main_part = ids[np.argmax(counts)]
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if part[v.index] != main_part], context="VERTS")
    bm.to_mesh(skin.data)
    bm.free()
    names = [g.name for g in skin.vertex_groups]
    which = np.zeros(len(skin.data.vertices), dtype=int)
    for v in skin.data.vertices:
        if v.groups:
            which[v.index] = max(v.groups, key=lambda g: g.weight).group
    sp = {"name": "MammothWool", "hair": tex_hair, "coat": tex_coat, "hair_palette": HAIR_PALETTE,
          "card_density": 230, "strands_per_card": 240,
          "strand_bright": (0.92, 1.06), "strand_shade": (0.82, 0.22)}   # even strands, tips barely lighter
    os.makedirs(os.path.join(out_dir, "textures"), exist_ok=True)
    cards, roots = fl.build_cards(skin, sp, which, names, out_dir)
    fl.card_normals_from_body(cards, roots, skin)
    fl.transfer_card_weights(cards, roots, skin)
    bpy.data.objects.remove(skin)
    cards.name = cards.data.name = "Mammoth_Fur"
    cards.parent = rig
    cards.modifiers.new("Armature", "ARMATURE").object = rig
    print("Mammoth hair cards:", len(cards.data.polygons))
    return cards


# ------------------------------------------------------------------------------------------- motion

def ramp(t, a, b):
    """0 before a, 1 after b, smooth in between."""
    x = min(max((t - a) / (b - a), 0.0), 1.0)
    return x * x * (3 - 2 * x)


def bump(t, a, b):
    """0 outside [a, b], a smooth hill inside."""
    if t <= a or t >= b:
        return 0.0
    return math.sin((t - a) / (b - a) * math.pi) ** 2


def idle_extra(r, t):
    """Breathing and weight shifts come from std idle; add the trunk's slow swing with a curl now and then, the
    ears fanning and a nodding head."""
    w = t * math.tau
    mam_trunk(r, t, 1.4)
    curl = bump(t, 0.45, 0.85)
    for name, k in (("snout2", 22), ("snout3", 32), ("snout4", 45)):
        x, y, z = r[name]
        r[name] = (x + k * curl, y, z)
    r["ear.L"] = (0, 0, 6 + 9 * math.sin(w * 2))
    r["ear.R"] = (0, 0, -6 - 9 * math.sin(w * 2 + 0.7))
    r["head"] = (r["head"][0] + 2 * math.sin(w), r["head"][1], r["head"][2])
    r["tail"] = (8 + 6 * math.sin(w * 3), 0, 10 * math.sin(w * 2))
    r["tail2"] = (4, 0, 14 * math.sin(w * 2 + 0.8))


def graze_extra(r, t):
    """Reach down, wrap the trunk round a tuft and lift it to the mouth, chew, reach again."""
    reach = 1 - bump(t, 0.38, 0.92)                    # 1 while the trunk is down at the grass
    lift = bump(t, 0.38, 0.92)
    tug = math.sin(t * math.tau * 4) * (t < 0.35)
    r["snout"] = (-6 * reach + 10 * lift, 0, 3 * tug)
    r["snout2"] = (-4 * reach + 32 * lift, 0, 5 * tug)
    r["snout3"] = (6 * reach + 48 * lift + 6 * tug, 0, 0)
    r["snout4"] = (20 * reach + 62 * lift + 10 * tug, 0, 0)
    r["ear.L"] = (0, 0, 5 + 5 * math.sin(t * math.tau * 2))
    r["ear.R"] = (0, 0, -5 - 5 * math.sin(t * math.tau * 2))


def alert_clip(rig):
    """Head up, ears spread wide, trunk raised and testing the air."""
    def f(r, t):
        w = t * math.tau
        r["neck"] = (12, 0, 0)
        r["head"] = (8, 0, 10 * math.sin(w))
        r["ear.L"] = (0, 0, 38)
        r["ear.R"] = (0, 0, -38)
        r["snout"] = (28, 0, 4 * math.sin(w * 2))
        r["snout2"] = (34, 0, 6 * math.sin(w * 2 + 0.5))
        r["snout3"] = (30 + 8 * math.sin(w * 3), 0, 8 * math.sin(w * 2 + 1.0))
        r["snout4"] = (25 + 15 * math.sin(w * 3 + 0.8), 0, 0)
        r["tail"] = (30, 0, 0)
        r["tail2"] = (10, 0, 4 * math.sin(w * 2))
        r["spine2"] = (1.5, 0, 0)
        return (0, 0, 0.02)
    return fl.loop_clip(rig, 2.0, 2, f)


def attack_clip(rig):
    """Rear back with the trunk up and the ears out, lunge, swing the tusks sideways and toss them up.
    The blow lands at ~0.55 of the 1.3 s clip (attack_windup 0.7 s in data/animals.json)."""
    n = int(1.3 * fl.FPS)
    for f in range(n + 1):
        t = f / n
        wind = bump(t, 0.0, 0.5) if t < 0.25 else (1.0 if t < 0.4 else bump(t, 0.15, 0.55))
        wind = min(1.0, wind * 1.2)
        swing = bump(t, 0.38, 0.72)
        toss = bump(t, 0.55, 0.9)
        r = fl.zero_pose(rig)
        r["neck"] = (14 * wind - 16 * swing + 12 * toss, 0, 0)
        r["neck2"] = (6 * wind - 8 * swing + 8 * toss, 0, 0)
        r["head"] = (10 * wind - 14 * swing + 24 * toss, 0, 26 * swing - 8 * toss)
        r["snout"] = (30 * wind + 10 * toss, 0, 0)
        r["snout2"] = (40 * wind + 25 * toss, 0, 0)
        r["snout3"] = (45 * wind + 30 * toss, 0, 0)
        r["snout4"] = (40 * wind + 30 * toss, 0, 0)
        spread = max(wind, swing, toss)
        r["ear.L"] = (0, 0, 40 * spread)
        r["ear.R"] = (0, 0, -40 * spread)
        r["spine2"] = (3 * wind - 2 * swing, 0, 0)
        r["upperarm.L"] = (18 * wind, 0, 0)            # a forefoot comes up as it rears
        r["forearm.L"] = (-34 * wind, 0, 0)
        r["tail"] = (35 * spread, 0, 0)
        back = -0.18 * wind + 0.55 * swing + 0.25 * toss
        fl.key(rig, f + 1, r, (0, back, 0.10 * wind))
    return n


def trunk_whip_clip(rig):
    """Trunk raised and cocked to one side, then whipped across at knee height; the head turns with it.
    1.0 s, the blow at 0.42 s (data/animals.json attacks: attack_trunk windup)."""
    n = int(1.0 * fl.FPS)
    for f in range(n + 1):
        t = f / n
        cock = ramp(t, 0.0, 0.3) * (1 - ramp(t, 0.3, 0.45))
        whip = bump(t, 0.3, 0.62)
        follow = bump(t, 0.45, 0.9)
        side = 1.0 * cock - 1.0 * whip - 0.6 * follow          # +: cocked to the left, -: swept to the right
        r = fl.zero_pose(rig)
        r["neck"] = (6 * cock - 4 * whip, 0, 14 * side)
        r["head"] = (6 * cock - 6 * whip, 0, 20 * side)
        r["snout"] = (25 * cock + 5 * whip, 0, 18 * side)
        r["snout2"] = (35 * cock - 10 * whip, 0, 26 * side)
        r["snout3"] = (30 * cock - 15 * whip, 0, 32 * side)
        r["snout4"] = (25 * cock + 30 * follow, 0, 30 * side)
        spread = max(cock, whip)
        r["ear.L"] = (0, 0, 32 * spread)
        r["ear.R"] = (0, 0, -32 * spread)
        r["spine2"] = (0, 0, 3 * side)
        r["tail"] = (25 * spread, 0, 0)
        fl.key(rig, f + 1, r, (0, 0.12 * whip, 0))
    return n


def stomp_clip(rig, species):
    """Rear up on the hind legs with the forelegs folded, then slam them down. 1.8 s, the stomp lands at
    1.0 s. The whole body pitches about the hips; the hind legs counter-rotate to stay planted."""
    J = fl.complete_joints(species["J"])
    hips_y, hips_z = J["hips"][1], J["hips"][2]
    n = int(1.8 * fl.FPS)
    for f in range(n + 1):
        sec = f / fl.FPS
        rise = ramp(sec, 0.0, 0.8) * (1 - ramp(sec, 0.8, 1.0))
        impact = bump(sec, 0.95, 1.35)
        pitch = 24 * rise                                      # body up at the front
        r = fl.zero_pose(rig)
        r["hips"] = (pitch, 0, 0)
        for s in ("L", "R"):
            r[f"thigh.{s}"] = (-pitch - 6 * rise, 0, 0)      # hind legs stay under the body, a little crouched
            r[f"shin.{s}"] = (10 * rise, 0, 0)
            r[f"hoof_h.{s}"] = (-4 * rise, 0, 0)
            r[f"upperarm.{s}"] = (38 * rise, 0, 0)            # forelegs tucked while up
            r[f"forearm.{s}"] = (-70 * rise, 0, 0)
            r[f"hoof_f.{s}"] = (25 * rise, 0, 0)
        r["neck"] = (-6 * rise - 10 * impact, 0, 0)
        r["head"] = (10 * rise - 12 * impact, 0, 8 * impact * math.sin(sec * 30))
        r["snout"] = (40 * rise, 0, 0)                         # trumpeting: trunk curled up
        r["snout2"] = (55 * rise, 0, 0)
        r["snout3"] = (50 * rise, 0, 0)
        r["snout4"] = (40 * rise - 10 * impact, 0, 0)
        spread = max(rise, impact)
        r["ear.L"] = (0, 0, 42 * spread)
        r["ear.R"] = (0, 0, -42 * spread)
        r["tail"] = (30 * spread, 0, 0)
        # the hips move back and up as the front rises; a jolt down on impact
        lift = math.radians(pitch)
        back = -(J["chest"][1] - hips_y) * (1 - math.cos(lift)) * 0.5 - 0.25 * rise
        fl.key(rig, f + 1, r, (0, back, 0.18 * rise - 0.07 * impact))
    return n


def tusk_thrust_clip(rig):
    """Head low with the tusks levelled forward, a lunge, then the tusks tossed up. 1.2 s, the blow at 0.62 s."""
    n = int(1.2 * fl.FPS)
    for f in range(n + 1):
        t = f / n
        lower = ramp(t, 0.0, 0.3) * (1 - ramp(t, 0.55, 0.8))
        lunge = bump(t, 0.35, 0.72)
        toss = bump(t, 0.5, 0.88)
        r = fl.zero_pose(rig)
        r["neck"] = (-16 * lower + 14 * toss, 0, 0)
        r["neck2"] = (-8 * lower + 8 * toss, 0, 0)
        r["head"] = (-14 * lower + 26 * toss, 0, 0)
        r["snout"] = (20 * lower + 20 * toss, 0, 0)            # trunk tucked back between the tusks
        r["snout2"] = (35 * lower + 30 * toss, 0, 0)
        r["snout3"] = (40 * lower + 30 * toss, 0, 0)
        r["snout4"] = (35 * lower + 25 * toss, 0, 0)
        spread = max(lower, toss)
        r["ear.L"] = (0, 0, 36 * spread)
        r["ear.R"] = (0, 0, -36 * spread)
        r["spine2"] = (-2 * lower, 0, 0)
        for s in ("L", "R"):
            r[f"upperarm.{s}"] = (-6 * lower, 0, 0)           # braced on the forelegs
        r["tail"] = (30 * spread, 0, 0)
        fl.key(rig, f + 1, r, (0, -0.15 * lower + 0.75 * lunge + 0.2 * toss, -0.06 * lower))
    return n


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("source", type=Path)
    cli.add_argument("output", type=Path)
    args = cli.parse_args(sys.argv[sys.argv.index("--") + 1:])
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = fl.FPS
    body, points = import_body(args.source)
    points, shift = clean_body(body, points)
    species = dict(MAMMOTH, J=symmetric_joints(shift, points), speeds=game_speeds(MAMMOTH), mouth=None)
    species["graze_pose"] = {"neck": -12, "neck2": -6, "head": -8, "arm": 3, "drop": 0.05}
    species["idle_extra"] = idle_extra
    species["graze_extra"] = graze_extra
    species["gait_extra"] = lambda r, t, g: (mam_trunk(r, t, 1.0), r.update({"ear.L": (0, 0, 8 + 6 * math.sin(t * math.tau * 2)),
                                                                          "ear.R": (0, 0, -8 - 6 * math.sin(t * math.tau * 2))}))
    walk = dict(MAM_WALK, ik_lift=0.085, fold_f=28, fold_h=14, toe_curl=14, head=3.5, spine=1.5, tail=9)
    run = dict(MAM_RUN, ik_lift=0.15, fold_f=45, fold_h=19, toe_curl=18)
    species["clips"] = lambda rig: fl.std_clips(rig, species, walk, run,
                                                extra={"alert": lambda: alert_clip(rig), "attack": lambda: attack_clip(rig),
                                                       "attack_trunk": lambda: trunk_whip_clip(rig),
                                                       "attack_stomp": lambda: stomp_clip(rig, species),
                                                       "attack_thrust": lambda: tusk_thrust_clip(rig)})
    mammoth_material(body)
    rig = fl.build_rig(species)
    bind(body, points, rig, species)
    # the strand atlas is embedded in the GLB: draw it in a scratch folder
    hair = add_hair(body, rig, tempfile.mkdtemp()) if os.environ.get("NO_HAIR") != "1" else None
    print("Mammoth clips:", fl.make_clips(rig, species))
    ground_fall(body, rig)
    fl.activate(rig)
    body.select_set(True)
    if hair:
        hair.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(args.output), export_format="GLB", use_selection=True,
                              export_animations=True, export_animation_mode="NLA_TRACKS", export_skins=True)


if __name__ == "__main__":
    main()
