extends Node3D
## Main menu. MainMenu draws its own backdrop (a still rendered from the game, see AutoShot "keyart").


func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	layer.add_child(MainMenu.new())
	_bed(&"wind_loop", linear_to_db(0.22))
	_bed(&"birds_loop", linear_to_db(0.14))
	AutoShot.attach_if_requested(self)


func _bed(name: StringName, volume_db: float) -> void:
	var p := AudioStreamPlayer.new()
	p.stream = Sfx.stream(name)
	p.bus = &"Ambience"
	p.volume_db = volume_db
	add_child(p)
	p.play()
