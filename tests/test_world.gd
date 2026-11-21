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
	var n := tree.get_nodes_in_group("resource_node").size()
	check(n > 400, "forest scattered (%d nodes)" % n)
	check("JOURNAL_START" in s.world.journal, "intro journal entry")
	await _teardown(s)


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
	check(tree_node.on_hit(p, axe), "buck the fallen trunk")
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
	var fires := tree.get_nodes_in_group("campfire")
	check(fires.size() == 1 and (fires[0] as Campfire).lit, "lit campfire restored")
	eq(tree.get_nodes_in_group("pickup").size(), 1, "pickup restored")
	await _teardown(s2)
