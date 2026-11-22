extends TestCase
## Tribes & diplomacy (GDD §7): stances, territory warnings, gestures, offerings, barter, aggression, saves.


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


func _npc(s: GameSession, faction: String, i: int = 0) -> HumanNPC:
	return s.world.camps.npcs["npc_%s_%d" % [faction, i]]


func _near(s: GameSession, npc: HumanNPC, dist: float) -> void:
	var p := s.player
	var at := npc.global_position + npc.global_transform.basis.z * dist
	p.global_position = s.world.ground_point(at.x, at.z) + Vector3.UP * 0.2


func test_camps_and_people_exist() -> void:
	var s: GameSession = await _boot()
	eq(s.world.camps.npcs.size(), 10, "3 + 4 + 3 people in three camps")
	for f in ["hunters", "clan", "gatherers"]:
		var fire: Campfire = s.world.structures_root.get_node("camp_%s_fire" % f)
		check(fire and fire.lit and fire.eternal, "%s camp fire burns" % f)
	eq(s.world.factions.stance(&"clan"), &"wary", "clan starts wary")
	eq(s.world.factions.stance(&"gatherers"), &"neutral", "gatherers start neutral")
	var hunter := _npc(s, "hunters")
	check(hunter._anim.has_animation("combat/thrust"), "armed NPC receives the authored thrust")
	var root_position := NodePath("Human_rig/Skeleton3D:Root")
	for gait in ["walk", "run"]:
		var clip := hunter._anim.get_animation(gait)
		var track := clip.find_track(root_position, Animation.TYPE_POSITION_3D)
		var origin: Vector3 = clip.track_get_key_value(track, 0)
		check(Vector2(origin.x, origin.z).length() < 0.1, "%s starts over the collision capsule" % gait)
	await _teardown(s)


func test_regional_bases_have_distinct_defenses_and_stream_guards() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var camps := w.camps
	eq(Camps.REGIONAL_BASES.size(), 5, "five regional base sites")
	var guard_counts := []
	var warning_times := []
	for id: String in Camps.REGIONAL_BASES:
		var def: Dictionary = Camps.REGIONAL_BASES[id]
		var c := Camps.site(def)
		var center := w.ground_point(c.x, c.y)
		check(center.y > ForestWorld.WATER_LEVEL + 1.0, "%s base is on dry ground" % id)
		var fire: Campfire = w.structures_root.get_node("base_%s_fire" % id)
		check(fire.lit and fire.eternal, "%s base fire is active" % id)
		var cache: BuildingPiece = w.get_piece("base_%s_cache" % id)
		check(cache.storage.free_slots() < cache.storage.size, "%s has supplies" % id)
		camps._stream_regional_guards(center)
		var guards: Array = camps._regional_guards[id]
		guard_counts.append(guards.size())
		warning_times.append((guards[0] as HumanNPC).warn_time)
		check((guards[0] as HumanNPC)._inside_territory(center), "%s guard protects this base" % id)
		if id == "varkai":
			var first: HumanNPC = guards[0]
			first.die(false)
			camps._stream_regional_guards(Vector3.ZERO)
			check(not camps.npcs.has(first.npc_id), "inactive guards are released")
			check(camps.save_state()[first.npc_id].dead, "inactive dead guard is saved")
			camps._stream_regional_guards(center)
			check((camps.npcs[first.npc_id] as HumanNPC).is_dead(), "guard stays dead after streaming")
		camps._stream_regional_guards(Vector3.ZERO)
	eq(guard_counts, [2, 3, 4, 5, 6], "garrison size increases with difficulty")
	eq(warning_times, [10.0, 8.0, 6.0, 4.0, 2.0], "higher difficulty gives a shorter warning")
	eq(w.get_piece("base_varkai_wall2").piece_id, &"palisade", "strongest base uses a palisade")
	check(w.get_piece("base_ossara_wall2") == null, "easiest base has an open perimeter")
	await _teardown(s)


func test_regional_bases_migrate_old_saves_without_resetting_new_ones() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var old := w.collect_save()
	old.erase("regional_bases")
	old.structures = (old.structures as Array).filter(func(row: Dictionary) -> bool:
		return not str(row.id).begins_with("base_"))
	w.apply_save(old)
	check(w.get_piece("base_ossara_cache") != null, "older saves gain regional bases")
	var state := w.collect_save()
	state.structures = (state.structures as Array).filter(func(row: Dictionary) -> bool:
		return str(row.id) != "base_ossara_cache")
	w.apply_save(state)
	check(w.get_piece("base_ossara_cache") == null, "a removed cache stays removed after loading")
	await _teardown(s)


func test_clan_warns_then_attacks_trespasser() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "clan", 0)
	_near(s, n, 6.0)
	n.awareness = 1.0
	n._think(0.1)
	eq(n.state, HumanNPC.State.WARN, "warns a trespasser first")
	var before := s.world.factions.relation(&"clan")
	n.state_time = HumanNPC.WARN_TIME + 0.5
	n.awareness = 1.0
	n._think(0.1)
	eq(n.state, HumanNPC.State.COMBAT, "attacks if the warning is ignored")
	check(s.world.factions.relation(&"clan") < before, "trespassing costs trust")
	await _teardown(s)


func test_gesture_and_offering() -> void:
	var s: GameSession = await _boot()
	var f := s.world.factions
	var r0 := f.relation(&"hunters")
	check(f.gesture_seen(&"hunters"), "gesture counts")
	check(not f.gesture_seen(&"hunters"), "but not spammable")
	near(f.relation(&"hunters"), r0 + 4.0, 0.01, "gesture +4")
	var n := _npc(s, "hunters", 0)
	var p := s.player
	p.inventory.add_item(&"flint", 2)
	var opts := n.get_interactions(p)
	check(not opts.is_empty() and opts[0].enabled, "can offer flint")
	n.perform_interaction(p, &"interact")
	eq(p.inventory.count_of(&"flint"), 1, "offering given")
	near(f.relation(&"hunters"), r0 + 4.0 + 6.0, 0.01, "offering raises trust by the item's value")
	n.perform_interaction(p, &"alt_interact")
	var got := 0
	for id in ["meat_dried", "spear", "bandage"]:
		got += p.inventory.count_of(StringName(id))
	eq(got, 1, "barter returns one of their goods")
	await _teardown(s)


func test_attacking_rallies_the_tribe() -> void:
	var s: GameSession = await _boot()
	var a := _npc(s, "clan", 0)
	var b := _npc(s, "clan", 1)
	a.take_damage(10.0, s.player)
	check(s.world.factions.relation(&"clan") <= Factions.HOSTILE, "clan turns hostile")
	eq(b.state, HumanNPC.State.COMBAT, "armed kin join the fight")
	var g := _npc(s, "gatherers", 0)
	g.take_damage(10.0, s.player)
	eq(g.state, HumanNPC.State.FLEE, "unarmed gatherer flees")
	await _teardown(s)


func test_npc_spear_hits_player() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "hunters", 1)
	var p := s.player
	_near(s, n, 1.4)
	n._face(p.global_position)
	n._set_state(HumanNPC.State.COMBAT)
	var hp := p.stats.health
	for i in 30:
		n._update_attack(1.0 / 60.0)
	near(p.stats.health, hp, 0.01, "the draw-back telegraphs the attack without doing damage")
	for i in 10:
		n._update_attack(1.0 / 60.0)
	near(p.stats.health, hp - HumanNPC.DAMAGE, 0.01, "the tip lands at full extension")
	for i in 35:
		n._update_attack(1.0 / 60.0)
	near(p.stats.health, hp - HumanNPC.DAMAGE, 0.01, "recovery cannot hit twice")

	n._attack_cd = 0.0
	for i in 30:
		n._update_attack(1.0 / 60.0)
	var dodge := n.global_transform.basis.x
	p.global_position += dodge
	for i in 45:
		n._update_attack(1.0 / 60.0)
	near(p.stats.health, hp - HumanNPC.DAMAGE, 0.01, "stepping sideways after the thrust commits avoids the tip")

	n._travel = dodge
	n._speed = 1.0
	n._animate()
	eq(n._cur_anim, "combat/strafe_l", "lateral motion uses the matching footwork clip")
	await _teardown(s)


func test_discovery_journal_and_sleep_safety() -> void:
	var s: GameSession = await _boot()
	var f := s.world.factions
	for k in ["hunters", "clan", "gatherers"]:
		f.meet(StringName(k))
	check("JOURNAL_CLAN" in s.world.journal and "JOURNAL_ACT2" in s.world.journal, "Act II journal after meeting all three")
	_near(s, _npc(s, "clan", 0), 10.0)
	s.world.day_night.time_hours = 23.0
	check(not s.player._safe_to_sleep(), "unsafe to sleep next to wary armed strangers")
	await _teardown(s)


func test_relations_and_deaths_persist() -> void:
	var s: GameSession = await _boot()
	s.world.factions.change(&"gatherers", 37.0)
	s.world.factions.meet(&"gatherers")
	_npc(s, "hunters", 2).take_damage(1000.0, null)
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))
	await _teardown(s)
	Game.pending_save = data
	var s2: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s2)
	await tree.physics_frame
	near(s2.world.factions.relation(&"gatherers"), 57.0, 0.01, "relation restored")
	check(s2.world.factions.known.has(&"gatherers"), "discovery restored")
	check(_npc(s2, "hunters", 2).is_dead(), "dead stay dead")
	await _teardown(s2)


func test_faces_follow_behaviour() -> void:
	var s: GameSession = await _boot()
	var npc := _npc(s, "gatherers", 0)
	npc.set_physics_process(false)  # hold the state; drive the face directly
	check(npc.expression_weight(&"angry") == 0.0, "sapiens gatherer starts with a neutral face")
	npc.state = HumanNPC.State.WARN
	for i in 30:
		npc._update_face(0.05)
	check(npc.expression_weight(&"angry") > 0.9, "warning someone off → angry face (%.2f)" % npc.expression_weight(&"angry"))
	npc.state = HumanNPC.State.GREET
	for i in 30:
		npc._update_face(0.05)
	check(npc.expression_weight(&"happy") > 0.9 and npc.expression_weight(&"angry") < 0.1, "greeting → smile, anger fades")
	npc._hurt_face_t = 1.0
	for i in 5:
		npc._update_face(0.05)
	check(npc.expression_weight(&"pain") > 0.9, "hit → pain")
	await _teardown(s)


func test_sapiens_have_spring_cloth_and_hair() -> void:
	var s: GameSession = await _boot()
	var npc := _npc(s, "gatherers", 0)
	var sims := npc.find_children("*", "SpringBoneSimulator3D", true, false)
	check(sims.size() == 1, "hominin NPC gets a spring-bone simulator")
	if sims.size() == 1:
		var sim: SpringBoneSimulator3D = sims[0]
		check(sim.setting_count >= 8, "skirt strips (and hair) are simulated (%d chains)" % sim.setting_count)
	await _teardown(s)
