extends Node
## Sound service: imported assets with procedural fallbacks + pooled 2D/3D players on the SFX bus.
## Important sounds emit a caption for the subtitles accessibility option (GDD §12).

signal caption(text: String)

const NAMES := [
	&"step_grass", &"step_wood", &"step_water", &"step_snow", &"rustle", &"chop", &"stone_knock", &"whoosh", &"pop",
	&"craft", &"place", &"build", &"dismantle", &"collapse", &"door", &"eat", &"drink", &"fire_ignite",
	&"tree_creak", &"tool_break", &"hurt", &"ui_click", &"axe_chop", &"axe_glance", &"fire_loop", &"wind_loop", &"birds_loop", &"crickets_loop", &"rain_loop",
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
	&"step_water": [
		"res://assets/audio/SFX_Step_Water_001.wav",
		"res://assets/audio/SFX_Step_Water_002.wav",
		"res://assets/audio/SFX_Step_Water_003.wav",
	],
	&"step_snow": [
		"res://assets/audio/SFX_Step_Snow_000.wav",
		"res://assets/audio/SFX_Step_Snow_001.wav",
		"res://assets/audio/SFX_Step_Snow_002.wav",
		"res://assets/audio/SFX_Step_Snow_003.wav",
		"res://assets/audio/SFX_Step_Snow_004.wav",
	],
	&"rustle": [
		"res://assets/audio/SFX_Rustle_001.wav",
		"res://assets/audio/SFX_Rustle_002.wav",
		"res://assets/audio/SFX_Rustle_003.wav",
		"res://assets/audio/SFX_Rustle_004.wav",
	],
	&"chop": [
		"res://assets/audio/SFX_Chop_001.wav",
		"res://assets/audio/SFX_Chop_002.wav",
		"res://assets/audio/SFX_Chop_003.wav",
	],
	&"stone_knock": [
		"res://assets/audio/SFX_Stone_Knock_001.wav",
		"res://assets/audio/SFX_Stone_Knock_002.wav",
		"res://assets/audio/SFX_Stone_Knock_003.wav",
	],
	&"whoosh": [
		"res://assets/audio/SFX_Whoosh_001.wav",
		"res://assets/audio/SFX_Whoosh_002.wav",
		"res://assets/audio/SFX_Whoosh_003.wav",
		"res://assets/audio/SFX_Whoosh_004.wav",
	],
	&"pop": [
		"res://assets/audio/SFX_Pop_001.wav",
		"res://assets/audio/SFX_Pop_002.wav",
	],
	&"craft": [
		"res://assets/audio/SFX_Craft_001.wav",
		"res://assets/audio/SFX_Craft_002.wav",
		"res://assets/audio/SFX_Craft_003.wav",
		"res://assets/audio/SFX_Craft_004.wav",
		"res://assets/audio/SFX_Craft_005.wav",
	],
	&"place": [
		"res://assets/audio/SFX_Place_001.wav",
		"res://assets/audio/SFX_Place_002.wav",
		"res://assets/audio/SFX_Place_003.wav",
	],
	&"build": [
		"res://assets/audio/SFX_Build_001.wav",
		"res://assets/audio/SFX_Build_002.wav",
		"res://assets/audio/SFX_Build_003.wav",
	],
	&"dismantle": [
		"res://assets/audio/SFX_Dismantle_001.wav",
		"res://assets/audio/SFX_Dismantle_002.wav",
		"res://assets/audio/SFX_Dismantle_003.wav",
	],
	&"tree_creak": [
		"res://assets/audio/SFX_Tree_Creak_001.wav",
		"res://assets/audio/SFX_Tree_Creak_002.wav",
		"res://assets/audio/SFX_Tree_Creak_003.wav",
	],
	&"collapse": ["res://assets/audio/SFX_Collapse_001.wav"],
	&"door": [
		"res://assets/audio/SFX_Door_001.wav",
		"res://assets/audio/SFX_Door_002.wav",
		"res://assets/audio/SFX_Door_003.wav",
		"res://assets/audio/SFX_Door_004.wav",
		"res://assets/audio/SFX_Door_005.wav",
	],
	&"eat": ["res://assets/audio/SFX_Eat_001.wav"],
	&"drink": [
		"res://assets/audio/SFX_Drink_001.wav",
		"res://assets/audio/SFX_Drink_002.wav",
		"res://assets/audio/SFX_Drink_003.wav",
	],
	&"fire_ignite": ["res://assets/audio/SFX_Fire_Ignite.wav"],
	&"tool_break": [
		"res://assets/audio/SFX_Tool_Break_001.wav",
		"res://assets/audio/SFX_Tool_Break_002.wav",
		"res://assets/audio/SFX_Tool_Break_003.wav",
	],
	&"hurt": [
		"res://assets/audio/SFX_Hurt_001.wav",
		"res://assets/audio/SFX_Hurt_002.wav",
		"res://assets/audio/SFX_Hurt_003.wav",
		"res://assets/audio/SFX_Hurt_004.wav",
		"res://assets/audio/SFX_Hurt_005.wav",
		"res://assets/audio/SFX_Hurt_006.wav",
	],
	&"ui_click": [
		"res://assets/audio/SFX_UI_Click_001.wav",
		"res://assets/audio/SFX_UI_Click_002.wav",
		"res://assets/audio/SFX_UI_Click_003.wav",
		"res://assets/audio/SFX_UI_Click_004.wav",
		"res://assets/audio/SFX_UI_Click_005.wav",
	],
	&"axe_chop": [
		"res://assets/audio/SFX_Axe_Chop_000.wav",
		"res://assets/audio/SFX_Axe_Chop_001.wav",
		"res://assets/audio/SFX_Axe_Chop_002.wav",
		"res://assets/audio/SFX_Axe_Chop_003.wav",
		"res://assets/audio/SFX_Axe_Chop_004.wav",
	],
	&"axe_glance": [
		"res://assets/audio/SFX_Axe_Glance_000.wav",
		"res://assets/audio/SFX_Axe_Glance_001.wav",
		"res://assets/audio/SFX_Axe_Glance_002.wav",
	],
	&"fire_loop": ["res://assets/audio/AMB_Campfire_Crackle.wav"],
	&"wind_loop": ["res://assets/audio/AMB_Wind_Loop.wav"],
	&"birds_loop": ["res://assets/audio/AMB_Birds_Loop.wav"],
	&"crickets_loop": ["res://assets/audio/AMB_Crickets_Loop.wav"],
	&"rain_loop": ["res://assets/audio/AMB_Rain_Loop.wav"],
}
const CAPTIONS := {
	&"fire_ignite": "CAPTION_FIRE", &"tool_break": "CAPTION_TOOL_BREAK",
	&"collapse": "CAPTION_COLLAPSE", &"hurt": "CAPTION_HURT", &"door": "CAPTION_DOOR",
}
## Animal voices: dropped into ANIMAL_DIR as <species>_<event>[_NN].(wav|ogg|mp3), e.g. wolf_howl_01.ogg,
## mammoth_stamp.wav; "any_<event>" serves every species without its own. Found at start-up, no code changes needed.
## Without a file nothing is heard, but the subtitle still says what the animal did (see play_animal).
const ANIMAL_DIR := "res://assets/audio/animals"
const ANIMAL_EVENTS := [&"howl", &"growl", &"roar", &"stamp", &"alarm", &"call", &"attack", &"hurt", &"death", &"eat"]
## How far each event carries (m) and how loud it is — howls and roars are heard across a valley.
const ANIMAL_RANGE := {&"howl": 400.0, &"roar": 250.0, &"call": 90.0, &"alarm": 80.0, &"growl": 35.0, &"stamp": 45.0,
	&"attack": 40.0, &"hurt": 50.0, &"death": 50.0, &"eat": 15.0}
## Events worth a subtitle (the quiet ones aren't).
const ANIMAL_CAPTIONED := [&"howl", &"roar", &"growl", &"stamp", &"alarm", &"call"]
const POOL_3D := 16
const POOL_2D := 6

var streams: Dictionary = {}
var _variants: Dictionary = {}
var _last_variant: Dictionary = {}
var _pool3d: Array[AudioStreamPlayer3D] = []
var _pool2d: Array[AudioStreamPlayer] = []
var _next3d := 0
var _next2d := 0
var animal_sounds: Dictionary = {}  # "wolf_howl" -> Array[AudioStream]


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
	for n: StringName in [&"fire_loop", &"wind_loop", &"birds_loop", &"crickets_loop", &"rain_loop"]:
		if streams[n] is AudioStreamWAV:
			var ambience := streams[n] as AudioStreamWAV
			ambience.loop_mode = AudioStreamWAV.LOOP_FORWARD
			ambience.loop_begin = 0
			ambience.loop_end = ambience.data.size() / 2
	_load_animal_sounds()
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
	if name == &"step_grass" or name == &"step_snow" or name == &"step_water":
		volume_db += 8.0
	elif name == &"hurt":
		volume_db -= 6.0
	var pitch := 1.0 + randf_range(-pitch_var, pitch_var)
	if pos is Vector3:
		var p := _pool3d[_next3d]
		_next3d = (_next3d + 1) % POOL_3D
		p.max_distance = 45.0
		p.unit_size = 6.0
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


func _load_animal_sounds() -> void:
	animal_sounds.clear()
	if not DirAccess.dir_exists_absolute(ANIMAL_DIR):
		return
	for f: String in ResourceLoader.list_directory(ANIMAL_DIR):
		if not (f.ends_with(".wav") or f.ends_with(".ogg") or f.ends_with(".mp3")):
			continue
		var key := animal_key(f)
		if key == "":
			continue
		var st := load(ANIMAL_DIR.path_join(f)) as AudioStream
		if st:
			if not animal_sounds.has(key):
				animal_sounds[key] = []
			animal_sounds[key].append(st)


## "wolf_howl_02.ogg" → "wolf_howl" (species + a known event; numbering and extension dropped), else "".
static func animal_key(file: String) -> String:
	var parts := file.get_basename().to_lower().split("_")
	for i in range(1, parts.size()):
		if StringName(parts[i]) in ANIMAL_EVENTS:
			return "_".join(parts.slice(0, i)) + "_" + parts[i]
	return ""


## An animal makes a sound: a recorded variant if one was dropped in (species-specific, then "any_"), and a
## subtitle for the loud ones when the player is close enough to hear it.
func play_animal(species: StringName, event: StringName, pos: Vector3, volume_db: float = 0.0) -> void:
	var range: float = ANIMAL_RANGE.get(event, 40.0)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var dist := cam.global_position.distance_to(pos) if cam else 0.0
	if dist > range:
		return
	var list: Array = animal_sounds.get("%s_%s" % [species, event], animal_sounds.get("any_%s" % event, []))
	if not list.is_empty():
		var p := _pool3d[_next3d]
		_next3d = (_next3d + 1) % POOL_3D
		p.stream = list[randi() % list.size()]
		p.global_position = pos
		p.volume_db = volume_db
		p.max_distance = range
		p.unit_size = range * 0.12
		p.pitch_scale = 1.0 + randf_range(-0.06, 0.06)
		p.play()
	if event in ANIMAL_CAPTIONED and bool(Settings.get_value("accessibility", "subtitles")):
		caption.emit(Loc.t("CAPTION_ANIMAL", {"animal": Loc.t("ANIMAL_%s" % String(species).to_upper()),
			"sound": Loc.t("ANIMAL_SOUND_%s" % String(event).to_upper())}))


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
