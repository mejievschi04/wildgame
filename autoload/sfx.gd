extends Node
## Sound service: imported assets with procedural fallbacks + pooled 2D/3D players on the SFX bus.
## Important sounds emit a caption for the subtitles accessibility option (GDD §12).

signal caption(text: String)

const NAMES := [
	&"step_grass", &"step_wood", &"step_water", &"rustle", &"chop", &"stone_knock", &"whoosh", &"pop",
	&"craft", &"place", &"build", &"dismantle", &"collapse", &"door", &"eat", &"drink", &"fire_ignite",
	&"tool_break", &"hurt", &"ui_click", &"axe_chop", &"axe_glance", &"fire_loop", &"wind_loop", &"birds_loop", &"crickets_loop", &"rain_loop",
]
const FILES := {
	&"step_grass": [
		"res://assets/audio/SFX_Step_Grass_000.wav",
		"res://assets/audio/SFX_Step_Grass_001.wav",
		"res://assets/audio/SFX_Step_Grass_002.wav",
		"res://assets/audio/SFX_Step_Grass_003.wav",
		"res://assets/audio/SFX_Step_Grass_004.wav",
	],
	&"step_wood": [
		"res://assets/audio/SFX_Step_Wood_000.wav",
		"res://assets/audio/SFX_Step_Wood_001.wav",
		"res://assets/audio/SFX_Step_Wood_002.wav",
		"res://assets/audio/SFX_Step_Wood_003.wav",
		"res://assets/audio/SFX_Step_Wood_004.wav",
	],
	&"axe_chop": ["res://assets/audio/SFX_Axe_Chop_09.wav"],
	&"axe_glance": ["res://assets/audio/SFX_Axe_Chop_05.wav"],
	&"fire_loop": ["res://assets/audio/AMB_Campfire_Crackle.wav"],
}
const CAPTIONS := {
	&"fire_ignite": "CAPTION_FIRE", &"tool_break": "CAPTION_TOOL_BREAK",
	&"collapse": "CAPTION_COLLAPSE", &"hurt": "CAPTION_HURT", &"door": "CAPTION_DOOR",
}
const POOL_3D := 16
const POOL_2D := 6

var streams: Dictionary = {}
var _variants: Dictionary = {}
var _last_variant: Dictionary = {}
var _pool3d: Array[AudioStreamPlayer3D] = []
var _pool2d: Array[AudioStreamPlayer] = []
var _next3d := 0
var _next2d := 0


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	for n: StringName in NAMES:
		var loaded: Array[AudioStream] = []
		for path: String in FILES.get(n, []):
			var custom_stream := load(path) as AudioStream
			if custom_stream:
				loaded.append(custom_stream)
		if not loaded.is_empty():
			streams[n] = loaded[0]
			_variants[n] = loaded
		else:
			streams[n] = SoundSynth.to_stream(SoundSynth.build(n), String(n).ends_with("_loop"))
	if streams[&"fire_loop"] is AudioStreamWAV:
		var fire := streams[&"fire_loop"] as AudioStreamWAV
		fire.loop_mode = AudioStreamWAV.LOOP_FORWARD
		fire.loop_begin = 0
		fire.loop_end = fire.data.size() / 2
	print_verbose("Sfx: prepared %d sounds in %d ms" % [streams.size(), Time.get_ticks_msec() - t0])
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
	var choices: Array = _variants.get(name, [])
	if choices.size() > 1:
		var variant := randi_range(0, choices.size() - 1)
		if variant == int(_last_variant.get(name, -1)):
			variant = (variant + 1) % choices.size()
		_last_variant[name] = variant
		s = choices[variant]
	if name == &"step_grass":
		volume_db += 8.0
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
