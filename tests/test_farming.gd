extends TestCase
## Farming & provisions update: wild plants, tool bonuses, clay, garden beds (plant / water / grow / harvest /
## save), spear fishing, crafting groups, cooking-pot recipes, the build menu's 3D preview.


func _boot() -> GameSession:
	Game.pending_save = {}
	var s: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s)
	for i in 4:
		await tree.physics_frame
	s.world.wildlife.enabled = false
	return s


func _teardown(s: GameSession) -> void:
	s.queue_free()
	await tree.process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _node_of(kind: StringName) -> ResourceNode:
	for n: ResourceNode in tree.get_nodes_in_group("resource_node"):
		if n.kind == kind and n.remaining > 0:
			return n
	return null


func _bed(s: GameSession) -> BuildingPiece:
	var pos := s.player.global_position + Vector3(4, 0, -4)
	var b: BuildingPiece = s.world.spawn_structure(&"piece", Transform3D(Basis(), s.world.ground_point(pos.x, pos.z)), {"piece": "garden_bed"})
	b.complete()
	return b


func test_wild_plants_in_the_valley() -> void:
	var s: GameSession = await _boot()
	for kind: StringName in [&"wild_grain", &"wild_carrot", &"herbs", &"flax", &"hazel", &"reeds", &"clay"]:
		check(_node_of(kind) != null, "%s grows in the start valley" % kind)
	var p := s.player
	var grain := _node_of(&"wild_grain")
	grain.perform_interaction(p, &"interact")
	eq(p.inventory.count_of(&"grain"), 2, "two ears by hand")
	p.inventory.add_item(&"sickle")
	grain.perform_interaction(p, &"interact")
	eq(p.inventory.count_of(&"grain"), 6, "a sickle doubles the take")
	var carrot := _node_of(&"wild_carrot")
	carrot.cfg = carrot.cfg.duplicate(true)
	carrot.cfg.hand_bonus = {"seeds_carrot": 1.0}
	carrot.perform_interaction(p, &"interact")
	check(p.inventory.count_of(&"seeds_carrot") == 1 and p.inventory.count_of(&"wild_carrot") == 1, "roots can come with seeds")
	var clay := _node_of(&"clay")
	check(not clay.on_hit(p, ItemDB.get_item(&"stone_axe")), "clay needs a digging stick")
	check(clay.on_hit(p, ItemDB.get_item(&"digging_stick")), "dug with a digging stick")
	eq(p.inventory.count_of(&"clay"), 2, "two lumps of clay")
	await _teardown(s)


func test_garden_bed_grows_a_crop() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var bed := _bed(s)
	check(bed.farm != null and bed.farm.stage() == -1, "an empty garden bed")
	check(not bed.get_interactions(p)[0].enabled, "nothing to plant without seeds")
	p.inventory.add_item(&"seeds_grain", 2)
	bed.perform_interaction(p, &"interact")
	eq(bed.farm.crop, &"grain", "grain planted")
	eq(p.inventory.count_of(&"seeds_grain"), 1, "one seed used for the bed")
	var grow := float(FarmPlot.crops()[&"grain"].grow)
	bed.simulate(grow * 0.25)
	near(bed.farm.progress, 0.25 * FarmPlot.DRY_GROWTH, 0.01, "dry soil grows slowly")
	p.inventory.add_item(&"waterskin_raw")
	check(bed.get_interactions(p)[0].op == &"water", "watering offered on dry soil")
	bed.perform_interaction(p, &"interact")
	check(bed.farm.is_wet() and p.inventory.count_of(&"waterskin_empty") == 1, "watered: skin emptied, soil wet")
	var before := bed.farm.progress
	bed.simulate(grow * 0.25)
	near(bed.farm.progress - before, 0.25, 0.01, "wet soil grows at full speed")
	check(bed.farm._root.get_child_count() > 0, "the crop is drawn on the bed")
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))
	bed.simulate(grow * 2.0)
	check(bed.farm.is_ripe(), "ripe in the end")
	bed.perform_interaction(p, &"interact")
	eq(p.inventory.count_of(&"grain"), 6, "harvest: grain")
	eq(p.inventory.count_of(&"seeds_grain"), 3, "harvest: seeds back")
	check(bed.farm.crop == &"", "bed empty again")
	await _teardown(s)
	Game.pending_save = data
	var s2: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s2)
	for i in 3:
		await tree.physics_frame
	var found := false
	for pc: BuildingPiece in tree.get_nodes_in_group("building"):
		if pc.piece_id == &"garden_bed":
			found = pc.farm.crop == &"grain" and pc.farm.progress > 0.3 and pc.farm.is_wet()
	check(found, "crop, growth and wet soil restored from the save")
	await _teardown(s2)


func test_spear_fishing() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var water: WaterBody = s.world.get_node("Water")
	p.inventory.add_item(&"fishing_spear")
	p.inventory.equip_slot(p.inventory.first_slot_of(&"fishing_spear"))
	var opts := water.get_interactions(p)
	check(opts.size() == 1 and opts[0].text == Loc.t("ACT_FISH"), "spear in hand: fishing instead of drinking")
	for i in 30:
		water.perform_interaction(p, &"interact")
		if p.inventory.hand == null:
			break
	check(p.inventory.count_of(&"fish_raw") > 0, "caught fish (%d)" % p.inventory.count_of(&"fish_raw"))
	await _teardown(s)


func test_crafting_groups_and_pot_recipes() -> void:
	for r: RecipeData in ItemDB.all_recipes():
		check(r.group in RecipeData.GROUPS, "%s has a known crafting group (%s)" % [r.id, r.group])
	var s: GameSession = await _boot()
	var inv: Inventory = s.player.inventory
	for id: StringName in [&"meat_raw", &"wild_carrot", &"herb"]:
		inv.add_item(id)
	var stew := ItemDB.get_recipe(&"stew")
	check(not Crafting.check(stew, inv, [&"campfire"]).tool_ok, "stew needs a clay pot")
	inv.add_item(&"clay_pot")
	check(not Crafting.check(stew, inv, []).station_ok, "and a fire")
	check(Crafting.craft(stew, inv, [&"campfire"]).ok and inv.count_of(&"stew") == 1, "stew cooked")
	check(inv.count_of(&"clay_pot") == 1, "the pot is kept")
	await _teardown(s)


func test_build_menu_shows_a_3d_preview() -> void:
	var s: GameSession = await _boot()
	var menu := BuildMenu.new()
	menu.player = s.player
	tree.root.add_child(menu)
	await tree.process_frame
	menu._show_info(&"palisade")
	check(menu._pv_pivot.get_child_count() == 1, "preview model built")
	check(menu._pv_cam.position.length() > 1.0, "camera framed on it")
	menu._show_info(&"garden_bed")
	await tree.process_frame
	check(menu._pv_id == &"garden_bed", "preview follows the hovered piece")
	menu.queue_free()
	await _teardown(s)
