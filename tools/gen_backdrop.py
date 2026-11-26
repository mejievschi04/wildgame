#!/usr/bin/env python3
"""Bakes the border mountains (world/backdrop.gd) with hydraulic erosion.

Run with a Python that has numpy (Blender's works):
  /Applications/Blender.app/Contents/Resources/5.3/python/bin/python3.13 tools/gen_backdrop.py [--size 1024] [--preview out.png]

The square ±EXTENT around the map is a heightfield of mountain height *above the map's edge*: 0 inside the map
(and it stays 0 there — the valleys drain toward it), a snowy range to the north, wooded hills east and west, a
volcanic plain with four volcanoes to the south. Shapes come from domain-warped ridged multifractal noise; then
~2 million simulated raindrops carve gullies, sharpen ridges and drop sediment in fans and valley floors.

Outputs (assets/textures/backdrop/):
  T_Backdrop_HM.png  R,G = height (16 bit, 0..HMAX m) · B = water flow (gullies) · A = deposited sediment
  T_Backdrop_N.png   RGB = world normal (x, y-up, z) · A = ambient occlusion (concavity)
"""
import argparse, math, os, struct, sys, time, zlib
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "textures", "backdrop")
EXTENT = 13100.0
INNER = 4200.0
HMAX = 6000.0
# keep in sync with Backdrop.VOLCANOES: [x, z, height, radius, crater radius, smoke]
VOLCANOES = [
    [1350.0, 7500.0, 2700.0, 3900.0, 380.0],
    [-2250.0, 6000.0, 1800.0, 2700.0, 240.0],
    [4650.0, 5700.0, 1350.0, 2300.0, 200.0],
    [-5550.0, 5300.0, 1100.0, 2000.0, 170.0],
]


# ------------------------------------------------------------------ noise

class Noise:
    def __init__(self, seed):
        rng = np.random.default_rng(seed)
        self.perm = np.concatenate([rng.permutation(256)] * 2)
        ang = rng.random(256) * math.tau
        self.gx, self.gy = np.cos(ang), np.sin(ang)

    def __call__(self, x, y):
        xi, yi = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64)
        xf, yf = x - xi, y - yi
        xi &= 255; yi &= 255
        p = self.perm
        def g(ix, iy, dx, dy):
            h = p[p[ix] + iy]
            return self.gx[h] * dx + self.gy[h] * dy
        u = xf * xf * xf * (xf * (xf * 6 - 15) + 10)
        v = yf * yf * yf * (yf * (yf * 6 - 15) + 10)
        n00 = g(xi, yi, xf, yf); n10 = g(xi + 1, yi, xf - 1, yf)
        n01 = g(xi, yi + 1, xf, yf - 1); n11 = g(xi + 1, yi + 1, xf - 1, yf - 1)
        return (n00 + u * (n10 - n00) + v * (n01 - n00 + u * (n11 - n01 - n10 + n00))) * 1.41


def fbm(nz, x, y, octaves, lac=2.0, gain=0.5):
    out = np.zeros_like(x); amp = 1.0; f = 1.0; tot = 0.0
    for i in range(octaves):
        out += nz(x * f + i * 17.3, y * f - i * 9.1) * amp
        tot += amp; amp *= gain; f *= lac
    return out / tot


def ridged(nz, x, y, octaves, lac=2.05, gain=0.52):
    """Ridged multifractal: sharp crests, each octave weighted by the one before (detail on the ridges)."""
    out = np.zeros_like(x); w = np.ones_like(x); amp = 1.0; f = 1.0; tot = 0.0
    for i in range(octaves):
        s = 1.0 - np.abs(nz(x * f + i * 31.7, y * f + i * 11.3))
        s = s * s * w
        w = np.clip(s * 1.8, 0, 1)
        out += s * amp
        tot += amp; amp *= gain; f *= lac
    return out / tot


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


# ------------------------------------------------------------------ shape

def base_heights(n):
    c = np.linspace(-EXTENT, EXTENT, n)
    x, z = np.meshgrid(c, c)            # rows = z, cols = x
    cheb = np.maximum(np.abs(x), np.abs(z))
    e = np.maximum(cheb - INNER, 0.0)
    nz = -z / np.maximum(cheb, 1.0)
    wn = smoothstep(0.45, 0.95, nz)
    ws = smoothstep(0.45, 0.95, -nz)
    A, B, C, D = Noise(11), Noise(12), Noise(13), Noise(14)
    # domain warp: ranges bend and branch instead of running in straight lines
    wx = x + fbm(A, x / 5200.0, z / 5200.0, 4) * 1600.0
    wz = z + fbm(B, x / 5200.0 + 7.1, z / 5200.0 - 3.3, 4) * 1600.0
    R = ridged(C, wx / 4200.0, wz / 4200.0, 6, gain=0.45)
    R2 = ridged(D, wx / 1700.0 + 3.0, wz / 1700.0 - 5.0, 6)
    massif = fbm(A, x / 8000.0 + 2.2, z / 8000.0 - 1.4, 3) * 0.5 + 0.5
    rise = smoothstep(0.0, 2600.0, e)
    # the main range peaks 3–7 km out, lower ranges behind it fade into the distance
    crest = 0.72 + 0.28 * np.exp(-((e - 4800.0) / 3200.0) ** 2)
    valley = fbm(D, x / 1400.0 - 4.0, z / 1400.0 + 2.0, 5) * (1.0 - R)  # broken ground between the ridges
    north = rise * crest * (380.0 + 3100.0 * (R ** 1.6) * (0.5 + 0.75 * massif) + 300.0 * R2 * R + 260.0 * valley) + 0.07 * e
    sides = rise * (220.0 + 900.0 * (R ** 1.4) * (0.35 + 0.65 * massif) + 160.0 * R2 * R) + 0.04 * e
    south = rise * (80.0 + 320.0 * (fbm(B, x / 2600.0, z / 2600.0, 5) * 0.5 + 0.5) + 120.0 * R2)
    h = (sides * (1 - wn) + north * wn) * (1 - ws) + south * ws
    for vx, vz, H, Rv, cr in VOLCANOES:
        d = np.hypot(x - vx, z - vz)
        cone = H * np.clip(1.0 - d / Rv, 0, 1) ** 1.7 + 120.0 * np.clip(1.0 - d / Rv, 0, 1)
        k = 140.0  # smooth maximum: the cone's foot spreads into the plain instead of meeting it at a crease
        h = np.maximum(h, cone) + np.maximum(k - np.abs(h - cone), 0.0) ** 2 / (4.0 * k)
    inner = cheb <= INNER
    h[inner] = 0.0
    return h, inner, x, z


# ------------------------------------------------------------------ erosion (vectorised raindrops)

def erode(h, fixed, cell, drops=2_000_000, batch=100_000, steps=64, seed=5):
    """Sebastian Lague's droplet erosion, run for a whole batch of droplets at once. Heights in metres;
    the simulation works in cell units so slopes are dimensionless."""
    rng = np.random.default_rng(seed)
    n = h.shape[0]
    H = (h / cell).astype(np.float64).ravel()
    flow = np.zeros(n * n)
    dep = np.zeros(n * n)
    inertia, cap_k, min_slope, dep_k, ero_k, evap, grav = 0.1, 2.5, 0.01, 0.15, 0.25, 0.02, 4.0
    max_ero = 1.2 / cell  # metres a drop may dig per step
    fixed_f = fixed.ravel()
    t0 = time.time()
    for b in range(max(drops // batch, 0)):
        before = H.copy()
        px = rng.uniform(1, n - 2, batch); py = rng.uniform(1, n - 2, batch)
        dx = np.zeros(batch); dy = np.zeros(batch)
        speed = np.ones(batch); water = np.ones(batch); sed = np.zeros(batch)
        alive = np.ones(batch, bool)
        for s in range(steps):
            ix = px.astype(np.int64); iy = py.astype(np.int64)
            fx = px - ix; fy = py - iy
            i00 = iy * n + ix
            h00, h10, h01, h11 = H[i00], H[i00 + 1], H[i00 + n], H[i00 + n + 1]
            gx = (h10 - h00) * (1 - fy) + (h11 - h01) * fy
            gy = (h01 - h00) * (1 - fx) + (h11 - h10) * fx
            hc = h00 * (1 - fx) * (1 - fy) + h10 * fx * (1 - fy) + h01 * (1 - fx) * fy + h11 * fx * fy
            dx = dx * inertia - gx * (1 - inertia)
            dy = dy * inertia - gy * (1 - inertia)
            ln = np.hypot(dx, dy)
            flat = ln < 1e-9
            ln[flat] = 1.0
            dx /= ln; dy /= ln
            nx_ = px + dx; ny_ = py + dy
            alive &= ~flat & (nx_ >= 1) & (nx_ < n - 2) & (ny_ >= 1) & (ny_ < n - 2)
            if not alive.any():
                break
            nx_ = np.where(alive, nx_, px); ny_ = np.where(alive, ny_, py)
            jx = nx_.astype(np.int64); jy = ny_.astype(np.int64)
            gfx = nx_ - jx; gfy = ny_ - jy
            j00 = jy * n + jx
            hn = (H[j00] * (1 - gfx) * (1 - gfy) + H[j00 + 1] * gfx * (1 - gfy)
                  + H[j00 + n] * (1 - gfx) * gfy + H[j00 + n + 1] * gfx * gfy)
            dh = hn - hc
            cap = np.maximum(-dh, min_slope) * speed * water * cap_k
            depositing = (sed > cap) | (dh > 0)
            # uphill: drop only part of the load (filling every pit flat turns basins into lakes of sediment)
            amt_dep = np.where(dh > 0, np.minimum(dh, sed) * 0.2, (sed - cap) * dep_k)
            amt_dep = np.where(depositing & alive, amt_dep, 0.0)
            amt_ero = np.minimum(np.minimum((cap - sed) * ero_k, -dh), max_ero)
            amt_ero = np.where(~depositing & alive, np.maximum(amt_ero, 0.0), 0.0)
            delta = amt_dep - amt_ero
            sed += amt_ero - amt_dep
            w = [(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy]
            idx = np.concatenate([i00, i00 + 1, i00 + n, i00 + n + 1])
            wts = np.concatenate(w)
            H += np.bincount(idx, weights=wts * np.tile(delta, 4), minlength=n * n)
            flow += np.bincount(idx, weights=wts * np.tile(water * alive, 4), minlength=n * n)
            dep += np.bincount(idx, weights=wts * np.tile(amt_dep, 4), minlength=n * n)
            speed = np.sqrt(np.maximum(speed * speed - dh * grav, 0.0))
            water *= (1 - evap)
            px, py = nx_, ny_
        # erosion "brush": spread this batch's change over 3x3 so drops dig smooth channels, not pits
        d = (H - before).reshape(n, n)
        d = blur3(d)
        H = before + d.ravel()
        H[fixed_f] = 0.0
        if b % 4 == 0:
            print(f"  erosion batch {b + 1}/{drops // batch}  {time.time() - t0:.0f}s", flush=True)
    return H.reshape(n, n) * cell, flow.reshape(n, n), dep.reshape(n, n)


def blur3(a):
    p = np.pad(a, 1, mode="edge")
    return (p[:-2, :-2] + 2 * p[:-2, 1:-1] + p[:-2, 2:] + 2 * p[1:-1, :-2] + 4 * p[1:-1, 1:-1] + 2 * p[1:-1, 2:]
            + p[2:, :-2] + 2 * p[2:, 1:-1] + p[2:, 2:]) / 16.0


def thermal(h, cell, talus_deg=38.0, iters=6, k=0.25):
    """Material on slopes steeper than the talus angle slides down: rounds needle peaks, leaves crisp ridges."""
    t = math.tan(math.radians(talus_deg)) * cell
    for _ in range(iters):
        p = np.pad(h, 1, mode="edge")
        nb = [p[:-2, 1:-1], p[2:, 1:-1], p[1:-1, :-2], p[1:-1, 2:]]
        move = np.zeros_like(h)
        for q in nb:
            diff = h - q
            excess = np.maximum(diff - t, 0.0) * k * 0.25
            move -= excess
        gain = np.zeros_like(h)
        for (q, (sy, sx)) in zip(nb, [(-1, 0), (1, 0), (0, -1), (0, 1)]):
            diff = h - q
            excess = np.maximum(diff - t, 0.0) * k * 0.25
            gain += np.roll(np.roll(excess, sy, 0), sx, 1)
        h = h + move + gain
    return h


# ------------------------------------------------------------------ output

def write_png(path, rgba):
    h, w, _ = rgba.shape
    raw = b"".join(b"\x00" + rgba[y].tobytes() for y in range(h))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--drops", type=int, default=2_000_000)
    ap.add_argument("--preview", default="")
    a = ap.parse_args()
    n = a.size
    cell = 2 * EXTENT / (n - 1)
    t0 = time.time()
    h, inner, x, z = base_heights(n)
    print(f"shape {time.time() - t0:.1f}s  max {h.max():.0f} m")
    h, flow, dep = erode(h, inner, cell, drops=a.drops)
    h = thermal(h, cell)
    # craters are carved after erosion so they stay crisp
    for vx, vz, H, Rv, cr in VOLCANOES:
        d = np.hypot(x - vx, z - vz)
        top = H * (1.0 - cr / Rv) ** 1.7 + 120.0 * (1.0 - cr / Rv)
        bowl = top - 0.35 * cr * (1.0 - np.clip(d / cr, 0, 1) ** 2)
        h = np.where(d < cr * 1.15, np.minimum(h, np.maximum(bowl, h - (1.0 - smoothstep(cr, cr * 1.15, d)) * 400.0)), h)
    h[inner] = 0.0
    h = np.clip(h, 0.0, HMAX)
    print(f"eroded {time.time() - t0:.1f}s  max {h.max():.0f} m")
    # masks
    fl = np.log1p(flow) / np.log1p(np.percentile(flow, 99.7))
    dp = np.log1p(dep * 40.0) / np.log1p(np.percentile(dep * 40.0, 99.5))
    gz, gx = np.gradient(h, cell)
    nrm = np.stack([-gx, np.ones_like(h), -gz], -1)
    nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
    big = h.copy()
    for _ in range(12):
        big = blur3(big)
    ao = np.clip(1.0 - np.maximum(big - h, 0.0) / 140.0, 0.25, 1.0)
    q = np.round(h / HMAX * 65535.0).astype(np.uint32)
    hm = np.zeros((n, n, 4), np.uint8)
    hm[..., 0] = q >> 8
    hm[..., 1] = q & 255
    hm[..., 2] = np.clip(fl * 255, 0, 255)
    hm[..., 3] = np.clip(dp * 255, 0, 255)
    nm = np.zeros((n, n, 4), np.uint8)
    nm[..., :3] = np.clip((nrm * 0.5 + 0.5) * 255, 0, 255)
    nm[..., 3] = np.clip(ao * 255, 0, 255)
    os.makedirs(OUT, exist_ok=True)
    write_png(os.path.join(OUT, "T_Backdrop_HM.png"), hm)
    write_png(os.path.join(OUT, "T_Backdrop_N.png"), nm)
    if a.preview:   # hillshade with snow, for a quick look
        sun = np.array([-0.5, 0.6, 0.6]); sun /= np.linalg.norm(sun)
        lit = np.clip((nrm @ sun), 0, 1) * ao
        col = np.stack([lit * 0.75, lit * 0.8, lit * 0.7], -1)
        snow = (h > 1300) & (nrm[..., 1] > 0.75)
        col[snow] = np.clip(lit[snow, None] * 1.2, 0, 1)
        if os.environ.get("FLOWTINT"):
            col[..., 2] += fl * 0.25
        img = np.zeros((n, n, 4), np.uint8)
        img[..., :3] = np.clip(col * 255, 0, 255); img[..., 3] = 255
        write_png(a.preview, img)
    print(f"done {time.time() - t0:.1f}s")


if __name__ == "__main__":
    main()
