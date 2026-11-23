# Phase 3b — people & tribes (GDD §7, Act II)

## People (Blender + MPFB)
`tools/blender/gen_humans.py` builds 5 NPC bodies with the MPFB (MakeHuman) add-on — M1/M2/M3 (men, one older),
F1/F2 (women, one older) — with the UE-style `game_engine` rig. Macro morphs are baked; helper geometry removed
(eyes kept). Clothing is **cut from body regions** (tunic with a flared hem, leggings, foot wraps), relaxed to hide
anatomy, thickened, textured with the scanned leather; a hair/hood shell on the crown and nape, beards on some men.
Clips (rotations authored in armature space): idle, walk, run, alert, gesture (open palm), attack (spear thrust),
sit (by the fire), death. ~58k tris each (Godot generates LODs). Armed NPCs carry the spear item model on `hand_r`.

## Tribes (`data/factions.json`, `world/factions.gd`)
| Faction | Temper | Start | Camp | Wants (offering value) | Gives (barter) |
|---|---|---|---|---|---|
| Nomad hunters | wary, armed | 0 | east (92, 62) | flint, hide, wood, stone | dried meat, spear, bandage |
| Territorial clan | territorial (34 m), armed | −15 | north-west, palisade | cooked/dried meat, hide | flint, knife, torch |
| Gatherers | peaceful, unarmed | +20 | south (−35, 78) | sticks, fibre, raw meat, flint | berries, cooked mushrooms, bandage, waterskin |

Relation −100…+100 → stance: hostile ≤ −40 < wary < 10 ≤ neutral < 50 ≤ friendly. Saved with the world.

## Behaviour (`world/human_npc.gd`)
- Perception only: sight (range × player visibility, 210° FOV, line of sight), hearing (player noise); they see your gesture.
- Routine: idle / sit by the fire / patrol / gather around camp.
- Noticed player → SUSPICIOUS → INVESTIGATE, by temper:
  - gatherers greet (open palm) or flee; never fight;
  - hunters keep distance (WARN when wary and close), greet when neutral+, fight when hostile;
  - clan: inside their territory → **WARN** (caption: shout + "leave" gesture); ignored for 6 s while close → trust −12 and **COMBAT**.
- Combat: spear thrust with 0.55 s wind-up, 18 dmg + bleed chance; give up after 25 s / 35 m / when you leave the territory;
  flee when below 40 % health. Attacking one rallies armed kin within 40 m (gatherers flee). Kills: −60 trust; the dead stay dead.

## Diplomacy (no shared language)
- **T — open-palm gesture**: if seen within 25 m, +4 trust (once per 45 s per tribe), calms warnings.
- **E — offering**: give the item they value most that you carry → trust + value.
- **R — barter** (trust ≥ 10): give one wanted item, receive one of their goods.
- Sleep is refused next to wary/hostile armed strangers or while a predator hunts you.
- Journal: an entry per tribe when first met; meeting all three opens Act II ("Три народа").

## Tests
`tests/test_tribes.gd` (7): camps & fires, clan warn → attack, gesture rate-limit + offering + barter, rally/flee on
aggression, NPC spear hit, discovery journal + sleep safety, persistence of relations/discoveries/deaths.

## Limitations
- NPC hands hold the spear rigidly; carried food/sticks are held in the left hand without a grip pose.
- Pathfinding covers the camps and bases only (NpcNav); hunting trips steer directly with local avoidance.
- Barter is one-for-one and does not draw from the camp's stock yet; no quests yet (Act II goal: find where your group went).

## Hominin races (concept sheet) — step 1: Homo sapiens (2026-11-22)
The six races follow the user's concept sheet: Heidelbergensis, Neanderthal, Homo sapiens, Denisovan,
Homo erectus and "Homo antiquus". The player is Homo sapiens. Generator: `tools/blender/gen_hominins.py -- SapiensM SapiensF`,
about 60 s per model. It reuses the rig, clips and severable parts from `gen_humans.py`.
- Body: MPFB macros + species morph targets; **5 facial-expression blend shapes** (`expr_focused`, `expr_angry`,
  `expr_surprised`, `expr_pain`, `expr_happy`) mixed from MakeHuman expression units.
- Skin is baked on the MakeHuman UVs: mottling, pores, forehead wrinkles by age, dirt on hands and feet, lips and eyelids (from MPFB masks),
  eyebrows, the concept's white face paint, and a hair-coloured scalp and beard base under the strands.
- Eyes: spheres with a generated iris texture (sclera, iris streaks, limbal ring, pupil).
- Hair and beard are strand cards on a thin-strand atlas. They hug the scalp down to ear level, then fall and collide with the body and
  clothes (BVH), and are kept off the face. Their weights blend from the head to the body under the strand.
- Clothing per the concept: fur mantle (or one-shoulder fur for women), crossed leather straps, belt and wrist wraps as
  surface ribbons, slit hide kilt/skirt with a jagged hem, a hide top for women, fur boots, and a cord necklace with teeth. Fur garments carry fur cards.
- In game: the gatherers tribe is now Homo sapiens (`SapiensF`, `SapiensM`). NPC strand cards use the shared fur-card
  material path (alpha scissor, no shadows); skin gets subsurface scattering.
- Preview: `tools/blender/preview_face.py` (expression sheet), web bestiary "Oameni" section.
- Budget: M ≈ 124k tris including hair and fur cards (body + clothes ≈ 47k), F ≈ 89k. That's above the sheet's 25–40k; a hair-card LOD
  pass is the follow-up.

## Hominin races — step 2: Neanderthal (2026-11-23)
`gen_hominins.py -- NeanderthalM NeanderthalF`. Short, very robust, barrel chest (macros + torso/neck morphs); heavy brow
ridge, sloping forehead, long low skull, broad projecting nose and midface, weak chin. Lighter skin, reddish-brown hair,
full beard, red-ochre smear on the cheekbones (no white paint). Heavier furs per the concept: the mantle drops lower and
hangs down the back as a cape; women wear a fur collar over both shoulders; tall fur boots. New spec options shared by
all races: `mantle_drop`, `mantle_back`, `female_mantle`, `boot_h`, `fur_len`, `face_depth` / `front_sweep` (keeps hair off
a sloping forehead). Budget (before the hair pass below): M ≈ 137k tris, F ≈ 107k.
In game the **clan** (and the regional garrisons) are Neanderthals: variants `NM1–NM3`, `NF1–NF2` in `HumanNPC.BODY_STYLES`.

## NPC AI v2 — a day in camp, beasts, fighting together, movement (2026-11-23)
New clips, baked onto the shipped rigs by `bake_human_combat.py` (no mesh rebuild): `combat/feint`, `combat/throw`
(release frame 17), `combat/hit_l`, `combat/hit_r`, and a `life` library — `sleep` (on the side, breathing), `work`
(squat and pick at the ground), `step` (stepping on the spot while the body pivots). All four hominin models have both.

**Camp life** (`TribeGroup`, one per camp / active base): by the clock — night 22:00–5:30 everyone sleeps around the
hearth except one watch (garrisons: every other guard); morning and evening by the fire (sit, talk, tend the fire); by
day the temper's plan: gatherers forage → pick (`work`) → carry it to the store (`DELIVER`, the camp's `stock` grows);
hunters work, patrol, talk; the clan patrols its edge. Kin tend a wounded member (`TEND`: +35 hp, stops bleeding).
**Hunting party**: once a day two armed hunters walk 50–85 m out, search, stalk prey (prey now notices people within
10 m), throw and thrust, butcher the kill (8 s), pick their thrown spears back up and carry the meat to the store.

**Beasts**: armed people fight predators that come close or go for one of them — kin within 25 m join; lions and bears
only when three or more armed are near, otherwise everyone runs to the fire (beasts fear it). Charging defensive
animals are avoided. Predators (wolves, cats) on a hungry day or at night go for a person alone and away from the fire;
their bites hurt NPCs; spears hurt animals, which fight back.

**Fighting together**: each fighter gets a slot around the foe, spread evenly; only two hold attack tokens and close
in, the rest circle on their slot and sometimes fake a lunge. A raised guard draws a **feint**; a spear is **thrown**
from 6–15 m (one spare each); a blow during the wind-up spoils the attack and plays a directional hit reaction; the
group falls back when half of its fighters on that foe are badly hurt.

**Movement**: `NpcNav` bakes a navigation mesh (terrain + every collider's footprint + the fire) around each camp and
active base on a worker thread; people path around fires, shelters and palisades. Head and neck turn toward what the
person attends to (foe, stranger, partner, next path point) before the body (`LookAtModifier3D`, about ±80°);
turning on the spot plays `life/step`; walking speeds build up and run down over a step or two.

Screenshots: `--shot-scenario=tribe` (clan lineup; `SHOT_ANIM=life/sleep`, `SHOT_DIST`, `SHOT_TURN`) and
`--shot-scenario=tribelife` (a camp from outside, `SHOT_CAMP=hunters|clan|gatherers`, with `--shot-hour`).
Tests: `tests/test_npc_ai.gd` (12).

## Hair & look pass (2026-11-23)
The strand-card hair (tens of thousands of thin cards, spring-simulated) read as a messy mop that stuck out sideways in
game. Hair is now built like game hair:
- **Hair cap**: the scalp faces of the body pushed out into a thin shell (thicker toward the crown and back), UV'd so its
  tileable strand texture combs away from the face and thins out into wisps at the hairline. Rigid on the head.
- **Locks**: a few dozen wide clump cards (`clump_atlas`: many fine strands gathering into a lock, solid core, wispy edges)
  rooted on the back and sides of the cap, falling straight down over the neck, back and shoulders (collision with the
  body, cap and clothes; kept off the face). They follow head → back through their skin weights; no spring chains.
- **Beard**: the same cap on the beard area (thicker toward the chin) plus short locks under the chin.
- **Fur garments**: a textured pelt (`pelt_material`, soft combed tufts) with a sparse layer of short, fine tufts instead
  of dense spiky cards.
- Skin is lighter (less AO darkening, lighter base tones); the Neanderthal is taller (≈ a head shorter than Sapiens
  rather than chest height) with a softer nose and less sunken eyes; a lighter, shorter mantle.

- **Stance**: the MPFB rest pose stands in an A (ankles ~10 cm outside the hips, ~6° per leg) and every procedural clip
  kept it. `human_anim.stance_fix` swings each thigh in about the forward axis (foot turned back to stay flat) so the
  ankle sits ~2 cm outside the hip; combat/life poses place the feet with `stance_x`. Mocap walk/run were already
  correct. Test: `test_legs_stand_under_the_hips`.

Budget now: Sapiens M ≈ 63k tris, F ≈ 56k, Neanderthal M ≈ 66k, F ≈ 62k (body + clothes ≈ 47k of that). Hair + beard ≈ 3–6k.
