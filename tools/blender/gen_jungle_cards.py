# Foliage cards for the southern jungle trees (gen_trees.py "jungle" and "palm"):
#   blender -b --python tools/blender/gen_jungle_cards.py
# Same layout as T_LeavesCard_D (1024×256, four 256×256 cells; each cell's branch starts at its left edge, u runs
# along the twig, v across):
#   T_JungleLeafCard_D.png  four sprays of large, glossy, drip-tipped tropical leaves with pale midribs
#   T_PalmFrondCard_D.png   one pinnate palm frond across the whole width (rachis left → right, leaflets droop)
import bpy, os, math
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEX = os.path.join(ROOT, "assets", "models", "trees", "textures")
W, H = 1024, 256
rng = np.random.default_rng(424242)


def new():
    return np.zeros((H, W, 4), dtype=np.float32)


def stroke(img, pts, w0, w1, c0, c1):
    """Anti-aliased tapered polyline in pixels (x right, y down)."""
    n = len(pts)
    for i in range(n - 1):
        a, b = np.array(pts[i], float), np.array(pts[i + 1], float)
        t0, t1 = i / (n - 1), (i + 1) / (n - 1)
        wa, wb = w0 + (w1 - w0) * t0, w0 + (w1 - w0) * t1
        r = max(wa, wb) + 2
        lo = np.floor(np.minimum(a, b) - r).astype(int)
        hi = np.ceil(np.maximum(a, b) + r).astype(int)
        lo = np.maximum(lo, 0); hi = np.minimum(hi, [W - 1, H - 1])
        if hi[0] <= lo[0] or hi[1] <= lo[1]:
            continue
        ys, xs = np.mgrid[lo[1]:hi[1] + 1, lo[0]:hi[0] + 1]
        p = np.stack([xs, ys], -1).astype(np.float32)
        ab = b - a
        u = np.clip(((p - a) @ ab) / max(ab @ ab, 1e-6), 0, 1)
        d = np.linalg.norm(p - (a + u[..., None] * ab), axis=-1)
        wd = wa + (wb - wa) * u
        cov = np.clip(wd - d + 0.5, 0, 1)
        t = t0 + (t1 - t0) * u
        c = np.array(c0)[None, None, :] * (1 - t[..., None]) + np.array(c1)[None, None, :] * t[..., None]
        reg = img[lo[1]:hi[1] + 1, lo[0]:hi[0] + 1]
        new_ = cov > reg[..., 3] * 0.9
        reg[..., :3] = np.where(new_[..., None], c, reg[..., :3])
        reg[..., 3] = np.maximum(reg[..., 3], cov)


def leaf(img, base, ang, length, width, col):
    """A broad ovate leaf with a drip tip: filled outline, darker edges, a pale midrib and a sheen on one half."""
    d = np.array([math.cos(ang), math.sin(ang)])
    nrm = np.array([-d[1], d[0]])
    lo = np.floor(np.minimum(base, base + d * length) - width - 2).astype(int)
    hi = np.ceil(np.maximum(base, base + d * length) + width + 2).astype(int)
    lo = np.maximum(lo, 0); hi = np.minimum(hi, [W - 1, H - 1])
    if hi[0] <= lo[0] or hi[1] <= lo[1]:
        return
    ys, xs = np.mgrid[lo[1]:hi[1] + 1, lo[0]:hi[0] + 1]
    p = np.stack([xs, ys], -1).astype(np.float32) - base
    t = (p @ d) / length
    s = (p @ nrm)
    half = width * np.sin(np.clip(t, 0, 1) * math.pi) ** 0.8 * (1 - 0.35 * np.clip(t - 0.75, 0, 1) * 4)
    inside = (t > 0) & (t < 1.0) & (np.abs(s) < half)
    edge = np.clip((half - np.abs(s)) / 2.5, 0, 1) * inside
    shade = 0.75 + 0.35 * (s > 0) + 0.15 * t
    rib = np.clip(1 - np.abs(s) / 1.4, 0, 1) * inside
    c = np.array(col)[None, None, :] * shade[..., None]
    c = c * (0.7 + 0.3 * np.clip((half - np.abs(s)) / max(width * 0.3, 1), 0, 1))[..., None]
    c = c * (1 - rib[..., None]) + np.array([0.55, 0.62, 0.35])[None, None, :] * rib[..., None] * 0.9
    reg = img[lo[1]:hi[1] + 1, lo[0]:hi[0] + 1]
    reg[..., :3] = np.where(edge[..., None] > reg[..., 3:4] * 0.5, c, reg[..., :3])
    reg[..., 3] = np.maximum(reg[..., 3], edge)


def save(img, name):
    m = img[..., 3] > 0.3
    mean = img[m][:, :3].mean(0) if m.any() else np.array([0.1, 0.2, 0.05])
    img[..., :3] = np.where(img[..., 3:4] > 0.02, img[..., :3], mean)
    im = bpy.data.images.new(name, W, H, alpha=True)
    im.pixels[:] = np.flipud(img).ravel()
    path = os.path.join(TEX, name + ".png")
    im.filepath_raw = path
    im.file_format = "PNG"
    im.save()
    print("CARD", path)


# ---- jungle leaf sprays
img = new()
GREENS = [(0.10, 0.24, 0.06), (0.13, 0.30, 0.07), (0.08, 0.20, 0.05), (0.16, 0.32, 0.09)]
for cell in range(4):
    x0 = cell * 256
    twig = [(x0 + 4, 128 + rng.normal(0, 6))]
    for k in range(1, 8):
        twig.append((x0 + 4 + k * 32, twig[-1][1] + rng.normal(0, 6)))
    stroke(img, twig, 4.0, 1.5, (0.22, 0.16, 0.08), (0.2, 0.25, 0.08))
    for k in range(int(rng.integers(9, 13))):
        t = rng.uniform(0.1, 0.95)
        bx = x0 + 4 + t * 224
        by = 128 + rng.normal(0, 4)
        ang = rng.choice([-1, 1]) * rng.uniform(0.35, 1.25) + rng.normal(0, 0.15)
        ln = rng.uniform(70, 115) * (1.15 - 0.4 * t)
        leaf(img, np.array([bx, by]), ang, ln, ln * rng.uniform(0.22, 0.3), GREENS[rng.integers(0, 4)])
    leaf(img, np.array([x0 + 200, 128.0]), rng.normal(0, 0.2), 52, 15, GREENS[1])
save(img, "T_JungleLeafCard_D")

# ---- palm frond
img = new()
rach = [(4 + k * 1020 / 24, 120 + 16 * (k / 24) ** 2) for k in range(25)]
stroke(img, rach, 5.0, 1.5, (0.24, 0.22, 0.1), (0.3, 0.34, 0.12))
for k in range(3, 24):
    t = k / 24
    x, y = rach[k]
    ln = 108 * math.sin(math.pi * min(t * 1.08, 1.0)) ** 0.7 + 10
    for side in (-1, 1):
        for j in range(2):
            ang = side * 0.95 + rng.normal(0, 0.06) + 0.12   # leaflets in a drooping V
            col = GREENS[rng.integers(0, 4)]
            xx = x + j * 18
            pts = [(xx, y), (xx + math.cos(ang) * ln * 0.5, y + math.sin(ang) * ln * 0.5 + 4),
                   (xx + math.cos(ang) * ln, y + math.sin(ang) * ln + 14)]
            stroke(img, pts, 6.5, 1.0, np.array(col) * 0.8, np.array(col) * 1.25)
save(img, "T_PalmFrondCard_D")
