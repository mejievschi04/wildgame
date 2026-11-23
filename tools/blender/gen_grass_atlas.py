# Grass card atlas for MeadowGrass: 4 columns (512 x 1024 each, roots at the bottom), RGBA with soft-edged blades.
#   blender -b --python tools/blender/gen_grass_atlas.py
# 0 lush meadow clump · 1 tall grass with seed heads · 2 dry, yellowed clump · 3 flowering clump (purple, white,
# yellow heads among the grass) · 4 reeds and cattails for the river banks.
# Output: assets/textures/vegetation/T_GrassCards_D.png
# Forest floor atlas (same layout): 0 fern · 1 sedge · 2 bilberry · 3 spruce sapling → T_ForestCards_D.png
import bpy, os, math
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "textures", "vegetation")
W, H = 2560, 1024   # 5 columns of 512
CW = 512
rng = np.random.default_rng(20261123)
img = np.zeros((H, W, 4), dtype=np.float32)


def srgb(c):
    return np.array(c, dtype=np.float32)


def stroke(pts, w0, w1, c0, c1, col):
    """Anti-aliased tapered polyline (pts in pixels, y down), colour c0 at the root → c1 at the tip."""
    n = len(pts)
    x0 = col * CW
    for i in range(n - 1):
        a, b = np.array(pts[i]), np.array(pts[i + 1])
        t0, t1 = i / (n - 1), (i + 1) / (n - 1)
        wa, wb = w0 + (w1 - w0) * t0, w0 + (w1 - w0) * t1
        r = max(wa, wb) + 2
        lo = np.floor(np.minimum(a, b) - r).astype(int)
        hi = np.ceil(np.maximum(a, b) + r).astype(int)
        lo[0] = max(lo[0], x0); hi[0] = min(hi[0], x0 + CW - 1)
        lo[1] = max(lo[1], 0); hi[1] = min(hi[1], H - 1)
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
        c = c0[None, None, :] * (1 - t[..., None]) + c1[None, None, :] * t[..., None]
        # thin bright midrib along the blade
        c = c * (1.0 + 0.18 * np.clip(1 - d / np.maximum(wd * 0.35, 0.5), 0, 1))[..., None]
        reg = img[lo[1]:hi[1] + 1, lo[0]:hi[0] + 1]
        old = reg[..., 3]
        new = cov > old * 0.85
        reg[..., :3] = np.where(new[..., None], c, reg[..., :3])
        reg[..., 3] = np.maximum(old, cov)


def blade(col, base_x, height, lean, width, c0, c1, curl=0.0):
    pts = []
    segs = 9
    for i in range(segs + 1):
        t = i / segs
        x = base_x + lean * height * (t ** 1.7) + curl * math.sin(t * 2.5) * 12
        y = H - 2 - height * (t - 0.12 * lean * lean * t * t)
        pts.append((x, y))
    stroke(pts, width, 0.6, c0, c1, col)
    return pts[-1]


def clump(col, n, hmin, hmax, palette, spread=0.36, lean_max=0.55):
    cx = col * CW + CW / 2
    for _ in range(n):
        bx = cx + np.clip(rng.normal(0, CW * 0.17), -CW * 0.4, CW * 0.4)
        h = rng.uniform(hmin, hmax) * H
        lean = np.clip(rng.normal(0, spread), -lean_max, lean_max)
        base = palette[rng.integers(0, len(palette))] * rng.uniform(0.8, 1.15)
        tip = base * np.array([1.25, 1.18, 0.85]) * rng.uniform(0.9, 1.15)
        h *= 1.0 - 0.45 * abs(bx - cx) / (CW * 0.4)        # shorter toward the clump's edges: a rounded tuft
        blade(col, bx, h, lean, rng.uniform(3.5, 6.5), base * 0.45, np.clip(tip, 0, 1))


def seed_head(col, x, y, c, size):
    for _ in range(int(size * 1.6)):
        ang = rng.uniform(-0.6, 0.6) - math.pi / 2
        ln = rng.uniform(0.3, 1.0) * size
        b = (x + math.cos(ang) * ln * 0.5, y + rng.uniform(0, size * 1.2))
        e = (b[0] + math.cos(ang) * ln * 0.4, b[1] + math.sin(ang) * ln * 0.6)
        stroke([b, e], 1.4, 0.6, c * 0.8, c, col)


def flower(col, x, y, petal, r):
    for k in range(7):
        a = k / 7 * math.tau + rng.uniform(0, 0.4)
        e = (x + math.cos(a) * r, y + math.sin(a) * r * 0.7)
        stroke([(x, y), e], r * 0.45, r * 0.25, petal * 0.85, petal, col)
    stroke([(x - 1, y), (x + 1, y)], r * 0.35, r * 0.35, srgb((0.55, 0.45, 0.1)), srgb((0.75, 0.6, 0.15)), col)


GREEN = [srgb(c) for c in [(0.28, 0.36, 0.14), (0.33, 0.40, 0.17), (0.23, 0.31, 0.12), (0.38, 0.42, 0.20)]]
DRY = [srgb(c) for c in [(0.50, 0.45, 0.25), (0.43, 0.40, 0.21), (0.55, 0.50, 0.30), (0.36, 0.38, 0.18)]]

# 0: lush meadow clump
clump(0, 260, 0.3, 0.75, GREEN)
# 1: tall grass with seed heads
clump(1, 200, 0.3, 0.65, GREEN)
for _ in range(16):
    bx = CW * 1.5 + rng.normal(0, CW * 0.08)
    tip = blade(1, bx, rng.uniform(0.75, 0.97) * H, np.clip(rng.normal(0, 0.18), -0.35, 0.35), 3.0,
                srgb((0.2, 0.3, 0.08)), srgb((0.55, 0.52, 0.25)))
    seed_head(1, tip[0], tip[1], srgb((0.48, 0.43, 0.27)), rng.uniform(16, 26))
# 2: dry clump
clump(2, 240, 0.3, 0.7, DRY + GREEN[:1])
# 3: flowering clump
clump(3, 200, 0.25, 0.6, GREEN)
COLS = [srgb(c) for c in [(0.50, 0.28, 0.70), (0.58, 0.36, 0.78), (0.92, 0.92, 0.86), (0.95, 0.80, 0.18)]]
for _ in range(14):
    bx = CW * 3.5 + rng.normal(0, CW * 0.12)
    tip = blade(3, bx, rng.uniform(0.5, 0.9) * H, np.clip(rng.normal(0, 0.2), -0.4, 0.4), 2.6,
                srgb((0.16, 0.28, 0.07)), srgb((0.24, 0.38, 0.1)))
    c = COLS[rng.integers(0, len(COLS))]
    if c[2] > 0.6 and c[0] < 0.7:   # purple: a spike of small florets (sage / knapweed)
        for k in range(6):
            flower(3, tip[0] + rng.normal(0, 3), tip[1] + k * 11, c * rng.uniform(0.85, 1.1), 7)
    else:
        flower(3, tip[0], tip[1], c, rng.uniform(12, 18))

def save(name):
    # fill transparent texels with the column's mean colour (no dark fringes on mips)
    for c in range(W // CW):
        reg = img[:, c * CW:(c + 1) * CW]
        m = reg[..., 3] > 0.3
        mean = reg[m][:, :3].mean(0) if m.any() else np.array([0.2, 0.3, 0.1])
        reg[..., :3] = np.where(reg[..., 3:4] > 0.02, reg[..., :3], mean)
    os.makedirs(OUT, exist_ok=True)
    im = bpy.data.images.new(name, W, H, alpha=True)
    im.colorspace_settings.name = "sRGB"
    im.pixels[:] = np.flipud(img).ravel()
    path = os.path.join(OUT, name + ".png")
    im.filepath_raw = path
    im.file_format = "PNG"
    im.save()
    print("ATLAS", path)


# 4: reeds and cattails — tall straight stems and long leaves, brown cattail heads
REED = [srgb(c) for c in [(0.30, 0.38, 0.14), (0.36, 0.42, 0.17), (0.25, 0.33, 0.11)]]
for _ in range(70):
    bx = CW * 4.5 + np.clip(rng.normal(0, CW * 0.16), -CW * 0.42, CW * 0.42)
    lean = np.clip(rng.normal(0, 0.12), -0.3, 0.3)
    blade(4, bx, rng.uniform(0.55, 0.98) * H, lean, rng.uniform(4.0, 7.0), REED[rng.integers(0, 3)] * 0.5,
          np.clip(REED[rng.integers(0, 3)] * 1.25, 0, 1))
for _ in range(4):
    bx = CW * 4.5 + rng.normal(0, CW * 0.13)
    hgt = rng.uniform(0.75, 0.97) * H
    tip = blade(4, bx, hgt, rng.normal(0, 0.05), 3.0, srgb((0.24, 0.3, 0.1)), srgb((0.32, 0.38, 0.14)))
    stroke([(bx + (tip[0] - bx) * 0.82, H - 2 - hgt * 0.8), (bx + (tip[0] - bx) * 0.93, H - 2 - hgt * 0.92)], 9, 9,
           srgb((0.17, 0.12, 0.07)), srgb((0.23, 0.16, 0.09)), 4)
save("T_GrassCards_D")

# ------------------------------------------------------------------ forest floor
img[:] = 0.0
FERN = [srgb(c) for c in [(0.16, 0.30, 0.07), (0.20, 0.34, 0.08), (0.13, 0.26, 0.06)]]
DARK = [srgb(c) for c in [(0.13, 0.22, 0.07), (0.17, 0.26, 0.09), (0.11, 0.18, 0.06)]]


def frond(col, x0, height, side, c):
    """A fern frond seen from the side: rises, arches outward and droops at the tip; broad leaflets in pairs."""
    pts = []
    n = 28
    reach = CW * 0.42 * abs(side)
    sg = 1 if side >= 0 else -1
    for i in range(n + 1):
        t = i / n
        pts.append((x0 + sg * reach * t ** 1.3, H - 2 - height * (math.sin(t * math.pi * 0.62) / math.sin(math.pi * 0.62)) * (1 - 0.25 * t * t)))
    stroke(pts, 3.0, 1.2, c * 0.6, c * 0.9, col)
    for i in range(2, n):
        t = i / n
        ax, ay = pts[i]
        bx_, by_ = pts[i - 1]
        dx, dy = ax - bx_, ay - by_
        ln = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / ln, dx / ln
        leaf = height * 0.12 * math.sin(math.pi * min(t * 1.1, 1.0)) + 4
        for s_ in (1, -1):
            e = (ax + nx * leaf * s_ + dx / ln * leaf * 0.45, ay + ny * leaf * s_ + dy / ln * leaf * 0.45)
            e = (min(max(e[0], col * CW + 3), (col + 1) * CW - 3), e[1])
            stroke([(ax, ay), e], 7.0 * (1 - t * 0.5), 2.0, c * 0.8, np.clip(c * 1.25, 0, 1), col)


cx = CW * 0.5
for k in range(14):
    side = (1 if k % 2 else -1) * rng.uniform(0.25, 1.0)
    frond(0, cx + rng.normal(0, 8), rng.uniform(0.35, 0.8) * H, side, FERN[rng.integers(0, 3)] * rng.uniform(0.85, 1.15))
clump(1, 230, 0.35, 0.85, DARK, spread=0.5, lean_max=0.8)
# bilberry: woody stems with small oval leaves and a few dark berries
for k in range(26):
    bx = CW * 2.5 + rng.normal(0, CW * 0.16)
    hgt = rng.uniform(0.35, 0.8) * H
    lean = rng.normal(0, 0.25)
    pts = [(bx + lean * hgt * (i / 10) ** 1.5, H - 2 - hgt * i / 10) for i in range(11)]
    stroke(pts, 2.5, 1.2, srgb((0.2, 0.25, 0.1)), srgb((0.26, 0.36, 0.12)), 2)
    for i in range(2, 11):
        x, y = pts[i]
        for sgn in (1, -1):
            if rng.random() < 0.75:
                a = rng.uniform(0.3, 1.1) * sgn
                e = (x + math.sin(a) * 16, y - math.cos(a) * 9)
                stroke([(x, y), e], 7.0, 3.0, srgb((0.17, 0.32, 0.08)) * rng.uniform(0.8, 1.2), srgb((0.24, 0.42, 0.1)), 2)
        if rng.random() < 0.12:
            stroke([(x - 1, y + 4), (x + 1, y + 4)], 5, 5, srgb((0.08, 0.08, 0.2)), srgb((0.12, 0.12, 0.3)), 2)
# spruce sapling: a thin trunk with drooping tiers of needled branches
tx = CW * 3.5
top = H * 0.08
stroke([(tx, H - 2), (tx, top)], 7, 2, srgb((0.25, 0.17, 0.1)), srgb((0.3, 0.22, 0.12)), 3)
tiers = 22
for i in range(tiers):
    t = i / (tiers - 1)
    y = H - 60 - t * (H - 60 - top)
    span = (1 - t) * CW * 0.42 + 10
    for sgn in (1, -1):
        ex = tx + sgn * span
        ey = y + span * 0.25
        stroke([(tx, y), (tx + sgn * span * 0.5, y + span * 0.08), (ex, ey)], 4, 1.5, srgb((0.08, 0.16, 0.06)), srgb((0.12, 0.22, 0.08)), 3)
        for j in range(int(span / 3)):
            u = j / max(span / 3, 1)
            px, py = tx + sgn * span * u, y + span * 0.25 * u * u
            for d in (-1, 1):
                ln = 14 * (1 - u * 0.5)
                stroke([(px, py), (px + sgn * ln * 0.5, py + d * ln)], 3.0, 1.2, srgb((0.06, 0.13, 0.05)),
                       srgb((0.12, 0.24, 0.08)) * rng.uniform(0.8, 1.2), 3)
save("T_ForestCards_D")
