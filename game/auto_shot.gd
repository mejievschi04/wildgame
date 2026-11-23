class_name AutoShot
extends Node
## DEV TOOL: deterministic screenshots for verification.
## Usage: godot --path . -- --autoshot=/abs/out.png [--shot-frames=120] [--shot-hour=21.5] [--shot-scenario=inventory]
## Scenarios: none, inventory, journal, pause, camp (lit fire + bed in view), kit (starter items), prompt (aim at sticks),
## tribe (Neanderthal clan + two sapiens in a row), tribelife (a camp at work / asleep; SHOT_CAMP=hunters|clan|gatherers),
## build (hut + lean-to + blueprint + active ghost), buildmenu (radial menu), fauna (all species, live), spear / club / bow (weapon in hand; bow mid-draw), river (main river valley from the bank), house (3/4 view of the build demo), farm (garden beds + wild plants).

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


## Screenshot tuning from environment variables named SHOT_<KEY> (e.g. SHOT_DIST, SHOT_ANIM).
static func _env(key: String) -> String:
	return OS.get_environment("SHOT" + "_" + key.to_upper())


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
	if scenario in ["build", "buildmenu", "house"]:
		_build_demo(session)
	if scenario == "house":  # three-quarter view of the demo house: thatch, window wall, gable, log walls
		var hc := p.global_position + Vector3(7, 0, -1)
		var eye := hc + Vector3(-5.2, 0, 2.2)
		p.global_position = session.world.ground_point(eye.x, eye.z) + Vector3.UP * 0.3
		p.look_at(Vector3(hc.x, p.global_position.y, hc.z))
		p.rotation = Vector3(0, p.rotation.y, 0)
		p.head.rotation.x = 0.05
	if scenario == "basefire":  # two of your own fires away from you: on-screen markers + smoke plume
		session.world.wildlife.enabled = false
		session.world.weather.set_state(&"clear", true)
		var fw := -p.global_transform.basis.z
		for e: Array in [[fw.rotated(Vector3.UP, 0.35), 70.0], [-fw, 45.0], [fw.rotated(Vector3.UP, -0.3), 25.0]]:
			var at: Vector3 = p.global_position + (e[0] as Vector3) * float(e[1])
			var fire: Campfire = session.world.spawn_structure(&"campfire", Transform3D(Basis(), session.world.ground_point(at.x, at.z)))
			fire.add_fuel(600)
			fire.ignite()
		p.head.rotation.x = 0.08
	if scenario == "moon":  # look up at the moon (use with --shot-hour at night)
		session.world.wildlife.enabled = false
		session.world.weather.set_state(&"clear", true)
		var md: Vector3 = session.world.day_night.moon_direction()
		p.look_at(p.global_position + Vector3(md.x, 0, md.z))
		p.rotation = Vector3(0, p.rotation.y, 0)
		p.head.rotation.x = asin(clampf(md.y, -1.0, 1.0)) * 0.85
	if scenario == "farm":  # four garden beds at different stages, wild plants beside them
		session.world.wildlife.enabled = false
		var w := session.world
		var fwd := -p.global_transform.basis.z
		var side := fwd.cross(Vector3.UP).normalized()
		var plan := [[&"grain", 1.0, -1.2], [&"carrot", 0.8, 1.2], [&"flax", 0.55, -1.2], [&"herb", 0.3, 1.2]]
		for i in plan.size():
			var e: Array = plan[i]
			var at: Vector3 = p.global_position + fwd * (4.0 + (i / 2) * 1.8) + side * float(e[2])
			var bed: BuildingPiece = w.spawn_structure(&"piece", Transform3D(Basis.looking_at(-fwd), w.ground_point(at.x, at.z)),
				{"piece": "garden_bed", "built": true, "farm": {"crop": String(e[0]), "p": e[1], "wet": 600.0}})
			bed.farm.refresh()
		var k := 0
		for kind: StringName in [&"wild_grain", &"flax", &"wild_carrot", &"herbs", &"reeds", &"hazel", &"clay"]:
			var at: Vector3 = p.global_position + fwd * 9.0 + side * (k - 3.0) * 1.7
			w._spawn_node(kind, at.x, at.z)
			k += 1
		p.head.rotation.x = -0.3
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
		var row := [[&"roe", -3.2, 5.5], [&"wolf", -1.2, 6.0], [&"deer", 1.2, 7.5], [&"bear", 4.0, 8.0], [&"rhino", -5.5, 12.0], [&"bison", 6.5, 11.0], [&"horse", -2.5, 10.0], [&"megaloceros", -8.0, 14.0], [&"lion", 2.6, 6.5], [&"boar", -0.5, 4.5], [&"reindeer", 5.5, 6.0], [&"fox", 1.0, 3.5], [&"hare", -1.6, 3.2], [&"mammoth", 1.0, 15.0]]
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
	if _env("at") != "":  # SHOT_AT=x,z[,yaw_deg]: stand anywhere on the map (streams the region in)
		var a := _env("at").split(",")
		var pos := session.world.ground_point(float(a[0]), float(a[1])) + Vector3.UP * 0.3
		p.global_position = pos
		p.rotation.y = deg_to_rad(float(a[2])) if a.size() > 2 else 0.0
		p.head.rotation.x = float(_env("pitch")) if _env("pitch") != "" else -0.05
	if scenario == "tribe":  # the Neanderthal clan in a row with two Homo sapiens gatherers, held in their idle pose
		session.world.wildlife.enabled = false
		session.world.factions.change(&"clan", 100.0)
		var cam := p.get_viewport().get_camera_3d()
		var fwd := -cam.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := fwd.cross(Vector3.UP)
		var ids := ["npc_clan_0", "npc_clan_2", "npc_clan_1", "npc_gatherers_0", "npc_gatherers_1", "npc_clan_3"]
		if _env("ids") != "":  # e.g. SHOT_IDS=npc_clan_0,npc_gatherers_1 for close portraits
			ids.assign(_env("ids").split(",", false))
		for i in ids.size():
			var n: HumanNPC = session.world.camps.npcs[ids[i]]
			var dist := float(_env("dist")) if _env("dist") != "" else 3.4
			var mid := (ids.size() - 1) * 0.5
			var pos: Vector3 = p.global_position + fwd * (dist + absf(i - mid) * 0.25) + right * (i - mid) * 0.9
			n.global_position = session.world.ground_point(pos.x, pos.z)
			n.rotation.y = atan2(-fwd.x, -fwd.z) + deg_to_rad(float(_env("turn")) if _env("turn") != "" else 0.0)
			n.set_physics_process(false)
			var clip := _env("anim")  # e.g. life/sleep, life/work, combat/throw
			n._play(clip if clip != "" and n._anim.has_animation(clip) else "idle")
			if _env("anim_t") != "" and n._anim.has_animation(clip):
				n._anim.speed_scale = 0.0
				n._anim.seek(float(_env("anim_t")), true)
		p.head.rotation.x = float(_env("pitch")) if _env("pitch") != "" else -0.12
	if scenario == "tribelife":  # a camp seen from outside: at work by day, asleep around the fire at night
		session.world.wildlife.enabled = false
		var g: TribeGroup = session.world.camps.groups["camp_" + str(_env("camp") if _env("camp") != "" else "hunters")]
		var at := g.home + Vector3(1.5, 0.0, -9.5)  # the side without shelters
		p.global_position = session.world.ground_point(at.x, at.z) + Vector3.UP * 0.3
		p.look_at(Vector3(g.home.x, p.global_position.y, g.home.z))
		p.rotation.x = 0
		p.head.rotation.x = -0.3
		for f: StringName in session.world.factions.defs:
			session.world.factions.change(f, 60.0)
	if scenario == "carcass":
		var cpos: Vector3 = session.world.get_node("POI_Carcass").global_position
		p.global_position = cpos + Vector3(3.0, 0.5, 2.0)
		p.look_at(Vector3(cpos.x, p.global_position.y, cpos.z))
		p.rotation.x = 0
		p.head.rotation.x = -0.35
	if scenario == "notch":  # a tree chopped 4 times, seen from beside the chopper: notch + chips on the ground
		session.world.wildlife.enabled = false
		var tn: TreeNode = null
		for n in session.get_tree().get_nodes_in_group("resource_node"):
			# An alder (crown high up) keeps the view clear of low spruce branches.
			if n is TreeNode and n.species == &"alder" and n.global_position.distance_to(p.global_position) > 6.0 \
					and (tn == null or n.global_position.distance_to(p.global_position) < tn.global_position.distance_to(p.global_position)):
				tn = n
		var chopper := tn.global_position + Vector3(1.4, 0.3, 0)
		p.global_position = chopper
		p.inventory.add_item(&"stone_axe")
		for i in 4:
			tn.on_hit(p, ItemDB.get_item(&"stone_axe"))
		var notch := tn.to_global(Vector3(tn._trunk_c.x, tn.cut_h, tn._trunk_c.y))
		p.global_position = tn.global_position + Vector3(1.5, 0.0, 0.55)
		p.global_position.y = session.world.height_at(p.global_position.x, p.global_position.z) + 0.2
		p.look_at(Vector3(notch.x, p.global_position.y, notch.z))
		p.rotation = Vector3(0, p.rotation.y, 0)
		p.head.rotation.x = -0.62
	if scenario in ["wheel", "pouch"]:  # weapon wheel held / the pouch open, with a varied kit
		session.world.wildlife.enabled = false
		for id: StringName in [&"stone_axe", &"spear", &"bow", &"club", &"flint_knife", &"torch", &"sickle"]:
			p.inventory.add_item(id)
		for e: Array in [[&"arrow", 12], [&"meat_cooked", 3], [&"berries", 9], [&"bandage", 2], [&"wood", 6], [&"stick", 14],
				[&"fiber", 20], [&"flint", 4], [&"stone", 7], [&"campfire_kit", 1], [&"herb", 5], [&"waterskin_boiled", 1]]:
			p.inventory.add_item(e[0], e[1])
		p.equip_id(&"stone_axe")
		if scenario == "wheel":
			session.weapon_wheel.open.call_deferred()
			(func() -> void:
				session.weapon_wheel._aim = Vector2(70, -40)
				session.weapon_wheel._pick()).call_deferred()
		else:
			session.open_inventory.call_deferred(0)
	if scenario == "map":  # the world map open, after a bit of exploring, with a fire and a waypoint
		session.world.wildlife.enabled = false
		var w := session.world
		for q: Vector2 in [Vector2(0, 0), Vector2(120, 60), Vector2(250, 150), Vector2(300, 300), Vector2(-150, -120), Vector2(92, 62)]:
			for k in 6:
				MapData.reveal(w.map_fog, q.x + k * 25.0, q.y + k * 18.0, MapData.REVEAL_RADIUS)
		var fp := p.global_position + Vector3(6, 0, 3)
		var fire: Campfire = w.spawn_structure(&"campfire", Transform3D(Basis(), w.ground_point(fp.x, fp.z)))
		fire.add_fuel(300)
		fire.ignite()
		w.waypoint = w.ground_point(260.0, 170.0)
		session.open_map.call_deferred()
	if scenario == "felled":  # a felled alder: cut stump + the butt of the trunk lying beside it
		session.world.wildlife.enabled = false
		var ft: TreeNode = null
		for n in session.get_tree().get_nodes_in_group("resource_node"):
			if n is TreeNode and n.species == &"alder" and n.global_position.distance_to(p.global_position) > 6.0 \
					and (ft == null or n.global_position.distance_to(p.global_position) < ft.global_position.distance_to(p.global_position)):
				ft = n
		p.global_position = ft.global_position + Vector3(1.4, 0.3, 0)
		for i in ft.fell_hits:
			ft.on_hit(p, ItemDB.get_item(&"stone_axe"))
		ft.complete_fall()
		for i in 2:  # buck two logs off the top end
			ft.on_hit(p, ItemDB.get_item(&"stone_axe"))
		var stump := ft.to_global(Vector3(ft._trunk_c.x, ft.cut_h, ft._trunk_c.y))
		p.global_position = ft.global_position + Vector3(1.0, 0.0, 4.5)
		p.global_position.y = session.world.height_at(p.global_position.x, p.global_position.z) + 0.2
		p.look_at(Vector3(stump.x - 4.0, p.global_position.y, stump.z))
		p.rotation = Vector3(0, p.rotation.y, 0)
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
	if scenario == "river":  # upstream along the main river from its west bank (valley shape, shoreline)
		session.world.wildlife.enabled = false
		var w := session.world
		var z := -400.0
		var at := Vector2(w.river_x(z) - 38.0, z)
		p.global_position = w.ground_point(at.x, at.y) + Vector3.UP * 0.3
		var ahead := Vector2(w.river_x(z - 140.0) - 6.0, z - 140.0)
		p.look_at(Vector3(ahead.x, p.global_position.y, ahead.y))
		p.rotation = Vector3(0, p.rotation.y, 0)
		p.head.rotation.x = -0.12
	if scenario in ["spear", "club", "bow"]:
		session.world.wildlife.enabled = false
		var weapon := StringName(scenario)
		p.inventory.add_item(weapon)
		p.inventory.equip_slot(p.inventory.first_slot_of(weapon))
		if weapon == &"bow":
			p.inventory.add_item(&"arrow", 10)
			p._begin_draw.call_deferred()  # caught mid-draw, arrow nocked


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
			"meadow":
				for v in root.find_children("MeadowGrass", "", true, false):
					v.visible = false
			"fx":
				for v in root.find_children("AtmosphereFX", "", true, false):
					v.visible = false
			"far":
				for v in root.find_children("FarForest", "", true, false):
					v.visible = false
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
		Transform3D(Basis(), Vector3(origin.x, w.height_at(origin.x, origin.z) - 0.05, origin.z)), {"piece": "foundation", "tier": 1, "built": true})
	var bc := p.build
	# [piece, socket mode, socket index, material tier]: a log house with a wattle window wall and a stone corner.
	var plan := [[&"window_wall", "edge", 1, 0], [&"wall", "edge", 2, 1], [&"doorway", "edge", 3, 1], [&"pillar", "corner", 0, 1],
		[&"half_wall", "edge", 0, 2]]
	for e: Array in plan:
		bc.def = ItemDB.get_piece(e[0])
		var sock: Dictionary = bc.find_sockets(e[1], f.global_position)[e[2]]
		w.spawn_structure(&"piece", sock.xform, {"piece": String(e[0]), "on": sock.supports, "tier": e[3], "built": true})
	bc.def = ItemDB.get_piece(&"door")
	var ds: Dictionary = bc.find_sockets("doorway", f.global_position)[0]
	var door: BuildingPiece = w.spawn_structure(&"piece", ds.xform, {"piece": "door", "on": ds.supports})
	door.complete()
	door.set_door_open(true)
	bc.def = ItemDB.get_piece(&"roof")
	var rs: Dictionary = bc.find_sockets("top", f.global_position)[0]
	var roof: BuildingPiece = w.spawn_structure(&"piece", rs.xform, {"piece": "roof", "on": rs.supports})
	roof.complete()
	bc.def = ItemDB.get_piece(&"gable")
	for gs: Dictionary in bc.find_sockets("gable", roof.global_position):
		w.spawn_structure(&"piece", gs.xform, {"piece": "gable", "on": gs.supports, "built": true})
	# A second cell under construction: deck half delivered (posts + beams standing, planks still a plan).
	var f2 := f.global_position + Vector3(0, 0, 2)
	w.spawn_structure(&"piece", Transform3D(Basis(), f2), {"piece": "foundation", "delivered": {"wood": 3, "stick": 1}})
	for i in 3:
		var pz := p.global_position + Vector3(9.5, 0, 3.0 + i * 2.0)
		w.spawn_structure(&"piece", Transform3D(Basis(Vector3.UP, PI * 0.5), w.ground_point(pz.x, pz.z)), {"piece": "palisade", "built": true})
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
