"""Paint the cave lion's coat over the Smilodon texture: no tiger stripes, tawny sand colour, cream belly and muzzle,
dark tail tuft. Mouth, teeth and eyes keep their original colours.

  blender -b --python tools/blender/lion_coat.py -- smilodon-fractalus.glb T_Lion_coat.png

PNG on purpose: Godot's JPEG decoder rejects the JPEGs Blender 5.3 writes.

The masks (belly, muzzle, tail tip, which texels are fur) are drawn per vertex on the mesh and rasterised into UV
space, so they follow the texture islands. tools/prepare_lion.py embeds the result in SK_Lion_Textured.glb.
"""
import sys

import bpy
import numpy as np

# sRGB palette from shadow to highlight: tawny cave-lion coat, slightly greyish.
PALETTE = [(0.00, (0.16, 0.11, 0.07)), (0.30, (0.50, 0.37, 0.23)), (0.55, (0.74, 0.60, 0.41)),
           (0.80, (0.88, 0.79, 0.62)), (1.00, (0.97, 0.92, 0.80))]
CREAM = np.array((0.90, 0.84, 0.70))
TUFT = np.array((0.13, 0.09, 0.06))


def smoothstep(lo, hi, x):
    t = np.clip((x - lo) / (hi - lo), 0, 1)
    return t * t * (3 - 2 * t)


def box_blur(img, r):
    """Box blur along both image axes (r in pixels), edge-clamped; three passes approximate a Gaussian."""
    for axis in (0, 1):
        pad = [(0, 0)] * img.ndim
        pad[axis] = (r + 1, r)
        c = np.cumsum(np.pad(img, pad, mode="edge"), axis=axis)
        img = (np.take(c, np.arange(2 * r + 1, c.shape[axis]), axis=axis)
               - np.take(c, np.arange(0, c.shape[axis] - 2 * r - 1), axis=axis)) / (2 * r + 1)
    return img


def blur(img, r, mask):
    """Gaussian-like blur that ignores texels outside the islands (normalised convolution)."""
    num, den = img * mask, mask.astype(float)
    for _ in range(3):
        num, den = box_blur(num, r), box_blur(den, r)
    return num / np.maximum(den, 1e-4)


def rasterise(uv, tris, values, size):
    """Interpolate per-vertex `values` (n x k) over the UV triangles into a size x size x k image (row 0 = top)."""
    out = np.zeros((size, size, values.shape[1]))
    hit = np.zeros((size, size), bool)
    px = np.column_stack((uv[:, 0] * size, (1 - uv[:, 1]) * size)) - 0.5
    for a, b, c in tris:
        p = px[[a, b, c]]
        x0, y0 = np.maximum(np.floor(p.min(0)).astype(int) - 1, 0)
        x1, y1 = np.minimum(np.ceil(p.max(0)).astype(int) + 1, size - 1)
        if x1 < x0 or y1 < y0:
            continue
        ys, xs = np.mgrid[y0:y1 + 1, x0:x1 + 1]
        d = (p[1, 1] - p[2, 1]) * (p[0, 0] - p[2, 0]) + (p[2, 0] - p[1, 0]) * (p[0, 1] - p[2, 1])
        if abs(d) < 1e-9:
            continue
        w0 = ((p[1, 1] - p[2, 1]) * (xs - p[2, 0]) + (p[2, 0] - p[1, 0]) * (ys - p[2, 1])) / d
        w1 = ((p[2, 1] - p[0, 1]) * (xs - p[2, 0]) + (p[0, 0] - p[2, 0]) * (ys - p[2, 1])) / d
        w2 = 1 - w0 - w1
        inside = (w0 >= -0.02) & (w1 >= -0.02) & (w2 >= -0.02)
        if not inside.any():
            continue
        v = w0[..., None] * values[a] + w1[..., None] * values[b] + w2[..., None] * values[c]
        out[ys[inside], xs[inside]] = v[inside]
        hit[ys[inside], xs[inside]] = True
    return out, hit


def main():
    src, dst = sys.argv[sys.argv.index("--") + 1:][:2]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=src)
    scene = bpy.context.scene
    rig = next(o for o in scene.objects if o.type == "ARMATURE")
    if rig.animation_data:
        for track in rig.animation_data.nla_tracks:
            track.mute = True
        rig.animation_data.action = None
    for bone in rig.pose.bones:
        bone.matrix_basis.identity()
    bpy.context.view_layer.update()
    body = next(o for o in scene.objects if o.type == "MESH")
    mesh = body.data
    mesh.calc_loop_triangles()
    n = len(mesh.vertices)
    P = np.array([(body.matrix_world @ v.co)[:] for v in mesh.vertices])
    N = np.array([(body.matrix_world.to_3x3() @ v.normal).normalized()[:] for v in mesh.vertices])
    uv = np.zeros((n, 2))
    for loop in mesh.loops:
        uv[loop.vertex_index] = mesh.uv_layers[0].data[loop.index].uv
    tris = np.array([t.vertices[:] for t in mesh.loop_triangles])

    # Separate parts: the body and its fur cards are recoloured; eyes and teeth (small parts in the mouth / eye
    # sockets, all within the front 8 % of the body) keep their colours.
    _, first, weld = np.unique(P.round(4), axis=0, return_index=True, return_inverse=True)
    parent = np.arange(len(first))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for a, b, c in weld[tris]:
        parent[root(a)] = root(b)
        parent[root(b)] = root(c)
    part = np.array([root(i) for i in range(len(first))])[weld]
    ids, counts = np.unique(part, return_counts=True)
    main = part == ids[np.argmax(counts)]
    lo, hi = P[main].min(0), P[main].max(0)
    # Body axis: the longer horizontal extent; the head is the end where the small parts (eyes, teeth) are.
    axis = int(np.argmax((hi - lo)[:2]))
    head_end = hi[axis] if P[~main, axis].mean() > P[main, axis].mean() else lo[axis]
    front = np.abs(head_end - P[:, axis]) / (hi[axis] - lo[axis])
    up = (P[:, 2] - lo[2]) / (hi[2] - lo[2])
    fur = main.astype(float)
    for i in ids:
        sel = part == i
        if not main[sel][0] and front[sel].max() > 0.09:
            fur[sel] = 1.0

    # Mouth: whole UV islands whose texture is pink on average (tongue, gums, palate) keep their colours.
    bsdf = next(nd for nd in mesh.materials[0].node_tree.nodes if nd.type == "BSDF_PRINCIPLED")
    img = bsdf.inputs["Base Color"].links[0].from_node.image
    size = img.size[0]
    pixels = np.array(img.pixels[:], dtype=np.float32).reshape(img.size[1], img.size[0], 4)[::-1, :, :3]
    island = np.arange(n)
    def iroot(i):
        while island[i] != i:
            island[i] = island[island[i]]
            i = island[i]
        return i
    for a, b, c in tris:
        island[iroot(a)] = iroot(b)
        island[iroot(b)] = iroot(c)
    island = np.array([iroot(i) for i in range(n)])
    texel = pixels[np.clip(((1 - uv[:, 1]) * size).astype(int), 0, size - 1), np.clip((uv[:, 0] * size).astype(int), 0, size - 1)]
    for i in np.unique(island):
        sel = island == i
        r_, g_, _ = texel[sel].mean(0)
        if r_ / max(g_, 1e-3) > 1.4:
            fur[sel] = 0.0

    # Masks drawn on the mesh.
    belly = smoothstep(-0.15, -0.75, N[:, 2]) * smoothstep(0.30, 0.15, up)
    belly = np.maximum(belly, smoothstep(-0.1, -0.6, N[:, 2]) * smoothstep(0.62, 0.45, up))
    muzzle = smoothstep(0.10, 0.04, front) * smoothstep(0.62, 0.48, up)
    tail_w = np.zeros(n)
    groups = {g.index: g.name for g in body.vertex_groups}
    for v in mesh.vertices:
        for g in v.groups:
            if "Tail" in groups[g.group] or groups[g.group].startswith("tail"):
                tail_w[v.index] += g.weight
    tail = tail_w > 0.3
    tip = np.zeros(n)
    if tail.any():
        t = (front[tail] - front[tail].min()) / max(np.ptp(front[tail]), 1e-6)
        tip[tail] = smoothstep(0.72, 0.95, t)
    print("TAIL", int(tail.sum()), "tip", int((tip > 0.5).sum()))
    back = smoothstep(0.35, 0.85, N[:, 2]) * smoothstep(0.55, 0.8, up)     # darker saddle along the spine
    attrs = np.column_stack((fur, belly, muzzle, tip, back))

    masks, hit = rasterise(uv, tris, attrs, size)
    # Grow the masks a few texels past the island edges so the JPEG seams don't show the old colour.
    for k in range(masks.shape[2]):
        grown = blur(masks[..., k], 2, hit)
        masks[..., k] = np.where(hit, masks[..., k], grown)
    island = box_blur(hit.astype(float), 2) > 0.01
    fur_m, belly_m, muzzle_m, tip_m, back_m = (masks[..., k] for k in range(5))

    src_rgb = pixels.astype(float)
    lum = src_rgb @ np.array((0.299, 0.587, 0.114))
    r, g, b = src_rgb[..., 0], src_rgb[..., 1], src_rgb[..., 2]
    # gums and tongue: bright saturated pink (the dark tiger stripes are reddish brown too, but dark)
    pink = smoothstep(1.45, 1.75, r / np.maximum(g, 1e-3)) * smoothstep(0.30, 0.42, r)
    paint = np.clip(fur_m, 0, 1) * (1 - pink) * island

    # De-stripe: keep the fur strands (< 4 px, softened so the source JPEG blocks don't show) and only the
    # broadest shading (> 70 px); the stripe band in between is dropped.
    valid = island & (lum > 0.02)
    fine = np.clip(lum / np.maximum(blur(lum, 4, valid), 1e-3), 0.6, 1.5) ** 0.6
    broad = blur(lum, 70, valid)
    shade = broad * fine
    target = np.median(shade[paint > 0.5])
    t = np.clip(shade / target * 0.48 * (1 - 0.22 * back_m), 0, 1)
    stops = np.array([s for s, _ in PALETTE])
    colours = np.array([c for _, c in PALETTE])
    coat = np.stack([np.interp(t, stops, colours[:, k]) for k in range(3)], axis=-1)
    detail = fine[..., None]
    light = np.clip(belly_m * 0.8 + muzzle_m * 0.85, 0, 1)[..., None]
    coat = coat * (1 - light) + np.clip(CREAM * detail, 0, 1) * light
    coat = coat * (1 - tip_m[..., None]) + np.clip(TUFT * detail, 0, 1) * tip_m[..., None]
    out = src_rgb * (1 - paint[..., None]) + coat * paint[..., None]
    if len(sys.argv[sys.argv.index("--") + 1:]) > 2:      # debug: dump the intermediate layers
        for name, layer in (("paint", paint), ("broad", broad / broad.max()), ("fine", fine / 2), ("t", t),
                            ("tip", tip_m), ("belly", belly_m)):
            dbg = bpy.data.images.new(name, size, size)
            dbg.pixels = np.dstack([np.clip(layer, 0, 1)] * 3 + [np.ones((size, size))])[::-1].astype(np.float32).ravel()
            dbg.filepath_raw = dst.replace(".png", f"_{name}.png"); dbg.file_format = "PNG"; dbg.save()

    result = bpy.data.images.new("lion_coat", size, size)
    result.pixels = np.dstack((out, np.ones((size, size))))[::-1].astype(np.float32).ravel()
    result.filepath_raw = dst
    result.file_format = "PNG"
    result.save()
    print("WROTE", dst)


if __name__ == "__main__":
    main()
