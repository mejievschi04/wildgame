# Arme, unelte, vânătoare și pescuit în The Forest și WILDBOUND

Analiza se bazează pe fișierele din instalarea locală The Forest și pe codul și probele Godot din WILDBOUND. În The Forest au fost examinate obiectele serializate din `TheForest32_Data/resources.assets` și metadatele și apelurile din `Managed/Assembly-CSharp.dll`. Pentru crestătură și căderea trunchiului există și [analiza copacilor](TREE_FELLING_ANALYSIS.md).

## Ce arată fișierele The Forest

| Sistem | Observație verificată local |
| --- | --- |
| Lovituri și unelte | Sunt prezente clipuri distincte pentru topor sus, jos și la cioată, lovituri grele și împunsături la înălțimi diferite. `treeHitTrigger` urmărește copacul curent, distanța și înălțimea loviturii. `weaponInfo` procesează contactele și diferențiază sunetele și reacțiile după tipul țintei sau suprafeței. |
| Arc și proiectile | Arcurile au controlere dedicate. `ArrowDamage.FixedUpdate` face un raycast în timpul zborului, iar `CheckHit` tratează tipuri diferite de ținte. `arrowStickToTarget` include fixarea săgeții pe articulația apropiată de impact. |
| Vânătoare și jupuire | `animalHealth` gestionează daunele, moartea și indicatorii de rană pe material. Există animație de jupuire și cod care schimbă materialul carcasei și activează interacțiunea cu carnea. |
| Pescuit și capcane | `Fish` are poziție, adâncime de înot și retragere. `FishZone` poate declanșa retragerea la apropiere. Contactul cu sulița apelează `DieSpear`, iar `FindFishNearTrap` caută pești în volumul capcanei. Codul și resursele includ și capcane pentru iepuri. |
| Crafting | `CraftingCog` verifică rețete și aplică îmbunătățiri. Datele și codul conțin atât modificatori de statistici, cât și componente vizuale pentru arme. |

## Starea din WILDBOUND

- **Arme corp la corp.** Există pregătire, lovitură, recul, blocaj și paradă. La impact, `_resolve_swing()` citește raza camerei și obiectul echipat în acel moment. În probă am pornit lovitura cu măciuca și am trecut la topor în timpul pregătirii. Copacul a înregistrat o lovitură, toporul a pierdut un punct de durabilitate și reculul a încercat să animeze modelul vechi, deja eliberat. [Atacul și echiparea](../player/player.gd)
- **Arc și suliță.** Arcul are putere variabilă, săgeată vizibilă pe coardă, consum de muniție și uzură. Săgețile și sulițele folosesc același sistem de zbor. Impactul folosește poziția centrului proiectilului ca aproximare pentru regiunea lovită, după care proiectilul ajunge în starea de obiect recuperabil. [Arcul și aruncarea](../player/player.gd) · [Proiectilele](../world/thrown_spear.gd) · [Modelele la persoana întâi](../player/hand_models.gd)
- **Vânătoare.** Animalele reacționează la vedere, zgomot și miros purtat de vânt. Prada poate alarma turma. Urmele și sângele ajută la urmărire, iar regiunea lovită modifică dauna. După moarte, cuțitul din inventar deblochează tranșarea, care acordă resursele după o interacțiune ținută apăsat. [Animale](../world/animal.gd) · [Urme](../world/tracks.gd) · [Specii și resurse](../data/animals.json)
- **Pescuit.** Cu sulița de pescuit în mână, interacțiunea cu apa durează 2,2 secunde. Fiecare încercare are 50% șansă de pește și consumă un punct de durabilitate. Reușita vine din tragerea la sorți. Testul repetă interacțiunea direct și verifică dacă apare un pește în inventar. [Pescuitul actual](../world/water_body.gd) · [Testul de pescuit](../tests/test_farming.gd)
- **Unelte și hrană.** Secera, bățul de săpat, cuțitele și ciocanul sunt recunoscute prin etichete. Unele cer echiparea, iar altele dau bonus sau permit acțiunea din inventar. Peștele crud poate fi gătit la foc sau folosit într-o rețetă cu oală. [Obiecte](../data/items.json) · [Rețete](../data/recipes.json) · [Resurse](../world/resource_node.gd) · [Culturi](../world/farm_plot.gd) · [Gătit](../world/campfire.gd)

Au trecut **6 teste țintite** pentru vânătoare și tranșare, lovitura cu sulița, lovitura cu arcul, eliberarea corzii după o tragere prea scurtă, pescuit și rețete. Proba separată de schimbare a armei în timpul loviturii a reprodus problema descrisă mai sus. [Testele vânătorii](../tests/test_wildlife.gd) · [Testele pescuitului și rețetelor](../tests/test_farming.gd)

## Ordinea propusă pentru implementare

1. **Fixează unealta la începutul acțiunii.** Leagă animația, profilul de impact și uzura de arma cu care începe lovitura. La schimbarea obiectului înainte de impact, anulează lovitura veche fără daune și curăță animația odată cu modelul vechi. Reprodu cazul măciucă → topor și verifică atât copacul, cât și durabilitatea.
2. **Măsoară contactul tăișului și al vârfului.** Folosește deplasarea dintre pozițiile succesive ale tăișului sau vârfului. Trimite același punct către calculul daunei, reacția țintei, sunet și efecte. Păstrează logica de zbor comună pentru arc și suliță, cu parametrii fiecărui proiectil. Verifică o lovitură, o ratare la limită și o țintă în spatele unui obstacol.
3. **Duce o vânătoare până la capăt.** Folosește un cerb în valea de început. Testează apropierea cu vântul potrivit, lovitura, retragerea animalului, urmărirea urmelor, recuperarea săgeții și tranșarea cu o acțiune vizibilă. Adaugă reaprovizionarea și gătitul în verificare după ce secvența din teren funcționează.
4. **Fă pescuitul fizic într-un singur vad.** Pune câțiva pești vizibili în apă puțin adâncă. Lasă-i să se îndepărteze la apropiere și folosește contactul vârfului suliței pentru captură. Verifică separat ratarea și lovitura reușită, apoi ridicarea și gătitul peștelui. Adaugă o capcană abia după ce aceste probe sunt stabile.
5. **Dă uneltelor acțiuni vizibile acolo unde schimbă rezultatul.** Începe cu cuțitul la tranșare, apoi secera la recoltă și bățul de săpat la rădăcini. Verifică cerința, sunetul, uzura și resursele acordate pentru fiecare acțiune.
