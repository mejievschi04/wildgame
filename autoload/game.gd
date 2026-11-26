extends Node
## Scene flow between the main menu and a game session.

const MENU_SCENE := "res://scenes/main_menu.tscn"
const GAME_SCENE := "res://scenes/game.tscn"

## Save data the next GameSession applies on _ready (empty = new game).
var pending_save: Dictionary = {}
var pending_opening := false
var current_slot := "slot1"
var _loading: LoadingScreen


func new_game(with_opening := false) -> void:
	if _loading:
		return
	pending_save = {}
	pending_opening = with_opening
	_enter_game()


func continue_game() -> bool:
	var slot := SaveManager.latest_slot()
	return load_slot(slot) if slot != "" else false


func load_slot(slot: String) -> bool:
	if _loading:
		return false
	var data := SaveManager.load_game(slot)
	if data.is_empty():
		Events.toast(TranslationServer.translate("MSG_LOAD_FAILED"), &"danger")
		return false
	pending_save = data
	pending_opening = false
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


## Loads the session behind a LoadingScreen. Building the world blocks the main thread for a few seconds, so each
## stage is shown on the bar before the next blocking step starts.
func _enter_game() -> void:
	get_tree().paused = false
	if _loading:
		return
	var tree := get_tree()
	_loading = LoadingScreen.new()
	tree.root.add_child(_loading)
	await _loading.opened
	_loading.set_stage("LOAD_STAGE_SCENE", 0.08)
	if ResourceLoader.load_threaded_request(GAME_SCENE) != OK:
		tree.change_scene_to_file(GAME_SCENE)
	else:
		var prog := []
		while ResourceLoader.load_threaded_get_status(GAME_SCENE, prog) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			_loading.set_stage("LOAD_STAGE_SCENE", 0.08 + 0.2 * float(prog[0]))
			await tree.process_frame
		var packed := ResourceLoader.load_threaded_get(GAME_SCENE) as PackedScene
		_loading.set_stage("LOAD_STAGE_WORLD", 0.42)
		while not _loading.caught_up():
			await tree.process_frame
		await tree.process_frame
		tree.change_scene_to_packed(packed)
	await tree.process_frame
	await tree.process_frame
	_loading.set_stage("LOAD_STAGE_LIFE", 0.9)
	# Let the first frames stream the nearby region and compile shaders behind the curtain.
	for i in 40:
		await tree.process_frame
	_loading.set_stage("LOAD_STAGE_READY", 1.0)
	while not _loading.caught_up():
		await tree.process_frame
	_loading.finish()
	await _loading.finished
	_loading = null
	var session := tree.current_scene as GameSession
	if session:
		session.play_opening()
