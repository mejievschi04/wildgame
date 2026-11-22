# Packs icon_1024.png into a multi-size Windows .ico (PNG-compressed entries).
#   blender -b --python tools/launcher/make_ico.py -- icon_1024.png out.ico
import bpy, sys, struct, os, tempfile

src, out = sys.argv[sys.argv.index("--") + 1:][:2]
sizes = [256, 128, 64, 48, 32, 16]
blobs = []
tmp = tempfile.mkdtemp()
for s in sizes:
    img = bpy.data.images.load(src)
    img.scale(s, s)
    p = os.path.join(tmp, "i%d.png" % s)
    img.filepath_raw = p
    img.file_format = "PNG"
    img.save()
    with open(p, "rb") as f:
        blobs.append(f.read())
    bpy.data.images.remove(img)
header = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries = b""
for s, b in zip(sizes, blobs):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
with open(out, "wb") as f:
    f.write(header + entries + b"".join(blobs))
print("ICO", out)
