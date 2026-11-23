extends TestCase
## Animal AI v2: herds, vigilance, rest and water, packs, bites and feeding, warnings, climate habitats.


func _boot() -> GameSession:
	Game.pending_save = {}
	var s: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s)
	for i in 4:
		await tree.physics_frame
	s.world.wildlife.enabled = false
	for a in s.world.wildlife.living():
		a.queue_free()
	await tree.process_frame
	return s


func _teardown(s: GameSession) -> void:
	s.queue_free()
	await tree.process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run(seconds: float) -> void:
	for i in int(seconds * 60.0):
		await tree.physics_frame


func test_herd_follows_leader_and_flees_together() -> void:
	var s: GameSession = await _boot()
	var herd := s.world.wildlife.spawn_group(&"deer", 4, s.player.global_position + Vector3(0, 0, -60))
	await tree.physics_frame
	var lead: Animal = herd[0].leader()
	for a: Animal in herd:
		check(a.leader() == lead, "one leader for the whole herd")
	var follower: Animal = herd[0] if herd[0] != lead else herd[1]
	follower.global_position = lead.global_position + Vector3(40, 0, 0)
	follower._set_state(Animal.State.GRAZE)
	follower._herd_routine()
	eq(follower.state, Animal.State.WANDER, "a straggler walks back to the herd")
	check(follower._goal.distance_to(lead.global_position) < 10.0, "toward the leader")
	follower.global_position = lead.global_position + Vector3(3, 0, 0)
	lead.take_damage(5.0, s.player)
	var dirs: Array = []
	for a: Animal in herd:
		if a.state == Animal.State.FLEE:
			dirs.append(a._flee_dir)
	check(dirs.size() >= 3, "the herd bolts (%d fleeing)" % dirs.size())
	for d: Vector3 in dirs:
		check(d.dot(dirs[0]) > 0.99, "all in the same direction")
	await _teardown(s)


func test_grazing_animals_see_less_until_they_look_up() -> void:
	var s: GameSession = await _boot()
	var deer := s.world.wildlife.spawn(&"deer", s.player.global_position + Vector3(0, 0, -30))
	await tree.physics_frame
	deer._set_state(Animal.State.GRAZE)
	deer._lookup_t = 0.0
	check(deer._sight_factor() < 0.7, "head down: short sight")
	deer._lookup_t = 1.0
	check(deer._sight_factor() > 1.0, "head up: scanning")
	deer._set_state(Animal.State.REST)
	check(deer._sight_factor() < 0.5, "bedded down at night: barely sees")
	await _teardown(s)


func test_herd_rests_at_night_and_drinks_by_day() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var z := -300.0
	var bank := Vector3(w.river_x(z) + 45.0, 0, z)
	var herd := w.wildlife.spawn_group(&"deer", 3, w.ground_point(bank.x, bank.z))
	await tree.physics_frame
	for a: Animal in herd:
		a.global_position = w.ground_point(bank.x, bank.z) + Vector3(randf_range(-3, 3), 0.2, randf_range(-3, 3))
		a.set_physics_process(false)
	var lead: Animal = herd[0].leader()
	w.day_night.time_hours = 23.5
	lead._set_state(Animal.State.GRAZE)
	lead._herd_routine()
	eq(lead.state, Animal.State.REST, "the herd beds down at night")
	w.day_night.time_hours = 9.0
	lead._herd_routine()
	eq(lead.state, Animal.State.GRAZE, "and gets up in the morning")
	lead._thirst_t = -1.0
	lead._herd_routine()
	eq(lead.state, Animal.State.DRINK, "thirsty: the leader heads for water")
	var h := w.height_at(lead._goal.x, lead._goal.z)
	check(h > ForestWorld.WATER_LEVEL and h < ForestWorld.WATER_LEVEL + 0.7, "to the waterline (h %.2f)" % h)
	var drinking := 0
	for a: Animal in herd:
		if a.state == Animal.State.DRINK:
			drinking += 1
	eq(drinking, 3, "the whole herd goes to drink")
	await _teardown(s)


func test_wolf_pack_stalks_bites_and_feeds() -> void:
	var s: GameSession = await _boot()
	var p := s.player.global_position
	var pack: Array[Animal] = []
	for i in 3:
		pack.append(s.world.wildlife.spawn(&"wolf", s.world.ground_point(p.x + i * 2.0, p.z - 120.0) + Vector3.UP * 0.3))
	for a: Animal in pack:
		a.herd = pack.duplicate()
	await tree.physics_frame
	var deer := s.world.wildlife.spawn(&"deer", pack[0].global_position + Vector3(30, 0, 0))
	await tree.physics_frame
	for a: Animal in pack:
		a.global_position = pack[0].global_position + Vector3(randf_range(-4, 4), 0, randf_range(-4, 4))
		a.set_physics_process(false)
		a._set_state(Animal.State.PATROL)
	deer.set_physics_process(false)
	var wolf: Animal = pack[0]
	wolf._start_hunt(deer)
	eq(wolf.state, Animal.State.STALK, "the wolf stalks first")
	var joined := 0
	for a: Animal in pack:
		if a != wolf and a.state == Animal.State.STALK and a.threat == deer:
			joined += 1
	eq(joined, 2, "the pack joins the hunt")
	wolf.global_position = deer.global_position + Vector3(1.5, 0, 0)
	wolf._think_predator(0.1, s.player, 0.0)
	eq(wolf.state, Animal.State.HUNT_PREY, "close: the sprint")
	var hp := deer.health
	wolf._attack_cd = 0.0
	wolf._think_predator(0.1, s.player, 0.0)
	check(deer.health < hp and not deer.is_dead(), "a bite wounds, it doesn't kill outright (%.0f → %.0f)" % [hp, deer.health])
	for i in 10:
		wolf._attack_cd = 0.0
		wolf._think_predator(0.1, s.player, 0.0)
		if deer.is_dead():
			break
	check(deer.is_dead() and deer.killed_by == &"wolf", "the pack brings it down")
	wolf._think_predator(0.1, s.player, 0.0)
	eq(wolf.state, Animal.State.FEED, "then feeds at the kill")
	s.player.global_position = deer.global_position + Vector3(9, 0, 0)
	wolf._think_predator(0.1, s.player, 0.5)
	eq(wolf.state, Animal.State.THREAT, "and warns someone who comes for it")
	await _teardown(s)


func test_hungry_predator_comes_to_a_carcass() -> void:
	var s: GameSession = await _boot()
	var p := s.player.global_position
	var wolf := s.world.wildlife.spawn(&"wolf", p + Vector3(0, 0, -150))
	var deer := s.world.wildlife.spawn(&"deer", p + Vector3(15, 0, -150))
	await tree.physics_frame
	deer.die(&"player")
	wolf.hungry = true
	wolf.set_physics_process(false)
	wolf._set_state(Animal.State.IDLE)
	wolf._think_predator(0.1, s.player, 0.0)
	eq(wolf.state, Animal.State.FEED, "the wolf comes to eat the carcass")
	check(wolf._carcass == deer, "that carcass")
	await _teardown(s)


func test_climate_habitats_and_temperature() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	check(w.wildlife.habitat_ok(&"boar", 100.0, 1500.0), "boars live in the jungle")
	check(not w.wildlife.habitat_ok(&"mammoth", 100.0, 1500.0), "no mammoths in the jungle")
	check(not w.wildlife.habitat_ok(&"reindeer", 100.0, 1500.0), "no reindeer in the jungle")
	check(w.wildlife.habitat_ok(&"reindeer", 180.0, -1740.0), "reindeer on the tundra")
	check(not w.wildlife.habitat_ok(&"boar", 180.0, -1740.0), "no boars on the tundra")
	var mid := w.ambient_temperature_at(w.ground_point(0, 0))
	check(w.ambient_temperature_at(w.ground_point(600, 1300)) > mid + 6.0, "the jungle is warm")
	check(w.ambient_temperature_at(w.ground_point(180, -1800)) < mid - 9.0, "the tundra is cold")
	await _teardown(s)


func test_animal_voices_are_pluggable_and_captioned() -> void:
	eq(Sfx.animal_key("wolf_howl_02.ogg"), "wolf_howl", "numbered variants share a key")
	eq(Sfx.animal_key("Mammoth_Stamp.wav"), "mammoth_stamp", "case does not matter")
	eq(Sfx.animal_key("any_alarm_1.wav"), "any_alarm", "a fallback for every species")
	eq(Sfx.animal_key("wolf_running.wav"), "", "unknown events are ignored")
	var s: GameSession = await _boot()
	var heard: Array = []
	var cb := func(t: String) -> void: heard.append(t)
	Sfx.caption.connect(cb)
	var was: Variant = Settings.get_value("accessibility", "subtitles")
	Settings.set_value("accessibility", "subtitles", true, false)
	var wolf := s.world.wildlife.spawn(&"wolf", s.player.global_position + Vector3(0, 0, -20))
	await tree.physics_frame
	wolf.voice(&"growl")
	wolf.voice(&"growl")
	eq(heard.size(), 1, "a subtitle even without a recording, and no spam")
	check(heard.size() > 0 and "рычание" in heard[0], "it says what the wolf did (%s)" % [heard])
	var far := s.world.wildlife.spawn(&"deer", s.player.global_position + Vector3(0, 0, -300))
	await tree.physics_frame
	far.voice(&"call")
	eq(heard.size(), 1, "too far away to hear a deer's call")
	Settings.set_value("accessibility", "subtitles", was, false)
	Sfx.caption.disconnect(cb)
	await _teardown(s)
