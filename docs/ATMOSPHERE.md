# Atmosfera lumii — analiză și primul pas

De ce WILDBOUND arăta palid și fără viață, comparat cu The Forest și Far Cry Primal, și ce s-a schimbat.
Capturile de verificare se fac cu `godot --path . res://scenes/game.tscn -- --autoshot=/abs/out.png --shot-hour=10`
(și `--shot-hour=6.6`, `18.6`, `--shot-scenario=river`, `--shot-scenario=camp --shot-hour=21.3`).

## Ce creează atmosfera în cele două jocuri

| | The Forest (Unity 5) | Far Cry Primal (Dunia) |
|---|---|---|
| Lumină | Soare cald, filtrat prin coroane; umbre adânci, ocluzie ambientală puternică | Soare auriu, umbre reci: contrast cald/rece („teal & orange”) |
| Cer și distanță | Ceață colorată de cer, groasă dimineața; raze de lumină | Cer albastru adânc; ceață de înălțime în văi; perspectivă aeriană albastră |
| Culoare | Gradare cu verzi bogați, negri adânci | LUT cu saturație ridicată în verzi și galbeni |
| Sol | Ferigi, iarbă, frunze uscate, bușteni: nicăieri pământ gol | Pajiști dese, flori sălbatice, petice verzi și uscate |
| Aer | Particule în raze, insecte | Polen, licurici, frunze, păsări |
| Timp | Răsărit și apus dramatice | „Golden hour” lung, nopți albastre |

## Ce avea WILDBOUND (cauzele aspectului palid)

- Saturația era redusă intenționat (`adjustment_saturation = 0.92`), iar curba AgX era neutră și plată.
- Cerul la orizont era gri (0.72, 0.77, 0.78), iar ceața și perspectiva aeriană luau acest gri: dealurile deveneau bej-cenușii.
- Ceața de zi și ceața volumetrică erau dense și albicioase (un văl lăptos peste tot).
- Textura scanată de iarbă e de fapt pământ uscat, bej: de departe lumea părea deșert.
- Iarba 3D: smocuri rare (0,9/m²) de 500 de triunghiuri fiecare. Nu se putea îndesi.
- Lumina de apus apărea doar foarte aproape de orizont: la 18:30 arăta ca la prânz.
- Aerul era gol: fără polen, insecte sau licurici.

## Ce s-a schimbat (pasul 1)

- **Gradare** (`day_night.gd`): AgX cu contrast 1,45, saturație 1,16, contrast 1,06 și un **LUT 3D generat în cod**
  (`_grade_lut`): umbrele trag spre albastru-verzui, luminile spre cald, iar verzii-gălbui devin verzi proaspeți, puțin mai saturați.
- **Cer și ceață**: albastru adânc sus, albastru pal la orizont (niciodată gri); ceața ia culoarea cerului; densitatea
  de zi e înjumătățită; ceața strălucește cald spre soare (`fog_sun_scatter`); golden hour mai lung (`dusk_k`).
- **Teren** (`terrain.gdshader`): stratul de iarbă păstrează detaliul scanat (luminozitatea), dar primește culoare de
  pajiște, verde cu petice uscate pe zone mari (același zgomot colorează și firele de iarbă). Malurile noroioase rămân
  pământii, nu portocalii.
- **Gazon dens** (`meadow_grass.gd`, `meadow_grass.gdshader`): smocuri de 12 fire subțiri (36 de triunghiuri) pe o grilă care
  se mută odată cu camera în shader. Iarba stă exact pe teren (aceeași interpolare ca `height_at`) și se mișcă în vânt
  (direcția și tăria vin din vreme). Lipsește în apă, pe stânci abrupte, sub pădure, la foc și la construcții. Flori
  sălbatice în pâlcuri (galbene, albe, mov, albastre, portocalii). LOD: de la ~40 % din rază, două treimi din fire dispar.
- **Aer** (`atmosphere_fx.gd`): polen și praf în lumina zilei; licurici seara (20–23:30) pe vreme senină.

Performanță (fereastra AutoShot, calitate medie, M4): **48 FPS înainte → 51,5 FPS acum**. Gradarea și ceața mai ușoară
au câștigat ~7 FPS; gazonul costă ~4. `--bench-off=meadow,fx` le dezactivează pentru măsurători.

## Pasul 2: păduri, cer, apă, sol (2026-11-23)

- **Păduri până la orizont** (`far_forest.gd`): copacii reali se încarcă doar pe ~150 m, de aceea dealurile erau goale.
  La pornire, fiecare model de copac e fotografiat o singură dată (viewport ascuns, nelit) într-un **impostor**: două
  plane încrucișate, 4 triunghiuri. Impostorii sunt plasați pe toată harta după densitatea pe regiuni și masca de
  pădure, grupați în crânguri (zgomot), în bucăți de 256 m, fără umbre. Sub 165 m dispar (shader), iar acolo stau
  copacii reali. Pozițiile se calculează pe un thread. În modul headless (teste) nu se generează.
- **Coroane** (`foliage.gdshader`): umbrite ca un volum moale (normale dinspre axa trunchiului), interior și parte
  inferioară mai întunecate, verde mai adânc. Gata cu frunzele galben-pale în soare.
- **Solul pădurii**: litieră brună și petice de mușchi, nu nisip portocaliu; un al treilea strat GPU cu frunze arcuite
  joase (ferigă, rogoz) sub copaci; dincolo de raza ierbii, terenul e mai verde, iar pădurile sunt în umbra coroanelor.
- **Cer** (`sky.gdshader`): gradient, disc și halo de soare, nori fractali care se mișcă după vânt, cu margini argintii
  spre soare, baze gri-albastre și culori aurii la apus. Acoperirea vine din vreme (`DayNight.cloud_cover`).
- **Apă** (`water.gdshader`): reflexie clară a cerului (Fresnel, rugozitate mică); fundul văzut prin apă trece prin
  emisie (nu mai e luminat de două ori, de aceea apa era cenușie); turcoaz la mică adâncime, albastru-verde închis la
  adâncime; spumă animată la mal.

FPS (fereastra AutoShot, calitate medie): la start ~51 (ca înainte de ambii pași), la apus ~43, în pădurea densă
Tavren ~30 (la fel ca înainte: zona e scumpă din cauza copacilor reali). `--bench-off=far` / `meadow` / `fx` pentru
măsurători, `SHOT_AT=x,z,yaw` și `SHOT_PITCH` pentru capturi oriunde pe hartă.

## Pasul 3: vegetație și pietre, spre imaginea-țintă (2026-11-23)

Ținta e `Downloads/scopjoc.png` (pajiște deasă, ferigi, pietre cu mușchi în râu, munți, pădure deasă). Pași: 1) vegetație
și pietre (acesta), 2) munți în fundal, 3) pădure deasă, 4) râu de munte, 5) păsări și mâna la persoana întâi.

- **Iarbă din carduri pictate** (`tools/blender/gen_grass_atlas.py` → `assets/textures/vegetation/T_GrassCards_D.png`):
  4 smocuri generate procedural (pajiște, iarbă înaltă cu spice, smoc uscat, smoc înflorit cu flori mov, albe și
  galbene), fiecare cu sute de fire subțiri. `grass_cards.gdshader` le desenează ca 3 carduri încrucișate (6
  triunghiuri) pe grila care se mută cu camera. Shaderul alege smocul după zone: flori în pâlcuri, iarbă înaltă în fâșii,
  smocuri uscate pe zonele uscate. De departe rămâne un singur card din trei. Vechile smocuri geometrice și vechea iarbă
  de 500 de triunghiuri au fost scoase.
- **Gazonul de sub iarbă**: aproape de cameră, terenul de sub smocuri e verde-închis, deci golurile par umbra ierbii,
  nu pământ. Terenul e mat (rugozitate ≥ 0,85): textura scanată reflecta cerul și părea gri-albăstruie.
- **Cerul nu mai luminează solul cu discul soarelui**: soarele e desenat doar pe cerul vizibil, nu și în cubemap-ul
  de lumină ambientală (`AT_CUBEMAP_PASS`).
- **Pietre** (`Vegetation._place_rocks`): grupuri de bolovani cu mușchi (scanări Poly Haven) pe pajiști și în pădure,
  cu coliziune la cei mari; pietre pe maluri și în apa mică. RNG propriu, deci salvările nu se schimbă.
- **Ferigi**: de 2,3 ori mai multe, mai mari, și la marginea pajiștilor; verde mai închis (nu mai sunt verde-lămâie).

FPS: start ~46, râu ~47, Meyra ~51, Tavren ~32 (înainte: 51 / 55 / 49 / 30).

## Pasul 4: granițele lumii — munți la nord, vulcani la sud (2026-11-23)

- **`world/backdrop.gd` + `backdrop.gdshader`**: un inel de relief în afara hărții jucabile, până la ±11 km. O singură
  plasă de înălțimi: celule de 40 m până la 3,8 km, apoi tot mai mari. Se calculează pe un thread la pornire și nu se
  generează în modul headless (teste).
  - **Nord**: lanț înalt de 1,5–2,6 km (zgomot „ridged”, deformat), cu păduri de conifere la poale, stâncă de granit
    peste ~950 m și zăpadă peste ~1 250 m. Zăpada nu rămâne pe pereții abrupți.
  - **Est/vest**: dealuri împădurite de 250–900 m; spre nord au vârfuri înzăpezite.
  - **Sud**: câmpie vulcanică joasă și 4 vulcani (1,1–2,7 km), cu cratere, ravene radiale, bazalt negru și cenușă
    ruginie. Lava lucește în dungi pe ravene și în crater, mai ales noaptea.
- **Fum** (`volcano_smoke.gdshader`): coloană de cenușă care se lărgește și se înclină după vânt, mai deasă la vulcanul
  mare și slabă la al doilea. Noaptea e luminată în roșu de jos.
- **Ceață proprie**: partea razei din interiorul hărții folosește densitatea ceții scenei, deci se potrivește cu
  terenul la margine; dincolo de margine aerul e mai limpede (≤ 0,00012), iar vârfurile sunt deasupra stratului gros.
  Ceața de zi a scenei a scăzut la 0,0002, deci se vede la kilometri.
- Marginea hărții urcă lin (≈60 m), nu mai e un perete de 290 m. Camera vede până la 14 km, iar luna și stelele au fost
  mutate la 13 km (altfel apăreau în fața munților).

FPS: neschimbat (start ~45, sud ~43, noaptea 60).

## Pasul 5: munți realiști cu eroziune (2026-11-23)

- **`tools/gen_backdrop.py`** (rulează cu Python-ul din Blender, ~13 s): relieful granițelor e copt offline. Forme
  din zgomot „ridged multifractal” cu domeniu deformat; apoi **2,5 milioane de picături de apă simulate** sapă ravene,
  ascut crestele și depun sediment în conuri și pe fundul văilor; o trecere termică rotunjește acele prea ascuțite.
  Ieșiri: `assets/textures/backdrop/T_Backdrop_HM.png` (înălțime 16 biți, curgerea apei, sediment) și `T_Backdrop_N.png`
  (normale și ocluzie ambientală), 1024² pe 22 km (~21 m/texel).
- **Shader nou** (`backdrop.gdshader`):
  - normale per texel, deci fiecare ravenă și creastă prinde lumina;
  - **umbre reale de relief**: fiecare pixel caută spre soare pe harta de înălțimi, iar crestele umbresc văile;
    la apus vârfurile se aprind rozaliu, iar văile rămân în umbră;
  - pădure de conifere care urcă mai sus pe ravene, pajiște alpină, granit stratificat cu stâncă scanată de aproape,
    pereți abrupți mai întunecați, conuri de grohotiș și zăpadă pe terase și în culoare (spulberată de pe pereții abrupți);
  - pe vulcani lava curge pe ravenele de sub crater; ceața se adună în văi dimineața.
- `backdrop.gd` citește relieful copt, îl așază pe înălțimile marginii hărții și pune fumul pe craterul real.

## Pasul 6: păduri în crânguri și performanță (2026-11-23)

- **Crânguri** (`FarForest.grove_at`, câmp comun): pădurea îndepărtată și copacii reali din apropiere folosesc
  același zgomot, deci pâlcurile de pe dealuri continuă exact în jurul jucătorului. `Vegetation._place_groves` adaugă
  copaci reali (care se pot tăia) în crânguri: o treime molizi printre foioase, copaci mai mici la margine și trunchiuri
  căzute (cu coliziune). Au RNG propriu și ID-uri `_grove_`, deci copacii existenți și salvările nu se schimbă.
  Impostorii îndepărtați sunt mai deși în crânguri, iar pădurea îndepărtată e grupată în bucăți de 640 m (mai puține apeluri).
- **Probleme de performanță găsite și rezolvate** (cauzate de camera de 14 km din pasul 4):
  - luminile focurilor din toate taberele și bazele își randau umbrele (de 6 ori scena, inclusiv terenul) din orice
    distanță: 14 milioane de triunghiuri pe cadru. Acum se estompează după 110 m (umbrele după 45 m);
  - obiectele de joc (resurse, construcții, tabere, POI) primesc automat o distanță de vizibilitate de 600 m
    (`ForestWorld._limit_view_distance`, grupul `far_scenery` e exceptat: teren, apă, munți, pădure îndepărtată);
  - iarba: fără alpha-to-coverage (nu ajută cu TAA), rază 20 m la calitate medie.
- FPS (calitate medie): start 46 → 50, Meyra 34 → 45, râu ~53, Tavren ~30.
- Unealta de capturi: `SHOT_HIDE=Nod1,Nod2` ascunde copii ai lumii; raportul arată `objects`/`prims`/`draw_calls`.

## Pasul 7: pădure compactă, sol de pădure, copaci încărcați pe măsură ce mergi (2026-11-23)

- **Încărcare treptată** (`Vegetation._stream_near(pos, immediate)`): în joc, bucățile noi de pădure intră într-o
  coadă și se construiesc câte una pe cadru, cea mai apropiată prima, deci nu mai apare o sacadare când intri în zone
  noi. Copacii reali se încarcă pe o rază de 2 bucăți (~96–170 m, înainte 3); dincolo de 95 m preiau copacii-imagine.
  `_stream_near(pos)` fără al doilea argument rămâne imediat (pornire, teleportări, teste).
- **Copaci mai mari și mai deși**: ×1,2 în regiunile rare sau medii (`Vegetation.tree_scale`), neschimbați în pădurile
  deja dese (Tavren), unde coroanele mai mari costau ~4 FPS. Crângurile completează densitatea până la ~0,012 copaci/m².
- **Pădure compactă la distanță**: impostori fotografiați la 512 px, mult mai deși în crânguri (coroanele se ating),
  vizibili până la 1,5 km (calitate medie). Câmpul de crânguri e copiat într-o textură (`FarForest.grove_image`) pentru
  teren: sub crânguri apare sol de pădure, iar dincolo de impostori solul ia culoarea verde-închisă a coroanelor.
  Nu există crânguri în valea de start.
- **Sol de pădure**: al doilea strat de carduri (`T_ForestCards_D`: ferigă, rogoz, afin, puiet de molid) sub copaci și
  în crânguri, cu humus întunecat între plante; iarba de pajiște nu mai crește în crânguri.

FPS (calitate medie): start ~54, Meyra ~45, râu ~46, Tavren ~29.

## Următorii pași propuși

1. **Pădurea de aproape**: copacii reali sunt așezați uniform; grupați în pâlcuri, cu tufișuri și bușteni căzuți.
   (Pozițiile lor intră în salvări, deci schimbarea are nevoie de migrare.)
2. **Umbre de nori** pe teren, care se mișcă odată cu norii.
3. **Malurile apei**: trestie, pietre, nămol umed.
4. **Variație de biom**: pajiști cu flori la sud, mesteacăn și ferigă la est, stepă rece cu iarbă înaltă uscată la nord.
5. **Păsări și sunete**: stoluri pe cer, păsări care zboară din iarbă, ciripit care se schimbă cu ora din zi.
6. **Raze de lumină** prin coroane în pădure, cu ceață volumetrică locală în pădurile dese.
