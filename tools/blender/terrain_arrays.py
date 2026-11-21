# Stacks terrain PBR layers vertically into atlases imported by Godot as Texture2DArray.
#   blender -b --python tools/blender/terrain_arrays.py
import bpy, os, numpy as np
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "art_source", "textures")
OUT = os.path.join(ROOT, "assets", "textures", "terrain")
LAYERS = ["forest_ground_04", "leafy_grass", "brown_mud_leaves_01", "lichen_rock", "ganges_river_pebbles", "snow_02"]
MAPS = {"albedo": "diff", "normal": "nor_gl", "arm": "arm"}
RES = 2048
for out_name, key in MAPS.items():
    stack = []
    for layer in LAYERS:
        img = bpy.data.images.load(os.path.join(SRC, layer, f"{layer}_{key}_2k.jpg"))
        if img.size[0] != RES:
            img.scale(RES, RES)
        px = np.empty(RES * RES * 4, dtype=np.float32)
        img.pixels.foreach_get(px)
        stack.append(px.reshape(RES, RES, 4))
        bpy.data.images.remove(img)
    # Blender stores rows bottom-up: put layer 0 at the TOP of the atlas.
    atlas = np.concatenate(list(reversed(stack)), axis=0)
    out = bpy.data.images.new(out_name, RES, RES * len(LAYERS), alpha=False)
    if key != "diff":
        out.colorspace_settings.name = "Non-Color"
    out.pixels.foreach_set(atlas.ravel())
    out.filepath_raw = os.path.join(OUT, f"T_Terrain_{out_name}.jpg")
    out.file_format = "JPEG"
    bpy.context.scene.render.image_settings.quality = 92
    out.save()
    # Godot's JPEG decoder rejects some Blender-written sRGB JPEGs: re-encode with macOS sips when available.
    import shutil, subprocess
    if shutil.which("sips"):
        tmp = out.filepath_raw + ".tmp.jpg"
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "90", out.filepath_raw, "--out", tmp], check=True, capture_output=True)
        os.replace(tmp, out.filepath_raw)
    print("ATLAS", out_name, atlas.shape)
