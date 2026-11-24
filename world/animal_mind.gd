class_name AnimalMind
extends RefCounted
## What an animal wants and feels, under the state machine in Animal (GDD §6):
##   needs that build up over time — hunger, thirst, fatigue — and are met by eating, drinking and resting;
##   fear that rises with danger (a hunter in sight, a wound, someone watching) and fades when things are quiet;
##   a temperament (bold / curious / aggressive) from data/animals.json "mind", a little different per animal;
##   memory: who hurt it (an aggressive animal holds a grudge and comes for them, a timid one shies away sooner)
##   and the places where it met danger, which it avoids when it picks where to wander.
## Everything is 0..1. Time is the animal's uptime in seconds.

## Temperament by diet when a species gives none (data "mind" overrides any of the keys).
const BY_DIET := {
	"prey": {"bold": 0.2, "curious": 0.35, "aggressive": 0.05},
	"defensive": {"bold": 0.7, "curious": 0.3, "aggressive": 0.5},
	"predator": {"bold": 0.6, "curious": 0.6, "aggressive": 0.55},
}
const DANGER_SPOTS := 4          # places remembered
const DANGER_RADIUS := 25.0      # a wander goal this close to one is avoided

var bold := 0.5
var curious := 0.5
var aggressive := 0.5
var memory_s := 600.0            # how long a grudge or a danger spot lasts

var hunger := 0.0
var thirst := 0.0
var fatigue := 0.0
var fear := 0.0

var hunger_rate := 1.0 / 480.0   # per second, from full to starving
var thirst_rate := 1.0 / 420.0

var grudge_until := -1.0         # remembers the player who hurt it until this uptime
var danger: Array = []           # [[position, until], ...] most recent last


func init(def: Dictionary, rng: RandomNumberGenerator) -> void:
	var diet := str(def.get("diet", "prey"))
	var base: Dictionary = BY_DIET.get(diet, BY_DIET.prey).duplicate()
	base.merge(def.get("mind", {}), true)
	# no two animals quite alike
	bold = clampf(float(base.bold) + rng.randf_range(-0.1, 0.1), 0.0, 1.0)
	curious = clampf(float(base.curious) + rng.randf_range(-0.1, 0.1), 0.0, 1.0)
	aggressive = clampf(float(base.aggressive) + rng.randf_range(-0.1, 0.1), 0.0, 1.0)
	memory_s = float(base.get("memory", 600.0))
	hunger_rate = 1.0 / float(base.get("hunger_s", 480.0 if diet == "predator" else 300.0))
	thirst_rate = 1.0 / float(base.get("thirst_s", 420.0))
	hunger = rng.randf_range(0.1, 0.5)
	thirst = rng.randf_range(0.0, 0.5)
	fatigue = rng.randf_range(0.0, 0.3)


## One think step. `running`: moving at more than a brisk walk; `state` names what it is doing.
func update(dt: float, state: int, running: bool, grazing_animal: bool) -> void:
	var S := Animal.State
	# hunger: herbivores eat while grazing; predators only at a kill (eat())
	if grazing_animal and state == S.GRAZE:
		hunger = maxf(hunger - dt / 45.0, 0.0)
	else:
		hunger = minf(hunger + hunger_rate * dt, 1.0)
	if state == S.DRINK:
		thirst = maxf(thirst - dt / 18.0, 0.0)
	else:
		thirst = minf(thirst + thirst_rate * dt, 1.0)
	# fatigue: a sprint tires quickly, a day on the move slowly; rest and standing still restore it
	if running:
		fatigue = minf(fatigue + dt / 35.0, 1.0)
	elif state == S.REST:
		fatigue = maxf(fatigue - dt / 60.0, 0.0)
	elif state in [S.IDLE, S.GRAZE, S.DRINK, S.FEED]:
		fatigue = maxf(fatigue - dt / 240.0, 0.0)
	else:
		fatigue = minf(fatigue + dt / 900.0, 1.0)
	# fear fades in quiet: a bold animal calms down faster
	fear = maxf(fear - dt * (0.04 + 0.06 * bold), 0.0)


func eat() -> void:
	hunger = 0.0


## Something frightening: `amount` before temperament (a bold animal is shaken less).
func scare(amount: float) -> void:
	fear = minf(fear + amount * (1.15 - bold), 1.0)


## Wounded. By the player: remembered for `memory_s`. Either way the spot becomes a danger spot.
func hurt(at: Vector3, by_player: bool, now: float) -> void:
	scare(0.6)
	if by_player:
		grudge_until = now + memory_s
	remember_danger(at, now)


func remember_danger(at: Vector3, now: float) -> void:
	for spot: Array in danger:
		if (spot[0] as Vector3).distance_to(at) < DANGER_RADIUS * 0.5:
			spot[1] = now + memory_s
			return
	danger.append([at, now + memory_s])
	if danger.size() > DANGER_SPOTS:
		danger.pop_front()


func remembers_player(now: float) -> bool:
	return now < grudge_until


## A grudge that turns into attack: an aggressive animal comes for whoever hurt it.
func wants_revenge(now: float) -> bool:
	return remembers_player(now) and aggressive >= 0.5


func near_danger(pos: Vector3, now: float) -> bool:
	for spot: Array in danger:
		if now < float(spot[1]) and (spot[0] as Vector3).distance_to(pos) < DANGER_RADIUS:
			return true
	return false


## Awareness of the player at which the animal stops what it is doing. Fear and a bad memory make it jumpier,
## curiosity lets it watch a little longer before reacting.
func alert_threshold(base: float, now: float) -> float:
	var t := base * lerpf(1.25, 0.55, fear) * lerpf(1.1, 0.9, 1.0 - curious)
	if remembers_player(now) and aggressive < 0.5:
		t *= 0.6
	return clampf(t, 0.08, 0.95)


## Running speed factor: a tired animal can't keep up a sprint.
func stamina() -> float:
	return lerpf(1.0, 0.62, smoothstep(0.35, 1.0, fatigue))


func summary() -> String:
	return "hunger %.2f thirst %.2f fatigue %.2f fear %.2f | bold %.2f curious %.2f aggressive %.2f%s" % [
		hunger, thirst, fatigue, fear, bold, curious, aggressive, " | grudge" if grudge_until > 0.0 else ""]
