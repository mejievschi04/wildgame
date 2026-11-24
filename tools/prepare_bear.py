"""Prepare the WildMesh 3D bear for Godot: python3 prepare_bear.py source.glb output.glb."""
import argparse
import json
from pathlib import Path
import struct


CLIPS = {
    "idle": "Stand_Breathing_01",
    "walk": "Walk",
    "run": "Run",
    "graze": "Stand_Eating_01",
    "alert": "StandAngry_Breathing_02",
    "attack": "Attack_Run_01_AttackF",
    "death": "Death_Stand_R01",
}
# Original idle bounds are about 1.77 m high. The game has a 1.45 m capsule.
SCALE = 0.82
# Adapt bone names used for damage regions while keeping joint indices and bind matrices.
BONES = {
    "RigHead_021": "head", "RigJaw_022": "jaw",
    "RigNeck1_019": "neck", "RigNeck2_020": "neck2",
    "RigRigLEar1_027": "ear.L", "RigRigREar1_028": "ear.R",
}
for side, suffixes in {"L": (15, 16, 17, 3, 4, 5), "R": (30, 31, 32, 7, 8, 9)}.items():
    for joint, name, suffix in zip(
        ("FLeg1", "FLeg2", "FLegAnkle", "BLeg1", "BLeg2", "BLegAnkle"),
        ("upperarm", "forearm", "hoof_f", "thigh", "shin", "hoof_h"),
        suffixes,
    ):
        BONES[f"Rig{side}{joint}_0{suffix}"] = f"{name}.{side}"


def read_glb(path):
    with path.open("rb") as f:
        magic, version, _ = struct.unpack("<4sII", f.read(12))
        assert (magic, version) == (b"glTF", 2)
        size, kind = struct.unpack("<I4s", f.read(8))
        assert kind == b"JSON"
        model = json.loads(f.read(size))
        size, kind = struct.unpack("<I4s", f.read(8))
        assert kind == b"BIN\0"
        return model, f.read(size)


def prepare(model, binary, *, species="Bear", scale=SCALE, ground_offset=0.017,
            forward_offset=-0.12, bones=BONES, clips=CLIPS,
            time_scales=None, in_place_clips=("walk", "run", "attack", "death"),
            material_names=("Coat", "Head", "Eyes"), custom_clips=None,
            root_name="RigRoot_01", adjust_clip=None, rotation=(0, 1, 0, 0)):
    if time_scales is None:
        time_scales = {"walk": 0.62, "run": 0.77, "attack": 0.9}
    animations = {clip["name"]: clip for clip in model["animations"]}
    nodes = model["nodes"]
    root = next(i for i, node in enumerate(nodes) if node["name"] == root_name)
    for node in nodes:
        node["name"] = bones.get(node["name"], node["name"])
    scene = model["scenes"][model.get("scene", 0)]
    scene["nodes"], children = [len(nodes)], scene["nodes"]
    scene["name"] = species
    nodes.append({"name": species, "children": children, "rotation": rotation,
                  "scale": [scale] * 3, "translation": [0, ground_offset, forward_offset]})
    for material, name in zip(model["materials"], material_names, strict=True):
        material["name"] = f"M_{species}_{name}"
        extensions = material.get("extensions", {})
        spec = extensions.pop("KHR_materials_pbrSpecularGlossiness", None)
        if spec:
            material["pbrMetallicRoughness"] = {"baseColorTexture": spec["diffuseTexture"],
                                                "metallicFactor": 0, "roughnessFactor": 0.64}
            if not extensions:
                material.pop("extensions")
    for key in ("extensionsUsed", "extensionsRequired"):
        extensions = model.get(key, [])
        extensions = [name for name in extensions if name != "KHR_materials_pbrSpecularGlossiness"]
        if extensions:
            model[key] = extensions
        else:
            model.pop(key, None)

    # Repack only the data used by the seven selected clips and model.
    packed = bytearray()
    views = model["bufferViews"]
    new_views = []
    view_map = {}
    accessors = model["accessors"]
    new_accessors = []
    accessor_map = {}

    def append_view(view, blob):
        packed.extend(b"\0" * (-len(packed) % 4))
        view.update(byteOffset=len(packed), byteLength=len(blob))
        packed.extend(blob)
        result = len(new_views)
        new_views.append(view)
        return result

    def copy_view(index):
        if index in view_map:
            return view_map[index]
        view = views[index].copy()
        start = view.get("byteOffset", 0)
        blob = binary[start:start + view["byteLength"]]
        result = append_view(view, blob)
        view_map[index] = result
        return result

    def read_rows(index):
        ac = accessors[index]
        assert ac["componentType"] == 5126
        fmt = struct.Struct("<" + "f" * {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[ac["type"]])
        view = views[ac["bufferView"]]
        offset = view.get("byteOffset", 0) + ac.get("byteOffset", 0)
        stride = view.get("byteStride", fmt.size)
        return [fmt.unpack_from(binary, offset + i * stride) for i in range(ac["count"])]

    def add_accessor(kind, rows):
        fmt = struct.Struct("<" + "f" * len(rows[0]))
        view = append_view({"buffer": 0}, b"".join(fmt.pack(*row) for row in rows))
        new_accessors.append({"bufferView": view, "componentType": 5126, "type": kind,
                              "count": len(rows), "min": list(map(min, zip(*rows))),
                              "max": list(map(max, zip(*rows)))})
        return len(new_accessors) - 1

    def copy_accessor(index, transform=None, animation=False):
        if transform is None and index in accessor_map:
            return accessor_map[index]
        ac = accessors[index].copy()
        if animation:
            rows = read_rows(index)
            if transform:
                rows = [transform(row) for row in rows]
            result = add_accessor(ac["type"], rows)
        else:
            ac["bufferView"] = copy_view(ac["bufferView"])
            result = len(new_accessors)
            new_accessors.append(ac)
        if transform is None:
            accessor_map[index] = result
        return result

    for mesh in model["meshes"]:
        for primitive in mesh["primitives"]:
            primitive["attributes"] = {key: copy_accessor(i) for key, i in primitive["attributes"].items()}
            primitive["indices"] = copy_accessor(primitive["indices"])
    for skin in model["skins"]:
        skin["inverseBindMatrices"] = copy_accessor(skin["inverseBindMatrices"])
    for image in model["images"]:
        image["bufferView"] = copy_view(image["bufferView"])

    model["animations"] = []
    for name, source in clips.items():
        source_clip = animations[source]
        clip = {"name": name, "channels": [], "samplers": []}
        time_scale = time_scales.get(name)
        time_indices = {}
        for channel in source_clip["channels"]:
            target = channel["target"]
            original = source_clip["samplers"][channel["sampler"]]
            sampler = original.copy()
            time_index = original["input"]
            if time_index not in time_indices:
                time_indices[time_index] = copy_accessor(
                    time_index, (lambda t: (t[0] * time_scale,)) if time_scale else None, animation=True)
            sampler["input"] = time_indices[time_index]
            in_place = (target["node"] == root and target["path"] == "translation"
                        and name in in_place_clips)
            # The source root moves in X/Z. Retain its vertical motion.
            sampler["output"] = copy_accessor(
                original["output"], (lambda p: (0, p[1], 0)) if in_place else None, animation=True)
            clip["channels"].append({"target": target, "sampler": len(clip["samplers"])})
            clip["samplers"].append(sampler)
        if adjust_clip:
            adjust_clip(clip, source_clip, nodes, root, read_rows, add_accessor)
        model["animations"].append(clip)
    if custom_clips:
        model["animations"].extend(custom_clips(nodes, animations, read_rows, add_accessor))

    model["accessors"] = new_accessors
    model["bufferViews"] = new_views
    model["buffers"] = [{"byteLength": len(packed)}]
    return packed


def convert(source, output, **settings):
    model, binary = read_glb(source)
    binary = prepare(model, binary, **settings)
    write_glb(output, model, binary)


def write_glb(output, model, binary):
    metadata = json.dumps(model, separators=(",", ":")).encode()
    metadata += b" " * (-len(metadata) % 4)
    binary.extend(b"\0" * (-len(binary) % 4))
    with output.open("wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, 28 + len(metadata) + len(binary)))
        f.write(struct.pack("<I4s", len(metadata), b"JSON"))
        f.write(metadata)
        f.write(struct.pack("<I4s", len(binary), b"BIN\0"))
        f.write(binary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    convert(args.source, args.output)


if __name__ == "__main__":
    main()
