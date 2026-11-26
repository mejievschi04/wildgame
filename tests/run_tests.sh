#!/bin/bash
# Runs the headless test suite. Fails on test failures, a non-zero exit, OR any SCRIPT ERROR
# (GDScript runtime errors abort a test coroutine without registering as an assertion failure).
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
LOG="$(mktemp -t wildbound_tests)"
# Refresh imports + global class cache (new class_name scripts, new assets).
"$GODOT" --headless --path . --import >/dev/null 2>&1
"$GODOT" --headless --path . res://tests/test_runner.tscn >"$LOG" 2>&1 &
PID=$!
for i in $(seq 1 1500); do kill -0 $PID 2>/dev/null || break; sleep 1; done
kill $PID 2>/dev/null
wait $PID; CODE=$?
grep -E "PASS|FAIL|tests,|SCRIPT ERROR|Parse Error|   at: " "$LOG" | grep -v "^   at: push_error"
if [ $CODE -ne 0 ] || grep -q "SCRIPT ERROR" "$LOG"; then
	echo "RESULT: FAILED (exit $CODE) — full log: $LOG"
	exit 1
fi
echo "RESULT: OK"
