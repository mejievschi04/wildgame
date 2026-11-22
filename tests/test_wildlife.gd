extends TestCase
## Phase 3: perception, prey/predator behaviour, combat, hunting loot, spear throw, director, persistence.


func _boot() -> GameSession:
	Game.pending_save = {}
	var s: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s)
	for i in 4:
		await tree.physics_frame
	s.world.wildlife.enabled = false  # tests place animals explicitly
	for a in s.world.wildlife.living():
		a.queue_free()
	await tree.process_frame
	return s


func _teardown(s: GameSession) -> void:
	s.queue_free()
	await tree.process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _spawn(s: GameSession, species: StringName, offset: Vector3) -> Animal:
	var p := s.player.global_position + offset
	return s.world.wildlife.spawn(species, s.world.ground_point(p.x, p.z) + Vector3.UP * 0.2)


func _run(seconds: float) -> void:
	var frames := int(seconds * 60.0)
	for i in frames:
		await tree.physics_frame


func test_smell_depends_on_wind() -> void:
	var s: GameSession = await _boot()
	var deer := _spawn(s, &"deer", Vector3(20, 0, 0))
	await tree.physics_frame
	var src := deer.global_position + Vector3(-20, 0, 0)
	s.world.weather.wind_dir = Vector2(1, 0)  # blowing from source towards the deer
	check(deer.smells(src), "downwind: scent reaches the deer")
	s.world.weather.wind_dir = Vector2(-1, 0)
	check(not deer.smells(src), "upwind: no scent")
	await _teardown(s)


func test_hearing_sprint_vs_crouch() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	p._move_noise = 1.0
	check(p.noise_level() > 0.9, "sprinting is loud")
	p._move_noise = 0.12
	p._noise_burst = 0.0
	check(p.noise_level() < 0.2, "crouch-walking is quiet")
	p._crouching = true
	check(p.visibility_factor() < 0.6, "crouching lowers visibility")
	await _teardown(s)


func test_prey_flees_and_alarms_herd() -> void:
	var s: GameSession = await _boot()
	var herd := s.world.wildlife.spawn_group(&"deer", 3, s.player.global_position)
	await tree.physics_frame
	var lead: Animal = herd[0]
	var start := lead.global_position.distance_to(s.player.global_position)
	lead.take_damage(10.0, s.player)
	check(lead.state == Animal.State.FLEE, "hurt deer flees")
	var others := 0
	for a: Animal in herd:
		if a != lead and a.state == Animal.State.FLEE:
			others += 1
	check(others >= 1, "herd mates were alarmed (%d)" % others)
	await _run(3.0)
	check(lead.global_position.distance_to(s.player.global_position) > start + 8.0, "deer ran away from the player")
	await _teardown(s)


func test_predator_gives_up_and_retreats() -> void:
	var s: GameSession = await _boot()
	var wolf := _spawn(s, &"wolf", Vector3(12, 0, 6))
	await tree.physics_frame
	wolf.threat = s.player
	wolf._set_state(Animal.State.CHASE)
	wolf.state_time = float(wolf.def.give_up) + 1.0
	wolf._think_predator(0.1, s.player, 0.0)
	check(wolf.state == Animal.State.PATROL, "wolf gives up a long chase (no permanent aggro)")
	check(wolf.calm_until > wolf._uptime, "and stays calm for a while")
	wolf.take_damage(wolf.max_health * 0.7, s.player)
	check(wolf.state == Animal.State.FLEE, "badly hurt wolf retreats")
	await _teardown(s)


func test_wolf_bite_hurts_player() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var wolf := _spawn(s, &"wolf", Vector3(0, 0, -1.3))
	await tree.physics_frame
	wolf.look_at(Vector3(p.global_position.x, wolf.global_position.y, p.global_position.z))
	wolf.threat = p
	var hp := p.stats.health
	wolf._set_state(Animal.State.ATTACK)
	await _run(1.0)
	check(p.stats.health < hp, "bite after the wind-up deals damage (%.1f → %.1f)" % [hp, p.stats.health])
	await _teardown(s)


func test_hunt_and_butcher() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var deer := _spawn(s, &"deer", Vector3(3, 0, 0))
	await tree.physics_frame
	deer.take_damage(1000.0, p)
	check(deer.is_dead() and deer.is_in_group("carcass"), "deer killed → carcass")
	check(deer.get_interactions(p)[0].enabled == false, "needs a knife")
	p.inventory.add_item(&"flint_knife")
	deer.perform_interaction(p, &"interact")
	eq(p.inventory.count_of(&"meat_raw"), 6, "meat from a deer")
	eq(p.inventory.count_of(&"hide"), 2, "hides from a deer")
	check("JOURNAL_HUNT" in s.world.journal, "first hunt journal entry")
	await _teardown(s)


func test_spear_throw_hits() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var deer := _spawn(s, &"deer", Vector3(0, 0, -8))
	deer.set_physics_process(false)  # stand still
	await tree.physics_frame
	var hp := deer.health
	var spear := ThrownSpear.new()
	s.world.pickups_root.add_child(spear)
	var target := deer.global_position + Vector3.UP * 0.9
	var from := target + Vector3(0, 0.3, 6)
	spear.launch(ItemStack.new(&"spear", 1, 80), from, (target - from).normalized() * 24.0, p)
	await _run(1.0)
	check(deer.health < hp, "thrown spear damages the deer (%.1f → %.1f)" % [hp, deer.health])
	check(not spear.flying and spear.stack.durability < 80, "spear landed and wore")
	await _teardown(s)


func test_director_spawns_out_of_sight() -> void:
	var s: GameSession = await _boot()
	s.world.wildlife.enabled = true
	s.world.wildlife.balance()
	await tree.physics_frame
	var deer := s.world.wildlife.living(&"deer")
	var wolves := s.world.wildlife.living(&"wolf")
	check(deer.size() > 0 and deer.size() <= 8, "deer population within limit (%d)" % deer.size())
	check(wolves.size() <= 3, "wolf pack within limit (%d)" % wolves.size())
	for i in 6:
		s.world.wildlife.balance()
	check(s.world.wildlife.living().size() <= Wildlife.MAX_TOTAL, "total population capped (%d)" % s.world.wildlife.living().size())
	for a in deer + wolves:
		check(a.global_position.distance_to(s.player.global_position) > 40.0, "spawned away from the player")
	await _teardown(s)


func test_carcass_persists() -> void:
	var s: GameSession = await _boot()
	var deer := _spawn(s, &"deer", Vector3(5, 0, 5))
	await tree.physics_frame
	deer.take_damage(1000.0, s.player)
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))
	await _teardown(s)
	Game.pending_save = data
	var s2: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s2)
	await tree.physics_frame
	var carcasses := tree.get_nodes_in_group("carcass")
	check(carcasses.size() == 1 and (carcasses[0] as Animal).species == &"deer", "deer carcass restored")
	await _teardown(s2)


func test_all_species_have_models_clips_and_fur() -> void:
	var s: GameSession = await _boot()
	for sp: StringName in ItemDB.animals.keys():
		var a := _spawn(s, sp, Vector3(30, 0, 30))
		await tree.process_frame
		check(a._anim != null, "%s has an AnimationPlayer" % sp)
		for clip in ["idle", "walk", "run", "graze", "alert", "attack", "death"]:
			check(a._anim.has_animation(clip), "%s has clip %s" % [sp, clip])
		var fur := false
		for mi: MeshInstance3D in a._model.find_children("*", "MeshInstance3D", true, false):
			var m := mi.get_surface_override_material(0)
			if m is BaseMaterial3D and (m as BaseMaterial3D).transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
				fur = mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		check(fur, "%s has alpha-tested fur cards that don't cast shadows" % sp)
		a.queue_free()
	await _teardown(s)


func test_mammoth_defends_itself() -> void:
	var s: GameSession = await _boot()
	var m := _spawn(s, &"mammoth", Vector3(0, 0, -6))
	await tree.physics_frame
	m.awareness = 1.0
	m._set_state(Animal.State.ALERT)
	m._think_defensive(0.1, s.player, 1.0)
	check(m.state == Animal.State.CHASE, "a mammoth charges a player who comes too close")
	m.state_time = float(m.def.give_up) + 1.0
	m._think_defensive(0.1, s.player, 1.0)
	check(m.state == Animal.State.RECOVER and m.calm_until > m._uptime, "then calms down (no permanent aggro)")
	var far := _spawn(s, &"mammoth", Vector3(0, 0, -40))
	await tree.physics_frame
	far.take_damage(30.0, s.player)
	check(far.state == Animal.State.CHASE, "a hurt mammoth turns on the attacker instead of fleeing")
	await _teardown(s)


func test_bear_is_territorial_and_wolves_skip_megafauna() -> void:
	var s: GameSession = await _boot()
	var bear := _spawn(s, &"bear", Vector3(0, 0, -8))
	await tree.physics_frame
	bear.hungry = false
	check(bear._wants_to_attack(s.player), "a bear engages a player inside its territory")
	check(bear._find_prey() == null, "bears don't hunt deer")
	var wolf := _spawn(s, &"wolf", Vector3(60, 0, 0))
	var mam := _spawn(s, &"mammoth", Vector3(64, 0, 0))
	var roe := _spawn(s, &"roe", Vector3(56, 0, 0))
	await tree.physics_frame
	var prey := wolf._find_prey()
	check(prey != mam, "wolves don't pick a mammoth as prey")
	check(prey == null or prey == roe, "roe deer are valid wolf prey")
	var stag := _spawn(s, &"megaloceros", Vector3(58, 0, 3))
	roe.queue_free()
	await tree.physics_frame
	check(wolf._find_prey() != stag, "a giant deer is too big for a wolf")
	await _teardown(s)
