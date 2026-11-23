class_name LoadingScreen
extends CanvasLayer
## Shown by Game while a session loads: a still from the game, the logo, and a hide band at the bottom with the
## stage, a progress bar and survival tips. Lives on the root so it survives the scene change.

signal opened

const BACKDROPS := [
	"res://assets/ui/BG_Load_Camp.jpg",
	"res://assets/ui/BG_Load_Mist.jpg",
	"res://assets/ui/BG_Load_Meadow.jpg",
	"res://assets/ui/BG_Menu_Herd.jpg",
]
const TIP_COUNT := 8
const TIP_SECONDS := 6.0

var _root: Control
var _stage: Label
var _percent: Label
var _bar: _Bar
var _tip: Label
var _dots: HBoxContainer
var _target := 0.0
var _shown := 0.0
var _tips: Array[int] = []
var _tip_i := 0
var _tip_t := 0.0


func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	add_child(_root)
	var bg := PrimalBackdrop.new()
	bg.texture = load(BACKDROPS[randi() % BACKDROPS.size()])
	bg.left_shade = 0.55
	bg.bottom_shade = 0.9
	bg.embers = 24
	_root.add_child(bg)
	var logo := PrimalLogo.new()
	logo.scale_factor = 0.95
	logo.show_tagline = false
	logo.position = Vector2(72, 56)
	_root.add_child(logo)
	_build_band()
	for i in TIP_COUNT:
		_tips.append(i + 1)
	_tips.shuffle()
	_show_tip(0)
	_root.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 1.0, 0.3).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(opened.emit)


func _build_band() -> void:
	var band := PanelContainer.new()
	band.add_theme_stylebox_override("panel", UITheme.hide_box(64.0))
	band.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	band.anchor_left = 0.1
	band.anchor_right = 0.9
	band.offset_left = 0
	band.offset_right = 0
	band.offset_top = -250
	band.offset_bottom = -28
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(band)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	band.add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	_stage = UITheme.caption(Loc.t("LOAD_STAGE_SCENE"), 26, UITheme.BONE_HI, 500, 1)
	_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_stage)
	_percent = UITheme.caption("0%", 26, UITheme.GOLD_HI, 500, 1)
	top.add_child(_percent)
	_bar = _Bar.new()
	_bar.custom_minimum_size.y = 26
	v.add_child(_bar)
	var tip := HBoxContainer.new()
	tip.add_theme_constant_override("separation", 14)
	v.add_child(tip)
	var ic := TextureRect.new()
	ic.texture = UITheme.icon("tip", UITheme.GOLD, 26)
	ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	tip.add_child(ic)
	_tip = UITheme.label("", "")
	_tip.add_theme_font_size_override("font_size", 19)
	_tip.add_theme_color_override("font_color", Color(UITheme.BONE, 0.92))
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tip.add_child(_tip)
	_dots = HBoxContainer.new()
	_dots.alignment = BoxContainer.ALIGNMENT_CENTER
	_dots.add_theme_constant_override("separation", 12)
	v.add_child(_dots)
	for i in 3:
		var d := _Dot.new()
		d.custom_minimum_size = Vector2(10, 10)
		_dots.add_child(d)


## Sets the stage text and where the bar is heading (0..1). The bar eases there.
func set_stage(key: String, progress: float) -> void:
	_stage.text = Loc.t(key)
	_target = maxf(_target, clampf(progress, 0.0, 1.0))


## True once the drawn bar has caught up with the target (so a stage is seen before a long blocking step).
func caught_up() -> bool:
	return _shown >= _target - 0.01


func finish() -> void:
	_target = 1.0
	var tw := create_tween()
	tw.tween_interval(0.25)
	tw.tween_property(_root, "modulate:a", 0.0, 0.45).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(queue_free)


func _process(delta: float) -> void:
	_shown = move_toward(_shown, _target, delta * 1.6)
	_bar.value = _shown
	_percent.text = "%d%%" % roundi(_shown * 100.0)
	_tip_t += delta
	if _tip_t > TIP_SECONDS:
		_tip_t = 0.0
		_show_tip((_tip_i + 1) % _tips.size())


func _show_tip(i: int) -> void:
	_tip_i = i
	_tip.text = Loc.t("LOAD_TIP") + ":  " + Loc.t("LOAD_TIP_%d" % _tips[i])
	for j in _dots.get_child_count():
		(_dots.get_child(j) as _Dot).on = j == i % _dots.get_child_count()
		_dots.get_child(j).queue_redraw()


class _Bar:
	extends Control

	var value := 0.0:
		set(v):
			value = v
			queue_redraw()
	var _t := 0.0

	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_style_box(UITheme.cell_box(Color(0.8, 0.8, 0.8, 1.0)), r)
		var inner := r.grow(-5.0)
		var w := inner.size.x * clampf(value, 0.0, 1.0)
		if w < 1.0:
			return
		var fill := Rect2(inner.position, Vector2(w, inner.size.y))
		draw_rect(fill, Color("#B87422"))
		draw_rect(Rect2(fill.position, Vector2(w, fill.size.y * 0.5)), Color(UITheme.GOLD_HI, 0.55))
		draw_texture_rect(UITheme.tex("Grain"), fill, true, Color(1, 0.9, 0.7, 0.18))
		var glow := 0.6 + 0.4 * sin(_t * 4.0)
		var tip := Vector2(fill.end.x, fill.get_center().y)
		draw_circle(tip, inner.size.y * 0.9, Color(1.0, 0.75, 0.35, 0.18 * glow))
		draw_rect(Rect2(fill.end.x - 3.0, fill.position.y, 3.0, fill.size.y), Color(1.0, 0.92, 0.7, 0.85))


class _Dot:
	extends Control

	var on := false

	func _draw() -> void:
		var c := size * 0.5
		draw_circle(c, 4.0 if on else 3.2, UITheme.GOLD_HI if on else Color(UITheme.BONE, 0.4))
