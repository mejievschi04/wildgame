extends TestCase


func test_all_sounds_generated() -> void:
	for n: StringName in Sfx.NAMES:
		var s := Sfx.stream(n) as AudioStreamWAV
		check(s != null, "stream %s exists" % n)
		if s == null:
			continue
		check(s.data.size() > 400, "%s has audio data" % n)
		var peak := 0
		for i in range(0, s.data.size() - 1, 2):
			peak = maxi(peak, absi(s.data.decode_s16(i)))
		check(peak > 3000, "%s is audible (peak %d)" % [n, peak])
		# Headroom/loop checks apply to the procedural fallbacks; imported recordings are mastered as delivered.
		if not Sfx.FILES.has(n):
			check(peak < 32767, "%s does not clip" % n)
			eq(s.loop_mode == AudioStreamWAV.LOOP_FORWARD, String(n).ends_with("_loop"), "%s loop flag" % n)
		elif String(n).ends_with("_loop"):
			eq(s.loop_mode, AudioStreamWAV.LOOP_FORWARD, "%s imported loop is looping" % n)


func test_captions_translated() -> void:
	for k: String in Sfx.CAPTIONS.values():
		check(Loc.has_key(k), "caption key %s" % k)


func test_play_is_safe_headless() -> void:
	Sfx.play(&"chop", Vector3.ZERO)
	Sfx.play(&"ui_click")
	Sfx.play(&"does_not_exist")
	check(true, "no crash")
