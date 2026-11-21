extends Node
## Sound service: procedurally generated streams (SoundSynth) + pooled 2D/3D players on the SFX bus.
## Important sounds emit a caption for the subtitles accessibility option (GDD §12).

signal caption(text: String)

const NAMES := [
	&"step_grass", &"step_wood", &"step_water", &"rustle", &"chop", &"stone_knock", &"whoosh", &"pop",
	&"craft", &"place", &"build", &"dismantle", &"collapse", &"door", &"eat", &"drink", &"fire_ignite",
	&"tool_break", &"hurt", &"ui_click", &"fire_loop", &"wind_loop", &"birds_loop", &"crickets_loop",
]
const CAPTIONS := {
	&"fire_ignite": "CAPTION_FIRE", &"tool_break": "CAPTION_TOOL_BREAK",
	&"collapse": "CAPTION_COLLAPSE", &"hurt": "CAPTION_HURT", &"door": "CAPTION_DOOR",
}
const POOL_3D := 16
const POOL_2D := 6

var streams: Dictionary = {}
var _pool3d: Array[AudioStreamPlayer3D] = []
var _pool2d: Array[AudioStreamPlayer] = []
var _next3d := 0
var _next2d := 0


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	for n: StringName in NAMES:
		streams[n] = SoundSynth.to_stream(SoundSynth.build(n), String(n).ends_with("_loop"))
	print_verbose("Sfx: generated %d sounds in %d ms" % [streams.size(), Time.get_ticks_msec() - t0])
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = &"SFX"
		p.unit_size = 6.0
		p.max_distance = 45.0
		p.attenuation_filter_cutoff_hz = 9000.0
		add_child(p)
		_pool3d.append(p)
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		p.bus = &"SFX"
		p.process_mode = Node.PROCESS_MODE_ALWAYS  # UI clicks while paused
		add_child(p)
		_pool2d.append(p)


func stream(name: StringName) -> AudioStream:
	return streams.get(name)


## Plays a one-shot. pos = null → 2D (UI / first-person); otherwise positional.
func play(name: StringName, pos: Variant = null, volume_db: float = 0.0, pitch_var: float = 0.08) -> void:
	var s: AudioStream = streams.get(name)
	if s == null:
		return
	var pitch := 1.0 + randf_range(-pitch_var, pitch_var)
	if pos is Vector3:
		var p := _pool3d[_next3d]
		_next3d = (_next3d + 1) % POOL_3D
		p.stream = s
		p.global_position = pos
		p.volume_db = volume_db
		p.pitch_scale = pitch
		p.play()
	else:
		var p := _pool2d[_next2d]
		_next2d = (_next2d + 1) % POOL_2D
		p.stream = s
		p.volume_db = volume_db
		p.pitch_scale = pitch
		p.play()
	if CAPTIONS.has(name) and bool(Settings.get_value("accessibility", "subtitles")):
		caption.emit(Loc.t(CAPTIONS[name]))


func ui_click() -> void:
	play(&"ui_click", null, -6.0, 0.03)


## A positional looping player owned by the caller (e.g. campfire crackle).
func make_loop_3d(name: StringName, volume_db: float = 0.0) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = streams.get(name)
	p.bus = &"SFX"
	p.volume_db = volume_db
	p.unit_size = 4.0
	p.max_distance = 30.0
	return p
