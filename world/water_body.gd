class_name WaterBody
extends Area3D
## River segment whose top face is the water surface. Ray-only (layer 4 = "water").

const RAW_SIP_SICKNESS := 0.04

var level := 0.0


func setup(size: float, water_level: float, length: float = -1.0) -> void:
	level = water_level
	collision_layer = 8
	collision_mask = 0
	monitoring = false
	monitorable = false
	add_to_group("interactable")
	var segment_length := size if length < 0.0 else length
	Graybox.add_shape(self, Graybox.box_shape(Vector3(size, 4.0, segment_length)), Vector3(0, water_level - 2.0, 0))


func setup_ellipse(radius_x: float, radius_z: float, water_level: float) -> void:
	level = water_level
	collision_layer = 8
	collision_mask = 0
	monitoring = false
	monitorable = false
	add_to_group("interactable")
	var points := PackedVector3Array()
	const SEGMENTS := 32
	for y: float in [0.0, -4.0]:
		for i in SEGMENTS:
			var a := TAU * float(i) / SEGMENTS
			points.append(Vector3(cos(a) * radius_x, y, sin(a) * radius_z))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	Graybox.add_shape(self, shape, Vector3(0.0, water_level, 0.0))


func get_display_name() -> String:
	return Loc.t("NODE_WATER")


func get_interactions(player: Node) -> Array:
	var opts := [{"action": &"interact", "text": Loc.t("ACT_DRINK"), "hold": 0.8,
		"enabled": player.stats.thirst < SurvivalStats.MAX - 1.0}]
	if player.inventory.count_of(&"waterskin_empty") > 0:
		opts.append({"action": &"alt_interact", "text": Loc.t("ACT_FILL_WATERSKIN"), "hold": 0.8, "enabled": true})
	return opts


func perform_interaction(player: Node, action: StringName) -> void:
	match action:
		&"interact":
			player.stats.thirst = minf(player.stats.thirst + 15.0, SurvivalStats.MAX)
			Sfx.play(&"drink", null, -4.0)
			if randf() < RAW_SIP_SICKNESS:
				player.stats.add_condition(&"food_poisoning", 90.0)
				Events.toast(Loc.t("MSG_FEEL_SICK"), &"danger")
			player.world.add_journal("JOURNAL_WATER")
		&"alt_interact":
			var inv: Inventory = player.inventory
			var i := inv.first_slot_of(&"waterskin_empty")
			if i >= 0:
				inv.slots[i] = ItemStack.new(&"waterskin_raw", 1)
				Sfx.play(&"step_water", player.global_position)
				inv.changed.emit()
				Events.toast(Loc.t("MSG_WATERSKIN_FILLED"), &"good")
