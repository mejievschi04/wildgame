# Copacii și tăierea lor în The Forest și WILDBOUND

Analiza combină inspecția statică a instalării locale The Forest, notele publice Endnight și probe rulate în Godot pe WILDBOUND. Prima scenă de lucru propusă este tăierea și secționarea aninului `tree_birch_005`, care folosește modelul `SM_Alder_01`.

## Ce am observat în The Forest

- În `TheForest32_Data/resources.assets` sunt variante de trunchi, cioate, bucăți tăiate și niveluri de detaliu pentru mai mulți pini și arțari. Codul `TreeCutChunk.Hit` activează piese premodelate. Endnight a ajustat modelele tăiate ca forma și scoarța lor să se îmbine cu arborele intact. [Notele v0.57](https://store.steampowered.com/news/posts/?appids=242760&enddate=1490648482)
- Codul `treeDealDamage` verifică în cădere contacte cu jucători, animale, inamici și construcții. `AFSTreeCutVariation` transmite viteza și rotația din timpul căderii către material, pentru deformarea vizuală. Endnight a documentat orientarea căderii după ultima lovitură și daunele la contact. [Notele v0.18](https://endnightgames.com/updates/v018-patch-update)
- După cădere, sistemul trece la bușteni fizici. În WILDBOUND, trunchiul rămâne disponibil pentru secționare cu toporul și fiecare buștean se desprinde separat. Această etapă merită păstrată ca parte a jocului. [Notele v0.18](https://endnightgames.com/updates/v018-destructible-buildings-controller-support-more-world-opened-and-much-more?page=3) · [Secționarea în WILDBOUND](../world/tree_node.gd)

## Ce am confirmat în WILDBOUND

Copacii folosesc mesh-uri procedurale, texturi de scoarță și carduri de frunziș. Crestătura se reconstruiește în geometria trunchiului măsurat din model. Fluxul include așchii, rumeguș, un scârțâit înaintea căderii, apoi cioată și bușteni fizici. [Generatorul de copaci](../tools/blender/gen_trees.py) · [Logica arborelui](../world/tree_node.gd) · [Buștenii fizici](../world/log_piece.gd)

| Problemă | Probă |
| --- | --- |
| Lovitura și crestătura pot indica locuri diferite | Prima lovitură fixează înălțimea și direcția tăieturii. O lovitură din partea opusă a adâncit aceeași crestătură de la aproximativ 6 la 12 cm și a păstrat direcția inițială. Lovitura se rezolvă la capătul animației, pe baza razei camerei. [Lovitura jucătorului](../player/player.gd) |
| Dauna la cădere folosește proiecția pe sol | Verificarea se face la aterizare, după distanța în plan a jucătorului față de trunchi. În probă, jucătorul poziționat la 12 m deasupra bazei a pierdut 45 HP la aterizare. [Calculul impactului](../world/tree_node.gd) |
| La prima secționare, mesh-ul rămâne la aceeași lungime | Pe aninul `tree_birch_005`, bușteanul s-a desprins și cilindrul de coliziune a scăzut de la aproximativ 9,46 la 7,10 m. Lungimea locală a mesh-ului de scoarță a rămas aproximativ 4,06 înainte și după. [Modelul testat](../assets/models/trees/SM_Alder_01.gltf) · [Testele copacilor](../tests/test_trees.gd) |

La această verificare au trecut **4 din 5 teste pentru copaci**. A eșuat aserțiunea `bucking shortens the trunk` din `test_buck_clear_regrow_and_save`. [Testele copacilor](../tests/test_trees.gd)

## Ordinea propusă pentru corecții

1. **Contactul și crestătura.** Măsoară contactul folosind traseul tăișului în timpul loviturii. Folosește același punct pentru crestătură, așchii, rumeguș și sunet. Ca primă variantă, o lovitură în afara crestăturii existente lasă o urmă superficială, iar loviturile care ating crestătura o adâncesc. Leagă direcția căderii de tăietura activă.
2. **Căderea în 3D.** Urmărește volumul trunchiului între pozițiile succesive ale căderii. Verifică o singură aplicare de daune per țintă, cu teste la nivelul solului și la altă înălțime. Pe pantă, verifică unde ating solul baza, mijlocul și coroana. Evaluează separat interacțiunile cu animale și construcții.
3. **Secționarea.** Folosește aceeași poziție de tăiere pentru capătul trunchiului, coliziune și capătul bușteanului desprins. Verifică întâi filtrarea ramurilor și reconstrucția mesh-ului pe `SM_Alder_01`. După fiecare lovitură acceptată, mesh-ul și coliziunea trunchiului se scurtează împreună.
4. **Finisajul vizual.** Compară scoarța deasupra și sub tăietură, fibra expusă și marginea cioatei. Adaugă o întârziere ușoară în mișcarea coroanei față de trunchi, păstrând punctul de contact urmărit în proba de la sol.

## Verificare la reluare

- Repetă ciclul complet în prima persoană pe aninul din test, apoi pe un pin. Include lovituri din două părți, cădere pe teren drept și pe pantă și secționare până la cioată.
- Verifică salvarea și reîncărcarea unei crestături parțiale și a unui trunchi cu bușteni rămași. Rulează suita `trees` și urmărește atât aserțiunile, cât și mesajele `SCRIPT ERROR`. [Runnerul de teste](../tests/run_tests.sh)
- Pentru cadre comparabile, folosește scenariile AutoShot `notch`, `chop` și `felled`. [Scenariile AutoShot](../game/auto_shot.gd)
