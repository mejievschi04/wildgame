class_name PrimalBackdrop
extends Control
## Full-screen still from the game (assets/ui/BG_*.jpg) brought to life: a slow push-in, drifting embers, film grain,
## and dark washes on the left / bottom so text stays readable. Shared by the main menu and the loading screen.

@export var texture: Texture2D
## Darkness of the wash from the left edge (0 = none) and from the bottom.
@export var left_shade := 0.85
@export var bottom_shade := 0.6
@export var embers := 36
## Seconds for one push-in / pull-back cycle.
@export var drift_period := 48.0

var _t := 0.0
var _left: GradientTexture2D
var _bottom: GradientTexture2D
var _vignette: GradientTexture2D
var _sparks: _Embers


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_left = _ramp(Vector2(0, 0.5), Vector2(0.62, 0.5), left_shade)
	_bottom = _ramp(Vector2(0.5, 1.0), Vector2(0.5, 0.45), bottom_shade)
	_vignette = GradientTexture2D.new()
	_vignette.fill = GradientTexture2D.FILL_RADIAL
	_vignette.fill_from = Vector2(0.5, 0.45)
	_vignette.fill_to = Vector2(1.15, 1.1)
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0))
	g.set_color(1, Color(0.02, 0.012, 0.006, 0.7))
	g.add_point(0.55, Color(0, 0, 0, 0.05))
	_vignette.gradient = g
	if embers > 0:
		_sparks = _Embers.new()
		_sparks.count = embers
		_sparks.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		_sparks.material = m
		add_child(_sparks)


func _ramp(from: Vector2, to: Vector2, strength: float) -> GradientTexture2D:
	var t := GradientTexture2D.new()
	t.fill_from = from
	t.fill_to = to
	var g := Gradient.new()
	g.set_color(0, Color(0.035, 0.024, 0.016, strength))
	g.set_color(1, Color(0.035, 0.024, 0.016, 0.0))
	t.gradient = g
	return t


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0c0907"))
	if texture:
		var ts := texture.get_size()
		var k := 0.5 - 0.5 * cos(_t * TAU / drift_period)
		var zoom := 1.02 + 0.06 * k
		var s := maxf(size.x / ts.x, size.y / ts.y) * zoom
		var d := ts * s
		var pan := Vector2(-0.35, -0.2) * (d - size) * k
		draw_texture_rect(texture, Rect2((size - d) * 0.5 + pan * 0.5, d), false)
	if left_shade > 0.0:
		draw_texture_rect(_left, Rect2(Vector2.ZERO, size), false)
	if bottom_shade > 0.0:
		draw_texture_rect(_bottom, Rect2(Vector2.ZERO, size), false)
	draw_texture_rect(_vignette, Rect2(Vector2.ZERO, size), false)
	draw_texture_rect(UITheme.tex("Grain"), Rect2(Vector2.ZERO, size), true, Color(1, 1, 1, 0.022))


## Sparks rising from somewhere below the frame, flickering out as they climb.
class _Embers:
	extends Control

	var count := 36
	var _p: Array[Dictionary] = []

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_IGNORE

	func _spawn(anywhere: bool) -> Dictionary:
		var w := maxf(size.x, 1.0)
		var h := maxf(size.y, 1.0)
		return {
			"pos": Vector2(randf_range(0.0, w * 0.55), h * randf_range(0.2, 1.0) if anywhere else h + 8.0),
			"vel": Vector2(randf_range(4.0, 22.0), -randf_range(18.0, 46.0)),
			"life": randf_range(5.0, 11.0), "age": randf_range(0.0, 4.0) if anywhere else 0.0,
			"r": randf_range(1.0, 2.4), "ph": randf() * TAU,
		}

	func _process(delta: float) -> void:
		if size.x < 2.0:
			return
		while _p.size() < count:
			_p.append(_spawn(_p.size() < count / 2))
		for i in _p.size():
			var e: Dictionary = _p[i]
			e.age += delta
			e.ph += delta * 3.0
			e.pos += (e.vel + Vector2(sin(e.ph * 0.7) * 10.0, 0.0)) * delta
			if e.age > e.life or e.pos.y < -10.0:
				_p[i] = _spawn(false)
		queue_redraw()

	func _draw() -> void:
		for e: Dictionary in _p:
			var k: float = clampf(e.age / 1.2, 0.0, 1.0) * clampf((e.life - e.age) / 2.0, 0.0, 1.0)
			var fl := 0.6 + 0.4 * sin(e.ph * 2.3)
			var c := Color(1.0, 0.55, 0.18, 0.55 * k * fl)
			draw_circle(e.pos, e.r * 2.6, Color(c, c.a * 0.25))
			draw_circle(e.pos, e.r, c)
