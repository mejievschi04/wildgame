extends Node
## Global signal bus. Systems emit here instead of referencing each other directly.

## Short on-screen message. kind: &"info", &"good", &"warn", &"danger".
signal notify(text: String, kind: StringName)
signal item_gained(item_id: StringName, count: int)
signal crafted(recipe_id: StringName)
signal journal_added(key: String)
signal player_died(cause: StringName)
signal game_saved(slot: String)
signal settings_applied


func toast(text: String, kind: StringName = &"info") -> void:
	notify.emit(text, kind)
