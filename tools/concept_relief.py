"""Reads the user's concept map (tools/reference/harta_joc.png, 'WILDBOUND - Harta lumii') and turns its painted
landscape into relief inputs for tools/bake_reference_world.py:

  mass   0..1  how mountainous each spot is painted (bare rock, scree and snow = 1, forest a little, meadow 0)
  snow   0..1  the painted snowfields (the north-east range)
  sea    0..1  the painted sea in the south-west

The map is a near top-down painting of the playable square: its width spans x -4000..4000 and its height
z -4000..4000 (north up), the same frame the settlement markers in data/world_layout.json were placed in.
Labels, the legend, the compass, the scale bar and the clouds round the edges are not landscape: they are
masked out and filled in from the ground around them.
"""
import struct
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
MAP = ROOT / "tools/reference/harta_joc.png"
PLAYABLE = 4000.0

# Painted overlays on the 1672 x 941 map: (x0, y0, x1, y1) in map pixels.
OVERLAYS = [
    (0, 0, 430, 115),        # title
    (15, 145, 215, 475),     # legend
    (1530, 0, 1672, 135),    # compass
    (1185, 855, 1610, 925),  # scale bar
    (425, 170, 605, 295),    # Tribul Stancii banner + label
    (1175, 145, 1375, 272),  # Tribul Nordului
    (785, 415, 1005, 498),   # Ruinele orasului Arun
    (1225, 550, 1425, 675),  # Tribul Rosu
    (245, 600, 395, 712),    # Tabara ta
]
NE_SNOW_BOX = (820, 0, 1672, 340)  # the only place where white means snow (elsewhere it is cloud)


def read_png(path):
    """Minimal PNG reader (8-bit RGB/RGBA, non-interlaced): enough for the reference map, no extra packages."""
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _c, _f, interlace = struct.unpack(">IIBBBBB", chunk)
            assert depth == 8 and ctype in (2, 6) and interlace == 0
            ch = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + n
    raw = np.frombuffer(zlib.decompress(idat), np.uint8).reshape(h, 1 + w * ch)
    out = np.zeros((h, w * ch), np.int32)
    prev = np.zeros(w * ch, np.int32)
    for y in range(h):
        f, row = raw[y, 0], raw[y, 1:].astype(np.int32)
        if f == 0:
            cur = row
        elif f == 2:
            cur = (row + prev) & 255
        elif f in (1, 3, 4):  # these depend on the pixel to the left: one pixel at a time
            cur = row.copy()
            for x in range(w * ch):
                a = cur[x - ch] if x >= ch else 0
                if f == 1:
                    cur[x] = (cur[x] + a) & 255
                elif f == 3:
                    cur[x] = (cur[x] + ((a + prev[x]) >> 1)) & 255
                else:
                    b, c = prev[x], (prev[x - ch] if x >= ch else 0)
                    p = a + b - c
                    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                    cur[x] = (cur[x] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        out[y] = cur
        prev = cur
    return (out.reshape(h, w, ch)[..., :3] / 255.0).astype(np.float32)


def box_blur(a, r):
    """Separable box blur, radius r pixels, edges clamped."""
    for axis in (0, 1):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (r + 1, r)
        c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis)
        a = (np.take(c, range(2 * r + 1, c.shape[axis]), axis=axis)
             - np.take(c, range(0, c.shape[axis] - 2 * r - 1), axis=axis)) / (2 * r + 1)
    return a


def soft_blur(a, r):
    return box_blur(box_blur(box_blur(a, r), r), r)  # ~ gaussian


def fill_unknown(values, known, radii=(4, 12, 30, 80)):
    """Normalised convolution: unknown pixels take the blurred average of the known ground around them."""
    out = values.copy()
    have = known.astype(np.float32)
    for r in radii:
        num = soft_blur(np.where(have > 0, out, 0) * have, r)
        den = soft_blur(have, r)
        fill = (have <= 0) & (den > 1e-3)
        out = np.where(fill, num / np.maximum(den, 1e-6), out)
        have = np.where(fill, 1.0, have)
    return out


def classify(img):
    r, g, b = img[..., 0], img[..., 1], img[..., 2]
    mx, mn = img.max(-1), img.min(-1)
    sat = (mx - mn) / np.maximum(mx, 1e-3)
    green = g - (r + b) / 2
    H, W = r.shape
    yy, xx = np.mgrid[0:H, 0:W]
    x0, y0, x1, y1 = NE_SNOW_BOX
    in_ne = (xx >= x0) & (xx < x1) & (yy >= y0) & (yy < y1)
    water = (b > r + 0.05) & (sat > 0.42)                       # sea and rivers (saturated teal/blue)
    snow = in_ne & (mx > 0.6) & (sat < 0.2)
    cloud = ~in_ne & (mx > 0.5) & (sat < 0.16)
    dark = mx < 0.09                                              # vignette and cloud shadow at the edges
    overlay = np.zeros_like(water)
    for ox0, oy0, ox1, oy1 in OVERLAYS:
        overlay[oy0:oy1, ox0:ox1] = True
    forest = (green > 0.03) & (mx < 0.36)
    meadow = (green > 0.015) & ~forest
    # bare rock and scree are warm brown-grey; in the snowy range the shaded slopes are grey-blue too
    rock = ~water & ~forest & ~meadow & (mx > 0.12) & ((r - b > -0.02) | (in_ne & (sat < 0.3)))
    score = np.where(rock | snow, 1.0, np.where(forest, 0.18, 0.0)).astype(np.float32)
    score = np.where(water, 0.0, score)
    # anything else (navy vignette, cloud and its shadow, labels) is not landscape: filled from around it.
    # Painted rivers too: the game's rivers come from data/world_layout.json and cut their own valleys.
    sea_box = (xx < 900) & (yy > 450)
    known = (rock | snow | forest | meadow | (water & sea_box)) & ~(cloud | dark | overlay)
    return score, snow.astype(np.float32), water.astype(np.float32), known


def load():
    """Returns sampler(x, z) -> dict of arrays in world metres: core (rocky cores), range (painted mountain zones),
    wide (whole ranges), snow, sea, painted (the painting's crags, lit vs shaded)."""
    img = read_png(MAP)
    score, snow, water, known = classify(img)
    score = fill_unknown(score, known)
    snow = fill_unknown(snow, known)
    water = fill_unknown(water, known)
    H, W = score.shape
    xx = np.arange(W)[None, :]
    yy = np.arange(H)[:, None]
    lum = img.mean(-1)
    clean = soft_blur(known.astype(np.float32), 3) > .98           # no label text in the crags
    grids = {
        "core": soft_blur(score, 9),            # ~45 m across, ~80 m north-south
        "range": soft_blur(score, 22),
        "wide": soft_blur(score, 45),
        "snow": soft_blur(snow, 25),
        # big water bodies in the south-west only (shaded snow slopes elsewhere read blue too)
        "sea": soft_blur(water * (box_blur(water, 30) > .55) * ((xx < 900) & (yy > 450)), 12),
        "painted": np.clip((lum - soft_blur(lum, 6)) * 4.0, -1, 1) * (score > .5) * clean,
    }

    def sample(grid, x, z):
        px = np.clip((x + PLAYABLE) / (2 * PLAYABLE) * W - 0.5, 0, W - 1.001)
        py = np.clip((z + PLAYABLE) / (2 * PLAYABLE) * H - 0.5, 0, H - 1.001)
        ix, iy = px.astype(int), py.astype(int)
        fx, fy = px - ix, py - iy
        a = grid[iy, ix] * (1 - fx) + grid[iy, ix + 1] * fx
        c = grid[iy + 1, ix] * (1 - fx) + grid[iy + 1, ix + 1] * fx
        return a * (1 - fy) + c * fy

    return lambda x, z: {k: sample(g, x, z) for k, g in grids.items()}
