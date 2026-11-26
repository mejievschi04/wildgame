extends TestCase
## Night raids (Raids): who comes, the approach with a torch, the stalk in cover, the attack, hit and run,
## the withdrawal, and a raid waking a sleeper.


func _boot() -> GameSession:
	Game.pending_save = {}
	var s: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s)
	for i in 4:
		await tree.physics_frame
	s.world.wildlife.enabled = false
	s.world.raids.enabled = false  # the tests start raids themselves
	s.world.day_night.time_hours = 23.0
	return s


func _teardown(s: GameSession) -> void:
	s.queue_free()
	await tree.process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run(seconds: float) -> void:
	for i in int(seconds * 60.0):
		await tree.physics_frame


func _put(n: HumanNPC, s: GameSession, dist: float) -> void:
	var p := s.player.global_position
	var away := n.global_position - p
	away.y = 0.0
	var at := p + away.normalized() * dist
	n.global_position = s.world.ground_point(at.x, at.z) + Vector3.UP * 0.1


func test_who_raids() -> void:
	var s: GameSession = await _boot()
	var r := s.world.raids
	var who := r.raiders()
	check(who.get(&"varkai", 0.0) == 3.0, "the hostile red tribe raids most (%s)" % [who])
	check(who.has(&"kharum") and who.has(&"north") and who.has(&"clan"), "wary territorial tribes raid sometimes")
	check(not who.has(&"gatherers") and not who.has(&"hunters"), "peaceful and neutral people never raid")
	s.world.factions.change(&"varkai", 200.0)
	check(not r.raiders().has(&"varkai"), "good relations stop the raids")
	await _teardown(s)


func test_war_party_approaches_stalks_attacks_and_withdraws() -> void:
	var s: GameSession = await _boot()
	var r := s.world.raids
	var p := s.player
	var party := r.start(&"varkai", 3)
	eq(party.size(), 3, "a war party of three")
	eq(r.phase, &"approach", "they set out")
	var d0 := party[0].global_position.distance_to(p.global_position)
	check(d0 > 100.0 and d0 < 160.0, "they come from out of sight (%.0f m)" % d0)
	check(party.all(func(n: HumanNPC) -> bool: return n.armed and n.raider), "all armed")
	check(is_instance_valid(party[0]._torch_light), "the leader carries a burning torch")
	await _run(4.0)
	check(party[0].global_position.distance_to(p.global_position) < d0 - 3.0, "they walk toward the player")
	for n in party:
		_put(n, s, 40.0)
	await _run(0.6)
	eq(r.phase, &"stalk", "close by they stop to stalk")
	var spots := party.map(func(n: HumanNPC) -> float: return n._raid_goal.distance_to(p.global_position))
	check(spots.all(func(d: float) -> bool: return d > 15.0 and d < 34.0), "stalking spots on a ring round the player (%s)" % [spots])
	await _run(4.0)
	var keep := func(n: HumanNPC) -> bool:
		return n.global_position.distance_to(p.global_position) > 10.0 and n.state != HumanNPC.State.COMBAT
	check(party.all(keep), "while stalking they keep their distance")
	r._phase_t = r._stalk_for + 1.0
	await _run(0.6)
	eq(r.phase, &"attack", "then they attack together")
	check(party.all(func(n: HumanNPC) -> bool: return n.state == HumanNPC.State.COMBAT and n.foe == p), "everyone fights the player")
	party[1].die(true)
	party[2].die(true)
	await _run(0.6)
	eq(r.phase, &"withdraw", "with two of three down the last one runs")
	eq(party[0].state, HumanNPC.State.RAID, "and stops fighting")
	_put(party[0], s, 130.0)
	await _run(0.6)
	check(not r.active(), "out of sight, the raid is over")
	await _teardown(s)


func test_walking_up_to_a_stalker_starts_the_fight() -> void:
	var s: GameSession = await _boot()
	var r := s.world.raids
	var party := r.start(&"kharum", 2)
	for n in party:
		_put(n, s, 30.0)
	await _run(0.6)
	eq(r.phase, &"stalk", "stalking")
	_put(party[0], s, 7.0)
	await _run(0.6)
	eq(r.phase, &"attack", "a player who comes close is attacked")
	await _teardown(s)


func test_hit_and_run_then_dawn() -> void:
	var s: GameSession = await _boot()
	var r := s.world.raids
	var party := r.start(&"varkai", 4)
	for n in party:
		_put(n, s, 20.0)
	await _run(0.6)
	r._phase_t = r._stalk_for + 1.0
	await _run(0.6)
	var n := party[0]
	n.health = n.max_health * 0.45
	var fled := false
	for i in 120:
		await tree.physics_frame
		fled = fled or n.state == HumanNPC.State.FLEE
	check(fled, "a badly hurt raider backs off")
	n.state_time = 13.0
	await _run(0.3)
	check(n.state in [HumanNPC.State.RAID, HumanNPC.State.COMBAT], "and comes back to the fight")
	s.world.day_night.time_hours = 6.0
	await _run(0.6)
	eq(r.phase, &"withdraw", "at dawn they leave")
	await _teardown(s)


func test_raid_wakes_a_sleeper() -> void:
	var s: GameSession = await _boot()
	var r := s.world.raids
	r.enabled = true
	r._plan_night = r._night_key()
	r._plan_hour = 23.5
	s.world.day_night.time_hours = 23.6
	r.simulate(10.0)
	check(r.active() and r.wake_player, "a raid due during sleep wakes the player")
	var d := r.party[0].global_position.distance_to(s.player.global_position)
	check(d < 100.0, "and the raiders are already close (%.0f m)" % d)
	await _teardown(s)


func test_daylight_raids_are_occasional() -> void:
	var s: GameSession = await _boot()
	var r := s.world.raids
	var dn := s.world.day_night
	var planned := 0
	for day in range(1, 41):
		dn.day = day
		r._plan_daylight()
		if r._day_hour >= 0.0:
			planned += 1
			check(r._day_hour >= Raids.DAY_START and r._day_hour <= Raids.DAY_END, "by day between 9 and 17 (%.1f)" % r._day_hour)
	check(planned > 3 and planned < 30, "some days, not every day (%d of 40)" % planned)
	r.enabled = true
	dn.day = 50
	r._plan_daylight()
	r._plan_night = r._night_key()
	r._plan_hour = -1.0
	r._day_hour = 11.0
	dn.time_hours = 10.5
	await _run(0.6)
	check(not r.active(), "not before its hour")
	dn.time_hours = 11.2
	await _run(0.6)
	check(r.active() and r.by_day, "a war party comes in daylight")
	check(not is_instance_valid(r.party[0]._torch_light), "without torches")
	r.enabled = false
	dn.time_hours = 13.0
	await _run(0.6)
	eq(r.phase, &"approach", "daylight does not send it home")
	dn.time_hours = 21.5
	await _run(0.6)
	check(r.phase in [&"withdraw", &""], "nightfall does (%s)" % r.phase)  # still far off: already gone
	await _teardown(s)
