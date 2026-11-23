extends TestCase
## Human NPC AI: the day in camp, paths through camp, animals, fighting together, Neanderthal clan.


func _boot() -> GameSession:
	Game.pending_save = {}
	var s: GameSession = load("res://scenes/game.tscn").instantiate()
	tree.root.add_child(s)
	for i in 4:
		await tree.physics_frame
	s.world.wildlife.enabled = false
	for a: Animal in s.world.wildlife.living():
		a.queue_free()
	await tree.process_frame
	return s


func _teardown(s: GameSession) -> void:
	s.queue_free()
	await tree.process_frame
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _npc(s: GameSession, faction: String, i: int = 0) -> HumanNPC:
	return s.world.camps.npcs["npc_%s_%d" % [faction, i]]


func _hold(n: HumanNPC) -> void:
	n.set_physics_process(false)


func _beast(s: GameSession, species: StringName, at: Vector3) -> Animal:
	var a := s.world.wildlife.spawn(species, s.world.ground_point(at.x, at.z) + Vector3.UP * 0.3)
	a.set_physics_process(false)
	return a


func test_clan_are_neanderthals_with_new_clips() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "clan", 0)
	eq(n._body_model, "NeanderthalM", "the clan is Neanderthal")
	eq(_npc(s, "clan", 2)._body_model, "NeanderthalF", "with Neanderthal women")
	for clip in ["life/sleep", "life/work", "life/step", "combat/throw", "combat/feint", "combat/hit_l", "combat/hit_r"]:
		check(n._anim.has_animation(clip), "clan member has %s" % clip)
	check(_npc(s, "gatherers", 0)._anim.has_animation("life/sleep"), "sapiens also sleep")
	eq(n._look_mods.size(), 2, "head and neck look-at modifiers")
	check(n.find_children("*", "SpringBoneSimulator3D", true, false).size() == 1, "skirt and hair swing")
	await _teardown(s)


func test_night_sleep_watch_and_morning() -> void:
	var s: GameSession = await _boot()
	var dn := s.world.day_night
	dn.time_hours = 23.0
	var g: TribeGroup = s.world.camps.groups["camp_hunters"]
	var sleepers := 0
	var watch := 0
	for n: HumanNPC in g.members:
		_hold(n)
		n.awareness = 0.0
		n._routine()
		if n.state == HumanNPC.State.SLEEP:
			sleepers += 1
		elif n.state == HumanNPC.State.SIT:
			watch += 1
	eq(watch, 1, "one hunter keeps watch by the fire")
	eq(sleepers, 2, "the others sleep")
	var sleeper: HumanNPC = g.members[1]
	check(sleeper._goal.distance_to(g.home) < 3.5, "they sleep around the hearth")
	check(sleeper._sees(s.player) < 0.01 or sleeper.global_position.distance_to(s.player.global_position) < 8.0,
		"a sleeper doesn't see a stranger far away")
	dn.time_hours = 8.0
	sleeper._routine()
	eq(sleeper.state, HumanNPC.State.IDLE, "wakes in the morning")
	await _teardown(s)


func test_camp_paths_go_around_the_fire() -> void:
	var s: GameSession = await _boot()
	var nav := s.world.npc_nav
	for i in 240:
		if nav.is_ready("camp_gatherers"):
			break
		await tree.physics_frame
	for i in 4:
		await tree.physics_frame
	check(nav.is_ready("camp_gatherers"), "camp navigation mesh baked")
	var g: TribeGroup = s.world.camps.groups["camp_gatherers"]
	var a := s.world.ground_point(g.home.x - 5.0, g.home.z)
	var b := s.world.ground_point(g.home.x + 5.0, g.home.z)
	var path := nav.path(a, b)
	check(path.size() >= 3, "a path with turns (%d points)" % path.size())
	var closest := INF
	for i in path.size() - 1:
		var q := Geometry3D.get_closest_point_to_segment(g.home, path[i], path[i + 1])
		closest = minf(closest, Vector2(q.x - g.home.x, q.z - g.home.z).length())
	check(closest > 0.9, "the path keeps clear of the fire (%.2f m)" % closest)
	check(nav.path(Vector3(1500, 0, 1500), Vector3(1510, 0, 1500)).is_empty(), "no path far from any camp")
	await _teardown(s)


func test_armed_people_fight_a_wolf_together() -> void:
	var s: GameSession = await _boot()
	var g: TribeGroup = s.world.camps.groups["camp_hunters"]
	var n: HumanNPC = g.members[0]
	var wolf := _beast(s, &"wolf", n.global_position + Vector3(6, 0, 0))
	wolf.threat = n
	wolf._set_state(Animal.State.CHASE)
	n._scan_t = 0.0
	n._think(0.12)
	eq(n.state, HumanNPC.State.COMBAT, "an armed hunter faces the wolf")
	check(n.foe == wolf, "the wolf is the foe")
	var joined := 0
	for m: HumanNPC in g.members:
		if m != n and m.state == HumanNPC.State.COMBAT and m.foe == wolf:
			joined += 1
	check(joined >= 1, "kin join the fight (%d)" % joined)
	await _teardown(s)


func test_unarmed_run_to_the_fire_and_bears_need_three() -> void:
	var s: GameSession = await _boot()
	var gatherer := _npc(s, "gatherers", 0)
	gatherer.global_position = gatherer.home + Vector3(9, 0, 0)
	var wolf := _beast(s, &"wolf", gatherer.global_position + Vector3(5, 0, 0))
	wolf.threat = gatherer
	wolf._set_state(Animal.State.CHASE)
	gatherer._scan_t = 0.0
	gatherer._think(0.12)
	eq(gatherer.state, HumanNPC.State.FLEE, "an unarmed gatherer flees")
	var dir: Vector3 = gatherer._desired().dir
	check(dir.dot((gatherer.home - gatherer.global_position).normalized()) > 0.5, "toward the fire")
	wolf.queue_free()
	var hunter: HumanNPC = (s.world.camps.groups["camp_hunters"] as TribeGroup).members[0]
	for m: HumanNPC in (s.world.camps.groups["camp_hunters"] as TribeGroup).members:
		if m != hunter:
			m.global_position = hunter.global_position + Vector3(0, 0, 60)  # alone
	var bear := _beast(s, &"bear", hunter.global_position + Vector3(7, 0, 0))
	bear.threat = hunter
	bear._set_state(Animal.State.CHASE)
	hunter._scan_t = 0.0
	hunter._think(0.12)
	eq(hunter.state, HumanNPC.State.FLEE, "a lone hunter doesn't face a bear")
	await _teardown(s)


func test_wolf_bites_people_and_spears_hurt_beasts() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "hunters", 1)
	_hold(n)
	var wolf := _beast(s, &"wolf", n.global_position + n.global_transform.basis.z * 1.2)
	wolf.look_at(n.global_position, Vector3.UP)
	wolf.threat = n
	wolf._set_state(Animal.State.ATTACK)
	var hp := n.health
	for i in 60:
		wolf._update_attack(1.0 / 30.0)
	check(n.health < hp, "the wolf's bite hurts the hunter (%.0f → %.0f)" % [hp, n.health])
	var deer := _beast(s, &"deer", n.global_position + n.global_transform.basis.z * 1.6)
	n._face(deer.global_position)
	n.foe = deer
	n.state = HumanNPC.State.COMBAT
	var deer_hp := deer.health
	n._begin(&"thrust", deer)
	for i in 60:
		n._update_attack(1.0 / 60.0)
	check(deer.health < deer_hp, "the spear thrust wounds the deer (%.0f → %.0f)" % [deer_hp, deer.health])
	await _teardown(s)


func test_spear_thrown_from_range() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "hunters", 0)
	_hold(n)
	var p := s.player
	var out := (n.global_position - n.home).normalized()  # away from the fire, over open ground
	var at := n.global_position + out * 9.0
	p.global_position = s.world.ground_point(at.x, at.z) + Vector3.UP * 0.2
	n._face(p.global_position)
	n._engage(p)
	eq(n.spears, 1, "armed people carry one throwing spear")
	for i in 70:
		n._update_attack(1.0 / 60.0)
	eq(n.spears, 0, "the spear was thrown at 9 m")
	var flying := s.world.pickups_root.find_children("*", "ThrownSpear", true, false)
	check(flying.size() >= 1, "a spear is in the air")
	await _teardown(s)


func test_attackers_share_tokens_and_slots() -> void:
	var s: GameSession = await _boot()
	var g: TribeGroup = s.world.camps.groups["camp_clan"]
	var p := s.player
	var fighters: Array = []
	for n: HumanNPC in g.members:
		_hold(n)
		n.foe = p
		n.state = HumanNPC.State.COMBAT
		fighters.append(n)
	var granted := 0
	for n: HumanNPC in fighters:
		if g.request_attack(n, p):
			granted += 1
	eq(granted, TribeGroup.MAX_ATTACKERS, "only two close in at once")
	var slots: Array = []
	for n: HumanNPC in fighters:
		slots.append(g.slot_for(n, p))
	var min_gap := INF
	for i in slots.size():
		for j in range(i + 1, slots.size()):
			min_gap = minf(min_gap, (slots[i] as Vector3).distance_to(slots[j]))
	check(min_gap > 2.5, "slots surround the foe (closest pair %.1f m)" % min_gap)
	g.release_attack(fighters[0])
	var waiting: HumanNPC = fighters[3] if not g.request_attack(fighters[3], p) else null
	check(waiting == null, "a released token passes to the next fighter")
	fighters[0].health = 20.0
	fighters[1].health = 20.0
	check(g.should_retreat(p), "half the fighters badly hurt → fall back")
	await _teardown(s)


func test_hit_during_windup_interrupts_and_feint_does_no_harm() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "clan", 1)
	_hold(n)
	var p := s.player
	var at := n.global_position + n.global_transform.basis.z * 1.5
	p.global_position = s.world.ground_point(at.x, at.z) + Vector3.UP * 0.2
	n._face(p.global_position)
	n._engage(p)
	n._begin(&"thrust", p)
	for i in 10:
		n._update_attack(1.0 / 60.0)
	n.take_damage(5.0, null)
	check(n._attack_time < 0.0, "a blow during the wind-up stops the thrust")
	var hp: float = p.stats.health
	n._attack_cd = 0.0
	n._begin(&"feint", p)
	for i in 80:
		n._update_attack(1.0 / 60.0)
	near(p.stats.health, hp, 0.01, "a feint never lands")
	await _teardown(s)


func test_hunting_party_and_caring_for_the_wounded() -> void:
	var s: GameSession = await _boot()
	s.world.day_night.time_hours = 9.0
	var g: TribeGroup = s.world.camps.groups["camp_hunters"]
	for n: HumanNPC in g.members:
		_hold(n)
		n.state = HumanNPC.State.IDLE
	(g.members[0] as HumanNPC)._choose_activity(&"day")
	var out := g.members.filter(func(n: HumanNPC) -> bool: return n.state == HumanNPC.State.HUNT)
	eq(out.size(), 2, "two hunters set out")
	check((out[0] as HumanNPC)._hunt_goal.distance_to(g.home) > 40.0, "to hunting grounds away from camp")
	(g.members[2] as HumanNPC)._choose_activity(&"day")
	check((g.members[2] as HumanNPC).state != HumanNPC.State.HUNT, "only one party a day")
	var hurt := _npc(s, "gatherers", 0)
	var carer := _npc(s, "gatherers", 1)
	_hold(hurt)
	_hold(carer)
	hurt.state = HumanNPC.State.IDLE
	hurt.health = 30.0
	hurt.bleeding = 1.0
	carer.state = HumanNPC.State.IDLE
	carer.global_position = hurt.global_position + Vector3(1.0, 0, 0)
	carer._choose_activity(&"day")
	eq(carer.state, HumanNPC.State.TEND, "a kinsman tends the wounded")
	carer.state_time = 9.0
	carer._routine()
	check(hurt.health > 60.0 and hurt.bleeding == 0.0, "the wound is dressed (%.0f hp)" % hurt.health)
	await _teardown(s)


func test_gatherers_bring_food_to_the_store() -> void:
	var s: GameSession = await _boot()
	s.world.day_night.time_hours = 11.0
	var n := _npc(s, "gatherers", 2)
	_hold(n)
	var g: TribeGroup = n.group
	n._set_state(HumanNPC.State.GATHER)
	n.global_position = n._goal
	n._routine()
	eq(n.state, HumanNPC.State.WORK, "picks at the forage spot")
	check(n.carrying != &"", "found something")
	n.state_time = 20.0
	n._routine()
	eq(n.state, HumanNPC.State.DELIVER, "carries it home")
	n.global_position = n._goal
	n._routine()
	var total := 0
	for k in g.stock:
		total += int(g.stock[k])
	check(total > 0, "the camp's store grew")
	await _teardown(s)


func test_throw_clip_draws_the_spear_back_over_the_shoulder() -> void:
	var s: GameSession = await _boot()
	var n := _npc(s, "clan", 0)
	_hold(n)
	var sk := n._skel
	var hand := sk.find_bone("hand_r")
	var head := sk.find_bone("head")
	n._play("combat/throw", false, 0.0)
	n._anim.seek(0.45, true)
	sk.force_update_all_bone_transforms()
	var h := sk.get_bone_global_pose(hand).origin
	var top := sk.get_bone_global_pose(head).origin
	print("THROW cocked hand=", h, " head=", top)
	check(h.y > top.y - 0.15, "hand raised to head height when cocked (%.2f vs %.2f)" % [h.y, top.y])
	check(h.z < top.z, "hand drawn back behind the head (z %.2f vs %.2f)" % [h.z, top.z])
	n._anim.seek(0.9, true)
	sk.force_update_all_bone_transforms()
	var f := sk.get_bone_global_pose(hand).origin
	print("THROW released hand=", f)
	check(f.z > top.z + 0.2, "hand forward after release")
	await _teardown(s)


func test_legs_stand_under_the_hips() -> void:
	var s: GameSession = await _boot()
	for id in ["npc_clan_0", "npc_clan_2", "npc_gatherers_0", "npc_gatherers_1"]:
		var n: HumanNPC = s.world.camps.npcs[id]
		_hold(n)
		var sk := n._skel
		for clip in ["idle", "alert", "gesture", "combat/guard"]:
			n._play(clip, false, 0.0)
			n._anim.seek(0.5, true)
			sk.force_update_all_bone_transforms()
			var widest := 0.0
			for side in ["l", "r"]:
				var hip := sk.get_bone_global_pose(sk.find_bone("thigh_" + side)).origin
				var ankle := sk.get_bone_global_pose(sk.find_bone("foot_" + side)).origin
				widest = maxf(widest, absf(ankle.x) - absf(hip.x))
			check(widest < 0.075, "%s %s: ankle %.3f m outside the hip (legs not splayed)" % [id, clip, widest])
	await _teardown(s)
