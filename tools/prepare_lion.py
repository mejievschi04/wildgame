"""Make the cave lion from the supplied Smilodon model: the same skeleton and clips, but its own look.

- smaller (about 15 %), clips retimed for the shorter steps and the lion's speeds in data/animals.json;
- sabre teeth cut down to ordinary canines;
- the sabre-cat fur cards removed: the ruff around the neck, the spiky crest on the nape, the crown tuft, the
  cheek tufts and the flange hanging under the chin (ears, eyes and teeth stay);
- its own coat: tawny, no tiger stripes, cream belly and muzzle, dark tail tuft (tools/blender/lion_coat.py).

  blender -b --python tools/blender/lion_coat.py -- smilodon-fractalus.glb art_source/textures/T_Lion_coat.png
  python3 tools/prepare_lion.py smilodon-fractalus.glb assets/models/animals/SK_Lion_Textured.glb \\
      --coat art_source/textures/T_Lion_coat.png
"""
import argparse
from collections import defaultdict
from pathlib import Path
import struct

from prepare_bear import prepare, read_glb, write_glb
from prepare_smilodon import BONES, CLIPS, idle_clip, settle_fall

SMILODON_SCALE = 1.12
SCALE = 0.95                      # about 15 % smaller than the smilodon
CANINE = 0.33                     # sabre length kept as a canine
CANINE_WIDTH = 0.8
# Clip timing. The smilodon walk at 0.95 matches its 1.4 m/s; a smaller body takes shorter steps, so the lion's
# clips run faster by the size ratio. The run is timed to data/animals.json (11 m/s) from the measured ground
# contact speed of the source run (6.66 m/s at the smilodon's scale and 0.75 time scale).
SIZE = SCALE / SMILODON_SCALE
TIME_SCALES = {"walk": round(0.95 * SIZE * 1.35 / 1.4, 3), "run": round(0.75 * SIZE * 6.66 / 11.0, 3)}
# Fur cards between the back of the head and the shoulders, as a fraction of the body length from the nose.
CARD_ZONE = (0.09, 0.32)


def _rows(model, binary, index):
    accessor = model["accessors"][index]
    view = model["bufferViews"][accessor["bufferView"]]
    width = {"SCALAR": 1, "VEC3": 3}[accessor["type"]]
    fmt = {5126: "f", 5125: "I", 5123: "H"}[accessor["componentType"]]
    size = struct.calcsize(fmt)
    stride = view.get("byteStride", size * width)
    offset = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    return [struct.unpack_from("<" + fmt * width, binary, offset + k * stride) for k in range(accessor["count"])], \
        offset, stride, fmt


class Mesh:
    """The source's single skinned primitive split into connected parts (UV seams welded). Local axes: X side,
    Y up, the head towards -Z."""

    def __init__(self, model, binary):
        self.model, self.binary = model, bytearray(binary)
        self.primitive = model["meshes"][0]["primitives"][0]
        self.points, self.offset, self.stride, _ = _rows(model, binary, self.primitive["attributes"]["POSITION"])
        rows, self.index_offset, self.index_stride, self.index_fmt = _rows(model, binary, self.primitive["indices"])
        self.indices = [row[0] for row in rows]
        welded = {}
        weld = [welded.setdefault(tuple(round(c, 4) for c in p), len(welded)) for p in self.points]
        parent = list(range(len(welded)))

        def root(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i

        for t in range(0, len(self.indices), 3):
            a, b, c = (weld[i] for i in self.indices[t:t + 3])
            parent[root(a)] = root(b)
            parent[root(b)] = root(c)
        parts = defaultdict(list)
        for i in range(len(self.points)):
            parts[root(weld[i])].append(i)
        self.part_of = {i: key for key, part in parts.items() for i in part}
        self.body = max(parts.values(), key=len)
        self.others = [p for p in parts.values() if p is not self.body]
        self.lo, self.hi = self.extent(self.body)

    def extent(self, part):
        return ([min(self.points[i][k] for i in part) for k in range(3)],
                [max(self.points[i][k] for i in part) for k in range(3)])

    def front(self, z):
        """0 at the nose, 1 at the tail."""
        return (z - self.lo[2]) / (self.hi[2] - self.lo[2])

    def move(self, i, p):
        self.points[i] = p
        struct.pack_into("<fff", self.binary, self.offset + i * self.stride, *p)

    def drop(self, parts):
        """Remove the triangles of `parts` (their vertices stay, unused)."""
        gone = {self.part_of[p[0]] for p in parts}
        kept = [self.indices[t:t + 3] for t in range(0, len(self.indices), 3)
                if self.part_of[self.indices[t]] not in gone]
        self.indices = [i for tri in kept for i in tri]
        for k, i in enumerate(self.indices):
            struct.pack_into("<" + self.index_fmt, self.binary, self.index_offset + k * self.index_stride, i)
        self.model["accessors"][self.primitive["indices"]]["count"] = len(self.indices)

    def finish(self):
        accessor = self.model["accessors"][self.primitive["attributes"]["POSITION"]]
        accessor["min"] = [min(p[k] for p in self.points) for k in range(3)]
        accessor["max"] = [max(p[k] for p in self.points) for k in range(3)]
        return bytes(self.binary)


def shorten_sabres(mesh):
    """The sabres are two thin vertical shells hanging from the upper jaw: the two parts at the snout that are
    longest relative to their side-to-side thickness. Shrink each towards its root at the gum."""
    height = mesh.hi[1] - mesh.lo[1]

    def slender(part):
        lo, hi = mesh.extent(part)
        if mesh.front(hi[2]) > 0.12:
            return 0
        length = hi[1] - lo[1]
        # side to side only: the sabres curve back, so they are deep but thin
        return length / max(hi[0] - lo[0], 1e-6) if length > 0.08 * height else 0

    sabres = sorted(mesh.others, key=slender, reverse=True)[:2]
    assert all(slender(p) > 2.5 for p in sabres), "sabre teeth not found"
    (la, ha), (lb, hb) = mesh.extent(sabres[0]), mesh.extent(sabres[1])
    assert abs((la[1] + ha[1]) - (lb[1] + hb[1])) < 0.05 * height, "sabres are not a mirrored pair"
    for part in sabres:
        lo, hi = mesh.extent(part)
        pivot = ((lo[0] + hi[0]) / 2, hi[1], (lo[2] + hi[2]) / 2)
        for i in part:
            x, y, z = mesh.points[i]
            mesh.move(i, (pivot[0] + (x - pivot[0]) * CANINE_WIDTH, pivot[1] + (y - pivot[1]) * CANINE,
                          pivot[2] + (z - pivot[2]) * CANINE_WIDTH))


def remove_ruff(mesh):
    """Drop the sabre-cat fur cards between the head and the shoulders, and the chin flange. Ears are the narrow
    cards there (under a tenth of the body width) and stay; teeth sit above the bottom third of the body height."""
    width, height = mesh.hi[0] - mesh.lo[0], mesh.hi[1] - mesh.lo[1]
    cards = []
    for part in mesh.others:
        lo, hi = mesh.extent(part)
        neck = CARD_ZONE[0] <= mesh.front(lo[2]) and mesh.front(hi[2]) <= CARD_ZONE[1] and hi[0] - lo[0] >= 0.1 * width
        chin = mesh.front(hi[2]) < 0.08 and (lo[1] - mesh.lo[1]) / height < 0.32
        if neck or chin:
            cards.append(part)
    assert 7 <= len(cards) <= 13, f"expected the ruff, crest, cheek and chin cards, found {len(cards)}"
    mesh.drop(cards)
    return len(cards)


def replace_coat(model, binary, coat):
    """Swap the base colour image for the lion coat (appended to the buffer; prepare() copies what is used)."""
    data = coat.read_bytes()
    texture = model["materials"][0]["pbrMetallicRoughness"]["baseColorTexture"]["index"]
    image = model["images"][model["textures"][texture]["source"]]
    pad = (-len(binary)) % 4
    model["bufferViews"].append({"buffer": 0, "byteOffset": len(binary) + pad, "byteLength": len(data),
                                 "name": "Lion_coat" + coat.suffix})
    image["bufferView"] = len(model["bufferViews"]) - 1
    image["mimeType"] = "image/png" if coat.suffix == ".png" else "image/jpeg"
    model["buffers"][0]["byteLength"] = len(binary) + pad + len(data)
    return binary + b"\0" * pad + data


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--coat", type=Path, required=True, help="coat texture made by tools/blender/lion_coat.py")
    args = parser.parse_args()
    model, binary = read_glb(args.source)
    mesh = Mesh(model, binary)
    shorten_sabres(mesh)
    cards = remove_ruff(mesh)
    binary = replace_coat(model, mesh.finish(), args.coat)
    binary = prepare(model, binary, species="Lion", scale=SCALE,
                     ground_offset=0.035 * SIZE, forward_offset=0.04 * SIZE, rotation=(0, 0, 0, 1),
                     bones=BONES, clips=CLIPS, custom_clips=idle_clip, root_name="_rootJoint",
                     material_names=("Coat",), time_scales=TIME_SCALES,
                     in_place_clips=(), adjust_clip=settle_fall)
    write_glb(args.output, model, binary)
    print(f"Lion: {cards} fur cards removed, time scales {TIME_SCALES}")


if __name__ == "__main__":
    main()
