> Historical Bobb document. For current Bobb capabilities, licensing and setup, see [BOBB.md](BOBB.md) and the [README](../README.md).

# Cosa manca

Stato al 28 settembre 2026, branch `claude/bobb-marketplace-product-g77orn`.
Questo file elenca con onestà tutto quello che non è finito, non è verificato o
non esiste ancora. Si parte dal lavoro interrotto ("Bobb deve saper usare
qualsiasi app, non solo quelle di messaggistica"), poi viene il resto.

---

## 1. Lavoro interrotto: usare qualsiasi app

### Cosa è già nel commit

**Motore (`bobbd`) — fatto e coperto da test (tutti i test Python passano)**

- Due nuove operazioni oltre a CLICK, TYPE, SCROLL, OPEN_APP, WAIT, DONE, BLOCKED:
  - `KEY`: preme un tasto o una scorciatoia scelta da un vocabolario chiuso di
    22 voci (`agent.KEYS`: Invio, Tab, Esc, frecce, Spazio, Cancella, ⌘A/C/V/X/Z/S/N/T/F/L/W, ⌘Invio).
    Il modello sceglie un nome, mai testo libero, quindi non può comporre un comando.
  - `OPEN`: apre un elemento come un doppio clic (file in Finder, brano, foto, voce di lista).
- **Testo della finestra (`screen_text`)**: il frame `observe` può portare il
  testo della finestra. Un estratto mirato (`screen_excerpt`) entra nel contesto
  di ogni passo. Chi scrive il testo da digitare ne riceve fino a 3000 caratteri,
  così nelle celle, nei moduli e nel codice usa i dati veri.
- **Risposta finale**: a ogni passo il modello indica anche se la richiesta
  chiedeva di scoprire qualcosa. Se il passo è DONE, genera 1-3 frasi con la
  risposta presa dallo schermo, e il testo viaggia nel campo `text` del frame `act`.
- **Domande sulla finestra aperta**: il frame `ask` accetta `screen`, cioè il
  testo della finestra in primo piano. `compose.for_request` risponde prima da
  quello, poi dalla memoria. Esempi: "in che mese ho speso di più?" su un foglio
  aperto, "cosa fa questa funzione?", "riassumi questo documento".
- Candidati con stato `selected`. Le procedure apprese sanno leggere i passi KEY e OPEN.
- **Banco di prova su tutte le categorie di app** (`bobbd/bobbd/task_eval.py`):
  - 39 passi realistici: file, fogli di calcolo, documenti, browser, moduli web,
    codice, terminale, note, calendario, promemoria, contatti, Impostazioni di
    Sistema, visori, musica, presentazioni, foto, mappe, mail, finestre di
    dialogo, menu a tendina aperti, copia/incolla tra app, app lette dai pixel;
  - 14 richieste da smistare tra "fai" e "rispondi";
  - lo strumento `bobbd/tools/task_reference_eval.py` li esegue con i pesi veri
    sul motore CPU di riferimento;
  - un test controlla che il banco sia valido.

**App — nucleo `BobbCore`, scritto ma NON compilato**

- `Agent/Keys.swift`: `KeyChord`, con codici tasto macOS, simboli (↩ ⇥ esc ⌘S…) e tasti offerti per app.
- `ActOperation.open` e `.key`. `TaskObserveFrame` porta `screen_text` e `keys`. `AgentCandidate.selected`.
- `UIElementSnapshot.cursor` ("dove si trova il cursore": cella selezionata,
  editor, canvas, terminale). Ruolo `AXVisualText` per le parole lette dai
  pixel. Voci di menu aperti, con bonus di ranking.
- **Motore dei permessi** (`ActionPolicy`):
  - Impostazioni di Sistema non è più vietata del tutto: chiede a ogni singolo
    passo e senza "consenti sempre";
  - i pannelli Privacy, Sicurezza, Utenti, Password, Login, FileVault, Firewall,
    Profili, Condivisione, Account restano vietati;
  - Invio chiede conferma nei terminali e nelle app di messaggi, e quando il
    pulsante predefinito della finestra fa qualcosa di serio (Elimina, Invia…);
  - ⌘W chiede conferma;
  - aprire un programma o un installer (.app, .pkg, .dmg, .sh…) chiede conferma;
  - un tasto sconosciuto è negato.
- `TaskLoop`:
  - invia testo della finestra e tasti;
  - il digest tiene conto anche del testo, così un passo che cambia solo una cella non risulta "bloccato";
  - risolve KEY solo se il tasto era tra quelli offerti;
  - risolve OPEN;
  - salva la risposta finale in `TaskRunState.report`;
  - blocca con motivo `unreadable` quando la finestra non si può leggere.
- `TaskPanel.describe` gestisce i due nuovi casi. È l'unica modifica nel target app.

### Cosa NON è fatto (in ordine di lavoro)

1. **Compilare e far passare la CI.** Le modifiche Swift non sono mai state
   compilate. Vanno eseguiti `swift build` e `swift test` su BobbCore (Linux)
   e poi controllata la CI macOS. È probabile qualche errore da correggere.
2. **`AXDriver` (target app): la parte che agisce davvero.**
   - `perform(.key)`: CGEvent con il `keyCode` e i flag ⌘/⇧ di `KeyChord`.
   - `perform(.open)`: azione `AXOpen` se c'è, altrimenti doppio clic sul frame vivo.
   - **Cursore**: dopo il walk, se l'elemento con il focus non è già un campo
     offerto, va aggiunto un candidato `cursor: true`. Titolo: "Where the cursor
     is — cell B14" o "— in “utils.py”". Per questi candidati la digitazione deve
     essere a tasti Unicode (`keyboardSetUnicodeString`) e non incolla, perché
     Numbers ed Excel trattino `=SUM(…)` come formula.
   - **Sicurezza di `type()`**: oggi fa ⌘A prima di incollare anche nelle aree
     multi-riga vuote. In editor come VS Code il valore accessibile può sembrare
     vuoto e ⌘A selezionerebbe tutto il file. Va fatto ⌘A solo nei campi a una riga.
   - **Menu aperti**: il walk non scende nei figli dei pulsanti, quindi le voci
     di un menu a tendina aperto sono invisibili. Vanno aggiunte le voci
     `AXMenu` figlie di `AXPopUpButton`/`AXMenuButton`/`AXComboBox` e i menu
     contestuali figli dell'app (solo con frame visibile), con contesto "open menu".
   - **Testo della finestra**: riusare `WindowReader.read` in background. Va
     saltato se la finestra è privata (`ScreenMemoryPolicy.mayRead`).
   - **Pulsante predefinito**: leggere `AXDefaultButton` della finestra e metterlo in `defaultButton`.
   - **Ripiego sui pixel**: se la finestra dà meno di 3 controlli con un nome,
     e l'utente ha attivato "Leggi il testo nelle immagini" con il permesso di
     registrazione schermo:
     - leggere il testo con Vision tenendo le coordinate (`boundingBox` convertito in coordinate schermo);
     - offrire le parole come candidati `AXVisualText`;
     - prima di cliccare, rileggere quella zona e cliccare solo se il testo c'è ancora.

     Se il permesso manca, impostare `unreadable = true`.
3. **Pannello attività (`TaskPanel`)**:
   - domanda di permesso per KEY e OPEN (oggi cade su "Premere…");
   - testi L10n per i motivi `closes` e `settings`;
   - nascondere "Consenti sempre" quando il motivo è `settings`;
   - mostrare `task.report` con un pulsante Copia;
   - spiegare `unreadable` con un pulsante che apre Impostazioni › Leggi il testo nelle immagini.
4. **Command bar**: `AskFrame` deve avere il campo `screen`. All'apertura va
   letto il testo della finestra in primo piano, prima che Bobb prenda il
   focus, e inviato con la domanda.
5. **Contratto e fixture**: aggiornare `docs/CONTRACT.md` (observe `screen_text`/`keys`, act KEY/OPEN,
   testo su DONE, ask `screen`), `bobbd/tools/export_contract_fixtures.py`,
   `ContractFixtureTests` Swift.
6. **Test Swift nuovi** (`AgentTests`):
   - policy su tasti, apertura ed Impostazioni;
   - risoluzione di KEY e rifiuto di tasti non offerti;
   - cursore e menu aperti nel ranking;
   - digest che cambia con il testo;
   - report salvato su DONE.
7. **Dimostrazioni ("Mostrami come")**: `DemonstrationWatcher` registra clic e
   digitazione ma non i tasti né i doppi clic. Va esteso a KEY e OPEN.
8. **Misurare sul modello vero**: eseguire
   `PYTHONPATH=. uv run --no-sync python -u tools/task_reference_eval.py` in `bobbd/`
   (40-60 minuti su CPU). Poi:
   - pubblicare i numeri per famiglia di app, che oggi non esistono;
   - correggere i prompt dove sbaglia;
   - decidere se servono domande per famiglia di app.

   Non ho ancora nessun numero su quanto il modello da 3B sappia usare le app fuori da mail e chat.
9. **Interfaccia e documenti**:
   - esempi nella command bar e nell'onboarding presi da tutti i tipi di lavoro,
     non solo messaggi (Finder, fogli, documenti, codice, impostazioni);
   - ADR-009 ("qualsiasi app: tasti, apertura, menu aperti, cursore, testo della finestra, ripiego sui pixel");
   - aggiornare ARCHITECTURE, README, CHANGELOG e la checklist di `LAUNCH.md` con prove su più app.

### Cosa manca ancora per "qualsiasi app" anche dopo il punto 1

- **Trascinare** (drag & drop): per esempio un file in una cartella o un blocco su un canvas.
- **Valori regolabili**: slider, stepper, selettori di data (volume, luminosità, zoom).
- **Clic destro**: aprire un menu contestuale su un elemento, cioè l'azione `AXShowMenu`.
- **Barra dei menu di sistema**: Centro di Controllo, menu extra, Dock, Spotlight,
  notifiche. Oggi Bobb legge solo l'app in primo piano.
- **Più finestre, Spazi e schermo intero**: scegliere la finestra giusta quando l'app ne ha più di una.
- **Pagine web molto lunghe**: il walk si ferma a 2600 nodi e 0,7 s, quindi
  parte della pagina resta invisibile e va raggiunta scorrendo.
- **Più monitor e Retina**: coordinate del ripiego sui pixel da verificare.
- **Metodi di input e lingue non latine**: digitazione con IME (cinese, giapponese) non gestita.
- **Aiuto proattivo fuori da mail, chat e calendario**: per esempio proporre
  "finisco io" quando l'utente inizia una procedura che Bobb ha già imparato.
- **Più tasti nel vocabolario**: Pagina su/giù, Inizio/Fine, ⌘⇧ vari, tasti
  funzione. Il vocabolario è chiuso di proposito: ogni aggiunta va fatta anche
  nella policy.

---

## 2. Da verificare su un Mac vero (mai fatto)

Nessuna persona ha ancora usato Bobb su un Mac vero. In particolare:

- installazione dal DMG, primo avvio, download del modello, onboarding;
- permessi di macOS: Accessibilità, Automazione Mail, Calendari, Microfono e
  Riconoscimento vocale, Registrazione schermo;
- mail e chat reali (Mail, Messaggi, Slack, WhatsApp, Telegram), bozze inserite davvero;
- attività su app vere: nessuna è stata eseguita da capo a fine su un Mac;
- voce: la dettatura sul dispositivo va scaricata da Impostazioni di Sistema;
- lettura del testo nelle immagini (Vision) su finestre vere;
- latenze reali su Apple silicon: tutti i numeri di velocità della 1.0 sono da misurare;
- consumo di memoria e batteria con il modello sempre caricato;
- checklist in 14 punti di `docs/LAUNCH.md`.

## 3. Limiti noti del prodotto

- **Modello da 3B per le azioni**: affidabilità non dimostrata fuori dai test.
  È costruito per fermarsi invece di tirare a indovinare, quindi aspettati
  molti "non sono abbastanza sicuro".
- **Specialista personale (Tier 0)**: si attiva solo dopo almeno 30 risposte
  dell'utente e solo se batte il modello generale.
- **Promesse**: lette solo dalla casella "Inviata" di Mail; le chat non sono ancora incluse.
- **Riassunti prima delle riunioni**: solo dai calendari di EventKit (Calendario
  di macOS e account aggiunti lì).
- **Lingue**: interfaccia e regole scritte a mano solo in italiano e inglese.
- **Nessun aggiornamento automatico dell'app**: "Controlla aggiornamenti" apre
  la pagina delle release nel browser (ADR-005). Aggiornamento in-app, per
  esempio con Sparkle, non integrato.
- **Nessuna telemetria né report di crash automatici**, per scelta: tutto
  locale. Esiste "Esporta diagnosi" nelle Impostazioni, che crea uno zip che
  l'utente può inviare. Manca il canale per riceverlo (supporto).

## 4. Lancio e business (da fare dal proprietario)

Dettagli in `docs/LAUNCH.md` e `docs/DEPLOYMENT.md`.

- Apple Developer ID, firma e notarizzazione vere (oggi il DMG è firmato ad-hoc).
- Chiave di licenza di produzione e deploy del worker Cloudflare delle licenze.
- Negozio e pagamenti.
- Società, termini d'uso, privacy policy e supporto.
- Nome, marchio, dominio.
- Canale di distribuzione: nessuna landing page, per scelta. Va deciso dove si scarica.
