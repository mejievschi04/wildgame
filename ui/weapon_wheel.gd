class_name WeaponWheel
extends Control
## Far Cry Primal style weapon wheel: hold the wheel key (Q / LB), time slows, flick the mouse or the right
## stick towards a weapon, release to take it in hand. The top-most sector is "bare hands" (put it away).

signal closed

const RADIUS := 190.0
const INNER := 78.0
const SLOW_TIME := 0.25
const PICK_DEADZONE := 26.0

var player: Player
var _ids: Array[StringName] = []  # sector i -> item id; &"" = bare hands
var _aim := Vector2.ZERO
var _sel := -1
var _icons: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS


func open() -> void:
	_ids = [&""]
	_ids.append_array(player.equippable_choices())
	_aim = Vector2.ZERO
	_sel = -1
	if player.inventory.hand:  # start on what you hold
		_sel = _ids.find(player.inventory.hand.id)
	visible = true
	Engine.time_scale = SLOW_TIME
	queue_redraw()


func close(pick: bool) -> void:
	if not visible:
		return
	visible = false
	Engine.time_scale = 1.0
	if pick and _sel >= 0 and _sel < _ids.size():
		player.equip_id(_ids[_sel])
	closed.emit()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseMotion:
		_aim += (event as InputEventMouseMotion).relative
		if _aim.length() > 120.0:
			_aim = _aim.normalized() * 120.0
		_pick()
		get_viewport().set_input_as_handled()
	elif event is InputEventJoypadMotion:
		var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
		if stick.length() > 0.5:
			_aim = stick * 120.0
			_pick()
	if event.is_action_released("weapon_wheel"):
		close(true)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("pause"):
		close(false)
		get_viewport().set_input_as_handled()


func _pick() -> void:
	if _aim.length() < PICK_DEADZONE or _ids.is_empty():
		return
	var n := _ids.size()
	var a := fposmod(_aim.angle() + PI * 0.5 + PI / n, TAU)  # sector 0 points up
	_sel = int(a / TAU * n) % n
	queue_redraw()


func _sector_dir(i: int) -> Vector2:
	var a := -PI * 0.5 + TAU * i / _ids.size()
	return Vector2(cos(a), sin(a))


func _draw() -> void:
	if _ids.is_empty():
		return
	var c := size * 0.5
	var n := _ids.size()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.02, 0.015, 0.45))
	# Sectors: dark hide wedges, the selected one lit ochre.
	for i in n:
		var a0 := -PI * 0.5 + TAU * (i - 0.5) / n + 0.02
		var a1 := -PI * 0.5 + TAU * (i + 0.5) / n - 0.02
		var pts := PackedVector2Array()
		for k in 17:
			var a := lerpf(a0, a1, k / 16.0)
			pts.append(c + Vector2(cos(a), sin(a)) * RADIUS)
		for k in 17:
			var a := lerpf(a1, a0, k / 16.0)
			pts.append(c + Vector2(cos(a), sin(a)) * INNER)
		var sel := i == _sel
		draw_colored_polygon(pts, Color(UITheme.OCHRE, 0.55) if sel else Color(UITheme.CHARCOAL, 0.78))
		draw_polyline(pts + PackedVector2Array([pts[0]]), Color(UITheme.BONE, 0.35 if sel else 0.12), 1.5, true)
		var at := c + _sector_dir(i) * (INNER + RADIUS) * 0.5
		var id := _ids[i]
		if id == &"":
			_draw_hand(at, sel)
		else:
			var tex := AssetLib.item_icon(id)
			var s := 64.0 if sel else 54.0
			if tex:
				draw_texture_rect(tex, Rect2(at - Vector2(s, s) * 0.5, Vector2(s, s)), false, Color(1, 1, 1, 1.0 if sel else 0.8))
			var cnt := player.inventory.count_of(id)
			if cnt > 1:
				draw_string(get_theme_default_font(), at + Vector2(14, 28), "×%d" % cnt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, UITheme.BONE)
	# Centre: name, wear, ammo of the highlighted weapon.
	draw_circle(c, INNER - 6, Color(UITheme.CHARCOAL, 0.9))
	var name := Loc.t("WHEEL_HANDS")
	var sub := ""
	if _sel >= 0 and _sel < n and _ids[_sel] != &"":
		var d := ItemDB.get_item(_ids[_sel])
		name = d.display_name()
		if _ids[_sel] == &"bow":
			sub = Loc.t("WHEEL_ARROWS", {"n": player.inventory.count_of(&"arrow")})
		elif d.has_durability():
			var best := 0
			for st: ItemStack in player.inventory.slots + [player.inventory.hand]:
				if st != null and st.id == d.id:
					best = maxi(best, st.durability)
			sub = "%d%%" % roundi(100.0 * best / d.max_durability)
	var font := get_theme_default_font()
	var w := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
	draw_string(font, c + Vector2(-w * 0.5, sub.is_empty() and 6.0 or -2.0), name, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, UITheme.BONE)
	if not sub.is_empty():
		var w2 := font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_string(font, c + Vector2(-w2 * 0.5, 20), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(UITheme.BONE, 0.7))
	# Pointer towards the stick / mouse flick.
	if _aim.length() > PICK_DEADZONE:
		var d := _aim.normalized()
		draw_colored_polygon(PackedVector2Array([c + d * (INNER - 2), c + d * (INNER - 16) + d.orthogonal() * 7.0,
			c + d * (INNER - 16) - d.orthogonal() * 7.0]), UITheme.OCHRE)


## Bare hands: an open palm.
func _draw_hand(at: Vector2, sel: bool) -> void:
	var col := Color(UITheme.BONE, 1.0 if sel else 0.75)
	draw_circle(at + Vector2(0, 6), 13.0, col)
	for k in 4:
		var x := -10.0 + k * 6.7
		draw_line(at + Vector2(x, 0), at + Vector2(x * 1.1, -16 + absf(x) * 0.3), col, 5.0, true)
	draw_line(at + Vector2(-12, 8), at + Vector2(-21, -2), col, 5.0, true)
