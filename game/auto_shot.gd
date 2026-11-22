class_name AutoShot
extends Node
## DEV TOOL: deterministic screenshots for verification.
## Usage: godot --path . -- --autoshot=/abs/out.png [--shot-frames=120] [--shot-hour=21.5] [--shot-scenario=inventory]
## Scenarios: none, inventory, journal, pause, camp (lit fire + bed in view), kit (starter items), prompt (aim at sticks),
## build (hut + lean-to + blueprint + active ghost), buildmenu (radial menu), fauna (all species, live).

var out_path := ""
var frames := 120
var shot_list: Array[int] = []
var _chop_tree: TreeNode
var _gore_pending := false
var hour := -1.0
var scenario := ""
var bench_off := PackedStringArray()
var _n := 0
var _fps_samples: Array[float] = []


static func attach_if_requested(parent: Node) -> void:
	var args := {}
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("--") and "=" in a:
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1]
	if not args.has("autoshot"):
		return
	var s := AutoShot.new()
	s.out_path = args.autoshot
	var fl := str(args.get("shot-frames", "120")).split(",", false)
	for f in fl:
		s.shot_list.append(int(f))
	s.frames = s.shot_list.max()
	s.hour = float(args.get("shot-hour", "-1"))
	s.scenario = args.get("shot-scenario", "")
	s.bench_off = str(args.get("bench-off", "")).split(",", false)
	s.process_mode = Node.PROCESS_MODE_ALWAYS
	parent.set_meta("no_focus_pause", true)  # unfocused automation window must not auto-pause
	parent.add_child.call_deferred(s)


func _ready() -> void:
	var session := get_parent() as GameSession
	if session == null:
		return
	if hour >= 0.0:
		session.world.day_night.time_hours = hour
	var p := session.player
	if scenario in ["inventory", "camp", "kit", "journal", "prompt"]:
		for id: StringName in [&"stick", &"stone", &"fiber", &"flint", &"berries", &"meat_raw"]:
			p.inventory.add_item(id, 6)
		p.inventory.add_item(&"flint_knife")
		p.inventory.add_item(&"stone_axe")
		p.inventory.equip_slot(p.inventory.first_slot_of(&"stone_axe"))
	if scenario == "camp":
		var fwd := -p.global_transform.basis.z
		var pos := p.global_position + fwd * 3.2
		var fire: Campfire = session.world.spawn_structure(&"campfire",
			Transform3D(Basis(), session.world.ground_point(pos.x, pos.z)))
		fire.add_fuel(600)
		fire.ignite()
		var bpos := p.global_position + fwd * 4.0 + p.global_transform.basis.x * 2.2
		session.world.spawn_structure(&"bed", Transform3D(Basis(Vector3.UP, 0.4), session.world.ground_point(bpos.x, bpos.z)))
		p.head.rotation.x = -0.25
	if scenario == "prompt":
		var target: Node3D = session.world.get_node_by_save_id("sticks_000")
		p.global_position = target.global_position + Vector3(-1.6, 0.2, 0.0)
		p.look_at(Vector3(target.global_position.x, p.global_position.y, target.global_position.z))
		p.head.rotation.x = -0.6
	if scenario in ["build", "buildmenu"]:
		_build_demo(session)
	if scenario in ["rain", "storm", "fog", "cloudy"]:
		session.world.weather.set_state(StringName(scenario), true)
	if scenario == "wildlife":
		var wl := session.world.wildlife
		wl.enabled = false
		var fwd := -p.global_transform.basis.z
		var c := p.global_position + fwd * 9.0
		var herd := wl.spawn_group(&"deer", 3, c)
		for i in herd.size():
			var pos := c + p.global_transform.basis.x * (i - 1) * 3.0
			herd[i].global_position = session.world.ground_point(pos.x, pos.z) + Vector3.UP * 0.2
			herd[i].rotation.y = p.rotation.y + PI * 0.5 + i * 0.4
			herd[i].set_physics_process(false)  # pose for the screenshot
			herd[i]._play(["graze", "walk", "alert"][i])
		var wc := p.global_position + fwd * 15.0 + p.global_transform.basis.x * 5.0
		for i in 2:
			var w := wl.spawn(&"wolf", session.world.ground_point(wc.x + i * 2.0, wc.z) + Vector3.UP * 0.2)
			w.rotation.y = p.rotation.y + PI * 0.8
			w.set_physics_process(false)
			w._play("walk" if i == 0 else "idle")
		p.head.rotation.x = -0.12
	if scenario == "fauna":  # every species in a row, physics ON (checks ground contact + live animation)
		var wl := session.world.wildlife
		wl.enabled = false
		var cam := p.get_viewport().get_camera_3d()
		var fwd := -cam.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := fwd.cross(Vector3.UP)
		var row := [[&"roe", -3.2, 5.5], [&"wolf", -1.2, 6.0], [&"deer", 1.2, 7.5], [&"bear", 4.0, 8.0], [&"rhino", -5.5, 12.0], [&"bison", 6.5, 11.0], [&"horse", -2.5, 10.0], [&"mammoth", 1.0, 15.0]]
		for e: Array in row:
			var pos: Vector3 = p.global_position + fwd * float(e[2]) + right * float(e[1])
			var a := wl.spawn(e[0], session.world.ground_point(pos.x, pos.z) + Vector3.UP * 0.3)
			a.rotation.y = atan2(fwd.x, fwd.z) + PI * 0.5
			a.calm_until = 1e9
			a.hungry = false
		get_tree().create_timer(1.5).timeout.connect(func() -> void:
			for a: Animal in wl.living():
				var g := session.world.height_at(a.global_position.x, a.global_position.z)
				print("FAUNA_GROUND %s body_y-ground=%.2f" % [a.species, a.global_position.y - g]))
		p.head.rotation.x = -0.05
	if scenario == "carcass":
		var cpos: Vector3 = session.world.get_node("POI_Carcass").global_position
		p.global_position = cpos + Vector3(3.0, 0.5, 2.0)
		p.look_at(Vector3(cpos.x, p.global_position.y, cpos.z))
		p.rotation.x = 0
		p.head.rotation.x = -0.35
	if scenario == "chop":
		var best: TreeNode = null
		for n in session.get_tree().get_nodes_in_group("resource_node"):
			if n is TreeNode and (best == null or n.global_position.distance_to(p.global_position) < best.global_position.distance_to(p.global_position)) \
					and n.global_position.distance_to(p.global_position) > 6.0:
				best = n
		_chop_tree = best
		var side := (p.global_position - best.global_position)
		side.y = 0.0
		p.global_position = best.global_position + side.normalized().rotated(Vector3.UP, 1.2) * 1.35 + Vector3.UP * 0.3
		p.look_at(Vector3(best.global_position.x, p.global_position.y, best.global_position.z))
		p.rotation = Vector3(0, p.rotation.y + 0.18, 0)
		p.head.rotation.x = -0.32
		p.inventory.add_item(&"stone_axe")
		p.inventory.equip_slot(p.inventory.first_slot_of(&"stone_axe"))
	if scenario.begins_with("tribe_"):
		var fname := scenario.substr(6)
		var c := Camps.site(session.world.factions.def_of(StringName(fname)))
		var center := session.world.ground_point(c.x, c.y)
		var at := center + Vector3(cos(-1.25), 0, sin(-1.25)) * 6.5
		p.global_position = session.world.ground_point(at.x, at.z) + Vector3.UP * 0.3
		p.look_at(Vector3(center.x, p.global_position.y, center.z))
		p.rotation = Vector3(0, p.rotation.y, 0)
		p.head.rotation.x = -0.16
		session.world.wildlife.enabled = false
		session.world.factions.change(StringName(fname), 60.0)  # friendly for a calm screenshot
	if scenario == "gore":
		session.world.wildlife.enabled = false
		var c := Camps.site(session.world.factions.def_of(&"hunters"))
		var center := session.world.ground_point(c.x, c.y)
		var at := center + Vector3(cos(-1.25), 0, sin(-1.25)) * 4.0
		p.global_position = session.world.ground_point(at.x, at.z) + Vector3.UP * 0.3
		p.look_at(Vector3(center.x, p.global_position.y, center.z))
		p.rotation = Vector3(0, p.rotation.y, 0)
		p.head.rotation.x = -0.2
		p.inventory.add_item(&"stone_axe")
		p.inventory.equip_slot(p.inventory.first_slot_of(&"stone_axe"))
		_gore_pending = true
	if scenario == "kit":
		session.world.add_journal("JOURNAL_WATER")


func _apply_bench() -> void:
	var root := get_parent()
	var env: Environment = null
	for we: WorldEnvironment in root.find_children("*", "WorldEnvironment", true, false):
		env = we.environment
	for f in bench_off:
		match f:
			"grass", "veg":
				for v in root.find_children("Vegetation", "", true, false):
					for c in v.get_children():
						if c is MultiMeshInstance3D and (f == "veg" or (c as MultiMeshInstance3D).visibility_range_end < 50.0):
							c.visible = false
			"volfog": env.volumetric_fog_enabled = false
			"ssao": env.ssao_enabled = false
			"shadows":
				for l: DirectionalLight3D in root.find_children("*", "DirectionalLight3D", true, false):
					l.shadow_enabled = false
			"msaa": get_viewport().msaa_3d = Viewport.MSAA_DISABLED
			"fsr2":
				get_viewport().msaa_3d = Viewport.MSAA_DISABLED
				get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
				get_viewport().scaling_3d_scale = 0.67
			"fsr2_60":
				get_viewport().msaa_3d = Viewport.MSAA_DISABLED
				get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
				get_viewport().scaling_3d_scale = 0.6
			"shadow2k":
				RenderingServer.directional_shadow_atlas_set_size(2048, true)
			"shadow60":
				for l: DirectionalLight3D in root.find_children("*", "DirectionalLight3D", true, false):
					l.directional_shadow_max_distance = 60.0
			"novsync":
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
				Engine.max_fps = 0
			"taa":
				get_viewport().msaa_3d = Viewport.MSAA_DISABLED
				get_viewport().use_taa = true
			"smaa":
				get_viewport().msaa_3d = Viewport.MSAA_DISABLED
				get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
			"fxaa":
				get_viewport().msaa_3d = Viewport.MSAA_DISABLED
				get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			"metalfx":
				get_viewport().msaa_3d = Viewport.MSAA_DISABLED
				get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_TEMPORAL
				get_viewport().scaling_3d_scale = 0.67
			"trees":
				for n: Node in root.get_tree().get_nodes_in_group("resource_node"):
					if String(n.get("kind")).begins_with("tree"):
						(n as Node3D).visible = false


func _process(delta: float) -> void:
	_n += 1
	if _n == 5 and not bench_off.is_empty():
		_apply_bench()
	if _n > frames - 120:
		_fps_samples.append(1.0 / maxf(delta, 0.0001))
	var session := get_parent() as GameSession
	if session and _n == 20:
		match scenario:
			"inventory": session.open_inventory(0)
			"journal": session.open_inventory(1)
			"pause": session.open_pause()
			"buildmenu": session.open_build_menu()
	if _gore_pending and _n == 30:
		_gore_pending = false
		var gs := get_parent() as GameSession
		var axe := ItemDB.get_item(&"stone_axe")
		var a: HumanNPC = gs.world.camps.npcs["npc_hunters_0"]
		var b: HumanNPC = gs.world.camps.npcs["npc_hunters_1"]
		for id: String in gs.world.camps.npcs.keys():
			(gs.world.camps.npcs[id] as HumanNPC).set_physics_process(false)
		var pl := gs.player
		var fwd := -pl.global_transform.basis.z
		var right := pl.global_transform.basis.x
		for k in 2:
			var n: HumanNPC = [a, b][k]
			var pos := pl.global_position + fwd * 2.2 + right * (-0.7 if k == 0 else 0.7)
			n.global_position = gs.world.ground_point(pos.x, pos.z)
			n.rotation.y = pl.rotation.y + PI + (0.5 if k == 0 else -0.4)  # face the camera
			n._play("idle")
		await get_tree().process_frame
		await get_tree().process_frame
		var sk := a._skel
		var arm := sk.global_transform * sk.get_bone_global_pose(sk.find_bone("hand_r")).origin
		a.take_damage(40.0, null, arm, axe)
		a.take_damage(40.0, null, arm, axe)
		var sk2 := b._skel
		var head := sk2.global_transform * sk2.get_bone_global_pose(sk2.find_bone("head")).origin + Vector3.UP * 0.08
		b.take_damage(40.0, null, head, axe)
	if scenario == "chop" and _chop_tree and _chop_tree.stage == TreeNode.Stage.STANDING and _n > 30 and _n % 45 == 0:
		var pl := (get_parent() as GameSession).player
		pl.stats.stamina = 100.0
		pl.swing()
	if scenario == "chop" and _chop_tree and _chop_tree.stage == TreeNode.Stage.FALLING and _n % 20 == 0:
		# Look at the falling crown.
		var pl2 := (get_parent() as GameSession).player
		pl2.head.rotation.x = lerpf(pl2.head.rotation.x, 0.25, 0.4)
	if _n in shot_list and _n < frames:
		get_viewport().get_texture().get_image().save_png(out_path.get_basename() + "_%d.png" % _n)
	if _n >= frames:
		var img := get_viewport().get_texture().get_image()
		img.save_png(out_path)
		print("viewport px=", get_viewport().get_texture().get_size(), " window=", DisplayServer.window_get_size(), " scale=", DisplayServer.screen_get_scale())
		var avg := 0.0
		for f in _fps_samples:
			avg += f
		avg /= maxf(_fps_samples.size(), 1.0)
		print("AutoShot saved ", out_path, "  fps=", Engine.get_frames_per_second(), " avg_last120=", snappedf(avg, 0.1), " off=", bench_off, "  draw_calls=", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		get_tree().quit()


func _build_demo(session: GameSession) -> void:
	var w := session.world
	var p := session.player
	var origin := p.global_position + Vector3(7, 0, -1)
	var f: BuildingPiece = w.spawn_structure(&"piece",
		Transform3D(Basis(), Vector3(origin.x, w.height_at(origin.x, origin.z) - 0.05, origin.z)), {"piece": "foundation"})
	f.complete()
	var bc := p.build
	var plan := [[&"wall", "edge", 1], [&"wall", "edge", 2], [&"doorway", "edge", 3], [&"pillar", "corner", 0]]
	for e: Array in plan:
		bc.def = ItemDB.get_piece(e[0])
		var sock: Dictionary = bc.find_sockets(e[1], f.global_position)[e[2]]
		var piece: BuildingPiece = w.spawn_structure(&"piece", sock.xform, {"piece": String(e[0]), "on": sock.supports})
		piece.complete()
	bc.def = ItemDB.get_piece(&"door")
	var ds: Dictionary = bc.find_sockets("doorway", f.global_position)[0]
	var door: BuildingPiece = w.spawn_structure(&"piece", ds.xform, {"piece": "door", "on": ds.supports})
	door.complete()
	door.set_door_open(true)
	bc.def = ItemDB.get_piece(&"roof")
	var rs: Dictionary = bc.find_sockets("top", f.global_position)[0]
	var roof: BuildingPiece = w.spawn_structure(&"piece", rs.xform, {"piece": "roof", "on": rs.supports})
	roof.complete()
	var f2 := f.global_position + Vector3(0, 0, 2)
	var bp: BuildingPiece = w.spawn_structure(&"piece", Transform3D(Basis(), f2), {"piece": "foundation"})
	bp.delivered[&"wood"] = 1
	var lt_pos := p.global_position + Vector3(6, 0, -6)
	var lt: BuildingPiece = w.spawn_structure(&"piece", Transform3D(Basis(Vector3.UP, 0.6), w.ground_point(lt_pos.x, lt_pos.z)), {"piece": "lean_to"})
	lt.complete()
	var rk_pos := p.global_position + Vector3(4, 0, 3.5)
	var rack: BuildingPiece = w.spawn_structure(&"piece", Transform3D(Basis(Vector3.UP, -0.4), w.ground_point(rk_pos.x, rk_pos.z)), {"piece": "drying_rack"})
	rack.complete()
	rack.drying.append({"id": &"meat_raw", "t": 0.0})
	rack.drying.append({"id": &"meat_raw", "t": 900.0})
	p.look_at(f.global_position + Vector3(0, 1.2, 0))
	p.rotation.x = 0.0
	p.rotation.z = 0.0
	p.head.rotation.x = -0.05
	if scenario == "build":
		bc.begin(&"fence")
