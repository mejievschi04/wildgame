# NPC-urile umanoide din The Forest

Notițe de referință pentru WILDBOUND. Analiza se bazează pe o inspecție statică a instalării locale, pe portofoliul unui artist Endnight și pe declarații publice ale echipei. Pașii pentru WILDBOUND sunt în [planul de implementare](HUMAN_NPCS_IMPLEMENTATION_PLAN.md).

## Ce arată instalarea locală

Instalarea analizată se află la `C:\Program Files (x86)\The Forest`. Datele din `TheForest32_Data` indică Unity 5.6.5p4. Numărătorile provin din fișierele Unity, iar comportamentele de mai jos au fost identificate în metadatele și apelurile din `Managed/Assembly-CSharp.dll`.

| Componentă | Observație |
| --- | --- |
| Corp | Mesh-ul masculin principal analizat are 9.657 de triunghiuri, iar cel feminin are 10.407. Mesh-urile corespondente cu nume `LOW` au 2.811 și 3.046. Aceste cifre sunt pentru corpuri individuale. |
| Variații vizuale | Sunt prezente modele masculine, feminine și variante slabe, păr separat și accesorii pentru lideri. Materialele și texturile includ variante pentru piele palidă, vopsea, sânge și arsuri. |
| Animații de deplasare | În `maleMutantController` au fost identificate 307 nume distincte de clipuri. Exemplele includ porniri din repaus spre stânga și dreapta, opriri din alergare, întoarceri de 180°, intrări în ghemuire și pași laterali. Variantele slabe au clipuri proprii. |
| Luptă | Controlerul face referire la atacuri de pe loc și din alergare, eschive cu contraatac, reacții direcționale la lovituri și împiedicări. Clasa `enemyAnimEvents` expune metode pentru activarea și dezactivarea armei, sunetele de pas și de atac și verificarea paradei. |
| Navigație și privire | `mutantAI.SearchPath` apelează `Seeker.StartPath`, iar `OnPathComplete` transmite rezultatul către PlayMaker. `mutantAnimatorControl.OnAnimatorIK` setează ținta și ponderea privirii. |
| Comportament de grup | `mutantFamilyFunctions` are evenimente pentru semnalarea țintei, apărarea unui aliat, ambuscadă și retragere. |

Numărul de clipuri descrie referințele din controler. Frecvența cu care apar în joc, pragurile LOD și ferestrele exacte de contact necesită o probă în joc sau analiza suplimentară a datelor.

## Ce a confirmat echipa Endnight

- Lukas Patrus a refăcut texturile inamicilor principali folosind modelele pe care le primise. Portofoliul său descrie și fluxul general de lucru cu sculptură în ZBrush, baking în Marmoset și texturare în Substance Painter. [The Forest – Enemies](https://broetchaen.artstation.com/projects/d1ADK)
- Ben Falcone descrie personaje care simulează un atac, se retrag și continuă să urmărească jucătorul de la distanță. Reacțiile variate au fost o alegere de design. [Interviu cu Ben Falcone](https://www.gameskinny.com/culture/interview-endlight-games-ben-falcone-talks-to-gameskinny-about-the-forest/)
- Endnight a corectat cazuri în care inamicii aplicau daune fără animație și cazuri în care o lovitură făcea daune de două ori. [Notele patch-ului 0.39](https://store.steampowered.com/news/posts/?appids=242760&enddate=1466629588)

## Ce contează pentru WILDBOUND

- **Mersul se vede cel mai bine în tranziții.** Pornirea, frânarea și pivotarea au nevoie de poziții credibile ale tălpilor. Privirea poate preceda întoarcerea corpului. Aceasta este prima ipoteză de testat pe vânătorul nostru.
- **Comportamentul trebuie să se vadă în mișcare.** O oprire la marginea taberei, urmărirea cu privirea și o retragere făcută cu fața spre jucător arată ezitarea înaintea unei decizii. Un atac poate porni din aceeași situație și trebuie să aibă o pregătire recognoscibilă.
- **Detaliul vizual poate veni din față, materiale și siluetă.** Exporturile WILDBOUND au aproximativ 127.900 de triunghiuri pentru `SapiensM` și 92.600 pentru `SapiensF`, înainte de LOD. Părul masculin are aproximativ 38.800, iar corpul de bază are aproximativ 26.800. Comparația relevantă este corp cu corp, iar costul părului și al blănii merită măsurat separat în joc. [SapiensM](../assets/models/humans/SK_Human_SapiensM.gltf) · [SapiensF](../assets/models/humans/SK_Human_SapiensF.gltf)
