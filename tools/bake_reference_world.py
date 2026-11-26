#!/usr/bin/env python3
"""Bake the geography in data/world_layout.json. Run with Python and NumPy."""
import json
from pathlib import Path
import zlib

import numpy as np

from gen_backdrop import Noise, fbm, ridged, smoothstep, write_png
import gen_terrain
import concept_relief

ROOT = Path(__file__).resolve().parent.parent
LAYOUT = json.loads((ROOT / "data/world_layout.json").read_text())
OUT = ROOT / "assets/terrain/world_layout"
HALF, PLAYABLE, COARSE = 4200.0, 4000.0, 2049


def river_x(river, z):
    points = np.asarray(river["points"], dtype=float)
    i = np.clip(np.searchsorted(points[:, 0], z), 1, len(points) - 1)
    a, b = points[i - 1], points[i]
    prev = points[np.maximum(i - 2, 0)]
    nxt = points[np.minimum(i + 1, len(points) - 1)]
    span = b[..., 0] - a[..., 0]
    t = np.clip((z - a[..., 0]) / span, 0.0, 1.0)
    da = (b[..., 1] - prev[..., 1]) / (b[..., 0] - prev[..., 0])
    db = (nxt[..., 1] - a[..., 1]) / (nxt[..., 0] - a[..., 0])
    return a[..., 1] + (b[..., 1] - a[..., 1]) * t*t*(3-2*t) + span*t*(1-t)*(da*(1-t)-db*t)


COAST_POINTS = None  # [(x, z)] traced from the painted sea (painted_coast); None = the analytic coast


def painted_coast():
    """The shoreline as drawn on the concept map: for each x, the northmost point of the open sea (the sea lies to
    the south-west). Smoothed a little; written to coast.json for the game (WorldLayout.coast_z)."""
    sampler = concept_relief.load()
    xs = np.arange(-4400.0, 1201.0, 50.0)
    zs = np.arange(-600.0, 4400.0, 8.0)
    out = []
    for x in xs:
        sea = sampler(np.full_like(zs, x), zs)["sea"] > .5
        run = np.convolve(sea, np.ones(6), "valid") >= 6           # solid sea, not a speck
        hit = np.flatnonzero(run)
        out.append(zs[hit[0]] if hit.size else np.nan)
    z = np.array(out)
    ok = ~np.isnan(z)
    # beyond the painted sea (east of the bottom edge) the shore keeps running south-east off the map
    first, last = np.flatnonzero(ok)[[0, -1]]
    z[:first] = z[first] - (xs[first] - xs[:first]) * .6
    z[last + 1:] = z[last] + (xs[last + 1:] - xs[last]) * 1.2
    z = np.convolve(np.pad(z, 3, mode="edge"), np.ones(7) / 7, "valid")
    return [(float(a), float(b)) for a, b in zip(xs, z)]


def coast_z(x):
    if COAST_POINTS is not None:
        px, pz = np.array(COAST_POINTS).T
        x = np.asarray(x, dtype=float)
        lo = pz[0] + (x - px[0]) * (pz[1] - pz[0]) / (px[1] - px[0])
        hi = pz[-1] + (x - px[-1]) * (pz[-1] - pz[-2]) / (px[-1] - px[-2])
        return np.where(x < px[0], lo, np.where(x > px[-1], hi, np.interp(x, px, pz)))
    coast = LAYOUT["coast"]
    dx = x - coast["center_x"]
    return coast["center_z"] + dx * coast["slope"] + 110*np.sin(dx*.0033) + 54*np.sin(dx*.0103+.55)


def mound(x, z, cx, cz, rx, rz):
    return np.exp(-2.0 * (((x - cx) / rx)**2 + ((z - cz) / rz)**2))


# Settlements: (layout key, flat radius, ramp). Mountains fade out around each one, so every town sits on
# level ground with gentle slopes around it (the concept map: ruins in an open central plain, the clans in
# their valleys).
SITES = [("player_camp", 45, 160), ("aruun", 90, 200), ("stone", 75, 220), ("north", 75, 240), ("red", 80, 200)]


def site_clearance(x, z):
    """0 on and right around a settlement, 1 well away from all of them."""
    keep = np.ones_like(x)
    for name, radius, ramp in SITES:
        cx, cz = LAYOUT[name]
        d = np.hypot(x - cx, z - cz)
        keep = np.minimum(keep, smoothstep(radius + 20.0, radius + 20.0 + ramp, d))
    return keep


def river_distance(x, z):
    return np.minimum.reduce([river_band(x, z, r) for r in LAYOUT["rivers"]])


_CONCEPT = None


def relief(x, z):
    """The landforms painted on the user's concept map (tools/reference/harta_joc.png, read by concept_relief.py):
    wherever the map shows bare rock, scree or snow there are mountains, as high as the painted mass is broad
    (the snowy north-east range the highest); forest and meadow stay low, rolling ground. Ridged noise gives the
    crests their shape inside the painted outlines; near rivers and towns the crests drop to foothills."""
    global _CONCEPT
    if _CONCEPT is None:
        _CONCEPT = concept_relief.load()
    c = _CONCEPT(x, z)
    wx = x + fbm(Noise(202), x/1250, z/1250, 3)*260
    wz = z + fbm(Noise(203), x/1250, z/1250, 3)*260
    detail = fbm(Noise(204), x/115, z/115, 4)
    broad = fbm(Noise(205), x/900, z/900, 5)
    rolling = fbm(Noise(207), x/340, z/340, 3)
    ridge = ridged(Noise(206), wx/520, wz/520, 6, gain=.52)
    crest = np.clip((ridge - .2)/.7, 0, 1)
    snowy = np.clip(c["snow"]*2.5, 0, 1)
    # Painted rock fraction: ~0.11 over the plains' forest and meadow, 0.25-0.6 in the ranges.
    mountain = smoothstep(.15, .36, c["range"])                # the painted mountain zones
    core = smoothstep(.2, .62, c["core"])                      # their bare rocky cores
    uplift = smoothstep(.14, .36, c["wide"]) * (35 + 110*snowy)
    fine = np.clip((ridged(Noise(210), wx/190, wz/190, 4) - .25)/.7, 0, 1)   # spurs and gullies on the slopes
    peaks = (mountain*.55 + core*.45) * (240 + 300*snowy) * (.12 + .9*crest + .35*fine)
    hills = (uplift + 25) * (.25*rolling + .1*detail) + c["painted"] * core * 22
    valleys = smoothstep(50.0, 260.0, river_distance(x, z))   # the map's rivers wind through narrow valleys
    open_ground = site_clearance(x, z)
    keep = .3 + .7 * valleys * open_ground
    # On the map the plains' forests stand on low ridges and the meadows lie in the hollows between them.
    woods = smoothstep(.07, .19, c["core"]) * (1 - mountain)
    plain = 17 + broad*7 + rolling*3.5 + detail*1.6 + woods * (14 + 10*rolling) * open_ground
    return plain + uplift + hills + peaks * keep


def river_band(x, z, river):
    points = river["points"]
    sector = np.clip(z, points[0][0], points[-1][0])
    center = river_x(river, sector)
    gradient = (river_x(river, sector+1) - river_x(river, sector-1))*.5
    gradient *= smoothstep(points[0][0], points[0][0]+85, sector)
    gradient *= smoothstep(points[-1][0], points[-1][0]-85, sector)
    nearest = np.hypot((x-center)/np.sqrt(1+gradient**2), z-sector)
    return nearest


def cut_features(h, x, z):
    for river in LAYOUT["rivers"]:
        d = river_band(x, z, river)
        width = river["width"]
        # The source lies in the mountains: there the valley is a narrow gorge that opens out downstream
        # (a 380 m valley all the way up left flat round plates at the river heads).
        z0 = river["points"][0][0]
        opening = smoothstep(z0 - 60.0, z0 + 900.0, z)
        slope = .11 + .5*(1 - opening) + .5*np.clip((h - 60.0)/300.0, 0, 1)  # steep sides in the mountains
        # The valley is as wide as its sides need to climb back to the land around (no walls in high ground).
        reach = np.clip((h - 4.0)/slope, width*1.5, 1200.0)
        valley = (1 - smoothstep(reach*.8, reach*1.15, d)) * .9
        # Valley sides keep a natural, uneven surface instead of a smooth cone.
        rough = fbm(Noise(208), x/160, z/160, 3)
        side = 4 + d*slope*(1 + .45*rough) + 5*fbm(Noise(209), x/55, z/55, 3)
        h = h * (1 - valley) + valley * np.minimum(h, side)
        wobble = np.sin(x*.052+z*.032)*2.0 + np.sin(z*.111)*.8
        bed = -1.65 + np.maximum(d + wobble - width*.44, 0) * .25 \
            + smoothstep(reach*.8, reach*1.25, d) * 2000  # inside the valley only, not a cone over the whole map
        h = np.minimum(h, bed)
    main = LAYOUT["rivers"][0]
    for fz, length in [(-200.0, 9.0), (1510.0, 15.0)]:
        across = np.abs(x - river_x(main, z))
        crossing = (1 - smoothstep(length*.75, length*1.45, np.abs(z-fz))) \
            * (1 - smoothstep(15.0, 28.0, across))
        h += crossing * (np.maximum(h, -.10) - h)
    lx, lz, rx, rz = LAYOUT["lake"]
    basin = np.hypot((x-lx)/rx, (z-lz)/rz)
    h = np.minimum(h, -5 + np.maximum(basin-.72, 0)*23 + smoothstep(2.5, 4.0, basin)*2000)  # local only
    distance = coast_z(x) - z
    beach = np.clip(distance*.063, -37.0, 1000.0) + smoothstep(350.0, 750.0, distance)*2000  # the shore only
    return np.minimum(h, beach)


def flatten_sites(h, x, z, sample):
    for name, radius, ramp in SITES:
        cx, cz = LAYOUT[name]
        distance = np.hypot(x-cx, z-cz)
        flat = 1 - smoothstep(radius*.6, radius+ramp*.6, distance)
        flat *= smoothstep(.3, 2.5, h)  # never lift a river bed, ford or the shore
        h = h + flat * (max(sample(cx, cz), 3.0) - h)
    return h


def bake_streams(h, axis):
    courses = [
        ("western_run", [(-3100,-780),(-2900,-620),(-2610,-470),(-2250,-350),(-1710,-220),(-1120,-120)],
         LAYOUT["rivers"][2], .55),
        ("red_hills_brook", [(2800,760),(2480,660),(2110,500),(1700,370),(1290,255),(620,140)],
         LAYOUT["rivers"][0], .40),
        ("coastal_brook", [(-3250,610),(-3080,780),(-2920,1050),(-2680,1240),(-2250,1400)],
         LAYOUT["rivers"][0], .25),
    ]
    mask = np.zeros_like(h)
    streams = []
    for name, course, parent, width in courses:
        last_z = course[-1][1]
        course[-1] = (float(river_x(parent, last_z)), last_z)
        points = gen_terrain.resample(gen_terrain.chaikin(np.array(course, dtype=float), 3), 12.0)
        levels = np.maximum(0.0, np.minimum.accumulate(gen_terrain.sample(h, axis, points[:,0], points[:,1])-.9))
        levels[-1] = 0.0
        for i in range(len(levels)-2, -1, -1):
            levels[i] = min(levels[i], levels[i+1] + np.linalg.norm(points[i+1]-points[i])*.075)
        gen_terrain.carve_creek(h, axis, points, levels, width, mask)
        streams.append({"id":name,"width":width,"points":np.column_stack((points, levels)).round(2).tolist()})
    (OUT / "streams.json").write_text(json.dumps({"streams":streams}, separators=(",", ":")))
    channels = np.zeros((COARSE,COARSE,4), np.uint8)
    channels[...,0] = (mask[::2,::2]*255).astype(np.uint8)
    channels[...,3] = 255
    write_png(OUT / "masks.png", channels)


def bake_map(h, file):
    n = 1600
    px = 2 * PLAYABLE / n
    coords = -PLAYABLE + (np.arange(n) + .5) * px
    ix = np.rint((coords + HALF) / (2*HALF) * (h.shape[0]-1)).astype(int)
    terrain = h[np.ix_(ix, ix)]
    x, z = np.meshgrid(coords, coords)
    gz, gx = np.gradient(terrain, px)
    normal = np.sqrt(1.0 + (gx*2.2)**2 + (gz*2.2)**2)
    light = np.clip((.68 + gx*.94 + gz*.7) / normal, -.1, 1.2)
    grain = fbm(Noise(211), x/245, z/245, 4)
    forest = smoothstep(.25, .6, grain*.9 + .38) * (1-smoothstep(.52,.88,np.hypot(gx,gz)))
    forest *= (1-smoothstep(205.0,320.0,terrain))
    low = np.array([.37,.42,.20])
    dark = np.array([.10,.24,.15])
    rock = np.array([.58,.49,.37])
    dry = smoothstep(78.0, 230.0, terrain) * (1-.55*forest)
    tint = low + forest[...,None]*(dark-low)
    tint += dry[...,None]*(rock-tint)
    white = np.array([.89,.92,.94])
    snow = smoothstep(170.0,320.0,terrain) * smoothstep(250.,1600.,x) * (1-smoothstep(-2100.,-1350.,z))
    tint += snow[...,None]*(white-tint)
    tint *= (.52 + .69*light + .13*grain)[...,None]
    depth = smoothstep(-1.5,-32.,terrain)
    aqua = np.array([.12,.43,.43])
    deep = np.array([.027,.13,.20])
    water = aqua + depth[...,None]*(deep-aqua)
    tint = np.where((terrain<.12)[...,None],water,tint)
    coast = (np.abs(coast_z(x)-z)<22) & (terrain>0) & (terrain<2)
    tint[coast] = tint[coast]*.50 + np.array([.38,.32,.22])*.50
    img = np.empty((n,n,4), np.uint8)
    img[...,:3] = np.clip(tint*255,0,255)
    img[...,3] = 255
    write_png(file, img)


def main():
    global COAST_POINTS
    OUT.mkdir(parents=True, exist_ok=True)
    COAST_POINTS = painted_coast()
    (OUT / "coast.json").write_text(json.dumps({"points": [[round(a, 1), round(b, 1)] for a, b in COAST_POINTS]},
                                               separators=(",", ":")))
    axis = np.linspace(-HALF, HALF, COARSE, dtype=np.float32)
    x, z = np.meshgrid(axis, axis)
    h = gen_terrain.upsample2(relief(x, z).astype(np.float32))
    size = h.shape[0]
    axis = np.linspace(-HALF, HALF, size, dtype=np.float32)
    cell = float(axis[1]-axis[0])
    # Each town's level: the median of the finished ground (after the coast and river cuts) over its flat disc,
    # so the levelling neither builds a mound nor digs a pit.
    reference = {}
    for name, radius, _ramp in SITES:
        cx, cz = LAYOUT[name]
        ix = np.flatnonzero(np.abs(axis - cx) <= radius)
        iz = np.flatnonzero(np.abs(axis - cz) <= radius)
        px, pz = np.meshgrid(axis[ix], axis[iz])
        inside = np.hypot(px - cx, pz - cz) <= radius
        ground = cut_features(h[np.ix_(iz, ix)].copy(), px, pz)
        reference[name] = float(np.median(ground[inside]))
    height_by_point = {tuple(LAYOUT[name]): value for name,value in reference.items()}
    for start in range(0, size, 180):
        end = min(start+180, size)
        x, z = np.meshgrid(axis, axis[start:end])
        part = cut_features(h[start:end], x, z)
        h[start:end] = flatten_sites(part, x, z, lambda px,pz: height_by_point[px,pz])
    bake_streams(h, axis)
    cave_specs = [
        {"id":"kharum_cave", "entry":(-1840.,-2160.), "dir":260., "length":68.,
         "hw":3., "height":4.2, "chamber":9., "chamber_height":7.5},
        {"id":"varkai_grotto", "entry":(2503.,1414.), "dir":66., "length":28.,
         "hw":2.6, "height":3.6, "chamber":5.5, "chamber_height":4.8},
    ]
    caves = []
    for cave in cave_specs:
        cx, cz = cave["entry"]
        ix = np.flatnonzero(np.abs(axis-cx) < 175)
        iz = np.flatnonzero(np.abs(axis-cz) < 175)
        patch = h[np.ix_(iz, ix)].copy()
        # The cave helper uses one shared square axis, so apply it in translated
        # coordinates and put the saved set of roof rings back in world space.
        count = min(len(iz), len(ix))
        local_axis = np.arange(count)*cell
        px, pz = np.meshgrid(local_axis, local_axis)
        ox, oz = float(axis[ix[0]]), float(axis[iz[0]])
        local = dict(cave, entry=(cx-ox, cz-oz))
        gen_terrain.CAVES = [local]
        patch = patch[:count,:count]
        result = gen_terrain.carve_caves(patch, px, pz, local_axis, np.zeros_like(patch))[0]
        result["entry"] = [cx, cz]
        for ring in result["rings"]:
            ring["x"] += ox
            ring["z"] += oz
        caves.append(result)
        h[np.ix_(iz[:count], ix[:count])] = patch
    (OUT / "caves.json").write_text(json.dumps({"caves":caves}, separators=(",", ":")))
    h = (np.round(h*100)/100).astype("<f4")
    (OUT / "height.bin").write_bytes(zlib.compress(h.tobytes(), 6))
    bake_map(h, OUT / "relief.png")
    for name, center in height_by_point.items():
        print(name, round(center,1))
    print(f"Baked {size}² terrain and 1600² map from the same geography.")


if __name__ == "__main__":
    main()
