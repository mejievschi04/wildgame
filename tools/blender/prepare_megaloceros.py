"""Build the giant deer from the in-game deer GLB, retaining its skin and animation data.

blender -b --factory-startup --python tools/blender/prepare_megaloceros.py -- deer.glb megaloceros.glb
"""
import argparse
from pathlib import Path
import struct
import sys
from tempfile import TemporaryDirectory
import zlib

import bpy
import numpy as np
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path[:0] = [str(SCRIPT_DIR), str(SCRIPT_DIR.parent)]
import fauna_lib as fl
from prepare_bear import read_glb, write_glb


BODY_SCALE = 1.45


def sculpt_antler(side):
    """A rising beam opens into a swept palm with tapered tines along its edge."""
    sculpt = fl.Sculpt()

    def point(p):
        x, y, z = p
        return (side * x - 0.015, y + side * 0.018 * x, z + side * 0.015 * x)

    def branch(points, radii, blend):
        path = [point(p) for p in points]
        for a, b, ra, rb in zip(path[:-1], path[1:], radii[:-1], radii[1:]):
            sculpt.cone(a, b, ra, rb, k=blend)

    def palm(center, radii, pitch, sweep):
        sculpt.ell(point(center), radii, (pitch, side * -12, side * sweep), k=0.057)

    branch([(0.104, 0.985, 1.456), (0.148, 0.954, 1.59), (0.270, 0.87, 1.65),
            (0.435, 0.755, 1.728), (0.618, 0.591, 1.792)], [0.042, 0.051, 0.052, 0.062, 0.066], 0.034)
    palm((0.66, 0.56, 1.825), (0.32, 0.052, 0.144), 16, -24)
    palm((0.815, 0.472, 1.917), (0.225, 0.044, 0.145), 16, -27)
    palm((0.947, 0.365, 1.978), (0.142, 0.032, 0.083), 17, -32)

    # Brow tines project forward over the face, below the crown of the palm.
    branch([(0.158, 0.937, 1.602), (0.183, 1.086, 1.568), (0.237, 1.217, 1.552),
            (0.296, 1.285, 1.593)], [0.037, 0.034, 0.023, 0.008], 0.022)
    branch([(0.26, 0.866, 1.649), (0.319, 0.955, 1.727), (0.369, 1.035, 1.797)],
           [0.038, 0.027, 0.009], 0.023)
    for points, radii in [
        ([(0.48, 0.696, 1.864), (0.492, 0.726, 1.962), (0.467, 0.745, 2.060)], [0.048, 0.028, 0.009]),
        ([(0.63, 0.597, 1.932), (0.649, 0.607, 2.061), (0.616, 0.633, 2.163)], [0.042, 0.030, 0.009]),
        ([(0.762, 0.496, 2.011), (0.791, 0.481, 2.138), (0.758, 0.486, 2.240)], [0.046, 0.029, 0.009]),
        ([(0.900, 0.424, 2.015), (0.949, 0.384, 2.151), (0.946, 0.369, 2.253)], [0.043, 0.025, 0.009]),
        ([(1.001, 0.344, 1.997), (1.107, 0.275, 2.069), (1.188, 0.214, 2.169)], [0.039, 0.024, 0.009]),
        ([(0.977, 0.353, 1.943), (1.078, 0.244, 1.936), (1.194, 0.171, 1.992)], [0.041, 0.023, 0.009]),
        ([(0.791, 0.483, 1.822), (0.876, 0.345, 1.784), (0.969, 0.261, 1.808)], [0.041, 0.024, 0.009]),
    ]:
        branch(points, radii, 0.021)
    return fl.sculpt_to_mesh(sculpt, "Antler", 0.0065, 6200)


def fit_antlers(deer_path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(deer_path))
    rig = next(o for o in bpy.context.scene.objects if o.type == "ARMATURE")
    antlers = next(o for o in bpy.context.scene.objects if o.type == "MESH"
                   and any(m.name == "M_Deer_Antlers" for m in o.data.materials))
    rig.animation_data.use_nla = False
    idle = bpy.data.actions["idle"]
    rig.animation_data.action = idle
    rig.animation_data.action_slot = idle.slots[0]
    bpy.context.scene.frame_set(1)
    transform = antlers.matrix_world.inverted().copy()
    to_local = transform.to_3x3()
    pos, normals, uv, triangles = [], [], [], []
    for side in (-1, 1):
        obj = sculpt_antler(side)
        mesh = obj.data
        mesh.calc_loop_triangles()
        base = len(pos)
        for v in mesh.vertices:
            x, y, z = v.co
            # Project each side into its own half of the atlas. A small depth term lets the
            # grain wrap across the front and back without stretching at the palm edge.
            span = np.clip((abs(x + 0.015) + 0.17 * (y - 0.55)) / 1.27, 0.02, 0.98)
            uv.append(((span + (side > 0)) * 0.5, np.clip((2.30 - z) / 0.9, 0.02, 0.98)))
            p = transform @ v.co
            n = (to_local @ v.normal).normalized()
            pos.append((p.x, p.z, -p.y))
            normals.append((n.x, n.z, -n.y))
        triangles.extend(base + i for tri in mesh.loop_triangles for i in tri.vertices)
    return (np.asarray(pos, "<f4"), np.asarray(normals, "<f4"),
            np.asarray(uv, "<f4"), np.asarray(triangles, "<u2"))


def append_view(model, binary, data):
    binary.extend(b"\0" * (-len(binary) % 4))
    model["bufferViews"].append({"buffer": 0, "byteOffset": len(binary), "byteLength": len(data)})
    binary.extend(data)
    return len(model["bufferViews"]) - 1


def accessor(model, binary, array, kind):
    a = {"bufferView": append_view(model, binary, array.tobytes()), "count": len(array),
         "componentType": 5126 if array.dtype.kind == "f" else (5125 if array.dtype.itemsize == 4 else 5123),
         "type": kind}
    if kind == "VEC3":
        a.update(min=array.min(axis=0).tolist(), max=array.max(axis=0).tolist())
    model["accessors"].append(a)
    return len(model["accessors"]) - 1


def png_image(pixels):
    rgb = np.ascontiguousarray(np.round(np.clip(pixels, 0, 1) * 255), dtype=np.uint8)
    height, width, channels = rgb.shape

    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))

    rows = b"".join(b"\0" + row.tobytes() for row in rgb)
    header = struct.pack(">IIBBBBB", width, height, 8, {3: 2, 4: 6}[channels], 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b"")


def antler_maps(model, binary):
    """Paint weathered bone with dark bases, irregular staining and mineral pores."""
    size = 512
    y, x = np.mgrid[0:size, 0:2*size].astype(np.float32) / size
    side = np.floor(x)
    u = x - side
    rng = np.random.default_rng(21024)

    def noise(columns, rows):
        grid = rng.random((rows + 1, columns + 1))
        gx, gy = x * columns * 0.5, y * rows
        ix, iy = gx.astype(int), gy.astype(int)
        fx, fy = gx - ix, gy - iy
        fx, fy = fx**2 * (3 - 2*fx), fy**2 * (3 - 2*fy)
        lower = grid[iy, ix] * (1-fx) + grid[iy, ix+1] * fx
        upper = grid[iy+1, ix] * (1-fx) + grid[iy+1, ix+1] * fx
        return lower * (1-fy) + upper * fy

    stains = noise(18, 12)
    grain = noise(102, 66)
    micro = noise(248, 157)
    pits = rng.random(x.shape)
    flow = y + 0.29*u + 0.035*np.sin(14*u + side*1.5) + 0.065*stains + 0.011*grain
    grooves = (0.5 + 0.5*np.sin(175*flow))**12 * np.clip(2.5*grain - 0.65, 0, 1)
    polish = np.clip((u - 0.08)*1.08 + (0.66 - y)*0.32 + 0.22*(stains-0.5), 0, 1)
    root = np.array((0.24, 0.175, 0.13))
    palm = np.array((0.405, 0.388, 0.347))
    tone = 0.68 + 0.43*stains + 0.15*grain + 0.08*micro - 0.20*grooves - 0.13*pits**10
    albedo = (root + (palm-root)*polish[..., None]) * tone[..., None]
    heights = 0.10*stains + 0.18*grain + 0.065*micro - 0.24*grooves - 0.095*pits**8
    dv, du = np.gradient(heights)
    normal = np.stack((-du*1.5, dv*1.5, np.ones_like(du)), axis=-1)
    normal /= np.linalg.norm(normal, axis=-1, keepdims=True)
    maps = []
    for name, pixels in (("Antlers_Color", albedo), ("Antlers_Normal", normal*0.5 + 0.5)):
        view = append_view(model, binary, png_image(pixels))
        model["images"].append({"name": name, "bufferView": view, "mimeType": "image/png"})
        model["textures"].append({"source": len(model["images"]) - 1})
        maps.append(len(model["textures"]) - 1)
    return maps


def grade_coat(model, binary, material):
    """Give the stag a charcoal brown coat with warmer tips and a restrained pale face."""
    texture_index = material["pbrMetallicRoughness"]["baseColorTexture"]["index"]
    image_data = model["images"][model["textures"][texture_index]["source"]]
    view = model["bufferViews"][image_data["bufferView"]]
    offset = view.get("byteOffset", 0)
    with TemporaryDirectory() as tmp:
        path = Path(tmp) / "coat.png"
        path.write_bytes(binary[offset:offset + view["byteLength"]])
        image = bpy.data.images.load(str(path))
        pixels = np.empty(len(image.pixels), dtype=np.float32)
        image.pixels.foreach_get(pixels)
        width, height = image.size
        rgb = pixels.reshape(height, width, 4)[::-1, :, :3]
        luma = rgb @ np.array((0.299, 0.587, 0.114), dtype=np.float32)
        # Preserve fine hair contrast and the light rump while removing much of the orange.
        shade = luma ** 1.30
        deep = np.array((0.265, 0.215, 0.19))
        light = np.array((0.81, 0.74, 0.64))
        color = deep + (light - deep) * shade[..., None]
        color *= (0.34 + 0.54 * luma[..., None])
        color += 0.06 * (rgb - luma[..., None])
        image_data["bufferView"] = append_view(model, binary, png_image(color))
        bpy.data.images.remove(image)


def pack_used_images(model, binary):
    # Drop the source antler textures and old, superseded albedo bytes.
    slots = []
    for mat in model["materials"]:
        for container in (mat, mat["pbrMetallicRoughness"]):
            slots.extend(value for key, value in container.items() if key.endswith("Texture"))
    textures = sorted({slot["index"] for slot in slots})
    model["textures"] = [model["textures"][i] for i in textures]
    for slot in slots:
        slot["index"] = textures.index(slot["index"])
    images = sorted({texture["source"] for texture in model["textures"]})
    model["images"] = [model["images"][i] for i in images]
    for texture in model["textures"]:
        texture["source"] = images.index(texture["source"])
    payloads = model["accessors"] + model["images"]
    used = sorted({entry["bufferView"] for entry in payloads})
    packed = bytearray()
    views = [model["bufferViews"][i] for i in used]
    for view in views:
        start = view.get("byteOffset", 0)
        packed.extend(b"\0" * (-len(packed) % 4))
        view["byteOffset"] = len(packed)
        packed.extend(binary[start:start + view["byteLength"]])
    model["bufferViews"] = views
    for entry in payloads:
        entry["bufferView"] = used.index(entry["bufferView"])
    return packed


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("deer", type=Path)
    cli.add_argument("output", type=Path)
    args = cli.parse_args(sys.argv[sys.argv.index("--") + 1:])
    model, block = read_glb(args.deer.resolve())
    binary = bytearray(block[:model["buffers"][0]["byteLength"]])
    pos, normals, uv, indices = fit_antlers(args.deer.resolve())
    material_index = next(i for i, mat in enumerate(model["materials"]) if mat["name"] == "M_Deer_Antlers")
    old_primitive, = (p for m in model["meshes"] for p in m["primitives"] if p.get("material") == material_index)
    old_primitive["attributes"] = {
        "POSITION": accessor(model, binary, pos, "VEC3"),
        "NORMAL": accessor(model, binary, normals, "VEC3"),
        "TEXCOORD_0": accessor(model, binary, uv, "VEC2"),
    }
    old_primitive["indices"] = accessor(model, binary, indices, "SCALAR")
    antler_material = model["materials"][material_index]
    color_map, normal_map = antler_maps(model, binary)
    antler_material["normalTexture"] = {"index": normal_map}
    antler_material["pbrMetallicRoughness"] = {
        "baseColorTexture": {"index": color_map}, "metallicFactor": 0, "roughnessFactor": 0.94,
    }

    for material in model["materials"]:
        if material["name"] in ("M_Deer_Coat", "M_Deer_Head"):
            grade_coat(model, binary, material)
        material["name"] = material["name"].replace("M_Deer_", "M_Megaloceros_")
    scene = model["scenes"][model.get("scene", 0)]
    scene["name"] = "Megaloceros"
    root = model["nodes"][scene["nodes"][0]]
    root["name"] = "Megaloceros"
    root["scale"] = [x * BODY_SCALE for x in root["scale"]]
    root["translation"] = [x * BODY_SCALE for x in root["translation"]]
    # A larger animal covers more ground per stride, so lengthen cycles for its configured movement speeds.
    scaled_times = {}
    for animation in model["animations"]:
        ratio = {"walk": BODY_SCALE * 1.5 / 1.6, "run": BODY_SCALE * 9.5 / 11.0}.get(animation["name"])
        if ratio is None:
            continue
        for sampler in animation["samplers"]:
            i = sampler["input"]
            key = (i, ratio)
            if key not in scaled_times:
                a = model["accessors"][i]
                view = model["bufferViews"][a["bufferView"]]
                offset = view.get("byteOffset", 0) + a.get("byteOffset", 0)
                times = np.frombuffer(binary, dtype="<f4", count=a["count"], offset=offset).copy() * ratio
                scaled_times[key] = accessor(model, binary, times.astype("<f4"), "SCALAR")
                model["accessors"][scaled_times[key]].update(min=[float(times.min())], max=[float(times.max())])
            sampler["input"] = scaled_times[key]
    binary = pack_used_images(model, binary)
    model["buffers"][0]["byteLength"] = len(binary)
    write_glb(args.output, model, binary)
    print(f"Built Megaloceros with {len(indices) // 3} antler triangles and {len(model['animations'])} clips")


if __name__ == "__main__":
    main()
