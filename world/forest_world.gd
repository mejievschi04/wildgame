class_name ForestWorld
extends Node3D
## Baked open world (8 × 8 km playable): the southwest coast, central valley, three clan territories
## and the snowy northeastern range. Resources and locations use a deterministic scatter seed.
## Deterministic seed → generated nodes have stable ids, so saves only store changed state.

const SIZE := 8400.0
const HALF := SIZE * 0.5
const SEED := 20261121
const WATER_LEVEL := 0.0
const PLAYABLE := 4000.0
const Layout := preload("res://world/world_layout.gd")
static var SPAWN := Layout.point("player_camp")
static var OLD_CAMP := SPAWN + Vector2(55.0, -58.0)
const LAKE_CENTER := Vector2(1200.0, -670.0)
const LAKE_RADIUS_X := 160.0
const LAKE_RADIUS_Z := 112.0
## Lake bounds are shared with the terrain bake in data/world_layout.json.
const LAKES := [Vector4(1200.0, -670.0, 160.0, 112.0)]
const GLACIER_SNOUT := -3330.0
const GLACIER_HALF_W := 170.0
## Relief baked offline (tools/bake_reference_world.py): the final float32 heights on a BAKE_N² grid
## (~2 m) over the whole terrain, zlib-compressed, with the river's cut, lake, fords and camp clearings already in.
## The visible terrain (TerrainLod), its collision (one HeightMapShape3D) and height_at() all use this grid and the
## same triangulation. Creeks (with their water levels) and the shader masks come from the same run.
const TERRAIN_BIN := Layout.TERRAIN_DIR + "height.bin"
const TERRAIN_MASKS := Layout.TERRAIN_DIR + "masks.png"
const STREAMS_JSON := Layout.TERRAIN_DIR + "streams.json"
const CAVES_JSON := Layout.TERRAIN_DIR + "caves.json"
const BAKE_N := 4097
const BAKE_CELL := SIZE / (BAKE_N - 1)
## Shallow crossings of the main river: river z, half-length along the river (m), bed height (water ~0.15 m deep).
## Cut into the bake: keep in sync with tools/gen_terrain.py FORDS.
const FORDS := {
	&"stone_ford": Vector3(-200.0, 9.0, -0.12),  # Vadul de Piatră: quick, open, stepping stones
	&"dry_ford": Vector3(1510.0, 15.0, -0.08),   # Vadul Secat: the southern gravel bar, hard to spot
}
const CREEK_HASH := 32.0

## Region centers also anchor the strategic map and future clan strongholds.
static var REGIONS := {
	&"aruun": Layout.point("aruun"),
	&"varkai": Layout.point("red"),
	&"meyra": Vector2(1300.0, -470.0),
	&"kharum": Layout.point("stone"),
	&"ossara": Layout.point("player_camp"),
	&"tavren": Vector2(-850.0, -1150.0),
	&"tundra": Vector2(1550.0, -2250.0),
	&"sakhal": Layout.point("north"),
	&"ilmar": Vector2(2800.0, -3640.0),
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
var raids: Raids
var npc_nav: NpcNav
var meadow_grass: MeadowGrass
var far_forest: FarForest
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
var landmarks: Landmarks
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
	_build_landmarks()  # after the forest mask: bones and stone rings keep to open ground
	_terrain_mat.set_shader_parameter("grove_tex", ImageTexture.create_from_image(FarForest.grove_image(512)))
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
		raids = Raids.new()
		raids.name = "Raids"
		raids.world = self
		add_child(raids)
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
	var relief := load(Layout.TERRAIN_DIR + "relief.png") as Texture2D
	map_image = relief.get_image() if relief else MapData.cached()
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
	return Layout.river_x(Layout.data.rivers[0], z)


func river_distance(x: float, z: float) -> float:
	var d := INF
	for river: Dictionary in Layout.data.rivers:
		var points: Array = river.points
		var at := clampf(z, float(points[0][0]), float(points[-1][0]))
		var center := Layout.river_x(river, at)
		var slope := (Layout.river_x(river, at + 2.0) - Layout.river_x(river, at - 2.0)) * 0.25
		d = minf(d, Vector2((x - center) / sqrt(1.0 + slope * slope), z - at).length())
	return d


## Distance to running water of any size: the river and its channels, or a creek. A creek's waterline is ~2–3.5 m
## from its centre (the river's ~10 m), so its distance is offset to read like the river's on the banks.
func water_distance(x: float, z: float) -> float:
	return minf(river_distance(x, z), creek_distance(x, z) + 7.0)



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
		if (d[k] as Dictionary).has("camp"):
			_add_camp_site(Camps.site(d[k]), 10.0)
	for id: String in Camps.REGIONAL_BASES:
		var center := Camps.site(Camps.REGIONAL_BASES[id])
		var radius := Camps.Layout.radius(id)
		_add_camp_site(center, radius)
		# Scatter queries scan adjacent 6 m cells. Tile the reserved area so even
		# the tree closest to a gate sees the city reservation.
		for x in range(-ceili(radius), ceili(radius) + 1, 6):
			for z in range(-ceili(radius), ceili(radius) + 1, 6):
				var offset := Vector2(x, z)
				if offset.length() <= radius:
					_occupy(center.x + x, center.y + z, 4.4)


func _add_camp_site(c: Vector2, flat_radius: float) -> void:
	_camp_sites.append(c)
	_camp_clearings.append(Vector2(flat_radius, flat_radius + 12.0))


func in_settlement(x: float, z: float) -> bool:
	var at := Vector2(x, z)
	for id: String in Camps.REGIONAL_BASES:
		var center := Camps.site(Camps.REGIONAL_BASES[id])
		var radius := Camps.Layout.radius(id)
		if center.distance_squared_to(at) < radius * radius:
			return true
	return false


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
		push_error("ForestWorld: %s is missing or damaged (run tools/bake_reference_world.py)" % TERRAIN_BIN)
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
	return smoothstep(1300.0, 2800.0, z + 120.0 * sin(x * 0.004)) * smoothstep(-1000.0, 1100.0, x)


static func tundra_at(x: float, z: float) -> float:
	return (1.0 - smoothstep(-1770.0, -1320.0, z + 85.0 * sin(x * 0.005 + 2.0))) \
		* smoothstep(0.0, 900.0, x) * (1.0 - taiga_at(x, z))


## The cold north beyond the northern range: snowy taiga, frozen water, the glacier mountains (0..1).
static func taiga_at(x: float, z: float) -> float:
	return (1.0 - smoothstep(-2560.0, -2020.0, z + 90.0 * sin(x * 0.0037 + 0.7))) * smoothstep(450.0, 1500.0, x)


## Any cold climate (tundra or taiga): cold-hardy animals, frost, snow.
static func cold_at(x: float, z: float) -> float:
	return maxf(tundra_at(x, z), taiga_at(x, z))


## 0..1 on the glacier's ice (keep in sync with gen_terrain.py glacier_at and biome.gdshaderinc).
static func glacier_at(x: float, z: float) -> float:
	var rx := 3050.0 + 110.0 * sin(z * 0.002)
	var d := absf(x - rx)
	var hw := glacier_half_w(z)
	return (1.0 - smoothstep(hw - 40.0, hw + 25.0, d)) * smoothstep(GLACIER_SNOUT + 10.0, GLACIER_SNOUT - 70.0, z)


## Half-width of the glacier's ice at z (gen_terrain.py glacier_half_w): broad cirque, narrower tongue.
static func glacier_half_w(z: float) -> float:
	var up := smoothstep(GLACIER_SNOUT, -4150.0, z)
	return GLACIER_HALF_W * (0.75 + 0.7 * up) + 28.0 * sin(z * 0.011 + 1.7) + 12.0 * sin(z * 0.047)


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
	for river: Dictionary in Layout.data.rivers:
		var points: Array = river.points
		var line := func(z: float) -> float: return Layout.river_x(river, z)
		_build_water_channel(river.name, float(points[0][0]), float(points[-1][0]), 15.0,
			float(river.width) + 8.0, line, m, true)
	_build_ocean(m)
	_build_lake(m)
	for i in creeks.size():
		_build_creek(i, m)


func _build_ocean(material: ShaderMaterial) -> void:
	var mesh := SurfaceTool.new()
	mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	const SECTIONS := 140
	for i in range(SECTIONS + 1):
		var x := lerpf(-7000.0, 3000.0, float(i) / SECTIONS)
		for z: float in [Layout.coast_z(x) - 45.0, 7900.0]:
			mesh.set_normal(Vector3.UP)
			mesh.set_uv(Vector2(x, z) / 25.0)
			mesh.add_vertex(Vector3(x, WATER_LEVEL + 0.018, z))
	for i in SECTIONS:
		var a := i * 2
		for vertex in [a, a + 2, a + 1, a + 1, a + 2, a + 3]:
			mesh.add_index(vertex)
	var ocean := MeshInstance3D.new()
	ocean.name = "SouthwestSea"
	ocean.mesh = mesh.commit()
	ocean.material_override = material
	ocean.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ocean)


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
	for i in LAKES.size():
		_build_one_lake(i, LAKES[i], material)


## A lake's surface and its water volume. A lake in the cold north is frozen: an ice sheet you can walk on.
func _build_one_lake(index: int, lk: Vector4, material: ShaderMaterial) -> void:
	const SEGMENTS := 64
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3(lk.x, WATER_LEVEL + 0.025, lk.y)
	for i in SEGMENTS:
		var a0 := TAU * float(i) / SEGMENTS
		var a1 := TAU * float(i + 1) / SEGMENTS
		var p0 := Vector3(lk.x + cos(a0) * lk.z, WATER_LEVEL + 0.025, lk.y + sin(a0) * lk.w)
		var p1 := Vector3(lk.x + cos(a1) * lk.z, WATER_LEVEL + 0.025, lk.y + sin(a1) * lk.w)
		for p: Vector3 in [center, p0, p1]:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(p.x / 18.0, p.z / 18.0))
			st.add_vertex(p)
	var surface := MeshInstance3D.new()
	surface.add_to_group("far_scenery")
	surface.name = "SouthernLake_Surface" if index == 0 else "Lake%d_Surface" % index
	surface.mesh = st.commit()
	surface.material_override = material
	surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(surface)
	var lake := WaterBody.new()
	lake.name = "LakeWater" if index == 0 else "Lake%dWater" % index
	add_child(lake)
	lake.setup_ellipse(lk.z, lk.w, WATER_LEVEL)
	lake.position = Vector3(lk.x, 0.0, lk.y)
	if taiga_at(lk.x, lk.y) > 0.5:
		_add_ice(surface.mesh, "Lake%d_Ice" % index)


## Walkable ice over frozen water: a static body on the surface mesh (the water shader draws it as ice there).
func _add_ice(mesh: Mesh, ice_name: String) -> void:
	var body := StaticBody3D.new()
	body.name = ice_name
	body.collision_layer = 1
	body.collision_mask = 0
	body.add_to_group("terrain")
	body.add_to_group("ice")
	var shape := mesh.create_trimesh_shape()
	shape.backface_collision = true
	Graybox.add_shape(body, shape)
	add_child(body)


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
	# in the cold north the river is frozen over: walkable ice along that stretch
	var ice := SurfaceTool.new()
	ice.begin(Mesh.PRIMITIVE_TRIANGLES)
	var frozen := 0
	for i in sections:
		var za := lerpf(start_z, end_z, float(i) / sections)
		var zb := lerpf(start_z, end_z, float(i + 1) / sections)
		if taiga_at(float(center_x.call(za)), za) < 0.5 or taiga_at(float(center_x.call(zb)), zb) < 0.5:
			continue
		var quad: Array[Vector3] = []
		for z: float in [za, zb]:
			var c := float(center_x.call(z))
			var tg := Vector2(float(center_x.call(z + 1.0)) - float(center_x.call(z - 1.0)), 2.0).normalized()
			var sd := Vector2(tg.y, -tg.x)
			for edge: float in [-1.0, 1.0]:
				var p: Vector2 = Vector2(c, z) + sd * half_width * edge
				quad.append(Vector3(p.x, WATER_LEVEL + 0.025, p.y))
		for v: Vector3 in [quad[0], quad[1], quad[2], quad[1], quad[3], quad[2]]:
			ice.set_normal(Vector3.UP)
			ice.add_vertex(v)
		frozen += 1
	if frozen > 0:
		_add_ice(ice.commit(), "%s_Ice" % channel_name)
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
		_occupy(SPAWN.x + s[1], SPAWN.y + s[2], 1.5)
		_spawn_node(s[0], SPAWN.x + s[1], SPAWN.y + s[2])
	# Flint on the river bank nearest to spawn.
	for dz: float in [-6.0, 14.0]:
		var z := SPAWN.y + dz
		var x := river_x(z) - 14.0  # on the dry bank: the waterline wanders 4-18 m from the channel centre
		while height_at(x, z) < 0.6 and x > river_x(z) - 30.0:
			x -= 1.0
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
	_spawn_node(&"sticks", SPAWN.x + (2), SPAWN.y + (0.75))
	_spawn_node(&"stones", SPAWN.x + (2.1), SPAWN.y + (-0.75))
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
	_spawn_node(&"wild_grain", SPAWN.x + (-6.5), SPAWN.y + (9))
	_spawn_node(&"herbs", SPAWN.x + (7.5), SPAWN.y + (10.5))
	# Dry twig bushes (sticks without hunting through the grass, as Far Cry Primal's wood bushes). Appended last so
	# older save ids stay put; a few in sight of the start.
	for offset: Vector2 in [Vector2(6.5, -3.0), Vector2(-7.5, 1.5), Vector2(1.0, 8.5), Vector2(-2.5, -9.5)]:
		var at := SPAWN + offset
		if is_scatter_site_free(at.x, at.y, 1.2):
			_occupy(at.x, at.y, 1.2)
			_spawn_node(&"deadwood", at.x, at.y, _rng.randf_range(0.9, 1.1))
	_scatter_kind(&"deadwood", 120, 1.3, anywhere)


func set_ground_wetness(v: float) -> void:
	if _terrain_mat:
		_terrain_mat.set_shader_parameter("rain_wetness", v)


## Forest density mask (0 clearing … 1 dense forest) from tree positions; drives terrain layers
## (needles vs grass) and decorative scatter.
func _build_forest_mask() -> void:
	const RES := 512  # ~16 m texels over the 8 km map
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
		&"sakhal": Color(0.97, 0.99, 1.02),
		&"ilmar": Color(0.98, 1.0, 1.03),
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
		&"sakhal": return 0.8
		&"ilmar": return 0.15
		_: return 0.26


# ---------------------------------------------------------------- POIs

## Skeletons, totems, standing stones and hunters' camps across the wilds (Landmarks), clear of the start, the
## clans' camps and the regional bases.
func _build_landmarks() -> void:
	var avoid: Array[Vector2] = [SPAWN, OLD_CAMP]
	for c: Vector2 in _camp_sites:
		avoid.append(c)
	for b: Dictionary in Camps.REGIONAL_BASES.values():
		avoid.append(Vector2(float(b.camp[0]), float(b.camp[1])))
	landmarks = Landmarks.new()
	landmarks.name = "Landmarks"
	add_child(landmarks)
	landmarks.build(self, avoid)

func _build_pois() -> void:
	# Abandoned camp above the river: collapsed lean-to, cold hearth, cache.
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
	var signpost := Node3D.new()
	signpost.position = Vector3(-1.7, 0.72, -0.65)
	camp.add_child(signpost)
	Graybox.part_mat(signpost, Graybox.box(Vector3(0.36, 1.45, 0.1)), wood, Vector3.ZERO)
	var pale_wood := Color(0.86, 0.64, 0.4)
	for i in range(-1, 2):
		Graybox.part(signpost, Graybox.box(Vector3(0.018, 0.14, 0.008)), pale_wood,
			Vector3(i * 0.085, 0.52, 0.052), Vector3(0, 0, -10))
	Graybox.part(signpost, Graybox.box(Vector3(0.02, 0.11, 0.008)), pale_wood,
		Vector3(0, 0.52, 0.058), Vector3(0, 0, 60))
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
	var cz := SPAWN.y + 26.0
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
	# the snowy taiga beyond the range is bitter (~ -16 °C colder), the glacier colder still
	t -= 16.0 * taiga_at(pos.x, pos.z) + 6.0 * glacier_at(pos.x, pos.z)
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
		"layout_version": Layout.VERSION,
		"time_hours": day_night.time_hours, "day": day_night.day, "journal": journal.duplicate(),
		"map_fog": Marshalls.raw_to_base64(map_fog.compress(FileAccess.COMPRESSION_DEFLATE)),
		"waypoint": [] if waypoint == Vector3.INF else [waypoint.x, waypoint.y, waypoint.z],
		"nodes": nodes, "pickups": pickups, "structures": structures, "structure_counter": _structure_counter,
		"regional_bases": Camps.REGIONAL_BASES.keys() if camps else [],
		"city_services": Camps.REGIONAL_BASES.keys() if camps else [],
		"weather": weather.save_state(), "carcasses": wildlife.save_state(), "wildlife": wildlife.save_director(),
		"factions": factions.save_state() if factions else {}, "npcs": camps.save_state() if camps else {},
	}


func apply_save(d: Dictionary) -> void:
	var current := uses_current_layout(d)
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
	if current and d.has("map_fog"):
		var raw := Marshalls.base64_to_raw(str(d.map_fog)).decompress(MapData.FOG_RES * MapData.FOG_RES, FileAccess.COMPRESSION_DEFLATE)
		if raw.size() == MapData.FOG_RES * MapData.FOG_RES:
			map_fog = raw
	var wp: Array = d.get("waypoint", []) if current else []
	waypoint = Vector3(float(wp[0]), float(wp[1]), float(wp[2])) if wp.size() == 3 else Vector3.INF
	for k: Variant in d.get("journal", []):
		journal.append(str(k))
	var nodes: Dictionary = d.get("nodes", {})
	_pending_region_states.clear()
	for id: String in nodes.keys() if current else []:
		if _nodes.has(id):
			_nodes[id].load_state(nodes[id])
		elif id.begins_with("region_"):
			_pending_region_states[id] = nodes[id]
	for p in pickups_root.get_children():
		pickups_root.remove_child(p)  # detach now so restored nodes keep their names
		p.queue_free()
	var old_heights := PackedFloat32Array()
	if not current and (not d.get("structures", []).is_empty() or not d.get("pickups", []).is_empty()):
		var old_bake := FileAccess.get_file_as_bytes("res://assets/terrain/terrain_height.bin")
		old_heights = old_bake.decompress(BAKE_N * BAKE_N * 4, FileAccess.COMPRESSION_DEFLATE).to_float32_array()
	for p: Dictionary in d.get("pickups", []):
		var st := ItemStack.from_dict(p.item)
		if ItemDB.get_item(st.id):
			var pos := _vec(p.pos)
			spawn_pickup(st, pos if current else _relocate_legacy_point(pos, old_heights))
	for s in structures_root.get_children():
		if not current and _layout_structure(String(s.name)):
			continue
		structures_root.remove_child(s)
		s.queue_free()
	_structure_counter = int(d.get("structure_counter", 0))
	for s: Dictionary in d.get("structures", []):
		var id := str(s.get("id", ""))
		if not current and _layout_structure(id):
			continue
		var pos := _vec(s.pos)
		var xf := Transform3D(Basis(Vector3.UP, float(s.get("yaw", 0.0))),
			pos if current else _relocate_legacy_point(pos, old_heights))
		spawn_structure(StringName(str(s.type)), xf, s.get("state", {}), id)
	if camps and current:
		camps.build_regional_bases(d.get("regional_bases", []))
		camps.build_city_services(d.get("city_services", []))


func uses_current_layout(save: Dictionary) -> bool:
	return int(save.get("layout_version", 1)) == Layout.VERSION


static func _layout_structure(id: String) -> bool:
	return id.begins_with("camp_") or id.begins_with("base_") or id.begins_with("city_") \
		or id.begins_with("player_camp_")


func _relocate_legacy_point(pos: Vector3, old_heights: PackedFloat32Array) -> Vector3:
	var at := Vector2(pos.x, pos.z)
	var lift := 0.12
	if old_heights.size() == BAKE_N * BAKE_N:
		var x := clampi(roundi((at.x + HALF) / BAKE_CELL), 0, BAKE_N - 1)
		var z := clampi(roundi((at.y + HALF) / BAKE_CELL), 0, BAKE_N - 1)
		lift = pos.y - old_heights[z * BAKE_N + x]
	# Old player settlements near the original spawn move together to the new camp.
	if at.length() < 280.0:
		at += SPAWN
	return Vector3(at.x, maxf(height_at(at.x, at.y), WATER_LEVEL) + lift, at.y)


func get_node_by_save_id(id: String) -> Node:
	return _nodes.get(id)


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
