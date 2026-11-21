class_name Ambience
extends Node
## Ambient beds that follow the time of day: wind always, birds by day, crickets at night.
## Music stays minimal per GDD §14 (none yet).

var day_night: DayNight
var _wind: AudioStreamPlayer
var _birds: AudioStreamPlayer
var _crickets: AudioStreamPlayer


func _ready() -> void:
	_wind = _bed(&"wind_loop")
	_birds = _bed(&"birds_loop")
	_crickets = _bed(&"crickets_loop")


func _bed(name: StringName) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = Sfx.stream(name)
	p.bus = &"Ambience"
	p.volume_db = -80.0
	add_child(p)
	p.play()
	return p


func _process(_delta: float) -> void:
	if day_night == null:
		return
	var day_k := smoothstep(-0.1, 0.25, day_night.sun_elevation())
	# Keep environmental beds behind gameplay; the Ambience slider controls this bus.
	_wind.volume_db = linear_to_db(lerpf(0.20, 0.14, day_k))
	_birds.volume_db = linear_to_db(maxf(0.13 * day_k, 0.0001))
	_crickets.volume_db = linear_to_db(maxf(0.10 * (1.0 - day_k), 0.0001))
