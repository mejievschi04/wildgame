# Tribal settlement architecture: four styles x (hall, house, hut, canopy, tower, fence, gate, banner) + a ruin.
#   blender -b --python tools/blender/gen_buildings.py [-- player stone north red]
# Output: assets/models/buildings/SM_Bld_<Style>_<Kind>.gltf (+ shared textures/), buildings.json (footprints).
# Reference: the user's concept sheet (four clans: yellow hand, stone/bull skull, north/deer skull, red/wolf).
# Convention (Blender Z-up, metres): the door faces -Y (Godot +Z after the Y-up export), origin = ground centre.
# Everything reaches ~0.6 m below the origin so buildings sit into uneven ground.
import bpy, bmesh, json, math, os, random, subprocess, sys, zlib
import numpy as np
from mathutils import Vector, Matrix

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "art_source", "textures")
OUT = os.path.join(ROOT, "assets", "models", "buildings")
TEX = os.path.join(OUT, "textures")
os.makedirs(TEX, exist_ok=True)
TS = 1024

STYLE_RGB = {"player": (0.86, 0.62, 0.10), "stone": (0.62, 0.17, 0.10), "north": (0.17, 0.30, 0.50),
             "red": (0.80, 0.30, 0.10)}


# ================================================================ textures (numpy)

def _load(name, kind):
    d = os.path.join(SRC, name)
    f = [x for x in sorted(os.listdir(d)) if f"_{kind}_" in x and not x.endswith(".import")][0]
    img = bpy.data.images.load(os.path.join(d, f), check_existing=True)
    if img.size[0] != TS:
        img.scale(TS, TS)
    a = np.empty(TS * TS * 4, np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(TS, TS, 4)


def _save(arr, name, alpha=False):
    path = os.path.join(TEX, name + (".png" if alpha else ".jpg"))
    h, w = arr.shape[:2]
    img = bpy.data.images.new(name, w, h, alpha=alpha)
    img.pixels.foreach_set(np.ascontiguousarray(arr, np.float32).ravel())
    img.filepath_raw = path
    img.file_format = "PNG" if alpha else "JPEG"
    if not alpha:
        bpy.context.scene.render.image_settings.quality = 90
    img.save()
    bpy.data.images.remove(img)
    if not alpha:  # Godot's JPEG loader rejects Blender's APP1 "NeoGeo" marker: re-encode with the system tool
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "88", path, "--out", path],
                       check=True, capture_output=True)
    return path


def _lum(a):
    return a[..., 0] * 0.3 + a[..., 1] * 0.59 + a[..., 2] * 0.11


def colorize(a, rgb, keep=0.25, gain=1.0, contrast=1.0, mean=None):
    l = _lum(a)
    l = (l - l.mean()) * contrast + l.mean()
    if mean is not None:
        l = l * (mean / max(1e-3, l.mean()))
    out = a.copy()
    for c in range(3):
        out[..., c] = np.clip((l * rgb[c] * 2.2 * (1 - keep) + a[..., c] * keep) * gain, 0, 1)
    return out


def noise(h, w, cells, seed, octaves=4):
    rng = np.random.default_rng(seed)
    acc = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        n = cells * 2 ** o
        g = rng.random((n + 1, n + 1)).astype(np.float32)
        ys = np.linspace(0, n, h, endpoint=False)
        xs = np.linspace(0, n, w, endpoint=False)
        y0 = ys.astype(int); x0 = xs.astype(int)
        fy = (ys - y0)[:, None]; fx = (xs - x0)[None, :]
        fy = fy * fy * (3 - 2 * fy); fx = fx * fx * (3 - 2 * fx)
        v = (g[y0][:, x0] * (1 - fx) + g[y0][:, x0 + 1] * fx) * (1 - fy) + \
            (g[y0 + 1][:, x0] * (1 - fx) + g[y0 + 1][:, x0 + 1] * fx) * fy
        acc += v * amp; tot += amp; amp *= 0.5
    return acc / tot


# --- emblem signed-distance shapes, coordinates in [-1, 1] (y up)

def _grid(h, w):
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    return (xs / (w - 1)) * 2 - 1, (ys / (h - 1)) * 2 - 1


def sd_capsule(x, y, a, b, r):
    ax, ay = a; bx, by = b
    px, py = x - ax, y - ay
    dx, dy = bx - ax, by - ay
    t = np.clip((px * dx + py * dy) / (dx * dx + dy * dy + 1e-9), 0, 1)
    if np.isscalar(r):
        rr = r
    else:
        rr = r[0] + (r[1] - r[0]) * t
    return np.hypot(px - dx * t, py - dy * t) - rr


def sd_chain(x, y, pts, r0, r1):
    d = np.full(x.shape, 9.0, np.float32)
    n = len(pts) - 1
    for i in range(n):
        ra = r0 + (r1 - r0) * i / n
        rb = r0 + (r1 - r0) * (i + 1) / n
        d = np.minimum(d, sd_capsule(x, y, pts[i], pts[i + 1], (ra, rb)))
    return d


def sd_ellipse(x, y, c, rx, ry):
    return (np.hypot((x - c[0]) / rx, (y - c[1]) / ry) - 1.0) * min(rx, ry)


def sd_poly(x, y, pts):
    inside = np.zeros(x.shape, bool)
    d = np.full(x.shape, 9.0, np.float32)
    n = len(pts)
    for i in range(n):
        xi, yi = pts[i]; xj, yj = pts[(i + 1) % n]
        cond = ((yi > y) != (yj > y)) & (x < (xj - xi) * (y - yi) / (yj - yi + 1e-9) + xi)
        inside ^= cond
        d = np.minimum(d, sd_capsule(x, y, (xi, yi), (xj, yj), 0.0))
    return np.where(inside, -d, d)


def _arc(c, r, a0, a1, n=8, sx=1.0):
    return [(c[0] + math.cos(a0 + (a1 - a0) * i / n) * r * sx, c[1] + math.sin(a0 + (a1 - a0) * i / n) * r)
            for i in range(n + 1)]


def emblem(style, x, y):
    """Returns (paint sdf, hole sdf): paint < 0 is the emblem, hole < 0 is cut back to cloth."""
    U = lambda *ds: np.minimum.reduce(ds)
    hole = np.full(x.shape, 9.0, np.float32)
    if style == "player":  # a black hand print
        d = U(sd_ellipse(x, y, (0.0, -0.22), 0.36, 0.38),
              sd_capsule(x, y, (-0.24, 0.0), (-0.36, 0.62), (0.11, 0.095)),
              sd_capsule(x, y, (-0.06, 0.05), (-0.08, 0.78), (0.115, 0.1)),
              sd_capsule(x, y, (0.12, 0.03), (0.2, 0.7), (0.11, 0.095)),
              sd_capsule(x, y, (0.27, -0.05), (0.43, 0.43), (0.095, 0.08)),
              sd_capsule(x, y, (-0.28, -0.32), (-0.7, -0.02), (0.13, 0.1)))
        return d, hole
    if style == "red":  # a wolf head in profile, facing left
        head = [(-0.86, 0.02), (-0.7, 0.12), (-0.38, 0.22), (-0.16, 0.42), (-0.05, 0.78), (0.1, 0.5),
                (0.22, 0.86), (0.38, 0.42), (0.55, 0.22), (0.66, -0.12), (0.72, -0.6), (0.4, -0.5),
                (0.1, -0.42), (-0.18, -0.3), (-0.5, -0.2), (-0.76, -0.16), (-0.9, -0.06)]
        d = sd_poly(x, y, head)
        hole = U(sd_ellipse(x, y, (-0.1, 0.18), 0.075, 0.04),
                 sd_capsule(x, y, (-0.78, -0.1), (-0.4, -0.14), 0.018),
                 sd_capsule(x, y, (0.12, -0.1), (0.5, -0.32), 0.03),
                 sd_capsule(x, y, (0.02, 0.6), (0.16, 0.38), 0.03))
        return d, hole
    # Skulls. Bull (stone) has horns sweeping out and up; deer (north) has branching antlers.
    skull = U(sd_ellipse(x, y, (0.0, 0.12), 0.3, 0.24),
              sd_poly(x, y, [(-0.27, 0.05), (0.27, 0.05), (0.15, -0.45), (0.1, -0.68), (-0.1, -0.68),
                             (-0.15, -0.45)]))
    hole = U(sd_ellipse(x, y, (-0.13, 0.06), 0.085, 0.07), sd_ellipse(x, y, (0.13, 0.06), 0.085, 0.07),
             sd_poly(x, y, [(-0.05, -0.3), (0.05, -0.3), (0.03, -0.55), (-0.03, -0.55)]))
    parts = [skull]
    for s in (-1.0, 1.0):
        if style == "stone":
            horn = [(s * 0.22, 0.22), (s * 0.5, 0.28), (s * 0.74, 0.42), (s * 0.84, 0.62), (s * 0.8, 0.84)]
            parts.append(sd_chain(x, y, horn, 0.1, 0.02))
        else:
            beam = [(s * 0.14, 0.3), (s * 0.3, 0.5), (s * 0.5, 0.62), (s * 0.66, 0.78), (s * 0.72, 0.96)]
            parts.append(sd_chain(x, y, beam, 0.05, 0.022))
            for (a, b) in [((s * 0.3, 0.5), (s * 0.22, 0.8)), ((s * 0.5, 0.62), (s * 0.46, 0.92)),
                           ((s * 0.62, 0.72), (s * 0.86, 0.74)), ((s * 0.22, 0.38), (s * 0.06, 0.58))]:
                parts.append(sd_capsule(x, y, a, b, (0.036, 0.016)))
    return U(*parts), hole


def banner_texture(style):
    W, H = 512, 768
    x, y = _grid(H, W)
    base = np.array(STYLE_RGB[style], np.float32)
    leather = _load("brown_leather", "diff")
    grain = _lum(leather[:H, :W]) / max(1e-3, _lum(leather).mean())
    n1 = noise(H, W, 6, zlib.crc32(style.encode()) & 0xffff)
    n2 = noise(H, W, 40, 7, 2)
    col = np.zeros((H, W, 4), np.float32)
    shade = (0.72 + 0.4 * n1) * (0.85 + 0.15 * grain)
    edge = np.clip(1.0 - np.maximum(np.abs(x), 0.0) ** 6 * 0.6 - np.clip(-y - 0.4, 0, 1) * 0.5, 0.3, 1)
    for c in range(3):
        col[..., c] = base[c] * shade * edge
    # Emblem in the upper-middle: y in [-0.15, 0.95] of the cloth (cloth y=1 is the top edge).
    ex, ey = x * 1.45, (y - 0.38) * 1.45 * H / W
    paint, hole = emblem(style, ex, ey)
    rough = (n2 - 0.5) * 0.05
    ink = np.array((0.05, 0.045, 0.04) if style == "player" else (0.9, 0.84, 0.7), np.float32)
    m = np.clip(0.5 - (paint + rough) * 60.0, 0, 1) * np.clip((hole + rough) * 60.0 + 0.5, 0, 1)
    m *= np.clip(0.55 + n1 * 1.2, 0, 1) ** 0.4  # worn paint
    for c in range(3):
        col[..., c] = col[..., c] * (1 - m) + ink[c] * m * (0.8 + 0.2 * grain)
    # Tattered bottom: three long tails with ragged edges, frayed sides.
    xs = (x + 1) * 0.5
    tails = np.abs(((xs * 3.0) % 1.0) - 0.5) * 2.0  # 0 at the tail centres, 1 between
    bottom = -0.55 - 0.42 * (1.0 - tails) + (noise(H, W, 30, 3, 2) - 0.5) * 0.12
    side = 0.97 - noise(H, W, 24, 5, 2) * 0.05
    alpha = ((y > bottom) & (np.abs(x) < side) & (y < 0.99)).astype(np.float32)
    holes = noise(H, W, 18, 11, 3)
    alpha *= (holes < 0.78).astype(np.float32)
    col[..., 3] = alpha
    return _save(col, f"T_Bld_Banner_{style}", alpha=True)


def prepare_textures():
    """Builds the shared building textures from the CC0 sources. Returns {key: (diff, nor, arm)}."""
    t = {}
    def nor_arm(src):
        n = os.path.join(TEX, f"T_Bld_{src}_nor.jpg")
        a = os.path.join(TEX, f"T_Bld_{src}_arm.png")
        if not os.path.exists(n) or not os.path.exists(a):
            _save(_load(src, "nor_gl"), f"T_Bld_{src}_nor")
            arm = _load(src, "arm")
            arm[..., 3] = 1.0
            _save(arm, f"T_Bld_{src}_arm", alpha=True)
        return n, a
    th = _load("thatch_roof_angled", "diff")
    t["thatch"] = (_save(colorize(th, (0.5, 0.38, 0.2), 0.2, 1.05, 1.3), "T_Bld_Thatch_diff"),) + nor_arm("thatch_roof_angled")
    t["thatch_dark"] = (_save(colorize(th, (0.34, 0.27, 0.17), 0.2, 0.8, 1.2), "T_Bld_ThatchDark_diff"),) + nor_arm("thatch_roof_angled")
    t["fur"] = (_save(colorize(th, (0.46, 0.39, 0.3), 0.1, 1.0, 1.7), "T_Bld_Fur_diff"),) + nor_arm("thatch_roof_angled")
    t["fur_dark"] = (_save(colorize(th, (0.25, 0.21, 0.17), 0.1, 0.9, 1.5), "T_Bld_FurDark_diff"),) + nor_arm("thatch_roof_angled")
    bark = _load("bark_brown_01", "diff")
    t["log"] = (_save(colorize(bark, (0.36, 0.25, 0.16), 0.3, 0.95, 1.2), "T_Bld_Log_diff"),) + nor_arm("bark_brown_01")
    wood = _load("rough_wood", "diff")
    t["pole"] = (_save(colorize(wood, (0.46, 0.32, 0.2), 0.25, 1.0, 1.25), "T_Bld_Pole_diff"),) + nor_arm("rough_wood")
    t["pole_old"] = (_save(colorize(wood, (0.33, 0.29, 0.25), 0.4, 0.95, 1.1), "T_Bld_PoleOld_diff"),) + nor_arm("rough_wood")
    rock = _load("lichen_rock", "diff")
    t["stone"] = (_save(colorize(rock, (0.36, 0.35, 0.33), 0.3, 1.25, 0.9), "T_Bld_Stone_diff"),) + nor_arm("lichen_rock")
    lea = _load("brown_leather", "diff")
    t["hide"] = (_save(colorize(lea, (0.42, 0.3, 0.2), 0.2, 1.0, 2.0), "T_Bld_Hide_diff"),) + nor_arm("brown_leather")
    t["bone"] = (_save(colorize(lea, (0.5, 0.46, 0.38), 0.0, 1.0, 1.6, mean=0.82), "T_Bld_Bone_diff"),) + nor_arm("brown_leather")
    grime = noise(TS, TS, 5, 21)[..., None]
    for style, rgb in STYLE_RGB.items():
        dyed = colorize(lea, rgb, 0.0, 1.0, 2.6)
        dyed[..., :3] *= 0.75 + 0.45 * grime
        t["dye_" + style] = (_save(dyed, f"T_Bld_Dye_{style}_diff"),) + nor_arm("brown_leather")
        dark = dyed.copy()
        dark[..., :3] = dark[..., :3] * 0.55 + _lum(lea)[..., None] * 0.25
        t["dye_dark_" + style] = (_save(dark, f"T_Bld_DyeDark_{style}_diff"),) + nor_arm("brown_leather")
        t["banner_" + style] = (banner_texture(style),) + nor_arm("brown_leather")
    return t


# ================================================================ materials

TEXTURES = {}
_mats = {}


def mat(key):
    if key in _mats:
        return _mats[key]
    m = bpy.data.materials.new("M_Bld_" + key.title().replace("_", ""))
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    if key == "shadow":
        b.inputs["Base Color"].default_value = (0.02, 0.016, 0.012, 1)
        b.inputs["Roughness"].default_value = 1.0
    else:
        diff, nor, arm = TEXTURES[key]
        d = nt.nodes.new("ShaderNodeTexImage"); d.image = bpy.data.images.load(diff, check_existing=True)
        nt.links.new(d.outputs["Color"], b.inputs["Base Color"])
        if key.startswith("banner"):
            nt.links.new(d.outputs["Alpha"], b.inputs["Alpha"])
            m.name = "M_Bld_Banner" + key[7:].title()
        n = nt.nodes.new("ShaderNodeTexImage"); n.image = bpy.data.images.load(nor, check_existing=True)
        n.image.colorspace_settings.name = "Non-Color"
        nm = nt.nodes.new("ShaderNodeNormalMap")
        nt.links.new(n.outputs["Color"], nm.inputs["Color"]); nt.links.new(nm.outputs["Normal"], b.inputs["Normal"])
        a = nt.nodes.new("ShaderNodeTexImage"); a.image = bpy.data.images.load(arm, check_existing=True)
        a.image.colorspace_settings.name = "Non-Color"
        sep = nt.nodes.new("ShaderNodeSeparateColor")
        nt.links.new(a.outputs["Color"], sep.inputs["Color"]); nt.links.new(sep.outputs["Green"], b.inputs["Roughness"])
        if key.startswith(("dye", "hide", "banner")):
            m.use_backface_culling = False
    _mats[key] = m
    return m


# ================================================================ geometry accumulator

class Geo:
    """Collects faces of one model (per-loop UVs, material keys, smooth flags); build() makes one object."""

    def __init__(self, seed):
        self.v = []
        self.f = []  # (vert ids, uvs, material key, smooth)
        self.rng = random.Random(seed)

    def vert(self, p):
        self.v.append(Vector(p))
        return len(self.v) - 1

    def face(self, ids, uvs, m, smooth=True):
        self.f.append((tuple(ids), tuple(uvs), m, smooth))

    def quad(self, a, b, c, d, m, uv=None, smooth=False):
        ids = [self.vert(p) for p in (a, b, c, d)]
        if uv is None:  # planar projection on the dominant axis, metres
            n = (Vector(b) - Vector(a)).cross(Vector(d) - Vector(a))
            ax = max(range(3), key=lambda i: abs(n[i]))
            pick = ((1, 2), (0, 2), (0, 1))[ax]
            uv = [(Vector(p)[pick[0]], Vector(p)[pick[1]]) for p in (a, b, c, d)]
        self.face(ids, uv, m, smooth)

    # ---- tubes: logs, poles, stakes, tusks, horns, ropes

    def tube(self, path, radii, m, seg=8, cap_start=True, cap_end=True, u_rep=None, v_scale=1.0, wobble=0.0):
        path = [Vector(p) for p in path]
        if not isinstance(radii, (list, tuple)):
            radii = [radii] * len(path)
        rings = []
        acc = 0.0
        prev_s = None
        circ = 2 * math.pi * max(radii)
        u_rep = u_rep if u_rep is not None else max(1.0, round(circ / 0.6))
        for i, p in enumerate(path):
            if i:
                acc += (path[i] - path[i - 1]).length
            t = (path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)]).normalized()
            if prev_s is None:
                ref = Vector((0, 0, 1)) if abs(t.z) < 0.9 else Vector((1, 0, 0))
                s = (ref - t * ref.dot(t)).normalized()
            else:  # parallel transport keeps the texture from twisting
                s = (prev_s - t * prev_s.dot(t)).normalized()
            prev_s = s
            u = t.cross(s)
            ring = []
            for k in range(seg):
                a = 2 * math.pi * k / seg
                r = radii[i] * (1.0 + (wobble * math.sin(k * 2.7 + i * 1.3) if wobble else 0.0))
                ring.append(self.vert(p + (s * math.cos(a) + u * math.sin(a)) * r))
            rings.append((ring, acc))
        for i in range(len(rings) - 1):
            (ra, va), (rb, vb) = rings[i], rings[i + 1]
            for k in range(seg):
                k2 = (k + 1) % seg
                u0, u1 = k / seg * u_rep, (k + 1) / seg * u_rep
                self.face([ra[k], ra[k2], rb[k2], rb[k]],
                          [(u0, va * v_scale), (u1, va * v_scale), (u1, vb * v_scale), (u0, vb * v_scale)], m)
        for (ring, _), do, rev in ((rings[0], cap_start, True), (rings[-1], cap_end, False)):
            if not do:
                continue
            ids = list(reversed(ring)) if rev else ring
            c = sum((self.v[i] for i in ids), Vector()) / len(ids)
            ci = self.vert(c)
            for k in range(len(ids)):
                a, b = ids[k], ids[(k + 1) % len(ids)]
                self.face([a, b, ci], [(self.v[a].x * 2, self.v[a].y * 2), (self.v[b].x * 2, self.v[b].y * 2),
                                       (c.x * 2, c.y * 2)], m, False)

    def log(self, a, b, r0, r1=None, m="pole", seg=8, bend=0.0, sharp=0.0, n=None, cap=True, sag=0.0):
        """A natural pole a→b: slight bend, knobbly radius, optional sharpened tip of length `sharp` at b."""
        a, b = Vector(a), Vector(b)
        r1 = r0 * 0.85 if r1 is None else r1
        L = (b - a).length
        n = n or max(2, int(L / 0.45) + 1)
        d = (b - a).normalized()
        side = d.cross(Vector((0, 0, 1)))
        if side.length < 0.1:
            side = d.cross(Vector((1, 0, 0)))
        side.normalize()
        up = side.cross(d)
        rng = self.rng
        ph = rng.uniform(0, 6.28)
        bend = bend if bend else rng.uniform(-0.012, 0.012) * L
        pts, rad = [], []
        body = L - sharp
        for i in range(n + 1):
            t = i / n * (body / L)
            p = a + (b - a) * t + side * math.sin(t * math.pi) * bend - up * math.sin(t * math.pi) * sag
            p += side * 0.008 * math.sin(t * 9 + ph) * L ** 0.5
            pts.append(p)
            rad.append((r0 + (r1 - r0) * t) * (1 + 0.06 * math.sin(t * 17 + ph)))
        if sharp > 0:
            tip_r = rad[-1]
            pts.append(a + d * (L - sharp * 0.55) + side * 0.005)
            rad.append(tip_r * 0.55)
            pts.append(b)
            rad.append(0.004)
        self.tube(pts, rad, m, seg, cap_start=cap, cap_end=cap and sharp <= 0)

    def lashing(self, at, axis, r, turns=3, m="rope"):
        """Rope wraps around a joint: a few thin rings."""
        axis = Vector(axis).normalized()
        ref = Vector((0, 0, 1)) if abs(axis.z) < 0.9 else Vector((1, 0, 0))
        s = (ref - axis * ref.dot(axis)).normalized(); u = axis.cross(s)
        for k in range(turns):
            c = Vector(at) + axis * (k - (turns - 1) / 2) * 0.035
            pts = [c + (s * math.cos(a) + u * math.sin(a)) * (r + 0.012)
                   for a in [2 * math.pi * j / 8 for j in range(9)]]
            self.tube(pts, 0.012, m, 3, False, False, u_rep=1, v_scale=4)

    # ---- stones

    def stone(self, c, size, yaw=0.0, m="stone", cuts=2, rough=0.18, tilt=0.06):
        """A rounded, lumpy block (subdivided box pushed toward an ellipsoid plus noise)."""
        rng = self.rng
        c = Vector(c)
        rot = Matrix.Rotation(yaw, 3, "Z") @ Matrix.Rotation(rng.uniform(-tilt, tilt), 3, "X") @ \
            Matrix.Rotation(rng.uniform(-tilt, tilt), 3, "Y")
        hs = Vector(size) * 0.5
        N = cuts + 1
        cache = {}
        ph = [rng.uniform(0, 6.28) for _ in range(3)]

        def vid(ix, iy, iz):
            key = (ix, iy, iz)
            if key not in cache:
                q = Vector((ix / N * 2 - 1, iy / N * 2 - 1, iz / N * 2 - 1))
                sph = q.normalized() * 1.0 if q.length > 0 else q
                q2 = q.lerp(sph * 1.15, 0.45)
                q2 = Vector((max(-1.08, min(1.08, q2.x)), max(-1.08, min(1.08, q2.y)), max(-1.08, min(1.08, q2.z))))
                wob = 1.0 + rough * (math.sin(q.x * 3.1 + ph[0]) * math.sin(q.y * 2.7 + ph[1]) +
                                     0.5 * math.sin(q.z * 4.3 + ph[2] + q.x * 2.0))
                p = Vector((q2.x * hs.x, q2.y * hs.y, q2.z * hs.z)) * wob
                cache[key] = self.vert(c + rot @ p)
            return cache[key]

        faces = []
        for i in range(N):
            for j in range(N):
                faces.append([(i, j, 0), (i, j + 1, 0), (i + 1, j + 1, 0), (i + 1, j, 0)])
                faces.append([(i, j, N), (i + 1, j, N), (i + 1, j + 1, N), (i, j + 1, N)])
                faces.append([(i, 0, j), (i + 1, 0, j), (i + 1, 0, j + 1), (i, 0, j + 1)])
                faces.append([(i, N, j), (i, N, j + 1), (i + 1, N, j + 1), (i + 1, N, j)])
                faces.append([(0, i, j), (0, i, j + 1), (0, i + 1, j + 1), (0, i + 1, j)])
                faces.append([(N, i, j), (N, i + 1, j), (N, i + 1, j + 1), (N, i, j + 1)])
        off = (rng.uniform(0, 5), rng.uniform(0, 5))
        for fc in faces:
            ids = [vid(*k) for k in fc]
            pts = [self.v[i] for i in ids]
            n = (pts[1] - pts[0]).cross(pts[3] - pts[0])
            ax = max(range(3), key=lambda i: abs(n[i]))
            pick = ((1, 2), (0, 2), (0, 1))[ax]
            uv = [(p[pick[0]] * 0.7 + off[0], p[pick[1]] * 0.7 + off[1]) for p in pts]
            self.face(ids, uv, m, True)

    def stone_course(self, a, b, z0, h, depth, m="stone", wmin=0.35, wmax=0.65, courses=3, outward=None):
        """Dry-laid wall from a to b (ground points), `courses` rows from z0 up to z0+h."""
        a, b = Vector(a), Vector(b)
        L = (b - a).length
        d = (b - a).normalized()
        yaw = math.atan2(d.y, d.x)
        ch = h / courses
        for k in range(courses):
            x = -self.rng.uniform(0, wmin) if k % 2 else 0.0
            while x < L:
                w = min(self.rng.uniform(wmin, wmax), L - x + 0.15)
                if w > 0.12:
                    c = a + d * (x + w * 0.5)
                    c.z = z0 + ch * (k + 0.5)
                    self.stone(c, (w * 1.02, depth * self.rng.uniform(0.85, 1.1), ch * self.rng.uniform(1.0, 1.25)),
                               yaw + self.rng.uniform(-0.06, 0.06), m)
                x += w

    # ---- cloth / hides

    def sheet(self, corners, m, nu=6, nv=6, sag=0.0, wave=0.0, ragged=0.0, uv_rect=None, double=True, z_of=None):
        """Bilinear patch a,b,c,d (a→b along u, a→d along v) with sag along its normal and an optional ragged v=1 edge."""
        a, b, c, d = [Vector(p) for p in corners]
        n = (b - a).cross(d - a).normalized()
        rng = self.rng
        grid = []
        for j in range(nv + 1):
            row = []
            for i in range(nu + 1):
                u, v = i / nu, j / nv
                p = (a * (1 - u) + b * u) * (1 - v) + (d * (1 - u) + c * u) * v
                p -= n * sag * math.sin(u * math.pi) * (0.4 + 0.6 * math.sin(v * math.pi))
                p += n * wave * math.sin(u * 7.0 + v * 3.0 + rng.uniform(0, 0.4))
                if ragged and j == nv:
                    p += (d - a).normalized() * rng.uniform(-ragged, ragged * 0.3)
                row.append(self.vert(p))
            grid.append(row)
        L_u, L_v = (b - a).length, (d - a).length
        for j in range(nv):
            for i in range(nu):
                ids = [grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]]
                if uv_rect:
                    u0, v0, u1, v1 = uv_rect
                    uv = [(u0 + (u1 - u0) * i / nu, v0 + (v1 - v0) * j / nv),
                          (u0 + (u1 - u0) * (i + 1) / nu, v0 + (v1 - v0) * j / nv),
                          (u0 + (u1 - u0) * (i + 1) / nu, v0 + (v1 - v0) * (j + 1) / nv),
                          (u0 + (u1 - u0) * i / nu, v0 + (v1 - v0) * (j + 1) / nv)]
                else:
                    uv = [(L_u * i / nu * 0.6, L_v * j / nv * 0.6), (L_u * (i + 1) / nu * 0.6, L_v * j / nv * 0.6),
                          (L_u * (i + 1) / nu * 0.6, L_v * (j + 1) / nv * 0.6), (L_u * i / nu * 0.6, L_v * (j + 1) / nv * 0.6)]
                self.face(ids, uv, m, True)

    def banner(self, top_center, width, height, style, yaw=0.0, wave=0.04, bar=True):
        """Hanging banner (alpha-cut emblem cloth) under a crossbar; faces -Y rotated by yaw."""
        R = Matrix.Rotation(yaw, 3, "Z")
        t = Vector(top_center)
        a = t + R @ Vector((-width / 2, 0, 0))
        b = t + R @ Vector((width / 2, 0, 0))
        c = t + R @ Vector((width / 2, 0, -height))
        d = t + R @ Vector((-width / 2, 0, -height))
        # u along the width, v from the top (v=1 is the texture top) down to the tails.
        self.sheet([d, c, b, a], "banner_" + style, 5, 8, 0.0, wave, 0.0, uv_rect=(0, 0, 1, 1))
        if bar:
            self.log(a + R @ Vector((-0.12, 0.03, 0.02)), b + R @ Vector((0.12, 0.03, 0.02)), 0.035, 0.03, "pole", 6)

    def build(self, name):
        bm = bmesh.new()
        uvl = bm.loops.layers.uv.new("UVMap")
        verts = [bm.verts.new(p) for p in self.v]
        keys = []
        for ids, uvs, m, smooth in self.f:
            if len(set(ids)) < 3:
                continue
            try:
                f = bm.faces.new([verts[i] for i in ids])
            except ValueError:
                continue
            if m not in keys:
                keys.append(m)
            f.material_index = keys.index(m)
            f.smooth = smooth
            for l, uv in zip(f.loops, uvs):
                l[uvl].uv = uv
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        for k in keys:
            me.materials.append(mat(k))
        o = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(o)
        return o


# ================================================================ shared parts

def skull_bull(g, at, yaw, s=1.0, horn=1.0):
    R = Matrix.Rotation(yaw, 3, "Z")
    P = lambda x, y, z: Vector(at) + R @ (Vector((x, y, z)) * s)
    g.tube([P(0, 0.02, 0.12), P(0, -0.02, 0.0), P(0, -0.08, -0.22), P(0, -0.1, -0.4)],
           [0.15 * s, 0.17 * s, 0.11 * s, 0.07 * s], "bone", 10)
    g.stone(P(0, 0.0, 0.06), (0.36 * s, 0.22 * s, 0.26 * s), yaw, "bone", 2, 0.08, 0.0)
    for k in (-1, 1):
        pts = [P(k * 0.14, 0.02, 0.12), P(k * 0.34, 0.0, 0.16), P(k * 0.52 * horn, -0.04, 0.28 * horn),
               P(k * 0.62 * horn, -0.06, 0.48 * horn), P(k * 0.58 * horn, -0.04, 0.68 * horn)]
        g.tube(pts, [0.07 * s, 0.065 * s, 0.05 * s, 0.032 * s, 0.006], "horn", 8, True, False)
        g.stone(P(k * 0.09, -0.12, 0.05), (0.07 * s, 0.03 * s, 0.06 * s), 0, "shadow", 1, 0.0, 0.0)


def skull_deer(g, at, yaw, s=1.0):
    R = Matrix.Rotation(yaw, 3, "Z")
    P = lambda x, y, z: Vector(at) + R @ (Vector((x, y, z)) * s)
    g.tube([P(0, 0.02, 0.1), P(0, -0.03, 0.0), P(0, -0.06, -0.25), P(0, -0.07, -0.42)],
           [0.1 * s, 0.11 * s, 0.07 * s, 0.045 * s], "bone", 10)
    for k in (-1, 1):
        g.stone(P(k * 0.065, -0.09, 0.02), (0.05 * s, 0.03 * s, 0.045 * s), 0, "shadow", 1, 0.0, 0.0)
        beam = [P(k * 0.06, 0.0, 0.12), P(k * 0.2, 0.02, 0.3), P(k * 0.36, 0.0, 0.46), P(k * 0.46, -0.02, 0.66),
                P(k * 0.5, -0.04, 0.86)]
        g.tube(beam, [0.035 * s, 0.03 * s, 0.025 * s, 0.02 * s, 0.006], "bone", 6, True, False)
        for i, (dx, dz) in enumerate([(-0.08, 0.2), (0.0, 0.24), (0.16, 0.14)]):
            base = beam[i + 1]
            tip = base + R @ Vector((k * dx, -0.03, dz)) * s
            g.tube([base, base.lerp(tip, 0.5) + Vector((0, 0, 0.02 * s)), tip], [0.022 * s, 0.015 * s, 0.004],
                   "bone", 5, False, False)


def tusk(g, foot, top, out, r=0.12, curl=0.35):
    """A mammoth tusk rising from `foot` to `top`, bowed outward along `out`."""
    foot, top, out = Vector(foot), Vector(top), Vector(out).normalized()
    pts, rad = [], []
    for i in range(9):
        t = i / 8
        p = foot.lerp(top, t) + out * math.sin(t * math.pi) * curl * (foot - top).length * 0.35
        pts.append(p)
        rad.append(r * (1 - 0.8 * t ** 1.4) + 0.006)
    g.tube(pts, rad, "bone", 10, True, False)


def stakes_ring(g, center, radius, n, h, r=0.07, gap=None, rng=None):
    """Short sharpened stakes standing around something (the hall in the concept has a ring of them)."""
    rng = rng or g.rng
    for i in range(n):
        a = 2 * math.pi * i / n + rng.uniform(-0.05, 0.05)
        if gap and abs(math.atan2(math.sin(a - gap[0]), math.cos(a - gap[0]))) < gap[1]:
            continue
        p = Vector(center) + Vector((math.cos(a), math.sin(a), 0)) * radius
        hh = h * rng.uniform(0.8, 1.15)
        lean = Vector((math.cos(a), math.sin(a), 0)) * rng.uniform(0.05, 0.25)
        g.log(p - Vector((0, 0, 0.4)), p + lean + Vector((0, 0, hh)), r, r * 0.85, "pole", 6, sharp=0.35)


def thatch_plane(g, ridge_a, ridge_b, eave_a, eave_b, rows, m="thatch", thick=0.2, col_w=0.2, fringe=0.3,
                 under="thatch_dark", lift=0.0):
    """Layered thatch courses on the quad ridge_a-ridge_b (top) / eave_a-eave_b (bottom): each course is a
    row of bulging straw bundles with a ragged hanging lower edge, upper courses lying over lower ones."""
    ridge_a, ridge_b, eave_a, eave_b = map(Vector, (ridge_a, ridge_b, eave_a, eave_b))
    along = ridge_b - ridge_a
    L = along.length
    slope = (eave_a - ridge_a)
    n = along.cross(slope).normalized()
    if n.z < 0:
        n = -n
    S = slope.length
    sd = slope.normalized()
    cols = max(2, int(L / col_w))
    rng = g.rng
    for k in range(rows):
        t0 = max(0.0, k / rows - 0.18)
        t1 = (k + 1) / rows
        base_off = lift + thick * 0.55 * (rows - k) / rows + 0.03
        th = thick * rng.uniform(0.85, 1.15)
        for c in range(cols):
            u0, u1 = c / cols, (c + 1) / cols
            last = k == rows - 1
            ext = rng.uniform(0.0, fringe) * (1.0 if last else 0.55)
            t1e = t1 + ext / S
            bump = rng.uniform(-0.03, 0.04)
            uoff = rng.uniform(0, 3.0)
            fan = rng.uniform(-0.05, 0.05)

            def P(u, t, h=0.0):
                base = (ridge_a.lerp(ridge_b, u)).lerp(eave_a.lerp(eave_b, u), t)
                mid = 4 * (t - t0) * (t1e - t) / max(1e-4, (t1e - t0) ** 2)  # bundle bulge
                return base + n * (base_off + bump + 0.07 * mid + h + 0.035 * math.sin(u * L * 1.7 + k * 2.1)) + \
                    along.normalized() * fan * (t - t0) * S * 0.3

            tm = (t0 + t1e) / 2
            uv = lambda u, t: ((u - u0) * L * 0.9 + uoff, -t * S * 0.9 + k * 0.37)
            ids = [g.vert(P(u0, t0)), g.vert(P(u1, t0)), g.vert(P(u1, tm)), g.vert(P(u0, tm)),
                   g.vert(P(u1, t1e)), g.vert(P(u0, t1e))]
            g.face([ids[0], ids[1], ids[2], ids[3]], [uv(u0, t0), uv(u1, t0), uv(u1, tm), uv(u0, tm)], m, True)
            g.face([ids[3], ids[2], ids[4], ids[5]], [uv(u0, tm), uv(u1, tm), uv(u1, t1e), uv(u0, t1e)], m, True)
            lip = -n * th + sd * 0.04
            d1, c1 = g.v[ids[5]], g.v[ids[4]]
            g.face([ids[5], ids[4], g.vert(c1 + lip), g.vert(d1 + lip)],
                   [uv(u0, t1e), uv(u1, t1e), uv(u1, t1e + 0.15 / S), uv(u0, t1e + 0.15 / S)], m, True)
    # The underside seen from inside / below the eaves.
    g.quad(eave_a - n * 0.02, eave_b - n * 0.02, ridge_b - n * 0.02, ridge_a - n * 0.02, under,
           [(0, 0), (L, 0), (L, S), (0, S)])


def thatch_cone(g, center, r_eave, z_eave, z_top, rows, m="thatch", segs=None, thick=0.13, fringe=0.15,
                squash=(1.0, 1.0), dome=0.0, under="thatch_dark", lift=0.0):
    """Round thatch (conical, or domed when dome > 0) with ragged courses."""
    c = Vector(center)
    segs = segs or max(16, int(2 * math.pi * r_eave / 0.16))
    rng = g.rng

    def P(a, t):  # t=0 apex, t=1 eave
        q = t * math.pi / 2
        rr = r_eave * (dome * math.sin(q) + (1 - dome) * t)
        z = z_top + (z_eave - z_top) * (dome * (1 - math.cos(q)) + (1 - dome) * t)
        return c + Vector((math.cos(a) * rr * squash[0], math.sin(a) * rr * squash[1], z))

    for k in range(rows):
        t0 = max(0.0, k / rows - 0.1)
        t1 = (k + 1) / rows
        for s in range(segs):
            a0, a1 = 2 * math.pi * s / segs, 2 * math.pi * (s + 1) / segs
            ext = rng.uniform(0, fringe) / max(0.5, r_eave)
            t1e = t1 + ext * (1.0 if k == rows - 1 else 0.6)
            out0 = Vector((math.cos(a0), math.sin(a0), 0.5)).normalized()
            out1 = Vector((math.cos(a1), math.sin(a1), 0.5)).normalized()
            o = lift + thick * 0.35 * (rows - k) / rows + rng.uniform(-0.01, 0.03)
            a = P(a0, t0) + out0 * o; b = P(a1, t0) + out1 * o
            cc = P(a1, t1e) + out1 * o; d = P(a0, t1e) + out0 * o
            circ = 2 * math.pi * r_eave
            uv = lambda aa, t: (aa / (2 * math.pi) * circ * 0.9, -t * (z_top - z_eave + r_eave) * 0.9 + k * 0.37)
            g.face([g.vert(a), g.vert(b), g.vert(cc), g.vert(d)], [uv(a0, t0), uv(a1, t0), uv(a1, t1e), uv(a0, t1e)], m)
            lip = Vector((0, 0, -thick - rng.uniform(-0.02, 0.03)))
            g.face([g.vert(d), g.vert(cc), g.vert(cc + lip), g.vert(d + lip)],
                   [uv(a0, t1e), uv(a1, t1e), uv(a1, t1e + 0.05), uv(a0, t1e + 0.05)], m)
    # underside
    ring = [g.vert(P(2 * math.pi * s / 24, 1.0) - Vector((0, 0, 0.03))) for s in range(24)]
    apex = g.vert(c + Vector((0, 0, z_top - 0.1)))
    for s in range(24):
        g.face([ring[(s + 1) % 24], ring[s], apex], [(0, 0), (1, 0), (0.5, 1)], under)


def plank_door(g, x0, x1, z0, z1, y, m="pole_old"):
    n = max(3, int((x1 - x0) / 0.16))
    for i in range(n):
        xa = x0 + (x1 - x0) * i / n
        xb = x0 + (x1 - x0) * (i + 1) / n - 0.01
        top = z1 - g.rng.uniform(0, 0.06)
        g.stone(Vector(((xa + xb) / 2, y, (z0 + top) / 2)), (xb - xa, 0.06, top - z0), 0.0, m, 1, 0.02, 0.0)
    for z in (z0 + 0.3, z1 - 0.35):
        g.log((x0 - 0.05, y - 0.06, z), (x1 + 0.05, y - 0.06, z + 0.02), 0.03, 0.028, m, 6)


# ================================================================ archetypes

def gable_house(g, style, W, L, eave_z, ridge_z, wall="stakes", roof="thatch", door_w=1.4, door_h=2.0,
                overhang=0.7, gable_ext=0.6, crossed=1.2, stakes_around=False, porch=False, ruin=False):
    """Rectangular house, ridge along Y, door in the -Y gable. Walls: stakes | logs | stone | none."""
    rng = g.rng
    hx, hy = W / 2, L / 2
    ye0, ye1 = -hy - gable_ext, hy + gable_ext
    ex = hx + overhang
    ez = eave_z - overhang * (ridge_z - eave_z) / hx
    # --- walls (long sides)
    if wall == "stone":
        for x in (-hx, hx):
            g.stone_course((x, -hy, 0), (x, hy, 0), -0.4, eave_z + 0.45, 0.55, courses=5)
        g.stone_course((-hx, hy, 0), (hx, hy, 0), -0.4, eave_z + 0.45, 0.55, courses=5)
        for x in (-hx, hx):  # corner menhirs
            for y in (-hy, hy):
                g.stone((x, y, eave_z * 0.55), (0.75, 0.7, eave_z * 1.4 + 0.6), rng.uniform(0, 3), "stone", 2, 0.12)
    elif wall in ("stakes", "logs"):
        for x in (-hx, hx):
            n = int(L / 0.24)
            for i in range(n + 1):
                y = -hy + L * i / n
                top = eave_z - 0.15 + rng.uniform(-0.08, 0.05)
                if wall == "stakes":
                    g.log((x, y, -0.5), (x + rng.uniform(-0.02, 0.02), y, top), 0.11, 0.1, "log", 7)
            if wall == "logs":
                k = int((eave_z + 0.3) / 0.26)
                for j in range(k):
                    z = 0.13 + j * 0.26
                    g.log((x, -hy - 0.25, z), (x, hy + 0.25, z), 0.13, 0.12, "log", 9)
        for x in (-hx, hx):  # posts at the corners and plates under the eaves
            for y in (-hy, hy):
                g.log((x, y, -0.5), (x, y, eave_z - 0.05), 0.16, 0.14, "log", 9)
            g.log((x, -hy - 0.3, eave_z - 0.12), (x, hy + 0.3, eave_z - 0.1), 0.12, 0.11, "log", 8)
        # back wall
        n = int(W / 0.24)
        for i in range(n + 1):
            x = -hx + W * i / n
            top = eave_z + (ridge_z - eave_z) * (1 - abs(x) / hx) - 0.1
            g.log((x, hy, -0.5), (x, hy, top), 0.1, 0.09, "log", 7)
        for x in (-hx, hx):
            g.stone_course((x - 0.1 * (1 if x > 0 else -1), -hy, 0), (x, hy, 0), -0.25, 0.4, 0.4, courses=1)
    # --- front gable: stake wall with a door, dark interior behind it
    n = int(W / 0.2)
    for i in range(n + 1):
        x = -hx + W * i / n
        top = eave_z + (ridge_z - eave_z) * (1 - abs(x) / hx) - 0.1
        if abs(x) < door_w / 2 + 0.05:  # above the door only
            if top > door_h + 0.1:
                g.log((x, -hy, door_h + 0.05), (x, -hy, top), 0.08, 0.075, "pole", 6)
            continue
        if wall == "stone" and top < eave_z + 0.6:
            continue
        g.log((x, -hy, -0.5 if wall != "stone" else eave_z + 0.2), (x, -hy, top), 0.1, 0.09, "log", 7)
    if wall == "stone":
        for side in (-1, 1):
            g.stone_course((side * (door_w / 2 + 0.35), -hy, 0), (side * hx, -hy, 0), -0.4, eave_z + 0.4, 0.55, courses=5)
    for side in (-1, 1):  # door jambs + lintel
        g.log((side * (door_w / 2 + 0.08), -hy - 0.12, -0.5), (side * (door_w / 2 + 0.03), -hy - 0.12, door_h + 0.35),
              0.13, 0.11, "log", 8)
    g.log((-door_w / 2 - 0.45, -hy - 0.18, door_h + 0.1), (door_w / 2 + 0.45, -hy - 0.18, door_h + 0.14), 0.12, 0.11, "log", 8)
    g.lashing((-door_w / 2 - 0.05, -hy - 0.18, door_h + 0.1), (1, 0, 0), 0.12)
    g.lashing((door_w / 2 + 0.05, -hy - 0.18, door_h + 0.14), (1, 0, 0), 0.12)
    # dim interior: back panel behind the door so the opening reads dark from outside
    g.quad((-door_w / 2, -hy + 1.4, 0), (door_w / 2, -hy + 1.4, 0), (door_w / 2, -hy + 1.4, door_h),
           (-door_w / 2, -hy + 1.4, door_h), "shadow")
    if not ruin and style in ("player", "stone"):  # hide door curtain, half drawn
        g.sheet([(-door_w / 2 + 0.05, -hy - 0.05, 0.05), (-0.05, -hy - 0.05, 0.1),
                 (-0.05, -hy - 0.05, door_h), (-door_w / 2 + 0.05, -hy - 0.05, door_h)], "hide", 3, 4, 0.03, 0.02)
    # --- roof structure: rafters at both gables, crossed and sticking out past the ridge
    for y in (ye0 + 0.1, ye1 - 0.1):
        for s in (-1, 1):
            foot = Vector((s * ex, y, ez))
            peak = Vector((0, y, ridge_z))
            dirv = (peak - foot).normalized()
            g.log(foot - dirv * 0.2, peak + dirv * crossed, 0.12, 0.08, "log", 8, sharp=0.3 if crossed > 0.5 else 0)
        g.lashing((0, y, ridge_z), (0, 1, 0), 0.16)
    g.log((0, ye0 - 0.25, ridge_z + 0.05), (0, ye1 + 0.25, ridge_z + 0.07), 0.14, 0.13, "log", 9)  # ridge pole
    if ruin:
        for s in (-1, 1):
            for i in range(5):
                y = ye0 + (ye1 - ye0) * (i + 0.5) / 5
                g.log((s * ex, y, ez - 0.2), (0, y + rng.uniform(-0.3, 0.3), ridge_z - rng.uniform(0, 0.8)), 0.07, 0.06,
                      "pole_old", 6)
    # --- roof covering
    for s in (-1, 1):
        ra, rb = Vector((0, ye0, ridge_z)), Vector((0, ye1, ridge_z))
        ea, eb = Vector((s * ex, ye0, ez)), Vector((s * ex, ye1, ez))
        if s > 0:
            ra, rb, ea, eb = rb, ra, eb, ea
        if ruin:
            ra2, rb2 = ra.lerp(ea, 0.45), rb.lerp(eb, 0.45)
            ea2, eb2 = ea, eb
            if s > 0:
                rb2 = rb.lerp(eb, 0.45); ra2 = ra.lerp(ea, 0.45); eb2 = ra2.lerp(eb2, 0.55)
            thatch_plane(g, ra2, rb2.lerp(ra2, 0.3), ea2, eb2.lerp(ea2, 0.3), 3, "thatch_dark")
            continue
        if roof == "thatch":
            thatch_plane(g, ra, rb, ea, eb, max(5, int((ra - ea).length / 0.75)))
        elif roof == "thatch_hides":
            thatch_plane(g, ra, rb, ea, eb, max(5, int((ra - ea).length / 0.75)), "thatch_dark", under="hide")
            nrm = (rb - ra).cross(ea - ra).normalized()
            if nrm.z < 0:
                nrm = -nrm
            for u0, u1, key in ((0.08, 0.36, "dye_" + style), (0.55, 0.8, "hide"), (0.84, 0.97, "dye_dark_" + style)):
                P = lambda u, t: ra.lerp(rb, u).lerp(ea.lerp(eb, u), t) + nrm * 0.32
                g.sheet([P(u0, -0.02), P(u1, -0.02), P(u1, 0.8), P(u0, 0.8)], key, 5, 6, -0.04, 0.015, 0.15)
                for t in (0.45, 0.78):  # weight stones on ropes
                    p = P((u0 + u1) / 2 + rng.uniform(-0.05, 0.05), t) + nrm * 0.12
                    g.stone(p, (0.42, 0.36, 0.28), rng.uniform(0, 3), "stone", 1, 0.2)
        elif roof in ("hide", "hide_thatch"):
            rows = max(3, int((ra - ea).length / 1.2))
            for k in range(rows):
                t0, t1 = k / rows - 0.04, (k + 1) / rows
                ncol = max(2, int((ra - rb).length / 1.6))
                for c in range(ncol):
                    u0, u1 = c / ncol - 0.02, (c + 1) / ncol + 0.02
                    P = lambda u, t: ra.lerp(rb, u).lerp(ea.lerp(eb, u), t) + Vector((0, 0, 0.06 + 0.02 * k))
                    r = rng.random()
                    key = "dye_" + style if r < 0.62 else ("dye_dark_" + style if r < 0.85 else "hide")
                    jit = Vector((0, rng.uniform(-0.08, 0.08), rng.uniform(-0.05, 0.05)))
                    g.sheet([P(u0, t0) + jit, P(u1, t0) + jit, P(u1, t1), P(u0, t1)], key, 4, 3,
                            rng.uniform(0.04, 0.1), 0.012, 0.14 if k == rows - 1 else 0.03)
            g.quad(ea - Vector((0, 0, 0.04)), eb - Vector((0, 0, 0.04)), rb - Vector((0, 0, 0.04)), ra - Vector((0, 0, 0.04)),
                   "hide")
            # poles holding the hides down
            for c in range(int((ra - rb).length / 1.6) + 1):
                u = c / max(1, int((ra - rb).length / 1.6))
                g.log(ra.lerp(rb, u) + Vector((0, 0, 0.12)), ea.lerp(eb, u) + Vector((0, 0, 0.0)), 0.06, 0.055, "pole", 6)
        elif roof == "slate":
            rows = max(4, int((ra - ea).length / 0.42))
            for k in range(rows):
                t = (k + 0.5) / rows
                ncol = int((ra - rb).length / 0.5)
                for c in range(ncol + (k % 2)):
                    u = (c + (0.5 if k % 2 else 0.0)) / ncol
                    if u > 1.0:
                        continue
                    p = ra.lerp(rb, u).lerp(ea.lerp(eb, u), t)
                    nrm = (rb - ra).cross(ea - ra).normalized()
                    if nrm.z < 0:
                        nrm = -nrm
                    p += nrm * (0.1 + 0.05 * (rows - k) / rows)
                    yaw = 0.0
                    g.stone(p, (0.62, 0.48, 0.12), yaw + rng.uniform(-0.2, 0.2), "stone", 1, 0.15, 0.25)
            g.quad(ea, eb, rb, ra, "thatch_dark")
    # gable triangles above the eaves at the back are filled by the stake wall; front gable above the door too.
    if roof != "slate" and not ruin:  # ridge bundle
        pts = [Vector((0, ye0 - 0.1 + (ye1 - ye0 + 0.2) * i / 12, ridge_z + 0.18)) for i in range(13)]
        g.tube(pts, [0.24] * 13, roof if roof in ("thatch",) else ("thatch_dark" if roof == "thatch_hides" else "hide"),
               10, True, True, u_rep=3, v_scale=0.8, wobble=0.08)
        for i in range(1, 12, 2):
            g.lashing(pts[i], (0, 1, 0), 0.24, 2)
    if stakes_around:
        stakes_ring(g, (0, 0, 0), max(hx, hy) + 1.6, int(2 * math.pi * (max(hx, hy) + 1.6) / 1.1), 1.0,
                    gap=(-math.pi / 2, 0.45))
    if porch:  # dyed cloth awning on two poles in front of the door
        y0, y1 = -hy - 0.1, -hy - 2.2
        z0, z1 = door_h + 0.75, door_h - 0.3
        for s in (-1, 1):
            g.log((s * 1.3, y1, -0.4), (s * 1.3, y1, z1 + 0.15), 0.08, 0.07, "pole", 7)
            g.lashing((s * 1.3, y1, z1), (0, 0, 1), 0.08)
        g.log((-1.5, y1, z1 + 0.05), (1.5, y1, z1 + 0.07), 0.065, 0.06, "pole", 6)
        g.sheet([(-1.55, y0, z0), (1.55, y0, z0), (1.6, y1 - 0.15, z1 - 0.05), (-1.6, y1 - 0.15, z1 - 0.05)],
                "dye_" + style, 6, 4, 0.22, 0.03, 0.2)
    # banner on the front gable above the door
    if not ruin:
        g.banner((0, -hy - 0.38, door_h + 0.15 + (ridge_z - door_h) * 0.55), min(1.2, W * 0.16) * 1.35,
                 min(1.7, (ridge_z - door_h) * 0.6), style)
    # firewood + stones around the base
    for i in range(3 if not ruin else 0):
        y = -hy + 0.8 + i * 0.22
        g.log((hx + 0.55, y, 0.12 + 0.2 * (i % 2)), (hx + 0.6, y + 1.4, 0.12 + 0.2 * (i % 2)), 0.1, 0.1, "log", 7)


def dome_house(g, style, R, H, base_h=0.9, cover="fur", ribs="tusk", door=1.2, squash=(1.0, 1.0), rows=6, ruin=False):
    """Round (or elliptic) dome: stone footing, covering courses, tusk or pole ribs, a framed door at -Y."""
    rng = g.rng
    rx, ry = R * squash[0], R * squash[1]
    # footing ring of stones
    segs = int(2 * math.pi * R / 0.5)
    for k in range(2 if base_h > 0.5 else 1):
        for s in range(segs):
            a = 2 * math.pi * (s + 0.5 * k) / segs
            if abs(math.atan2(math.sin(a + math.pi / 2), math.cos(a + math.pi / 2))) < (door / 2 + 0.2) / R:
                continue
            p = Vector((math.cos(a) * (rx + 0.08), math.sin(a) * (ry + 0.08), -0.15 + k * base_h * 0.5 + base_h * 0.22))
            g.stone(p, (0.55, 0.5, base_h * 0.6 + 0.1), a + math.pi / 2, "stone", 2, 0.16)
    z0 = base_h * 0.75
    thatch_cone(g, (0, 0, 0), R, z0, H, rows, cover, thick=0.16, fringe=0.2, squash=squash, dome=0.85,
                under="fur_dark" if cover.startswith("fur") else "thatch_dark")
    # hides draped over the top
    if style in ("north", "stone") and not ruin:
        for i in range(3):
            a = rng.uniform(0, 6.28) if i else math.pi / 2
            p0 = Vector((math.cos(a) * rx * 0.25, math.sin(a) * ry * 0.25, H + 0.08))
            p1 = Vector((math.cos(a) * rx * 0.85, math.sin(a) * ry * 0.85, z0 + (H - z0) * 0.45 + 0.15))
            side = Vector((-math.sin(a), math.cos(a), 0)) * (0.7 if i else 0.85)
            g.sheet([p0 - side, p0 + side, p1 + side * 1.2, p1 - side * 1.2], "dye_" + style if i == 0 else "hide",
                    4, 4, -0.08, 0.02, 0.1)
    # ribs over the dome
    n_ribs = 8 if R < 3 else 12
    for i in range(n_ribs):
        a = 2 * math.pi * (i + 0.5) / n_ribs
        if abs(math.atan2(math.sin(a + math.pi / 2), math.cos(a + math.pi / 2))) < 0.35:
            continue
        out = Vector((math.cos(a), math.sin(a), 0))
        foot = Vector((out.x * (rx + 0.25), out.y * (ry + 0.25), -0.3))
        if ribs == "tusk":
            top = Vector((out.x * rx * 0.55, out.y * ry * 0.55, H * 0.92 + 0.35))
            tusk(g, foot, top, out, 0.13 if R > 3 else 0.1, 0.4)
        else:
            pts = []
            for j in range(7):
                t = j / 6
                ang = t * math.pi / 2 * 0.92
                pts.append(Vector((out.x * (rx + 0.2) * math.cos(ang), out.y * (ry + 0.2) * math.cos(ang),
                                   z0 + (H + 0.25 - z0) * math.sin(ang))))
            pts[0].z = -0.3
            g.tube(pts, [0.07] * 6 + [0.05], "pole", 6)
    # smoke hole poles at the top
    for i in range(5):
        a = 2 * math.pi * i / 5 + 0.3
        g.log((math.cos(a) * 0.25, math.sin(a) * 0.25, H - 0.3), (math.cos(a) * 0.55, math.sin(a) * 0.55, H + 0.9),
              0.045, 0.035, "pole", 5, sharp=0.15)
    # door: a short entrance porch with two posts (tusk arch in the north), dark opening, hide flap
    y = -ry - 0.2
    dh = min(1.9, H * 0.62)
    g.quad((-door / 2, -ry + 0.6, 0), (door / 2, -ry + 0.6, 0), (door / 2, -ry + 0.6, dh), (-door / 2, -ry + 0.6, dh), "shadow")
    if ribs == "tusk":
        for s in (-1, 1):
            tusk(g, (s * (door / 2 + 0.25), y - 0.2, -0.3), (s * 0.05, y - 0.35, dh + 0.55), (s, 0, 0.3), 0.12, 0.6)
    else:
        for s in (-1, 1):
            g.log((s * (door / 2 + 0.1), y, -0.4), (s * (door / 2 + 0.05), y, dh + 0.2), 0.1, 0.09, "log", 7)
        g.log((-door / 2 - 0.35, y - 0.05, dh + 0.05), (door / 2 + 0.35, y - 0.05, dh + 0.08), 0.09, 0.085, "log", 7)
    # porch roof from the door frame into the dome
    thatch_plane(g, (door / 2 + 0.5, -ry + 0.4, dh + 0.55), (-door / 2 - 0.5, -ry + 0.4, dh + 0.55),
                 (door / 2 + 0.5, y - 0.6, dh + 0.05), (-door / 2 - 0.5, y - 0.6, dh + 0.05), 2, cover,
                 under="fur_dark" if cover.startswith("fur") else "thatch_dark")
    for s in (-1, 1):
        g.quad((s * (door / 2 + 0.05), y, 0), (s * (door / 2 + 0.05), -ry + 0.5, 0),
               (s * (door / 2 + 0.05), -ry + 0.5, dh + 0.5), (s * (door / 2 + 0.05), y, dh), cover)
    if not ruin:
        g.sheet([(-door / 2 + 0.05, y - 0.08, 0.0), (0.0, y - 0.08, 0.05), (0.0, y - 0.08, dh), (-door / 2 + 0.05, y - 0.08, dh)],
                "hide" if style != "north" else "fur", 3, 4, 0.04, 0.02)
        g.banner((door / 2 + 0.55, y - 0.4, dh + 0.25), 0.75, 1.1, style, 0.0)
        g.log((door / 2 + 0.55, y - 0.38, -0.4), (door / 2 + 0.55, y - 0.38, dh + 0.55), 0.06, 0.05, "pole", 6)
    if style == "north" and not ruin:
        skull_deer(g, (0, y - 0.45, dh + 0.5), 0.0, 0.8)
    if style == "stone" and not ruin:
        skull_bull(g, (0, y - 0.4, dh + 0.55), 0.0, 0.85)


def a_frame(g, style, W, L, H, wall_h=0.0, door_w=1.3):
    """Hide-covered A-frame (red clan): crossed rafters, stitched hide panels, open front with flaps."""
    rng = g.rng
    hx, hy = W / 2, L / 2
    ez = wall_h
    if wall_h > 0.2:
        for x in (-hx, hx):
            for j in range(int(wall_h / 0.26) + 1):
                z = 0.13 + j * 0.26
                g.log((x, -hy - 0.2, z), (x, hy + 0.2, z), 0.13, 0.12, "log", 8)
            for y in (-hy, hy):
                g.log((x, y, -0.5), (x, y, wall_h + 0.4), 0.15, 0.14, "log", 8, sharp=0.25)
    nr = max(3, int(L / 1.4) + 1)
    for i in range(nr):
        y = -hy + L * i / (nr - 1)
        for s in (-1, 1):
            foot = Vector((s * (hx + 0.35), y, ez - 0.4 if wall_h else -0.45))
            peak = Vector((0, y, H))
            dirv = (peak - foot).normalized()
            ext = 1.1 if i in (0, nr - 1) else 0.35
            g.log(foot, peak + dirv * ext, 0.1, 0.07, "log", 7, sharp=0.25)
        g.lashing((0, y, H), (0, 1, 0), 0.12)
    g.log((0, -hy - 0.4, H + 0.05), (0, hy + 0.4, H + 0.06), 0.1, 0.1, "log", 8)
    for s in (-1, 1):
        for i in range(nr - 1):
            y0 = -hy + L * i / (nr - 1)
            y1 = -hy + L * (i + 1) / (nr - 1)
            rows = 3
            for k in range(rows):
                t0, t1 = k / rows - 0.03, (k + 1) / rows
                P = lambda yy, t: Vector((s * (hx + 0.35) * t, yy, H + (ez - H) * t)) + Vector((s * 0.08, 0, 0.04))
                r = rng.random()
                key = "dye_" + style if r < 0.6 else ("dye_dark_" + style if r < 0.85 else "hide")
                c = [P(y0 - 0.05, t0), P(y1 + 0.05, t0), P(y1 + 0.05, t1), P(y0 - 0.05, t1)]
                if s > 0:
                    c = [c[1], c[0], c[3], c[2]]
                g.sheet(c, key, 4, 3, rng.uniform(0.05, 0.12), 0.012, 0.16 if k == rows - 1 else 0.03)
    # back gable closed, front gable: hide flaps tied open beside a dark door
    for y, front in ((hy + 0.05, False), (-hy - 0.05, True)):
        pts = [Vector((-(hx + 0.3), y, ez - 0.1)), Vector((hx + 0.3, y, ez - 0.1)), Vector((0, y, H - 0.1))]
        if not front:
            g.sheet([pts[0], pts[1], pts[2] + Vector((0.01, 0, 0)), pts[2]], "dye_" + style, 6, 6, 0.08, 0.01)
            continue
        for s in (-1, 1):
            base_out = Vector((s * (hx + 0.3), y, ez - 0.1))
            base_in = Vector((s * door_w / 2, y - 0.25, ez - 0.1 if ez > 0 else 0.0))
            top = Vector((0, y, H - 0.1))
            g.sheet([base_out, base_in, top + Vector((s * 0.02, 0, 0)), top], "dye_" + style if s > 0 else "hide",
                    4, 6, 0.06, 0.02)
        g.quad((-door_w / 2, -hy + 1.2, 0), (door_w / 2, -hy + 1.2, 0), (0.05, -hy + 1.2, H * 0.8),
               (-0.05, -hy + 1.2, H * 0.8), "shadow")
    g.banner((0, -hy - 0.5, H * 0.72), min(1.3, W * 0.2), min(1.8, H * 0.38), style)
    if wall_h:
        stakes_ring(g, (0, 0, 0), max(hx, hy) + 1.4, int(2 * math.pi * (max(hx, hy) + 1.4) / 1.3), 0.9,
                    gap=(-math.pi / 2, 0.45))


def canopy(g, style, W, L, H, roof="thatch", tusks=False):
    """Open-sided work shelter: posts, a pitched roof, a bench and a hide drying on a rail."""
    hx, hy = W / 2, L / 2
    eave = H - 0.9
    posts = [(-hx, -hy), (hx, -hy), (-hx, hy), (hx, hy), (-hx, 0), (hx, 0)]
    for x, y in posts:
        if tusks:
            tusk(g, (x * 1.05, y, -0.3), (x * 0.25, y, H + 0.2), (1 if x > 0 else -1, 0, 0), 0.11, 0.35)
        g.log((x, y, -0.5), (x, y, eave + 0.05), 0.11, 0.1, "log", 8)
        g.lashing((x, y, eave - 0.05), (0, 0, 1), 0.1)
    for x in (-hx, hx):
        g.log((x, -hy - 0.4, eave), (x, hy + 0.4, eave + 0.02), 0.09, 0.085, "log", 8)
    for y in (-hy, 0, hy):
        for s in (-1, 1):
            g.log((s * (hx + 0.5), y, eave - 0.25), (0, y, H), 0.08, 0.07, "log", 7)
    g.log((0, -hy - 0.5, H), (0, hy + 0.5, H + 0.02), 0.09, 0.09, "log", 7)
    for s in (-1, 1):
        ra, rb = Vector((0, -hy - 0.6, H)), Vector((0, hy + 0.6, H))
        ea, eb = Vector((s * (hx + 0.6), -hy - 0.6, eave - 0.3)), Vector((s * (hx + 0.6), hy + 0.6, eave - 0.3))
        if s > 0:
            ra, rb, ea, eb = rb, ra, eb, ea
        if roof == "thatch":
            thatch_plane(g, ra, rb, ea, eb, 4)
        else:
            for c in range(3):
                u0, u1 = c / 3 - 0.02, (c + 1) / 3 + 0.02
                P = lambda u, t: ra.lerp(rb, u).lerp(ea.lerp(eb, u), t) + Vector((0, 0, 0.08))
                g.sheet([P(u0, 0), P(u1, 0), P(u1, 1), P(u0, 1)],
                        "dye_" + style if c != 1 else ("fur" if style == "north" else "hide"), 4, 4, 0.12, 0.01, 0.14)
    # dyed cloth strips hanging from a tie beam between the front posts
    g.log((-hx - 0.2, -hy - 0.13, eave - 0.35), (hx + 0.2, -hy - 0.13, eave - 0.33), 0.07, 0.065, "log", 7)
    for i in range(3):
        y = -hy - 0.2
        x = -hx + 0.7 + i * (W - 1.4) / 2
        if i == 2:
            continue
        g.sheet([(x - 0.45, y, eave - 1.15), (x + 0.45, y, eave - 1.15), (x + 0.45, y, eave - 0.38), (x - 0.45, y, eave - 0.38)],
                "dye_" + style, 3, 4, 0.0, 0.03)
    # workbench: a split log on two stumps; a stretched hide on a rack
    for y in (-0.9, 0.9):
        g.log((0.6, y, -0.2), (0.6, y, 0.45), 0.2, 0.19, "log", 9)
    g.stone((0.6, 0, 0.52), (0.45, 2.3, 0.14), math.pi / 2 * 0 + 0.0, "pole_old", 1, 0.05, 0.0)
    for y in (-hy + 0.6, hy - 0.6):
        g.log((-hx + 0.7, y, -0.3), (-hx + 0.7, y, 1.7), 0.05, 0.045, "pole", 6)
    g.log((-hx + 0.7, -hy + 0.4, 1.6), (-hx + 0.7, hy - 0.4, 1.62), 0.045, 0.04, "pole", 6)
    g.sheet([(-hx + 0.72, -hy + 0.9, 1.55), (-hx + 0.72, hy - 0.9, 1.55), (-hx + 0.8, hy - 1.0, 0.35),
             (-hx + 0.8, -hy + 1.0, 0.35)], "hide", 4, 4, 0.05, 0.02, 0.08)
    g.banner((hx - 0.55, -hy - 0.25, eave - 0.4), 0.75, 1.05, style, 0.0, bar=False)


SOURCE = os.path.join(ROOT, "tools", "blender", "source")  # tools/blender/prepare_tripo.py writes these
TOWER_SRC = os.path.join(SOURCE, "SK_Tower_Tripo.glb")
HUT_SRC = os.path.join(SOURCE, "SK_HideHut_Tripo.glb")
TOWER_HEIGHT = 11.0
TOWER_SINK = 0.35
HUT_WIDTH = 5.4
HUT_SINK = 0.25
_TRIPO_CACHE = {}
EXTRA_META = {}  # model name -> extra buildings.json fields (e.g. the smoke source)


def _tripo_maps(src, mat_src):
    """Saves a Tripo model's normal and roughness/metal maps once; returns (base pixels, nor path, rm path)."""
    if src not in _TRIPO_CACHE:
        tag = os.path.splitext(os.path.basename(src))[0].replace("SK_", "").replace("_Tripo", "")
        imgs = {}
        for n in mat_src.node_tree.nodes:
            if n.type == "TEX_IMAGE" and n.image:
                nm = n.image.name.lower()
                imgs["base" if "base" in nm else ("nor" if "normal" in nm else "rm")] = n.image
        def px(img):
            a = np.empty(img.size[0] * img.size[1] * 4, np.float32)
            img.pixels.foreach_get(a)
            return a.reshape(img.size[1], img.size[0], 4)
        _TRIPO_CACHE[src] = (px(imgs["base"]), _save(px(imgs["nor"]), f"T_Bld_{tag}Tripo_nor"),
                            _save(px(imgs["rm"]), f"T_Bld_{tag}Tripo_rm"), tag)
    return _TRIPO_CACHE[src]


def tripo_model(g, style, src, size, by_height, sink, banner_rect=None, redye=False):
    """Imports a prepared Tripo model, centres it on the ground and scales it (to `size` metres tall, or wide).
    `redye` re-dyes its red hides in the clan colour; `banner_rect` (x, z_top, width, height on the unit model)
    hangs the clan banner over the model's own banner. Returns (object, scale, offset): v_game = (v_raw - offset) * scale."""
    bpy.ops.import_scene.gltf(filepath=src)
    obj = next(o for o in bpy.context.selected_objects if o.type == "MESH")
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    me = obj.data
    xs = [v.co.x for v in me.vertices]; ys = [v.co.y for v in me.vertices]; zs = [v.co.z for v in me.vertices]
    k = size / ((max(zs) - min(zs)) if by_height else (max(xs) - min(xs)))
    off = Vector(((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2, min(zs)))
    for v in me.vertices:
        v.co = (v.co - off) * k - Vector((0, 0, sink))
    me.update()
    base, nor, rm, tag = _tripo_maps(src, me.materials[0])
    diff = base.copy()
    if redye and style != "stone":
        r, gg, b = diff[..., 0], diff[..., 1], diff[..., 2]
        red = np.clip(((r - np.maximum(gg, b)) / np.maximum(r, 1e-3) - 0.3) * 3.5, 0, 1)[..., None]
        # Re-dye keeping the hide's shading: the target colour at the hides' average brightness.
        roof = np.array({"player": (0.8, 0.6, 0.24), "north": (0.5, 0.45, 0.38), "red": (0.72, 0.24, 0.1)}[style],
                        np.float32)
        l = _lum(diff)
        lred = max(1e-3, float(l[red[..., 0] > 0.5].mean()))
        tint = np.clip(roof[None, None, :] * (l / lred)[..., None], 0, 1)
        diff[..., :3] = diff[..., :3] * (1 - red) + tint * red
    dpath = _save(diff, f"T_Bld_{tag}Tripo_{style}_diff")
    m = bpy.data.materials.new(f"M_Bld_{tag}Tripo{style.title()}")
    m.use_nodes = True
    nt = m.node_tree; bsdf = nt.nodes["Principled BSDF"]
    d = nt.nodes.new("ShaderNodeTexImage"); d.image = bpy.data.images.load(dpath, check_existing=True)
    nt.links.new(d.outputs["Color"], bsdf.inputs["Base Color"])
    n = nt.nodes.new("ShaderNodeTexImage"); n.image = bpy.data.images.load(nor, check_existing=True)
    n.image.colorspace_settings.name = "Non-Color"
    nm = nt.nodes.new("ShaderNodeNormalMap")
    nt.links.new(n.outputs["Color"], nm.inputs["Color"]); nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    a = nt.nodes.new("ShaderNodeTexImage"); a.image = bpy.data.images.load(rm, check_existing=True)
    a.image.colorspace_settings.name = "Non-Color"
    sep = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(a.outputs["Color"], sep.inputs["Color"])
    nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"]); nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
    me.materials.clear(); me.materials.append(m)
    if banner_rect:  # find the model's own banner on the front (-Y) face and cover it
        bx, bz, bw, bh = banner_rect
        hit, loc, _n, _i = obj.ray_cast(Vector((bx * k, -50, (bz - bh * 0.4) * k - sink)), Vector((0, 1, 0)))
        front_y = loc.y if hit else -size * 0.5
        g.banner((bx * k, front_y - 0.06 * max(1.0, k / 6), bz * k - sink), bw * k, bh * k, style, 0.0, 0.0, bar=False)
    return obj, k, off


def tripo_tower(g, style):
    """The user's Tripo lookout tower (stone base, hide roof, horns), 11 m tall, hides re-dyed per clan, the clan's
    banner over its bull-skull one (kept for the stone tribe, whose emblem it is)."""
    obj, _k, _off = tripo_model(g, style, TOWER_SRC, TOWER_HEIGHT, True, TOWER_SINK,
                          None if style == "stone" else (-0.068, 0.585, 0.17, 0.33), redye=True)
    return obj


def tripo_hut(g, style):
    """The user's Tripo hide-and-pole dome hut (the hand clan). Its sculpted smoke was cut off by prepare_tripo.py;
    the game draws real smoke from the smoke hole, recorded here as "smoke" (Godot model space, metres)."""
    obj, k, off = tripo_model(g, style, HUT_SRC, HUT_WIDTH, False, HUT_SINK, (-0.328, 0.245, 0.095, 0.2))
    info = json.load(open(os.path.splitext(HUT_SRC)[0] + ".json"))
    # The smoke source is in the raw frame: map it like the vertices, then Blender Z-up -> Godot Y-up.
    p = (Vector(info["smoke"]) - off) * k
    EXTRA_META[f"{style.title()}_Hut"] = {"smoke": [round(p.x, 3), round(p.z - HUT_SINK + 0.15, 3), round(-p.y, 3)]}
    return obj


def fence(g, style, length=4.0, variant=0):
    """One wall segment along X (centred), the outside facing -Y. Reaches 0.7 m underground."""
    rng = g.rng
    hx = length / 2
    if style == "stone":
        g.stone_course((-hx, 0, 0), (hx, 0, 0), -0.4, 1.3, 0.75, courses=3, wmin=0.45, wmax=0.8)
        for x in (-hx + 0.3, hx - 0.3) if variant else (-hx + 0.3,):
            for k in range(4):
                g.stone((x, 0, -0.1 + k * 0.5), (0.8, 0.85, 0.55), rng.uniform(0, 3), "stone", 2, 0.12)
        n = int(length / 0.22)
        for i in range(n):
            x = -hx + length * (i + 0.5) / n
            if abs(x - (-hx + 0.3)) < 0.5:
                continue
            g.log((x, 0.1, 0.7), (x + rng.uniform(-0.03, 0.03), 0.1 + rng.uniform(-0.05, 0.05), 2.1 + rng.uniform(-0.2, 0.2)),
                  0.06, 0.05, "pole", 6, sharp=0.2)
        g.log((-hx, 0.18, 1.7), (hx, 0.18, 1.72), 0.05, 0.05, "pole", 6)
        if variant:
            g.banner((0, -0.15, 2.1), 0.8, 1.15, style, 0.0)
        return
    n = int(length / (0.2 if style != "north" else 0.26))
    h = 2.7 if style in ("player", "red") else 2.3
    for i in range(n):
        x = -hx + length * (i + 0.5) / n
        r = rng.uniform(0.085, 0.11) if style != "north" else rng.uniform(0.07, 0.09)
        top = h + rng.uniform(-0.3, 0.3)
        g.log((x, rng.uniform(-0.03, 0.03), -0.7), (x + rng.uniform(-0.04, 0.04), rng.uniform(-0.04, 0.04), top),
              r, r * 0.9, "log" if style != "north" else "pole", 6, sharp=0.32, n=3)
    for z in (0.7, 1.75):  # rails on the inside, lashed
        g.log((-hx - 0.1, 0.17, z), (hx + 0.1, 0.17, z + rng.uniform(-0.05, 0.05)), 0.065, 0.06, "pole", 7)
        for i in range(2, n, 7):
            x = -hx + length * (i + 0.5) / n
            g.lashing((x, 0.1, z), (0, 0, 1), 0.1, 2)
    for x in (-hx + 0.15,):  # stone packing at the foot
        pass
    for i in range(int(length / 0.6)):
        g.stone((-hx + 0.3 + i * 0.6, -0.15, 0.0), (0.45, 0.3, 0.3), rng.uniform(0, 3), "stone", 1, 0.2)
    if style == "north" and variant:
        for s in (-1, 1):
            tusk(g, (s * 1.3, -0.35, -0.4), (s * 0.1, -0.4, 3.1), (s, 0, 0.2), 0.13, 0.5)
        g.banner((0, -0.45, 2.4), 0.8, 1.1, style, 0.0)
    elif variant:
        g.banner((0, -0.18, 2.25), 0.85, 1.25, style, 0.0)


def gate(g, style, width=6.0):
    rng = g.rng
    hx = width / 2
    if style == "north":
        for s in (-1, 1):
            tusk(g, (s * (hx - 0.1), 0, -0.6), (s * 0.15, 0, 4.4), (s, 0, 0.4), 0.22, 0.55)
            tusk(g, (s * (hx - 0.3), 0.5, -0.6), (s * 0.4, 0.5, 4.0), (s, 0, 0.4), 0.18, 0.5)
        skull_deer(g, (0, -0.2, 3.7), 0.0, 1.3)
        g.banner((0, -0.15, 3.1), 1.0, 1.4, style, 0.0, bar=True)
        for s in (-1, 1):
            for k in range(3):
                g.stone((s * (hx - 0.1), 0.2, -0.1 + k * 0.4), (0.9, 0.9, 0.5), rng.uniform(0, 3), "stone", 2, 0.12)
        return
    for s in (-1, 1):
        x = s * (hx - 0.1)
        if style == "stone":
            for k in range(7):
                g.stone((x, 0, -0.2 + k * 0.55), (1.0 - k * 0.03, 1.0, 0.6), rng.uniform(0, 3), "stone", 2, 0.12)
        else:
            g.log((x, 0, -0.8), (x, 0, 4.6), 0.24, 0.2, "log", 10, sharp=0.4)
            g.log((x + s * 0.55, 0.2, -0.8), (x + s * 0.5, 0.2, 3.7), 0.18, 0.16, "log", 9, sharp=0.35)
            g.lashing((x, 0, 3.75), (0, 0, 1), 0.24)
    z = 3.95 if style != "stone" else 3.75
    g.log((-hx - 0.7, -0.15, z), (hx + 0.7, -0.15, z + 0.04), 0.2, 0.19, "log", 10)
    if style == "red":  # crossed poles over the lintel
        for s in (-1, 1):
            g.log((s * hx * 0.9, -0.2, z - 0.3), (-s * 0.6, -0.2, z + 1.8), 0.09, 0.06, "log", 7, sharp=0.25)
    if style == "stone":
        skull_bull(g, (0, -0.42, z + 0.25), 0.0, 1.6, 1.2)
    if style == "player":
        for s in (-1, 1):
            g.log((s * 0.6, -0.2, z - 0.2), (s * 1.4, -0.2, z + 1.2), 0.07, 0.05, "pole", 6, sharp=0.2)
    g.banner((0, -0.4, z - 0.15), 1.1, 1.55, style, 0.0, bar=False)
    for s in (-1, 1):
        g.banner((s * (hx - 0.1), -0.45, z - 0.8), 0.7, 1.0, style, 0.0, bar=False) if style == "red" else None


def banner_post(g, style):
    g.log((0, 0, -0.6), (0, 0, 4.2), 0.14, 0.1, "log", 9, sharp=0.3 if style in ("player", "red") else 0.0)
    g.log((-0.85, -0.05, 3.55), (0.85, -0.05, 3.6), 0.06, 0.05, "pole", 6)
    g.lashing((0, -0.02, 3.57), (1, 0, 0), 0.12)
    g.banner((0, -0.14, 3.5), 1.4, 1.9, style, 0.0, bar=False)
    if style == "stone":
        skull_bull(g, (0, -0.15, 4.15), 0.0, 0.9)
    elif style == "north":
        skull_deer(g, (0, -0.12, 4.15), 0.0, 0.9)
    elif style == "red":
        for i in range(3):  # wolf tails
            g.tube([Vector((-0.5 + i * 0.5, -0.1, 3.5)), Vector((-0.5 + i * 0.5, -0.12, 3.2)),
                    Vector((-0.48 + i * 0.5, -0.1, 2.9))], [0.06, 0.08, 0.02], "fur_dark", 6)
    for i in range(5):
        a = i * 1.3
        g.stone((math.cos(a) * 0.35, math.sin(a) * 0.35, 0.05), (0.4, 0.35, 0.3), a, "stone", 1, 0.2)


# ================================================================ the catalogue

def catalogue():
    """name -> (builder, footprint [w, l] for collision/placement, shape)."""
    C = {}
    def add(name, fn, fp, shape="rect"):
        C[name] = (fn, fp, shape)
    # Player clan: thatch + timber, yellow hand.
    add("Player_Hall", lambda g: gable_house(g, "player", 8.0, 11.0, 1.7, 7.4, "stakes", "thatch", 1.6, 2.2,
                                             crossed=1.5, stakes_around=True), (8.0, 11.0))
    add("Player_House", lambda g: gable_house(g, "player", 5.0, 6.4, 1.4, 4.9, "stakes", "thatch", 1.2, 1.9,
                                              crossed=1.0, porch=True), (5.0, 6.4))
    add("Player_Hut", lambda g: tripo_hut(g, "player"), (5.4, 5.4), "round")
    add("Player_Canopy", lambda g: canopy(g, "player", 4.4, 5.4, 3.4, "thatch"), (4.4, 5.4), "open")
    add("Player_Ruin", lambda g: gable_house(g, "player", 5.0, 6.4, 1.3, 4.6, "stakes", "thatch", 1.2, 1.9,
                                             crossed=0.9, ruin=True), (5.0, 6.4))
    # Stone tribe: dry-stone walls, menhirs, bull skulls, rust-red hides.
    add("Stone_Hall", lambda g: gable_house(g, "stone", 8.0, 11.5, 2.0, 6.6, "stone", "thatch_hides", 1.6, 2.2,
                                            crossed=1.4), (8.0, 11.5))
    add("Stone_House", lambda g: gable_house(g, "stone", 5.2, 6.6, 1.7, 4.3, "stone", "slate", 1.2, 1.9,
                                             crossed=0.6), (5.2, 6.6))
    add("Stone_Hut", lambda g: dome_house(g, "stone", 2.6, 3.4, 1.4, "thatch", "pole", 1.1), (5.2, 5.2), "round")
    add("Stone_Canopy", lambda g: canopy(g, "stone", 4.4, 5.4, 3.3, "hide"), (4.4, 5.4), "open")
    # North: mammoth tusks, furs, blue deer skull.
    add("North_Hall", lambda g: dome_house(g, "north", 4.2, 5.4, 0.9, "fur", "tusk", 1.5, (0.95, 1.4), 7),
        (8.0, 11.8), "round")
    add("North_House", lambda g: dome_house(g, "north", 3.0, 3.9, 0.8, "fur", "tusk", 1.2, (1.0, 1.15)), (6.0, 6.9), "round")
    add("North_Hut", lambda g: dome_house(g, "north", 2.4, 3.1, 0.6, "fur", "tusk", 1.0), (4.8, 4.8), "round")
    add("North_Canopy", lambda g: canopy(g, "north", 4.4, 5.4, 3.3, "hide", tusks=True), (4.4, 5.4), "open")
    # Red clan: A-frames of red-dyed hides, wolf.
    add("Red_Hall", lambda g: a_frame(g, "red", 8.0, 11.5, 7.6, 1.4, 1.6), (8.0, 11.5))
    add("Red_House", lambda g: a_frame(g, "red", 5.0, 6.6, 4.6, 0.0, 1.2), (5.0, 6.6))
    add("Red_Hut", lambda g: a_frame(g, "red", 4.0, 5.0, 3.8, 0.0, 1.1), (4.0, 5.0))
    add("Red_Canopy", lambda g: canopy(g, "red", 4.4, 5.4, 3.4, "hide"), (4.4, 5.4), "open")
    for st in ("player", "stone", "north", "red"):
        S = st.title()
        add(f"{S}_Tower", lambda g, st=st: tripo_tower(g, st), (5.4, 5.4), "round")
        add(f"{S}_Fence", lambda g, st=st: fence(g, st, 4.0, 0), (4.0, 0.5), "wall")
        add(f"{S}_FenceB", lambda g, st=st: fence(g, st, 4.0, 1), (4.0, 0.5), "wall")
        add(f"{S}_Gate", lambda g, st=st: gate(g, st, 6.0), (6.0, 1.0), "gate")
        add(f"{S}_Banner", lambda g, st=st: banner_post(g, st), (0.5, 0.5), "post")
    return C


def export(obj, name):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    path = os.path.join(OUT, f"SM_Bld_{name}.gltf")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLTF_SEPARATE", export_texture_dir="textures",
                              use_selection=True, export_image_format="AUTO", export_yup=True, export_normals=True)
    g = json.load(open(path))
    for m in g.get("materials", []):
        n = m.get("name", "")
        if "Banner" in n:
            m["alphaMode"] = "MASK"
            m["alphaCutoff"] = 0.5
        if any(k in n for k in ("Banner", "Dye", "Hide", "Fur", "Thatch")):
            m["doubleSided"] = True
    json.dump(g, open(path, "w"), indent=1)
    return path


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    only = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    global TEXTURES
    TEXTURES = prepare_textures()
    TEXTURES["horn"] = TEXTURES["fur_dark"]
    TEXTURES["rope"] = TEXTURES["thatch_dark"]
    cat = catalogue()
    meta_path = os.path.join(OUT, "buildings.json")
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
    for name, (fn, fp, shape) in cat.items():
        if only and not any(name.lower().startswith(o.lower()) or name.lower() == o.lower() for o in only):
            continue
        for o in list(bpy.context.scene.objects):
            bpy.data.objects.remove(o)
        g = Geo(zlib.crc32(name.encode()))
        extra = fn(g)
        obj = g.build("SM_Bld_" + name)
        if extra is not None:  # an imported mesh (the Tripo tower) joins the generated parts
            bpy.ops.object.select_all(action="DESELECT")
            extra.select_set(True)
            if obj.data.polygons:
                obj.select_set(True)
                bpy.context.view_layer.objects.active = obj
                bpy.ops.object.join()
            else:
                bpy.data.objects.remove(obj)
                obj = extra
            obj.name = "SM_Bld_" + name
        tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
        mn = [min(v.co[i] for v in obj.data.vertices) for i in range(3)]
        mx = [max(v.co[i] for v in obj.data.vertices) for i in range(3)]
        export(obj, name)
        meta[name] = {"footprint": list(fp), "shape": shape, "height": round(mx[2], 2), "tris": tris}
        meta[name].update(EXTRA_META.get(name, {}))
        print(f"BUILT {name}: {tris} tris, height {mx[2]:.1f} m, x {mn[0]:.1f}..{mx[0]:.1f}, y {mn[1]:.1f}..{mx[1]:.1f}")
    json.dump(meta, open(meta_path, "w"), indent=1, sort_keys=True)


main()
