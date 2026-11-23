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
	check(not t.limbed() and t._bark_mi.mesh.get_surface_count() > 1, "the crown stays on the felled tree")
	var before := tree.get_nodes_in_group("pickup").size()
	for i in TreeNode.LIMB_HITS:
		t.on_hit(p, axe)
	check(t.limbed(), "limbing takes %d blows" % TreeNode.LIMB_HITS)
	check(tree.get_nodes_in_group("pickup").size() >= before + 2, "the branches drop as sticks")
	check(t._bark_mi.mesh.get_surface_count() == 1, "leaving a bare trunk")
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
	for i in TreeNode.LIMB_HITS:
		t.on_hit(p, axe)
	var full := t._bark_mi.mesh.get_aabb().size.y
	check(t._bark_mi.mesh.get_surface_count() == 1, "limbed: the crown is gone, a bare trunk lies there")
	t.on_hit(p, axe)
	check(t._bark_mi.mesh.get_aabb().size.y < full, "bucking shortens the trunk")
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))
	var left := t.remaining
	for i in left:
		t.on_hit(p, axe)
	eq(t.stage, TreeNode.Stage.CLEARED, "trunk fully bucked → stump")
	var logs := tree.get_nodes_in_group("pickup").filter(func(n: Node) -> bool: return n is LogPiece)
	eq(logs.size(), t.capacity, "one physical log per bucking hit")
	await _run_frames(90)
	for l: LogPiece in logs:
		var g := s.world.height_at(l.global_position.x, l.global_position.z)
		check(l.global_position.y - g < 1.2, "the log rests on the ground, not thrown up (%.1f m)" % (l.global_position.y - g))
		check(l.global_position.distance_to(t.global_position) < t.height + 4.0, "and stays by the trunk")
	for l: LogPiece in logs:
		l.perform_interaction(p, &"interact")
	eq(p.inventory.count_of(&"wood"), t.capacity, "picking the logs up gives the wood")
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


## The notch, chips and collision sit on this tree's real bark (measured from the model), whatever its scale.
func test_chop_effects_sit_on_the_real_bark() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var checked := 0
	for t: TreeNode in tree.get_nodes_in_group("resource_node").filter(func(n: Node) -> bool: return n is TreeNode):
		var tr := t._trunk_at(t.cut_h)
		check(tr.z > 0.12 and tr.z < 0.6, "%s: plausible bark radius %.2f" % [t.node_id, tr.z])
		check(Vector2(tr.x, tr.y).length() < 0.2, "%s: trunk centre near the node origin" % t.node_id)
		check(absf((t._shape.shape as CylinderShape3D).radius - t._trunk_at(1.0).z) < 0.001, "%s: collision follows the bark" % t.node_id)
		checked += 1
		if checked >= 12:
			break
	check(checked > 0, "trees found")
	var t: TreeNode = s.world.get_node_by_save_id("tree_pine_010")
	_stand_at(p, t, Vector3(1, 0, 0))
	var axe := _axe(p)
	t.on_hit(p, axe)
	t.on_hit(p, axe)
	# The cut is real geometry now: the model's lower trunk is removed and a carved section takes its place.
	check(t._cut_mode and t._cut_upper.mesh.get_surface_count() == 2, "carved section: bark + fresh-wood faces")
	var d2 := t.notch_depth()
	check(d2 > 0.0 and d2 < t._trunk_r, "notch bites into the trunk (%.2f of r %.2f)" % [d2, t._trunk_r])
	var lowest := INF
	for v: Vector3 in t._bark_mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		lowest = minf(lowest, v.y)
	check(lowest >= (t._clip_top + TreeNode.SINK) / t._size - 0.001, "original trunk cut away below the section")
	t.on_hit(p, axe)
	check(t.notch_depth() > d2, "each blow deepens the notch")
	check(t._debris.get_child_count() == 9, "chips pile up at the foot of the tree (%d)" % t._debris.get_child_count())
	for c: Node3D in t._debris.get_children():
		var g := c.global_position
		check(absf(g.y - s.world.height_at(g.x, g.z)) < 0.05, "debris chip lies on the ground")
		check(Vector2(g.x - t.global_position.x, g.z - t.global_position.z).dot(Vector2(-t.fall_dir.x, -t.fall_dir.z)) > 0.0, "debris on the chopper's side")
	await _teardown(s)


func _run_frames(n: int) -> void:
	for i in n:
		await tree.physics_frame
