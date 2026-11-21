class_name SoundSynth
extends RefCounted
## Tiny offline synthesizer: filtered noise + tones + envelopes → AudioStreamWAV.
## Procedural fallback for sound events that do not have imported assets yet.

const RATE := 22050


static func _coef(hz: float) -> float:
	return 1.0 - exp(-TAU * hz / RATE)


static func _env(t: float, attack: float, decay: float) -> float:
	if t < attack:
		return t / maxf(attack, 0.0001)
	return exp(-(t - attack) / maxf(decay, 0.0001))


## Noise burst. lp/hp in Hz (hp 0 = off).
static func noise(dur: float, lp: float, hp: float, attack: float, decay: float, gain: float, seed: int = 1) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var a := _coef(lp)
	var ah := _coef(hp) if hp > 0.0 else 0.0
	var y := 0.0
	var low := 0.0
	for i in n:
		y += a * (rng.randf() * 2.0 - 1.0 - y)
		var s := y
		if hp > 0.0:
			low += ah * (y - low)
			s = y - low
		out[i] = s * _env(float(i) / RATE, attack, decay) * gain
	return out


## Sine sweep f0→f1 with optional 2nd harmonic.
static func tone(dur: float, f0: float, f1: float, attack: float, decay: float, gain: float, harm: float = 0.0) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		phase += TAU * lerpf(f0, f1, t / dur) / RATE
		out[i] = (sin(phase) + harm * sin(2.0 * phase)) * _env(t, attack, decay) * gain
	return out


## Adds b into a starting at offset seconds (a grows if needed).
static func mix(a: PackedFloat32Array, b: PackedFloat32Array, offset: float = 0.0) -> PackedFloat32Array:
	var o := int(offset * RATE)
	if a.size() < o + b.size():
		a.resize(o + b.size())
	for i in b.size():
		a[o + i] += b[i]
	return a


static func silence(dur: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(int(dur * RATE))
	return out


static func normalize(buf: PackedFloat32Array, peak: float = 0.85) -> PackedFloat32Array:
	var m := 0.0
	for v in buf:
		m = maxf(m, absf(v))
	if m > 0.0001:
		var k := peak / m
		for i in buf.size():
			buf[i] *= k
	return buf


## Crossfades the tail into the head so the buffer loops seamlessly.
static func make_loop(buf: PackedFloat32Array, fade: float = 0.25) -> PackedFloat32Array:
	var f := mini(int(fade * RATE), buf.size() / 2)
	var n := buf.size() - f
	var out := buf.slice(0, n)
	for i in f:
		var k := float(i) / f
		out[i] = buf[i] * k + buf[n + i] * (1.0 - k)
	return out


static func to_stream(buf: PackedFloat32Array, loop: bool = false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 2)
	for i in buf.size():
		bytes.encode_s16(i * 2, int(clampf(buf[i], -1.0, 1.0) * 32767.0))
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_16_BITS
	s.mix_rate = RATE
	s.stereo = false
	s.data = bytes
	if loop:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = buf.size()
	return s


# ---------------------------------------------------------------- recipes

static func build(name: StringName) -> PackedFloat32Array:
	match name:
		&"step_grass":
			return normalize(mix(noise(0.14, 1600, 200, 0.006, 0.05, 0.8, 3), tone(0.06, 95, 70, 0.002, 0.02, 0.4)), 0.5)
		&"step_wood":
			return normalize(mix(tone(0.12, 170, 140, 0.001, 0.035, 0.8, 0.3), noise(0.04, 3200, 600, 0.001, 0.01, 0.4, 5)), 0.55)
		&"step_water":
			var b := noise(0.3, 900, 150, 0.01, 0.09, 0.8, 7)
			for i in b.size():
				b[i] *= 0.6 + 0.4 * sin(i * 0.011)
			return normalize(b, 0.5)
		&"rustle":
			var b := noise(0.45, 4200, 500, 0.03, 0.15, 1.0, 11)
			var rng := RandomNumberGenerator.new()
			rng.seed = 12
			for i in b.size():
				if i % 600 == 0:
					rng.randf()
				b[i] *= 0.5 + 0.5 * sin(i * 0.004 + rng.randf() * 0.2)
			return normalize(b, 0.6)
		&"chop":
			return normalize(mix(tone(0.25, 120, 65, 0.001, 0.07, 1.0, 0.4), noise(0.08, 2600, 300, 0.001, 0.02, 0.7, 13)), 0.85)
		&"axe_chop":
			return normalize(mix(tone(0.25, 120, 65, 0.001, 0.07, 1.0, 0.4), noise(0.08, 2600, 300, 0.001, 0.02, 0.7, 13)), 0.85)
		&"axe_glance":
			return normalize(noise(0.25, 1400, 300, 0.08, 0.07, 1.0, 19), 0.35)
		&"stone_knock":
			var b := tone(0.12, 980, 900, 0.0005, 0.03, 0.6, 0.5)
			mix(b, tone(0.1, 1450, 1400, 0.0005, 0.02, 0.4))
			return normalize(mix(b, noise(0.03, 6000, 1500, 0.0005, 0.008, 0.6, 17)), 0.75)
		&"whoosh":
			return normalize(noise(0.25, 1400, 300, 0.08, 0.07, 1.0, 19), 0.35)
		&"pop":
			return normalize(tone(0.09, 520, 880, 0.002, 0.03, 1.0), 0.4)
		&"craft":
			var b := noise(0.6, 3000, 400, 0.02, 0.2, 0.8, 23)
			mix(b, tone(0.1, 300, 260, 0.001, 0.03, 0.5), 0.15)
			return normalize(mix(b, tone(0.1, 330, 280, 0.001, 0.03, 0.5), 0.4), 0.6)
		&"place":
			return normalize(mix(tone(0.35, 85, 55, 0.002, 0.1, 1.0, 0.3), noise(0.2, 900, 80, 0.002, 0.06, 0.6, 29)), 0.8)
		&"build":
			var b := mix(tone(0.15, 210, 170, 0.001, 0.04, 0.9, 0.3), noise(0.05, 3000, 400, 0.001, 0.015, 0.5, 31))
			mix(b, tone(0.15, 220, 175, 0.001, 0.04, 0.9, 0.3), 0.22)
			return normalize(b, 0.8)
		&"dismantle":
			var b := noise(0.4, 5000, 900, 0.002, 0.12, 0.9, 37)
			for k in 4:
				mix(b, noise(0.03, 7000, 2000, 0.0005, 0.01, 0.8, 40 + k), 0.05 + k * 0.07)
			return normalize(b, 0.8)
		&"collapse":
			var b := mix(tone(0.8, 70, 40, 0.01, 0.25, 1.0, 0.5), noise(0.9, 1500, 60, 0.01, 0.3, 0.9, 43))
			return normalize(b, 0.9)
		&"door":
			var b := tone(0.45, 380, 520, 0.03, 0.2, 0.5, 0.6)
			for i in b.size():
				b[i] *= 0.7 + 0.3 * sin(i * 0.05)
			return normalize(mix(b, noise(0.4, 1800, 300, 0.02, 0.15, 0.3, 47)), 0.45)
		&"eat":
			var b := silence(0.5)
			for k in 3:
				mix(b, noise(0.08, 3500, 600, 0.003, 0.03, 0.8, 50 + k), 0.03 + k * 0.15)
			return normalize(b, 0.5)
		&"drink":
			var b := silence(0.6)
			for k in 3:
				mix(b, tone(0.12, 320, 210, 0.01, 0.05, 0.8), 0.02 + k * 0.18)
			return normalize(b, 0.45)
		&"fire_ignite":
			var b := noise(0.9, 1300, 120, 0.35, 0.3, 1.0, 53)
			for k in 6:
				mix(b, noise(0.02, 7000, 2500, 0.0005, 0.006, 0.7, 60 + k), 0.4 + k * 0.08)
			return normalize(b, 0.7)
		&"tool_break":
			var b := mix(noise(0.25, 6000, 1200, 0.0005, 0.06, 1.0, 67), tone(0.2, 700, 300, 0.0005, 0.05, 0.6))
			return normalize(b, 0.85)
		&"hurt":
			return normalize(mix(tone(0.3, 110, 60, 0.002, 0.09, 1.0, 0.3), noise(0.15, 800, 80, 0.002, 0.05, 0.5, 71)), 0.8)
		&"ui_click":
			return normalize(tone(0.035, 1300, 1100, 0.001, 0.01, 1.0), 0.25)
		&"fire_loop":
			var b := noise(3.0, 420, 60, 0.0, 99.0, 0.5, 73)
			var rng := RandomNumberGenerator.new()
			rng.seed = 74
			for k in 26:
				mix(b, noise(0.025, 7000, 2200, 0.0005, 0.006, rng.randf_range(0.4, 1.0), 80 + k), rng.randf_range(0.0, 2.9))
			return make_loop(normalize(b, 0.6), 0.2)
		&"wind_loop":
			var n := int(6.0 * RATE)
			var b := PackedFloat32Array()
			b.resize(n)
			var rng := RandomNumberGenerator.new()
			rng.seed = 91
			var y := 0.0
			for i in n:
				var cutoff := 250.0 + 200.0 * (0.5 + 0.5 * sin(TAU * i / n * 2.0))
				y += _coef(cutoff) * (rng.randf() * 2.0 - 1.0 - y)
				b[i] = y * (0.6 + 0.4 * sin(TAU * i / n * 3.0 + 1.0))
			return make_loop(normalize(b, 0.5), 0.5)
		&"birds_loop":
			var b := silence(6.0)
			var rng := RandomNumberGenerator.new()
			rng.seed = 97
			for k in 9:
				var f := rng.randf_range(2200, 3800)
				var at := rng.randf_range(0.0, 5.4)
				for c in rng.randi_range(2, 4):
					mix(b, tone(0.09, f, f * rng.randf_range(1.1, 1.4), 0.01, 0.03, 0.5), at + c * 0.12)
			return make_loop(normalize(b, 0.4), 0.3)
		&"rain_loop":
			var b := noise(4.0, 5200, 900, 0.0, 99.0, 0.6, 131)
			var rng := RandomNumberGenerator.new()
			rng.seed = 132
			for k in 160:
				mix(b, noise(0.012, 8000, 3000, 0.0005, 0.004, rng.randf_range(0.2, 0.6), 140 + k), rng.randf_range(0.0, 3.9))
			return make_loop(normalize(b, 0.5), 0.3)
		&"crickets_loop":
			var b := silence(4.0)
			var t := 0.0
			while t < 3.6:
				for p in 3:
					mix(b, tone(0.025, 4600, 4600, 0.004, 0.008, 0.5), t + p * 0.035)
				t += 0.42
			return make_loop(normalize(b, 0.3), 0.2)
	push_error("SoundSynth: unknown sound %s" % name)
	return silence(0.05)
