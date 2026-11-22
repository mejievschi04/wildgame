class_name MapScreen
extends Control
## Full-screen world map (Far Cry Primal style): the painted hide with fog of war, the player, your fires,
## the clans' camps once found, region names, and a waypoint you set with a click (shown in the HUD too).
## Mouse wheel zooms about the cursor, drag pans, left click sets / clears the waypoint, F centres on you.

signal closed

const MIN_ZOOM := 1.0
const MAX_ZOOM := 7.0
## Unexplored land: a faded, smoky hide you can just make out the relief through (not a black void).
const FOG_COLOR := Color(0.36, 0.29, 0.22, 0.86)

var player: Player
var _view: Control  # the map canvas (clips, draws everything)
var _map_tex: Texture2D
var _fog_tex: ImageTexture
var _zoom := 3.2
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
	top.add_child(UITheme.label(Loc.t("MAP_TITLE"), "HeadingLabel"))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	var hint := UITheme.label(Loc.t("MAP_HINT", {"key": InputSetup.label(&"map")}), "MutedLabel")
	top.add_child(hint)
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
	_center = _clamp_center(MapData.to_uv(player.global_position.x, player.global_position.z))
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
	_draw_grid(tl, span)
	_draw_regions()
	_draw_camps()
	_draw_regional_bases()
	_draw_fires()
	_draw_waypoint()
	_draw_player()
	_draw_compass()
	_draw_scale()
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


## Faint graticule every 500 m, like a surveyed hide.
func _draw_grid(tl: Vector2, span: Vector2) -> void:
	var col := Color(0.2, 0.14, 0.08, 0.18)
	var e := MapData.extent()
	var step := 500.0
	var k := -e
	while k <= e + 1.0:
		var t := (k + e) / (2.0 * e)
		_view.draw_line(Vector2(tl.x + t * span.x, tl.y), Vector2(tl.x + t * span.x, tl.y + span.y), col, 1.0)
		_view.draw_line(Vector2(tl.x, tl.y + t * span.y), Vector2(tl.x + span.x, tl.y + t * span.y), col, 1.0)
		k += step


func _draw_regions() -> void:
	var font := get_theme_default_font()  # the display font lacks some Cyrillic capitals
	var w := player.world
	for r: StringName in ForestWorld.REGIONS:
		var c: Vector2 = ForestWorld.REGIONS[r]
		if r == &"aruun":
			c += Vector2(0, -260)  # keep the label off the start valley's markers
		var known := MapData.explored(w.map_fog, c.x, c.y) or r == &"aruun"
		var p := _world_to_screen(c.x, c.y)
		var name := Loc.t("REGION_%s" % String(r).to_upper())
		var fs := int(clampf(15.0 + _zoom * 4.0, 16.0, 34.0))
		var sz := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var base: Dictionary = Camps.REGIONAL_BASES.get(String(r), {})
		if not base.is_empty():
			var site := Camps.site(base)
			var marker := _world_to_screen(site.x, site.y)
			if absf(p.x - marker.x) < sz.x * 0.5 + 14.0 and absf(p.y - marker.y) < 42.0:
				p.y = marker.y - fs - 10.0
		var col := Color(0.2, 0.12, 0.07, 0.78) if known else Color(0.72, 0.64, 0.52, 0.45)
		_view.draw_string(font, p - Vector2(sz.x * 0.5, -fs * 0.35), name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw_camps() -> void:
	var w := player.world
	if w.factions == null:
		return
	var font := get_theme_default_font()
	for f: StringName in w.factions.defs.keys():
		var c := Camps.site(w.factions.def_of(f))
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


func _draw_regional_bases() -> void:
	var font := get_theme_default_font()
	var risk_colors := [Color("526e3e"), Color("83743e"), Color("976334"),
		Color("8e442e"), Color("752b25")]
	for id: String in Camps.REGIONAL_BASES:
		var def: Dictionary = Camps.REGIONAL_BASES[id]
		var level := int(def.level)
		var site := Camps.site(def)
		var p := _world_to_screen(site.x, site.y)
		var corners := PackedVector2Array([p + Vector2(-11, -9), p + Vector2(11, -9),
			p + Vector2(11, 4), p + Vector2(0, 12), p + Vector2(-11, 4)])
		_view.draw_colored_polygon(corners, risk_colors[level - 1])
		corners.append(corners[0])
		_view.draw_polyline(corners, Color(0.95, 0.82, 0.6), 1.6, true)
		var rank := str(level)
		var rank_width := font.get_string_size(rank, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		_view.draw_string(font, p + Vector2(-rank_width * 0.5, 4), rank,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
		var label := Loc.t("MAP_REGIONAL_BASE", {"name": Loc.t("REGION_" + id.to_upper())})
		var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
		_view.draw_string(font, p + Vector2(-width * 0.5, 29), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.14, 0.09, 0.06))


func _draw_fires() -> void:
	for f: Campfire in get_tree().get_nodes_in_group("campfire"):
		if f.eternal:
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
	var n := Loc.t("MAP_NORTH")
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
