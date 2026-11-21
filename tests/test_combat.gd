extends TestCase
## Combat realism: hit locations, dismemberment (axe), gore toggle, guard/parry, limp, blood.


func _boot() -> GameSession:
	Game.pending_save = {}
	var s: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s)
	for i in 4:
		await tree.physics_frame
	s.world.wildlife.enabled = false
	return s


func _teardown(s: GameSession) -> void:
	Settings.set_value("gameplay", "gore", true, false)
	s.queue_free()
	await tree.process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _npc(s: GameSession, f: String, i: int) -> HumanNPC:
	return s.world.camps.npcs["npc_%s_%d" % [f, i]]


func _bone_pos(n: HumanNPC, bone: String) -> Vector3:
	var sk := n._skel
	return sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone)).origin


func _mid(n: HumanNPC, a: String, b: String) -> Vector3:
	return _bone_pos(n, a).lerp(_bone_pos(n, b), 0.5)


func _axe() -> ItemData:
	return ItemDB.get_item(&"stone_axe")


func test_hit_regions() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "gatherers", 0)
	await tree.physics_frame
	eq(BodyRegions.region_at(n._skel, _bone_pos(n, "head") + Vector3.UP * 0.08), &"head", "head")
	eq(BodyRegions.region_at(n._skel, _mid(n, "spine_02", "spine_03")), &"torso", "torso")
	eq(BodyRegions.region_at(n._skel, _mid(n, "lowerarm_l", "hand_l")), &"arm_l", "left forearm")
	eq(BodyRegions.region_at(n._skel, _mid(n, "calf_r", "foot_r")), &"leg_r", "right shin")
	await _teardown(s)


func test_headshot_multiplier_and_decapitation() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "hunters", 0)
	await tree.physics_frame
	var hp := n.health
	n.take_damage(10.0, null, _bone_pos(n, "head") + Vector3.UP * 0.08)
	near(hp - n.health, 25.0, 0.01, "head hit ×2.5")
	n.take_damage(30.0, s.player, _bone_pos(n, "head") + Vector3.UP * 0.08, _axe())
	check(&"head" in n.severed, "axe severs the head")
	check(n.is_dead(), "decapitation kills")
	check(n._severed_mod.hidden.has("head"), "head bone hidden on the body")
	await tree.process_frame
	check(tree.get_nodes_in_group("severed").size() == 1, "head detached as a physics object")
	await _teardown(s)


func test_axe_severs_arm_spear_does_not() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "clan", 0)
	await tree.physics_frame
	var arm := _mid(n, "lowerarm_r", "hand_r")
	n.take_damage(60.0, s.player, arm, ItemDB.get_item(&"spear"))
	check(not (&"arm_r" in n.severed), "a spear pierces, it does not cut limbs off")
	var m := _npc(s, "clan", 1)
	arm = _mid(m, "lowerarm_r", "hand_r")
	m.take_damage(30.0, s.player, arm, _axe())
	m.take_damage(30.0, s.player, arm, _axe())
	check(&"arm_r" in m.severed, "axe severs the forearm")
	check(not m.armed, "loses the spear with the arm")
	check(m.bleeding > 0.0, "stump bleeds")
	check(m._severed_mod.hidden.has("lowerarm_r") and m._severed_mod.get_parent() == m._skel and m._severed_mod.active,
		"forearm bone collapsed by the skeleton modifier")
	await _teardown(s)


func test_gore_toggle_disables_dismemberment() -> void:
	var s: GameSession = await _boot()
	Settings.set_value("gameplay", "gore", false, false)
	var n := _npc(s, "hunters", 1)
	await tree.physics_frame
	var leg := _mid(n, "calf_l", "foot_l")
	for i in 4:
		n.take_damage(30.0, s.player, leg, _axe())
	check(n.severed.is_empty(), "no severing with gore off")
	await _teardown(s)


func test_corpse_can_be_dismembered() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "gatherers", 1)
	await tree.physics_frame
	n.take_damage(1000.0, s.player)
	check(n.is_dead() and n.is_in_group("corpse"), "dead")
	var leg := _mid(n, "calf_r", "foot_r")
	for i in 3:
		n.take_damage(25.0, s.player, leg, _axe())
	check(&"leg_r" in n.severed, "a corpse can be dismembered")
	await _teardown(s)


func test_block_parry_and_npc_guard() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var n := _npc(s, "clan", 2)
	var front := p.global_position - p.global_transform.basis.z * 1.5
	p._set_blocking(true)
	p._block_started = Time.get_ticks_msec() / 1000.0
	var hp := p.stats.health
	p.take_hit(20.0, &"human", 0.0, front, n)
	near(p.stats.health, hp, 0.01, "perfect parry: no damage")
	check(n.is_staggered(), "parry staggers the attacker")
	p._block_started -= 1.0
	p.take_hit(20.0, &"human", 0.0, front, n)
	near(hp - p.stats.health, 5.0, 0.01, "regular block takes 25 %")
	p._set_blocking(false)
	p.take_hit(20.0, &"human", 0.0, front, n)
	near(hp - p.stats.health, 25.0, 0.01, "unblocked takes full")
	await tree.physics_frame
	var g := _npc(s, "hunters", 2)
	g.look_at(p.global_position)
	g.rotation.y += PI
	g._guard_t = 1.0
	var ghp := g.health
	g.take_damage(20.0, p, Vector3.INF)
	near(ghp - g.health, 7.0, 0.01, "NPC guard blocks 65 %")
	await _teardown(s)


func test_leg_wound_limp_and_blood_trail() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "clan", 3)
	await tree.physics_frame
	n.take_damage(40.0, s.player, _mid(n, "calf_l", "foot_l"), ItemDB.get_item(&"flint_knife"))
	check(n._limp < 1.0, "wounded leg → limp")
	var before := tree.get_nodes_in_group("blood").size()
	var deer := s.world.wildlife.spawn(&"deer", s.player.global_position + Vector3(10, 0.5, 0))
	await tree.physics_frame
	deer.take_damage(10.0, s.player)
	deer._speed = 9.0
	for i in 30:
		deer._blood_trail(0.1)
	check(tree.get_nodes_in_group("blood").size() > before + 2, "wounded animal leaves a blood trail")
	await _teardown(s)
