class_name SaveSlotsPanel
extends PanelContainer
## Lists save slots. mode "save" writes the chosen slot; "load" loads it.

signal slot_chosen(slot: String)
signal closed

var mode := "load"
var _list: VBoxContainer
var _title: Label


func _ready() -> void:
	custom_minimum_size = Vector2(520, 0)
	var v := VBoxContainer.new()
	add_child(v)
	_title = UITheme.label("", "HeadingLabel")
	v.add_child(_title)
	v.add_child(HSeparator.new())
	_list = VBoxContainer.new()
	v.add_child(_list)
	v.add_child(UITheme.button(Loc.t("BTN_BACK"), func() -> void: closed.emit()))


func refresh() -> void:
	_title.text = Loc.t("MENU_SAVE" if mode == "save" else "MENU_LOAD")
	for c in _list.get_children():
		c.queue_free()
	var first: Button = null
	for info: Dictionary in SaveManager.list_slots():
		var slot: String = info.slot
		if mode == "save" and slot == "autosave":
			continue
		var label := Loc.t("SLOT_%s" % slot.to_upper())
		if info.exists:
			var dt := Time.get_datetime_string_from_unix_time(int(info.saved_at), true)
			label += "   —   " + Loc.t("SLOT_INFO", {"day": info.day, "date": dt})
		else:
			label += "   —   " + Loc.t("SLOT_EMPTY")
		var b := UITheme.button(label, func() -> void: slot_chosen.emit(slot))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = mode == "load" and not info.exists
		_list.add_child(b)
		if first == null and not b.disabled:
			first = b
	if first:
		first.grab_focus.call_deferred()
