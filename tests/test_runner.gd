extends Node
## Headless test runner:  godot --headless --path . res://tests/test_runner.tscn
## Exit code 0 = all passed. Each suite method starting with test_ is run (may be a coroutine).

const SUITES := [
	"res://tests/test_data.gd",
	"res://tests/test_inventory.gd",
	"res://tests/test_crafting.gd",
	"res://tests/test_survival.gd",
	"res://tests/test_save.gd",
	"res://tests/test_world.gd",
	"res://tests/test_building.gd",
	"res://tests/test_audio.gd",
	"res://tests/test_weather.gd",
	"res://tests/test_wildlife.gd",
	"res://tests/test_trees.gd",
	"res://tests/test_tribes.gd",
	"res://tests/test_combat.gd",
]


func _ready() -> void:
	await get_tree().process_frame  # root must finish setting up before suites add scenes
	SaveManager.save_dir = "user://test_saves"
	for s: String in SaveManager.SLOTS:
		SaveManager.delete_slot(s)
	var total := 0
	var failed := 0
	var only := OS.get_environment("TEST_ONLY")  # e.g. TEST_ONLY=wildlife runs test_wildlife.gd only
	for path: String in SUITES:
		if only != "" and not path.contains(only):
			continue
		var script: GDScript = load(path)
		if script == null or not script.can_instantiate():
			total += 1
			failed += 1
			print("  FAIL  %s (script failed to load)" % path)
			continue
		var suite: TestCase = script.new()
		suite.tree = get_tree()
		for m: Dictionary in suite.get_method_list():
			var mname: String = m.name
			if not mname.begins_with("test_"):
				continue
			total += 1
			suite.failures.clear()
			await suite.call(mname)
			if suite.failures.is_empty():
				print("  PASS  %s::%s" % [path.get_file(), mname])
			else:
				failed += 1
				print("  FAIL  %s::%s" % [path.get_file(), mname])
				for f in suite.failures:
					print("        - ", f)
	print("\n%d tests, %d failed" % [total, failed])
	get_tree().quit(1 if failed > 0 else 0)
