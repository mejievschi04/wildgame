"""Prepare the supplied Smilodon model and animation clips for the game."""
import argparse
import math
from pathlib import Path

from prepare_bear import convert
from prepare_elk import multiply


CLIPS = {
    "walk": "Stalker", "run": "Run", "graze": "Eating",
    "alert": "Roaring", "attack": "Attack", "death": "Layout",
}
BONES = {
    "Sabrecat_Head__Head__035": "head", "Sabrecat_Head_jaw__041": "jaw",
    "Sabrecat_Neck_Nek0__032": "neck", "Sabrecat_Neck_Nek1__033": "neck2",
    "Sabrecat_HeadLeftEar_LEar__038": "ear.L", "Sabrecat_HeadRightEar_REar__043": "ear.R",
    "Sabrecat_LeftUpperArm_LUar__061": "upperarm.L", "Sabrecat_RightUpperArm_RUar__047": "upperarm.R",
    "Sabrecat_LeftForearm_LFar__062": "forearm.L", "Sabrecat_RightForearm_RFar__048": "forearm.R",
    "Sabrecat_LeftHand_LHnd__064": "hand.L", "Sabrecat_RightHand_RHnd__050": "hand.R",
    "Sabrecat_LeftThigh_LThi__012": "thigh.L", "Sabrecat_RightThigh_RThi__017": "thigh.R",
    "Sabrecat_LeftCalf_LClf__013": "shin.L", "Sabrecat_RightCalf_RClf__018": "shin.R",
    "Sabrecat_LeftFoot_LFot__014": "hoof_h.L", "Sabrecat_RightFoot_RFot__019": "hoof_h.R",
    "Sabrecat_Tail0_Tal0__022": "tail",
}


def idle_clip(nodes, animations, read_rows, add_accessor):
    """Use the standing pose at the start of Layout, with a small head and tail motion."""
    source = animations["Layout"]
    duration = 4.0
    times = (0.0, 1.0, 2.0, 3.0, duration)
    motion = {"neck2": (0, 2, 0, -2, 0), "head": (0, -1, 0, 1, 0),
              "tail": (0, -4, 0, 4, 0)}
    idle = {"name": "idle", "channels": [], "samplers": []}
    held_time = add_accessor("SCALAR", [(0,), (duration,)])
    motion_time = add_accessor("SCALAR", [(t,) for t in times])
    for channel in source["channels"]:
        target = channel["target"]
        index = source["samplers"][channel["sampler"]]["output"]
        pose = read_rows(index)[0]
        name = nodes[target["node"]]["name"]
        rotation = target["path"] == "rotation"
        rows = [pose, pose]
        time = held_time
        if rotation and name in motion:
            half_angles = [math.radians(angle) / 2 for angle in motion[name]]
            rows = [multiply(pose, (0, 0, math.sin(a), math.cos(a))) for a in half_angles]
            time = motion_time
        idle["channels"].append({"target": target, "sampler": len(idle["samplers"])})
        idle["samplers"].append({"input": time, "output": add_accessor("VEC4" if rotation else "VEC3", rows),
                                 "interpolation": "LINEAR"})
    yield idle


def settle_fall(clip, source, nodes, root, read_rows, add_accessor):
    if clip["name"] != "death":
        return
    # The source position of the torso dips below the standing ground plane at the end.
    times = [(0,), (0.7,), (1.15,), (1.6,), (2.0,)]
    lift = [(0, y, 0) for y in (0, 0, 3, 8, 8)]
    clip["channels"].append({"target": {"node": root, "path": "translation"}, "sampler": len(clip["samplers"])})
    clip["samplers"].append({"input": add_accessor("SCALAR", times),
                             "output": add_accessor("VEC3", lift), "interpolation": "LINEAR"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    convert(args.source, args.output, species="Smilodon", scale=1.12,
            ground_offset=0.035, forward_offset=0.04, rotation=(0, 0, 0, 1),
            bones=BONES, clips=CLIPS, custom_clips=idle_clip, root_name="_rootJoint",
            material_names=("Coat",), time_scales={"walk": 0.95, "run": 0.75},
            in_place_clips=(), adjust_clip=settle_fall)


if __name__ == "__main__":
    main()
