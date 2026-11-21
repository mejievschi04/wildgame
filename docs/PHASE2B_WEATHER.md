# Phase 2b — basic weather

| Aspect | Implementation (`world/weather.gd`) |
|---|---|
| States | clear, cloudy, fog, rain, storm, cold snap — seeded Markov chain, 2–6 game hours each (storms 1–2.5 h), smooth 90 s blending; saved/loaded |
| Visuals | noise cloud cover on the sky, dimmer/greyer light, extra fog, GPU rain that stops on roofs (heightfield collision following the camera), wet/darker glossy ground, wind on all foliage (global shader uniforms) |
| Temperature | weather offset (+1.5 … −7 °C) + wind chill when exposed (up to −3.5 °C) |
| Wetness | rain soaks the player in ~1.5 min; wet clothing keeps only 40 % insulation and adds −4 °C; dries slowly, fast by a fire; HUD shows «Промок» |
| Shelter | roofed rooms and lean-tos block rain (raycast up + shelter volume) |
| Fires | exposed fires burn 4× faster in a storm (status line warns) |
| Drying rack | pauses while rained on |
| Sleep | not possible in the rain without a roof |
| Storms | damage built pieces (~3 HP per storm hour) → repair with materials |
| Journal | first rain adds a hint entry |

Tests: `tests/test_weather.gd` (5): determinism, wetness/drying, exposed vs sheltered fire + sleep rule, storm damage, persistence.
Known limits: no snow accumulation, no lightning, no seasonal climate yet; rain sound is a procedural placeholder.
