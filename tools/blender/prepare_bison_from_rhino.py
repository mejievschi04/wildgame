"""Build a bison variant using the textured rhino torso, skeleton and animation clips.

blender -b --factory-startup --python tools/blender/prepare_bison_from_rhino.py -- rhino.glb bison.gltf output.glb
"""
import argparse
import copy
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory

import bpy
import bmesh
import numpy as np
from mathutils import Matrix, Quaternion, Vector
from mathutils.bvhtree import BVHTree
from mathutils.geometry import closest_point_on_tri

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path[:0] = [str(SCRIPT_DIR), str(SCRIPT_DIR.parent)]
from prepare_bear import read_glb, write_glb
from prepare_megaloceros import append_view, accessor, pack_used_images, png_image
from fauna_lib import surface_nets


WIDTHS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
TYPES = {5121: "u1", 5123: "<u2", 5125: "<u4", 5126: "<f4"}


def read_array(model, binary, index):
    a = model["accessors"][index]
    view = model["bufferViews"][a["bufferView"]]
    dtype = np.dtype(TYPES[a["componentType"]])
    width = WIDTHS[a["type"]]
    offset = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = view.get("byteStride", width * dtype.itemsize)
    return np.ndarray((a["count"], width), dtype=dtype, buffer=binary, offset=offset,
                      strides=(stride, dtype.itemsize)).copy()


def posed_skin(model, binary):
    """World skin matrices at the first frame, including the original bind transforms."""
    nodes = [dict(n) for n in model["nodes"]]
    idle = next(a for a in model["animations"] if a["name"] == "idle")
    for channel in idle["channels"]:
        target = channel["target"]
        source = idle["samplers"][channel["sampler"]]["output"]
        nodes[target["node"]][target["path"]] = read_array(model, binary, source)[0]
    world = {}

    def walk(index, parent):
        node = nodes[index]
        if "matrix" in node:
            transform = np.array(node["matrix"]).reshape(4, 4).T
        else:
            x, y, z, w = node.get("rotation", (0, 0, 0, 1))
            transform = np.array(Matrix.LocRotScale(node.get("translation", (0, 0, 0)),
                                 Quaternion((w, x, y, z)), node.get("scale", (1, 1, 1))))
        world[index] = parent @ transform
        for child in node.get("children", []):
            walk(child, world[index])

    for index in model["scenes"][model.get("scene", 0)]["nodes"]:
        walk(index, np.eye(4))
    skin = model["skins"][0]
    bind = read_array(model, binary, skin["inverseBindMatrices"]).reshape(-1, 4, 4).transpose(0, 2, 1)
    return np.array([world[j] for j in skin["joints"]]) @ bind


def point_transform(matrices, points):
    return np.einsum("nij,nj->ni", matrices[:, :3], np.c_[points, np.ones(len(points))])


def mix_skin(matrices, joints, weights):
    return np.sum(matrices[joints] * weights[:, :, None, None], axis=1)


def smooth(lo, hi, values):
    t = np.clip((values-lo)/(hi-lo), 0, 1)
    return t*t*(3-2*t)


def match_coat(data, fur=False):
    """Bring both sets of painted hairs into a shared dark brown palette."""
    with TemporaryDirectory() as directory:
        path = Path(directory) / "coat.png"
        path.write_bytes(data)
        image = bpy.data.images.load(str(path))
        try:
            width, height = image.size
            pixels = np.empty(len(image.pixels), dtype=np.float32)
            image.pixels.foreach_get(pixels)
            rgba = pixels.reshape(height, width, 4)[::-1].copy()
            rgb = rgba[:, :, :3]
            luma = rgb @ np.array((0.2989, 0.587, 0.114), dtype=np.float32)
            shade = np.clip(luma, 0, 1) ** 0.80
            shadows = np.array((0.075, 0.049, 0.033))
            lights = np.array((0.51, 0.39, 0.28))
            rgb[:] = shadows + (lights - shadows)*shade[..., None] + 0.08*(rgb-luma[..., None])
            return png_image(rgba if fur else rgb)
        finally:
            bpy.data.images.remove(image)


def modify_body(model, binary, skin):
    body = model["meshes"][0]["primitives"][0]
    attrs = body["attributes"]
    points = read_array(model, binary, attrs["POSITION"])
    joints = read_array(model, binary, attrs["JOINTS_0"])
    weights = read_array(model, binary, attrs["WEIGHTS_0"])
    matrices = mix_skin(skin, joints, weights)
    posed = point_transform(matrices, points)
    x, z, y = posed.T
    y = -y
    faces = read_array(model, binary, body["indices"]).reshape(-1, 3)
    # Cut the old face at the neck, retaining the shoulder and its skinned fur silhouette.
    cut = 0.825 - 0.095*smooth(0.65, 1.0, z)
    faces = faces[np.all(y[faces] <= cut[faces], axis=1)]
    assert len(faces) > 0
    body["indices"] = accessor(model, binary, faces.ravel().astype("<u2"), "SCALAR")

    # Narrow the haunches and lower legs, but keep the muscular shoulder mass.
    hind = 1 - smooth(-1.12, -0.19, y)
    lower = 1 - smooth(0.11, 0.64, z)
    shoulder = np.exp(-((y-0.11)/0.38)**2)
    x_new = x * (0.96 - 0.17*hind - 0.22*lower)
    z_new = z + 0.14*shoulder*smooth(0.95, 1.66, z) - 0.045*hind*smooth(0.65, 1.43, z)
    # Tuck the lower neck behind the donor's beard so it hides the cut as the head moves.
    tucked = 0.16*smooth(0.47, 0.82, y)*(1-smooth(0.65, 0.93, z))
    reshaped = np.column_stack((x_new, z_new, -(y-tucked)))
    attrs["POSITION"] = accessor(model, binary, point_transform(np.linalg.inv(matrices), reshaped).astype("<f4"), "VEC3")

    return reshaped, faces, joints, weights


def donor_material(model, binary, donor, directory, index):
    mat = copy.deepcopy(donor["materials"][index])
    pbr = mat["pbrMetallicRoughness"]
    is_fur = mat["name"].endswith("_Fur")
    if is_fur:
        pbr["baseColorFactor"] = [0.88, 0.85, 0.83, 1.0]
    elif mat["name"].endswith("_Coat"):
        pbr["baseColorFactor"] = [0.90, 0.87, 0.84, 1.0]
    slots = [v for table in (mat, pbr) for k, v in table.items() if k.endswith("Texture")]
    for slot in slots:
        tex = donor["textures"][slot["index"]]
        image = donor["images"][tex["source"]]
        data = (directory / image["uri"]).read_bytes()
        if slot is pbr.get("baseColorTexture"):
            data = match_coat(data, fur=is_fur)
        view = append_view(model, binary, data)
        model["images"].append({"mimeType": "image/png", "bufferView": view})
        model["textures"].append({"source": len(model["images"]) - 1})
        slot["index"] = len(model["textures"]) - 1
    model["materials"].append(mat)
    return len(model["materials"]) - 1


def trim_fur_cards(xyz, triangles, uv):
    """Select whole cards by their roots and shorten them at the edges of the mane."""
    parents = np.arange(len(xyz))

    def root(i):
        while parents[i] != i:
            parents[i] = parents[parents[i]]
            i = parents[i]
        return i

    for a, b, c in triangles:
        parents[root(b)] = root(a)
        parents[root(c)] = root(a)
    groups = {}
    for i in range(len(xyz)):
        groups.setdefault(root(i), []).append(i)
    result = xyz.copy()
    keep = np.zeros(len(xyz), dtype=bool)
    for ids in groups.values():
        v = uv[ids, 1]
        anchor = xyz[np.asarray(ids)[v >= v.max() - 0.0001]].mean(axis=0)
        y, z = -anchor[2], anchor[1]
        if y < 0.48 or z < 0.73:
            continue
        taper = 0.28 + 0.72 * smooth(0.50, 0.97, y)
        # Short coat around the eyes. Retain the beard below the jaw.
        if y > 1.12 and z > 1.18 and abs(anchor[0]) > 0.11:
            taper *= 0.52
        result[ids] = anchor + (xyz[ids] - anchor) * taper
        keep[ids] = True
    return result, triangles[keep[triangles[:, 0]]]


def blend_shoulder(positions, longitudinal, joints, weights, body_surface):
    """Put the rear collar over the body and share its motion at the overlap."""
    body_points, body_faces, body_joints, body_weights = body_surface
    shoulder = BVHTree.FromPolygons(body_points, body_faces, all_triangles=True)
    amount = 1 - smooth(0.55, 1.02, longitudinal)
    for i in np.flatnonzero(amount > 0.005):
        point, normal, face, distance = shoulder.find_nearest(Vector(positions[i]), 0.44)
        if point is None:
            continue
        strength = amount[i]
        # The very back of the collar sits just beneath the baked body surface.
        offset = 0.035 - 0.055 * strength
        positions[i] = (1-strength)*positions[i] + strength*np.array(point + normal*offset)
        verts = body_faces[face]
        distances = np.linalg.norm(body_points[verts] - np.array(point), axis=1)
        influences = 1 / np.maximum(distances, 0.004)
        influences /= influences.sum()
        combined = np.zeros(int(max(joints[i].max(), body_joints[verts].max())) + 1)
        np.add.at(combined, joints[i], weights[i]*(1-strength))
        np.add.at(combined, body_joints[verts].ravel(), (body_weights[verts]*influences[:, None]*strength).ravel())
        strongest = np.argsort(combined)[-4:][::-1]
        joints[i] = strongest
        weights[i] = combined[strongest] / combined[strongest].sum()


def graft_head(model, binary, skin_matrix, donor_path, body_surface):
    donor = json.loads(donor_path.read_text())
    source = (donor_path.parent / donor["buffers"][0]["uri"]).read_bytes()
    skin = model["skins"][0]
    names = [model["nodes"][i]["name"] for i in skin["joints"]]
    head, neck, jaw, chest = (names.index(name) for name in ("head", "neck", "jaw", "Bone_Spine003_053"))
    material_map = {}
    output = model["meshes"][0]["primitives"]
    for mesh in donor["meshes"]:
        insert = []
        for part in mesh["primitives"]:
            attrs = part["attributes"]
            xyz = read_array(donor, source, attrs["POSITION"])
            triangles = read_array(donor, source, part["indices"]).reshape(-1, 3)
            material = donor["materials"][part["material"]]["name"]
            fur = material.endswith("_Fur")
            uv = read_array(donor, source, attrs["TEXCOORD_0"]) if "TEXCOORD_0" in attrs else None
            if fur:
                xyz, chosen = trim_fur_cards(xyz, triangles, uv)
            else:
                head_region = (xyz[:, 2] < -0.48) & (xyz[:, 1] > 0.72)
                chosen = triangles[np.all(head_region[triangles], axis=1)]
            if not chosen.size:
                continue
            used, remap = np.unique(chosen.ravel(), return_inverse=True)
            xx, zz, yy = xyz[used].T
            yy = -yy
            collar = 1 - smooth(0.74, 1.10, yy)
            hem = 1 - smooth(0.48, 0.76, yy)
            # Sink the rear hem into the shoulder while leaving a thicker collar around the neck.
            xyz = np.column_stack((xx*(1.15 + 0.19*collar - 0.35*hem),
                                   1.10 + (zz-1.20)*(0.90-0.13*hem) - 0.035*collar,
                                   -(0.49 + (yy-0.80)*0.87 - 0.13*collar)))
            # The rear collar follows the neck, the lower muzzle follows the jaw, and
            # the forehead and horns are rigid on the head.
            head_mix = smooth(0.86, 1.21, yy)
            jaw_mix = smooth(1.30, 1.58, yy) * (1 - smooth(0.95, 1.09, zz)) * 0.86
            if material.endswith(("_Horn", "_Eye")):
                head_mix[:] = 1
                jaw_mix[:] = 0
            chest_mix = 1 - smooth(0.65, 0.94, yy)
            neck_mix = (1-head_mix)*(1-jaw_mix)
            weights = np.column_stack((head_mix*(1-jaw_mix), neck_mix*(1-chest_mix), jaw_mix, neck_mix*chest_mix))
            joints = np.tile(np.array((head, neck, jaw, chest), dtype="<u2"), (len(used), 1))
            if not material.endswith(("_Horn", "_Eye")):
                blend_shoulder(xyz, yy, joints, weights, body_surface)
            matrices = mix_skin(skin_matrix, joints, weights)
            positions = point_transform(np.linalg.inv(matrices), xyz)
            normals = read_array(donor, source, attrs["NORMAL"])[used] / (1.15, 0.90, 0.87)
            normals = np.einsum("nij,nj->ni", matrices[:, :3, :3].transpose(0, 2, 1), normals)
            normals /= np.linalg.norm(normals, axis=1, keepdims=True)
            vertex_attrs = {"POSITION": accessor(model, binary, positions.astype("<f4"), "VEC3"),
                            "NORMAL": accessor(model, binary, normals.astype("<f4"), "VEC3"),
                            "JOINTS_0": accessor(model, binary, joints, "VEC4"),
                            "WEIGHTS_0": accessor(model, binary, weights.astype("<f4"), "VEC4")}
            if uv is not None:
                vertex_attrs["TEXCOORD_0"] = accessor(model, binary, uv[used].astype("<f4"), "VEC2")
            if fur:
                edge = smooth(0.50, 0.83, yy)
                vertex_color = np.column_stack((np.ones((len(used), 3)), edge))
                vertex_attrs["COLOR_0"] = accessor(model, binary, vertex_color.astype("<f4"), "VEC4")
            mat_id = part["material"]
            if mat_id not in material_map:
                material_map[mat_id] = donor_material(model, binary, donor, donor_path.parent, mat_id)
            insert.append({"attributes": vertex_attrs, "material": material_map[mat_id],
                           "indices": accessor(model, binary, remap.astype("<u2"), "SCALAR")})
        if not insert:
            continue
        if fur:
            # Separate mesh so Godot can disable fur card shadows without changing the body.
            mesh_index = next(i for i, n in enumerate(model["nodes"]) if n.get("mesh") == 0 and "skin" in n)
            parent = next(n for n in model["nodes"] if mesh_index in n.get("children", []))
            parent["children"].append(len(model["nodes"]))
            model["nodes"].append({"name": "BisonFur", "mesh": len(model["meshes"]), "skin": 0})
            model["meshes"].append({"name": "BisonFur", "primitives": insert})
        else:
            output.extend(insert)


def seal_shell(points, faces):
    """Fill the cut rims after welding coincident UV seam vertices."""
    mesh = bpy.data.meshes.new("Shell")
    mesh.from_pydata(points.tolist(), [], faces.tolist())
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=list(bm.verts), dist=0.0005)
    bmesh.ops.holes_fill(bm, edges=[edge for edge in bm.edges if edge.is_boundary], sides=0)
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(mesh)
    bm.free()
    return mesh


def continuous_hide(body, head):
    """Join the chest and head into a closed mesh, with solid volume inside the throat."""
    parts = [seal_shell(p, f) for p, f in (body, head)]
    bm = bmesh.new()
    membrane = bmesh.ops.create_uvsphere(bm, u_segments=28, v_segments=20, radius=1)
    for v in membrane["verts"]:
        # Stays inside the shoulder and jaw so the gap cannot open in the front view.
        v.co = (v.co.x * 0.255, 0.88 + v.co.y * 0.30, -0.58 + v.co.z * 0.34)
    filler = bpy.data.meshes.new("Throat")
    bm.to_mesh(filler)
    bm.free()
    parts.append(filler)
    samples = []
    for mesh in parts:
        mesh.calc_loop_triangles()
        points = np.array([v.co[:] for v in mesh.vertices])
        faces = np.array([f.vertices[:] for f in mesh.loop_triangles], dtype=np.int32)
        samples.append((points, faces))
        bpy.data.meshes.remove(mesh)
    step = 0.024
    bounds = np.vstack([p[np.unique(f)] for p, f in samples])
    start = bounds.min(axis=0) - step*4
    shape = (np.ceil((bounds.max(axis=0)-start) / step).astype(int) + 5).tolist()
    inside = np.zeros(shape, dtype=bool)

    for points, triangles in samples:
        tree = BVHTree.FromPolygons(points, triangles, all_triangles=True)
        votes = np.zeros(shape, dtype=np.uint8)
        for axis in range(3):
            order = [i for i in range(3) if i != axis] + [axis]
            rays = votes.transpose(order)
            d = np.eye(3)[axis]
            for i, j in np.ndindex(rays.shape[:2]):
                origin = start.copy()
                origin[order[0]] += (i+0.13)*step
                origin[order[1]] += (j+0.31)*step
                hit_indices = []
                for _ in range(60):
                    hit, _, _, _ = tree.ray_cast(Vector(origin), Vector(d))
                    if hit is None:
                        break
                    hit_indices.append((hit[axis]-start[axis])/step)
                    origin[axis] = hit[axis] + step*0.018
                stops = np.ceil(hit_indices).astype(int)
                for first, last in zip(stops[::2], stops[1::2]):
                    rays[i, j, first:last] += 1
        inside |= votes >= 2

    # Close sub-voxel seams and the hollows between decorative tufts before contouring.
    def neighbors(mask, reducer, initial):
        padded = np.pad(mask, 1, constant_values=initial)
        result = np.full_like(mask, initial)
        for i, j, k in np.ndindex(3, 3, 3):
            reducer(result, padded[i:i+shape[0], j:j+shape[1], k:k+shape[2]], out=result)
        return result

    inside = neighbors(neighbors(inside, np.logical_or, False), np.logical_and, True)
    field = np.where(inside, -1., 1.)
    # Smooth the signed field before contouring ambiguous diagonal contacts.
    for axis in range(3):
        field = 0.23*np.roll(field, 1, axis) + 0.54*field + 0.23*np.roll(field, -1, axis)
    points, faces = surface_nets(field, start, step)
    mesh = bpy.data.meshes.new("Continuous Bison Hide")
    mesh.from_pydata(points.tolist(), [], faces.tolist())
    obj = bpy.data.objects.new(mesh.name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    # Smooth the grid edge and discard isolated pieces left by the source coat.
    mesh = obj.data
    bm = bmesh.new()
    bm.from_mesh(mesh)
    unseen = set(bm.verts)
    components = []
    while unseen:
        first = unseen.pop()
        stack, island = [first], [first]
        while stack:
            for edge in stack.pop().link_edges:
                for v in edge.verts:
                    if v in unseen:
                        unseen.remove(v)
                        stack.append(v)
                        island.append(v)
        components.append(island)
    main = max(components, key=len)
    bmesh.ops.delete(bm, geom=[v for island in components if island is not main for v in island], context="VERTS")
    for _ in range(2):
        bmesh.ops.smooth_vert(bm, verts=list(bm.verts), factor=0.35,
                             use_axis_x=True, use_axis_y=True, use_axis_z=True)
    bmesh.ops.triangulate(bm, faces=list(bm.faces))
    bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    bm.to_mesh(mesh)
    bm.free()
    if len(mesh.polygons) > 30000:
        decimate = obj.modifiers.new("Game Mesh", "DECIMATE")
        decimate.ratio = 30000 / len(mesh.polygons)
        bpy.ops.object.modifier_apply(modifier=decimate.name)
        mesh = obj.data
    bm = bmesh.new()
    bm.from_mesh(mesh)
    boundary = [edge for edge in bm.edges if edge.is_boundary]
    if boundary:
        filled = bmesh.ops.holes_fill(bm, edges=boundary, sides=0)["faces"]
        bmesh.ops.triangulate(bm, faces=filled)
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        bm.to_mesh(mesh)
    open_edges = sum(not edge.is_manifold for edge in bm.edges)
    bm.free()
    if open_edges:
        raise ValueError(f"Bison hide must be closed, found {open_edges} non-manifold edges")
    mesh.update()
    return (np.array([v.co[:] for v in mesh.vertices]),
            np.array([v.normal[:] for v in mesh.vertices]),
            np.array([f.vertices[:] for f in mesh.polygons], dtype=np.int32))


def triangle_weights(p, triangle):
    a, b, c = triangle
    v, w, q = b-a, c-a, p-a
    vv, vw, ww = v@v, v@w, w@w
    denom = vv*ww-vw*vw
    if denom < 1e-14:
        return np.array((1.0, 0.0, 0.0))
    t = ((q@v)*ww - (q@w)*vw)/denom
    s = ((q@w)*vv - (q@v)*vw)/denom
    weights = np.clip((1-t-s, t, s), 0, 1)
    return weights / weights.sum()


def transfer_skin(points, sources, count):
    surfaces = [BVHTree.FromPolygons(p, faces, all_triangles=True) for p, faces, _, _ in sources]
    joints = np.empty((len(points), 4), dtype="<u2")
    weights = np.empty((len(points), 4), dtype="<f4")
    for i, point in enumerate(points):
        nearest = [surface.find_nearest(Vector(point)) for surface in surfaces]
        distances = [hit[3] for hit in nearest]
        # Share weights across the old seam where the two sources overlap.
        shares = np.exp(-((np.array(distances)-min(distances)) / 0.082)**2)
        combined = np.zeros(count)
        for (location, _, f, _), (src, faces, js, ws), share in zip(nearest, sources, shares):
            verts = faces[f]
            bary = triangle_weights(np.array(location), src[verts])
            np.add.at(combined, js[verts].ravel(), (ws[verts]*bary[:, None]*share).ravel())
        strongest = np.argsort(combined)[-4:][::-1]
        joints[i] = strongest
        weights[i] = combined[strongest] / combined[strongest].sum()
    return joints, weights


def project_bison_uv(deer_points, triangles, donor_path):
    donor = json.loads(donor_path.read_text())
    data = (donor_path.parent / donor["buffers"][0]["uri"]).read_bytes()
    part = next(p for mesh in donor["meshes"] for p in mesh["primitives"]
                if donor["materials"][p["material"]]["name"] == "M_Bison_Coat")
    attrs = part["attributes"]
    source_points = read_array(donor, data, attrs["POSITION"])
    source_uv = read_array(donor, data, attrs["TEXCOORD_0"])
    src_faces = read_array(donor, data, part["indices"]).reshape(-1, 3)
    source = BVHTree.FromPolygons(source_points, src_faces, all_triangles=True)
    x, z, back = deer_points.T
    y = -back
    projected = np.column_stack((x * 0.84, z * 1.08,
                                 -np.interp(y, [-1.66, -0.85, 0.12, 0.48, 1.32],
                                            [-1.06, -0.72, 0.46, 0.80, 1.72])))
    uv = np.empty((len(projected), 2), dtype="<f4")
    for i, point in enumerate(projected):
        hit, _, index, _ = source.find_nearest(Vector(point))
        verts = src_faces[index]
        uv[i] = triangle_weights(np.array(hit), source_points[verts]) @ source_uv[verts]

    # Split UV edges when adjacent vertices land in different islands of the donor atlas.
    # Share all other vertices so the skinned mesh stays compact.
    face_uv = uv[triangles]
    splits = np.flatnonzero(np.ptp(face_uv, axis=1).max(axis=1) > 0.085)
    extra_uv, duplicate = [], []
    faces = triangles.copy()
    for f in splits:
        _, _, index, _ = source.find_nearest(Vector(projected[faces[f]].mean(axis=0)))
        verts = src_faces[index]
        src = source_points[verts]
        a, b, c = (Vector(p) for p in src)
        for k, v in enumerate(faces[f].copy()):
            point = closest_point_on_tri(Vector(projected[v]), a, b, c)
            extra_uv.append(triangle_weights(np.array(point), src) @ source_uv[verts])
            faces[f, k] = len(uv) + len(duplicate)
            duplicate.append(v)
    if extra_uv:
        uv = np.vstack((uv, np.asarray(extra_uv, "<f4")))
    return uv, faces, np.r_[np.arange(len(projected)), np.asarray(duplicate, dtype=int)]


def replace_hide(model, binary, skin, body, donor_path):
    parts = model["meshes"][0]["primitives"]
    head = next(p for p in parts if model["materials"][p["material"]]["name"] == "M_Bison_Coat")
    attrs = head["attributes"]
    hp, hj, hw = (read_array(model, binary, attrs[key]) for key in ("POSITION", "JOINTS_0", "WEIGHTS_0"))
    head_world = point_transform(mix_skin(skin, hj, hw), hp)
    head_faces = read_array(model, binary, head["indices"]).reshape(-1, 3)
    head = (head_world, head_faces, hj, hw)
    points, normals, tris = continuous_hide(body[:2], head[:2])
    joints, weights = transfer_skin(points, (body, head), len(skin))
    matrices = mix_skin(skin, joints, weights)
    pos = point_transform(np.linalg.inv(matrices), points).astype("<f4")
    normal = np.einsum("nij,nj->ni", matrices[:, :3, :3].transpose(0, 2, 1), normals)
    normal = (normal / np.linalg.norm(normal, axis=1, keepdims=True)).astype("<f4")
    uv, tris, split = project_bison_uv(points, tris, donor_path)
    coat = next(i for i, m in enumerate(model["materials"]) if m["name"] == "M_Bison_Coat")
    parts[:] = [p for p in parts if p["material"] not in (0, coat)]
    parts.insert(0, {
        "attributes": {
            "POSITION": accessor(model, binary, pos[split], "VEC3"),
            "NORMAL": accessor(model, binary, normal[split], "VEC3"),
            "TEXCOORD_0": accessor(model, binary, uv, "VEC2"),
            "JOINTS_0": accessor(model, binary, joints[split], "VEC4"),
            "WEIGHTS_0": accessor(model, binary, weights[split], "VEC4"),
        },
        "indices": accessor(model, binary, tris.ravel().astype("<u4"), "SCALAR"),
        "material": coat,
    })
    # The original rhino surface and its texture are no longer in the exported asset.
    model["materials"].pop(0)
    for mesh in model["meshes"]:
        for part in mesh["primitives"]:
            part["material"] -= 1
    print(f"Closed hide: {len(points)} vertices, {len(tris)} triangles")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("rhino", "bison_head", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:])
    model, data = read_glb(args.rhino)
    binary = bytearray(data[:model["buffers"][0]["byteLength"]])
    matrices = posed_skin(model, binary)
    body_surface = modify_body(model, binary, matrices)
    graft_head(model, binary, matrices, args.bison_head, body_surface)
    replace_hide(model, binary, matrices, body_surface, args.bison_head)
    scene = model["scenes"][model.get("scene", 0)]
    scene["name"] = "Bison"
    model["nodes"][scene["nodes"][0]]["name"] = "Bison"
    binary = pack_used_images(model, binary)
    model["buffers"][0]["byteLength"] = len(binary)
    write_glb(args.output, model, binary)


if __name__ == "__main__":
    main()
