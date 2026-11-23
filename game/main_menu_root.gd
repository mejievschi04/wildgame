extends Node3D
## Main menu scene: live 3D backdrop (the forest at dawn, a small camp) + MainMenu UI.

var _cam: Camera3D
var _t := 0.0
var _pivot := Vector3.ZERO


func _ready() -> void:
	var world := ForestWorld.new()
	world.menu_mode = true
	add_child(world)
	world.day_night.time_hours = 6.6
	var base := world.ground_point(-2.0, 2.0)
	_pivot = base + Vector3(0, 0.8, 0)
	var fire: Campfire = world.spawn_structure(&"campfire", Transform3D(Basis(), base))
	fire.add_fuel(Campfire.MAX_FUEL)
	fire.ignite()
	var lean: BuildingPiece = world.spawn_structure(&"piece", Transform3D(Basis(Vector3.UP, 0.5 + PI), world.ground_point(-4.5, 0.0)), {"piece": "lean_to"})
	lean.complete()
	var bed: Node3D = world.spawn_structure(&"bed", Transform3D(Basis(Vector3.UP, 0.5), world.ground_point(-4.0, 1.2)))
	bed.process_mode = Node.PROCESS_MODE_DISABLED
	_cam = Camera3D.new()
	_cam.fov = 62.0
	_cam.far = 14000.0
	add_child(_cam)
	_update_cam()
	var amb := Ambience.new()
	amb.day_night = world.day_night
	add_child(amb)
	var layer := CanvasLayer.new()
	add_child(layer)
	layer.add_child(MainMenu.new())
	AutoShot.attach_if_requested(self)


func _process(delta: float) -> void:
	_t += delta
	_update_cam()


func _update_cam() -> void:
	var a := 0.9 + sin(_t * 0.05) * 0.18
	var r := 7.5
	_cam.position = _pivot + Vector3(cos(a) * r, 1.6 + sin(_t * 0.11) * 0.1, sin(a) * r)
	_cam.look_at(_pivot + Vector3(-2.2, 0.4, 0), Vector3.UP)
