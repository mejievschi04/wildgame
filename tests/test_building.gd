extends TestCase
## Building system: sockets, staged delivery, support/collapse, refunds, shelter, storage, persistence.


func _boot() -> GameSession:
	Game.pending_save = {}
	var s: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s)
	for i in 4:
		await tree.physics_frame
	return s


func _teardown(s: GameSession) -> void:
	s.queue_free()
	await tree.process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


## Flat spot a few metres from the player, foundation base at terrain height.
func _foundation(s: GameSession, offset: Vector3 = Vector3(4, 0, 4), built: bool = true) -> BuildingPiece:
	var w := s.world
	var pos := s.player.global_position + offset
	var y := w.height_at(pos.x, pos.z) - 0.05
	var f: BuildingPiece = w.spawn_structure(&"piece", Transform3D(Basis(), Vector3(pos.x, y, pos.z)), {"piece": "foundation"})
	if built:
		f.complete()
	return f


## Player-built pieces only (faction camps contribute their own structures).
func _mine() -> Array:
	return tree.get_nodes_in_group("building").filter(func(n: Node) -> bool: return not String(n.name).begins_with("camp_"))


func _place(s: GameSession, id: StringName, mode: String, near: Vector3, pick: int = 0) -> BuildingPiece:
	var bc := s.player.build
	bc.piece_id = id
	bc.def = ItemDB.get_piece(id)
	var sockets := bc.find_sockets(mode, near)
	var sock: Dictionary = sockets[pick]
	var p: BuildingPiece = s.world.spawn_structure(&"piece", sock.xform, {"piece": String(id), "on": sock.supports})
	p.complete()
	return p


func test_piece_data_and_translations() -> void:
	check(ItemDB.pieces.size() >= 10, "pieces loaded")
	for id: StringName in ItemDB.piece_order:
		check(Loc.has_key("BUILD_%s" % String(id).to_upper()), "name for %s" % id)
		check(Loc.has_key("BUILD_%s_DESC" % String(id).to_upper()), "desc for %s" % id)
		check(not ItemDB.piece_cost(id).is_empty(), "cost for %s" % id)


func test_staged_delivery() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var f := _foundation(s, Vector3(4, 0, 4), false)
	check(not f.built and f.collision_layer == 4, "blueprint is soft (walk-through)")
	var opts := f.get_interactions(p)
	check(not opts[0].enabled, "needs a hammer tool to build")
	p.inventory.add_item(&"stone", 1)
	p.inventory.add_item(&"wood", 2)
	check(f.get_interactions(p)[0].enabled, "can deliver with tool + some material")
	f.perform_interaction(p, &"interact")
	check(not f.built, "partial delivery keeps blueprint")
	eq(int(f.delivered.get(&"wood", 0)), 2, "wood delivered")
	eq(p.inventory.count_of(&"wood"), 0, "wood taken from inventory")
	p.inventory.add_item(&"wood", 5)
	p.inventory.add_item(&"stick", 10)
	f.perform_interaction(p, &"interact")
	check(f.built and f.collision_layer == 1, "completed foundation is solid")
	eq(p.inventory.count_of(&"wood"), 4, "only the missing wood consumed")
	await _teardown(s)


func test_sockets_and_occupancy() -> void:
	var s: GameSession = await _boot()
	var f := _foundation(s)
	var bc := s.player.build
	bc.piece_id = &"wall"
	bc.def = ItemDB.get_piece(&"wall")
	eq(bc.find_sockets("edge", f.global_position).size(), 4, "4 edge sockets")
	eq(bc.find_sockets("corner", f.global_position).size(), 4, "4 corner sockets")
	var sock: Dictionary = bc.find_sockets("edge", f.global_position)[0]
	var aim: Vector3 = sock.xform.origin
	var res := bc.evaluate(aim, Vector3.UP, null, 0.0)
	check(res.valid, "free edge socket is valid: %s" % res.reason)
	_place(s, &"wall", "edge", f.global_position, 0)
	res = bc.evaluate(aim, Vector3.UP, null, 0.0)
	check(not res.valid, "occupied socket rejected")
	# Roof needs 2 supports.
	bc.piece_id = &"roof"
	bc.def = ItemDB.get_piece(&"roof")
	var top := f.global_position + Vector3.UP * (BuildingPiece.FOUNDATION_H + BuildingPiece.WALL_H)
	res = bc.evaluate(top, Vector3.UP, null, 0.0)
	check(not res.valid, "roof with one wall is unsupported")
	_place(s, &"pillar", "corner", f.global_position, 0)
	bc.piece_id = &"roof"
	bc.def = ItemDB.get_piece(&"roof")
	res = bc.evaluate(top, Vector3.UP, null, 0.0)
	check(res.valid and res.supports.size() == 2, "roof with wall + pillar is supported")
	# Foundation snapping next to an existing one.
	bc.piece_id = &"foundation"
	bc.def = ItemDB.get_piece(&"foundation")
	res = bc.evaluate(f.global_position + Vector3(2.3, 0, 0.2), Vector3.UP, null, 0.0)
	check(res.xform.origin.distance_to(f.global_position + Vector3(2, 0, 0)) < 0.01, "foundation snaps to neighbour grid")
	res = bc.evaluate(f.global_position, Vector3.UP, null, 0.0)
	check(not res.valid, "cannot stack a foundation on another")
	await _teardown(s)


func test_collapse_cascade_and_refunds() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var f := _foundation(s)
	var wall := _place(s, &"wall", "edge", f.global_position, 0)
	_place(s, &"doorway", "edge", f.global_position, 1)
	_place(s, &"door", "doorway", f.global_position, 0)
	var roof := _place(s, &"roof", "top", f.global_position, 0)
	check(roof.supported_by.size() == 2, "roof rests on wall + doorway")
	# Dismantling one wall keeps the roof (still 1 support).
	var sticks_before := p.inventory.count_of(&"stick")
	wall.perform_interaction(p, &"alt_interact")
	await tree.process_frame
	eq(p.inventory.count_of(&"stick") - sticks_before, 3, "dismantle refunds 50 %")
	check(is_instance_valid(roof) and not roof.is_queued_for_deletion(), "roof survives with one support")
	# Removing the foundation collapses everything on it.
	s.world.remove_piece(f, 0.25, null)
	await tree.process_frame
	await tree.process_frame
	eq(_mine().size(), 0, "doorway, door and roof collapsed")
	check(tree.get_nodes_in_group("pickup").size() > 0, "collapse drops some materials")
	await _teardown(s)


func test_shelter_insulation() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var f := _foundation(s, Vector3(0, 0, 0))
	var inside := f.global_position + Vector3.UP * 0.8
	eq(s.world.get_shelter_at(inside), 0.0, "bare floor gives no shelter")
	_place(s, &"wall", "edge", f.global_position, 0)
	_place(s, &"wall", "edge", f.global_position, 1)
	_place(s, &"wall", "edge", f.global_position, 2)
	_place(s, &"roof", "top", f.global_position, 0)
	near(s.world.get_shelter_at(inside), 11.0, 0.01, "roof + 3 walls shelter")
	var lt: BuildingPiece = s.world.spawn_structure(&"piece", Transform3D(Basis(), p.global_position + Vector3(-8, 0, 0)), {"piece": "lean_to"})
	lt.complete()
	near(s.world.get_shelter_at(lt.global_position + Vector3(0, 0.8, 0.2)), 6.0, 0.01, "lean-to shelter")
	await _teardown(s)


func test_storage_door_rack_persist() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var box: BuildingPiece = s.world.spawn_structure(&"piece", Transform3D(Basis(), p.global_position + Vector3(3, 0, -3)), {"piece": "storage"})
	box.complete()
	box.storage.add_item(&"flint", 7)
	var f := _foundation(s, Vector3(-5, 0, 5))
	_place(s, &"doorway", "edge", f.global_position, 0)
	var door := _place(s, &"door", "doorway", f.global_position, 0)
	door.perform_interaction(p, &"interact")
	check(door.door_open, "door opens")
	var rack: BuildingPiece = s.world.spawn_structure(&"piece", Transform3D(Basis(), p.global_position + Vector3(-3, 0, -4)), {"piece": "drying_rack"})
	rack.complete()
	p.inventory.add_item(&"meat_raw", 2)
	rack.perform_interaction(p, &"interact")
	eq(rack.drying.size(), 1, "meat hung")
	rack.simulate(BuildingPiece.DRY_TIME + 1.0)
	rack.perform_interaction(p, &"interact")
	eq(p.inventory.count_of(&"meat_dried"), 1, "dried meat taken")
	var bp: BuildingPiece = s.world.spawn_structure(&"piece", Transform3D(Basis(), p.global_position + Vector3(6, 0, 0)), {"piece": "fence"})
	bp.delivered[&"stick"] = 2
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))
	await _teardown(s)

	Game.pending_save = data
	var s2: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s2)
	for i in 3:
		await tree.physics_frame
	var pieces := _mine()
	eq(pieces.size(), 6, "all pieces restored")
	var found_box := false
	var found_door := false
	var found_bp := false
	for pc: BuildingPiece in pieces:
		if pc.piece_id == &"storage":
			found_box = pc.storage.count_of(&"flint") == 7
		if pc.piece_id == &"door":
			found_door = pc.door_open and pc.supported_by.size() == 1
		if pc.piece_id == &"fence":
			found_bp = not pc.built and int(pc.delivered.get(&"stick", 0)) == 2
	check(found_box, "storage contents restored")
	check(found_door, "door state + support restored")
	check(found_bp, "blueprint progress restored")
	await _teardown(s2)


func test_repair() -> void:
	var s: GameSession = await _boot()
	var f := _foundation(s)
	f.damage(150.0)
	near(f.health, 150.0, 0.01, "damaged")
	s.player.inventory.add_item(&"wood", 1)
	check(f.repair(s.player.inventory), "repaired with 1 wood")
	near(f.health, 270.0, 0.01, "+40 % health")
	f.damage(1000.0)
	await tree.process_frame
	eq(_mine().size(), 0, "destroyed piece removed")
	await _teardown(s)


func test_new_pieces_tiers_translated() -> void:
	for id: StringName in [&"window_wall", &"half_wall", &"gable", &"palisade"]:
		check(ItemDB.pieces.has(id), "piece %s exists" % id)
	for id: StringName in ItemDB.piece_order:
		var tiers: Array = ItemDB.get_piece(id).get("tiers", [])
		for t in tiers.size():
			check(Loc.has_key("BUILD_%s_T%d" % [String(id).to_upper(), t + 1]), "tier name for %s T%d" % [id, t + 1])
		var v := BuildingPiece.build_visual(id, 0, 1)
		check(int(v.get_meta("stages", 0)) >= 1 and not BuildingVisuals.stage_nodes(v).is_empty(), "%s has construction stages" % id)
		for t in tiers.size():
			var vt := BuildingPiece.build_visual(id, t + 1, 1)
			check(not BuildingVisuals.stage_nodes(vt).is_empty(), "%s T%d has a visual" % [id, t + 1])
			vt.free()
		v.free()


func test_construction_stages_follow_delivery() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var f := _foundation(s, Vector3(4, 0, 4), false)
	eq(f.stage_count(), 3, "foundation goes up in 3 stages")
	eq(f.stages_done(), 0, "fresh blueprint: nothing built yet")
	p.inventory.add_item(&"stone", 1)
	p.inventory.add_item(&"wood", 3)
	f.perform_interaction(p, &"interact")
	check(f.stages_done() >= 1 and not f.built, "delivered wood raises the first stages (%d)" % f.stages_done())
	var looks := BuildingVisuals.stage_nodes(f._visual)
	var first: MeshInstance3D = (looks[0][0] as Node).find_children("*", "MeshInstance3D", true, false)[0]
	var last: MeshInstance3D = (looks[2][0] as Node).find_children("*", "MeshInstance3D", true, false)[0]
	check(first.material_override == null, "built stage shows real materials")
	check(last.material_override == BuildingPiece._blueprint_mat(), "unbuilt stage is still a plan")
	p.inventory.add_item(&"stick", 4)
	f.perform_interaction(p, &"interact")
	check(f.built and f.stages_done() == 3, "completed: all stages")
	await _teardown(s)


func test_upgrade_wall_through_tiers() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var f := _foundation(s)
	var wall := _place(s, &"wall", "edge", f.global_position, 0)
	near(wall.max_health, 150.0, 0.01, "wattle wall health")
	var opts := wall.get_interactions(p)
	check(not opts[0].enabled and opts[0].op == &"upgrade", "upgrade needs hammer + materials")
	p.inventory.add_item(&"stone", 1)
	p.inventory.add_item(&"wood", 4)
	check(wall.get_interactions(p)[0].enabled, "upgrade offered with the materials")
	wall.perform_interaction(p, &"interact")
	eq(wall.tier, 1, "now a log wall")
	near(wall.max_health, 300.0, 0.01, "log wall is twice as strong")
	eq(p.inventory.count_of(&"wood"), 0, "logs used")
	eq(wall.display_name(), Loc.t("BUILD_WALL_T1"), "named as a log wall")
	var shape := wall.get_children().filter(func(n: Node) -> bool: return n is CollisionShape3D)[0] as CollisionShape3D
	near((shape.shape as BoxShape3D).size.z, 0.24, 0.001, "thicker collision for logs")
	p.inventory.add_item(&"stone", 10)
	p.inventory.add_item(&"wood", 1)
	wall.perform_interaction(p, &"interact")
	eq(wall.tier, 2, "now a stone wall")
	check(wall.get_interactions(p)[0].op != &"upgrade", "no tier above stone")
	var refund := wall.refund(0.5)
	check(int(refund.get(&"stone", 0)) == 5 and int(refund.get(&"wood", 0)) == 2, "dismantling returns part of every tier (%s)" % refund)
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))
	await _teardown(s)
	Game.pending_save = data
	var s2: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s2)
	for i in 3:
		await tree.physics_frame
	var found := false
	for pc: BuildingPiece in _mine():
		if pc.piece_id == &"wall":
			found = pc.tier == 2 and is_equal_approx(pc.max_health, 525.0)
	check(found, "stone wall restored from the save")
	await _teardown(s2)


func test_gable_needs_a_roof_and_keeps_warmth() -> void:
	var s: GameSession = await _boot()
	var f := _foundation(s, Vector3(0, 0, 0))
	var bc := s.player.build
	bc.piece_id = &"gable"
	bc.def = ItemDB.get_piece(&"gable")
	var top := f.global_position + Vector3.UP * (BuildingPiece.FOUNDATION_H + BuildingPiece.WALL_H)
	check(not bc.evaluate(top + Vector3(1, 0, 0), Vector3.UP, null, 0.0).valid, "no gable without a roof")
	_place(s, &"wall", "edge", f.global_position, 0)
	_place(s, &"wall", "edge", f.global_position, 1)
	_place(s, &"wall", "edge", f.global_position, 2)
	var roof := _place(s, &"roof", "top", f.global_position, 0)
	var inside := f.global_position + Vector3.UP * 0.8
	var before := s.world.get_shelter_at(inside)
	bc.piece_id = &"gable"
	bc.def = ItemDB.get_piece(&"gable")
	eq(bc.find_sockets("gable", roof.global_position).size(), 2, "a gable socket at each end of the ridge")
	var g := _place(s, &"gable", "gable", roof.global_position, 0)
	check(g.supported_by == [roof.structure_id], "gable rests on the roof")
	check(s.world.get_shelter_at(inside) > before, "closed gable keeps the room warmer")
	s.world.remove_piece(roof, 0.25, null)
	await tree.process_frame
	check(not is_instance_valid(g) or g.is_queued_for_deletion(), "gable falls with its roof")
	await _teardown(s)
