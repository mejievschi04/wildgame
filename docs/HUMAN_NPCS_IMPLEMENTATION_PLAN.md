# Plan de lucru pentru NPC-urile umane

Prima livrare propusă este un vânător care îl observă pe jucător, se oprește, pivotează spre el și decide dacă înaintează sau se retrage. Se testează în tabăra existentă, în Godot, din perspectiva jucătorului. [Observațiile despre The Forest](HUMAN_NPCS_THE_FOREST_NOTES.md)

## Punctul de plecare

- Triburile înarmate folosesc variante bazate pe `SapiensM` și `SapiensF`. Mersul și alergarea urmăresc viteza de deplasare, iar jocul corectează decalajul orizontal din exporturile de mocap. Vânătorul poate face pași laterali și ocoli local un obstacol. [HumanNPC](../world/human_npc.gd)
- Atacul existent are gardă, pregătire, împunsătură și revenire. La extensie se verifică segmentul activ al vârfului suliței și obstacolele. Testele acoperă dauna unică și eschiva laterală după ce atacul s-a angajat. [Generatorul Blender](../tools/blender/bake_human_combat.py) · [Testele triburilor](../tests/test_tribes.gd)
- Lipsesc clipurile dedicate pentru porniri, opriri și pivotări. NPC-ul are o ocolire reactivă la coliziune, iar deplasarea dintre obiective urmează direcția directă. [Deplasarea NPC-ului](../world/human_npc.gd)

## 1. Mers și întâlnire în tabără

1. Înregistrează o probă înainte de schimbări cu un vânător care merge drept, ocolește focul și îl observă pe jucător. Repetă cu jucătorul frontal și apoi lateral.
2. Creează clipuri originale pentru pornirea mersului, oprirea din mers, oprirea din alergare și pivotarea la 90° în ambele direcții. Adaugă întoarcerea de 180° dacă proba arată că oprirea urmată de pivotul scurt este insuficientă.
3. În Godot, selectează clipurile de tranziție după viteza orizontală reală, viteza cerută și unghiul spre țintă. Pornește deplasarea odată cu pasul, frânează pe piciorul de sprijin și păstrează aceeași fază a pașilor când se schimbă viteza în mers.
4. Leagă stările de vigilență și avertizare de secvența din tabără. Vânătorul se oprește, își orientează întâi privirea, apoi trunchiul și picioarele. Alege dacă păstrează distanța, înaintează sau se retrage în funcție de reacția și poziția jucătorului.
5. Dacă ocolirea locală cedează la două obstacole succesive, testează un `NavigationAgent3D` într-o singură tabără, cu focul, corturile și palisada incluse în trasee. [Documentația Godot pentru NavigationAgent3D](https://docs.godotengine.org/en/stable/classes/class_navigationagent3d.html)

**Probă de acceptare.** La oprire și pivot, piciorul de sprijin rămâne aproape fix în lume. Vânătorul trece pe lângă foc și rămâne orientat spre jucător când se retrage.

## 2. Atac și reacții

1. Adaugă o împunsătură din pas și o fentă care se termină prin retragere. Calibrează pasul și extensia suliței împreună, din perspectiva jucătorului.
2. Folosește momentul de contact definit de fiecare clip pentru a declanșa verificarea vârfului. Păstrează o singură aplicare de daune per atac. Fenta folosește pregătirea și retragerea fără moment de contact.
3. Adaugă reacții scurte la lovituri din stânga și dreapta. O paradă sau o lovitură care întrerupe atacul consumă atacul curent și trece imediat în reacția potrivită.
4. Compară cadrele de pregătire, extensie și revenire la distanța reală de luptă. Verifică atacul de pe loc și cel din pas pe ambele rig-uri.

**Probă de acceptare.** Pregătirea se citește din prima persoană. O eschivă după angajarea împunsăturii, o paradă și un obstacol opresc dauna. O lovitură confirmată se aplică o singură dată.

## 3. Față, siluetă și cost de randare

1. Construiește un vânător de referință în Blender pe rig-ul Sapiens. Dă-i o față și o siluetă proprie. Lucrează expresia neutră, pleoapele și ochii, materialul pielii, forma mantiei și felul în care se prind accesoriile.
2. Verifică materialele și silueta în Godot înainte să multiplici personajul. Creează variante de piele, păr și echipament pe baza rezultatului, păstrând compatibilitatea cu rig-ul și animațiile comune.
3. Simplifică întâi părul, barba și blana prin variante cu mai puține carduri pentru distanță. Măsoară costul în aceeași scenă cu un singur NPC și cu toată tabăra în cadru. Folosește măsurarea pentru a stabili limitele de LOD.
4. Verifică vânătorul la aproximativ 2 și 10 metri, în lumină de zi și lângă foc. Urmărește lizibilitatea ochilor, conturul costumului și trecerea dintre nivelurile de detaliu. [Fluxul de lucru Blender Studio](https://studio.blender.org/training/realistic-human-research/)

## Verificare la reluare

- Rulează suitele `tribes` și `combat`. Verifică atât rezumatul, cât și eventualele mesaje `SCRIPT ERROR`. [Runnerul de teste](../tests/run_tests.sh) · [Testele de luptă](../tests/test_combat.gd)
- Compară capturile înainte și după în aceeași tabără, cu aceeași cameră și aceeași lumină. Pentru mers și atac, înregistrează secvența completă de la observare până la revenire.
- Folosește modele, materiale și animații originale sau cu licență compatibilă și notează proveniența resurselor externe. [Creditele proiectului](ASSET_CREDITS.md)
