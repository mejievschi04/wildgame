extends TestCase
## Tree felling: notch progress, physical fall, landing, damage under the trunk, bucking, regrowth, saves.


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


func _axe(p: Player) -> ItemData:
	p.inventory.add_item(&"stone_axe")
	p.inventory.equip_slot(p.inventory.first_slot_of(&"stone_axe"))
	return p.inventory.hand.get_data()


## Stand the player 1.5 m from the tree, opposite to where it will fall.
func _stand_at(p: Player, t: TreeNode, side: Vector3) -> void:
	p.global_position = t.global_position + side.normalized() * 1.5 + Vector3.UP * 0.2


func test_fall_is_physical_and_lands() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var t: TreeNode = s.world.get_node_by_save_id("tree_pine_010")
	_stand_at(p, t, Vector3(1, 0, 0))
	var axe := _axe(p)
	for i in t.fell_hits - 1:
		t.on_hit(p, axe)
	eq(t.stage, TreeNode.Stage.STANDING, "still standing before the last hit")
	check(t.get_status_text() != "", "notch progress shown")
	t.on_hit(p, axe)
	eq(t.stage, TreeNode.Stage.FALLING, "falling")
	check(t.fall_dir.dot(Vector3(-1, 0, 0)) > 0.9, "falls away from the chopper")
	var max_angle := 0.0
	var frames := 0
	while t.stage == TreeNode.Stage.FALLING and frames < 600:
		await tree.physics_frame
		max_angle = maxf(max_angle, t.fall_angle)
		frames += 1
	eq(t.stage, TreeNode.Stage.FALLEN, "landed")
	check(frames > 90 and frames < 480, "fall takes a realistic 1.5–8 s (%d frames)" % frames)
	near(t.fall_angle, t.final_angle, 0.01, "rests at the landing angle")
	check(t.final_angle > deg_to_rad(50.0), "lands near horizontal (%.0f°)" % rad_to_deg(t.final_angle))
	check(tree.get_nodes_in_group("pickup").size() >= 2, "branches dropped as sticks")
	await _teardown(s)


func test_trunk_hurts_whoever_is_under_it() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var t: TreeNode = s.world.get_node_by_save_id("tree_pine_011")
	_stand_at(p, t, Vector3(0, 0, 1))
	var axe := _axe(p)
	for i in t.fell_hits:
		t.on_hit(p, axe)
	# Walk under the falling trunk.
	p.global_position = t.global_position + t.fall_dir * 5.0 + Vector3.UP * 0.5
	p.set_physics_process(false)
	var hp := p.stats.health
	var frames := 0
	while t.stage == TreeNode.Stage.FALLING and frames < 600:
		await tree.physics_frame
		frames += 1
	check(p.stats.health < hp - 30.0, "falling trunk hits the player (%.0f → %.0f)" % [hp, p.stats.health])
	await _teardown(s)


func test_buck_clear_regrow_and_save() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var t: TreeNode = s.world.get_node_by_save_id("tree_birch_005")
	_stand_at(p, t, Vector3(0, 0, -1))
	var axe := _axe(p)
	for i in t.fell_hits:
		t.on_hit(p, axe)
	t.complete_fall()
	t.on_hit(p, axe)
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))
	var left := t.remaining
	for i in left:
		t.on_hit(p, axe)
	eq(t.stage, TreeNode.Stage.CLEARED, "trunk fully bucked → stump")
	eq(p.inventory.count_of(&"wood"), t.capacity, "one wood per bucking hit")
	t.simulate(t.regrow_seconds + 1.0)
	eq(t.stage, TreeNode.Stage.STANDING, "tree regrows")
	await _teardown(s)
	Game.pending_save = data
	var s2: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s2)
	await tree.physics_frame
	var t2: TreeNode = s2.world.get_node_by_save_id("tree_birch_005")
	eq(t2.stage, TreeNode.Stage.FALLEN, "fallen state restored")
	eq(t2.remaining, left, "remaining logs restored")
	await _teardown(s2)


func test_player_swing_resolves_at_impact() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var t: TreeNode = s.world.get_node_by_save_id("tree_pine_012")
	p.global_position = t.global_position + Vector3(1.2, 0.2, 0)
	p.look_at(Vector3(t.global_position.x, p.global_position.y, t.global_position.z))
	p.head.rotation.x = -0.35
	_axe(p)
	for i in 3:
		await tree.physics_frame
	p.swing()
	eq(t.chop, 0, "no hit on the click itself (wind-up first)")
	for i in 40:
		await tree.physics_frame
	eq(t.chop, 1, "hit lands at the end of the strike")
	await _teardown(s)
