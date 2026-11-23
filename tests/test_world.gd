extends TestCase
## Integration: boots a real GameSession headless and drives the Phase 1 loop through public APIs.

var session: GameSession


func _boot() -> GameSession:
	Game.pending_save = {}
	var s: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s)
	for i in 5:
		await tree.physics_frame
	return s


func _teardown(s: GameSession) -> void:
	s.queue_free()
	await tree.process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func test_session_boots_and_player_stands() -> void:
	var s: GameSession = await _boot()
	for i in 60:
		await tree.physics_frame
	var p := s.player
	check(p.is_on_floor(), "player lands on terrain (y=%.2f)" % p.global_position.y)
	check(p.global_position.y > ForestWorld.WATER_LEVEL, "spawn is dry land")
	for kind: StringName in [&"stones", &"sticks"]:
		var reached := false
		for pile: ResourceNode in tree.get_nodes_in_group("gather_pile"):
			var offset := pile.global_position - p.global_position
			if pile.kind != kind or offset.x <= 0.0 or offset.length() > 2.4:
				continue
			p.camera.rotation = Vector3.ZERO
			check(p.camera.is_position_in_frustum(pile.global_position), "starter %s visible at spawn" % kind)
			p.camera.look_at(pile.global_position + Vector3.UP * 0.18)
			p.ray.force_raycast_update()
			if p.ray.get_collider() == pile:
				pile.perform_interaction(p, &"interact")
				reached = pile.remaining < pile.capacity
				break
		check(reached, "starter %s in front of player and reachable by hand" % kind)
	# Sample both triangles off-grid on the bank, where the landform curves sharply.
	for xz: Vector2 in [Vector2(172, 13), Vector2(178, 17)]:
		var top := Vector3(xz.x, 300.0, xz.y)
		var ray := PhysicsRayQueryParameters3D.create(top, Vector3(xz.x, -10.0, xz.y), 1)
		var hit := s.world.get_world_3d().direct_space_state.intersect_ray(ray)
		check(hit.get("collider") == s.world.get_node("TerrainBody"), "bank ray hits terrain")
		if not hit.is_empty():
			near(s.world.height_at(xz.x, xz.y), hit.position.y, 0.01, "placement matches terrain collision")
	var n := tree.get_nodes_in_group("resource_node").size()
	check(n > 400, "forest scattered (%d nodes)" % n)
	check("JOURNAL_START" in s.world.journal, "intro journal entry")
	await _teardown(s)


func test_wilderness_resources_survive_streaming() -> void:
	var s: GameSession = await _boot()
	var v := s.world.get_node("Vegetation") as Vegetation
	var region := Vector2(1050, 580)
	s.player.global_position = s.world.ground_point(region.x, region.y) + Vector3.UP
	v._stream_near(region)
	await tree.physics_frame
	await tree.physics_frame
	var trunk: TreeNode
	var stone: ResourceNode
	for n: ResourceNode in tree.get_nodes_in_group("resource_node"):
		if not n.node_id.begins_with("region_"):
			continue
		if n is TreeNode:
			trunk = n
		elif n.kind == &"stones":
			stone = n
	check(trunk != null and stone != null, "harvestable trees and stones outside the starter valley")
	if trunk and stone:
		var id := trunk.node_id
		var stone_id := stone.node_id
		var pos := trunk.global_position + Vector3.UP
		var ray := PhysicsRayQueryParameters3D.create(pos + Vector3.RIGHT * 0.8, pos, 1)
		var hit := s.world.get_world_3d().direct_space_state.intersect_ray(ray)
		check(hit.get("collider") == trunk, "wilderness trunk blocks the player's collision layer")
		for i in trunk.fell_hits:
			trunk.on_hit(s.player, ItemDB.get_item(&"stone_axe"))
		check(trunk.stage == TreeNode.Stage.FALLING, "wilderness tree can be felled")
		trunk.complete_fall()
		stone.perform_interaction(s.player, &"interact")
		v._stream_near(ForestWorld.SPAWN)
		var saved := s.world.collect_save()
		v._stream_near(region)
		check(s.world.get_node_by_save_id(id) == trunk and trunk.stage == TreeNode.Stage.FALLEN, "felled tree persists on return")
		await _teardown(s)
		s = await _boot()
		s.world.apply_save(saved)
		check(s.world.collect_save().nodes.has(id), "saving before revisiting preserves distant progress")
		v = s.world.get_node("Vegetation")
		v._stream_near(region)
		var loaded := s.world.get_node_by_save_id(id) as TreeNode
		var pile := s.world.get_node_by_save_id(stone_id) as ResourceNode
		check(loaded != null and loaded.stage == TreeNode.Stage.FALLEN, "distant felled tree restored")
		check(pile != null and pile.remaining == pile.capacity - 1, "distant gathering restored")
	await _teardown(s)


func test_terrain_and_tree_textures() -> void:
	for suffix in ["albedo", "normal", "arm"]:
		var atlas := load("res://assets/textures/terrain/T_Terrain_%s.jpg" % suffix) as TextureLayered
		check(atlas != null and atlas.get_layered_type() == TextureLayered.LAYERED_TYPE_2D_ARRAY
			and atlas.get_layers() == 6, "six terrain layers in %s" % suffix)
	for species: StringName in [&"spruce", &"pine", &"alder"]:
		for path: String in AssetLib.TREES[species]:
			var mesh := AssetLib.mesh(path)
			var bark := false
			var foliage := false
			for surface in mesh.get_surface_count():
				var mat := mesh.surface_get_material(surface)
				if mat is BaseMaterial3D:
					bark = bark or mat.albedo_texture != null
				elif mat is ShaderMaterial:
					foliage = foliage or mat.get_shader_parameter("albedo_tex") is Texture2D
			check(bark and foliage, "textured bark and foliage in %s" % path.get_file())


func test_world_generation_deterministic() -> void:
	var s1: GameSession = await _boot()
	var a: Vector3 = s1.world.get_node_by_save_id("tree_pine_050").global_position
	await _teardown(s1)
	var s2: GameSession = await _boot()
	var b: Vector3 = s2.world.get_node_by_save_id("tree_pine_050").global_position
	check(a.is_equal_approx(b), "same seed → same node positions")
	await _teardown(s2)


func test_core_loop_gather_craft_fire_cook() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var w := s.world
	# Gather by hand.
	var sticks: ResourceNode = w.get_node_by_save_id("sticks_000")
	sticks.perform_interaction(p, &"interact")
	eq(p.inventory.count_of(&"stick"), 2, "gathered sticks")
	var stones: ResourceNode = w.get_node_by_save_id("stones_000")
	for i in 3:
		stones.perform_interaction(p, &"interact")
	eq(stones.remaining, 0, "stone pile depleted")
	check(stones.get_interactions(p)[0].enabled == false, "depleted pile not interactable")
	# Tool-gated harvesting.
	var tree_node: TreeNode = w.get_node_by_save_id("tree_pine_000")
	check(not tree_node.on_hit(p, null), "cannot chop barehanded")
	p.inventory.add_item(&"fiber", 10)
	p.inventory.add_item(&"stone", 6)
	p.inventory.add_item(&"stick", 6)
	var res := Crafting.craft(ItemDB.get_recipe(&"stone_axe"), p.inventory, [])
	check(res.ok, "crafted axe")
	p.inventory.equip_slot(p.inventory.first_slot_of(&"stone_axe"))
	var axe := p.inventory.hand.get_data()
	for i in tree_node.fell_hits:
		check(tree_node.on_hit(p, axe), "chop with axe")
	eq(tree_node.stage, TreeNode.Stage.FALLING, "tree starts falling after enough hits")
	tree_node.complete_fall()
	for i in TreeNode.LIMB_HITS:
		check(tree_node.on_hit(p, axe), "lop off the crown")
	check(tree_node.on_hit(p, axe), "buck the fallen trunk")
	for l: Node in tree.get_nodes_in_group("pickup"):
		if l is LogPiece:
			l.perform_interaction(p, &"interact")  # the log rolls off the trunk; pick it up
	eq(p.inventory.count_of(&"wood"), 1, "got wood")
	# Campfire: place, fuel, ignite, warmth, cook.
	check(Crafting.craft(ItemDB.get_recipe(&"campfire_kit"), p.inventory, []).ok, "crafted campfire kit")
	var fire: Campfire = w.spawn_structure(&"campfire", Transform3D(Basis(), p.global_position + Vector3(1.5, 0, 0)))
	fire.perform_interaction(p, &"interact")  # add fuel (stick)
	check(fire.fuel > 0.0 and not fire.lit, "fuel added, not lit yet")
	fire.perform_interaction(p, &"interact")  # ignite
	check(fire.lit, "fire lit")
	check("JOURNAL_FIRE" in w.journal, "fire journal entry")
	check(w.get_warmth_at(p.global_position) > 10.0, "fire warms the player")
	check(&"campfire" in w.get_stations_near(p.global_position), "lit fire is a crafting station")
	p.inventory.add_item(&"meat_raw", 1)
	var cook_opt := fire.get_interactions(p).filter(func(o: Dictionary) -> bool: return o.get("op") == &"cook")
	check(not cook_opt.is_empty(), "cook option offered")
	fire.perform_interaction(p, cook_opt[0].action)
	fire.add_fuel(300.0)
	fire.simulate(45.0)
	fire.perform_interaction(p, &"interact")  # take cooked
	eq(p.inventory.count_of(&"meat_cooked"), 1, "meat cooked")
	fire.simulate(Campfire.MAX_FUEL + 10.0)
	check(not fire.lit, "fire burns out")
	await _teardown(s)


func test_water_and_waterskin() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var water: WaterBody = s.world.get_node("Water")
	p.stats.thirst = 40.0
	water.perform_interaction(p, &"interact")
	check(p.stats.thirst > 50.0, "drinking restores hydration")
	p.inventory.add_item(&"waterskin_empty")
	water.perform_interaction(p, &"alt_interact")
	eq(p.inventory.count_of(&"waterskin_raw"), 1, "waterskin filled")
	var i := p.inventory.first_slot_of(&"waterskin_raw")
	p.consume_slot(i)
	eq(p.inventory.count_of(&"waterskin_empty"), 1, "container returned after drinking")
	await _teardown(s)


func test_sleep_skips_to_morning() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var w := s.world
	w.day_night.time_hours = 22.0
	var fire: Campfire = w.spawn_structure(&"campfire", Transform3D(Basis(), p.global_position + Vector3(1.2, 0, 0)))
	fire.add_fuel(Campfire.MAX_FUEL)
	fire.ignite()
	var bed: Node3D = w.spawn_structure(&"bed", Transform3D(Basis(), p.global_position + Vector3(-1.5, 0, 0)))
	check(p.can_sleep().ok, "can sleep when warm at night")
	p.sleep_at(bed)
	check(w.day_night.day == 2, "a new day started")
	check(w.day_night.time_hours >= 6.0 and w.day_night.time_hours < 7.0, "woke in the morning (%.2f)" % w.day_night.time_hours)
	check(p.stats.rest > 95.0, "rested")
	check(fire.fuel < Campfire.MAX_FUEL, "fire burned during the night")
	await _teardown(s)


func test_cold_blocks_sleep() -> void:
	var s: GameSession = await _boot()
	s.world.day_night.time_hours = 2.0
	check(not s.player.can_sleep().ok, "cannot sleep in the freezing night without fire")
	await _teardown(s)


func test_save_and_restore_world_state() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var w := s.world
	var bush: ResourceNode = w.get_node_by_save_id("bush_000")
	bush.perform_interaction(p, &"interact")
	w.spawn_structure(&"campfire", Transform3D(Basis(), p.global_position + Vector3(2, 0, 0)), {"fuel": 120.0, "lit": true})
	w.spawn_pickup(ItemStack.new(&"flint", 3), p.global_position + Vector3(0, 1, 2))
	w.day_night.time_hours = 18.25
	p.stats.hunger = 42.0
	p.inventory.add_item(&"flint_knife")
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))  # through JSON like real saves
	await _teardown(s)

	Game.pending_save = data
	var s2: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s2)
	for i in 3:
		await tree.physics_frame
	var bush2: ResourceNode = s2.world.get_node_by_save_id("bush_000")
	eq(bush2.remaining, bush2.capacity - 1, "harvest state restored")
	near(s2.world.day_night.time_hours, 18.25, 0.05, "time restored")
	near(s2.player.stats.hunger, 42.0, 0.5, "stats restored")
	eq(s2.player.inventory.count_of(&"flint_knife"), 1, "inventory restored")
	var fires := tree.get_nodes_in_group("campfire").filter(func(n: Node) -> bool: return not String(n.name).begins_with("camp_"))
	check(fires.size() == 1 and (fires[0] as Campfire).lit, "lit campfire restored")
	eq(tree.get_nodes_in_group("pickup").size(), 1, "pickup restored")
	await _teardown(s2)


func _region_flint() -> Array[ResourceNode]:
	var out: Array[ResourceNode] = []
	for n: ResourceNode in tree.get_nodes_in_group("resource_node"):
		if n.kind == &"flint" and n.node_id.begins_with("region_") and not n.is_queued_for_deletion():
			out.append(n)
	return out


func test_flint_beyond_the_start_valley() -> void:
	var s: GameSession = await _boot()
	var v := s.world.get_node("Vegetation") as Vegetation
	var kharum := Vector2(-1400, 80)
	s.player.global_position = s.world.ground_point(kharum.x, kharum.y) + Vector3.UP
	v._stream_near(kharum)
	await tree.physics_frame
	var mountain := _region_flint().size()
	check(mountain >= 3, "Kharum mountains have flint outcrops (%d)" % mountain)
	var z := -900.0
	var bank := Vector2(s.world.river_x(z) - 12.0, z)
	s.player.global_position = s.world.ground_point(bank.x, bank.y) + Vector3.UP
	v._stream_near(bank)
	await tree.physics_frame
	var near_river := 0
	for n in _region_flint():
		if n.global_position.distance_to(s.player.global_position) < 200.0 \
				and s.world.river_distance(n.global_position.x, n.global_position.z) < 25.0:
			near_river += 1
	check(near_river >= 1, "flint on the far river banks (%d)" % near_river)
	await _teardown(s)


func test_flint_regrows_and_boulders_can_yield_flint() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var hammer := ItemDB.get_item(&"stone_axe")
	var flint := ResourceNode.new()
	flint.setup("test_flint", &"flint")
	s.world.add_child(flint)
	for i in flint.capacity:
		flint.on_hit(p, hammer)
	check(flint.remaining == 0, "flint outcrop worked out")
	flint.simulate(float(ItemDB.get_node_kind(&"flint").regrow) + 1.0)
	check(flint.remaining == flint.capacity, "flint outcrop regrows")
	var rock := ResourceNode.new()
	rock.setup("test_rock", &"rock")
	s.world.add_child(rock)
	rock.cfg = rock.cfg.duplicate(true)
	rock.cfg.hit_bonus = {"flint": 1.0}  # force the roll
	var before := p.inventory.count_of(&"flint")
	rock.on_hit(p, hammer)
	check(p.inventory.count_of(&"flint") == before + 1, "breaking a boulder can turn up flint")
	check(float(ItemDB.get_node_kind(&"rock").get("hit_bonus", {}).get("flint", 0.0)) > 0.0, "boulders have a flint chance")
	await _teardown(s)


func test_world_map_fog_and_waypoint() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	check(MapData.explored(w.map_fog, ForestWorld.SPAWN.x, ForestWorld.SPAWN.y), "the start valley is on the map from the start")
	check(not MapData.explored(w.map_fog, 1160.0, -1240.0), "Varkai is still unexplored")
	s.player.global_position = w.ground_point(600.0, 300.0) + Vector3.UP
	for i in 40:
		await tree.process_frame
	await tree.create_timer(0.6).timeout
	check(MapData.explored(w.map_fog, 600.0, 300.0), "walking somewhere reveals it on the map")
	w.waypoint = w.ground_point(250.0, 150.0)
	var img := w.get_map_image()
	check(img != null and img.get_width() == MapData.RES, "the painted map is ready")
	var uv := MapData.to_uv(w.river_x(0.0), 0.0)
	var river_px := img.get_pixel(int(uv.x * MapData.RES), int(uv.y * MapData.RES))
	var land_px := img.get_pixel(int(MapData.RES * 0.5) - 40, int(MapData.RES * 0.5))
	check(river_px.b > river_px.r and land_px.r > land_px.b, "river painted as water, land as hide")
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))
	await _teardown(s)
	Game.pending_save = data
	var s2: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s2)
	for i in 3:
		await tree.physics_frame
	check(MapData.explored(s2.world.map_fog, 600.0, 300.0), "explored land survives a save")
	check(s2.world.waypoint.distance_to(Vector3(250.0, s2.world.waypoint.y, 150.0)) < 0.1, "waypoint survives a save")
	s2.open_map()
	await tree.process_frame
	check(s2.map_screen.visible, "M opens the map")
	s2.map_screen.close()
	await _teardown(s2)


func test_map_shift_click_teleport() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	p.set_physics_process(false)
	var map := s.map_screen
	map._zoom = MapScreen.MIN_ZOOM
	s.open_map()
	await tree.process_frame

	var site := Camps.site(Camps.REGIONAL_BASES["varkai"])
	var original := p.global_position
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = map._world_to_screen(site.x, site.y)
	click.pressed = true
	map._on_input(click)
	click.pressed = false
	map._on_input(click)
	eq(p.global_position, original, "ordinary map click keeps the player in place")
	near(s.world.waypoint.x, site.x, 0.01, "ordinary click still places a waypoint")

	p.velocity = Vector3(4.0, -30.0, -2.0)
	p._fall_speed = 30.0
	click.shift_pressed = true
	click.pressed = true
	map._on_input(click)
	click.pressed = false
	map._on_input(click)
	var at := Vector2(p.global_position.x, p.global_position.z)
	check(site.distance_to(at) <= 10.01, "Shift+click reaches the selected base")
	check(p.global_position.y >= s.world.height_at(at.x, at.y), "arrival is above ground")
	eq(p.velocity, Vector3.ZERO, "teleport clears momentum")
	near(p._fall_speed, 0.0, 0.01, "teleport clears pending fall damage")
	check(MapData.explored(s.world.map_fog, at.x, at.y), "arrival reveals the map")
	check(p.input_enabled, "teleport returns control to the player")
	await _teardown(s)
