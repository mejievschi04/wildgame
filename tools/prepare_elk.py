"""Prepare the WildMesh 3D elk for the game's deer slot."""
import argparse
import math
from pathlib import Path

from prepare_bear import convert


CLIPS = {
    "idle": "Stand_Breathing_01",
    "walk": "Walk",
    "run": "Run",
    "graze": "Stand_Eating_01",
    "death": "Death_Stand_R01",
}
BONES = {
    "RigHead_00": "head", "RigJaw1_022": "jaw", "RigNeck1_019": "neck",
    "RigNeck2_020": "neck2", "RigNeck3_021": "neck3",
    "RigLEar1_026": "ear.L", "RigREar1_028": "ear.R",
}
for side, suffixes in {"L": (15, 16, 17, 18, 3, 4, 5, 6),
                       "R": (31, 32, 33, 34, 7, 8, 9, 10)}.items():
    for joint, name, suffix in zip(
        ("FLeg1", "FLeg2", "FLeg3", "FLegAnkle", "BLeg1", "BLeg2", "BLeg3", "BLegAnkle"),
        ("upperarm", "forearm", "hoof_f", "hoof_f_toe", "thigh", "shin", "hoof_h", "hoof_h_toe"),
        suffixes,
    ):
        BONES[f"Rig{side}{joint}_0{suffix}"] = f"{name}.{side}"


def multiply(a, b):
    x, y, z, w = a
    u, v, t, s = b
    return (w*u + x*s + y*t - z*v, w*v - x*t + y*s + z*u,
            w*t + x*v - y*u + z*s, w*s - x*u - y*v - z*t)


def inverse(q):
    x, y, z, w = q
    return (-x, -y, -z, w)


def pose_clips(nodes, source, read_rows, add_accessor):
    """Animate a raised alert pose and an antler thrust from the source standing pose."""
    idle = source[CLIPS["idle"]]
    standing = {}
    for channel in idle["channels"]:
        target = channel["target"]
        accessor = idle["samplers"][channel["sampler"]]["output"]
        standing[target["node"], target["path"]] = read_rows(accessor)[0]
    parents = {child: i for i, node in enumerate(nodes[:-1]) for child in node.get("children", [])}

    def world_rotation(i):
        if i not in parents:
            return (0, 0, 0, 1)
        rotation = standing.get((i, "rotation"), nodes[i].get("rotation", (0, 0, 0, 1)))
        return multiply(world_rotation(parents[i]), rotation)

    actions = {
        "alert": ((0, 0.25, 0.95, 1.55, 2.0),
                  {"neck": (0, -11, -8, -12, 0), "head": (0, -8, -12, -6, 0)}),
        "attack": ((0, 0.24, 0.48, 0.68, 1.1),
                   {"neck": (0, -8, 26, 17, 0), "neck2": (0, -5, 14, 8, 0),
                    "head": (0, -5, 23, 10, 0)}),
    }
    for name, (times, angles) in actions.items():
        clip = {"name": name, "channels": [], "samplers": []}
        animated_time = add_accessor("SCALAR", [(t,) for t in times])
        held_time = add_accessor("SCALAR", [(0,), (times[-1],)])
        for (i, path), value in standing.items():
            node_name = nodes[i]["name"]
            time = held_time
            rows = [value, value]
            if path == "rotation" and node_name in angles:
                # Source +Z is forward. Pitch about the model's lateral axis in parent space.
                parent_rotation = world_rotation(parents[i])
                axis = multiply(multiply(inverse(parent_rotation), (1, 0, 0, 0)), parent_rotation)
                rows = []
                for angle in angles[node_name]:
                    half = math.radians(angle) / 2
                    pitch = (*[component * math.sin(half) for component in axis[:3]], math.cos(half))
                    rows.append(multiply(pitch, value))
                time = animated_time
            output = add_accessor("VEC4" if path == "rotation" else "VEC3", rows)
            clip["channels"].append({"target": {"node": i, "path": path}, "sampler": len(clip["samplers"])})
            clip["samplers"].append({"input": time, "output": output, "interpolation": "LINEAR"})
        yield clip


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    convert(args.source, args.output, species="Deer", scale=0.87, ground_offset=0.006,
            forward_offset=-0.10, bones=BONES, clips=CLIPS, custom_clips=pose_clips,
            material_names=("Head", "Eyes", "Coat", "Antlers"),
            time_scales={"walk": 0.97, "run": 1.15},
            in_place_clips=("walk", "run", "graze", "death"))


if __name__ == "__main__":
    main()
