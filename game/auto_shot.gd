class_name AutoShot
extends Node
## DEV TOOL: deterministic screenshots for verification.
## Usage: godot --path . -- --autoshot=/abs/out.png [--shot-frames=120] [--shot-hour=21.5] [--shot-scenario=inventory]
## Scenarios: none, inventory, journal, pause, camp (lit fire + bed in view), kit (starter items), prompt (aim at sticks),
## build (hut + lean-to + blueprint + active ghost), buildmenu (radial menu).

var out_path := ""
var frames := 120
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
	s.frames = int(args.get("shot-frames", "120"))
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
