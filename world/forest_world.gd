class_name ForestWorld
extends Node3D
## Procedural open world (4 × 4 km playable): central tutorial valley and regional wilderness,
## deterministic resource scatter, POIs, day/night, structures, pickups and world persistence.
## Deterministic seed → generated nodes have stable ids, so saves only store changed state.

const SIZE := 4200.0
const HALF := SIZE * 0.5
const SEED := 20261121
const WATER_LEVEL := 0.0
const PLAYABLE := 2000.0
const SPAWN := Vector2(0.0, 0.0)
const OLD_CAMP := Vector2(55.0, -58.0)
const LAKE_CENTER := Vector2(205.0, 1760.0)
const LAKE_RADIUS_X := 170.0
const LAKE_RADIUS_Z := 145.0
## Relief baked offline with hydraulic erosion (tools/gen_terrain.py): the final float32 heights on a BAKE_N² grid
## (~2 m) over the whole terrain, zlib-compressed, with the river's cut, lake, fords and camp clearings already in.
## The visible terrain (TerrainLod), its collision (one HeightMapShape3D) and height_at() all use this grid and the
## same triangulation. Creeks (with their water levels) and the shader masks come from the same run.
const TERRAIN_BIN := "res://assets/terrain/terrain_height.bin"
const TERRAIN_MASKS := "res://assets/terrain/T_Terrain_Masks.png"
const STREAMS_JSON := "res://data/streams.json"
const CAVES_JSON := "res://data/caves.json"
const BAKE_N := 2049
const BAKE_CELL := SIZE / (BAKE_N - 1)
## Shallow crossings of the main river: river z, half-length along the river (m), bed height (water ~0.15 m deep).
## Cut into the bake: keep in sync with tools/gen_terrain.py FORDS.
const FORDS := {
	&"stone_ford": Vector3(-200.0, 9.0, -0.12),  # Vadul de Piatră: quick, open, stepping stones
	&"dry_ford": Vector3(1150.0, 15.0, -0.08),   # Vadul Secat: the southern gravel bar, hard to spot
}
const CREEK_HASH := 32.0

## Region centers also anchor the strategic map and future clan strongholds.
const REGIONS := {
	&"aruun": Vector2(0.0, 0.0),
	&"varkai": Vector2(1160.0, -1240.0),
	&"meyra": Vector2(1160.0, 580.0),
	&"kharum": Vector2(-1400.0, 80.0),
	&"ossara": Vector2(80.0, 1480.0),
	&"tavren": Vector2(-1000.0, -1200.0),
	&"tundra": Vector2(180.0, -1740.0),
}
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
var factions: Factions
var camps: Camps
var npc_nav: NpcNav
var meadow_grass: MeadowGrass
var far_forest: FarForest
var waterfall: Waterfall
var _water_mat: ShaderMaterial
var _camp_sites: Array[Vector2] = []
var _camp_clearings: Array[Vector2] = []
var journal: Array[String] = []
## World map: explored cells (MapData fog), the player's waypoint, the painted map (ready when map_task finishes).
var map_fog := MapData.new_fog()
var waypoint := Vector3.INF
var map_image: Image
var _map_task := -1
var _map_t := 0.0
var player: Node = null

var _noise := FastNoiseLite.new()
var _landform := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var terrain_lod: TerrainLod
var caves: Array[Cave] = []
var _nodes: Dictionary = {}  # id -> Node
var _pending_region_states: Dictionary = {}
var _structure_counter := 0
var _sim_accum := 0.0
var _occupied: Dictionary = {}  # Vector2i cell -> Array[Vector3] (x, z, radius)
var _rng := RandomNumberGenerator.new()
static var _bake := PackedFloat32Array()
## Hash of the baked relief file: caches derived from the terrain (the painted map) are keyed by it.
static var bake_hash := 0
## Creeks: per creek the centre line as (x, water level, z), its width class 0..1, and a 32 m grid of nearby segments.
var creeks: Array[PackedVector3Array] = []
var creek_widths: PackedFloat32Array = []
var _creek_hash: Dictionary = {}  # Vector2i -> PackedInt32Array of (creek << 16 | segment)

var nodes_root: Node3D
var forest_mask: Image
var _terrain_mat: ShaderMaterial
var structures_root: Node3D
var pickups_root: Node3D


## Gameplay geometry (resources, props, camps, buildings, pickups) is hidden beyond this distance. The camera sees
## ~14 km for the border mountains; without a limit every object on the 4 km map would be drawn every frame.
const PROP_VIEW_DIST := 600.0


func _ready() -> void:
	get_tree().node_added.connect(_limit_view_distance)
	_noise.seed = SEED
	_noise.frequency = 0.0018
	_noise.fractal_octaves = 4
	_landform.seed = SEED + 2
	_landform.frequency = 0.0038
	_landform.fractal_octaves = 3
	_detail.seed = SEED + 1
	_detail.frequency = 0.012
	_load_bake()
	_load_creeks()
	_rng.seed = SEED
	_load_camp_sites()
	nodes_root = _child_root("Nodes")
	structures_root = _child_root("Structures")
	pickups_root = _child_root("Pickups")
	day_night = DayNight.new()
	day_night.add_to_group("far_scenery")
	day_night.name = "DayNight"
	add_child(day_night)
	weather = Weather.new()
	weather.name = "Weather"
	weather.world = self
	add_child(weather)
	_build_terrain()
	_build_caves()
	_build_water()
	_build_bounds()
	_build_pois()
	for i in _camp_sites.size():
		var c := _camp_sites[i]
		_occupy(c.x, c.y, maxf(16.0, _camp_clearings[i].x + 4.0))
	_scatter()
	_build_forest_mask()
	_terrain_mat.set_shader_parameter("grove_tex", ImageTexture.create_from_image(FarForest.grove_image()))
	tracks = Tracks.new()
	tracks.name = "Tracks"
	add_child(tracks)
	wildlife = Wildlife.new()
	wildlife.name = "Wildlife"
	wildlife.world = self
	add_child(wildlife)
	if not menu_mode:
		factions = Factions.new()
		factions.name = "Factions"
		factions.world = self
		add_child(factions)
		npc_nav = NpcNav.new()
		npc_nav.name = "NpcNav"
		npc_nav.world = self
		add_child(npc_nav)
		camps = Camps.new()
		camps.name = "Camps"
		camps.world = self
		camps.factions = factions
		add_child(camps)
		camps.build_structures()
		camps.spawn_people()
	waterfall = Waterfall.new()
	waterfall.name = "Waterfall"
	add_child(waterfall)
	waterfall.build(self, -520.0, 1.0)
	_water_mat.set_shader_parameter("rapids", waterfall.rapids())
	var veg := Vegetation.new()
	veg.name = "Vegetation"
	add_child(veg)
	veg.build(self, forest_mask)
	var backdrop := Backdrop.new()
	backdrop.add_to_group("far_scenery")
	backdrop.name = "Backdrop"
	add_child(backdrop)
	backdrop.build(self)
	far_forest = FarForest.new()
	far_forest.add_to_group("far_scenery")
	far_forest.name = "FarForest"
	add_child(far_forest)
	far_forest.build(self, forest_mask)
	var birds := Birds.new()
	birds.name = "Birds"
	birds.world = self
	birds.add_to_group("far_scenery")
	add_child(birds)
	var fx := AtmosphereFX.new()
	fx.add_to_group("far_scenery")  # follows the camera
	fx.name = "AtmosphereFX"
	fx.world = self
	add_child(fx)
	meadow_grass = MeadowGrass.new()
	meadow_grass.add_to_group("far_scenery")  # positioned around the camera in its shader
	meadow_grass.name = "MeadowGrass"
	add_child(meadow_grass)
	meadow_grass.build(self, _bake, forest_mask, _terrain_mat.get_shader_parameter("macro_noise"))
	if menu_mode:
		day_night.frozen = true
	else:
		MapData.reveal(map_fog, SPAWN.x, SPAWN.y, MapData.START_REVEAL)
		_start_map_paint()


## Paints the world map once per seed in the background (it is cached on disk afterwards).
func _start_map_paint() -> void:
	map_image = MapData.cached()
	if map_image:
		return
	var heights := _bake
	var forest := forest_mask.duplicate() as Image
	var creek_lines := creeks.duplicate()
	_map_task = WorkerThreadPool.add_task(func() -> void:
		var img := MapData.paint(heights, BAKE_N - 1, SIZE, forest, WATER_LEVEL, creek_lines)
		img.save_png(MapData.cache_path())
		_set_map_image.call_deferred(img))


func _set_map_image(img: Image) -> void:
	map_image = img


## The painted map, waiting for the background job if it is still running (e.g. the map opened early).
func get_map_image() -> Image:
	if map_image == null and _map_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_map_task)
		_map_task = -1
		if map_image == null:
			map_image = MapData.cached()
	return map_image


func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_limit_view_distance):
		get_tree().node_added.disconnect(_limit_view_distance)
	if _map_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_map_task)
		_map_task = -1


func _child_root(n: String) -> Node3D:
	var r := Node3D.new()
	r.name = n
	add_child(r)
	return r


func _process(delta: float) -> void:
	if menu_mode:
		return
	_map_t += delta
	if _map_t >= 0.5 and player:
		_map_t = 0.0
		var pp := (player as Node3D).global_position
		MapData.reveal(map_fog, pp.x, pp.z, MapData.REVEAL_RADIUS)
	_sim_accum += delta
	if _sim_accum >= 1.0:
		for n in get_tree().get_nodes_in_group("slow_sim"):
			n.simulate(_sim_accum)
		_advance_pending_regrowth(_sim_accum)
		_sim_accum = 0.0


# ---------------------------------------------------------------- terrain

func river_x(z: float) -> float:
	return 155.0 + 95.0 * sin(z * 0.0019) + 34.0 * sin(z * 0.0044 + 1.3)


func river_distance(x: float, z: float) -> float:
	var d := _channel_distance(x, z, -PLAYABLE, LAKE_CENTER.y - LAKE_RADIUS_Z + 20.0, Callable(self, "river_x"))
	# The main river splits into slow channels through Meyra's eastern marsh; they braid and drain into the lake.
	d = minf(d, _channel_distance(x, z, 180.0, MEYRA_A_END, Callable(self, "_meyra_channel_a")))
	d = minf(d, _channel_distance(x, z, 430.0, MEYRA_B_END, Callable(self, "_meyra_channel_b")))
	return d


## Distance to running water of any size: the river and its channels, or a creek. A creek's waterline is ~2–3.5 m
## from its centre (the river's ~10 m), so its distance is offset to read like the river's on the banks.
func water_distance(x: float, z: float) -> float:
	return minf(river_distance(x, z), creek_distance(x, z) + 7.0)


func _channel_distance(x: float, z: float, start_z: float, end_z: float, center_x: Callable) -> float:
	var nearest_z := clampf(z, start_z, end_z)
	var dx := x - float(center_x.call(nearest_z))
	return Vector2(dx, z - nearest_z).length()


## Keep the Meyra channels in sync with tools/gen_terrain.py (meyra_a / meyra_b).
const MEYRA_A_END := 1700.0
const MEYRA_B_END := 1300.0


func _meyra_channel_a(z: float) -> float:
	var bend := 35.0 * (sin(z * 0.003) - sin(180.0 * 0.003))
	var out := 250.0 * smoothstep(180.0, 520.0, z) + bend
	var home := smoothstep(1250.0, 1720.0, z)  # turns back into the lake's east shore
	return river_x(z) + out * (1.0 - home) + home * (LAKE_CENTER.x + 120.0 - river_x(z))


func _meyra_channel_b(z: float) -> float:
	var bend := 45.0 * (sin(z * 0.0025) - sin(430.0 * 0.0025))
	return _meyra_channel_a(z) + (220.0 * smoothstep(430.0, 760.0, z) + bend) * (1.0 - smoothstep(1050.0, 1300.0, z))


func region_at(x: float, z: float) -> StringName:
	var p := Vector2(x, z)
	var selected: StringName = &"aruun"
	var best := INF
	for region: StringName in REGIONS:
		var dist := p.distance_squared_to(REGIONS[region])
		if dist < best:
			best = dist
			selected = region
	return selected


func _region_blend(x: float, z: float) -> Array:
	var p := Vector2(x, z)
	var near: StringName = &"aruun"
	var next: StringName = &"aruun"
	var near_distance := INF
	var next_distance := INF
	for region: StringName in REGIONS:
		var distance := p.distance_to(REGIONS[region])
		if distance < near_distance:
			next = near
			next_distance = near_distance
			near = region
			near_distance = distance
		elif distance < next_distance:
			next = region
			next_distance = distance
	var near_weight := clampf(0.5 + (next_distance - near_distance) / 900.0, 0.5, 1.0)
	return [near, next, near_weight]


func _load_camp_sites() -> void:
	var f := FileAccess.open("res://data/factions.json", FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text()) if f else {}
	for k: String in (d as Dictionary).keys():
		_add_camp_site(Camps.site(d[k]), 10.0)
	for base: Dictionary in Camps.REGIONAL_BASES.values():
		_add_camp_site(Camps.site(base), maxf(12.0, float(base.wall_radius) + 6.0))


func _add_camp_site(c: Vector2, flat_radius: float) -> void:
	_camp_sites.append(c)
	_camp_clearings.append(Vector2(flat_radius, flat_radius + 12.0))


## The baked terrain at (x, z): the triangle of the bake grid under the point, split like the terrain mesh and the
## HeightMapShape3D collision (u + v <= 1). Outside the map square it continues the nearest edge value.
static func bake_height(x: float, z: float) -> float:
	var gx := clampf((x + HALF) / BAKE_CELL, 0.0, BAKE_N - 1.0)
	var gz := clampf((z + HALF) / BAKE_CELL, 0.0, BAKE_N - 1.0)
	var ix := mini(int(gx), BAKE_N - 2)
	var iz := mini(int(gz), BAKE_N - 2)
	var u := gx - ix
	var v := gz - iz
	var a := iz * BAKE_N + ix
	var b := _bake[a + 1]
	var c := _bake[a + BAKE_N]
	if u + v <= 1.0:
		return _bake[a] * (1.0 - u - v) + b * u + c * v
	return b * (1.0 - v) + c * (1.0 - u) + _bake[a + BAKE_N + 1] * (u + v - 1.0)


## Upward normal of the bake at a grid sample, from central differences `step` samples apart.
static func bake_normal(bx: int, bz: int, step: int = 1) -> Vector3:
	var x0 := maxi(bx - step, 0)
	var x1 := mini(bx + step, BAKE_N - 1)
	var z0 := maxi(bz - step, 0)
	var z1 := mini(bz + step, BAKE_N - 1)
	var dx := (_bake[bz * BAKE_N + x1] - _bake[bz * BAKE_N + x0]) / ((x1 - x0) * BAKE_CELL)
	var dz := (_bake[z1 * BAKE_N + bx] - _bake[z0 * BAKE_N + bx]) / ((z1 - z0) * BAKE_CELL)
	return Vector3(-dx, 1.0, -dz).normalized()


## Loads the baked relief once per run (the menu backdrop and the game session share it).
static func _load_bake() -> void:
	if _bake.size() == BAKE_N * BAKE_N:
		return
	var packed := FileAccess.get_file_as_bytes(TERRAIN_BIN)
	bake_hash = hash(packed) ^ hash(FileAccess.get_file_as_string(STREAMS_JSON))
	var raw := packed.decompress(BAKE_N * BAKE_N * 4, FileAccess.COMPRESSION_DEFLATE)
	_bake = raw.to_float32_array()
	if _bake.size() != BAKE_N * BAKE_N:
		push_error("ForestWorld: %s is missing or damaged (run tools/gen_terrain.py)" % TERRAIN_BIN)
		_bake.resize(BAKE_N * BAKE_N)
		_bake.fill(30.0)


func _load_creeks() -> void:
	var f := FileAccess.open(STREAMS_JSON, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text()) if f else null
	if not d is Dictionary:
		return
	for c: Dictionary in d.get("streams", []):
		var pts := PackedVector3Array()
		for p: Array in c.get("points", []):
			pts.append(Vector3(float(p[0]), float(p[2]), float(p[1])))
		if pts.size() < 2:
			continue
		var ci := creeks.size()
		creeks.append(pts)
		creek_widths.append(float(c.get("width", 0.0)))
		for si in pts.size() - 1:
			var a := Vector2(pts[si].x, pts[si].z)
			var b := Vector2(pts[si + 1].x, pts[si + 1].z)
			var lo := (a.min(b) - Vector2.ONE * 48.0) / CREEK_HASH
			var hi := (a.max(b) + Vector2.ONE * 48.0) / CREEK_HASH
			for gx in range(floori(lo.x), floori(hi.x) + 1):
				for gz in range(floori(lo.y), floori(hi.y) + 1):
					var key := Vector2i(gx, gz)
					var list: PackedInt32Array = _creek_hash.get(key, PackedInt32Array())
					list.append((ci << 16) | si)
					_creek_hash[key] = list


## Distance to the nearest creek's centre line (1e9 when none is within ~48 m).
func creek_distance(x: float, z: float) -> float:
	var list: PackedInt32Array = _creek_hash.get(Vector2i(floori(x / CREEK_HASH), floori(z / CREEK_HASH)), PackedInt32Array())
	var best := 1e9
	var p := Vector2(x, z)
	for code in list:
		var pts := creeks[code >> 16]
		var si := code & 0xFFFF
		var a := Vector2(pts[si].x, pts[si].z)
		var b := Vector2(pts[si + 1].x, pts[si + 1].z)
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


## The creek's water level near (x, z), or -INF away from creeks.
func creek_level_at(x: float, z: float) -> float:
	var list: PackedInt32Array = _creek_hash.get(Vector2i(floori(x / CREEK_HASH), floori(z / CREEK_HASH)), PackedInt32Array())
	var best := 1e9
	var level := -INF
	var p := Vector2(x, z)
	for code in list:
		var pts := creeks[code >> 16]
		var si := code & 0xFFFF
		var a := Vector2(pts[si].x, pts[si].z)
		var b := Vector2(pts[si + 1].x, pts[si + 1].z)
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := p.distance_to(q)
		if d < best:
			best = d
			var t := clampf(a.distance_to(q) / maxf(a.distance_to(b), 0.001), 0.0, 1.0)
			level = lerpf(pts[si].y, pts[si + 1].y, t)
	return level


## Caves cut into the bake (data/caves.json): each gets its rock roof; their ground is kept clear of scatter.
func _build_caves() -> void:
	var f := FileAccess.open(CAVES_JSON, FileAccess.READ)
	var d: Variant = JSON.parse_string(f.get_as_text()) if f else null
	if not d is Dictionary:
		return
	for def: Dictionary in d.get("caves", []):
		var cave := Cave.new()
		cave.add_to_group("far_scenery")
		add_child(cave)
		cave.build(self, def, _terrain_mat)
		caves.append(cave)
		for r: Dictionary in cave.rings:
			var c := Vector2(float(r.x), float(r.z))
			var reach := float(r.r)
			var l := -reach
			while l <= reach:
				var p := c + cave.side * l
				_occupy(p.x, p.y, 3.0)
				l += 3.0
		var t := -cave.mouth - 14.0
		while t < cave.mouth:  # the open approach
			var p := cave.entry + cave.dir * t
			_occupy(p.x, p.y, 6.0)
			t += 3.0


## True over a cave's cut (its approach, trench and roof), widened by `margin`.
func in_cave_cut(x: float, z: float, margin: float = 0.0) -> bool:
	for cave in caves:
		if cave.covers(x, z, margin):
			return true
	return false


## The cave around `pos`, or null.
func cave_at(pos: Vector3) -> Cave:
	for cave in caves:
		if cave.contains(pos):
			return cave
	return null


## Terrain height at (x, z) (the backdrop samples it beyond the map's edge too).
func _terrain_height(x: float, z: float) -> float:
	return bake_height(x, z)


## Climate bands, north (−z) to south (+z): tundra · taiga · temperate · jungle. 0..1, with wavy borders.
## Keep in sync with biome.gdshaderinc.
static func jungle_at(x: float, z: float) -> float:
	return smoothstep(650.0, 1150.0, z + 120.0 * sin(x * 0.004) + 80.0 * sin(x * 0.011 + 1.0))


static func tundra_at(x: float, z: float) -> float:
	return 1.0 - smoothstep(-1550.0, -1200.0, z + 100.0 * sin(x * 0.005 + 2.0) + 60.0 * sin(x * 0.013))


## Dry, walkable ground well inside the map (hunting grounds, forage spots).
func habitat_ok_for_people(p: Vector3) -> bool:
	return height_at(p.x, p.z) > WATER_LEVEL + 0.4 and absf(p.x) < PLAYABLE - 20.0 and absf(p.z) < PLAYABLE - 20.0


func height_at(x: float, z: float) -> float:
	return bake_height(x, z)


func normal_at(x: float, z: float) -> Vector3:
	var e := 0.6
	var dx := height_at(x + e, z) - height_at(x - e, z)
	var dz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-dx, 2.0 * e, -dz).normalized()


func ground_point(x: float, z: float) -> Vector3:
	return Vector3(x, height_at(x, z), z)


## The terrain: TerrainLod draws it (full resolution near the camera, every 4th sample beyond) and one
## HeightMapShape3D over the whole bake is its collision.
func _build_terrain() -> void:
	_terrain_mat = ShaderMaterial.new()
	_terrain_mat.shader = preload("res://world/shaders/terrain.gdshader")
	_terrain_mat.set_shader_parameter("albedo_tex", load("res://assets/textures/terrain/T_Terrain_albedo.jpg"))
	_terrain_mat.set_shader_parameter("normal_tex", load("res://assets/textures/terrain/T_Terrain_normal.jpg"))
	_terrain_mat.set_shader_parameter("arm_tex", load("res://assets/textures/terrain/T_Terrain_arm.jpg"))
	_terrain_mat.set_shader_parameter("map_size", SIZE)
	_terrain_mat.set_shader_parameter("water_level", WATER_LEVEL)
	_terrain_mat.set_shader_parameter("biome_tint", ImageTexture.create_from_image(_build_biome_tint()))
	if ResourceLoader.exists(TERRAIN_MASKS):
		_terrain_mat.set_shader_parameter("terrain_masks", load(TERRAIN_MASKS))
	var macro := FastNoiseLite.new()
	macro.seed = SEED + 5
	macro.frequency = 0.02
	macro.fractal_octaves = 3
	var macro_img := macro.get_seamless_image(256, 256)
	macro_img.generate_mipmaps()
	_terrain_mat.set_shader_parameter("macro_noise", ImageTexture.create_from_image(macro_img))
	terrain_lod = TerrainLod.new()
	terrain_lod.name = "Terrain"
	terrain_lod.add_to_group("far_scenery")
	add_child(terrain_lod)
	terrain_lod.build(self, _terrain_mat, spawn_position())
	var body := StaticBody3D.new()
	body.name = "TerrainBody"
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("terrain")
	var shape := HeightMapShape3D.new()
	shape.map_width = BAKE_N
	shape.map_depth = BAKE_N
	shape.map_data = _bake
	var cs := Graybox.add_shape(body, shape)
	cs.scale = Vector3(BAKE_CELL, 1.0, BAKE_CELL)
	add_child(body)


func _build_water() -> void:
	var m := ShaderMaterial.new()
	_water_mat = m
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
	_build_water_channel("MainRiver", -PLAYABLE, LAKE_CENTER.y - LAKE_RADIUS_Z + 20.0, 65.0, 14.0, Callable(self, "river_x"), m, true)
	_build_water_channel("MeyraChannelA", 180.0, MEYRA_A_END, 60.0, 12.0, Callable(self, "_meyra_channel_a"), m, true)
	_build_water_channel("MeyraChannelB", 430.0, MEYRA_B_END, 60.0, 11.0, Callable(self, "_meyra_channel_b"), m, true)
	_build_lake(m)
	for i in creeks.size():
		_build_creek(i, m)


## A creek's water: a ribbon following its descending level (so it runs downhill, unlike the river at 0 m), and
## drinkable/fishable water volumes along it. Its bed is already cut into the baked relief.
func _build_creek(index: int, material: ShaderMaterial) -> void:
	var pts := creeks[index]
	# A little past the waterline (~2.3–3.5 m from the centre), so the ribbon's own edge stays under the banks.
	var half_width := 4.5 + 2.5 * creek_widths[index]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var along := 0.0
	for i in pts.size():
		var a := pts[maxi(i - 1, 0)]
		var b := pts[mini(i + 1, pts.size() - 1)]
		var tangent := Vector2(b.x - a.x, b.z - a.z).normalized()
		var side := Vector2(tangent.y, -tangent.x)
		if i > 0:
			along += Vector2(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z).length()
		# narrow at the source, full width after the first ~60 m
		var w := half_width
		for edge: float in [-1.0, 1.0]:
			var p := Vector2(pts[i].x, pts[i].z) + side * w * edge
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(along / 18.0, edge * 0.5 + 0.5))
			st.add_vertex(Vector3(p.x, pts[i].y + 0.03, p.y))
	for i in pts.size() - 1:
		var a := i * 2
		st.add_index(a)
		st.add_index(a + 1)
		st.add_index(a + 2)
		st.add_index(a + 1)
		st.add_index(a + 3)
		st.add_index(a + 2)
	var surface := MeshInstance3D.new()
	surface.add_to_group("far_scenery")
	surface.name = "Creek%d_Surface" % index
	surface.mesh = st.commit()
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(surface)
	var i := 0
	while i < pts.size() - 1:
		var j := mini(i + 2, pts.size() - 1)
		var p0 := pts[i]
		var p1 := pts[j]
		var segment := WaterBody.new()
		segment.name = "Creek%d_Water_%03d" % [index, i]
		add_child(segment)
		var length := Vector2(p1.x - p0.x, p1.z - p0.z).length()
		segment.setup(half_width * 1.3, (p0.y + p1.y) * 0.5 + 0.03, length + 1.0)
		segment.position = Vector3((p0.x + p1.x) * 0.5, 0.0, (p0.z + p1.z) * 0.5)
		segment.rotation.y = atan2(p1.x - p0.x, p1.z - p0.z)
		i = j


func _build_lake(material: ShaderMaterial) -> void:
	const SEGMENTS := 64
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3(LAKE_CENTER.x, WATER_LEVEL + 0.025, LAKE_CENTER.y)
	for i in SEGMENTS:
		var a0 := TAU * float(i) / SEGMENTS
		var a1 := TAU * float(i + 1) / SEGMENTS
		var p0 := Vector3(LAKE_CENTER.x + cos(a0) * LAKE_RADIUS_X, WATER_LEVEL + 0.025,
			LAKE_CENTER.y + sin(a0) * LAKE_RADIUS_Z)
		var p1 := Vector3(LAKE_CENTER.x + cos(a1) * LAKE_RADIUS_X, WATER_LEVEL + 0.025,
			LAKE_CENTER.y + sin(a1) * LAKE_RADIUS_Z)
		for p: Vector3 in [center, p0, p1]:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(p.x / 18.0, p.z / 18.0))
			st.add_vertex(p)
	var surface := MeshInstance3D.new()
	surface.add_to_group("far_scenery")
	surface.name = "SouthernLake_Surface"
	surface.mesh = st.commit()
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(surface)
	var lake := WaterBody.new()
	lake.name = "LakeWater"
	add_child(lake)
	lake.setup_ellipse(LAKE_RADIUS_X, LAKE_RADIUS_Z, WATER_LEVEL)
	lake.position = Vector3(LAKE_CENTER.x, 0.0, LAKE_CENTER.y)


func _build_water_channel(channel_name: String, start_z: float, end_z: float, step: float,
		half_width: float, center_x: Callable, material: ShaderMaterial, interactable: bool) -> void:
	var sections := maxi(2, ceili((end_z - start_z) / step))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(sections + 1):
		var z := lerpf(start_z, end_z, float(i) / sections)
		var prev_z := maxf(start_z, z - 1.0)
		var next_z := minf(end_z, z + 1.0)
		var center := float(center_x.call(z))
		var tangent := Vector2(float(center_x.call(next_z)) - float(center_x.call(prev_z)), next_z - prev_z).normalized()
		var side := Vector2(tangent.y, -tangent.x)
		var taper := 1.0
		if channel_name != "MainRiver":
			taper = minf(smoothstep(start_z, start_z + 75.0, z), 1.0 - smoothstep(end_z - 75.0, end_z, z))
		for edge: float in [-1.0, 1.0]:
			var p: Vector2 = Vector2(center, z) + side * half_width * taper * edge
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(z / 18.0, edge * 0.5 + 0.5))
			st.add_vertex(Vector3(p.x, WATER_LEVEL + 0.025, p.y))
	for i in sections:
		var a := i * 2
		var b := a + 1
		var c := a + 2
		var d := a + 3
		st.add_index(a)
		st.add_index(b)
		st.add_index(c)
		st.add_index(b)
		st.add_index(d)
		st.add_index(c)
	var surface := MeshInstance3D.new()
	surface.add_to_group("far_scenery")
	surface.name = "%s_Surface" % channel_name
	surface.mesh = st.commit()
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(surface)
	if not interactable:
		return
	var main_water_index := floori(sections * 0.5)
	for i in sections:
		var z0 := lerpf(start_z, end_z, float(i) / sections)
		var z1 := lerpf(start_z, end_z, float(i + 1) / sections)
		var x0 := float(center_x.call(z0))
		var x1 := float(center_x.call(z1))
		var segment := WaterBody.new()
		segment.name = "Water" if channel_name == "MainRiver" and i == main_water_index else "%s_Water_%02d" % [channel_name, i]
		add_child(segment)
		segment.setup(half_width * 2.0, WATER_LEVEL, z1 - z0 + 2.0)
		segment.position = Vector3((x0 + x1) * 0.5, 0.0, (z0 + z1) * 0.5)
		segment.rotation.y = atan2(x1 - x0, z1 - z0)


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


func is_scatter_site_free(x: float, z: float, r: float) -> bool:
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
	var n: ResourceNode = TreeNode.new() if String(kind).begins_with("tree") else ResourceNode.new()
	n.setup(id, kind, s, _rng.randf() * TAU)
	n.position = ground_point(x, z)
	if kind not in [&"stones", &"sticks"]:
		n.position.y -= 0.05
	nodes_root.add_child(n)
	_nodes[id] = n
	return n


func spawn_region_resource(root: Node3D, id: String, kind: StringName, at: Vector2,
		size_scale: float, yaw: float, species: StringName = &"") -> void:
	if _nodes.has(id):
		(_nodes[id] as ResourceNode).reparent(root)
		return
	var n: ResourceNode
	if species != &"":
		var trunk := TreeNode.new()
		trunk.species = species
		n = trunk
	else:
		n = ResourceNode.new()
	n.setup(id, kind, size_scale, yaw)
	n.position = ground_point(at.x, at.y)
	_register_resource(root, n)


func spawn_scattered_resource(root: Node3D, id: String, kind: StringName, mesh: Mesh, xf: Transform3D) -> void:
	var n := ResourceNode.new()
	n.setup_scattered(id, kind, mesh, xf)
	_register_resource(root, n)


func _register_resource(root: Node3D, n: ResourceNode) -> void:
	var id := n.node_id
	root.add_child(n)
	_nodes[id] = n
	if _pending_region_states.has(id):
		n.load_state(_pending_region_states[id])
		_pending_region_states.erase(id)


func unload_region_resources(root: Node3D) -> void:
	for child in root.get_children():
		if child is ResourceNode:
			if child.is_in_group("scattered_resource"):
				if child.is_modified():
					_pending_region_states[child.node_id] = child.save_state()
				_nodes.erase(child.node_id)
				continue
			if child.is_modified():
				# Keep felling, branch drops and regrowth running outside the loaded area.
				child.reparent(nodes_root)
			else:
				_nodes.erase(child.node_id)


var _kind_counts: Dictionary = {}


func _count_kind(kind: StringName) -> int:
	var c: int = _kind_counts.get(kind, 0)
	_kind_counts[kind] = c + 1
	return c


## Gives every newly added mesh under the world a view distance, unless it already has one or belongs to the
## far scenery (group "far_scenery": terrain, water, mountains, distant forest, sky).
func _limit_view_distance(n: Node) -> void:
	var g := n as GeometryInstance3D
	if g == null or g.visibility_range_end > 0.0 or not is_ancestor_of(g):
		return
	var p: Node = g
	while p != null and p != self:
		if p.is_in_group("far_scenery"):
			return
		p = p.get_parent()
	g.visibility_range_end = PROP_VIEW_DIST
	g.visibility_range_end_margin = 60.0


func _scatter_kind(kind: StringName, count: int, radius: float, accept: Callable, attempts_per: int = 12) -> void:
	var placed := 0
	var attempts := 0
	while placed < count and attempts < count * attempts_per:
		attempts += 1
		# The hand-authored tutorial valley remains resource-rich; remote regions
		# receive their own biome resources as those systems are added.
		var x := _rng.randf_range(SPAWN.x - 245.0, SPAWN.x + 245.0)
		var z := _rng.randf_range(SPAWN.y - 245.0, SPAWN.y + 245.0)
		var h := height_at(x, z)
		if h < 0.6 or normal_at(x, z).y < 0.84 or creek_distance(x, z) < 5.0:
			continue
		if not accept.call(x, z, h) or not is_scatter_site_free(x, z, radius):
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
		var x := river_x(z) - 14.0  # on the dry bank: the waterline sits ~10 m from the channel centre
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
	# In sight when a new player faces east. Append after the seeded scatter for save stability.
	_spawn_node(&"sticks", 2.0, 0.75)
	_spawn_node(&"stones", 2.1, -0.75)
	# Wild food and fibre plants (farming update). Appended after everything above so older save ids stay put.
	var meadow := func(x: float, z: float, h: float) -> bool:
		return anywhere.call(x, z, h) and river_distance(x, z) > 25.0
	var wet_bank := func(x: float, z: float, _h: float) -> bool:
		var d := river_distance(x, z)
		return d > 9.0 and d < 26.0
	_scatter_kind(&"wild_grain", 18, 1.2, meadow)
	_scatter_kind(&"wild_carrot", 14, 1.0, meadow)
	_scatter_kind(&"herbs", 16, 0.9, anywhere)
	_scatter_kind(&"flax", 12, 1.1, meadow)
	_scatter_kind(&"hazel", 12, 1.6, away_from_spawn)
	# the dry strip of bank is only a few metres wide: many more tries for the bank plants
	_scatter_kind(&"reeds", 18, 1.0, wet_bank, 60)
	_scatter_kind(&"clay", 8, 1.2, wet_bank, 80)
	# A few right by the start so the first loop shows them.
	_spawn_node(&"wild_grain", -6.5, 9.0)
	_spawn_node(&"herbs", 7.5, 10.5)


func set_ground_wetness(v: float) -> void:
	if _terrain_mat:
		_terrain_mat.set_shader_parameter("rain_wetness", v)


## Forest density mask (0 clearing … 1 dense forest) from tree positions; drives terrain layers
## (needles vs grass) and decorative scatter.
func _build_forest_mask() -> void:
	const RES := 256
	const CANOPY_RADIUS := 5.0
	const COVER_PER_TREE := PI * CANOPY_RADIUS * CANOPY_RADIUS / ((SIZE / RES) * (SIZE / RES))
	var acc := PackedFloat32Array()
	acc.resize(RES * RES)
	for n: Node in _nodes.values():
		if not (n is ResourceNode and String((n as ResourceNode).kind).begins_with("tree")):
			continue
		var p := (n as Node3D).position
		# Distribute canopy area in square metres over the nearest texel centres.
		var uv := (Vector2(p.x, p.z) / SIZE + Vector2(0.5, 0.5)) * RES - Vector2(0.5, 0.5)
		for dy in 2:
			for dx in 2:
				var x := floori(uv.x) + dx
				var y := floori(uv.y) + dy
				if x < 0 or y < 0 or x >= RES or y >= RES:
					continue
				acc[y * RES + x] += COVER_PER_TREE * (1.0 - absf(uv.x - x)) * (1.0 - absf(uv.y - y))
	forest_mask = Image.create(RES, RES, false, Image.FORMAT_L8)
	for y in RES:
		for x in RES:
			var wx := (float(x) / RES - 0.5) * SIZE
			var wz := (float(y) / RES - 0.5) * SIZE
			var blend := _region_blend(wx, wz)
			var base := lerpf(_forest_density(blend[1], wx, wz), _forest_density(blend[0], wx, wz), blend[2])
			var clearing := 1.0 - smoothstep(190.0, 390.0, Vector2(wx, wz).distance_to(SPAWN))
			var value := lerpf(base, minf(base, 0.08), clearing)
			forest_mask.set_pixel(x, y, Color(clampf(maxf(value, acc[y * RES + x]), 0.0, 1.0), 0, 0))
	_terrain_mat.set_shader_parameter("forest_mask", ImageTexture.create_from_image(forest_mask))


func _build_biome_tint() -> Image:
	const RES := 256
	var img := Image.create(RES, RES, false, Image.FORMAT_RGB8)
	var colors := {
		&"aruun": Color(0.99, 1.0, 0.97),
		&"varkai": Color(1.0, 0.98, 0.93),
		&"meyra": Color(0.96, 0.99, 0.96),
		&"kharum": Color(0.96, 0.98, 1.0),
		&"ossara": Color(1.0, 0.98, 0.94),
		&"tavren": Color(0.95, 0.99, 0.94),
		&"tundra": Color(0.98, 0.99, 1.0),
	}
	for y in RES:
		for x in RES:
			var wx := (float(x) / RES - 0.5) * SIZE
			var wz := (float(y) / RES - 0.5) * SIZE
			var blend := _region_blend(wx, wz)
			var tint: Color = colors[blend[1]].lerp(colors[blend[0]], blend[2])
			img.set_pixel(x, y, tint)
	return img


func _forest_density(region: StringName, x: float, z: float) -> float:
	match region:
		&"tavren": return 0.88
		&"kharum": return 0.22
		&"ossara": return 0.06
		&"meyra": return 0.48 if river_distance(x, z) < 720.0 else 0.20
		&"varkai": return 0.12
		&"tundra": return 0.10
		_: return 0.26


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
	var hearth_stones: Array[Mesh] = []
	for path: String in AssetLib.ROCKS[&"small"]:
		hearth_stones.append(AssetLib.mesh(path))
	for i in 7:
		var a := TAU * i / 7.0
		var pos := Vector3(2.5 + cos(a) * 0.5, 0.0, 1.5 + sin(a) * 0.5)
		var xf := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 2.2), pos)
		spawn_scattered_resource(camp, "old_camp_stone_%d" % i, &"loose_stone", hearth_stones[i % hearth_stones.size()], xf)
	Graybox.part(camp, Graybox.cylinder(0.4, 0.4, 0.02, 10), Color(0.1, 0.1, 0.1), Vector3(2.5, 0.02, 1.5))
	var stash := Stash.new()
	stash.name = "Stash"
	stash.position = Vector3(-1.2, 0.0, -0.4)
	camp.add_child(stash)
	_nodes[stash.save_id] = stash
	for i in 5:
		var a := TAU * i / 5.0
		var pos := stash.position + Vector3(cos(a) * 0.75, 0.0, sin(a) * 0.75)
		var xf := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 2.4), pos)
		spawn_scattered_resource(camp, "old_camp_stash_stone_%d" % i, &"loose_stone", hearth_stones[i % hearth_stones.size()], xf)

	_build_stone_ford()

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


## Vadul de Piatră: a line of stepping stones across the gravel bar (solid rocks: they can be broken for stone).
func _build_stone_ford() -> void:
	var ford: Vector3 = FORDS[&"stone_ford"]
	var z := ford.x
	var c := Vector2(river_x(z), z)
	var t := Vector2(river_x(z + 2.0) - river_x(z - 2.0), 4.0).normalized()
	var across := Vector2(t.y, -t.x)
	var root := Node3D.new()
	root.name = "POI_StoneFord"
	add_child(root)
	var meshes: Array[Mesh] = []
	for path: String in AssetLib.ROCKS[&"medium"]:
		meshes.append(AssetLib.mesh(path))
	var r := RandomNumberGenerator.new()
	r.seed = SEED + 777
	var off := -13.0
	var i := 0
	while off <= 13.0:
		var p := c + across * off + t * r.randf_range(-0.6, 0.6)
		var sc := r.randf_range(0.6, 0.85)
		var basis := Basis(Vector3.UP, r.randf() * TAU).scaled(Vector3.ONE * sc)
		var at := Vector3(p.x, minf(height_at(p.x, p.y), 0.0) - 0.12 * sc, p.y)
		spawn_scattered_resource(root, "stone_ford_%d" % i, &"rock", meshes[i % meshes.size()], Transform3D(basis, at))
		_occupy(p.x, p.y, 1.0)
		off += r.randf_range(1.9, 2.4)
		i += 1


# ---------------------------------------------------------------- gameplay queries

func spawn_position() -> Vector3:
	return ground_point(SPAWN.x, SPAWN.y) + Vector3(0, 0.2, 0)


func ambient_temperature_at(pos: Vector3) -> float:
	var t := day_night.ambient_temperature()
	# climate bands: the tundra is ~10 °C colder (taiga a little), the southern jungle ~8 °C warmer
	t += 8.0 * jungle_at(pos.x, pos.z) - 10.0 * tundra_at(pos.x, pos.z) - 3.0 * (1.0 - smoothstep(-1200.0, -800.0, pos.z))
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
	for cave in caves:
		best = maxf(best, cave.shelter_at(pos))
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
			var extra := 0.0  # sturdier materials and closed gables keep more warmth in
			var roofs: Array[BuildingPiece] = []
			for sp in supports:
				if sp.built and sp.piece_class() == "wall" and bool(sp.def.get("shelter_wall", true)):
					walls += 1
					extra += sp.warmth()
				for r in dependents_of(sp):
					if r.built and r.piece_class() == "roof" and not r in roofs:
						roofed = true
						roofs.append(r)
			for r in roofs:
				extra += r.warmth()
				for g in dependents_of(r):
					if g.built and g.piece_class() == "gable":
						extra += 0.75
			if roofed:
				# Roof alone shelters a bit; each wall adds more (max with 3+ walls).
				best = maxf(best, 5.0 + 2.0 * mini(walls, 3) + minf(extra, 6.0))
	return best


## Bulk time skip (sleep): advances the clock and every time-simulated system consistently.
func advance_time(seconds: float) -> void:
	day_night.advance(seconds)
	for n in get_tree().get_nodes_in_group("time_sim"):
		n.simulate(seconds)
	_advance_pending_regrowth(seconds)


func _advance_pending_regrowth(seconds: float) -> void:
	for id: String in _pending_region_states.keys():
		var state: Dictionary = _pending_region_states[id]
		var remaining := float(state.get("g", 0.0))
		if remaining > 0.0:
			if remaining <= seconds:
				_pending_region_states.erase(id) # Fully regrown on next visit.
			else:
				state.g = remaining - seconds


# ---------------------------------------------------------------- persistence

func collect_save() -> Dictionary:
	var nodes := _pending_region_states.duplicate()
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
		"map_fog": Marshalls.raw_to_base64(map_fog.compress(FileAccess.COMPRESSION_DEFLATE)),
		"waypoint": [] if waypoint == Vector3.INF else [waypoint.x, waypoint.y, waypoint.z],
		"nodes": nodes, "pickups": pickups, "structures": structures, "structure_counter": _structure_counter,
		"regional_bases": Camps.REGIONAL_BASES.keys() if camps else [],
		"weather": weather.save_state(), "carcasses": wildlife.save_state(), "wildlife": wildlife.save_director(),
		"factions": factions.save_state() if factions else {}, "npcs": camps.save_state() if camps else {},
	}


func apply_save(d: Dictionary) -> void:
	day_night.time_hours = float(d.get("time_hours", 12.0))
	day_night.day = int(d.get("day", 1))
	if d.has("weather"):
		weather.load_state(d.weather)
	wildlife.load_state(d.get("carcasses", []))
	wildlife.load_director(d.get("wildlife", {}))
	if factions:
		factions.load_state(d.get("factions", {}))
	if camps:
		camps.load_state(d.get("npcs", {}))
	journal.clear()
	if d.has("map_fog"):
		var raw := Marshalls.base64_to_raw(str(d.map_fog)).decompress(MapData.FOG_RES * MapData.FOG_RES, FileAccess.COMPRESSION_DEFLATE)
		if raw.size() == MapData.FOG_RES * MapData.FOG_RES:
			map_fog = raw
	var wp: Array = d.get("waypoint", [])
	waypoint = Vector3(float(wp[0]), float(wp[1]), float(wp[2])) if wp.size() == 3 else Vector3.INF
	for k: Variant in d.get("journal", []):
		journal.append(str(k))
	var nodes: Dictionary = d.get("nodes", {})
	_pending_region_states.clear()
	for id: String in nodes.keys():
		if _nodes.has(id):
			_nodes[id].load_state(nodes[id])
		elif id.begins_with("region_"):
			_pending_region_states[id] = nodes[id]
	for p in pickups_root.get_children():
		pickups_root.remove_child(p)  # detach now so restored nodes keep their names
		p.queue_free()
	for p: Dictionary in d.get("pickups", []):
		var st := ItemStack.from_dict(p.item)
		if ItemDB.get_item(st.id):
			spawn_pickup(st, _vec(p.pos))
	for s in structures_root.get_children():
		structures_root.remove_child(s)
		s.queue_free()
	_structure_counter = int(d.get("structure_counter", 0))
	for s: Dictionary in d.get("structures", []):
		var xf := Transform3D(Basis(Vector3.UP, float(s.get("yaw", 0.0))), _vec(s.pos))
		spawn_structure(StringName(str(s.type)), xf, s.get("state", {}), str(s.get("id", "")))
	if camps:
		camps.build_regional_bases(d.get("regional_bases", []))


func get_node_by_save_id(id: String) -> Node:
	return _nodes.get(id)


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
