# Bobb — guida e stato di implementazione

Bobb comprende codice, interfaccia Liquid Glass, logo nero con occhiali rivolti in alto a sinistra e [licenza source-available](../LICENSE). I moduli Swift sono `BobbApp` e `BobbCore`, il daemon è `bobbd`, il bundle ID è `com.bobb.app` e i dati risiedono in `~/Library/Application Support/Bobb`. Le funzionalità desiderate e le priorità sono in [FEATURES.md](FEATURES.md).

| Area | Implementazione |
|---|---|
| Qualsiasi app | Scoperta automatica delle app installate, esclusioni facoltative; driver AX, menu, tastiera, cursore, apertura e doppio clic; OCR locale opzionale con bersagli riletti e conferma per ogni clic |
| Confini | Esclusioni e permessi per app; otto tipi di azione; da solo/chiedi/mai; fasce orarie; regole a parole che possono solo restringere |
| App dell’utente | Browser abituale, profili e accessi esistenti; riutilizzo delle app già aperte, senza browser di test |
| Incarichi permanenti | SQLite, orari locali e ora legale, eventi osservati, deduplicazione, stato e heartbeat |
| Progetti | Obiettivo, profilo, sotto-attività rivedibili, checkpoint e resoconti trasferiti alla fase successiva |
| Routine | Suggerimenti dopo tre esecuzioni completate della stessa richiesta, in giorni diversi con giorno settimanale e orario simili; attivazione esplicita |
| Modelli locali | Solo inferenza locale: Qwen3.5 4B a 4 bit per i testi e Kev 4B a 8 bit per le decisioni; checkpoint di generazione MLX selezionabile e suggerimenti prudenti secondo la RAM |
| iPhone e voce | Chat iMessage con se stessi; riconoscimento locale dei comandi; risposte a voce solo per le conversazioni avviate al microfono sul Mac |
| Più Bobb | Nome, carattere e profilo; incarichi separati; browser e desktop condividono lo schermo e lavorano uno alla volta; singolo connettore serializzato |
| MCP | Server stdio configurati esplicitamente, strumenti scoperti, argomenti visibili prima dell’approvazione |
| Mac virtuale | Installazione da IPSW locale, disco separato, avvio/finestra/arresto; controllo attraverso endpoint MCP nel guest via SSH |

## Primo avvio

Il primo avvio mostra solo l’icona nella barra dei menu. Concedi i permessi macOS quando servono. Le app installate sono disponibili automaticamente: nei Confini puoi escludere app e scegliere le azioni che può fare da solo. Bobb usa il browser indicato nella richiesta o quello attivo quando apri la barra dei comandi; altrimenti usa il browser predefinito di macOS. Riutilizza la sessione e gli accessi esistenti, senza un profilo separato. Con più profili del browser, la destinazione dell’apertura dipende dalle impostazioni del browser stesso. Invio, pagamenti, eliminazione, pubblicazione, impostazioni ed esecuzione chiedono conferma di default. La lettura dei pixel parte disattivata e richiede Registrazione schermo.

Per un incarico ricorrente abilita anche il lavoro in background. Il Mac deve restare acceso, sveglio e con la sessione disponibile. Sui Mac con fino a 16 GB di RAM si esegue un solo incarico in background alla volta; gli altri restano in coda. Bobb scopre le app senza avviarle tutte: apre quelle necessarie al lavoro. Il lavoro su giorni è salvato; dopo un arresto, una fase già iniziata viene indicata come interrotta e si riprende solo con un nuovo tentativo esplicito. Il tentativo conserva il resoconto precedente e riceve un nuovo identificatore di audit.

Browser e desktop condividono una sola sessione di lavoro anche sui Mac più grandi. Gli incarichi in background cedono quando torni a usare il Mac. Al termine Bobb lascia aperte le app e le schede usate. Per dettagli tecnici e verifiche vedi [ADR-012](ADR-012-user-applications.md).

## Per te: iniziative dal contesto

La pagina iniziale **Per te** raccoglie suggerimenti dal contesto, impegni,
suggerimenti mail/chat, routine e lavori bloccati. Con osservazione, memoria
locale e “Suggerisci prossimi passi dalle mie app” attivi, Bobb analizza al
massimo un nuovo contesto ogni cinque minuti. Propone una preparazione quando
riconosce una richiesta aperta, un’informazione mancante o un errore concreto.
Mostra la fonte e una citazione letterale; puoi preparare, rinviare di un’ora o
rifiutare. La preparazione resta una risposta testuale e non avvia azioni nelle app.

Le iniziative scadono dopo 24 ore. Tre rifiuti espliciti sospendono i suggerimenti
dal contesto di quell’app; puoi azzerare questa regola in **Cosa ho imparato**.
L’apprendimento delle routine e quello della soglia per mail/chat restano separati.
Cancellare la fonte o escludere l’app rimuove i suggerimenti derivati. Non serve
attivare Background, che riguarda l’esecuzione degli incarichi configurati.

Sono inferenze fallibili dal testo osservato: non conoscenza completa della tua
vita, consulenza professionale o comprensione universale di ogni applicazione.
La [revisione del prodotto](PRODUCT-REVIEW-2026-10-01.md) riporta le verifiche.

## iMessage da iPhone

Sul Mac configura Messaggi con il tuo account, concedi a Bobb Accesso completo al disco e Automazione di Messaggi, verifica che Messaggi non sia esclusa e inserisci il tuo indirizzo esatto. Attiva la lettura della chat con te stesso. La prima attivazione stabilisce una baseline: i vecchi messaggi non diventano comandi.

Scrivi nella chat con te stesso: `/bobb la tua domanda`, `/bobb status`, oppure `/bobb run https://sito.example il tuo incarico`. Le risposte rispettano la regola di invio di Messaggi e, se chiedono, attendono approvazione sul Mac. Nessun server di relay.

Per parlare con Bobb sul Mac usa il pulsante microfono nella barra dei comandi o la scorciatoia vocale. Solo la risposta a quella richiesta viene letta a voce. Chiudere la conversazione, premere Stop o iniziare a scrivere interrompe l’audio e impedisce la lettura di risposte tardive. Le richieste scritte, i suggerimenti, i resoconti degli incarichi e i messaggi da iPhone restano silenziosi, anche mentre è in corso una conversazione vocale. Il microfono non si riattiva automaticamente.

## Mac virtuale

Richiede Apple silicon, almeno 24 GB di RAM, spazio per un disco sparso da 64 GB e un IPSW macOS compatibile scelto da te. La rete del guest parte spenta e non ci sono cartelle condivise.

Installa Bobb in `/Applications` dentro il guest. Concedi Accessibilità e configura lì app, esecuzione e Confini. Abilita esplicitamente rete e Login remoto quando vuoi collegarlo. Configura una chiave SSH dedicata e verifica di persona l’impronta dell’host nella tua configurazione SSH. Nella pagina Computer del Mac principale inserisci IPv4 privato, account e chiave; collega Mac virtuale. Il client usa StrictHostKeyChecking, senza inoltro dell’agent, credenziali o porte.

Assegna un incarico al connettore `virtual-mac`. L’endpoint `BobbApp --mcp-guest` offre osservazione e una sola azione su bersagli correnti, con nonce consumato prima dell’effetto. Valgono entrambi i livelli di Confini. Un’azione che chiede nel guest resta bloccata: rivedi la categoria nel guest. Nessun token del modello può sostituire il permesso.

## Verifica e limiti

CI verifica Swift su macOS e Linux, daemon, specialist, strumenti e pacchetto DMG. I test coprono confini, oscuramento, contratti, calendario/DST, persistenza, concorrenza, retry e bersagli visuali. Le schermate sono renderizzate dalle viste reali in italiano e inglese, tema chiaro e scuro.

iMessage con un account reale, installazione IPSW, SSH nel guest e checkpoint locali grandi richiedono prove sul Mac. Le app senza controlli o testo leggibile possono richiedere intervento. La qualità dei modelli locali e l’affidabilità dei singoli flussi richiedono valutazioni sul campo. La visibilità pubblica del repository richiede un’operazione amministrativa GitHub separata.

## Mac consumer e inferenza locale

Il riferimento di prodotto è un MacBook Air M4 con 16 GB di RAM. Qwen3.5 4B a 4 bit e Kev 4B a 8 bit sono condivisi tra i Bobb. Kev sostituisce il vecchio classificatore NumPy nel runtime del prodotto. Il primo avvio mostra solo l’icona nella barra dei menu; i modelli si preparano in background e i permessi macOS vengono richiesti quando servono. Le raccomandazioni di modelli più grandi lasciano spazio a macOS, contesto e app dell’utente. Non ci sono endpoint di inferenza remoti, impostazioni cloud o chiavi API per il modello. Il download iniziale dei pesi richiede la rete; siti, Messaggi e connettori opzionali usano i propri servizi di rete. Le prestazioni complete sul MacBook Air di riferimento devono ancora essere misurate.
