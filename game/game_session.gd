class_name GameSession
extends Node
## Root of a play session: world + player + UI. Handles new/load, saving, UI modality, death.

const AUTOSAVE_INTERVAL := 300.0

var world: ForestWorld
var player: Player
var hud: HUD
var inventory_screen: InventoryScreen
var pause_menu: PauseMenu
var death_screen: DeathScreen
var build_menu: BuildMenu
var storage_screen: StorageScreen
var _autosave_t := 0.0


func _ready() -> void:
	world = ForestWorld.new()
	world.name = "World"
	add_child(world)
	player = Player.new()
	player.name = "Player"
	player.world = world
	world.add_child(player)
	world.player = player
	var save := Game.pending_save
	Game.pending_save = {}
	if save.is_empty():
		_start_new()
	else:
		_apply_save(save)
	_build_ui()
	player.died.connect(_on_player_died)
	player.slept.connect(func(_h: float) -> void: save_to("autosave"))
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	AutoShot.attach_if_requested(self)


func _start_new() -> void:
	player.global_position = world.spawn_position()
	player.respawn_point = player.global_position
	player.rotation.y = -PI * 0.5  # face east, towards the river
	world.day_night.time_hours = 10.0
	world.add_journal("JOURNAL_START")


func _apply_save(d: Dictionary) -> void:
	world.apply_save(d.get("world", {}))
	player.from_dict(d.get("player", {}))


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "UI"
	add_child(layer)
	hud = HUD.new()
	layer.add_child(hud)
	hud.bind(player)
	inventory_screen = InventoryScreen.new()
	layer.add_child(inventory_screen)
	inventory_screen.bind(player)
	inventory_screen.closed.connect(_on_ui_closed)
	pause_menu = PauseMenu.new()
	pause_menu.day_text_provider = func() -> String: return Loc.t("PAUSE_DAY", {"day": world.day_night.day})
	layer.add_child(pause_menu)
	pause_menu.resumed.connect(_on_ui_closed)
	pause_menu.save_requested.connect(save_to)
	build_menu = BuildMenu.new()
	build_menu.player = player
	layer.add_child(build_menu)
	build_menu.closed.connect(_on_ui_closed)
	build_menu.chosen.connect(func(id: StringName) -> void:
		_on_ui_closed()
		player.build.begin(id))
	storage_screen = StorageScreen.new()
	layer.add_child(storage_screen)
	storage_screen.closed.connect(_on_ui_closed)
	Events.open_storage.connect(open_storage)
	Events.building_completed.connect(func(p: Node) -> void:
		if (p as BuildingPiece).piece_class() in ["roof", "shelter"]:
			world.add_journal("JOURNAL_SHELTER"))
	death_screen = DeathScreen.new()
	layer.add_child(death_screen)


func build_save() -> Dictionary:
	return {"world": world.collect_save(), "player": player.to_dict()}


func save_to(slot: String) -> bool:
	if player.dead:
		return false
	return SaveManager.save_game(slot, build_save())


func _process(delta: float) -> void:
	var dn := world.day_night
	if dn.day >= 2 and dn.time_hours >= 6.0 and not player.dead:
		world.add_journal("JOURNAL_FIRST_NIGHT")
	_autosave_t += delta
	if _autosave_t >= AUTOSAVE_INTERVAL:
		_autosave_t = 0.0
		save_to("autosave")


func is_ui_open() -> bool:
	return inventory_screen.visible or pause_menu.visible or death_screen.visible \
		or build_menu.visible or storage_screen.visible


func open_inventory(tab: int = 0) -> void:
	player.placement.cancel()
	player.input_enabled = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	inventory_screen.open(tab)


func open_build_menu() -> void:
	player.placement.cancel()
	player.build.cancel()
	player.input_enabled = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	build_menu.open()


func open_storage(piece: Node) -> void:
	player.input_enabled = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	storage_screen.open(player, piece as BuildingPiece)


func open_pause() -> void:
	player.input_enabled = false
	pause_menu.open()


func _on_ui_closed() -> void:
	if player.dead:
		return
	player.input_enabled = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_player_died(cause: StringName) -> void:
	player.input_enabled = false
	for ui: Control in [inventory_screen, build_menu, storage_screen]:
		ui.visible = false
	death_screen.show_death(cause)


func _unhandled_input(event: InputEvent) -> void:
	if player.dead or is_ui_open():
		return
	if event.is_action_pressed("pause"):
		if player.build.active:
			player.build.cancel()
		elif player.placement.active:
			player.placement.cancel()
		else:
			open_pause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("inventory"):
		open_inventory(0)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("journal"):
		open_inventory(1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_menu"):
		open_build_menu()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and not has_meta("no_focus_pause") and not is_ui_open() and player and not player.dead:
		open_pause.call_deferred()
