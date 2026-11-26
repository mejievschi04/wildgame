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
	var z := ForestWorld.SPAWN.y
	for xz: Vector2 in [Vector2(s.world.river_x(z + 13) - 20, z + 13),
			Vector2(s.world.river_x(z + 17) - 17, z + 17)]:
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


func test_generated_stones_and_grass_can_be_harvested() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var v := w.get_node("Vegetation") as Vegetation
	var stone: ResourceNode
	var grass: ResourceNode
	var boulder: ResourceNode
	for n: ResourceNode in tree.get_nodes_in_group("scattered_resource"):
		if not n.node_id.begins_with("region_"):
			continue
		match n.kind:
			&"loose_stone": stone = n
			&"wild_grass": grass = n
			&"rock": boulder = n
	check(stone != null and grass != null and boulder != null, "chunks contain harvestable stones, grass and boulders")
	check(not w.meadow_grass.is_in_group("interactable"), "meadow grass is decorative")
	if stone and grass and boulder:
		var stone_id := stone.node_id
		var grass_id := grass.node_id
		var grass_time := grass.regrow_seconds
		var stones_before := s.player.inventory.count_of(&"stone")
		var fiber_before := s.player.inventory.count_of(&"fiber")
		stone.perform_interaction(s.player, &"interact")
		grass.perform_interaction(s.player, &"interact")
		eq(s.player.inventory.count_of(&"stone"), stones_before + 1, "a loose stone yields one stone")
		eq(s.player.inventory.count_of(&"fiber"), fiber_before + 1, "wild grass yields one fiber")
		eq(stone.remaining, 0, "loose stone is used up")
		eq(grass.remaining, 0, "tuft is cut")
		check(boulder.on_hit(s.player, ItemDB.get_item(&"stone")), "boulder can be mined with a hammer tool")
		eq(boulder.remaining, boulder.capacity - 1, "boulder loses one charge")
		v._stream_near(ForestWorld.SPAWN + Vector2(900, 0))
		var saved := w.collect_save()
		check(saved.nodes.has(stone_id) and saved.nodes.has(grass_id), "unloaded scatter state is saved")
		w.apply_save(saved)
		v._stream_near(ForestWorld.SPAWN)
		eq((w.get_node_by_save_id(stone_id) as ResourceNode).remaining, 0, "stone stays depleted")
		var restored := w.get_node_by_save_id(grass_id) as ResourceNode
		eq(restored.remaining, 0, "grass depletion survives streaming and load")
		restored.simulate(grass_time)
		eq(restored.remaining, restored.capacity, "grass grows back")
	# A water surface obscures the normal ray, but the player can still target a stone below it.
	var origin := Vector3(0, 150, 0)
	var water := WaterBody.new()
	water.setup(2.0, origin.y)
	w.add_child(water)
	var mesh := BoxMesh.new()
	w.spawn_scattered_resource(w, "test_submerged_stone", &"loose_stone", mesh,
		Transform3D(Basis.IDENTITY, origin - Vector3.UP * 0.65))
	await tree.physics_frame
	await tree.physics_frame
	s.player.ray.global_transform = Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), origin + Vector3.UP * 0.6)
	s.player.ray.force_raycast_update()
	check(s.player.ray.get_collider() == water, "the normal ray hits water first")
	s.player._update_interaction(0.0)
	check(s.player.look_target == w.get_node_by_save_id("test_submerged_stone"), "the underwater stone gets the gather prompt")
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
	s.world.structures_root.get_node("player_camp_fire").load_state({"lit": false})
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
	var fires := tree.get_nodes_in_group("campfire").filter(func(n: Campfire) -> bool: return n.structure_id.begins_with("s_"))
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
	var kharum: Vector2 = ForestWorld.REGIONS[&"kharum"] + Vector2(-160, 95)
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


## The coast, mountain regions, connected rivers and occupied settlements share the map's geometry.
func test_relief_creeks_and_fords() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var callout := Vector2(-3200.0, ForestWorld.Layout.coast_z(-3200.0))
	check(w.height_at(callout.x, callout.y + 130.0) < ForestWorld.WATER_LEVEL, "southwest shoreline opens onto real sea")
	check(w.height_at(callout.x, callout.y - 130.0) > ForestWorld.WATER_LEVEL, "coast has dry land on the inland side")
	check(w.has_node("SouthwestSea"), "ocean surface is present in the playable scene")
	var north := Camps.site(Camps.REGIONAL_BASES["north"])
	var stone := Camps.site(Camps.REGIONAL_BASES["kharum"])
	var red := Camps.site(Camps.REGIONAL_BASES["varkai"])
	check(stone.x < 0.0 and stone.y < 0.0, "Stone tribe is north-west")
	check(north.x > 0.0 and north.y < 0.0 and ForestWorld.taiga_at(north.x, north.y) > 0.6, "North tribe is in snowy north-east")
	check(red.x > 0.0 and red.y > 0.0, "Red tribe is south-east")
	# creeks
	check(w.creeks.size() >= 3, "creeks traced (%d)" % w.creeks.size())
	var dry := 0
	var samples := 0
	for pts: PackedVector3Array in w.creeks:
		for i in pts.size() - 1:
			check(pts[i + 1].y <= pts[i].y + 0.001, "creek water only flows downhill")
			if i % 3 == 0:
				samples += 1
				if w.height_at(pts[i].x, pts[i].z) >= pts[i].y:
					dry += 1
		var mouth := pts[pts.size() - 1]
		check(mouth.y < 0.01 or w.creek_level_at(mouth.x, mouth.z) <= mouth.y + 0.5, "creek ends in other water")
	check(dry <= samples / 20, "creek beds hold water (%d of %d dry)" % [dry, samples])
	var creek_water := 0
	for c in w.get_children():
		if c is WaterBody and String(c.name).begins_with("Creek"):
			creek_water += 1
	check(creek_water > 50, "creeks are drinkable (%d water volumes)" % creek_water)
	var mid := w.creeks[0][w.creeks[0].size() / 2]
	check(w.creek_distance(mid.x, mid.z) < 1.0 and w.water_distance(mid.x, mid.z) < 8.0, "water_distance sees creeks")
	var narrow := 0
	var probes := 0
	for pts: PackedVector3Array in w.creeks:
		for i in range(2, pts.size() - 3, 4):
			var t := Vector2(pts[i + 1].x - pts[i - 1].x, pts[i + 1].z - pts[i - 1].z).normalized()
			var side := Vector2(t.y, -t.x) * 9.0
			probes += 1
			if w.height_at(pts[i].x + side.x, pts[i].z + side.y) > pts[i].y and w.height_at(pts[i].x - side.x, pts[i].z - side.y) > pts[i].y:
				narrow += 1
	check(narrow >= probes * 9 / 10, "creeks are narrow: dry ground 9 m from the centre (%d of %d)" % [narrow, probes])
	check(absf(w.creek_level_at(mid.x, mid.z) - mid.y) < 0.5, "creek level query")
	# fords and channels
	for id: StringName in ForestWorld.FORDS:
		var z: float = ForestWorld.FORDS[id].x
		var bed := w.height_at(w.river_x(z), z)
		check(bed > -0.3 and bed < ForestWorld.WATER_LEVEL, "%s is wadeable (bed %.2f m)" % [id, bed])
	check(w.height_at(w.river_x(-600.0), -600.0) < -1.0, "the river is deep away from the fords")
	check(w.get_node_or_null("POI_StoneFord") != null and w.get_node("POI_StoneFord").get_child_count() >= 8,
		"stepping stones across the stone ford")
	for river: Dictionary in ForestWorld.Layout.data.rivers.slice(1):
		var mouth: Array = river.points[-1]
		near(w.river_x(float(mouth[0])), float(mouth[1]), 0.2, "tributary meets the main river")
	await _teardown(s)


## The terrain is drawn from the bake: full-resolution chunks around the camera over a coarse far mesh, and its
## collision (one heightmap) agrees with height_at() everywhere, near or far from the player.
func test_terrain_lod_and_collision() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var lod := w.terrain_lod
	check(lod != null and lod.far_mesh != null, "terrain has a far mesh")
	var p := s.player.global_position
	check(lod.is_full_resolution(p.x, p.z), "full-resolution terrain under the player")
	check(not lod.is_full_resolution(p.x + 1500.0, p.z), "coarse terrain far away")
	var space := w.get_world_3d().direct_space_state
	var r := RandomNumberGenerator.new()
	r.seed = 7
	var worst := 0.0
	for i in 200:
		var x := r.randf_range(-1950.0, 1950.0)
		var z := r.randf_range(-1950.0, 1950.0)
		var q := PhysicsRayQueryParameters3D.create(Vector3(x, 400.0, z), Vector3(x, -50.0, z), 1)
		var hit := space.intersect_ray(q)
		if hit.is_empty() or not (hit.collider as Node).is_in_group("terrain"):
			continue
		worst = maxf(worst, absf(hit.position.y - w.height_at(x, z)))
	check(worst < 0.02, "collision matches height_at (worst %.3f m)" % worst)
	# camp sites are cut flat into the bake
	for base: Dictionary in Camps.REGIONAL_BASES.values():
		var c := Camps.site(base)
		var lo := INF
		var hi := -INF
		for k in 8:
			var a := TAU * k / 8.0
			var h := w.height_at(c.x + cos(a) * 8.0, c.y + sin(a) * 8.0)
			lo = minf(lo, h)
			hi = maxf(hi, h)
		check(hi - lo < 0.6, "regional base at %s is level (%.2f m)" % [c, hi - lo])
	# walking away streams a new window in and the far mesh's hole follows it
	s.player.global_position = w.ground_point(p.x + 400.0, p.z) + Vector3.UP
	for i in 60:
		await tree.process_frame
	var cam := s.player.get_viewport().get_camera_3d()
	check(lod.is_full_resolution(cam.global_position.x, cam.global_position.z), "chunks stream in around the camera")
	var hole: Vector4 = lod.far_material.get_shader_parameter("hole")
	check(cam.global_position.x > hole.x and cam.global_position.x < hole.z, "the far mesh's hole follows the camera")
	await _teardown(s)


## Caves (gen_terrain.py cuts the trench, Cave adds the roof): walkable inside, roofed, sheltered, dark, empty.
func test_caves() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	check(w.caves.size() >= 2, "caves built (%d)" % w.caves.size())
	var space := w.get_world_3d().direct_space_state
	for cave in w.caves:
		var deep: Dictionary = cave.rings[cave.rings.size() / 2]
		var inside := Vector3(float(deep.x), float(deep.floor) + 1.2, float(deep.z))
		var floor_y := w.height_at(inside.x, inside.z)
		check(absf(floor_y - float(deep.floor)) < 0.3, "%s: the floor is cut (%.2f vs %.2f)" % [cave.id, floor_y, float(deep.floor)])
		var up := space.intersect_ray(PhysicsRayQueryParameters3D.create(inside, inside + Vector3.UP * 60.0, 1))
		check(not up.is_empty() and up.position.y < float(deep.floor) + float(deep.h) + 1.0,
			"%s: a rock ceiling overhead" % cave.id)
		var down := space.intersect_ray(PhysicsRayQueryParameters3D.create(
			inside + Vector3.UP * 80.0, inside + Vector3.DOWN * 5.0, 1))
		check(not down.is_empty() and down.position.y > inside.y + 1.0, "%s: from above, you stand on the hill" % cave.id)
		check(cave.contains(inside) and w.cave_at(inside) == cave, "%s: inside is inside" % cave.id)
		check(w.get_shelter_at(inside) >= 7.0, "%s: shelters from the weather" % cave.id)
		check(cave.get_node_or_null("Darkness") is ReflectionProbe, "%s: dark inside" % cave.id)
		var mouth: Dictionary = cave.rings[0]
		var outside := Vector3(float(mouth.x), 0.0, float(mouth.z)) - Vector3(cave.dir.x, 0.0, cave.dir.y) * 8.0
		outside.y = w.height_at(outside.x, outside.z) + 1.0
		check(not cave.contains(outside) and w.get_shelter_at(outside) == 0.0, "%s: the approach is open sky" % cave.id)
		# the way in is clear: nothing blocks a walk from the approach to the back
		var walk := space.intersect_ray(PhysicsRayQueryParameters3D.create(outside + Vector3.UP * 0.3, inside, 1))
		check(walk.is_empty(), "%s: open from the mouth in" % cave.id)
	for n: Node in w.get_tree().get_nodes_in_group("resource_node"):
		var p := (n as Node3D).global_position
		check(w.cave_at(p + Vector3.UP) == null, "no resource node grows inside a cave (%s)" % n.name)
	await _teardown(s)


## The player is a Homo sapiens man: a body seen from inside (no head in the way), a full body casting the shadow,
## clips that follow the movement, and the right arm making way for a held item's own hand.
func test_player_body() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var body := p.body
	check(body != null and body.visible_model != null and body.shadow_model != null, "the player has a body")
	for i in 10:
		await tree.process_frame
	var sk := body.visible_model.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var trim := sk.get_node("BodyTrim") as PlayerBody.BodyTrim
	check(sk.find_bone("head") in trim.hidden, "no head in front of the camera")
	check(body.clip == "idle", "standing still: idle (%s)" % body.clip)
	for i in 4:
		p.velocity = -p.global_transform.basis.z * Player.WALK_SPEED
		body._physics_process(1.0 / 60.0)
	check(body.clip == "run", "walking forward moves the legs (%s)" % body.clip)
	p.velocity = Vector3.ZERO
	p._crouching = true
	body._physics_process(1.0 / 60.0)
	check(body.clip == "player_crouch_idle", "crouching (%s)" % body.clip)
	p._crouching = false
	p.inventory.add_item(&"stone_axe")
	p.inventory.equip_slot(p.inventory.first_slot_of(&"stone_axe"))
	for i in 3:
		await tree.process_frame
	check(sk.find_bone("upperarm_r") in trim.hidden, "the held axe's hand replaces the body's right arm")
	check(not sk.find_bone("upperarm_l") in trim.hidden, "the left arm stays")
	await _teardown(s)


func test_world_map_fog_and_waypoint() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	check(MapData.explored(w.map_fog, ForestWorld.SPAWN.x, ForestWorld.SPAWN.y), "the start valley is on the map from the start")
	var red := Camps.site(Camps.REGIONAL_BASES["varkai"])
	check(not MapData.explored(w.map_fog, red.x, red.y), "Red tribe is still unexplored")
	s.player.global_position = w.ground_point(600.0, 300.0) + Vector3.UP
	for i in 40:
		await tree.process_frame
	await tree.create_timer(0.6).timeout
	check(MapData.explored(w.map_fog, 600.0, 300.0), "walking somewhere reveals it on the map")
	w.waypoint = w.ground_point(250.0, 150.0)
	var img := w.get_map_image()
	check(img != null and img.get_width() >= 1600, "the painted map is ready")
	var uv := MapData.to_uv(w.river_x(0.0), 0.0)
	var map_size := img.get_width()
	var river_px := img.get_pixel(int(uv.x * map_size), int(uv.y * map_size))
	var land_px := img.get_pixel(int(map_size * 0.5) - 40, int(map_size * 0.5))
	check(river_px.b > river_px.r and land_px.r > land_px.b, "river and land are visually distinct")
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


func test_dry_twig_bushes_give_sticks_and_stand_out_of_the_grass() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var near: Array = []
	for n: Node in tree.get_nodes_in_group("resource_node"):
		if n is ResourceNode and (n as ResourceNode).kind == &"deadwood":
			if (n as Node3D).global_position.distance_to(p.global_position) < 15.0:
				near.append(n)
	check(near.size() >= 2, "dry twig bushes in sight of the start (%d)" % near.size())
	var bush: ResourceNode = near[0]
	var mi := bush.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	check(mi.get_aabb().size.y * mi.scale.y > 0.8, "taller than the meadow grass (%.2f m)" % (mi.get_aabb().size.y * mi.scale.y))
	var opts: Array = bush.get_interactions(p)
	check(opts[0].enabled and float(opts[0].hold) > 0.0, "a hold-to-gather action")
	for i in bush.capacity:
		bush.perform_interaction(p, &"interact")
	eq(p.inventory.count_of(&"stick"), 2 * bush.capacity, "two sticks per gather")
	eq(bush.remaining, 0, "picked bare")
	check(bush.get_interactions(p)[0].enabled == false, "nothing more to break off")
	await _teardown(s)


func test_landmarks_spread_across_the_wilds() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var placed: Array = w.landmarks.placed
	check(placed.size() > 100, "a landmark every few hundred metres (%d)" % placed.size())
	var kinds := {}
	for e: Array in placed:
		kinds[e[0]] = true
		var p: Vector3 = e[1]
		check(Vector2(p.x, p.z).distance_to(ForestWorld.SPAWN) > Landmarks.KEEP_CLEAR, "clear of the start")
		check(p.y > ForestWorld.WATER_LEVEL + 1.0 and w.water_distance(p.x, p.z) >= 25.0, "on dry ground away from water")
		for c: Vector2 in w._camp_sites:
			check(Vector2(p.x, p.z).distance_to(c) > Landmarks.KEEP_CLEAR, "clear of the clans' camps")
	eq(kinds.size(), Landmarks.KINDS.size(), "every kind appears somewhere")
	# nearest neighbour spacing: no clumps
	var close := 0
	for i in placed.size():
		for j in range(i + 1, placed.size()):
			if (placed[i][1] as Vector3).distance_to(placed[j][1]) < 60.0:
				close += 1
	check(close == 0, "no two landmarks within 60 m (%d)" % close)
	await _teardown(s)
