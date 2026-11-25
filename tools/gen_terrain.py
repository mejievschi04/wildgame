#!/usr/bin/env python3
"""Bakes the playable terrain (world/forest_world.gd) with hydraulic erosion and extracts its creeks.

Run with a Python that has numpy (Blender's works):
  /Applications/Blender.app/Contents/Resources/5.3/python/bin/python3.13 tools/gen_terrain.py [--preview out.png]

The square ±HALF (4.2 km) is laid out by region, each with its own landform:
  Aruun   a raised terrace over the river, a steep bluff on the river side and a path down to the water
  Kharum  a western massif of domain-warped ridged noise with a pass (Pasul Pietrei) cut north toward Tavren
  Tavren  rolling forest hills and ravines in the north-west
  Tundra  a cold upland under the northern range; the river leaves the range through a gorge
  Varkai  a plateau in the north-east, an escarpment toward Aruun with a crest along its western rim
  Meyra   an eastern marsh lowland a metre or two above the water, crossed by the river's channels
  Ossara  a low rolling steppe in the south with a dry gully (Șanțul Uscat) running to the lake
The river, Meyra channels and lake are fixed sinks during erosion (their exact profile is cut at runtime), so
~1.5 million raindrops carve valleys that drain into them. Creeks are then traced on the eroded surface (flow
accumulation over a depression-filled copy), given a water level that only ever descends, and cut into the bake.

The erosion runs on a 4 m grid; the result is upsampled (Catmull-Rom) to the final ~2 m grid, where the creeks,
the river's and lake's exact cut, the fords and the flattened camp sites are applied. The game reads the final
heights as they are (mesh, collision and height_at() all use the same grid and triangulation).

Outputs:
  assets/terrain/terrain_height.bin  zlib-compressed float32 heights, FINE_N², row = z (north first), metres
  assets/terrain/T_Terrain_Masks.png R = creek bed · G = runoff gullies · B = sediment · A = 255
  data/streams.json                  creeks: points [x, z, water level], width class, catchment
  data/caves.json                    caves: rings along each tunnel (floor, half-width, height, roof heights)

Caves are cut, not tunnelled: a trench in the heightfield is the cave's floor and walls (so the terrain collision
needs no holes), and at runtime a rock roof (world/cave.gd) closes it, its outer face the hillside as it was.
Keep RIVER / MEYRA / LAKE in sync with ForestWorld.
"""
import argparse, heapq, json, math, os, sys, time, zlib
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_backdrop import Noise, fbm, ridged, smoothstep, erode, thermal, blur3, write_png  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "terrain")
HALF = 2100.0
PLAYABLE = 2000.0
LAKE = (205.0, 1760.0, 170.0, 145.0)  # centre x, z, radius x, radius z
SPAWN = (0.0, 0.0)
FINE_N = 2049                      # final grid: 4200 m / 2048 = 2.05 m (keep in sync with ForestWorld.BAKE_N)
OLD_CAMP = (55.0, -58.0)
# Regional bases (keep in sync with Camps.REGIONAL_BASES): centre, wall radius. Faction camps come from factions.json.
REGIONAL_BASES = [((112.0, 1280.0), 0.0), ((1032.0, 606.0), 8.0), ((-912.0, -1152.0), 10.0),
                  ((-1260.0, 100.0), 12.0), ((1170.0, -1220.0), 15.0)]
# Fords (keep in sync with ForestWorld.FORDS): river z, half-length along the river, bed height.
FORDS = [(-200.0, 9.0, -0.12), (1150.0, 15.0, -0.08)]
# Caves: entrance, heading (degrees, 0 = +x/east, 90 = +z/south), tunnel length, half-width and height, and the
# chamber at the end (radius, height). MOUTH: metres from the entrance where the roof begins.
CAVES = [
    {"id": "kharum_cave", "entry": (-1296.0, 87.0), "dir": 270.0, "length": 72.0, "hw": 3.0, "height": 4.2,
     "chamber": 10.0, "chamber_height": 7.5},
    {"id": "varkai_grotto", "entry": (554.0, -1000.0), "dir": 350.0, "length": 26.0, "hw": 2.6, "height": 3.6,
     "chamber": 5.5, "chamber_height": 4.8},
]
CAVE_MOUTH = 4.0
CAVE_APPROACH = 14.0
CAVE_COVER = 2.5
ROOF_SAMPLES = 31   # across each roof ring (same count on every ring, so rings join quad to quad)
# River cross-section (ForestWorld used to cut it at runtime).
RIVER_BED, RIVER_BANK_START, RIVER_BANK_END, RIVER_BANK_TOP, RIVER_VALLEY_SLOPE = -1.4, 1.0, 23.0, 2.0, 0.34


# ------------------------------------------------------------------ water layout (keep in sync with ForestWorld)

def river_x(z):
    return 155.0 + 95.0 * np.sin(z * 0.0019) + 34.0 * np.sin(z * 0.0044 + 1.3)


def meyra_a(z):
    """East channel: leaves the river at z 180, swings through the marsh and turns back into the lake's east shore."""
    bend = 35.0 * (np.sin(z * 0.003) - math.sin(180.0 * 0.003))
    out = 250.0 * smoothstep(180.0, 520.0, z) + bend
    home = smoothstep(1250.0, 1720.0, z)
    return river_x(z) + out * (1.0 - home) + home * (LAKE[0] + 120.0 - river_x(z))


def meyra_b(z):
    """Braid: splits from the east channel at z 430 and rejoins it at z 1300."""
    bend = 45.0 * (np.sin(z * 0.0025) - math.sin(430.0 * 0.0025))
    return meyra_a(z) + (220.0 * smoothstep(430.0, 760.0, z) + bend) * (1.0 - smoothstep(1050.0, 1300.0, z))


RIVER_END = LAKE[1] - LAKE[3] + 20.0
CHANNELS = [  # (function, start z, end z)
    (river_x, -PLAYABLE - 100.0, RIVER_END),
    (meyra_a, 180.0, 1700.0),
    (meyra_b, 430.0, 1300.0),
]


def channel_distance(x, z):
    """Distance to the nearest channel centre line, sampled along z (good enough for the bake's 4 m cells)."""
    d = np.full(x.shape, 1e9)
    for fn, z0, z1 in CHANNELS:
        zs = np.arange(z0, z1 + 4.0, 4.0)
        xs = fn(zs)
        # per row of the grid only the stretch of channel within ±400 m of that z matters
        for r in range(x.shape[0]):
            zr = z[r, 0]
            sel = np.abs(zs - zr) < 420.0
            if not sel.any():
                continue
            cx, cz = xs[sel], zs[sel]
            dd = np.min(np.hypot(x[r][:, None] - cx[None, :], zr - cz[None, :]), axis=1)
            d[r] = np.minimum(d[r], dd)
    return d


def lake_distance(x, z):
    return np.hypot((x - LAKE[0]) * LAKE[3] / LAKE[2], z - LAKE[1])


# ------------------------------------------------------------------ helpers

def ellipse(wx, wz, cx, cz, rx, rz):
    return np.hypot((wx - cx) / rx, (wz - cz) / rz)


def polyline_distance(x, z, pts):
    """Distance to a polyline and the interpolated parameter t (0..1 by length) of the nearest point."""
    pts = np.asarray(pts, float)
    seg = pts[1:] - pts[:-1]
    lens = np.hypot(seg[:, 0], seg[:, 1])
    cum = np.concatenate([[0.0], np.cumsum(lens)])
    best = np.full(x.shape, 1e9)
    bt = np.zeros(x.shape)
    for i in range(len(seg)):
        px, pz = x - pts[i, 0], z - pts[i, 1]
        u = np.clip((px * seg[i, 0] + pz * seg[i, 1]) / (lens[i] ** 2), 0.0, 1.0)
        d = np.hypot(px - u * seg[i, 0], pz - u * seg[i, 1])
        m = d < best
        best = np.where(m, d, best)
        bt = np.where(m, (cum[i] + u * lens[i]) / cum[-1], bt)
    return best, bt


def smin(a, b, k):
    t = np.maximum(k - np.abs(a - b), 0.0) / k
    return np.minimum(a, b) - t * t * k * 0.25


# Pasul Pietrei: from the Aruun side up through the Kharum massif to the Tavren hills.
KHARUM_PASS = [(-740.0, 340.0), (-900.0, 250.0), (-1010.0, 120.0), (-1130.0, -40.0), (-1160.0, -200.0),
               (-1230.0, -340.0), (-1200.0, -500.0), (-1110.0, -640.0), (-1070.0, -860.0)]
KHARUM_SADDLE = 58.0
# Șanțul Uscat: a dry gully across the steppe to the lake's west shore (Ossara's covered approach).
DRY_GULLY = [(-820.0, 1640.0), (-640.0, 1700.0), (-450.0, 1735.0), (-260.0, 1760.0), (-100.0, 1770.0),
             (30.0, 1765.0)]
# Poteca Aruun: from the terrace down the bluff to the river bank.
ARUUN_PATH = [(70.0, 20.0), (105.0, 52.0), (138.0, 66.0), (170.0, 72.0)]


# ------------------------------------------------------------------ landform

def landform(x, z):
    N = [Noise(100 + i) for i in range(10)]
    # Domain warp: region outlines bend instead of reading as circles.
    wx = x + fbm(N[0], x / 1500.0, z / 1500.0, 3) * 260.0
    wz = z + fbm(N[1], x / 1500.0 + 5.0, z / 1500.0 - 2.0, 3) * 260.0
    roll = fbm(N[2], x / 900.0, z / 900.0, 5)
    fine = fbm(N[3], x / 160.0, z / 160.0, 4)
    swell = fbm(N[7], x / 320.0 + 3.0, z / 320.0 - 8.0, 4)
    h = 30.0 + 11.0 * roll + 3.2 * swell + 1.6 * fine

    # Tavren: rolling forest hills cut by ravines.
    m_tv = 1.0 - smoothstep(0.75, 1.15, ellipse(wx, wz, -1080.0, -1150.0, 820.0, 560.0))
    hills = ridged(N[4], wx / 520.0, wz / 520.0, 5, gain=0.5)
    h += m_tv * (8.0 + 46.0 * hills ** 1.3)

    # Kharum: the western massif, separate summits on a broken ridge network.
    m_k = 1.0 - smoothstep(0.62, 1.08, ellipse(wx, wz, -1560.0, 60.0, 700.0, 980.0))
    R = ridged(N[5], wx / 760.0, wz / 760.0, 6, gain=0.5)
    R = (R - R.min()) / (R.max() - R.min())
    h += m_k * (26.0 + 150.0 * R ** 1.45)

    # Northern range over the tundra; lower near the river, which leaves it through a gorge.
    m_n = smoothstep(-1640.0, -1960.0, wz)
    R2 = ridged(N[6], wx / 640.0 + 3.0, wz / 640.0 - 1.0, 6, gain=0.5)
    R2 = (R2 - R2.min()) / (R2.max() - R2.min())
    gap = 1.0 - 0.55 * np.exp(-((x - river_x(z)) / 300.0) ** 2)
    h += m_n * gap * (45.0 + 135.0 * R2 ** 1.35)
    m_t = smoothstep(-1150.0, -1450.0, wz) * (1.0 - m_n)
    h += m_t * (14.0 + 4.0 * fbm(N[7], x / 600.0, z / 600.0, 3))

    # Varkai plateau: crisp outline (small warp), escarpment west and south, gentle ramp to the east.
    vx = x + fbm(N[8], x / 900.0, z / 900.0, 4) * 190.0
    vz = z + fbm(N[9], x / 900.0 + 2.0, z / 900.0, 4) * 190.0
    dv = ellipse(vx, vz, 1150.0, -1180.0, 620.0, 520.0)
    east = np.clip((vx - 1150.0) / 620.0 / np.maximum(dv, 1e-3), -1.0, 1.0)
    soft = 0.05 + 0.03 * fbm(N[6], x / 200.0, z / 200.0, 3) + 0.34 * smoothstep(-0.1, 0.85, east)
    plateau = 1.0 - smoothstep(1.0 - soft, 1.0, dv)
    rim = np.exp(-((dv - 0.9) / 0.07) ** 2) * smoothstep(0.3, -0.5, east)
    mesa = ridged(N[8], x / 380.0, z / 380.0, 5, gain=0.5)
    top = 70.0 + 5.0 * roll + 14.0 * mesa + 1.2 * fine
    h = h * (1.0 - plateau) + plateau * np.maximum(top, h) + 14.0 * rim * plateau

    # Meyra: marsh lowland a little above the water, hummocks and slight rises.
    m_m = 1.0 - smoothstep(0.45, 1.35, ellipse(wx, wz, 1280.0, 820.0, 760.0, 700.0))
    marsh = 2.4 + 1.6 * fbm(N[2], x / 260.0 + 9.0, z / 260.0, 4) + 0.9 * swell + 0.5 * fine
    h = h * (1.0 - m_m * 0.92) + m_m * 0.92 * np.maximum(marsh, 1.1)

    # Ossara: low steppe with long swells.
    m_o = smoothstep(820.0, 1180.0, wz) * (1.0 - m_m)
    steppe = 13.0 + 9.0 * fbm(N[3], x / 1300.0 + 4.0, z / 1300.0, 3) + 3.5 * swell + 1.5 * fine
    h = h * (1.0 - 0.85 * m_o) + 0.85 * m_o * steppe

    # River valley: a floodplain along the river, narrowing into a gorge through the northern range.
    dr = channel_distance(x, z)
    width = 1.0 - 0.6 * m_n
    valley = 1.0 - smoothstep(50.0 * width, 330.0 * width, dr)
    floor = 6.0 + 0.045 * dr
    h = h * (1.0 - 0.85 * valley) + 0.85 * valley * np.minimum(floor, h)

    # Aruun: raised terrace over the river, steeper toward the water (the bluff).
    ax = np.where(x > 0.0, 135.0, 190.0)
    da = ellipse(x + fbm(N[4], x / 260.0, z / 260.0, 4) * 75.0, z + fbm(N[5], x / 260.0, z / 260.0, 4) * 60.0,
                 -20.0, -10.0, ax, 240.0)
    core = 1.0 - smoothstep(0.7, 1.25, da)
    top = 40.0 + 2.5 * roll + 2.0 * swell + 0.8 * fine
    h = np.maximum(h, h * (1.0 - core) + core * top)

    # Kharum pass: a corridor through the massif rising to the saddle and falling to Tavren.
    dp, tp = polyline_distance(x, z, chaikin(np.array(KHARUM_PASS), 3))
    dp = dp + 9.0 * fbm(N[9], x / 120.0, z / 120.0, 3)
    pass_floor = np.interp(tp, [0.0, 0.42, 0.55, 1.0], [36.0, KHARUM_SADDLE, KHARUM_SADDLE, 44.0])
    walls = pass_floor + 2.0 * fine + np.maximum(dp - 26.0, 0.0) * 0.55
    h = np.where(dp < 200.0, smin(h, walls, 10.0), h)

    # Water bodies: sinks for the erosion (their exact profile is cut at runtime).
    ld = lake_distance(x, z)
    h = np.where(ld < 260.0, h * smoothstep(150.0, 260.0, ld) - 5.0 * (1.0 - smoothstep(150.0, 260.0, ld)), h)
    # Stay ~2 m above the runtime river profile on the banks: there the runtime cut alone decides the shape
    # (two near-equal surfaces through its smooth minimum would sink the banks by ~2 m).
    h = np.where(dr < 40.0, np.minimum(h, 3.2 + dr * 0.2), h)
    fixed = (dr < 10.0) | (ld < 150.0)
    h[fixed] = np.minimum(h[fixed], -1.0)
    return h, fixed, dr, ld, m_m


# ------------------------------------------------------------------ hydrology

def fill_depressions(h, outlet):
    """Priority flood: raises every pit to its spill level so water can always reach an outlet."""
    n = h.shape[0]
    filled = h.copy()
    done = np.zeros(h.shape, bool)
    heap = []
    edge = outlet.copy()
    edge[0, :] = edge[-1, :] = edge[:, 0] = edge[:, -1] = True
    for r, c in zip(*np.nonzero(edge)):
        heapq.heappush(heap, (filled[r, c], r, c))
        done[r, c] = True
    flat = filled.ravel()
    dn = done.ravel()
    eps = 1e-4
    while heap:
        hv, r, c = heapq.heappop(heap)
        for dr_, dc in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
            rr, cc = r + dr_, c + dc
            if rr < 0 or cc < 0 or rr >= n or cc >= n:
                continue
            k = rr * n + cc
            if dn[k]:
                continue
            dn[k] = True
            if flat[k] <= hv:
                flat[k] = hv + eps
            heapq.heappush(heap, (flat[k], rr, cc))
    return filled


OFFS = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]


def flow_directions(f):
    """D8 steepest descent on the filled surface: index of the receiving cell, -1 for outlets/edges."""
    n = f.shape[0]
    p = np.pad(f, 1, mode="constant", constant_values=np.inf)
    best = np.zeros(f.shape)
    rec = np.full(f.shape, -1, np.int64)
    rows, cols = np.indices(f.shape)
    for dr_, dc in OFFS:
        q = p[1 + dr_:n + 1 + dr_, 1 + dc:n + 1 + dc]
        drop = (f - q) / math.hypot(dr_, dc)
        m = drop > best
        best = np.where(m, drop, best)
        rec = np.where(m, (rows + dr_) * n + (cols + dc), rec)
    return rec


def accumulate(f, rec):
    n = f.shape[0]
    order = np.argsort(-f.ravel(), kind="stable")
    acc = np.ones(n * n)
    rv = rec.ravel()
    for k in order:
        r = rv[k]
        if r >= 0:
            acc[r] += acc[k]
    return acc.reshape(f.shape)


def trace_creeks(h, f, rec, acc, water, cell, xs):
    """Creek trunks (and their big tributaries) from mouth to source, only those draining into the river or lake."""
    n = h.shape[0]
    a_mouth = 0.35e6 / (cell * cell)    # catchment needed to show a creek at its mouth (m²)
    a_src = 0.05e6 / (cell * cell)      # the creek begins where its catchment reaches this
    a_branch = 0.18e6 / (cell * cell)
    rv = rec.ravel()
    av = acc.ravel()
    wv = water.ravel()
    # donors of each cell
    donors = [[] for _ in range(n * n)]
    for k in np.nonzero(rv >= 0)[0]:
        donors[rv[k]].append(k)
    mouths = [k for k in np.nonzero((~wv) & (rv >= 0))[0] if wv[rv[k]] and av[k] >= a_mouth]
    mouths.sort(key=lambda k: -av[k])
    creeks = []
    claimed = np.zeros(n * n, bool)

    def walk(k, min_a):
        path = [k]
        while True:
            ups = [d for d in donors[path[-1]] if not wv[d]]
            if not ups:
                break
            u = max(ups, key=lambda d: av[d])
            if av[u] < min_a:
                break
            path.append(u)
        return path

    for m in mouths:
        if claimed[m]:
            continue
        trunk = walk(m, a_src)
        if len(trunk) * cell < 260.0:
            continue
        for k in trunk:
            claimed[k] = True
        creeks.append({"cells": trunk, "catchment": float(av[m] * cell * cell), "joins": -1})
        ti = len(creeks) - 1
        # one level of tributaries
        for k in trunk[1:]:
            main = max([d for d in donors[k] if not wv[d]], key=lambda d: av[d], default=None)
            for d in donors[k]:
                if d == main or wv[d] or claimed[d] or av[d] < a_branch:
                    continue
                trib = walk(d, a_src)
                if len(trib) * cell < 200.0:
                    continue
                for t in trib:
                    claimed[t] = True
                creeks.append({"cells": [k] + trib, "catchment": float(av[d] * cell * cell), "joins": ti})
    out = []
    for c in creeks:
        idx = np.array(c["cells"])
        r, col = idx // n, idx % n
        pts = np.stack([xs[col], xs[r]], -1)[::-1]  # source → mouth
        out.append({"pts": pts, "catchment": c["catchment"], "joins": c["joins"]})
    return out


def snap_to_valley(h, xs, pts, reach=14.0):
    """Smoothing cuts a D8 path's corners and can lift it onto the valley side; move each point across the flow
    to the lowest ground within ±reach, then smooth those shifts so the line stays a gentle curve."""
    t = np.gradient(pts, axis=0)
    t /= np.maximum(np.linalg.norm(t, axis=1, keepdims=True), 1e-6)
    nrm = np.stack([t[:, 1], -t[:, 0]], -1)
    offs = np.arange(-reach, reach + 0.1, 1.0)
    qx = pts[:, 0:1] + nrm[:, 0:1] * offs[None, :]
    qz = pts[:, 1:2] + nrm[:, 1:2] * offs[None, :]
    hh = sample(h, xs, qx, qz) + 0.004 * offs[None, :] ** 2   # ties: stay near the line
    shift = offs[np.argmin(hh, axis=1)]
    k = np.ones(5) / 5.0
    shift = np.convolve(np.pad(shift, 2, mode="edge"), k, mode="valid")
    shift[0] = shift[-1] = 0.0                                   # keep the ends (sources, junctions) in place
    return pts + nrm * shift[:, None]


def chaikin(pts, it=3):
    for _ in range(it):
        q = pts[:-1] * 0.75 + pts[1:] * 0.25
        r = pts[:-1] * 0.25 + pts[1:] * 0.75
        mid = np.empty((len(q) * 2, 2))
        mid[0::2], mid[1::2] = q, r
        pts = np.vstack([pts[:1], mid, pts[-1:]])
    return pts


def resample(pts, step):
    seg = np.hypot(*np.diff(pts, axis=0).T)
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    t = np.arange(0.0, cum[-1], step)
    t = np.append(t, cum[-1])
    return np.stack([np.interp(t, cum, pts[:, 0]), np.interp(t, cum, pts[:, 1])], -1)


def sample(h, xs, px, pz):
    n = h.shape[0]
    cell = xs[1] - xs[0]
    gx = np.clip((px - xs[0]) / cell, 0, n - 1.001)
    gz = np.clip((pz - xs[0]) / cell, 0, n - 1.001)
    ix, iz = gx.astype(int), gz.astype(int)
    fx, fz = gx - ix, gz - iz
    return (h[iz, ix] * (1 - fx) * (1 - fz) + h[iz, ix + 1] * fx * (1 - fz)
            + h[iz + 1, ix] * (1 - fx) * fz + h[iz + 1, ix + 1] * fx * fz)


# Creek cross-section on the 2 m grid: a flat bed a little wider than the grid (so it never slips between
# vertices), a bank up to the meadow, then valley sides. Water ~4.5 m wide (small creeks) to ~7 m (the largest).
def creek_profile(d, s, big):
    bed_r, top_r = 1.3 + 0.9 * big, 4.2 + 2.2 * big
    bed, top = s - 0.5, s + 0.9
    return np.where(d < bed_r, bed, np.where(d < top_r, bed + (top - bed) * (d - bed_r) / (top_r - bed_r),
                                             top + (d - top_r) * 0.42))


def carve_creek(h, xs, pts, levels, big, mask):
    cell = xs[1] - xs[0]
    n = h.shape[0]
    reach = 24.0
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        lo = np.minimum(a, b) - reach
        hi = np.maximum(a, b) + reach
        c0, c1 = max(int((lo[0] - xs[0]) / cell), 0), min(int((hi[0] - xs[0]) / cell) + 2, n)
        r0, r1 = max(int((lo[1] - xs[0]) / cell), 0), min(int((hi[1] - xs[0]) / cell) + 2, n)
        X, Z = np.meshgrid(xs[c0:c1], xs[r0:r1])
        seg = b - a
        L2 = max(seg @ seg, 1e-6)
        u = np.clip(((X - a[0]) * seg[0] + (Z - a[1]) * seg[1]) / L2, 0, 1)
        d = np.hypot(X - a[0] - u * seg[0], Z - a[1] - u * seg[1])
        s = levels[i] + (levels[i + 1] - levels[i]) * u
        prof = creek_profile(d, s, big)
        sub = h[r0:r1, c0:c1]
        h[r0:r1, c0:c1] = np.where(d < reach, smin(sub, prof, 0.6), sub)
        mask[r0:r1, c0:c1] = np.maximum(mask[r0:r1, c0:c1], 1.0 - smoothstep(2.5 + big, 5.5 + 2.0 * big, d))


# ------------------------------------------------------------------ fine grid

def upsample2(a):
    """Catmull-Rom 2x upsampling along both axes: n → 2n − 1 samples, the originals kept."""
    def axis0(m):
        p = np.concatenate([m[:1], m, m[-1:]], 0)
        mid = (-p[:-3] + 9.0 * p[1:-2] + 9.0 * p[2:-1] - p[3:]) / 16.0
        out = np.empty((m.shape[0] * 2 - 1,) + m.shape[1:])
        out[0::2] = m
        out[1::2] = mid
        return out
    return axis0(axis0(a).T).T


def channel_distance_runtime(x, z):
    """ForestWorld._channel_distance: horizontal offset from the centre line at the clamped z."""
    d = np.full(x.shape, 1e9)
    for fn, z0, z1 in CHANNELS:
        zc = np.clip(z, z0, z1)
        d = np.minimum(d, np.hypot(x - fn(zc), z - zc))
    return d


def runtime_features(h, x, z, base_at):
    """What ForestWorld._terrain_height used to add per vertex: camp clearings, the spawn terrace, the old camp,
    the river's cut, the fords, the lake basin and the rise into the border mountains."""
    sites = []
    with open(os.path.join(ROOT, "data", "factions.json")) as f:
        for d in json.load(f).values():
            c = d.get("camp", [0, 0])
            sites.append(((float(c[0]), float(c[1])), 10.0))
    for c, wall in REGIONAL_BASES:
        sites.append((c, max(12.0, wall + 6.0)))
    for (cx, cz), r in sites:
        ch = max(base_at(cx, cz), 1.5)
        dc = np.hypot(x - cx, z - cz)
        k = 1.0 - smoothstep(r, r + 12.0, dc)
        h = h * (1.0 - k) + ch * k
    spawn_h = base_at(*SPAWN) - 2.0
    k = (1.0 - smoothstep(45.0, 145.0, np.hypot(x - SPAWN[0], z - SPAWN[1]))) * 0.35
    h = h * (1.0 - k) + spawn_h * k
    k = 1.0 - smoothstep(4.0, 12.0, np.hypot(x - OLD_CAMP[0], z - OLD_CAMP[1]))
    h = h * (1.0 - k) + np.maximum(h, 2.6) * k
    d = channel_distance_runtime(x, z)
    slope = RIVER_VALLEY_SLOPE + 0.08 * fbm(Noise(150), x / 520.0, z / 520.0, 3)
    prof = np.where(d <= RIVER_BANK_START, RIVER_BED,
                    np.where(d <= RIVER_BANK_END,
                             RIVER_BED + (RIVER_BANK_TOP - RIVER_BED) * (d - RIVER_BANK_START) / (RIVER_BANK_END - RIVER_BANK_START),
                             RIVER_BANK_TOP + (d - RIVER_BANK_END) * slope))
    h = smin(h, prof, 8.0)
    main = np.abs(x - river_x(z))
    grit = fbm(Noise(151), x / 6.0, z / 6.0, 2)
    for fz, half_len, bed in FORDS:
        along = np.abs(z - fz)
        k = (1.0 - smoothstep(half_len * 0.6, half_len * 1.7, along)) * (1.0 - smoothstep(20.0, 32.0, main))
        b = bed + 0.08 * grit
        h = h * (1.0 - k) + np.maximum(h, b) * k
        h = np.where(main > 8.0, h * (1.0 - k) + np.minimum(h, b + (main - 8.0) * 0.16) * k, h)
    basin = 1.0 - smoothstep(150.0, 260.0, lake_distance(x, z))
    h = h * (1.0 - basin) - 5.0 * basin
    e = np.maximum(np.abs(x), np.abs(z))
    h = h + np.where(e > PLAYABLE + 4.0, (np.maximum(e - PLAYABLE - 4.0, 0.0) / 96.0) ** 1.5 * 60.0, 0.0)
    return h


# ------------------------------------------------------------------ caves

def cave_shape(c, t):
    """Half-width, roof height and floor height along a cave at t metres from its entrance."""
    L, hw0, H0 = c["length"], c["hw"], c["height"]
    k = smoothstep(L - 2.4 * c["chamber"], L - c["chamber"], t)
    hw = hw0 + (c["chamber"] - hw0) * k
    H = H0 + (c["chamber_height"] - H0) * k
    floor = c["floor0"] - 0.05 * np.maximum(t, 0.0)
    return hw, H, floor


def cave_frame(c):
    a = math.radians(c["dir"])
    d = np.array([math.cos(a), math.sin(a)])
    return np.array(c["entry"]), d, np.array([-d[1], d[0]])


def cave_coords(c, X, Z):
    """(t along the cave, lateral offset) of grid points, t clamped to the carved span."""
    e, d, n = cave_frame(c)
    rx, rz = X - e[0], Z - e[1]
    t = rx * d[0] + rz * d[1]
    lat = rx * n[0] + rz * n[1]
    return t, lat


def carve_caves(hf, X, Z, fx_, mask):
    """Raise the hillside where the roof needs cover, remember it (the roof's outer face), then cut the trench."""
    out = []
    for c in CAVES:
        c = dict(c)
        c["floor0"] = float(sample(hf, fx_, np.array([c["entry"][0]]), np.array([c["entry"][1]]))[0])
        t, lat = cave_coords(c, X, Z)
        L = c["length"]
        tc = np.clip(t, -CAVE_APPROACH, L)
        hw, H, floor = cave_shape(c, tc)
        # distance to the capsule: rounded at the far end
        along = np.where(t > L, t - L, 0.0)
        d = np.hypot(lat, along)
        near = (t > -CAVE_APPROACH - 10.0) & (t < L + c["chamber"] + 12.0) & (d < hw + 14.0)
        # cover over the roofed part (a hump where the hill is too thin), blended out over 10 m
        roofed = smoothstep(CAVE_MOUTH - 0.5, CAVE_MOUTH + 0.5, t)
        need = floor + H + CAVE_COVER + 0.6 * fbm(Noise(170), X / 9.0, Z / 9.0, 2)
        k = roofed * (1.0 - smoothstep(hw + 4.0, hw + 14.0, d))
        hf[:] = np.where(near, np.maximum(hf, hf * (1.0 - k) + np.maximum(hf, need) * k), hf)
        orig = hf.copy()
        # the trench: flat floor, near-vertical walls up to the hillside (rounded at the far end)
        # the floor runs a grid cell past the arch's feet, so the walls rise behind the ceiling, not inside it
        wall = floor + np.maximum(d - hw - 2.3, 0.0) * 4.0
        cut = near & (d < hw + 7.0)
        hf[:] = np.where(cut, np.minimum(hf, wall), hf)
        fine_cell = fx_[1] - fx_[0]
        mask[:] = np.where(near & (d < hw) & (t > -2.0), np.maximum(mask, 1.0), mask)
        # rings for the runtime roof, every 2 m from the mouth past the end (the dome closes over the chamber)
        e, dvec, nvec = cave_frame(c)
        rings = []
        hw_end = float(cave_shape(c, L)[0])
        # past the dome the roof still covers the trench's rounded end and its walls (5 m)
        ts = list(np.arange(CAVE_MOUTH, L, 2.0)) + [L] + [L + hw_end * s for s in (0.35, 0.6, 0.8, 0.93, 1.0)] \
            + [L + hw_end + 2.5, L + hw_end + 5.0, L + hw_end + 7.5]
        for tt in ts:
            if tt <= L:
                rhw, rH, rfl = (float(v) for v in cave_shape(c, tt))
                ctr = e + dvec * tt
            else:  # dome: the ring shrinks over the capsule's rounded end
                rhw0, rH0, rfl = (float(v) for v in cave_shape(c, L))
                f = math.sqrt(max(1.0 - min((tt - L) / hw_end, 1.0) ** 2, 0.0))
                rhw, rH = rhw0 * f, rH0 * f
                ctr = e + dvec * tt
            R = float(cave_shape(c, min(tt, L))[0]) + 7.5
            ls = np.linspace(-R, R, ROOF_SAMPLES)
            px = ctr[0] + nvec[0] * ls
            pz = ctr[1] + nvec[1] * ls
            top = sample(orig, fx_, px, pz)
            rings.append({"t": round(float(tt), 2), "x": round(float(ctr[0]), 2), "z": round(float(ctr[1]), 2),
                          "floor": round(rfl, 2), "hw": round(rhw, 2), "h": round(rH, 2), "r": round(R, 2),
                          "top": [round(float(v), 2) for v in top]})
        out.append({"id": c["id"], "entry": [c["entry"][0], c["entry"][1]], "dir": [round(float(dvec[0]), 5), round(float(dvec[1]), 5)],
                    "floor": round(c["floor0"], 2), "length": L, "mouth": CAVE_MOUTH, "approach": CAVE_APPROACH,
                    "rings": rings})
    return out


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", type=int, default=1025)
    ap.add_argument("--drops", type=int, default=1_500_000)
    ap.add_argument("--preview", default="")
    a = ap.parse_args()
    n = a.size
    xs = np.linspace(-HALF, HALF, n)
    cell = xs[1] - xs[0]
    x, z = np.meshgrid(xs, xs)
    t0 = time.time()
    h, fixed, dr, ld, marsh = landform(x, z)
    print(f"landform {time.time() - t0:.1f}s  {h.min():.1f}..{h.max():.1f} m", flush=True)
    # keep the start terrace and the camps out of the erosion's reach (they are flattened at runtime anyway)
    before = h.copy()
    h, flow, dep = erode(h, fixed, cell, drops=a.drops, steps=80)
    h[fixed] = before[fixed]
    # Full erosion in the hills and mountains, a lighter touch on the lowlands, none on the start terrace.
    w = (0.45 + 0.55 * smoothstep(34.0, 60.0, before)) * smoothstep(150.0, 230.0, np.hypot(x - SPAWN[0], z - SPAWN[1]))
    h = before * (1.0 - w) + h * w
    # No pits: drops never dig more than 18 m, and dry land stays above the water outside the water bodies.
    h = np.maximum(h, before - 18.0)
    # Near the river only light rills: its banks are shaped at runtime.
    h = np.where(dr < 120.0, np.maximum(h, before - 1.0 - 2.0 * smoothstep(40.0, 120.0, dr)), h)
    h = np.where((dr > 16.0) & (ld > 175.0), np.maximum(h, np.minimum(before, 0.8)), h)
    h = thermal(h, cell, talus_deg=46.0, iters=4)
    print(f"eroded {time.time() - t0:.1f}s  {h.min():.1f}..{h.max():.1f} m", flush=True)

    # Re-level the pass floor and the Aruun path after erosion so they stay walkable.
    dp, tp = polyline_distance(x, z, chaikin(np.array(KHARUM_PASS), 3))
    floor = np.interp(tp, [0.0, 0.42, 0.55, 1.0], [36.0, KHARUM_SADDLE, KHARUM_SADDLE, 44.0])
    k = 1.0 - smoothstep(7.0, 16.0, dp)
    h = h * (1.0 - k) + k * np.minimum(h, floor + 0.04 * np.maximum(dp - 9.0, 0.0))

    # Creeks.
    water = (dr < 12.0) | (ld < 150.0)
    # Route over a slightly roughened copy: on gentle ground the creeks then wander instead of running in
    # the D8 grid's straight lines.
    rough = 0.9 * fbm(Noise(140), x / 90.0, z / 90.0, 3) + 0.4 * fbm(Noise(141), x / 30.0, z / 30.0, 2)
    f = fill_depressions(h + rough * smoothstep(60.0, 20.0, h), water)
    print(f"filled {time.time() - t0:.1f}s", flush=True)
    rec = flow_directions(f)
    acc = accumulate(f, rec)
    print(f"accumulated {time.time() - t0:.1f}s", flush=True)
    raw = trace_creeks(h, f, rec, acc, water, cell, xs)
    creeks = []
    inside = lambda p: np.all(np.abs(p) < PLAYABLE - 30.0, axis=1)
    kept = {}
    for ri, c in enumerate(raw):
        parent = kept.get(c["joins"]) if c["joins"] >= 0 else None
        if c["joins"] >= 0 and parent is None:
            continue
        pts = c["pts"]
        keep = inside(pts)
        if keep.sum() < 20:
            continue
        # the marsh has its channels; creeks crossing it on the flat would run in straight lines
        if sample(marsh, xs, pts[:, 0], pts[:, 1]).mean() > 0.35:
            continue
        # drop the part outside the playable square (sources on the border slopes)
        first = int(np.argmax(keep))
        pts = pts[first:]
        pts = resample(chaikin(resample(pts, cell * 3.0), 2), 10.0)
        pts = snap_to_valley(h, xs, pts)
        hs = np.min([sample(h, xs, pts[:, 0] + ox, pts[:, 1] + oz)
                     for ox, oz in ((0, 0), (3, 0), (-3, 0), (0, 3), (0, -3))], axis=0)
        # the receiving water's level: the river / lake (0 m) or the parent creek where they meet
        end = 0.0
        if parent is not None:
            j = np.argmin(np.hypot(parent["pts"][:, 0] - pts[-1, 0], parent["pts"][:, 1] - pts[-1, 1]))
            end = float(parent["levels"][j])
            pts[-1] = parent["pts"][j]
        levels = np.minimum.accumulate(hs - 0.9)  # cut in below the meadow, so flat ground beside it stays dry
        # the last stretch eases into the receiving surface
        tail = np.clip(np.arange(len(levels))[::-1] / 4.0, 0.0, 1.0)
        levels = np.minimum(levels, end + np.maximum(levels - end, 0.0) * tail)
        levels[-1] = end
        levels = np.maximum(levels, end)
        # no cliffs in the water: steeper drops are cut back upstream into a small gorge (≤ 18 % gradient)
        for i in range(len(levels) - 2, -1, -1):
            levels[i] = min(levels[i], levels[i + 1] + 0.18 * float(np.hypot(*(pts[i] - pts[i + 1]))))
        big = float(np.clip((c["catchment"] - 0.35e6) / 1.2e6, 0.0, 1.0))
        creeks.append({"pts": pts, "levels": levels, "big": big, "catchment": c["catchment"],
                       "joins": parent["id"] if parent is not None else -1})
        kept[ri] = creeks[-1]
        creeks[-1]["id"] = len(creeks) - 1
    print(f"{len(creeks)} creeks  {time.time() - t0:.1f}s", flush=True)

    # The final ~2 m grid: upsampled relief with a little fine detail, then everything cut at full resolution.
    hf = upsample2(h)
    fx_ = np.linspace(-HALF, HALF, FINE_N)
    fcell = fx_[1] - fx_[0]
    X, Z = np.meshgrid(fx_, fx_)
    dr_f = channel_distance_runtime(X, Z)
    calm = smoothstep(20.0, 60.0, dr_f) * smoothstep(150.0, 260.0, lake_distance(X, Z))
    hf += (0.28 * fbm(Noise(160), X / 14.0, Z / 14.0, 3) + 0.12 * fbm(Noise(161), X / 5.0, Z / 5.0, 2)) * calm
    print(f"fine grid {time.time() - t0:.1f}s", flush=True)
    mask = np.zeros_like(hf)
    for c in creeks:
        carve_creek(hf, fx_, c["pts"], c["levels"], c["big"], mask)
    # Șanțul Uscat: cut after the creeks are traced, so it stays a dry gully.
    dg, tg = polyline_distance(X, Z, chaikin(np.array(DRY_GULLY), 3))
    dg = dg + 3.0 * fbm(Noise(142), X / 60.0, Z / 60.0, 3)
    hf = hf - 4.5 * (1.0 - smoothstep(4.0, 15.0, dg)) * smoothstep(0.0, 0.08, tg) * (1.0 - smoothstep(0.92, 1.0, tg))
    # Aruun path: a sunken lane at walking slope from the terrace to the river bank.
    dpth, tpth = polyline_distance(X, Z, ARUUN_PATH)
    start_h = sample(hf, fx_, np.array([ARUUN_PATH[0][0]]), np.array([ARUUN_PATH[0][1]]))[0]
    lane = start_h + (2.6 - start_h) * tpth
    k = 1.0 - smoothstep(2.5, 9.0, dpth)
    hf = hf * (1.0 - k) + k * lane
    base = hf.copy()
    hf = runtime_features(hf, X, Z, lambda px, pz: float(sample(base, fx_, np.array([px]), np.array([pz]))[0]))
    caves = carve_caves(hf, X, Z, fx_, mask)
    with open(os.path.join(ROOT, "data", "caves.json"), "w") as fo:
        json.dump({"caves": caves}, fo, indent=1)
    hf = np.round(hf * 100.0) / 100.0  # centimetres: plenty, and the file compresses far better
    print(f"features {time.time() - t0:.1f}s", flush=True)

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "terrain_height.bin"), "wb") as fo:
        fo.write(zlib.compress(hf.astype("<f4").tobytes(), 9))
    fl = np.log1p(flow) / np.log1p(np.percentile(flow, 99.7))
    dp_ = np.log1p(dep * 40.0) / np.log1p(max(np.percentile(dep * 40.0, 99.5), 1e-6))
    creek_m = np.maximum.reduce([mask[0::2, 0::2], np.pad(mask[1::2, 0::2], ((0, 1), (0, 0))),
                                 np.pad(mask[0::2, 1::2], ((0, 0), (0, 1)))])
    m = np.zeros((n, n, 4), np.uint8)
    m[..., 0] = np.clip(creek_m * 255, 0, 255)
    m[..., 1] = np.clip(fl * 255, 0, 255)
    m[..., 2] = np.clip(dp_ * 255, 0, 255)
    m[..., 3] = 255
    write_png(os.path.join(OUT, "T_Terrain_Masks.png"), m)
    streams = []
    for i, c in enumerate(creeks):
        streams.append({
            "id": "creek_%d" % i,
            "joins": ("creek_%d" % c["joins"]) if c["joins"] >= 0 else "",
            "width": round(c["big"], 2),
            "catchment_km2": round(c["catchment"] / 1e6, 2),
            "points": [[round(float(p[0]), 1), round(float(p[1]), 1), round(float(l), 2)]
                       for p, l in zip(c["pts"], c["levels"])],
        })
    with open(os.path.join(ROOT, "data", "streams.json"), "w") as fo:
        json.dump({"size": n, "half": HALF, "streams": streams}, fo, indent=1)
    print(f"wrote {FINE_N}x{FINE_N}  {hf.min():.1f}..{hf.max():.1f} m  {time.time() - t0:.1f}s", flush=True)

    if a.preview:
        h, cell, n = hf[0::2, 0::2], cell, n
        mask = creek_m
        gz, gx = np.gradient(h, cell)
        nrm = np.stack([-gx, np.ones_like(h), -gz], -1)
        nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
        sun = np.array([-0.5, 0.7, -0.5]); sun /= np.linalg.norm(sun)
        lit = np.clip(nrm @ sun, 0, 1)
        t = np.clip(h / 170.0, 0, 1)[..., None]
        col = (np.array([0.42, 0.50, 0.30]) * (1 - t) + np.array([0.62, 0.58, 0.52]) * t) * (0.35 + 0.75 * lit[..., None])
        col[h < 0.05] = [0.15, 0.3, 0.4]
        col[mask > 0.6] = [0.2, 0.4, 0.6]
        img = np.zeros((n, n, 4), np.uint8)
        img[..., :3] = np.clip(col * 255, 0, 255)
        img[..., 3] = 255
        write_png(a.preview, img)


if __name__ == "__main__":
    main()
