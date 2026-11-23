"""Straightens a static (unrigged) animal sculpt before rigging: turns the whole body onto the X axis, then turns the
head back to the midline with a soft blend through the neck, so there is no visible kink.

  Blender -b --factory-startup -P tools/blender/straighten_mesh.py -- in.glb out.glb preview_prefix \
      body_yaw=-10 head_x=0.55 blend=0.25 head_yaw=12 head_roll=0 head_pitch=0 center=1

Axes after glTF import: X = length (head at +X), Y = side, Z = up. Angles in degrees. head_x is where the neck turn
starts (in the straightened body), blend is the length over which it ramps to the full head turn,
head_shift moves the head sideways (metres, same ramp).
"""
import bpy, sys, math
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:]
src, dst, prev = argv[0], argv[1], argv[2]
P = {"body_yaw": 0.0, "head_x": 0.5, "blend": 0.25, "head_yaw": 0.0, "head_roll": 0.0, "head_pitch": 0.0, "head_shift": 0.0, "center": 1.0}
for a in argv[3:]:
    k, v = a.split("=")
    P[k] = float(v)
print("PARAMS", P)

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
o = [x for x in bpy.context.scene.objects if x.type == "MESH"][0]
me = o.data
mw = o.matrix_world.copy()
pts = [mw @ v.co for v in me.vertices]

# 1. whole body yaw about the vertical axis through the centre
c = sum(pts, Vector()) / len(pts)
R = Matrix.Rotation(math.radians(P["body_yaw"]), 3, "Z")
pts = [c + R @ (p - c) for p in pts]

# 2. head turn: rotate the front part about a pivot on the neck, weight ramps from head_x to head_x + blend
lo = min(p.x for p in pts); hi = max(p.x for p in pts)
L = hi - lo
x0 = lo + P["head_x"] * L
x1 = x0 + P["blend"] * L
neck = [p for p in pts if abs(p.x - x0) < 0.02 * L]
piv = sum(neck, Vector()) / max(len(neck), 1)
def smooth(t):
    t = min(max(t, 0.0), 1.0)
    return t * t * (3 - 2 * t)
out = []
for p in pts:
    w = smooth((p.x - x0) / max(x1 - x0, 1e-6))
    if w <= 0.0:
        out.append(p)
        continue
    rot = (Matrix.Rotation(math.radians(P["head_yaw"] * w), 3, "Z")
           @ Matrix.Rotation(math.radians(P["head_pitch"] * w), 3, "Y")
           @ Matrix.Rotation(math.radians(P["head_roll"] * w), 3, "X"))
    out.append(piv + rot @ (p - piv) + Vector((0, P["head_shift"] * w, 0)))
pts = out

# 3. centre the side axis on the spine line (upper half of the torso), feet on z = min
if P["center"] > 0:
    torso = [p for p in pts if lo + 0.25 * L < p.x < lo + 0.7 * L]
    zmid = sorted(p.z for p in torso)[len(torso) // 2]
    up = [p for p in torso if p.z > zmid]
    cy = sum(p.y for p in up) / len(up)
    pts = [Vector((p.x, p.y - cy, p.z)) for p in pts]

inv = mw.inverted()
for v, p in zip(me.vertices, pts):
    v.co = inv @ p
me.update()

# Report symmetry of the result.
from mathutils import kdtree
kd = kdtree.KDTree(len(pts))
for i, p in enumerate(pts):
    kd.insert(p, i)
kd.balance()
def sym(a, b):
    sel = [p for p in pts if lo + a * L <= p.x <= lo + b * L]
    return sum(kd.find(Vector((p.x, -p.y, p.z)))[2] for p in sel) / len(sel) / L * 100
print("SYM overall %.2f%%  head %.2f%%  torso %.2f%%  tail %.2f%%" % (sym(0, 1), sym(0.8, 1), sym(0.3, 0.7), sym(0, 0.2)))

# Preview: orthographic top / front / side with a red midline.
for p in me.polygons:
    p.use_smooth = True
mat = bpy.data.materials.new("clay"); mat.use_nodes = True
mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.62, 0.58, 0.52, 1)
me.materials.clear(); me.materials.append(mat)
red = bpy.data.materials.new("red"); red.use_nodes = True
red.node_tree.nodes["Principled BSDF"].inputs["Emission Color"].default_value = (1, 0.1, 0.05, 1)
red.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 3.0
bpy.ops.mesh.primitive_cube_add(size=1)
line = bpy.context.object
line.scale = (L * 1.3, 0.008, 0.008)
line.location = ((lo + hi) / 2, 0, max(p.z for p in pts) + 0.05)
line.data.materials.append(red)
sc = bpy.context.scene
sc.render.engine = "BLENDER_WORKBENCH"
sc.display.shading.light = "STUDIO"
sc.display.shading.color_type = "MATERIAL"
sc.render.resolution_x = 640; sc.render.resolution_y = 480
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam")); sc.collection.objects.link(cam); sc.camera = cam
cam.data.type = "ORTHO"; cam.data.ortho_scale = L * 1.25
ctr = Vector(((lo + hi) / 2, 0, (min(p.z for p in pts) + max(p.z for p in pts)) / 2))
views = [("top", (0, 0, 10), (0, 0, 0)), ("front", (10, 0, 0), (math.pi / 2, 0, math.pi / 2)),
         ("side", (0, -10, 0), (math.pi / 2, 0, 0))]
for name, off, rot in views:
    cam.location = ctr + Vector(off)
    cam.rotation_euler = rot
    # The midline: along X seen from above, a vertical post seen from the front.
    if name == "front":
        line.scale = (0.008, 0.008, 2.0); line.location = (hi + 0.3, 0, ctr.z)
    else:
        line.scale = (L * 1.3, 0.008, 0.008); line.location = ((lo + hi) / 2, 0, max(p.z for p in pts) + 0.05)
    sc.render.filepath = f"{prev}_{name}.png"
    bpy.ops.render.render(write_still=True)
bpy.data.objects.remove(line)

bpy.ops.object.select_all(action="DESELECT")
o.select_set(True)
bpy.ops.export_scene.gltf(filepath=dst, use_selection=True, export_format="GLB")
print("WROTE", dst)
