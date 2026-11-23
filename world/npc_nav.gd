class_name NpcNav
extends Node
## Walkable navigation meshes around tribe camps and regional bases, baked at runtime (on a worker thread)
## from the terrain and the colliders inside each site: shelters, palisades, racks, rocks, tree trunks and
## the camp fire. NPCs ask for a path between two points; outside every site (hunting trips) they fall back
## to direct steering with local avoidance.

const CELL := 0.25
const TERRAIN_STEP := 2.0
const AGENT_RADIUS := 0.5

var world: ForestWorld
var _sites: Dictionary = {}  # id -> {center: Vector3, radius: float, region: RID, ready: bool}


func _map() -> RID:
	return world.get_world_3d().navigation_map if world and world.is_inside_tree() else RID()


## Bakes (or re-bakes) the walkable area of a site. Safe to call again after structures change.
func add_site(id: String, center: Vector3, radius: float) -> void:
	if world == null or not world.is_inside_tree():
		return
	var site: Dictionary = _sites.get(id, {})
	site.center = center
	site.radius = radius
	site.ready = false
	if not site.has("region"):
		var region := NavigationServer3D.region_create()
		NavigationServer3D.region_set_map(region, _map())
		site.region = region
	_sites[id] = site
	var nav := NavigationMesh.new()
	nav.cell_size = CELL
	nav.cell_height = CELL
	nav.agent_radius = AGENT_RADIUS
	nav.agent_height = 1.75
	nav.agent_max_climb = 0.5
	nav.agent_max_slope = 42.0
	nav.region_min_size = 4.0
	nav.filter_baking_aabb = AABB(center - Vector3(radius, 40.0, radius), Vector3(radius * 2.0, 80.0, radius * 2.0))
	var src := NavigationMeshSourceGeometryData3D.new()
	_add_terrain(src, center, radius)
	_add_obstacles(src, center, radius)
	NavigationServer3D.bake_from_source_geometry_data_async(nav, src, _on_baked.bind(id, nav))


func remove_site(id: String) -> void:
	if not _sites.has(id):
		return
	NavigationServer3D.free_rid(_sites[id].region)
	_sites.erase(id)


func is_ready(id: String) -> bool:
	return _sites.has(id) and bool(_sites[id].ready)


func _on_baked(id: String, nav: NavigationMesh) -> void:
	if not _sites.has(id):
		return
	NavigationServer3D.region_set_navigation_mesh(_sites[id].region, nav)
	_sites[id].ready = true


## The site (if any) whose baked area contains `pos`.
func site_at(pos: Vector3) -> String:
	for id: String in _sites:
		var s: Dictionary = _sites[id]
		if s.ready and Vector2(pos.x - s.center.x, pos.z - s.center.z).length() < float(s.radius) - 1.0:
			return id
	return ""


## Path from → to through a baked site. Empty when neither end is inside one (steer directly instead).
## When the goal lies outside the site, the path ends at the closest walkable point toward it.
func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	if site_at(from) == "" and site_at(to) == "":
		return PackedVector3Array()
	var map := _map()
	if not map.is_valid() or NavigationServer3D.map_get_iteration_id(map) == 0:
		return PackedVector3Array()
	return NavigationServer3D.map_get_path(map, from, to, true)


func _add_terrain(src: NavigationMeshSourceGeometryData3D, center: Vector3, radius: float) -> void:
	var faces := PackedVector3Array()
	var n := int(ceil(radius * 2.0 / TERRAIN_STEP))
	var x0 := center.x - radius
	var z0 := center.z - radius
	for iz in n:
		for ix in n:
			var a := _ground(x0 + ix * TERRAIN_STEP, z0 + iz * TERRAIN_STEP)
			var b := _ground(x0 + (ix + 1) * TERRAIN_STEP, z0 + iz * TERRAIN_STEP)
			var c := _ground(x0 + ix * TERRAIN_STEP, z0 + (iz + 1) * TERRAIN_STEP)
			var d := _ground(x0 + (ix + 1) * TERRAIN_STEP, z0 + (iz + 1) * TERRAIN_STEP)
			if minf(minf(a.y, b.y), minf(c.y, d.y)) < ForestWorld.WATER_LEVEL + 0.15:
				continue  # people don't path through water
			faces.append_array([a, b, c, b, d, c])
	src.add_faces(faces, Transform3D.IDENTITY)


func _ground(x: float, z: float) -> Vector3:
	return world.ground_point(x, z)


## Every solid collider in the site becomes a projected obstruction (its footprint, from the shape bounds).
func _add_obstacles(src: NavigationMeshSourceGeometryData3D, center: Vector3, radius: float) -> void:
	var space := world.get_world_3d().direct_space_state
	var box := BoxShape3D.new()
	box.size = Vector3(radius * 2.0, 30.0, radius * 2.0)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = box
	q.transform = Transform3D(Basis(), center)
	q.collision_mask = 1
	var seen := {}
	for hit: Dictionary in space.intersect_shape(q, 1024):
		var body := hit.collider as CollisionObject3D
		if body == null or seen.has(body) or body.is_in_group("terrain") or body is CharacterBody3D or body is RigidBody3D:
			continue
		seen[body] = true
		for owner_id in body.get_shape_owners():
			var owner := body.shape_owner_get_owner(owner_id) as Node3D
			if owner == null or body.is_shape_owner_disabled(owner_id):
				continue
			for i in body.shape_owner_get_shape_count(owner_id):
				var shape := body.shape_owner_get_shape(owner_id, i)
				if shape is WorldBoundaryShape3D or shape is HeightMapShape3D or shape is ConcavePolygonShape3D:
					continue
				_add_footprint(src, shape, owner.global_transform)
	for fire: Node3D in world.get_tree().get_nodes_in_group("campfire"):
		if fire.global_position.distance_to(center) < radius:
			var ring := PackedVector3Array()
			for k in 10:
				var a := TAU * k / 10.0
				ring.append(fire.global_position + Vector3(cos(a), 0.0, sin(a)) * 0.9)
			src.add_projected_obstruction(ring, fire.global_position.y - 1.0, 3.0, false)


func _add_footprint(src: NavigationMeshSourceGeometryData3D, shape: Shape3D, xf: Transform3D) -> void:
	var aabb := xf * shape.get_debug_mesh().get_aabb()
	var ground := world.ground_point(aabb.get_center().x, aabb.get_center().z).y
	if aabb.end.y < ground + 0.45 or aabb.position.y > ground + 1.8:
		return  # low enough to step over, or high enough to walk under (a lean-to roof edge)
	var local := shape.get_debug_mesh().get_aabb()
	var pts := PackedVector2Array()
	for i in 8:
		var p := xf * local.get_endpoint(i)
		pts.append(Vector2(p.x, p.z))
	var hull := Geometry2D.convex_hull(pts)
	if hull.size() < 3:
		return
	var verts := PackedVector3Array()
	for k in hull.size() - 1:  # convex_hull repeats the first point at the end
		verts.append(Vector3(hull[k].x, 0.0, hull[k].y))
	src.add_projected_obstruction(verts, aabb.position.y - 0.5, aabb.size.y + 1.0, false)


func _exit_tree() -> void:
	for id: String in _sites.keys():
		remove_site(id)
