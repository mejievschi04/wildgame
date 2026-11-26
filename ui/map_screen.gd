class_name MapScreen
extends Control
## Full-screen world map (Far Cry Primal style): the painted hide with fog of war, the player, your fires,
## the clans' camps once found, region names, and a waypoint you set with a click (shown in the HUD too).
## Mouse wheel zooms about the cursor, drag pans, left click sets / clears the waypoint, F centres on you.

signal closed

const MIN_ZOOM := 1.0
const MAX_ZOOM := 7.0
## Unexplored land: a faded, smoky hide you can just make out the relief through (not a black void).
const FOG_COLOR := Color(0.10, 0.12, 0.16, 0.34)

var player: Player
var _view: Control  # the map canvas (clips, draws everything)
var _map_tex: Texture2D
var _fog_tex: ImageTexture
var _zoom := 1.30
var _center := Vector2(0.5, 0.5)  # map uv at the middle of the view
var _drag := false
var _dragged := 0.0
var _teleport_click := false
var _hover_uv := Vector2(-1, -1)
var _info: Label
var _loading: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	visible = false
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.07, 0.05)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	_view = Control.new()
	_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_view.clip_contents = true
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.draw.connect(_draw_map)
	_view.gui_input.connect(_on_input)
	add_child(_view)
	var top := HBoxContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 40
	top.offset_right = -40
	top.offset_top = 24
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(top)
	top.add_child(UITheme.label("WILDBOUND   /   HARTA LUMII", "HeadingLabel"))
	var hint := UITheme.label("Derulează pentru zoom · Trage pentru deplasare · Clic pentru reper · F revine la poziția ta", "SmallLabel")
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_top = -46
	hint.offset_bottom = -18
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_theme_color_override("font_outline_color", Color(0.04, 0.04, 0.03))
	hint.add_theme_constant_override("outline_size", 7)
	add_child(hint)
	_info = UITheme.label("", "SmallLabel")
	_info.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_info.offset_left = -520
	_info.offset_right = -40
	_info.offset_top = -60
	_info.offset_bottom = -30
	_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_info)
	_loading = UITheme.label(Loc.t("MAP_LOADING"), "HeadingLabel")
	_loading.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_loading.visible = false
	add_child(_loading)


func open() -> void:
	if _map_tex == null:
		_loading.visible = true
		UITheme.show_animated(self, true)
		await get_tree().process_frame
		var img := player.world.get_map_image()
		if img:
			_map_tex = ImageTexture.create_from_image(img)
		_loading.visible = false
	_fog_tex = ImageTexture.create_from_image(MapData.fog_image(player.world.map_fog))
	_center = _clamp_center(_center)
	UITheme.show_animated(self, true)
	_view.queue_redraw()


func close() -> void:
	UITheme.show_animated(self, false)
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("map") or event.is_action_pressed("pause") or event.is_action_pressed("inventory"):
		close()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and (event as InputEventKey).physical_keycode == KEY_F:
		_center = _clamp_center(MapData.to_uv(player.global_position.x, player.global_position.z))
		_view.queue_redraw()


func _process(_delta: float) -> void:
	if visible:
		_view.queue_redraw()  # the player arrow and fires are live


# ---------------------------------------------------------------- view maths

## Size in pixels of the whole map at the current zoom (zoom 1 = fits the screen height).
func _map_px() -> float:
	return _view.size.y * _zoom


func _uv_to_screen(uv: Vector2) -> Vector2:
	return _view.size * 0.5 + (uv - _center) * _map_px()


func _screen_to_uv(p: Vector2) -> Vector2:
	return _center + (p - _view.size * 0.5) / _map_px()


func _world_to_screen(x: float, z: float) -> Vector2:
	return _uv_to_screen(MapData.to_uv(x, z))


func _clamp_center(c: Vector2) -> Vector2:
	var half := _view.size * 0.5 / _map_px()
	var lo := Vector2(minf(half.x, 0.5), minf(half.y, 0.5))
	return Vector2(clampf(c.x, lo.x, 1.0 - lo.x), clampf(c.y, lo.y, 1.0 - lo.y))


func _on_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var before := _screen_to_uv(mb.position)
			_zoom = clampf(_zoom * (1.15 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15), MIN_ZOOM, MAX_ZOOM)
			_center += before - _screen_to_uv(mb.position)  # zoom about the cursor
			_center = _clamp_center(_center)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag = true
				_dragged = 0.0
				_teleport_click = mb.shift_pressed
			elif _drag:
				_drag = false
				if _dragged < 6.0:
					var uv := _screen_to_uv(mb.position)
					if _teleport_click:
						_teleport_on_map(uv)
					else:
						_toggle_waypoint(uv)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			player.world.waypoint = Vector3.INF
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_hover_uv = _screen_to_uv(mm.position)
		if _drag:
			_dragged += mm.relative.length()
			_center = _clamp_center(_center - mm.relative / _map_px())
	_view.queue_redraw()


func _toggle_waypoint(uv: Vector2) -> void:
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return
	var w := player.world
	if w.waypoint != Vector3.INF and _uv_to_screen(MapData.to_uv(w.waypoint.x, w.waypoint.z)).distance_to(_uv_to_screen(uv)) < 18.0:
		w.waypoint = Vector3.INF
		return
	var p := MapData.from_uv(uv)
	w.waypoint = w.ground_point(p.x, p.y)
	Sfx.play(&"ui_click")


## Temporary map shortcut for testing distant sites.
func _teleport_on_map(uv: Vector2) -> void:
	if not uv.is_finite() or uv != uv.clamp(Vector2.ZERO, Vector2.ONE) or player.dead:
		return
	var world := player.world
	var point := MapData.from_uv(uv)
	var vegetation := world.get_node_or_null("Vegetation") as Vegetation
	if vegetation:
		vegetation._stream_near(point)
	var candidates := [point]
	for radius in [2.0, 5.0, 10.0]:
		for i in 8:
			candidates.append(point + Vector2.RIGHT.rotated(i * TAU / 8.0) * radius)
	for candidate: Vector2 in candidates:
		if maxf(absf(candidate.x), absf(candidate.y)) > ForestWorld.PLAYABLE:
			continue
		var destination := world.ground_point(candidate.x, candidate.y)
		destination.y = maxf(destination.y, ForestWorld.WATER_LEVEL) + 0.25
		var pose := Transform3D(player.global_basis, destination)
		if player.test_move(pose, Vector3.ZERO, null, 0.001, true):
			continue
		player.teleport_to(destination)
		MapData.reveal(world.map_fog, candidate.x, candidate.y, MapData.REVEAL_RADIUS)
		Sfx.play(&"ui_click")
		close()
		return
	Events.toast(Loc.t("MAP_TELEPORT_BLOCKED"), &"warn")


# ---------------------------------------------------------------- drawing

func _draw_map() -> void:
	var v := _view
	var tl := _uv_to_screen(Vector2.ZERO)
	var span := Vector2.ONE * _map_px()
	if _map_tex:
		v.draw_texture_rect(_map_tex, Rect2(tl, span), false)
	else:
		v.draw_rect(Rect2(tl, span), Color(0.7, 0.6, 0.45))
	if _fog_tex:
		v.draw_texture_rect(_fog_tex, Rect2(tl, span), false, FOG_COLOR)
	if _zoom > 2.7:
		_draw_camps()
	_draw_key_places()
	_draw_fires()
	_draw_waypoint()
	_draw_player()
	_draw_compass()
	_draw_scale()
	_draw_legend()
	var w := player.world
	var hint := ""
	if _hover_uv.x >= 0.0 and _hover_uv.x <= 1.0 and _hover_uv.y >= 0.0 and _hover_uv.y <= 1.0:
		var hp := MapData.from_uv(_hover_uv)
		if MapData.explored(w.map_fog, hp.x, hp.y):
			hint = Loc.t("REGION_%s" % String(w.region_at(hp.x, hp.y)).to_upper())
		else:
			hint = Loc.t("MAP_UNEXPLORED")
	if w.waypoint != Vector3.INF:
		hint += ("  ·  " if hint != "" else "") + Loc.t("MAP_WAYPOINT_DIST", {"n": roundi(w.waypoint.distance_to(player.global_position))})
	_info.text = hint


func _draw_camps() -> void:
	var w := player.world
	if w.factions == null:
		return
	var font := get_theme_default_font()
	for f: StringName in w.factions.defs.keys():
		var def := w.factions.def_of(f)
		if not def.has("camp"):
			continue
		var c := Camps.site(def)
		if not MapData.explored(w.map_fog, c.x, c.y):
			continue
		var p := _world_to_screen(c.x, c.y)
		var stance: StringName = w.factions.stance(f)
		var col: Color = {&"hostile": Color(0.62, 0.12, 0.08), &"wary": Color(0.7, 0.45, 0.12),
			&"neutral": Color(0.35, 0.3, 0.22), &"friendly": Color(0.25, 0.42, 0.2)}.get(stance, Color(0.3, 0.25, 0.2))
		# a hut glyph: ring + roof
		_view.draw_circle(p, 13.0, Color(0.92, 0.85, 0.7, 0.9))
		_view.draw_arc(p, 13.0, 0, TAU, 24, col, 2.5, true)
		_view.draw_colored_polygon(PackedVector2Array([p + Vector2(-8, 4), p + Vector2(8, 4), p + Vector2(0, -7)]), col)
		var key := "JOURNAL_%s_TITLE" % String(f).to_upper()
		var label := Loc.t(key) if Loc.has_key(key) else String(f)
		var sz := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15)
		_view.draw_string(font, p + Vector2(-sz.x * 0.5, 30), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.15, 0.1, 0.06))


func _draw_key_places() -> void:
	var camp := ForestWorld.SPAWN
	_place_label(_world_to_screen(camp.x, camp.y), "Tabăra ta", Color("b88c2d"), "camp")
	var entries := {
		"kharum": ["Tribul Stâncii", Color("813f31")],
		"north": ["Tribul Nordului", Color("224a73")],
		"varkai": ["Tribul Roșu", Color("a34323")],
		"aruun": ["Ruinele orașului Arun", Color("90765b")],
	}
	for id: String in entries:
		var site := Camps.site(Camps.REGIONAL_BASES[id])
		_place_label(_world_to_screen(site.x, site.y), entries[id][0], entries[id][1], id)


func _place_label(p: Vector2, label: String, color: Color, kind: String) -> void:
	var font := UITheme.display_font(600, 1)
	var size := 21
	var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 30.0
	var banner := p - Vector2(0, 23)
	_draw_marker(banner, color, kind)
	var rect := Rect2(p + Vector2(-width * 0.5, 1.0), Vector2(width, 31))
	_view.draw_rect(rect, Color(0.045, 0.039, 0.030, 0.87))
	_view.draw_string(font, p + Vector2(-width * 0.5 + 15, 23), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, UITheme.BONE_HI)


func _draw_marker(p: Vector2, color: Color, kind: String) -> void:
	var ink := Color("ebd4ad")
	if kind == "aruun":
		_view.draw_colored_polygon(PackedVector2Array([p + Vector2(-17, -9), p + Vector2(-9, -15),
			p + Vector2(8, -14), p + Vector2(17, -5), p + Vector2(14, 7), p + Vector2(-16, 7)]),
			color.darkened(0.45))
		for x in [-10.0, -3.0, 5.0, 11.0]:
			_view.draw_line(p + Vector2(x, 6), p + Vector2(x + 1.0, -6 - absf(x) * 0.23), ink, 3.0, true)
		_view.draw_line(p + Vector2(-16, 8), p + Vector2(16, 8), ink, 2.0, true)
		return
	var cloth := PackedVector2Array([p + Vector2(-17, -21), p + Vector2(17, -21), p + Vector2(15, 16),
		p + Vector2(5, 11), p + Vector2(-3, 17), p + Vector2(-9, 12), p + Vector2(-15, 15)])
	_view.draw_colored_polygon(cloth, color)
	cloth.append(cloth[0])
	_view.draw_polyline(cloth, color.darkened(0.5), 1.5, true)
	_view.draw_line(p + Vector2(-20, -21), p + Vector2(20, -21), ink.darkened(0.32), 2.5, true)
	match kind:
		"camp":
			var tipi := PackedVector2Array([p + Vector2(-8, 6), p + Vector2(0, -13), p + Vector2(8, 6)])
			_view.draw_polyline(tipi, ink, 2.5, true)
			_view.draw_line(p + Vector2(-11, 6), p + Vector2(11, 6), ink, 2.0, true)
		"north":
			_view.draw_line(p + Vector2(0, 8), p + Vector2(0, -4), ink, 3.0, true)
			for x: float in [-1.0, 1.0]:
				_view.draw_polyline(PackedVector2Array([p + Vector2(0, -3), p + Vector2(x * 9, -7),
					p + Vector2(x * 10, -15)]), ink, 2.2, true)
				_view.draw_line(p + Vector2(x * 8, -7), p + Vector2(x * 4, -15), ink, 1.8, true)
		"kharum":
			_view.draw_colored_polygon(PackedVector2Array([p + Vector2(-11, 6), p + Vector2(-2, -11),
				p + Vector2(3, -4), p + Vector2(6, -9), p + Vector2(12, 6)]), ink)
		_:
			_view.draw_colored_polygon(PackedVector2Array([p + Vector2(-10, -11), p + Vector2(-7, 1),
				p + Vector2(0, 8), p + Vector2(7, 1), p + Vector2(10, -11), p + Vector2(0, -6)]), ink)


func _draw_legend() -> void:
	if _zoom > 2.7 or _view.size.x < 840:
		return
	var origin := Vector2(30, 114)
	_view.draw_rect(Rect2(origin, Vector2(185, 139)), Color(0.045, 0.039, 0.030, 0.88))
	var font := get_theme_default_font()
	_view.draw_string(font, origin + Vector2(16, 27), "Legendă", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, UITheme.BONE_HI)
	var labels := ["Tabăra ta", "Trib rival", "Ruine"]
	var colors := [Color("c99b3f"), Color("ac563d"), Color("c8aa8b")]
	for i in labels.size():
		var y := 52.0 + i * 29.0
		_view.draw_circle(origin + Vector2(22, y - 5), 5.0, colors[i])
		_view.draw_string(font, origin + Vector2(39, y), labels[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, UITheme.BONE)


func _draw_fires() -> void:
	for f: Campfire in get_tree().get_nodes_in_group("campfire"):
		if f.eternal or f.structure_id == "player_camp_fire":
			continue
		var p := _world_to_screen(f.global_position.x, f.global_position.z)
		var col := Color(0.95, 0.5, 0.12) if f.is_lit() else Color(0.35, 0.3, 0.26)
		_view.draw_circle(p, 11.0, Color(0.15, 0.1, 0.06, 0.85))
		var pts := PackedVector2Array()
		for i in 13:
			var a := TAU * i / 12.0
			var q := Vector2(sin(a) * 6.0, cos(a) * 6.0)
			if q.y < 0.0:
				q = Vector2(q.x * (1.0 + q.y / 6.0 * 0.7), q.y * 1.9)
			pts.append(p + q + Vector2(0, 2))
		_view.draw_colored_polygon(pts, col)


func _draw_waypoint() -> void:
	var w := player.world
	if w.waypoint == Vector3.INF:
		return
	var p := _world_to_screen(w.waypoint.x, w.waypoint.z)
	var col := Color(0.62, 0.1, 0.08)
	_view.draw_line(p + Vector2(-9, -9), p + Vector2(9, 9), col, 4.0, true)
	_view.draw_line(p + Vector2(-9, 9), p + Vector2(9, -9), col, 4.0, true)
	_view.draw_arc(p, 15.0, 0, TAU, 28, Color(col, 0.6), 2.0, true)


## The player: an arrow pointing where you look.
func _draw_player() -> void:
	var p := _world_to_screen(player.global_position.x, player.global_position.z)
	var fwd3 := -player.global_transform.basis.z
	var dir := Vector2(fwd3.x, fwd3.z).normalized()
	var side := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([p + dir * 14.0, p - dir * 8.0 + side * 9.0, p - dir * 3.0, p - dir * 8.0 - side * 9.0])
	_view.draw_circle(p, 16.0, Color(0.1, 0.07, 0.04, 0.35))
	_view.draw_colored_polygon(pts, Color(0.98, 0.94, 0.82))
	_view.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0.15, 0.08, 0.04), 2.0, true)


func _draw_compass() -> void:
	var c := Vector2(_view.size.x - 80, 120)
	var ink := Color(0.88, 0.8, 0.62, 0.85)
	_view.draw_arc(c, 34.0, 0, TAU, 40, ink, 2.0, true)
	_view.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -30), c + Vector2(7, 0), c + Vector2(-7, 0)]), Color(0.75, 0.2, 0.12))
	_view.draw_colored_polygon(PackedVector2Array([c + Vector2(0, 30), c + Vector2(7, 0), c + Vector2(-7, 0)]), ink)
	var font := get_theme_default_font()
	var n := "N"
	var sz := font.get_string_size(n, HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
	_view.draw_string(font, c + Vector2(-sz.x * 0.5, -40), n, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, ink)


func _draw_scale() -> void:
	var metres := 500.0 if _zoom < 3.0 else 100.0
	var px := metres / (2.0 * MapData.extent()) * _map_px()
	var o := Vector2(40, _view.size.y - 50)
	var ink := Color(0.88, 0.8, 0.62, 0.9)
	_view.draw_line(o, o + Vector2(px, 0), ink, 3.0)
	for x in [0.0, px]:
		_view.draw_line(o + Vector2(x, -6), o + Vector2(x, 6), ink, 2.0)
	_view.draw_string(get_theme_default_font(), o + Vector2(0, -12), Loc.t("HUD_DISTANCE", {"n": int(metres)}),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 15, ink)
