# Animal voices

Drop recordings here; the game finds them at start-up (no code changes). Name them

    <species>_<event>[_NN].wav|ogg|mp3        e.g. wolf_howl_01.ogg, wolf_howl_02.ogg, mammoth_stamp.wav

Several files for the same species and event are played at random. `any_<event>` (e.g. `any_hurt.wav`) is used
for every species that has no file of its own.

Species: deer, roe, reindeer, megaloceros, horse, boar, hare, fox, wolf, lion, bear, rhino, bison, mammoth.

| event  | when                                                                  | heard up to |
|--------|-----------------------------------------------------------------------|-------------|
| howl   | wolves at night (the pack leader starts, the others join in)          | 400 m       |
| roar   | lion and bear warning an intruder                                     | 250 m       |
| call   | herds now and then while grazing (deer bellow, reindeer grunt, mammoth rumble) | 90 m |
| alarm  | the prey animal that spots danger, as the herd bolts                  | 80 m        |
| stamp  | mammoth, bison, rhino, boar warning before a charge (stamp, snort, trumpet) | 45 m  |
| growl  | wolves warning someone off their kill                                 | 35 m        |
| attack | a bite or a charge                                                    | 40 m        |
| hurt   | when wounded                                                          | 50 m        |
| death  | when killed                                                           | 50 m        |
| eat    | predators feeding at a kill                                           | 15 m        |

Without a recording nothing plays, but the loud events still show a subtitle when subtitles are on.
Licensing: CC0, public domain, CC-BY (credit in docs/ASSET_CREDITS.md), bought sounds, or a short cut from the Sonniss GDC bundle. Sonniss files stay inside the game and are not shipped again as a sound library.
