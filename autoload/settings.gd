extends Node
## Persistent user settings (user://settings.cfg) + applying them to the engine.

signal changed(section: String, key: String)

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"video": {"fullscreen": false, "vsync": true, "fov": 80.0, "render_scale": 1.0, "shadows": true, "max_fps": 0,
		"quality": 1, "aa": 3, "upscaler": 0},
	"audio": {"master": 0.8, "music": 0.6, "sfx": 0.9},
	"gameplay": {
		"mouse_sensitivity": 1.0, "invert_y": false, "difficulty": 1, "toggle_sprint": false,
		"toggle_crouch": true, "day_length_min": 24.0, "language": "ru",
	},
	"accessibility": {"hud_scale": 1.0, "high_contrast": false, "reduce_motion": false, "subtitles": true},
}
const DIFFICULTY_MULT := [0.6, 1.0, 1.45]
## Graphics presets (index = video.quality): low / medium / high.
const QUALITY := [
	{"shadow_dist": 45.0, "shadow_atlas": 2048, "splits": 2, "volfog": false, "ssao": false, "grass_range": 26.0, "fern_range": 45.0},
	{"shadow_dist": 65.0, "shadow_atlas": 2048, "splits": 2, "volfog": true, "ssao": true, "grass_range": 34.0, "fern_range": 60.0},
	{"shadow_dist": 120.0, "shadow_atlas": 4096, "splits": 4, "volfog": true, "ssao": true, "grass_range": 55.0, "fern_range": 90.0},
]
const AUDIO_BUSES := ["Music", "SFX"]

var _cfg := ConfigFile.new()


func _ready() -> void:
	_ensure_audio_buses()
	InputSetup.register_defaults()
	load_settings()
	apply_all()


func load_settings() -> void:
	_cfg = ConfigFile.new()
	_cfg.load(PATH)  # missing file is fine → defaults
	var bindings: Dictionary = _cfg.get_value("controls", "bindings", {})
	for action: String in bindings.keys():
		var ev := InputSetup.deserialize(bindings[action])
		if ev != null and InputMap.has_action(action):
			InputSetup.rebind(StringName(action), ev)


func save_settings() -> void:
	var err := _cfg.save(PATH)
	if err != OK:
		push_warning("Settings: could not save (%s)" % error_string(err))


func get_value(section: String, key: String) -> Variant:
	var def: Variant = DEFAULTS.get(section, {}).get(key)
	return _cfg.get_value(section, key, def)


func set_value(section: String, key: String, value: Variant, persist: bool = true) -> void:
	_cfg.set_value(section, key, value)
	_apply(section, key)
	if persist:
		save_settings()
	changed.emit(section, key)
	Events.settings_applied.emit()


func set_binding(action: StringName, ev: InputEvent) -> void:
	InputSetup.rebind(action, ev)
	var bindings: Dictionary = _cfg.get_value("controls", "bindings", {})
	bindings[String(action)] = InputSetup.serialize(ev)
	_cfg.set_value("controls", "bindings", bindings)
	save_settings()
	changed.emit("controls", String(action))


func reset_bindings() -> void:
	InputSetup.register_defaults()
	if _cfg.has_section("controls"):
		_cfg.erase_section("controls")
	save_settings()
	changed.emit("controls", "")


func quality() -> Dictionary:
	return QUALITY[clampi(int(get_value("video", "quality")), 0, 2)]


func difficulty_mult() -> float:
	return DIFFICULTY_MULT[clampi(int(get_value("gameplay", "difficulty")), 0, 2)]


func apply_all() -> void:
	for section: String in DEFAULTS.keys():
		for key: String in DEFAULTS[section].keys():
			_apply(section, key)


func _apply(section: String, key: String) -> void:
	var v: Variant = get_value(section, key)
	match [section, key]:
		["video", "fullscreen"]:
			if DisplayServer.get_name() != "headless":
				DisplayServer.window_set_mode(
					DisplayServer.WINDOW_MODE_FULLSCREEN if v else DisplayServer.WINDOW_MODE_WINDOWED)
		["video", "vsync"]:
			DisplayServer.window_set_vsync_mode(
				DisplayServer.VSYNC_ENABLED if v else DisplayServer.VSYNC_DISABLED)
		["video", "render_scale"]:
			get_tree().root.scaling_3d_scale = clampf(float(v), 0.5, 1.0)
		["video", "aa"]:
			var vp := get_tree().root
			var mode := int(v)  # 0 off, 1 FXAA, 2 SMAA, 3 TAA, 4 MSAA 2x
			vp.use_taa = mode == 3
			vp.msaa_3d = Viewport.MSAA_2X if mode == 4 else Viewport.MSAA_DISABLED
			vp.screen_space_aa = [Viewport.SCREEN_SPACE_AA_DISABLED, Viewport.SCREEN_SPACE_AA_FXAA,
				Viewport.SCREEN_SPACE_AA_SMAA, Viewport.SCREEN_SPACE_AA_DISABLED, Viewport.SCREEN_SPACE_AA_DISABLED][clampi(mode, 0, 4)]
		["video", "upscaler"]:
			get_tree().root.scaling_3d_mode = [Viewport.SCALING_3D_MODE_BILINEAR, Viewport.SCALING_3D_MODE_FSR2,
				Viewport.SCALING_3D_MODE_METALFX_TEMPORAL][clampi(int(v), 0, 2)]
		["video", "max_fps"]:
			Engine.max_fps = int(v)
		["audio", "master"]:
			_set_bus_volume("Master", float(v))
		["audio", "music"]:
			_set_bus_volume("Music", float(v))
		["audio", "sfx"]:
			_set_bus_volume("SFX", float(v))
		["gameplay", "language"]:
			TranslationServer.set_locale(str(v))
		["accessibility", "hud_scale"]:
			get_tree().root.content_scale_factor = clampf(float(v), 0.75, 1.5)


func _set_bus_volume(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))
		AudioServer.set_bus_mute(idx, linear <= 0.001)


func _ensure_audio_buses() -> void:
	for bus_name: String in AUDIO_BUSES:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")
