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
	lead.mind.thirst = 1.0
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
	check(w.wildlife.habitat_ok(&"lion", 100.0, 1500.0), "cave lions live in the jungle")
	check(not w.wildlife.habitat_ok(&"mammoth", 100.0, 1500.0), "no mammoths in the jungle")
	check(not w.wildlife.habitat_ok(&"bison", 100.0, 1500.0), "no bison in the jungle")
	check(w.wildlife.habitat_ok(&"bison", 180.0, -1740.0), "bison on the tundra")
	check(not w.wildlife.habitat_ok(&"lion", 180.0, -1740.0), "no cave lions on the tundra")
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


func test_minds_needs_fear_and_memory() -> void:
	var s: GameSession = await _boot()
	var far := s.player.global_position + Vector3(0, 0, -150)
	# needs: a fed predator gets hungry with time, a kill satisfies it
	var bear := s.world.wildlife.spawn(&"bear", far)
	await tree.physics_frame
	bear.set_physics_process(false)
	bear.hungry = false
	bear.mind.hunger = 0.0
	for i in 400:
		bear.mind.update(1.0, Animal.State.PATROL, false, false)
	check(bear.mind.hunger > 0.65, "hunger builds up over minutes (%.2f)" % bear.mind.hunger)
	bear.mind.eat()
	eq(bear.mind.hunger, 0.0, "eating satisfies it")
	# temperament comes from the data, a little different per animal
	var deer := s.world.wildlife.spawn(&"deer", far + Vector3(30, 0, 0))
	await tree.physics_frame
	deer.set_physics_process(false)
	check(deer.mind.bold < 0.3 and bear.mind.bold > 0.65, "a deer is timid, a bear bold")
	# fear: a wound frightens, quiet calms; a frightened deer reacts to the player sooner
	var calm := deer.mind.alert_threshold(0.35, deer._uptime)
	deer.take_damage(5.0, s.player)
	check(deer.mind.fear > 0.4, "a wound frightens (%.2f)" % deer.mind.fear)
	check(deer.mind.remembers_player(deer._uptime), "and the deer remembers who did it")
	check(deer.mind.alert_threshold(0.35, deer._uptime) < calm * 0.6, "a wary deer bolts sooner")
	for i in 60:
		deer.mind.update(1.0, Animal.State.GRAZE, false, true)
	check(deer.mind.fear < 0.1, "fear fades when things are quiet")
	# memory: an aggressive animal holds a grudge after it has healed; a timid one only shies away
	bear.take_damage(5.0, s.player)
	bear.health = bear.max_health
	bear.hungry = false
	s.world.day_night.time_hours = 12.0
	check(bear._wants_to_attack(s.player), "the bear comes for whoever hurt it, even healed and fed")
	check(not deer.mind.wants_revenge(deer._uptime), "the deer only keeps away")
	check(bear.mind.near_danger(bear.global_position, bear._uptime), "the place it was hurt is remembered")
	# fatigue: a long sprint wears an animal out and slows its flight
	var fresh := deer.mind.stamina()
	for i in 40:
		deer.mind.update(1.0, Animal.State.FLEE, true, true)
	check(deer.mind.stamina() < fresh * 0.75, "a long run tires (stamina %.2f)" % deer.mind.stamina())
	for i in 120:
		deer.mind.update(1.0, Animal.State.REST, false, true)
	check(deer.mind.fatigue < 0.2, "rest restores it")
	await _teardown(s)


## Puts an animal under the test's control: no physics ticks, nothing perceived from far away.
func _held(s: GameSession, species: StringName, pos: Vector3) -> Animal:
	var a: Animal = s.world.wildlife.spawn(species, s.world.ground_point(pos.x, pos.z))
	await tree.physics_frame
	a.set_physics_process(false)
	return a


func test_species_habits_prey() -> void:
	var s: GameSession = await _boot()
	var base := s.player.global_position + Vector3(0, 0, -200)
	s.world.day_night.time_hours = 12.0
	# deer: freezes first, then grazes on if it calms down, or snorts and bolts if the danger comes close
	var deer := await _held(s, &"deer", base)
	deer.threat = s.player
	deer._set_state(Animal.State.ALERT)
	deer._think(0.1)
	eq(deer.state, Animal.State.FREEZE, "a deer freezes when it notices something")
	deer.state_time = 3.0
	deer.awareness = 0.1
	deer._think(0.1)
	eq(deer.state, Animal.State.GRAZE, "nothing more: it grazes on")
	deer._set_state(Animal.State.FREEZE)
	s.player.global_position = deer.global_position + Vector3(0, 0, 5)
	deer._think(0.1)
	eq(deer.state, Animal.State.FLEE, "the danger comes close: it bolts")
	var d1: Vector3 = deer._desired().dir
	var weave := 0.0
	for i in 26:
		deer.state_time += 0.1
		weave = maxf(weave, d1.angle_to(deer._desired().dir))
	check(weave > 0.5, "and weaves as it runs (%.2f rad)" % weave)
	# giant deer: runs, but cornered and wounded it turns and fights
	var stag := await _held(s, &"megaloceros", base + Vector3(60, 0, 0))
	stag.threat = s.player
	stag._set_state(Animal.State.FLEE)
	stag.health = stag.max_health * 0.5
	s.player.global_position = stag.global_position + Vector3(0, 0, 3)
	stag._think(0.1)
	check(stag.fighting and stag.state == Animal.State.CHASE, "a cornered giant deer turns at bay")
	check(stag.is_hostile(), "and is dangerous while it fights")
	await _teardown(s)


func test_species_habits_predators() -> void:
	var s: GameSession = await _boot()
	var w := s.world
	var base := s.player.global_position + Vector3(0, 0, -220)
	# wolves pick the weak one: a wounded deer a little further off over a healthy one close by
	var wolf := await _held(s, &"wolf", base)
	var healthy := await _held(s, &"deer", base + Vector3(12, 0, 0))
	var hurt := await _held(s, &"deer", base + Vector3(-16, 0, 0))
	hurt.health = hurt.max_health * 0.3
	check(wolf._find_prey() == hurt, "a wolf singles out the wounded deer")
	healthy.queue_free()
	hurt.queue_free()
	# cave lion: lies up by day, wakes hungry at dusk
	var lion := await _held(s, &"lion", base + Vector3(40, 0, 0))
	w.day_night.time_hours = 12.0
	lion.hungry = false
	lion.mind.hunger = 0.45
	lion._set_state(Animal.State.PATROL)
	lion.state_time = 3.0
	lion._think(0.1)
	eq(lion.state, Animal.State.REST, "the lion rests through the day")
	w.day_night.time_hours = 19.0
	lion._think(0.1)
	check(lion.hungry and lion.state == Animal.State.PATROL, "and gets up hungry at dusk")
	# a cat's sprint is short: no catch, it gives up winded
	lion.threat = s.player
	lion._set_state(Animal.State.CHASE)
	lion.state_time = 10.0
	s.player.global_position = lion.global_position + Vector3(0, 0, 30)
	lion._think(0.1)
	eq(lion.state, Animal.State.PATROL, "a missed sprint is given up")
	# smilodon: lies in wait by water, leaps from close with a tearing first bite, drags the kill into cover
	var z := -300.0
	var bank := w.ground_point(w.river_x(z) + 30.0, z)
	var cat := await _held(s, &"smilodon", bank)
	cat.hungry = true
	cat.awareness = 0.0
	s.player.global_position = bank + Vector3(0, 0, 200)
	cat._set_state(Animal.State.PATROL)
	cat._think(0.1)
	eq(cat.state, Animal.State.AMBUSH, "a smilodon goes to lie in wait by the water")
	var prey := await _held(s, &"deer", cat.global_position + Vector3(4, 0, 0))
	prey._set_state(Animal.State.GRAZE)
	cat._think(0.1)
	check(cat.state == Animal.State.HUNT_PREY and cat.attack_bonus > 1.0, "it leaps when prey grazes close")
	prey.die(&"smilodon")
	cat._carcass = prey
	cat._set_state(Animal.State.FEED)
	eq(cat.state, Animal.State.DRAG, "and drags the kill off before it eats")
	await _teardown(s)


func test_species_habits_giants() -> void:
	var s: GameSession = await _boot()
	var base := s.player.global_position + Vector3(0, 0, -240)
	s.world.day_night.time_hours = 12.0
	# bear: roots for food when hungry, and bluffs once before a real charge
	var bear := await _held(s, &"bear", base)
	bear.hungry = true
	bear._set_state(Animal.State.PATROL)
	for i in 400:
		bear.state_time = 4.0
		bear._think(0.1)
		if bear.state == Animal.State.FORAGE:
			break
	eq(bear.state, Animal.State.FORAGE, "a hungry bear forages")
	bear.threat = s.player
	s.player.global_position = bear.global_position + Vector3(0, 0, 4)
	bear._set_state(Animal.State.CHASE)
	bear._think(0.1)
	eq(bear.state, Animal.State.THREAT, "the first charge is a bluff")
	bear._set_state(Animal.State.CHASE)
	bear._think(0.1)
	check(bear.state in [Animal.State.CHASE, Animal.State.ATTACK], "the next one is real")
	# rhino: charges a noise it can't see, in a straight line, then has to stop and turn
	var rhino := await _held(s, &"rhino", base + Vector3(60, 0, 0))
	s.player.global_position = rhino.global_position + Vector3(0, 0, 9)
	rhino.last_known = s.player.global_position
	rhino.awareness = 0.9
	rhino._set_state(Animal.State.ALERT)
	rhino.behavior.mock_left = 0
	rhino._think(0.1)
	eq(rhino.state, Animal.State.CHASE, "a rhino charges what it hears")
	var line: Vector3 = rhino._desired().dir
	s.player.global_position += Vector3(6, 0, 0)   # sidestep
	check(rhino._desired().dir.angle_to(line) < 0.05, "it keeps to its line: the player can sidestep")
	rhino.behavior.charge_t = 5.0
	rhino._think(0.1)
	eq(rhino.state, Animal.State.ALERT, "after the charge it pulls up and turns")
	# bison: a stampede tramples whoever stands in its way
	var bison := await _held(s, &"bison", base + Vector3(120, 0, 0))
	bison._set_state(Animal.State.FLEE)
	bison._speed = float(bison.def.run)
	s.player.global_position = bison.global_position - bison.global_transform.basis.z * 1.2
	var hp: float = s.player.stats.health
	bison.behavior.physics(bison, 0.016)
	check(s.player.stats.health < hp, "the stampede tramples the player")
	# mammoth: the matriarch faces the threat, the herd closes ranks; if she is hurt they all charge
	var herd: Array = []
	for i in 3:
		herd.append(await _held(s, &"mammoth", base + Vector3(180 + i * 8, 0, 0)))
	for m: Animal in herd:
		m.herd = herd
	var lead: Animal = herd[0].leader()
	var cow: Animal = herd[0] if herd[0] != lead else herd[1]
	s.player.global_position = lead.global_position + Vector3(0, 0, 12)
	lead.threat = s.player
	lead._set_state(Animal.State.THREAT)
	cow._set_state(Animal.State.GRAZE)
	cow._think(0.1)
	eq(cow.state, Animal.State.RING, "the herd closes ranks behind the matriarch")
	lead.health = lead.max_health * 0.5
	lead._set_state(Animal.State.CHASE)
	cow._think(0.1)
	eq(cow.state, Animal.State.CHASE, "she is hurt: the herd charges with her")
	await _teardown(s)


func test_wolf_attack_moves() -> void:
	var s: GameSession = await _boot()
	var wolf := await _held(s, &"wolf", s.player.global_position + Vector3(0, 0, -200))
	wolf.threat = s.player
	check(wolf._reach() > float(wolf.def.attack_range) + 1.0, "a wolf can start an attack from leaping distance")
	s.player.global_position = wolf.global_position + Vector3(0, 0, 1.2)
	var near := {}
	for i in 80:
		near[String(wolf._pick_attack().clip)] = true
	check(near.size() >= 3, "up close it mixes its attacks (%s)" % [near.keys()])
	s.player.global_position = wolf.global_position + Vector3(0, 0, 3.0)
	var far := {}
	for i in 40:
		far[String(wolf._pick_attack().clip)] = true
	check(far.keys() == ["attack_leap"], "from a few metres off it leaps (%s)" % [far.keys()])
	var tear: Dictionary = {}
	s.player.global_position = wolf.global_position + Vector3(0, 0, 1.2)
	for i in 200:
		var m := wolf._pick_attack()
		if m.clip == "attack_hamstring":
			tear = m
			break
	check(float(tear.get("bleed", 0.0)) > float(wolf.def.bleed_chance), "the hamstring slash makes the wound bleed")
	# the leap carries it to just short of its target, so it lands where it jumped instead of sliding back
	s.player.global_position = wolf.global_position + Vector3(0, 0, 3.0)
	wolf._set_state(Animal.State.ATTACK)
	wolf._update_attack(0.01)
	eq(String(wolf._attack.clip), "attack_leap", "from 3 m the attack is a leap")
	var travel := float(wolf._lunge.get("speed", 0.0)) * (float(wolf._lunge.get("end", 0.0)) - float(wolf._lunge.get("start", 0.0)))
	check(travel > 1.8 and travel < 2.4, "the leap covers the gap and stops short of the target (%.2f m)" % travel)
	await _teardown(s)
