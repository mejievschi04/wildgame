# blender -b --python tools/blender/inspect.py -- <gltf paths...>
import bpy, sys, mathutils
paths = sys.argv[sys.argv.index("--") + 1:]
for p in paths:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=p)
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    tris = 0
    mn = mathutils.Vector((1e9,) * 3); mx = -mn
    for o in objs:
        dg = o.evaluated_get(bpy.context.evaluated_depsgraph_get())
        m = dg.to_mesh()
        m.calc_loop_triangles()
        tris += len(m.loop_triangles)
        for v in m.vertices:
            w = o.matrix_world @ v.co
            mn = mathutils.Vector(map(min, mn, w)); mx = mathutils.Vector(map(max, mx, w))
        dg.to_mesh_clear()
    mats = sorted({s.material.name for o in objs for s in o.material_slots if s.material})
    print("INSPECT", p.split("/")[-2], "objs", len(objs), "tris", tris, "size", [round(x, 2) for x in (mx - mn)],
          "min", [round(x, 2) for x in mn], "mats", mats, "names", [o.name for o in objs][:8])
