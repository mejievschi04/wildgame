extends TestCase

const MILD := {"ambient_temp": 16.0, "warmth": 0.0, "insulation": 4.0}


func _sim(s: SurvivalStats, seconds: float, env: Dictionary) -> void:
	var t := 0.0
	while t < seconds:
		s.tick(1.0, env)
		t += 1.0


func test_needs_drain() -> void:
	var s := SurvivalStats.new()
	_sim(s, 600, MILD)
	check(s.hunger < 100.0 and s.hunger > 60.0, "hunger drains moderately in 10 min (%.1f)" % s.hunger)
	check(s.thirst < s.hunger, "thirst drains faster than hunger")
	near(s.health, 100.0, 0.01, "no damage while needs are fine")


func test_starvation_damages() -> void:
	var s := SurvivalStats.new()
	s.hunger = 0.0
	_sim(s, 10, MILD)
	check(s.health < 100.0, "starving hurts")


func test_cold_night_causes_hypothermia() -> void:
	var s := SurvivalStats.new()
	_sim(s, 400, {"ambient_temp": -2.0, "warmth": 0.0, "insulation": 4.0})
	check(s.has_condition(&"hypothermia"), "hypothermia after a cold exposure (body %.2f)" % s.body_temp)
	check(s.health < 100.0, "hypothermia damages")


func test_fire_prevents_hypothermia() -> void:
	var s := SurvivalStats.new()
	_sim(s, 600, {"ambient_temp": -2.0, "warmth": 20.0, "insulation": 4.0})
	check(not s.has_condition(&"hypothermia"), "fire keeps you warm")
	near(s.body_temp, SurvivalStats.NORMAL_TEMP, 0.2, "body temperature normal")


func test_sleep_restores_rest() -> void:
	var s := SurvivalStats.new()
	s.rest = 10.0
	_sim(s, 300, {"ambient_temp": 10.0, "warmth": 15.0, "insulation": 4.0, "sleeping": true})
	check(s.rest > 70.0, "rest restored while sleeping (%.1f)" % s.rest)


func test_sprint_stamina() -> void:
	var s := SurvivalStats.new()
	for i in 50:
		s.tick(0.1, {"ambient_temp": 16.0, "sprinting": true})
	check(s.stamina < 100.0 - 50.0, "sprinting 5 s costs stamina")
	_sim(s, 10, MILD)
	check(s.stamina > 90.0, "stamina regenerates")


func test_consume_and_sickness() -> void:
	var s := SurvivalStats.new()
	s.hunger = 50.0
	var sick := s.consume(ItemDB.get_item(&"meat_cooked"), 0.99)
	check(not sick, "cooked meat is safe")
	near(s.hunger, 82.0, 0.01, "cooked meat feeds")
	sick = s.consume(ItemDB.get_item(&"meat_raw"), 0.1)
	check(sick and s.has_condition(&"food_poisoning"), "raw meat can poison")
	s.add_condition(&"bleeding")
	s.consume(ItemDB.get_item(&"bandage"))
	check(not s.has_condition(&"bleeding"), "bandage stops bleeding")


func test_difficulty_scales() -> void:
	var a := SurvivalStats.new()
	var b := SurvivalStats.new()
	b.difficulty = 1.45
	_sim(a, 300, MILD)
	_sim(b, 300, MILD)
	check(b.hunger < a.hunger, "hard difficulty drains faster")


func test_death_and_roundtrip() -> void:
	var s := SurvivalStats.new()
	s.add_condition(&"food_poisoning", 30.0)
	s.body_temp = 36.1
	var s2 := SurvivalStats.new()
	s2.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	near(s2.body_temp, 36.1, 0.001, "temp restored")
	check(s2.has_condition(&"food_poisoning"), "condition restored")
	s.damage(1000.0, &"fall")
	check(s.dead and s.death_cause == &"fall", "death recorded")
