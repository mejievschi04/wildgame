extends TestCase


func test_save_load_roundtrip() -> void:
	var data := {"world": {"day": 3, "time_hours": 7.5}, "player": {"pos": [1, 2, 3]}}
	check(SaveManager.save_game("slot3", data), "saved")
	var loaded := SaveManager.load_game("slot3")
	eq(int(loaded.world.day), 3, "day restored")
	eq(int(loaded.version), SaveManager.SAVE_VERSION, "version stamped")
	check(SaveManager.has_any_save(), "has a save")
	SaveManager.delete_slot("slot3")
	check(not SaveManager.has_save("slot3"), "slot deleted")


func test_future_version_rejected() -> void:
	var f := FileAccess.open(SaveManager.slot_path("slot3"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 999}))
	f.close()
	check(SaveManager.load_game("slot3").is_empty(), "newer save version refused")
	SaveManager.delete_slot("slot3")
