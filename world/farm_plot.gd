class_name FarmPlot
extends RefCounted
## Crops on a garden bed (a BuildingPiece with piece_id "garden_bed"), data/crops.json:
##   plant seeds -> the crop grows through sprout / young / flowering / ripe -> harvest (crop + seeds back).
## Growth needs wet soil: rain or a waterskin keeps the bed wet for a day; dry soil grows at DRY_GROWTH speed.
## A sickle in the inventory gives a bigger harvest. Growth runs on simulated time (sleep, time skips).

const CROPS_PATH := "res://data/crops.json"
const WET_FOR := 1440.0  # simulated seconds one watering (or a shower) keeps the soil wet
const DRY_GROWTH := 0.35
const SICKLE_BONUS := 1.5
## Plants on the bed: two ridges of three (bed-local x, z); the soil surface is at SOIL_Y.
const SPOTS: Array[Vector2] = [Vector2(-0.6, -0.3), Vector2(0.0, -0.3), Vector2(0.6, -0.3),
	Vector2(-0.6, 0.3), Vector2(0.0, 0.3), Vector2(0.6, 0.3)]
const SOIL_Y := 0.27

static var _crops: Dictionary = {}

var piece: BuildingPiece
var crop: StringName = &""
var progress := 0.0  # 0..1, ripe at 1
var moisture := 0.0  # wet seconds left
var _root: Node3D
var _shown := -2


static func crops() -> Dictionary:
	if _crops.is_empty():
		var f := FileAccess.open(CROPS_PATH, FileAccess.READ)
		var d: Variant = JSON.parse_string(f.get_as_text()) if f else {}
		for k: String in (d as Dictionary).keys():
			_crops[StringName(k)] = d[k]
	return _crops


static func crop_for_seed(seed: StringName) -> StringName:
	for c: StringName in crops():
		if StringName(str(crops()[c].seed)) == seed:
			return c
	return &""


func _init(p_piece: BuildingPiece) -> void:
	piece = p_piece


## 0 sprout, 1 young, 2 flowering, 3 ripe; -1 = nothing planted.
func stage() -> int:
	if crop == &"":
		return -1
	if progress >= 1.0:
		return 3
	return mini(int(progress * 3.0), 2)


func is_ripe() -> bool:
	return stage() == 3


func is_wet() -> bool:
	return moisture > 0.0


func grow(seconds: float, raining: bool) -> void:
	if raining:
		moisture = WET_FOR
	if crop == &"" or progress >= 1.0:
		moisture = maxf(moisture - seconds, 0.0)
		return
	var wet_part := minf(seconds, moisture)
	moisture -= wet_part
	var grow_time := float(crops()[crop].grow)
	progress = minf(progress + (wet_part + (seconds - wet_part) * DRY_GROWTH) / grow_time, 1.0)
	if stage() != _shown:
		refresh()


## The one thing to do with the bed right now (harvest > plant > water), or {} when it just needs time.
func option(inv: Inventory) -> Dictionary:
	if crop == &"":
		var seed := _seed_in(inv)
		if seed == &"":
			return {"action": &"interact", "text": Loc.t("NEED_SEEDS"), "hold": 0.0, "enabled": false, "op": &"plant"}
		return {"action": &"interact", "text": Loc.t("ACT_PLANT", {"item": ItemDB.get_item(seed).display_name()}),
			"hold": 1.2, "enabled": true, "op": &"plant"}
	if is_ripe():
		return {"action": &"interact", "text": Loc.t("ACT_HARVEST"), "hold": 1.0, "enabled": true, "op": &"harvest"}
	if not is_wet():
		var can := inv.count_of(&"waterskin_raw") + inv.count_of(&"waterskin_boiled") > 0
		return {"action": &"interact", "text": Loc.t("ACT_WATER") if can else Loc.t("NEED_WATER"), "hold": 0.8,
			"enabled": can, "op": &"water"}
	return {}


func _seed_in(inv: Inventory) -> StringName:
	for c: StringName in crops():
		var seed := StringName(str(crops()[c].seed))
		if inv.count_of(seed) > 0:
			return seed
	return &""


func perform(op: StringName, player: Node) -> void:
	var inv: Inventory = player.inventory
	match op:
		&"plant":
			var seed := _seed_in(inv)
			if seed != &"" and inv.remove_item(seed, 1):
				crop = crop_for_seed(seed)
				progress = 0.0
				Sfx.play(&"rustle", piece.global_position, -4.0)
				refresh()
		&"water":
			for id: StringName in [&"waterskin_raw", &"waterskin_boiled"]:
				var i := inv.first_slot_of(id)
				if i >= 0:
					inv.slots[i] = ItemStack.new(&"waterskin_empty", 1)
					inv.changed.emit()
					moisture = WET_FOR
					Sfx.play(&"step_water", piece.global_position, -2.0)
					refresh()
					return
		&"harvest":
			if not is_ripe():
				return
			var def: Dictionary = crops()[crop]
			var mult := SICKLE_BONUS if inv.has_tag(&"tool_sickle") else 1.0
			for id: String in (def.yield as Dictionary).keys():
				player.give_item(StringName(id), int(round(int(def.yield[id]) * mult)))
			if int(def.get("seeds", 0)) > 0:
				player.give_item(StringName(str(def.seed)), int(def.seeds))
			Sfx.play(&"rustle", piece.global_position, -2.0)
			crop = &""
			progress = 0.0
			refresh()


func status_text() -> String:
	if crop == &"":
		return Loc.t("STATUS_BED_EMPTY")
	var name := ItemDB.get_item(StringName(str((crops()[crop].yield as Dictionary).keys()[0]))).display_name()
	if is_ripe():
		return Loc.t("STATUS_CROP_RIPE", {"crop": name})
	return Loc.t("STATUS_CROP", {"crop": name, "p": roundi(progress * 100.0),
		"soil": Loc.t("STATUS_SOIL_WET" if is_wet() else "STATUS_SOIL_DRY")})


func save_state() -> Dictionary:
	return {"crop": String(crop), "p": progress, "wet": moisture}


func load_state(d: Dictionary) -> void:
	crop = StringName(str(d.get("crop", "")))
	if crop != &"" and not crops().has(crop):
		crop = &""
	progress = float(d.get("p", 0.0))
	moisture = float(d.get("wet", 0.0))
	refresh()


# ---------------------------------------------------------------- visuals

## (Re)attaches the crop visual to the bed's current visual.
func attach(visual: Node3D) -> void:
	_root = Node3D.new()
	_root.name = "CropRoot"
	visual.add_child(_root)
	_shown = -2
	refresh()


func refresh() -> void:
	if _root == null or not is_instance_valid(_root):
		return
	var st := stage()
	_shown = st
	for c in _root.get_children():
		c.queue_free()
	if st < 0:
		return
	var m := BuildingVisuals.Acc.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(piece.structure_id) ^ hash(String(crop))
	var g := smoothstep(0.0, 1.0, minf(progress, 1.0)) * 0.85 + 0.15  # overall size
	for s: Vector2 in SPOTS:
		var at := Vector3(s.x + rng.randf_range(-0.06, 0.06), SOIL_Y, s.y + rng.randf_range(-0.04, 0.04))
		match crop:
			&"grain": _grain(m, at, g, st, rng)
			&"carrot": _carrot(m, at, g, st, rng)
			&"flax": _flax(m, at, g, st, rng)
			_: _herb(m, at, g, st, rng)
	m.commit(_root)
	for mi: MeshInstance3D in _root.find_children("*", "MeshInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _mat(c: Color) -> Material:
	return Graybox.mat(c, 0.85)


static func _leaf_green(st: int) -> Color:
	return Color(0.32, 0.5, 0.18) if st < 3 else Color(0.62, 0.55, 0.26)


func _grain(m: BuildingVisuals.Acc, at: Vector3, g: float, st: int, rng: RandomNumberGenerator) -> void:
	var stalk := _mat(_leaf_green(st))
	var head := _mat(Color(0.82, 0.68, 0.32) if st == 3 else Color(0.5, 0.6, 0.25))
	for i in 7:
		var a := rng.randf() * TAU
		var lean := Vector3(cos(a), 0, sin(a)) * rng.randf_range(0.03, 0.09) * g
		var h := rng.randf_range(0.75, 1.0) * g * 0.95
		var top := at + lean + Vector3(0, h, 0)
		m.pole(0, stalk, at + lean * 0.2, top, 0.008, 0.006, 4, false)
		if st >= 2:
			var droop := lean.normalized() * 0.03 if st == 3 else Vector3.ZERO
			m.pole(0, head, top - Vector3(0, 0.02, 0), top + Vector3(0, 0.09, 0) + droop, 0.016, 0.008, 5)


func _carrot(m: BuildingVisuals.Acc, at: Vector3, g: float, st: int, rng: RandomNumberGenerator) -> void:
	var leaf := _mat(Color(0.28, 0.52, 0.2) if st < 3 else Color(0.4, 0.5, 0.2))
	for i in 8:
		var a := TAU * i / 8.0 + rng.randf_range(-0.2, 0.2)
		var tip := at + Vector3(cos(a) * 0.12 * g, rng.randf_range(0.22, 0.34) * g, sin(a) * 0.12 * g)
		m.pole(0, leaf, at, tip, 0.012, 0.004, 4, false)
		m.box(0, leaf, Transform3D(Basis.looking_at((tip - at).normalized(), Vector3.UP), at.lerp(tip, 0.7)), Vector3(0.05, 0.004, 0.08) * g)
	if st == 3:
		m.pole(0, _mat(Color(0.85, 0.45, 0.12)), at - Vector3(0, 0.03, 0), at + Vector3(0, 0.035, 0), 0.03, 0.028, 7)


func _flax(m: BuildingVisuals.Acc, at: Vector3, g: float, st: int, rng: RandomNumberGenerator) -> void:
	var stalk := _mat(Color(0.36, 0.5, 0.24) if st < 3 else Color(0.6, 0.5, 0.3))
	var flower := _mat(Color(0.42, 0.55, 0.85) if st == 2 else Color(0.55, 0.45, 0.28))
	for i in 9:
		var off := Vector3(rng.randf_range(-0.09, 0.09), 0, rng.randf_range(-0.07, 0.07))
		var top := at + off + Vector3(rng.randf_range(-0.03, 0.03), rng.randf_range(0.65, 0.8) * g, rng.randf_range(-0.03, 0.03))
		m.pole(0, stalk, at + off, top, 0.006, 0.005, 4, false)
		if st >= 2:
			m.box(0, flower, Transform3D(Basis.from_euler(Vector3(0, rng.randf() * TAU, 0)), top), Vector3(0.035, 0.01, 0.035))


func _herb(m: BuildingVisuals.Acc, at: Vector3, g: float, st: int, rng: RandomNumberGenerator) -> void:
	var stalk := _mat(Color(0.3, 0.46, 0.22))
	var bloom := _mat(Color(0.92, 0.9, 0.82))
	for i in 5:
		var off := Vector3(rng.randf_range(-0.07, 0.07), 0, rng.randf_range(-0.07, 0.07))
		var top := at + off + Vector3(0, rng.randf_range(0.35, 0.5) * g, 0)
		m.pole(0, stalk, at + off * 0.3, top, 0.01, 0.007, 4, false)
		for k in 3:  # feathery leaves up the stem
			var y := at.lerp(top, 0.25 + k * 0.2)
			m.box(0, stalk, Transform3D(Basis.from_euler(Vector3(0.3, rng.randf() * TAU, 0)), y), Vector3(0.09, 0.005, 0.02) * g)
		if st >= 2:
			m.box(0, bloom, Transform3D(Basis(), top + Vector3(0, 0.01, 0)), Vector3(0.09, 0.025, 0.09))
