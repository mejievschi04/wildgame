class_name ForestWorld
extends Node3D
## Graybox forest valley test map (~260 × 260 m): procedural terrain with a river, mountain rim,
## deterministic resource scatter, POIs, day/night, structures, pickups and world persistence.
## Deterministic seed → generated nodes have stable ids, so saves only store changed state.

const SIZE := 260.0
const HALF := SIZE * 0.5
const GRID := 160
const SEED := 20261121
const WATER_LEVEL := 0.0
const PLAYABLE := HALF - 34.0
const SPAWN := Vector2(0.0, 0.0)
const OLD_CAMP := Vector2(62.0, -58.0)
const STRUCTURE_SCRIPTS := {
	&"campfire": preload("res://world/campfire.gd"),
	&"bed": preload("res://world/bed.gd"),
	&"piece": preload("res://world/building_piece.gd"),
}

## true when used as the main-menu backdrop: no gameplay simulation.
var menu_mode := false
var day_night: DayNight
var weather: Weather
var tracks: Tracks
var wildlife: Wildlife
var journal: Array[String] = []
var player: Node = null

var _noise := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _nodes: Dictionary = {}  # id -> Node
var _structure_counter := 0
var _sim_accum := 0.0
var _occupied: Dictionary = {}  # Vector2i cell -> Array[Vector3] (x, z, radius)
var _rng := RandomNumberGenerator.new()

var nodes_root: Node3D
var forest_mask: Image
var _terrain_mat: ShaderMaterial
var structures_root: Node3D
var pickups_root: Node3D


func _ready() -> void:
	_noise.seed = SEED
	_noise.frequency = 0.011
	_noise.fractal_octaves = 4
	_detail.seed = SEED + 1
	_detail.frequency = 0.09
	_rng.seed = SEED
	nodes_root = _child_root("Nodes")
	structures_root = _child_root("Structures")
	pickups_root = _child_root("Pickups")
	day_night = DayNight.new()
	day_night.name = "DayNight"
	add_child(day_night)
	weather = Weather.new()
	weather.name = "Weather"
	weather.world = self
	add_child(weather)
	_build_terrain()
	_build_water()
	_build_bounds()
	_build_pois()
	_scatter()
	_build_forest_mask()
	tracks = Tracks.new()
	tracks.name = "Tracks"
	add_child(tracks)
	wildlife = Wildlife.new()
	wildlife.name = "Wildlife"
	wildlife.world = self
	add_child(wildlife)
	var veg := Vegetation.new()
	veg.name = "Vegetation"
	add_child(veg)
	veg.build(self, forest_mask)
	if menu_mode:
		day_night.frozen = true


func _child_root(n: String) -> Node3D:
	var r := Node3D.new()
	r.name = n
	add_child(r)
	return r


func _process(delta: float) -> void:
	if menu_mode:
		return
	_sim_accum += delta
	if _sim_accum >= 1.0:
		for n in get_tree().get_nodes_in_group("slow_sim"):
			n.simulate(_sim_accum)
		_sim_accum = 0.0


# ---------------------------------------------------------------- terrain

func river_x(z: float) -> float:
	return 38.0 + 22.0 * sin(z * 0.018) + 8.0 * sin(z * 0.05 + 1.3)


func river_distance(x: float, z: float) -> float:
	return absf(x - river_x(z))


func height_at(x: float, z: float) -> float:
	var h := _noise.get_noise_2d(x, z) * 5.0 + 3.6 + _detail.get_noise_2d(x, z) * 0.35
	var ds := Vector2(x, z).distance_to(SPAWN)
	h = lerpf(h, 3.2, (1.0 - smoothstep(7.0, 20.0, ds)) * 0.85)
	var dc := Vector2(x, z).distance_to(OLD_CAMP)
	h = lerpf(h, maxf(h, 2.6), 1.0 - smoothstep(4.0, 12.0, dc))
	var t := 1.0 - smoothstep(3.5, 13.0, river_distance(x, z))
	h = lerpf(h, -1.4, t)
	var e := maxf(absf(x), absf(z))
	if e > PLAYABLE + 4.0:
		h += pow((e - PLAYABLE - 4.0) / 30.0, 2.0) * 28.0
	return h


func normal_at(x: float, z: float) -> Vector3:
	var e := 0.6
	var dx := height_at(x + e, z) - height_at(x - e, z)
	var dz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


func ground_point(x: float, z: float) -> Vector3:
	return Vector3(x, height_at(x, z), z)


func _terrain_color(x: float, z: float, h: float, n: Vector3) -> Color:
	var grass := Color(0.24, 0.31, 0.16).lerp(Color(0.3, 0.34, 0.17), _detail.get_noise_2d(x * 0.5, z * 0.5) * 0.5 + 0.5)
	var dirt := Color(0.33, 0.27, 0.19)
	var mud := Color(0.3, 0.27, 0.2)
	var rock := Color(0.42, 0.41, 0.39)
	var snow := Color(0.86, 0.88, 0.9)
	var c := grass.lerp(dirt, smoothstep(0.92, 0.75, n.y))
	c = c.lerp(mud, 1.0 - smoothstep(0.2, 1.1, h))
	c = c.lerp(rock, smoothstep(9.0, 14.0, h))
	c = c.lerp(snow, smoothstep(20.0, 26.0, h))
	return c


func _build_terrain() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cell := SIZE / GRID
	for iz in GRID + 1:
		for ix in GRID + 1:
			var x := -HALF + ix * cell
			var z := -HALF + iz * cell
			var h := height_at(x, z)
			var n := normal_at(x, z)
			st.set_normal(n)
			st.set_color(_terrain_color(x, z, h, n))
			st.set_uv(Vector2(ix, iz) / 8.0)
			st.add_vertex(Vector3(x, h, z))
	var row := GRID + 1
	for iz in GRID:
		for ix in GRID:
			var a := iz * row + ix
			var b := a + 1
			var c := a + row
			var d := c + 1
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(b)
			st.add_index(d)
			st.add_index(c)
	st.generate_tangents()
	var mesh := st.commit()
	_terrain_mat = ShaderMaterial.new()
	_terrain_mat.shader = preload("res://world/shaders/terrain.gdshader")
	_terrain_mat.set_shader_parameter("albedo_tex", load("res://assets/textures/terrain/T_Terrain_albedo.jpg"))
	_terrain_mat.set_shader_parameter("normal_tex", load("res://assets/textures/terrain/T_Terrain_normal.jpg"))
	_terrain_mat.set_shader_parameter("arm_tex", load("res://assets/textures/terrain/T_Terrain_arm.jpg"))
	_terrain_mat.set_shader_parameter("map_size", SIZE)
	_terrain_mat.set_shader_parameter("water_level", WATER_LEVEL)
	var macro := FastNoiseLite.new()
	macro.seed = SEED + 5
	macro.frequency = 0.02
	macro.fractal_octaves = 3
	var macro_img := macro.get_seamless_image(256, 256)
	macro_img.generate_mipmaps()
	_terrain_mat.set_shader_parameter("macro_noise", ImageTexture.create_from_image(macro_img))
	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	mi.material_override = _terrain_mat
	add_child(mi)
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("terrain")
	var shape := mesh.create_trimesh_shape()
	shape.backface_collision = true
	Graybox.add_shape(body, shape)
	add_child(body)


func _build_water() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(SIZE, SIZE)
	plane.subdivide_width = 64
	plane.subdivide_depth = 64
	var m := ShaderMaterial.new()
	m.shader = preload("res://world/shaders/water.gdshader")
	for key in ["wave_a", "wave_b"]:
		var nt := NoiseTexture2D.new()
		nt.width = 512
		nt.height = 512
		nt.seamless = true
		nt.as_normal_map = true
		nt.bump_strength = 6.0
		var fn := FastNoiseLite.new()
		fn.seed = SEED + (11 if key == "wave_a" else 23)
		fn.frequency = 0.012 if key == "wave_a" else 0.03
		nt.noise = fn
		m.set_shader_parameter(key, nt)
	var mi := MeshInstance3D.new()
	mi.name = "WaterSurface"
	mi.mesh = plane
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position.y = WATER_LEVEL
	add_child(mi)
	var water := WaterBody.new()
	water.name = "Water"
	water.setup(SIZE, WATER_LEVEL)
	add_child(water)


func _build_bounds() -> void:
	var walls := StaticBody3D.new()
	walls.name = "Bounds"
	walls.collision_layer = 1
	var lim := PLAYABLE + 14.0
	for side: Vector3 in [Vector3(lim, 0, 0), Vector3(-lim, 0, 0), Vector3(0, 0, lim), Vector3(0, 0, -lim)]:
		var size := Vector3(1, 80, SIZE) if side.x != 0.0 else Vector3(SIZE, 80, 1)
		Graybox.add_shape(walls, Graybox.box_shape(size), side + Vector3(0, 20, 0))
	add_child(walls)


# ---------------------------------------------------------------- scatter

func _cell(x: float, z: float) -> Vector2i:
	return Vector2i(floori(x / 6.0), floori(z / 6.0))


func _is_free(x: float, z: float, r: float) -> bool:
	var c := _cell(x, z)
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			for o: Vector3 in _occupied.get(c + Vector2i(dx, dz), []):
				if Vector2(x, z).distance_to(Vector2(o.x, o.y)) < r + o.z:
					return false
	return true


func _occupy(x: float, z: float, r: float) -> void:
	var c := _cell(x, z)
	if not _occupied.has(c):
		_occupied[c] = []
	_occupied[c].append(Vector3(x, z, r))


func _spawn_node(kind: StringName, x: float, z: float, s: float = 1.0) -> ResourceNode:
	var id := "%s_%03d" % [kind, _count_kind(kind)]
	var n := ResourceNode.new()
	n.setup(id, kind, s, _rng.randf() * TAU)
	n.position = ground_point(x, z) + Vector3(0, -0.05, 0)
	nodes_root.add_child(n)
	_nodes[id] = n
	return n


var _kind_counts: Dictionary = {}


func _count_kind(kind: StringName) -> int:
	var c: int = _kind_counts.get(kind, 0)
	_kind_counts[kind] = c + 1
	return c


func _scatter_kind(kind: StringName, count: int, radius: float, accept: Callable, attempts_per: int = 12) -> void:
	var placed := 0
	var attempts := 0
	while placed < count and attempts < count * attempts_per:
		attempts += 1
		var x := _rng.randf_range(-PLAYABLE, PLAYABLE)
		var z := _rng.randf_range(-PLAYABLE, PLAYABLE)
		var h := height_at(x, z)
		if h < 0.6 or normal_at(x, z).y < 0.84:
			continue
		if not accept.call(x, z, h) or not _is_free(x, z, radius):
			continue
		_occupy(x, z, radius)
		_spawn_node(kind, x, z, _rng.randf_range(0.85, 1.2))
		placed += 1


func _scatter() -> void:
	# Guaranteed starter resources around the spawn clearing (first 5-minute loop).
	var starters := [
		[&"sticks", 5.0, 3.5], [&"sticks", -6.0, 4.5], [&"sticks", 2.0, -8.0],
		[&"stones", 3.5, -5.5], [&"stones", -4.0, -7.0],
		[&"bush", -8.0, -4.0], [&"bush", 9.0, -3.0], [&"bush", -3.0, 10.0],
		[&"rock", -13.0, 9.0], [&"mushroom", 11.0, 8.0],
	]
	for s: Array in starters:
		_occupy(s[1], s[2], 1.5)
		_spawn_node(s[0], s[1], s[2])
	# Flint on the river bank nearest to spawn.
	for z: float in [-6.0, 14.0]:
		var x := river_x(z) - 8.0
		_occupy(x, z, 2.0)
		_spawn_node(&"flint", x, z)

	var away_from_spawn := func(x: float, z: float, _h: float) -> bool:
		return Vector2(x, z).distance_to(SPAWN) > 11.0 and Vector2(x, z).distance_to(OLD_CAMP) > 9.0
	var anywhere := func(x: float, z: float, _h: float) -> bool:
		return Vector2(x, z).distance_to(OLD_CAMP) > 7.0
	var on_bank := func(x: float, z: float, _h: float) -> bool:
		var d := river_distance(x, z)
		return d > 6.0 and d < 18.0
	_scatter_kind(&"tree_pine", 190, 2.2, away_from_spawn)
	_scatter_kind(&"tree_birch", 80, 2.0, func(x: float, z: float, h: float) -> bool:
		return away_from_spawn.call(x, z, h) and river_distance(x, z) < 45.0)
	_scatter_kind(&"rock", 16, 2.5, anywhere)
	_scatter_kind(&"flint", 10, 2.0, on_bank)
	_scatter_kind(&"bush", 70, 1.4, anywhere)
	_scatter_kind(&"sticks", 50, 1.0, anywhere)
	_scatter_kind(&"stones", 40, 1.0, anywhere)
	_scatter_kind(&"mushroom", 30, 0.6, anywhere)


func set_ground_wetness(v: float) -> void:
	if _terrain_mat:
		_terrain_mat.set_shader_parameter("rain_wetness", v)


## Forest density mask (0 clearing … 1 dense forest) from tree positions; drives terrain layers
## (needles vs grass) and decorative scatter.
func _build_forest_mask() -> void:
	const RES := 256
	var acc := PackedFloat32Array()
	acc.resize(RES * RES)
	var px_per_m := RES / SIZE
	var radius := 7
	for n: Node in _nodes.values():
		if not (n is ResourceNode and String((n as ResourceNode).kind).begins_with("tree")):
			continue
		var p := (n as Node3D).position
		var cx := int((p.x / SIZE + 0.5) * RES)
		var cy := int((p.z / SIZE + 0.5) * RES)
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var x := cx + dx
				var y := cy + dy
				if x < 0 or y < 0 or x >= RES or y >= RES:
					continue
				var d2 := float(dx * dx + dy * dy) / float(radius * radius)
				if d2 <= 1.0:
					acc[y * RES + x] += (1.0 - d2) * 0.45
	forest_mask = Image.create(RES, RES, false, Image.FORMAT_L8)
	for y in RES:
		for x in RES:
			forest_mask.set_pixel(x, y, Color(clampf(acc[y * RES + x], 0.0, 1.0), 0, 0))
	_terrain_mat.set_shader_parameter("forest_mask", ImageTexture.create_from_image(forest_mask))


# ---------------------------------------------------------------- POIs

func _build_pois() -> void:
	# Abandoned camp across the river: collapsed lean-to, cold hearth, cache.
	var camp := Node3D.new()
	camp.name = "POI_OldCamp"
	camp.position = ground_point(OLD_CAMP.x, OLD_CAMP.y)
	add_child(camp)
	_occupy(OLD_CAMP.x, OLD_CAMP.y, 7.0)
	var wood := Graybox.tex("Log", Color(0.85, 0.8, 0.75), 1.5)
	for i in 6:
		Graybox.part_mat(camp, Graybox.cylinder(0.05, 0.06, 3.2, 7), wood,
			Vector3(-1.6 + i * 0.65, 1.1, -1.2), Vector3(-35, 0, 4.0 * (i % 3)))
	Graybox.part_mat(camp, Graybox.cylinder(0.06, 0.06, 4.2, 7), wood, Vector3(0, 1.9, -0.3), Vector3(0, 0, 90))
	Graybox.part_mat(camp, Graybox.box(Vector3(2.4, 1.8, 0.04)), Graybox.tex("Leather", Color(0.7, 0.62, 0.55), 0.8), Vector3(0.3, 1.25, -1.0), Vector3(-35, 0, 6))
	for i in 7:
		var a := TAU * i / 7.0
		var hs := AssetLib.instance(AssetLib.ROCKS[&"small"][i % 3])
		hs.scale = Vector3.ONE * 2.2
		hs.position = Vector3(2.5 + cos(a) * 0.5, 0.0, 1.5 + sin(a) * 0.5)
		camp.add_child(hs)
	Graybox.part(camp, Graybox.cylinder(0.4, 0.4, 0.02, 10), Color(0.1, 0.1, 0.1), Vector3(2.5, 0.02, 1.5))
	var stash := Stash.new()
	stash.name = "Stash"
	stash.position = Vector3(-1.2, 0.0, -0.4)
	camp.add_child(stash)
	_nodes[stash.save_id] = stash

	# Fresh kill on the near river bank.
	var cz := 26.0
	var cx := river_x(cz) - 10.0
	var carcass := Carcass.new()
	carcass.name = "POI_Carcass"
	carcass.position = ground_point(cx, cz)
	carcass.rotation.y = 0.7
	add_child(carcass)
	_occupy(cx, cz, 3.0)
	_nodes[carcass.save_id] = carcass


# ---------------------------------------------------------------- gameplay queries

func spawn_position() -> Vector3:
	return ground_point(SPAWN.x, SPAWN.y) + Vector3(0, 0.2, 0)


func ambient_temperature_at(pos: Vector3) -> float:
	var t := day_night.ambient_temperature()
	if weather:
		t += weather.temp_offset + weather.wind_chill_at(pos)
	if pos.y < WATER_LEVEL - 0.3:
		t -= 4.0
	return t


func get_warmth_at(pos: Vector3) -> float:
	var w := 0.0
	for c: Campfire in get_tree().get_nodes_in_group("campfire"):
		w += c.warmth_at(pos)
	return minf(w, 26.0)


func get_stations_near(pos: Vector3) -> Array:
	var out: Array = []
	for c: Campfire in get_tree().get_nodes_in_group("campfire"):
		if c.is_lit() and c.global_position.distance_to(pos) <= Campfire.STATION_RADIUS:
			out.append(&"campfire")
			break
	return out


func add_journal(key: String) -> void:
	if key in journal:
		return
	journal.append(key)
	Events.journal_added.emit(key)


func spawn_pickup(stack: ItemStack, pos: Vector3) -> WorldPickup:
	var p := WorldPickup.new()
	p.setup(stack)
	pickups_root.add_child(p)
	p.global_position = pos
	return p


func spawn_structure(type: StringName, xform: Transform3D, state: Dictionary = {}, id: String = "") -> Node3D:
	if not STRUCTURE_SCRIPTS.has(type):
		push_error("ForestWorld: unknown structure type %s" % type)
		return null
	var s: Node3D = STRUCTURE_SCRIPTS[type].new()
	if id == "":
		_structure_counter += 1
		id = "s_%d" % _structure_counter
	s.set("structure_id", id)
	s.name = id
	if s.has_method("pre_setup"):
		s.pre_setup(state)
	structures_root.add_child(s)
	s.global_transform = xform
	if not state.is_empty():
		s.load_state(state)
	return s


# ---------------------------------------------------------------- building

func get_piece(id: String) -> BuildingPiece:
	return structures_root.get_node_or_null(id) as BuildingPiece


func pieces_near(pos: Vector3, radius: float) -> Array[BuildingPiece]:
	var out: Array[BuildingPiece] = []
	for p: BuildingPiece in get_tree().get_nodes_in_group("building"):
		if not p.is_queued_for_deletion() and p.global_position.distance_to(pos) <= radius:
			out.append(p)
	return out


## Pieces resting on the given piece.
func dependents_of(piece: BuildingPiece) -> Array[BuildingPiece]:
	var out: Array[BuildingPiece] = []
	for p: BuildingPiece in get_tree().get_nodes_in_group("building"):
		if p != piece and not p.is_queued_for_deletion() and piece.structure_id in p.supported_by:
			out.append(p)
	return out


## Removes a piece. Refund goes to `player` (dismantle) or is dropped as pickups (collapse).
## Dependents that lose all support collapse recursively (25 % refund dropped on the ground).
func remove_piece(piece: BuildingPiece, ratio: float, player: Node) -> void:
	if piece.is_queued_for_deletion():
		return
	var refund := piece.refund(ratio)
	if piece.storage:
		for i in piece.storage.size:
			var st := piece.storage.get_slot(i)
			if st:
				spawn_pickup(st.copy(), piece.global_position + Vector3(randf() * 0.6 - 0.3, 0.8 + 0.2 * i, randf() * 0.6 - 0.3))
	for id: StringName in refund.keys():
		if player:
			player.give_item(id, int(refund[id]))
		else:
			spawn_pickup(ItemStack.new(id, int(refund[id])), piece.global_position + Vector3(0, 1.0, 0))
	var was_dismantle := player != null
	Events.toast(Loc.t("MSG_DISMANTLED" if was_dismantle else "MSG_COLLAPSED", {"name": piece.display_name()}),
		&"info" if was_dismantle else &"warn")
	Events.building_removed.emit(piece, was_dismantle)
	piece.remove_from_group("building")
	piece.queue_free()
	for dep in dependents_of(piece):
		dep.supported_by.erase(piece.structure_id)
		if dep.needs_support() and dep.supported_by.is_empty():
			remove_piece(dep, 0.25, null)


## Extra insulation (°C) from shelters: inside a lean-to, or on a roofed foundation.
func get_shelter_at(pos: Vector3) -> float:
	var best := 0.0
	for p: BuildingPiece in pieces_near(pos, 4.0):
		if not p.built:
			continue
		var local := p.global_transform.affine_inverse() * pos
		if p.piece_id == &"lean_to" and absf(local.x) < 1.6 and local.z > -1.4 and local.z < 1.3 and local.y < 2.2:
			best = maxf(best, p.shelter_value())
		elif p.piece_id == &"foundation" and absf(local.x) <= 1.05 and absf(local.z) <= 1.05 \
				and local.y > 0.0 and local.y < BuildingPiece.WALL_H + 0.5:
			var supports := dependents_of(p)
			var walls := 0
			var roofed := false
			for sp in supports:
				if sp.built and sp.piece_class() == "wall":
					walls += 1
				for r in dependents_of(sp):
					if r.built and r.piece_class() == "roof":
						roofed = true
			if roofed:
				# Roof alone shelters a bit; each wall adds more (max with 3+ walls).
				best = maxf(best, 5.0 + 2.0 * mini(walls, 3))
	return best


## Bulk time skip (sleep): advances the clock and every time-simulated system consistently.
func advance_time(seconds: float) -> void:
	day_night.advance(seconds)
	for n in get_tree().get_nodes_in_group("time_sim"):
		n.simulate(seconds)


# ---------------------------------------------------------------- persistence

func collect_save() -> Dictionary:
	var nodes := {}
	for n in get_tree().get_nodes_in_group("persistent"):
		if n.is_modified():
			nodes[n.get_save_id()] = n.save_state()
	var pickups: Array = []
	for p: WorldPickup in get_tree().get_nodes_in_group("pickup"):
		if not p.is_queued_for_deletion():
			pickups.append(p.to_dict())
	var structures: Array = []
	for s: Node3D in get_tree().get_nodes_in_group("structure"):
		if s.is_queued_for_deletion():
			continue
		var o := s.global_position
		structures.append({"type": String(s.get("structure_type")), "id": s.get("structure_id"),
			"pos": [o.x, o.y, o.z], "yaw": s.global_rotation.y, "state": s.save_state()})
	return {
		"time_hours": day_night.time_hours, "day": day_night.day, "journal": journal.duplicate(),
		"nodes": nodes, "pickups": pickups, "structures": structures, "structure_counter": _structure_counter,
		"weather": weather.save_state(), "carcasses": wildlife.save_state(),
	}


func apply_save(d: Dictionary) -> void:
	day_night.time_hours = float(d.get("time_hours", 12.0))
	day_night.day = int(d.get("day", 1))
	if d.has("weather"):
		weather.load_state(d.weather)
	wildlife.load_state(d.get("carcasses", []))
	journal.clear()
	for k: Variant in d.get("journal", []):
		journal.append(str(k))
	var nodes: Dictionary = d.get("nodes", {})
	for id: String in nodes.keys():
		if _nodes.has(id):
			_nodes[id].load_state(nodes[id])
	for p in pickups_root.get_children():
		p.queue_free()
	for p: Dictionary in d.get("pickups", []):
		var st := ItemStack.from_dict(p.item)
		if ItemDB.get_item(st.id):
			spawn_pickup(st, _vec(p.pos))
	for s in structures_root.get_children():
		s.queue_free()
	_structure_counter = int(d.get("structure_counter", 0))
	for s: Dictionary in d.get("structures", []):
		var xf := Transform3D(Basis(Vector3.UP, float(s.get("yaw", 0.0))), _vec(s.pos))
		spawn_structure(StringName(str(s.type)), xf, s.get("state", {}), str(s.get("id", "")))


func get_node_by_save_id(id: String) -> Node:
	return _nodes.get(id)


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
