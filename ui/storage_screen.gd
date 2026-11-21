class_name StorageScreen
extends Control
## Two-grid transfer screen for a storage piece. Click (or Enter on a focused slot) moves a stack.

signal closed

var player: Player
var piece: BuildingPiece
var _player_grid: GridContainer
var _box_grid: GridContainer


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = UITheme.get_theme(bool(Settings.get_value("accessibility", "high_contrast")))
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.05, 0.04, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	center.add_child(row)
	_player_grid = _panel(row, Loc.t("COL_ITEMS"), 6)
	_box_grid = _panel(row, Loc.t("STORAGE_TITLE"), 4)
	var hint := UITheme.label(Loc.t("STORAGE_HINT"), "MutedLabel")
	hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hint.position.y -= 60
	add_child(hint)


func _panel(parent: Container, title: String, cols: int) -> GridContainer:
	var p := PanelContainer.new()
	parent.add_child(p)
	var v := VBoxContainer.new()
	p.add_child(v)
	v.add_child(UITheme.label(title, "HeadingLabel"))
	v.add_child(HSeparator.new())
	var g := GridContainer.new()
	g.columns = cols
	g.add_theme_constant_override("h_separation", 6)
	g.add_theme_constant_override("v_separation", 6)
	v.add_child(g)
	return g


func open(p: Player, target: BuildingPiece) -> void:
	player = p
	piece = target
	_fill(_player_grid, player.inventory)
	_fill(_box_grid, piece.storage)
	UITheme.show_animated(self, true)


func _fill(grid: GridContainer, inv: Inventory) -> void:
	for c in grid.get_children():
		c.queue_free()
	for i in inv.size:
		var s := ItemSlot.new()
		s.index = i
		s.inventory = inv
		s.focus_mode = Control.FOCUS_ALL
		s.clicked.connect(func(slot: ItemSlot, _b: int, _d: bool) -> void: transfer(slot.inventory, slot.index))
		grid.add_child(s)


func transfer(from: Inventory, index: int) -> void:
	var to := piece.storage if from == player.inventory else player.inventory
	var st := from.take_from_slot(index)
	if st == null:
		return
	var left := to.add_stack(st)
	if left > 0:
		from.add_item(st.id, left, st.durability)


func close() -> void:
	UITheme.show_animated(self, false)
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("inventory") or event.is_action_pressed("interact"):
		close()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		var f := get_viewport().gui_get_focus_owner()
		if f is ItemSlot:
			transfer((f as ItemSlot).inventory, (f as ItemSlot).index)
			get_viewport().set_input_as_handled()
