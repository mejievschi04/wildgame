class_name InputSetup
extends RefCounted
## Default action map. Keyboard uses PHYSICAL keys so WASD works on Russian (ЙЦУКЕН) layouts.
## Remaps are stored by Settings as serialized events and applied over these defaults.

const REMAPPABLE := [
	&"move_forward", &"move_back", &"move_left", &"move_right", &"jump", &"sprint", &"crouch",
	&"interact", &"alt_interact", &"primary_action", &"secondary_action", &"inventory",
	&"journal", &"pause", &"hotbar_1", &"hotbar_2", &"hotbar_3", &"hotbar_4", &"hotbar_5", &"hotbar_6",
]


static func defaults() -> Dictionary:
	return {
		&"move_forward": [_key(KEY_W), _axis(JOY_AXIS_LEFT_Y, -1.0)],
		&"move_back": [_key(KEY_S), _axis(JOY_AXIS_LEFT_Y, 1.0)],
		&"move_left": [_key(KEY_A), _axis(JOY_AXIS_LEFT_X, -1.0)],
		&"move_right": [_key(KEY_D), _axis(JOY_AXIS_LEFT_X, 1.0)],
		&"look_left": [_axis(JOY_AXIS_RIGHT_X, -1.0)],
		&"look_right": [_axis(JOY_AXIS_RIGHT_X, 1.0)],
		&"look_up": [_axis(JOY_AXIS_RIGHT_Y, -1.0)],
		&"look_down": [_axis(JOY_AXIS_RIGHT_Y, 1.0)],
		&"jump": [_key(KEY_SPACE), _button(JOY_BUTTON_A)],
		&"sprint": [_key(KEY_SHIFT), _button(JOY_BUTTON_LEFT_STICK)],
		&"crouch": [_key(KEY_C), _button(JOY_BUTTON_B)],
		&"interact": [_key(KEY_E), _button(JOY_BUTTON_X)],
		&"alt_interact": [_key(KEY_R), _button(JOY_BUTTON_Y)],
		&"primary_action": [_mouse(MOUSE_BUTTON_LEFT), _axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)],
		&"secondary_action": [_mouse(MOUSE_BUTTON_RIGHT), _axis(JOY_AXIS_TRIGGER_LEFT, 1.0)],
		&"inventory": [_key(KEY_TAB), _button(JOY_BUTTON_BACK)],
		&"journal": [_key(KEY_J)],
		&"pause": [_key(KEY_ESCAPE), _button(JOY_BUTTON_START)],
		&"hotbar_1": [_key(KEY_1)],
		&"hotbar_2": [_key(KEY_2)],
		&"hotbar_3": [_key(KEY_3)],
		&"hotbar_4": [_key(KEY_4)],
		&"hotbar_5": [_key(KEY_5)],
		&"hotbar_6": [_key(KEY_6)],
		&"hotbar_next": [_button(JOY_BUTTON_RIGHT_SHOULDER), _mouse(MOUSE_BUTTON_WHEEL_DOWN)],
		&"hotbar_prev": [_button(JOY_BUTTON_LEFT_SHOULDER), _mouse(MOUSE_BUTTON_WHEEL_UP)],
	}


static func register_defaults() -> void:
	var d := defaults()
	for action: StringName in d.keys():
		if InputMap.has_action(action):
			InputMap.action_erase_events(action)
		else:
			InputMap.add_action(action, 0.25)
		for ev: InputEvent in d[action]:
			InputMap.action_add_event(action, ev)


## Replaces the keyboard/mouse binding (first non-joypad event) of an action.
static func rebind(action: StringName, ev: InputEvent) -> void:
	for old: InputEvent in InputMap.action_get_events(action):
		if old is InputEventKey or old is InputEventMouseButton:
			InputMap.action_erase_event(action, old)
	InputMap.action_add_event(action, ev)


static func primary_event(action: StringName) -> InputEvent:
	if not InputMap.has_action(action):
		return null
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventKey or ev is InputEventMouseButton:
			return ev
	return null


## Human-readable label for HUD prompts, e.g. "E", "ЛКМ".
static func label(action: StringName) -> String:
	return event_label(primary_event(action))


static func event_label(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		# Show the latin label of the physical key (matches the key caps players learn from guides).
		return OS.get_keycode_string(code)
	if ev is InputEventMouseButton:
		match (ev as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT: return TranslationServer.translate("KEY_LMB")
			MOUSE_BUTTON_RIGHT: return TranslationServer.translate("KEY_RMB")
			MOUSE_BUTTON_MIDDLE: return TranslationServer.translate("KEY_MMB")
			MOUSE_BUTTON_WHEEL_UP: return TranslationServer.translate("KEY_WHEEL_UP")
			MOUSE_BUTTON_WHEEL_DOWN: return TranslationServer.translate("KEY_WHEEL_DOWN")
			_: return "M%d" % (ev as InputEventMouseButton).button_index
	return "—"


static func serialize(ev: InputEvent) -> Dictionary:
	if ev is InputEventKey:
		return {"t": "key", "code": int((ev as InputEventKey).physical_keycode)}
	if ev is InputEventMouseButton:
		return {"t": "mouse", "code": int((ev as InputEventMouseButton).button_index)}
	return {}


static func deserialize(d: Dictionary) -> InputEvent:
	match str(d.get("t", "")):
		"key": return _key(int(d.get("code", 0)))
		"mouse": return _mouse(int(d.get("code", 1)))
	return null


static func _key(code: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	return e


static func _mouse(button: MouseButton) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	return e


static func _button(button: JoyButton) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	return e


static func _axis(axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = value
	return e
