class_name AutoShot
extends Node
## DEV TOOL: deterministic screenshots for verification.
## Usage: godot --path . -- --autoshot=/abs/out.png [--shot-frames=120] [--shot-hour=21.5] [--shot-scenario=inventory]
## Scenarios: none, inventory, journal, pause, camp (lit fire + bed in view), kit (starter items), prompt (aim at sticks).

var out_path := ""
var frames := 120
var hour := -1.0
var scenario := ""
var _n := 0


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
	if scenario == "kit":
		session.world.add_journal("JOURNAL_WATER")


func _process(_delta: float) -> void:
	_n += 1
	var session := get_parent() as GameSession
	if session and _n == 20:
		match scenario:
			"inventory": session.open_inventory(0)
			"journal": session.open_inventory(1)
			"pause": session.open_pause()
	if _n >= frames:
		var img := get_viewport().get_texture().get_image()
		img.save_png(out_path)
		print("AutoShot saved ", out_path, "  fps=", Engine.get_frames_per_second(), "  draw_calls=", RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
		get_tree().quit()
