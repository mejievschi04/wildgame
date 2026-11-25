"""Adds the player's own clips (crouching, jumping, sprinting, swimming) to the Homo sapiens man.

  .../python3.13 tools/blender/player_clips.py UAL1.glb UAL2.glb [assets/models/humans/SK_Human_SapiensM.gltf]

UAL1/UAL2   the Universal Animation Library's Godot / Unreal-Godot .glb (Quaternius, CC0; art_source/ual/)

The clips come from UAL1 onto the SapiensM skeleton the same way rig_sapiens_ual.py moves its clips over
(rotations as recorded, hips carried at the body's height). The player's capsule moves the body, so no clip
moves the Root. They are written as extra animations named player_* with their own buffer
(SK_Human_SapiensM_player.bin), so running this again replaces them and leaves the NPC clips untouched.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path = [x for x in sys.path if os.path.abspath(x or ".") != HERE]   # tools/blender/inspect.py shadows the stdlib
import inspect  # noqa: E402,F401
import numpy as np  # noqa: E402

sys.path.insert(0, HERE)
import rig_sapiens as rs                                     # noqa: E402
import rig_sapiens_ual as ru                                 # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
# game clip <- (UAL1 clip, loops)
CLIPS = {
    "player_crouch_idle": ("Crouch_Idle_Loop", True),
    "player_crouch_walk": ("Crouch_Fwd_Loop", True),
    "player_sprint": ("Sprint_Loop", True),
    "player_jump_start": ("Jump_Start", False),
    "player_jump_loop": ("Jump_Loop", True),
    "player_jump_land": ("Jump_Land", False),
    "player_swim": ("Swim_Fwd_Loop", True),
    "player_swim_idle": ("Swim_Idle_Loop", True),
}
PREFIX = "player_"


def main():
    a = sys.argv[1:]
    path = a[2] if len(a) > 2 else os.path.join(ROOT, "assets", "models", "humans", "SK_Human_SapiensM.gltf")
    j1, b1 = rs.load(a[0])
    j2, _ = rs.load(a[1])
    jc, bc = rs.load(path)
    S, _ = ru.skel_from_gltf(jc)
    Rg_ual, _ = ru.skel_from_gltf(j2, rename=lambda n: ru.RENAME.get(n, n), drop=lambda n: "leaf" in n)
    for n in ("Root", "pelvis"):
        ru.v_rest[n] = Rg_ual.rest[n][:3, 3]
    ual_pelvis_y = Rg_ual.globals(Rg_ual.rest)["pelvis"][1, 3]
    # the body's bind pose P from its inverse bind matrices (stored column-major)
    skin = jc["skins"][0]
    ibm = rs.acc(jc, bc, skin["inverseBindMatrices"]).reshape(-1, 16)
    names = [jc["nodes"][i]["name"] for i in skin["joints"]]
    P = {n: np.linalg.inv(ibm[k].reshape(4, 4).T) for k, n in enumerate(names)}
    new_pelvis_y = P["pelvis"][1, 3]
    lib1 = ru.gltf_clips(j1, b1, lambda n: ru.RENAME.get(ru.ual1_name(n), ru.ual1_name(n)))

    clips = {}
    for game, (src, _loop) in CLIPS.items():
        c = ru.ual_clip(S, ual_pelvis_y, new_pelvis_y, lib1[src], True)
        c.pop("Root", None)
        clips[game] = c

    # drop an earlier run's clips, accessors and views (they were appended last, on buffer 1)
    jc["animations"] = [an for an in jc.get("animations", []) if not an["name"].startswith(PREFIX)]
    views = jc["bufferViews"]
    keep_views = [k for k, v in enumerate(views) if v["buffer"] == 0]
    assert keep_views == list(range(len(keep_views))), "player views are expected after the body's"
    jc["bufferViews"] = views[:len(keep_views)]
    accs = jc["accessors"]
    n_acc = len([x for x in accs if x.get("bufferView", 0) < len(keep_views)])
    assert all(x.get("bufferView", 0) < len(keep_views) for x in accs[:n_acc])
    jc["accessors"] = accs[:n_acc]
    jc["buffers"] = jc["buffers"][:1]

    o = rs.Out()
    node_of = {jc["nodes"][i]["name"]: i for i in skin["joints"]}
    anims = []
    for game, clip in clips.items():
        samplers, chans = [], []
        for n, tr in clip.items():
            for p, (t, v) in tr.items():
                typ = "VEC4" if p == "rotation" else "VEC3"
                samplers.append({"input": o.add(t.astype(np.float32), "SCALAR", minmax=True),
                                 "output": o.add(v.astype(np.float32), typ), "interpolation": "LINEAR"})
                chans.append({"sampler": len(samplers) - 1, "target": {"node": node_of[n], "path": p}})
        anims.append({"name": game, "samplers": samplers, "channels": chans})
    # Out numbers its accessors and views from 0 on its own buffer: shift them after the body's
    acc0, view0 = len(jc["accessors"]), len(jc["bufferViews"])
    for v in o.views:
        v["buffer"] = 1
    for x in o.accs:
        x["bufferView"] += view0
    for an in anims:
        for s in an["samplers"]:
            s["input"] += acc0
            s["output"] += acc0
    jc["bufferViews"] += o.views
    jc["accessors"] += o.accs
    jc["animations"] += anims
    base = os.path.splitext(os.path.basename(path))[0] + "_player.bin"
    jc["buffers"].append({"byteLength": len(o.buf), "uri": base})
    open(os.path.join(os.path.dirname(os.path.abspath(path)), base), "wb").write(o.buf)
    json.dump(jc, open(path, "w"), indent=1)
    for game, clip in clips.items():
        print("clip", game, f"{ru.clip_len(clip):.2f} s")


if __name__ == "__main__":
    main()
