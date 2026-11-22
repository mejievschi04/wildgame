# Generarea lumii și optimizarea în The Forest și WILDBOUND

Analiza se bazează pe instalarea locală The Forest, pe codul WILDBOUND și pe măsurători separate pentru construcția lumii, trecerile dintre celule și randare. Prima prioritate propusă este reducerea pauzelor produse de vegetație în timpul deplasării.

## Ce am verificat în The Forest

- Instalarea conține o scenă principală `ForestMain_v08` și un obiect Unity `TerrainData`, plus scene separate pentru peșteri, decor și zonele de final. În resurse sunt prezente mesh-uri de copaci cu mai multe niveluri de detaliu și variante billboard.
- În `TheForest32_Data/Managed/Assembly-CSharp.dll`, `WorkScheduler` grupează lucrul pe celule și măsoară un buget în milisecunde. `LOD_Base.ThreadedRefresh` calculează decizii LOD, iar `MainThreadRefresh` aplică schimbarea. `TreeLodGrid` folosește densitatea copacilor din celulele din jur și vizibilitatea estimată pe direcții pentru a ajusta distanța de afișare.
- Ideea aplicabilă în WILDBOUND este să programezi munca după poziția jucătorului, să pregătești datele în paralel și să limitezi aplicarea schimbărilor pe firul principal.

## Cum funcționează WILDBOUND acum

- Zona jucabilă are 4 × 4 km, în interiorul unui teren de 4,2 × 4,2 km. Șapte regiuni, zgomot procedural, forme de relief definite în cod și un seed fix dau o distribuție deterministă. Grila de 10 m are 177.241 de vârfuri și 352.800 de triunghiuri într-un mesh global. Coliziunea pornește din același mesh, iar `height_at()` interpolează aceleași triunghiuri. [Generarea terenului](../world/forest_world.gd)
- Meniul principal și sesiunea de joc creează fiecare un `ForestWorld`. Terenul, resursele din vale și prima fereastră de vegetație se construiesc în timpul inițializării. Imaginea hărții se calculează într-un worker și are cache pe disc. Deschiderea devreme a hărții poate aștepta finalizarea lucrării pe firul principal. [Meniul](../game/main_menu_root.gd) · [Sesiunea de joc](../game/game_session.gd) · [Cache-ul hărții](../world/map_data.gd)
- Vegetația folosește până la 49 de celule de 48 m. Iarba și ferigile sunt grupate în `MultiMesh`, iar copacii interactivi au noduri și coliziuni proprii. Importul modelelor de copaci generează deja LOD-uri. La schimbarea celulei, cele necesare se construiesc în același apel sincron. Celulele care ies din fereastră se desprind, iar resursele modificate sunt mutate sub rădăcina permanentă a lumii ca să își continue simularea. [Vegetația](../world/vegetation.gd) · [Încărcarea și descărcarea resurselor](../world/forest_world.gd) · [Exemplu de import LOD](../assets/models/trees/SM_Pine_01.gltf.import)

## Măsurători de referință

Probele CPU au rulat headless. Timpul de streaming măsoară apelul sincron la schimbarea poziției, cu aceeași lume și același seed. El include construcția și desprinderea imediată a celulelor, iar eliberarea programată cu `queue_free()` poate continua după apel.

| Probă CPU | Rezultat |
| --- | --- |
| Pornirea lumii | 9,7–9,8 s. Terenul a luat aproximativ 6 s. |
| Etapele principale ale terenului | 2,1 s pentru grila de înălțimi, 1,1 s pentru vârfuri și indici, 0,7 s pentru tangente, 1,8 s pentru coliziune. |
| Trecere la est din vale | 7 celule noi, 125–136 ms pe firul principal. |
| Trecere pe diagonală în vale | 13 celule noi, 308–336 ms pe firul principal. |
| Intrare directă în Tavren la `(-1000, -1200)` | 49 de celule noi, 0,9–1,0 s. În acea fereastră erau 1.569 de copaci interactivi și peste 34.000 de noduri în scenă. |

Proba grafică a folosit o cameră fixă în Tavren, GTX 1060, Vulkan Forward+, presetul Medium și viewportul raportat de 576 × 324. Fiecare variantă a avut 40 de cadre de încălzire și 65 măsurate. Rezultatele servesc la comparația dintre variantele acelui cadru.

| Variantă în Tavren | Mediană | p95 | Apeluri de desen pe cadru |
| --- | ---: | ---: | ---: |
| Referință | 6,8 ms | 9,1 ms | 279 |
| Fără ceață volumetrică | 6,6 ms | 8,2 ms | 279 |
| Fără umbrele soarelui | 5,2 ms | 8,9 ms | 180 |
| Fără vegetația de sol | 5,7 ms | 7,9 ms | 259 |
| Cu arborii ascunși | 4,4 ms | 7,8 ms | 168 |
| Referință repetată | 6,7 ms | 9,1 ms | 279 |

În `AutoShot._apply_bench()`, opțiunile `grass` și `veg` caută `MultiMeshInstance3D` doar printre copiii direcți ai nodului `Vegetation`. Loturile se află în interiorul celulelor. Proba grafică de mai sus le-a căutat recursiv. Corectează această căutare înainte de a folosi AutoShot pentru comparații de vegetație. [Benchmarkul AutoShot](../game/auto_shot.gd)

## Ordinea propusă pentru implementare

1. **Întinde încărcarea celulelor pe mai multe cadre.** Pune celulele într-o coadă ordonată după distanță. Pregătește pozițiile și transformările din date care pot fi citite în siguranță de worker. Limitează instanțierea, coliziunile și descărcarea pe firul principal la un buget măsurat pe cadru. Prioritizează vecinătatea imediată și păstrează distribuția, ID-urile și starea resurselor la reîncărcare.
2. **Reutilizează terenul generat.** Salvează în cache înălțimile, mesh-ul și datele de coliziune pe baza seed-ului și a versiunii generatorului. Folosește un decor local pentru meniu. Apoi probează terenul împărțit pe sectoare și nivelurile de detaliu, cu aceeași înălțime la margini și coliziune aliniată cu mesh-ul.
3. **Separă copacii apropiați de reprezentarea lor la distanță.** Păstrează nodurile interactive și coliziunile lângă jucător. Testează gruparea, siluetele simplificate și o distanță mai scurtă de umbră pentru copacii îndepărtați. Verifică trecerea din reprezentarea de la distanță în copacul interactiv și conservarea stării după tăiere.

## Verificare la reluare

- Parcurge înainte și după același traseu prin Tavren, pornind în jurul coordonatelor `(-1000, -1200)`. Ține camera, presetul, rezoluția și viteza de deplasare identice. Înregistrează durata fiecărui cadru, p95, p99, cadrul maxim și numărul de cadre peste 33 ms, alături de câte celule se construiesc în fiecare cadru. Separă intrarea directă în regiune de mersul continuu.
- Măsoară pornirea cu cache gol și cu cache populat. Compară separat timpul până la meniu, timpul până la controlul jucătorului și timpul de deschidere a hărții.
- Verifică determinismul, resursele modificate, regenerarea după descărcare și încărcarea unei salvări vechi. După descărcarea și reîncărcarea celulei, același obiect trebuie regăsit la aceeași coordonată, cu starea corespunzătoare timpului simulat. [Testele lumii](../tests/test_world.gd) · [Runnerul de teste](../tests/run_tests.sh)
