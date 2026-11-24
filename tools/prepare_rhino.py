"""Prepare the supplied woolly rhinoceros for the game's rhino slot."""
import argparse
from pathlib import Path

from prepare_bear import prepare, read_glb, write_glb


CLIPS = {
    "idle": "Drone_Idle",
    "walk": "Drone_Walk",
    "run": "Drone_Jog",
    "graze": "Sanc_Eat_HayBall",
    "alert": "Battle_SpecialCast_Roar",
    "attack": "Battle_Attk",
    "death": "Battle_Death",
}
BONES = {
    "Bone_Head_021": "head", "Bone_Jaw_022": "jaw", "Bone_Neck1_FK_042": "neck",
    "Bone_L_Ear_036": "ear.L", "Bone_R_Ear_044": "ear.R",
    "Bone_FL_UpLeg_00": "upperarm.L", "Bone_FR_UpLeg_020": "upperarm.R",
    "Bone_FL_Leg_012": "forearm.L", "Bone_FR_Leg_017": "forearm.R",
    "Bone_FL_Foot_010": "hoof_f.L", "Bone_FR_Foot_015": "hoof_f.R",
    "Bone_L_UpLeg_041": "thigh.L", "Bone_R_UpLeg_049": "thigh.R",
    "Bone_L_Leg_039": "shin.L", "Bone_R_Leg_047": "shin.R",
    "Bone_L_Foot_037": "hoof_h.L", "Bone_R_Foot_045": "hoof_h.R",
}


def limit_stationary_travel(clip, source, nodes, root, read_rows, add_accessor):
    if clip["name"] not in ("graze", "death"):
        return
    # The source animates its limbs and pelvis directly under the same root.
    # Counter large offsets at that shared root so all weighted parts move together.
    pelvis = next(i for i, node in enumerate(nodes) if node["name"] == "Bone_Pelvis_043")
    channel = next(c for c in source["channels"] if c["target"] == {"node": pelvis, "path": "translation"})
    sampler = source["samplers"][channel["sampler"]]
    times = read_rows(sampler["input"])
    positions = read_rows(sampler["output"])
    start_x, _, start_z = positions[0]
    rows = []
    for (time,), (x, _, z) in zip(times, positions, strict=True):
        if clip["name"] == "death":
            settle = min(time / 1.0, 1.0)
            # The imported fall sinks about 10 cm at source scale.
            rows.append((max(0, start_x - x - 0.55), 0, 0.17 * settle))
        else:
            # A short feeding step is part of the original cycle.
            rows.append((0, max(0, z - start_z - 0.45), 0))
    clip["channels"].append({"target": {"node": root, "path": "translation"}, "sampler": len(clip["samplers"])})
    clip["samplers"].append({"input": add_accessor("SCALAR", times),
                             "output": add_accessor("VEC3", rows), "interpolation": "LINEAR"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    model, binary = read_glb(args.source)
    # Low alpha on the painted feet hides them when treated as a transparency mask.
    model["materials"][0]["alphaMode"] = "OPAQUE"
    binary = prepare(model, binary, species="Rhino", scale=1.2, ground_offset=0.011,
                     forward_offset=1.10, bones=BONES, root_name="Bone_Root_01",
                     clips={key: "Anim_026_" + name for key, name in CLIPS.items()},
                     material_names=("Coat",), time_scales={"run": 0.40, "attack": 0.95},
                     in_place_clips=(), adjust_clip=limit_stationary_travel)
    write_glb(args.output, model, binary)


if __name__ == "__main__":
    main()
