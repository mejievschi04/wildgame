#!/bin/bash
# Runs the headless test suite. Fails on test failures, a non-zero exit, OR any SCRIPT ERROR
# (GDScript runtime errors abort a test coroutine without registering as an assertion failure).
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
LOG="$(mktemp -t wildbound_tests)"
"$GODOT" --headless --path . res://tests/test_runner.tscn >"$LOG" 2>&1 &
PID=$!
( sleep 240; kill $PID 2>/dev/null ) & WATCH=$!
wait $PID; CODE=$?
kill $WATCH 2>/dev/null; wait $WATCH 2>/dev/null
grep -E "PASS|FAIL|tests,|SCRIPT ERROR|Parse Error|   at: " "$LOG" | grep -v "^   at: push_error"
if [ $CODE -ne 0 ] || grep -q "SCRIPT ERROR" "$LOG"; then
	echo "RESULT: FAILED (exit $CODE) — full log: $LOG"
	exit 1
fi
echo "RESULT: OK"
