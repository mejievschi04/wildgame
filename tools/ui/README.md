# UI art pipeline

Everything the menus draw comes from the game itself or from these scripts. No outside art.

## Textures (`assets/ui/T_UI_*.png`)

```sh
B=/Applications/Blender.app/Contents/MacOS/Blender
$B -b --factory-startup -P tools/ui/render_silhouette.py -- assets/models/animals/SK_Mammoth.gltf /tmp/sil_mammoth.png 90
$B -b --factory-startup -P tools/ui/gen_ui_textures.py -- /tmp/sil_mammoth.png
```

Stroke (9-slice caps 44 px), Slab (40), Hide (84), Cell and Rim (16), Grain, Mammoth, Hunters, Hand.
The margins are the `UITheme.*_EDGE` constants. Change both together.

## Backdrops (`assets/ui/BG_*.jpg`)

These are 1920×1080 stills from the AutoShot `keyart` scenario. It hides the UI and the hands, then places a herd,
a campfire and a lean-to relative to the camera.

```sh
shot() { godot --path . scenes/game.tscn --resolution 1920x1080 -- --autoshot=/tmp/$1.png --shot-frames=220 --shot-scenario=keyart --shot-hour=$2; }
SHOT_HERD="3:22:75;9:28:105;-1:34:85;14:38:100" SHOT_AT="-60,-400,20" SHOT_PITCH=0.0 shot herd 18.7      # BG_Menu_Herd
SHOT_FIRE="0.8:4.0" SHOT_AT="-60,-400,20" SHOT_PITCH=-0.12 shot camp 19.6                            # BG_Load_Camp
SHOT_WEATHER=fog SHOT_AT="-60,-400,200" SHOT_PITCH=-0.04 shot mist 7.2                               # BG_Load_Mist
SHOT_AT="-60,-400,110" SHOT_PITCH=-0.05 shot meadow 16.5                                             # BG_Load_Meadow
sips -s format jpeg -s formatOptions 86 /tmp/herd.png --out assets/ui/BG_Menu_Herd.jpg
```

`SHOT_HERD` is `right:ahead:yaw[:species];…` in metres from the camera.

## Where it is used

- `ui/ui_theme.gd`: the palette, fonts, `stroke_box` / `slab_box` / `hide_box` / `cell_box` / `rim_box`, `icon()`, `keycap()`, `hint()`.
- `ui/primal_backdrop.gd`: an animated still (slow push-in, embers, grain).
- `ui/primal_logo.gd`: the cave frieze, the title and the subtitle.
- `ui/main_menu.gd`, `ui/loading_screen.gd`, `ui/inventory_screen.gd`.
