extends RefCounted
## Authored districts on the baked terrain. Architecture is deterministic scenery; the
## surrounding interactive fires, supplies and people keep their normal save IDs.

const Detail := preload("res://world/settlement_detail.gd")

const PLANS := {
	"aruun": {"radius": 65.0, "style": "red", "districts": [
		["sacred_hearth", Vector2(-23, -13), "hearth"],
		["homes", Vector2(-26, 27), "homes"],
		["workshops", Vector2(17, 32), "workshops"],
		["occupied_quarter", Vector2(31, -18), "garrison"],
	]},
	"varkai": {"radius": 62.0, "style": "red", "districts": [
		["chiefs_hall", Vector2(-31, -16), "hall"],
		["barracks", Vector2(28, -21), "garrison"],
		["workers_quarter", Vector2(27, 24), "workshops"],
		["homes", Vector2(-22, 28), "homes"],
	]},
	"kharum": {"radius": 54.0, "style": "stone", "districts": [
		["stone_hall", Vector2(-6, -30), "hall"],
		["terrace_homes", Vector2(-27, 13), "homes"],
		["stonecutters", Vector2(24, 18), "workshops"],
	]},
	"north": {"radius": 57.0, "style": "north", "districts": [
		["winter_hearth", Vector2(-26, -12), "hall"],
		["hide_shelters", Vector2(24, -8), "homes"],
		["winter_stores", Vector2(-6, 28), "stores"],
	]},
}


static func radius(id: String) -> float:
	return float(PLANS[id].radius)


static func build(world: ForestWorld, city: Node3D, id: String, center: Vector2,
		keep_radius: float) -> Array[Vector2]:
	var plan: Dictionary = PLANS[id]
	var districts: Array = plan.districts
	var roads := SurfaceTool.new()
	roads.begin(Mesh.PRIMITIVE_TRIANGLES)
	var posts: Array[Vector2] = []
	if keep_radius > 0.0:
		var ring := keep_radius + 3.6
		for i in 24:
			var a := center + Vector2.from_angle(TAU * i / 24.0) * ring
			var b := center + Vector2.from_angle(TAU * (i + 1) / 24.0) * ring
			_road(roads, world, a, b, 3.6)
		_road(roads, world, center + Vector2(2.0, 0.0), center + Vector2(ring, 0.0), 3.9)
		if id != "varkai":
			_road(roads, world, center - Vector2(2.0, 0.0), center - Vector2(ring, 0.0), 3.9)
	for row: Array in districts:
		var district := Node3D.new()
		district.name = String(row[0]).capitalize().replace(" ", "")
		city.add_child(district)
		var hub: Vector2 = center + row[1]
		var outward := (hub - center).normalized()
		var side := Vector2(-outward.y, outward.x)
		var role: String = row[2]
		posts.append(hub)
		var junction := center + outward * (keep_radius + 3.6 if keep_radius > 0.0 else 2.4)
		_road(roads, world, junction, hub, 3.5)
		_road(roads, world, hub - side * 5.5, hub + side * 5.5, 3.1)
		var front := hub + outward * 8.5
		var primary_style: String = plan.style
		if id == "aruun" and role in ["homes", "workshops"]:
			primary_style = "player"
		match role:
			"hearth":
				_hearth(world, district, hub, outward)
				place_shelter(world, district, front, hub, Vector2(8, 11), "player", "GatheringShelter")
			"hall", "garrison":
				place_shelter(world, district, front, hub, Vector2(8, 12), primary_style, "GatheringShelter")
			"homes":
				place_shelter(world, district, front - side * 4.4, hub, Vector2(5.3, 6.8),
					primary_style, "LongShelter", id == "aruun")
				place_shelter(world, district, front + side * 4.5, hub, Vector2(4.8, 6.0),
					primary_style, "FamilyShelter", id == "aruun")
			_:
				place_shelter(world, district, front, hub, Vector2(6.5, 8.4), primary_style, "SupplyShelter")
				Detail.canopy(world, district, hub + outward * 2.4 + side * 2.2, primary_style,
					atan2(-outward.x, -outward.y))
		for i: float in [-1.0, 1.0]:
			var lot := hub + side * (9.4 if role == "homes" else 10.4) * i
			place_shelter(world, district, lot, hub, Vector2(4.7, 6.4), primary_style, "SideShelter")
		if role in ["garrison", "hall"] or id != "aruun":
			banner(world, district, hub + side * 3.0, plan.style, outward.angle())
	if id in ["aruun", "varkai"]:
		var outer := radius(id) - 7.0
		for direction: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN]:
			var entry := center + direction * (outer - 8.0)
			var closest: Vector2 = posts[0]
			for hub: Vector2 in posts:
				if hub.distance_squared_to(entry) < closest.distance_squared_to(entry):
					closest = hub
			_road(roads, world, closest, entry, 3.6)
			_road(roads, world, entry, center + direction * (outer + 6.0), 3.8)
	var road := MeshInstance3D.new()
	road.name = "Streets"
	road.mesh = roads.commit()
	var earth := Graybox.tex("Mud", Color("b39d83"), 0.55).duplicate() as StandardMaterial3D
	earth.vertex_color_use_as_albedo = true
	earth.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	road.material_override = earth
	road.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	city.add_child(road)
	if id in ["aruun", "varkai"]:
		_perimeter(world, city, center, radius(id) - 7.0, id == "aruun", plan.style)
	var tower_offset: Vector2 = {
		"aruun": Vector2(10, -23), "varkai": Vector2(21, 7),
		"kharum": Vector2(15, -15), "north": Vector2(9, -19),
	}[id]
	Detail.tower(world, city, center + tower_offset, plan.style, center)
	if id in ["kharum", "north"]:
		Detail.gate(world, city, center + Vector2(keep_radius + 1.3, 0.0),
			plan.style, PI * 0.5, 4.5)
	return posts


static func _road(surface: SurfaceTool, world: ForestWorld, start: Vector2, end: Vector2, width: float) -> void:
	var dir := (end - start).normalized()
	var side := Vector2(-dir.y, dir.x) * width * 0.5
	var steps := maxi(1, ceili(start.distance_to(end) / 1.15))
	for i in steps:
		var a := start.lerp(end, float(i) / steps)
		var b := start.lerp(end, float(i + 1) / steps)
		a += side * sin(a.x * 0.31 + a.y * 0.28) * 0.13
		b += side * sin(b.x * 0.31 + b.y * 0.28) * 0.13
		var offsets := [-1.0, -0.48, 0.48, 1.0]
		var opacity := [0.0, 0.82, 0.82, 0.0]
		for strip in 3:
			var left: float = offsets[strip]
			var right: float = offsets[strip + 1]
			var vertices := [a + side * left, b + side * left, a + side * right, b + side * right]
			for vertex: int in [0, 1, 2, 2, 1, 3]:
				var p: Vector2 = vertices[vertex]
				surface.set_normal(Vector3.UP)
				surface.set_color(Color(1, 1, 1, opacity[strip + (1 if vertex >= 2 else 0)]))
				surface.add_vertex(world.ground_point(p.x, p.y) + Vector3.UP * 0.09)


## Which model a shelter label gets, by role: the gathering hall, family houses, small huts.
const KINDS := {"GatheringShelter": "Hall", "CoastalHall": "Hall", "LongShelter": "House",
	"SupplyShelter": "House", "FamilyShelter": "Hut", "SideShelter": "Hut"}


static func place_shelter(world: ForestWorld, district: Node3D, pos: Vector2, plaza: Vector2,
		size: Vector2, style: String, label: String, damaged := false) -> void:
	var facing := (plaza - pos).normalized()
	var yaw := atan2(facing.x, facing.y)
	# Rigid models need fairly level ground and dry feet.
	var ground := world.height_at(pos.x, pos.y)
	var slope_limit := 3.25 if size.y >= 11.0 else 2.1  # steeper ground gets a stone terrace (Detail.plinth)
	for i in 12:
		var angle := TAU * i / 12.0
		var at := pos + (Vector2(sin(angle), cos(angle)) * size * 0.5).rotated(-yaw)
		var h := world.height_at(at.x, at.y)
		if h < ForestWorld.WATER_LEVEL + 0.22 or absf(h - ground) > slope_limit:
			return
	var kind: String = "Ruin" if damaged else KINDS.get(label, "Hut")
	Detail.place(world, district, label, "player" if damaged else style, kind, pos, yaw, size)


static func _hearth(world: ForestWorld, district: Node3D, at: Vector2, axis: Vector2) -> void:
	var pit := AssetLib.instance(AssetLib.PROPS[&"fire_pit"])
	pit.position = world.ground_point(at.x, at.y)
	pit.scale = Vector3.ONE * 3.0
	district.add_child(pit)
	for i in range(-2, 3):
		var angle := axis.angle() + float(i) * 0.43
		var p := at + Vector2.from_angle(angle) * 5.3
		var stone := AssetLib.instance(AssetLib.ROCKS[&"small"][i % AssetLib.ROCKS[&"small"].size()])
		stone.position = world.ground_point(p.x, p.y)
		stone.scale = Vector3(1.4, 3.4 + (2 - absi(i)) * 0.35, 1.25)
		district.add_child(stone)


static func banner(world: ForestWorld, parent: Node3D, at: Vector2, style: String, yaw: float) -> void:
	Detail.banner(world, parent, at, style, yaw)


static func _perimeter(world: ForestWorld, parent: Node3D, center: Vector2,
		r: float, occupied: bool, style: String) -> void:
	# Southern, eastern and western entries. North keeps one broken stretch at Aruun.
	var openings := func(mid: float) -> bool:
		return absf(sin(mid)) < 0.10 or absf(mid - PI * 0.5) < 0.10 or (occupied and absf(mid - PI * 1.5) < 0.15)
	Detail.ring_wall(world, parent, center, r, style, openings)
	for gate in [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN]:
		var p: Vector2 = center + gate * r
		var side := Vector2(-gate.y, gate.x)
		var yaw := atan2(gate.x, gate.y)
		Detail.gate(world, parent, p, style, yaw, 6.0)
		banner(world, parent, p + side * 5.1, style, yaw)
