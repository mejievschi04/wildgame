extends TestCase
## Weather: determinism, wetness, fires, shelter, sleep, storm damage, persistence.


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


func _roofed_room(s: GameSession, at: Vector3) -> BuildingPiece:
	var w := s.world
	var f: BuildingPiece = w.spawn_structure(&"piece", Transform3D(Basis(), Vector3(at.x, w.height_at(at.x, at.z) - 0.05, at.z)), {"piece": "foundation"})
	f.complete()
	var bc := s.player.build
	for i in 3:
		bc.def = ItemDB.get_piece(&"wall")
		var sock: Dictionary = bc.find_sockets("edge", f.global_position)[i]
		var wall: BuildingPiece = w.spawn_structure(&"piece", sock.xform, {"piece": "wall", "on": sock.supports})
		wall.complete()
	bc.def = ItemDB.get_piece(&"roof")
	var rs: Dictionary = bc.find_sockets("top", f.global_position)[0]
	var roof: BuildingPiece = w.spawn_structure(&"piece", rs.xform, {"piece": "roof", "on": rs.supports})
	roof.complete()
	return f


func test_deterministic_sequence() -> void:
	var seqs: Array = []
	for run in 2:
		var s: GameSession = await _boot()
		var seq := PackedStringArray()
		for i in 40:
			s.world.weather.simulate(300.0)
			seq.append(String(s.world.weather.state))
		seqs.append(seq)
		await _teardown(s)
	eq(seqs[0], seqs[1], "same seed → same weather sequence")
	var kinds := {}
	for st in seqs[0]:
		kinds[st] = true
	check(kinds.size() >= 3, "several weather states occur over ~8 game days (%s)" % str(kinds.keys()))


func test_rain_wets_and_chills() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	s.world.weather.set_state(&"rain", true)
	await tree.physics_frame
	check(s.world.weather.rain_at(p.global_position) > 0.5, "player is exposed to rain")
	var dry_env := {"ambient_temp": 10.0, "warmth": 0.0, "insulation": 4.0}
	var a := SurvivalStats.new()
	var b := SurvivalStats.new()
	for i in 120:
		a.tick(1.0, dry_env)
		b.tick(1.0, {"ambient_temp": 10.0, "warmth": 0.0, "insulation": 4.0, "rain": 0.6})
	check(b.wetness > 0.6 and b.has_condition(&"wet"), "soaked after 2 min of rain (%.2f)" % b.wetness)
	check(b.last_effective_temp < a.last_effective_temp - 3.0, "wet clothes feel much colder")
	for i in 40:
		b.tick(1.0, {"ambient_temp": 10.0, "warmth": 20.0, "insulation": 4.0})
	check(b.wetness < 0.2, "dries quickly by a fire (%.2f)" % b.wetness)
	check(s.world.ambient_temperature_at(p.global_position) < s.world.day_night.ambient_temperature(), "rain + wind lower the air temperature")
	await _teardown(s)


func test_fire_and_shelter() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var p := s.player
	w.weather.set_state(&"storm", true)
	var open_fire: Campfire = w.spawn_structure(&"campfire", Transform3D(Basis(), p.global_position + Vector3(6, 0, 6)))
	open_fire.add_fuel(600.0)
	open_fire.ignite()
	var room := _roofed_room(w.get_parent() as GameSession, p.global_position + Vector3(-8, 0, -6))
	await tree.physics_frame
	var room_fire: Campfire = w.spawn_structure(&"campfire", Transform3D(Basis(), room.global_position + Vector3(0, BuildingPiece.FOUNDATION_H, 0)))
	room_fire.add_fuel(600.0)
	room_fire.ignite()
	await tree.physics_frame
	check(not w.weather.is_exposed(room.global_position + Vector3(0, 0.5, 0)), "inside the roofed room is sheltered")
	open_fire.simulate(100.0)
	room_fire.simulate(100.0)
	check(open_fire.fuel < room_fire.fuel - 200.0, "storm burns an exposed fire much faster (%.0f vs %.0f)" % [open_fire.fuel, room_fire.fuel])
	p.global_position = Vector3(p.global_position.x + 20, p.global_position.y, p.global_position.z)
	w.day_night.time_hours = 23.0
	await tree.physics_frame
	check(not p.can_sleep().ok, "cannot sleep in the rain outside")
	await _teardown(s)


func test_storm_damages_buildings() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var f: BuildingPiece = w.spawn_structure(&"piece", Transform3D(Basis(), s.player.global_position + Vector3(5, -0.05, 5)), {"piece": "foundation"})
	f.complete()
	w.weather.set_state(&"storm", true)
	w.weather.state_left = 99999.0
	w.weather.simulate(w.day_night.day_length_sec / 24.0 * 4.0)
	check(f.health < f.max_health, "4 storm hours damage buildings (%.1f / %.0f)" % [f.health, f.max_health])
	await _teardown(s)


func test_weather_persists() -> void:
	var s: GameSession = await _boot()
	s.world.weather.set_state(&"fog", true)
	s.world.weather.state_left = 123.0
	var data: Dictionary = JSON.parse_string(JSON.stringify(s.build_save()))
	await _teardown(s)
	Game.pending_save = data
	var s2: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s2)
	await tree.physics_frame
	eq(s2.world.weather.state, &"fog", "weather state restored")
	near(s2.world.weather.state_left, 123.0, 0.5, "remaining duration restored")
	await _teardown(s2)
