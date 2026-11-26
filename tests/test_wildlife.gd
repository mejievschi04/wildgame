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
	check(spear._host != null and spear.freeze, "the spear stays stuck in the deer")
	var rel := spear.global_position - deer.global_position
	deer.global_position += Vector3(2.0, 0.0, 0.0)
	await _run(0.1)
	check((spear.global_position - deer.global_position).distance_to(rel) < 0.3, "the stuck spear moves with the deer")
	await _teardown(s)


## A patch of ground a few metres in front of the player (the spawn meadow is flat).
func _flat_ground(s: GameSession) -> Vector3:
	var p := s.player.global_position + Vector3(0, 0, -6)
	return s.world.ground_point(p.x, p.z)


func test_spear_sticks_point_first_in_the_ground() -> void:
	var s: GameSession = await _boot()
	var g := _flat_ground(s)
	var spear := ThrownSpear.new()
	s.world.pickups_root.add_child(spear)
	var from := g + Vector3(0, 3.0, 3.0)
	spear.launch(ItemStack.new(&"spear", 1, 80), from, (g - from).normalized() * 22.0, s.player)
	await _run(0.6)
	check(not spear.flying, "it came down")
	check(spear.freeze, "stuck fast, not lying loose")
	var tip := spear.global_position + spear.global_transform.basis.z.normalized() * spear._tip
	var ground := s.world.ground_point(tip.x, tip.z)
	check(tip.y < ground.y - 0.05, "the point is buried (%.2f m deep)" % (ground.y - tip.y))
	check(spear.global_position.y > ground.y, "the shaft stands out of the ground")
	check(spear.global_transform.basis.z.normalized().y < -0.5, "point down, as it came in")
	await _teardown(s)


func test_grazing_spear_glances_off_and_tumbles() -> void:
	var s: GameSession = await _boot()
	var g := _flat_ground(s)
	var spear := ThrownSpear.new()
	s.world.pickups_root.add_child(spear)
	var from := g + Vector3(0, 0.5, 6.0)
	# skimming in at a few degrees: too flat to bite
	spear.launch(ItemStack.new(&"spear", 1, 80), from, (g - from).normalized() * 22.0, s.player)
	await _run(0.5)
	check(not spear.flying, "it hit the ground")
	check(not spear.freeze, "it glanced off as a loose rigid body instead of sticking")
	await _run(3.0)
	var at := spear.global_position
	check(at.y > s.world.ground_point(at.x, at.z).y - 0.2, "it comes to rest on the ground, not in it")
	await _teardown(s)


func test_arrow_flies_a_ballistic_arc_with_drag() -> void:
	var s: GameSession = await _boot()
	var arrow := ThrownSpear.new()
	s.world.pickups_root.add_child(arrow)
	arrow.drag = Player.ARROW_DRAG
	var from := s.player.global_position + Vector3(0, 30.0, 0)  # high up: nothing to hit for a while
	arrow.launch(ItemStack.new(&"arrow", 1), from, Vector3(0, 0, -45.0), s.player)
	await _run(0.5)
	check(arrow.flying, "still in the air")
	var drop := from.y - arrow.global_position.y
	check(drop > 0.9 and drop < 1.4, "falls under gravity (%.2f m in 0.5 s)" % drop)
	check(-arrow._vel.z < 44.0 and -arrow._vel.z > 38.0, "air drag slows it (%.1f m/s)" % -arrow._vel.z)
	check(arrow.global_transform.basis.z.normalized().dot(arrow._vel.normalized()) > 0.99, "points along its flight")
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


func test_all_species_have_models_clips_and_coats() -> void:
	var s: GameSession = await _boot()
	for sp: StringName in ItemDB.animals.keys():
		var a := _spawn(s, sp, Vector3(30, 0, 30))
		await tree.process_frame
		check(a._anim != null, "%s has an AnimationPlayer" % sp)
		for clip in ["idle", "walk", "run", "graze", "alert", "attack", "death"]:
			check(a._anim.has_animation(clip), "%s has clip %s" % [sp, clip])
		for move: Dictionary in ItemDB.animals[sp].get("attacks", []):
			check(a._anim.has_animation(String(move.clip)), "%s has attack clip %s" % [sp, move.clip])
		if sp in [&"mammoth", &"bear", &"deer", &"megaloceros", &"rhino", &"smilodon", &"lion", &"wolf"]:
			var skeletons := a._model.find_children("*", "Skeleton3D", true, false)
			check(not skeletons.is_empty(), "%s has an imported skeleton" % sp)
			if not skeletons.is_empty():
				var skeleton := skeletons[0] as Skeleton3D
				var bones := ["head", "ear.L", "ear.R"]
				bones.append_array(["snout", "snout2", "snout3", "snout4"] if sp == &"mammoth"
					else ["jaw", "upperarm.L", "forearm.R", "thigh.L", "shin.R"])
				for bone in bones:
					check(skeleton.find_bone(bone) >= 0, "%s has bone %s" % [sp, bone])
			var textured_skin := false
			for mesh: MeshInstance3D in a._model.find_children("*", "MeshInstance3D", true, false):
				var material := mesh.mesh.surface_get_material(0) as BaseMaterial3D
				if mesh.skin and material and material.albedo_texture:
					textured_skin = true
			check(textured_skin, "%s has a skinned mesh with its baked coat texture" % sp)
			a.queue_free()
			continue
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
	check(m.state == Animal.State.THREAT, "a mammoth first warns a player who comes too close")
	m.state_time = Animal.THREAT_TIME + 0.1
	m._think_defensive(0.1, s.player, 1.0)
	check(m.state == Animal.State.CHASE, "and charges if the player stays")
	m.state_time = float(m.def.give_up) + 1.0
	m._think_defensive(0.1, s.player, 1.0)
	check(m.state == Animal.State.RECOVER and m.calm_until > m._uptime, "then calms down (no permanent aggro)")
	var far := _spawn(s, &"mammoth", Vector3(0, 0, -40))
	await tree.physics_frame
	far.take_damage(30.0, s.player)
	check(far.state == Animal.State.CHASE, "a hurt mammoth turns on the attacker instead of fleeing")
	# several attack moves: up close they vary; the short rear-up stomp is never drawn out of its reach
	var near := {}
	m.threat = s.player
	s.player.global_position = m.global_position + Vector3(0, 0, 2.0)
	for i in 60:
		near[String(m._pick_attack().clip)] = true
	check(near.size() >= 3, "a mammoth up close varies its attacks (%s)" % [near.keys()])
	s.player.global_position = m.global_position + Vector3(0, 0, 3.5)
	var stomped := false
	for i in 60:
		stomped = stomped or m._pick_attack().clip == "attack_stomp"
	check(not stomped, "the stomp is only drawn when the target is close enough for it")
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
	var prey_deer := _spawn(s, &"deer", Vector3(56, 0, 0))
	await tree.physics_frame
	var prey := wolf._find_prey()
	check(prey != mam, "wolves don't pick a mammoth as prey")
	check(prey == null or prey == prey_deer, "deer are valid wolf prey")
	var stag := _spawn(s, &"megaloceros", Vector3(58, 0, 3))
	prey_deer.queue_free()
	await tree.physics_frame
	check(wolf._find_prey() != stag, "a giant deer is too big for a wolf")
	await _teardown(s)


func test_start_valley_has_no_dangerous_spawns() -> void:
	var s: GameSession = await _boot()
	var w := s.world.wildlife
	w.enabled = true
	for i in 60:
		w.balance()
	await tree.physics_frame
	var dangerous := 0
	for a in w.living():
		if Wildlife.is_dangerous(a.def):
			dangerous += 1
	check(dangerous == 0, "no predators/defensive animals around the start clearing (%d)" % dangerous)
	check(w.living(&"deer").size() > 0, "prey still populates the start valley")
	await _teardown(s)


func test_habitat_and_wildness_rules() -> void:
	var s: GameSession = await _boot()
	var w := s.world.wildlife
	var camp := ForestWorld.SPAWN
	var aruun: Vector2 = ForestWorld.REGIONS[&"aruun"]
	var north: Vector2 = ForestWorld.REGIONS[&"tundra"]
	check(w.habitat_ok(&"deer", camp.x, camp.y + 40.0), "deer live near the coastal camp")
	check(not w.habitat_ok(&"wolf", camp.x, camp.y + 40.0), "wolves keep away from the start clearing")
	check(w.habitat_ok(&"wolf", aruun.x, aruun.y - 90.0), "wolves roam the wilder parts of Aruun")
	check(not w.habitat_ok(&"mammoth", aruun.x, aruun.y), "mammoths don't live in the Aruun forest")
	check(w.habitat_ok(&"mammoth", north.x, north.y), "mammoths live on the northeastern tundra")
	await _teardown(s)


func test_killed_pack_stays_gone() -> void:
	var s: GameSession = await _boot()
	var w := s.world.wildlife
	var wolf := _spawn(s, &"wolf", Vector3(30, 0, 0))
	check(w.can_respawn(&"wolf"), "wolves may spawn before any kill")
	wolf.take_damage(9999.0, s.player)
	await tree.physics_frame
	check(not w.can_respawn(&"wolf"), "a killed wolf blocks new packs for a while")
	s.world.advance_time(float(ItemDB.get_animal(&"wolf").respawn_h) * s.world.day_night.day_length_sec / 24.0 + 10.0)
	check(w.can_respawn(&"wolf"), "wolves return after their respawn time")
	var saved := w.save_director()
	w.load_director({})
	w.load_director(saved)
	check(saved.has("wolf"), "respawn timers are saved")
	await _teardown(s)


func _equip_bow(p: Node, arrows: int) -> void:
	p.inventory.add_item(&"bow")
	p.inventory.equip_slot(p.inventory.first_slot_of(&"bow"))
	if arrows > 0:
		p.inventory.add_item(&"arrow", arrows)


func test_bow_shoots_arrow_into_deer() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	var deer := _spawn(s, &"deer", Vector3(0, 0, -12))
	deer.set_physics_process(false)
	await tree.physics_frame
	_equip_bow(p, 3)
	var target := deer.global_position + Vector3.UP * 0.9
	p.look_at(Vector3(target.x, p.global_position.y, target.z))
	var cam: Camera3D = p.camera
	var to := target - cam.global_position
	p.head.rotation.x = atan2(to.y, Vector2(to.x, to.z).length())
	await tree.physics_frame
	var hp := deer.health
	p._begin_draw()
	check(p.drawing, "drawing starts with arrows in the inventory")
	p._draw_t = Player.BOW_DRAW_TIME
	p._release_draw()
	check(p.inventory.count_of(&"arrow") == 2, "one arrow used (%d left)" % p.inventory.count_of(&"arrow"))
	check(p.inventory.hand != null and p.inventory.hand.durability < 150, "bow wears per shot")
	await _run(1.0)
	check(deer.health < hp, "arrow damages the deer (%.1f → %.1f)" % [hp, deer.health])
	await _teardown(s)


func test_bow_needs_arrows_and_a_real_draw() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	_equip_bow(p, 0)
	p._begin_draw()
	check(not p.drawing, "no draw without arrows")
	p.inventory.add_item(&"arrow", 1)
	p._begin_draw()
	p._draw_t = Player.BOW_DRAW_TIME * 0.1
	p._release_draw()
	check(p.inventory.count_of(&"arrow") == 1, "a barely drawn string is let down without shooting")
	check(not p.drawing and not p.aiming, "draw state cleared")
	await _teardown(s)


func test_club_blow_knocks_a_wolf_back_but_not_a_mammoth() -> void:
	var s: GameSession = await _boot()
	var wolf := _spawn(s, &"wolf", Vector3(0, 0, -6))
	var mammoth := _spawn(s, &"mammoth", Vector3(14, 0, -14))
	await tree.physics_frame
	var club := ItemDB.get_item(&"club")
	var j := HitPhysics.melee_impulse(club, true)
	var w0 := wolf.global_position
	wolf.hit_impulse(j, Vector3(0, 0, -1))
	check(wolf._stagger_t > 0.0, "a heavy club blow staggers the wolf")
	var m0 := mammoth.global_position
	mammoth.hit_impulse(j, Vector3(0, 0, -1))
	check(mammoth._stagger_t <= 0.0, "the mammoth does not even stagger")
	await _run(0.6)
	var wolf_back := (wolf.global_position - w0).dot(Vector3(0, 0, -1))
	check(wolf_back > 0.5, "the wolf is shoved back along the blow (%.2f m)" % wolf_back)
	check(Vector2(mammoth.global_position.x - m0.x, mammoth.global_position.z - m0.z).length() < 0.5 \
		or mammoth._speed > 0.5, "the mammoth is not shoved (it may walk on its own)")
	await _teardown(s)


func test_carcass_keeps_the_killing_blow_and_lies_along_the_slope() -> void:
	var s: GameSession = await _boot()
	var deer := _spawn(s, &"deer", Vector3(0, 0, -8))
	await tree.physics_frame
	deer.take_damage(1000.0, s.player, deer.global_position + Vector3.UP)
	check(deer.is_dead(), "killed")
	var p0 := deer.global_position
	deer.hit_impulse(HitPhysics.projectile_impulse(1.8, 24.0), Vector3(1, 0, 0))
	await _run(1.5)
	check(deer.global_position.x - p0.x > 0.2, "the carcass slid on with the spear's momentum (%.2f m)" % (deer.global_position.x - p0.x))
	check(deer._push_v.length() < 0.05, "and came to rest")
	var n := HitPhysics.ground_normal(s.world, deer.global_position.x, deer.global_position.z)
	var up := deer._model.global_transform.basis.y.normalized()
	check(up.dot(n) > 0.97, "the body lies along the ground (normal %.3f)" % up.dot(n))
	await _teardown(s)


func test_carcass_slides_down_a_steep_slope() -> void:
	var n := Vector3(0.6, 0.8, 0.0)  # ~37°, steeper than a hide holds on grass
	var v := Vector3.ZERO
	for i in 60:
		v = HitPhysics.corpse_slide(v, n, 1.0 / 60.0)
	check(v.x > 0.5, "slides downhill (%.2f m/s)" % v.x)
	v = Vector3.ZERO
	n = Vector3(0.3, 0.95, 0.0).normalized()  # ~17°: it stays
	for i in 60:
		v = HitPhysics.corpse_slide(v, n, 1.0 / 60.0)
	check(v.length() < 0.01, "a gentle slope holds it")


func _shoot_arrow(s: GameSession, from: Vector3, at: Vector3) -> ThrownSpear:
	var arrow := ThrownSpear.new()
	s.world.pickups_root.add_child(arrow)
	arrow.base_damage = 34.0
	arrow.ref_speed = Player.ARROW_SPEED_MAX * 0.85
	arrow.drag = Player.ARROW_DRAG
	arrow.stick_speed = 11.0
	arrow.launch(ItemStack.new(&"arrow", 1), from, (at - from).normalized() * 42.0, s.player)
	return arrow


func _nearest_tree(s: GameSession, around: Vector3) -> ResourceNode:
	var best: ResourceNode = null
	for n: Node in s.world.get_tree().get_nodes_in_group("resource_node"):
		var r := n as ResourceNode
		if r and String(r.kind).begins_with("tree") and r.collision_layer & 1 and r.is_inside_tree() \
				and (best == null or r.global_position.distance_to(around) < best.global_position.distance_to(around)):
			best = r
	return best


func test_arrows_stick_in_trees_animals_and_people() -> void:
	var s: GameSession = await _boot()
	var p := s.player
	# a tree: shot at chest height from 8 m
	var tree_node := _nearest_tree(s, p.global_position)
	check(tree_node != null, "a tree to shoot at")
	var tp := tree_node.global_position + Vector3.UP * 1.4
	var a1 := _shoot_arrow(s, tp + Vector3(8, 0.2, 0.5), tp)
	# a deer standing still
	var deer := _spawn(s, &"deer", Vector3(0, 0, -10))
	deer.set_physics_process(false)
	await tree.physics_frame
	var dp := deer.global_position + Vector3.UP * 1.0
	var a2 := _shoot_arrow(s, dp + Vector3(0, 0.3, 9), dp)
	# a person
	var n: HumanNPC = s.world.camps.npcs["npc_hunters_0"]
	n.set_physics_process(false)
	var np := n.global_position + Vector3.UP * 1.2
	var a3 := _shoot_arrow(s, np + Vector3(7, 0.2, 0), np)
	for a: ThrownSpear in [a1, a2, a3]:
		a.break_chance = 0.0
	await _run(0.8)
	for pair: Array in [[a1, "tree"], [a2, "deer"], [a3, "person"]]:
		var a: ThrownSpear = pair[0]
		check(is_instance_valid(a) and not a.flying and a.freeze and a.collision_layer == 4,
			"the arrow is stuck in the %s" % pair[1])
	check(is_instance_valid(a2) and a2._host != null, "the arrow in the deer rides on its bones")
	check(is_instance_valid(a3) and a3._host != null, "the arrow in the person rides on their bones")
	await _teardown(s)


func test_arrows_stick_in_carcasses_and_dead_wood() -> void:
	var s: GameSession = await _boot()
	var deer := _spawn(s, &"deer", Vector3(0, 0, -9))
	await tree.physics_frame
	deer.take_damage(1000.0, s.player, deer.global_position + Vector3.UP)
	await _run(2.0)  # lying down
	var dp := deer.global_position + Vector3.UP * 0.35
	var a1 := _shoot_arrow(s, dp + Vector3(0, 2.5, 6), dp)
	a1.break_chance = 0.0
	# a lone log on the ground (vegetation marks them as wood)
	var log_body: StaticBody3D = null
	for b: StaticBody3D in s.world.find_children("*", "StaticBody3D", true, false):
		if b.has_meta(&"wood"):
			log_body = b
			break
	check(log_body != null, "a fallen trunk, stump or log to shoot at")
	var lp := log_body.global_position + Vector3.UP * 0.25
	var a2 := _shoot_arrow(s, lp + Vector3(0, 3.0, 5), lp)
	a2.break_chance = 0.0
	await _run(0.8)
	check(is_instance_valid(a1) and a1.freeze and a1._host != null, "the arrow is stuck in the carcass")
	var ok := is_instance_valid(a2) and a2.freeze
	check(ok, "the arrow is stuck in the dead wood")
	await _teardown(s)
