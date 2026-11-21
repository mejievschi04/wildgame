extends Node
## Scene flow between the main menu and a game session.

const MENU_SCENE := "res://scenes/main_menu.tscn"
const GAME_SCENE := "res://scenes/game.tscn"

## Save data the next GameSession applies on _ready (empty = new game).
var pending_save: Dictionary = {}
var current_slot := "slot1"


func new_game() -> void:
	pending_save = {}
	_enter_game()


func continue_game() -> bool:
	var slot := SaveManager.latest_slot()
	return load_slot(slot) if slot != "" else false


func load_slot(slot: String) -> bool:
	var data := SaveManager.load_game(slot)
	if data.is_empty():
		Events.toast(TranslationServer.translate("MSG_LOAD_FAILED"), &"danger")
		return false
	pending_save = data
	if slot != "autosave":
		current_slot = slot
	_enter_game()
	return true


func to_main_menu() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_SCENE)


func quit() -> void:
	get_tree().quit()


func _enter_game() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file(GAME_SCENE)
