"""Bakes the shared WILDBOUND UI textures (assets/ui/T_UI_*.png). Everything is procedural, no outside art.

  /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -P tools/ui/gen_ui_textures.py -- <mammoth_silhouette.png>

The silhouette comes from tools/ui/render_silhouette.py (the game's own SK_Mammoth seen from the side).
White textures are masks: the game tints them (ochre for the selected brush stroke, bone for cave paint).
"""
import os, sys, zlib, struct
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "ui")
RNG = np.random.default_rng(7)


# ------------------------------------------------------------------ io

def save_png(path, rgba):
    """rgba: float array (h, w, 4) in 0..1."""
    a = (np.clip(rgba, 0, 1) * 255 + 0.5).astype(np.uint8)
    h, w = a.shape[:2]
    raw = b"".join(b"\x00" + a[y].tobytes() for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print("wrote", os.path.relpath(path, ROOT), w, "x", h)


def load_alpha(path):
    import bpy
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)[::-1]
    return px[..., 3]


# ------------------------------------------------------------------ noise

def value_noise(h, w, cy, cx, seed, tile=True):
    """Bilinear value noise with cy x cx cells, wrapping when tile=True."""
    r = np.random.default_rng(seed).random((cy + 1, cx + 1))
    if tile:
        r[-1, :] = r[0, :]
        r[:, -1] = r[:, 0]
    ys = np.linspace(0, cy, h, endpoint=not tile)
    xs = np.linspace(0, cx, w, endpoint=not tile)
    y0 = np.minimum(ys.astype(int), cy - 1)
    x0 = np.minimum(xs.astype(int), cx - 1)
    ty = (ys - y0)[:, None]
    tx = (xs - x0)[None, :]
    ty = ty * ty * (3 - 2 * ty)
    tx = tx * tx * (3 - 2 * tx)
    a = r[y0][:, x0]
    b = r[y0][:, x0 + 1]
    c = r[y0 + 1][:, x0]
    d = r[y0 + 1][:, x0 + 1]
    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty


def fbm(h, w, cy, cx, seed, octaves=4, tile=True):
    out = np.zeros((h, w))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        out += amp * value_noise(h, w, cy * 2 ** o, cx * 2 ** o, seed + o * 31, tile)
        tot += amp
        amp *= 0.5
    return out / tot


def noise1(n, cells, seed, octaves=4):
    return fbm(1, n, 1, cells, seed, octaves, tile=False)[0]


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def box_blur(a, r):
    if r < 1:
        return a
    k = 2 * r + 1
    p = np.pad(a, r, mode="edge")
    c = np.cumsum(np.cumsum(p, 0), 1)
    c = np.pad(c, ((1, 0), (1, 0)))
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)


def resize(a, h, w):
    ys = np.linspace(0, a.shape[0] - 1, h)
    xs = np.linspace(0, a.shape[1] - 1, w)
    y0 = np.floor(ys).astype(int)
    x0 = np.floor(xs).astype(int)
    y1 = np.minimum(y0 + 1, a.shape[0] - 1)
    x1 = np.minimum(x0 + 1, a.shape[1] - 1)
    ty = (ys - y0)[:, None]
    tx = (xs - x0)[None, :]
    return (a[y0][:, x0] * (1 - tx) + a[y0][:, x1] * tx) * (1 - ty) + (a[y1][:, x0] * (1 - tx) + a[y1][:, x1] * tx) * ty


def rgba(rgb, alpha):
    h, w = alpha.shape
    out = np.zeros((h, w, 4))
    out[..., :3] = rgb
    out[..., 3] = alpha
    return out


# ------------------------------------------------------------------ brush stroke

def stroke():
    """A dry-brush stroke of paint: ragged edges, bristle streaks, broken ends. 9-slice: 44 px caps."""
    W, H = 320, 64
    y = np.arange(H)[:, None].astype(float)
    x = np.arange(W)[None, :].astype(float)
    top = 9 + 3.5 * (noise1(W, 8, 1) - 0.5) * 2 + 1.5 * (noise1(W, 50, 2) - 0.5) * 2
    bot = 55 + 3.5 * (noise1(W, 8, 3) - 0.5) * 2 + 1.5 * (noise1(W, 50, 4) - 0.5) * 2
    band = smooth(-1.0, 1.0, y - top[None, :]) * smooth(-1.0, 1.0, bot[None, :] - y)
    # Ends: each bristle row stops at its own place.
    rows = noise1(H, 10, 5, 3)
    left = 4 + 28 * rows + 10 * ((y[:, 0] - 32) / 32) ** 2
    rows2 = noise1(H, 10, 6, 3)
    right = W - 4 - 32 * rows2 - 10 * ((y[:, 0] - 32) / 32) ** 2
    ends = smooth(-1.5, 4, x - left[:, None]) * smooth(-1.5, 6, right[:, None] - x)
    bristle = fbm(H, W, 24, 3, 9, 3, tile=False)
    streak = 0.72 + 0.28 * smooth(0.25, 0.75, bristle)
    # Dry gaps where the brush ran out of paint near the right end.
    dry = fbm(H, W, 14, 6, 11, 3, tile=False)
    fade = smooth(W - 90, W - 8, x)
    dry_mask = 1 - fade * smooth(0.45, 0.62, dry)
    alpha = band * ends * dry_mask
    alpha *= 0.88 + 0.12 * streak
    value = 0.8 + 0.2 * streak
    rgb = np.stack([value] * 3, -1)
    save_png(os.path.join(OUT, "T_UI_Stroke.png"), rgba(rgb, np.clip(alpha, 0, 1)))


# ------------------------------------------------------------------ panels

def rough_rect(H, W, inset, amp, seed):
    y = np.arange(H)[:, None].astype(float)
    x = np.arange(W)[None, :].astype(float)
    t = inset + amp * noise1(W, 12, seed)
    b = H - inset - amp * noise1(W, 12, seed + 1)
    l = inset + amp * noise1(H, 12, seed + 2)
    r = W - inset - amp * noise1(H, 12, seed + 3)
    d = np.minimum(np.minimum(y - t[None, :], b[None, :] - y), np.minimum(x - l[:, None], r[:, None] - x))
    return d  # signed distance-ish to the rough edge (positive inside)


def slab():
    """Dark stone / smoked hide panel with a chipped edge. 9-slice: 40 px."""
    S = 256
    d = rough_rect(S, S, 5, 5, 20)
    alpha = smooth(-0.8, 0.8, d) * 0.95
    n = fbm(S, S, 3, 3, 21, 5)
    base = np.array([0.105, 0.078, 0.055])
    shade = (0.86 + 0.28 * n)[..., None]
    rgb = base * shade
    # Lit rim and inner shade.
    rim = smooth(3.5, 0.5, d) * smooth(-0.5, 0.5, d)
    rgb = rgb + rim[..., None] * np.array([0.30, 0.22, 0.12]) * (0.5 + 0.5 * n[..., None])
    inner = smooth(26, 4, d)[..., None]
    rgb = rgb * (1 - 0.35 * inner)
    save_png(os.path.join(OUT, "T_UI_Slab.png"), rgba(rgb, alpha))


def cell():
    """Item cell: dark inset with a worn bevel. 9-slice: 16 px."""
    S = 128
    d = rough_rect(S, S, 2, 2.5, 40)
    alpha = smooth(-0.8, 0.8, d)
    y = np.arange(S)[:, None] / S
    n = fbm(S, S, 4, 4, 41, 4)
    rgb = np.array([0.075, 0.058, 0.042]) * (0.9 + 0.2 * n)[..., None] * (1.12 - 0.24 * y)[..., None]
    rim = smooth(2.6, 0.6, d) * smooth(-0.6, 0.6, d)
    rgb = rgb + rim[..., None] * np.array([0.26, 0.2, 0.13]) * (0.6 + 0.4 * n[..., None])
    inner = smooth(10, 2, d)[..., None]
    rgb = rgb * (1 - 0.3 * inner)
    save_png(os.path.join(OUT, "T_UI_Cell.png"), rgba(rgb, alpha * 0.9))
    # Selection rim (white mask, tinted gold in game).
    r2 = smooth(4.0, 1.5, d) * smooth(-0.6, 0.6, d) * (0.75 + 0.25 * n)
    save_png(os.path.join(OUT, "T_UI_Rim.png"), rgba(np.ones(3), r2))


def hide():
    """Scraped animal hide: fur-fringed ragged edge, mottled leather. 9-slice: 84 px."""
    S = 384
    y = np.arange(S)[:, None].astype(float)
    x = np.arange(S)[None, :].astype(float)
    def edge(seed):
        wave = 12 * noise1(S, 5, seed, 3) + 6 * noise1(S, 18, seed + 1, 2)
        hair = 9 * smooth(0.35, 0.95, noise1(S, S // 3, seed + 2, 1)) * noise1(S, 9, seed + 3, 2)
        return 14 + wave - hair, 14 + wave
    t, t0 = edge(100)
    b, b0 = edge(110)
    l, l0 = edge(120)
    r, r0 = edge(130)
    d = np.minimum(np.minimum(y - t[None, :], (S - y) - b[None, :]), np.minimum(x - l[:, None], (S - x) - r[:, None]))
    alpha = smooth(-0.9, 0.9, d)
    n = fbm(S, S, 4, 4, 140, 5)
    m = fbm(S, S, 14, 14, 141, 3)
    base = np.array([0.20, 0.145, 0.098])
    rgb = base * (0.78 + 0.32 * n + 0.1 * (m - 0.5))[..., None]
    burn = smooth(34, 2, d)[..., None]
    rgb = rgb * (1 - 0.55 * burn)
    fur = smooth(6, -1, d) * smooth(-1, 1, d)
    rgb = rgb + fur[..., None] * np.array([0.10, 0.07, 0.04]) * m[..., None]
    save_png(os.path.join(OUT, "T_UI_Hide.png"), rgba(rgb, alpha * 0.97))


def grain():
    S = 256
    n = 0.5 * fbm(S, S, 64, 64, 60, 2) + 0.5 * fbm(S, S, 128, 128, 61, 1)
    save_png(os.path.join(OUT, "T_UI_Grain.png"), rgba(np.stack([n] * 3, -1), np.ones((S, S))))


# ------------------------------------------------------------------ cave paintings

def paint(alpha, seed, rough=0.32, blur=3):
    """Turns a hard mask into ochre-on-rock paint: chewed edges, uneven pigment."""
    h, w = alpha.shape
    soft = box_blur(alpha, blur)
    n = fbm(h, w, max(2, h // 24), max(2, w // 24), seed, 4, tile=False)
    a = smooth(0.42, 0.58, soft + (n - 0.5) * rough)
    pig = fbm(h, w, max(2, h // 10), max(2, w // 10), seed + 5, 3, tile=False)
    a *= 0.78 + 0.22 * smooth(0.25, 0.7, pig)
    speck = fbm(h, w, max(2, h // 7), max(2, w // 7), seed + 9, 2, tile=False)
    a *= 1 - 0.3 * smooth(0.7, 0.82, speck)
    return a


def crop(alpha, pad=8):
    ys, xs = np.nonzero(alpha > 0.05)
    y0, y1 = max(ys.min() - pad, 0), min(ys.max() + pad, alpha.shape[0])
    x0, x1 = max(xs.min() - pad, 0), min(xs.max() + pad, alpha.shape[1])
    return alpha[y0:y1, x0:x1]


def mammoth(sil_path):
    a = crop(load_alpha(sil_path), 24)
    h, w = a.shape
    W = 512
    H = int(round(h * W / w))
    a = resize(a, H, W)
    a = paint(a, 70, 0.36, 4)
    save_png(os.path.join(OUT, "T_UI_Mammoth.png"), rgba(np.ones(3), a))


def seg_field(H, W, segs):
    """Max over thick segments: segs = [(x0, y0, x1, y1, width)]. Returns coverage 0..1."""
    yy, xx = np.mgrid[0:H, 0:W].astype(float)
    out = np.zeros((H, W))
    for x0, y0, x1, y1, wd in segs:
        dx, dy = x1 - x0, y1 - y0
        L = dx * dx + dy * dy
        t = np.clip(((xx - x0) * dx + (yy - y0) * dy) / max(L, 1e-6), 0, 1)
        d = np.hypot(xx - (x0 + t * dx), yy - (y0 + t * dy))
        out = np.maximum(out, smooth(wd * 0.5 + 0.8, wd * 0.5 - 0.8, d))
    return out


def disc_field(H, W, discs):
    yy, xx = np.mgrid[0:H, 0:W].astype(float)
    out = np.zeros((H, W))
    for cx, cy, rx, ry in discs:
        d = np.hypot((xx - cx) / rx, (yy - cy) / ry)
        out = np.maximum(out, smooth(1.04, 0.96, d))
    return out


def hunter(ox, oy, s, lean, spear_up, stride):
    """Running stick hunter in the style of rock art. Returns (segments, discs)."""
    def P(x, y):
        return ox + x * s, oy + y * s
    hip = P(lean * 0.3, 0)
    neck = P(lean, -46)
    head = P(lean * 1.15, -58)
    k1 = P(lean * 0.3 + 14 * stride, 22)
    f1 = P(lean * 0.3 + 26 * stride, 44)
    k2 = P(lean * 0.3 - 12 * stride, 24)
    f2 = P(lean * 0.3 - 26 * stride, 40)
    sh = P(lean * 0.9, -40)
    hand = P(lean + 22, -36 - 8 * spear_up)
    hand2 = P(lean - 16, -24)
    sp0 = P(lean - 34, -14 + 18 * spear_up)
    sp1 = P(lean + 62, -54 - 30 * spear_up)
    w = 6.5 * s
    segs = [
        (*hip, *neck, w * 1.25), (*hip, *k1, w), (*k1, *f1, w * 0.85), (*hip, *k2, w), (*k2, *f2, w * 0.85),
        (*sh, *hand, w * 0.8), (*sh, *hand2, w * 0.8), (*sp0, *sp1, w * 0.45),
    ]
    tip_dx, tip_dy = sp1[0] - sp0[0], sp1[1] - sp0[1]
    L = np.hypot(tip_dx, tip_dy)
    ux, uy = tip_dx / L, tip_dy / L
    segs.append((sp1[0] - ux * 14 * s - uy * 5 * s, sp1[1] - uy * 14 * s + ux * 5 * s, sp1[0] + ux * 4 * s, sp1[1] + uy * 4 * s, w * 0.55))
    segs.append((sp1[0] - ux * 14 * s + uy * 5 * s, sp1[1] - uy * 14 * s - ux * 5 * s, sp1[0] + ux * 4 * s, sp1[1] + uy * 4 * s, w * 0.55))
    discs = [(head[0], head[1], 8.5 * s, 9.5 * s)]
    return segs, discs


def hunters():
    H, W = 200, 420
    segs, discs = [], []
    for ox, oy, s, lean, up, st in [(70, 120, 1.1, 10, 0.6, 1.0), (205, 128, 1.0, 14, 0.2, 1.15), (330, 122, 1.05, 8, 0.9, 0.9)]:
        a, b = hunter(ox, oy, s, lean, up, st)
        segs += a
        discs += b
    a = np.maximum(seg_field(H, W, segs), disc_field(H, W, discs))
    a = paint(a, 80, 0.3, 2)
    save_png(os.path.join(OUT, "T_UI_Hunters.png"), rgba(np.ones(3), a))


def handprint():
    """Hand stencil: pigment blown round a hand, the hand itself left bare."""
    S = 256
    hand = disc_field(S, S, [(128, 168, 40, 44)])
    fingers = [(104, 140, 90, 64, 24), (122, 134, 118, 46, 26), (142, 136, 150, 54, 24), (158, 146, 178, 90, 20), (94, 176, 56, 138, 26)]
    hand = np.maximum(hand, seg_field(S, S, fingers))
    hand = np.maximum(hand, seg_field(S, S, [(128, 196, 128, 256, 62)]))
    yy, xx = np.mgrid[0:S, 0:S].astype(float)
    r = np.hypot(xx - 130, yy - 140) / 118
    n = fbm(S, S, 10, 10, 90, 4, tile=False)
    spray = smooth(1.0, 0.45, r + (n - 0.5) * 0.35)
    spray *= 0.55 + 0.45 * fbm(S, S, 40, 40, 91, 2, tile=False)
    a = spray * (1 - smooth(0.3, 0.7, box_blur(hand, 2)))
    save_png(os.path.join(OUT, "T_UI_Hand.png"), rgba(np.ones(3), np.clip(a, 0, 1)))


if __name__ == "__main__":
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    os.makedirs(OUT, exist_ok=True)
    stroke()
    slab()
    cell()
    grain()
    hide()
    hunters()
    handprint()
    if argv:
        mammoth(argv[0])
