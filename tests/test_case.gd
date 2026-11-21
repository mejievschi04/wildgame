class_name TestCase
extends RefCounted
## Minimal assertion base for the headless test runner (no external plugins needed).

var failures: PackedStringArray = PackedStringArray()
var tree: SceneTree


func check(cond: bool, msg: String) -> void:
	if not cond:
		failures.append(msg)


func eq(actual: Variant, expected: Variant, msg: String) -> void:
	if actual != expected:
		failures.append("%s (expected %s, got %s)" % [msg, str(expected), str(actual)])


func near(actual: float, expected: float, tol: float, msg: String) -> void:
	if absf(actual - expected) > tol:
		failures.append("%s (expected ~%s, got %s)" % [msg, expected, actual])
