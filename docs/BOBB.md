# Bobb — guida e stato di implementazione

Il passaggio da Leonard comprende codice, interfaccia Liquid Glass, logo nero con occhiali rivolti in alto a sinistra e licenza MIT. Le vecchie cartelle dati e il bundle ID restano compatibili.

| Area | Implementazione |
|---|---|
| Qualsiasi app | Driver AX, menu, tastiera, cursore, apertura e doppio clic; OCR locale opzionale con bersagli riletti e conferma per ogni clic |
| Confini | Elenco esplicito di app e siti; otto tipi di azione; da solo/chiedi/mai; fasce orarie; regole a parole che possono solo restringere |
| Computer proprio | Browser WebKit nascosto per ogni Bobb, cookie separati e finestra apribile |
| Incarichi permanenti | SQLite, orari locali e ora legale, eventi osservati, deduplicazione, stato e heartbeat |
| Progetti | Obiettivo, profilo, sotto-attività rivedibili, checkpoint e resoconti trasferiti alla fase successiva |
| Routine | Suggerimenti dopo tre esecuzioni completate della stessa richiesta, in giorni diversi con giorno settimanale e orario simili; attivazione esplicita |
| Cervello cloud | Spento di default; endpoint HTTPS e modello scelti dall’utente, chiave nel Portachiavi, oscuramento locale, registro della richiesta esatta |
| Modelli locali | Checkpoint MLX locale selezionabile, suggerimenti secondo la RAM; nessun download automatico di modelli grandi |
| iPhone e voce | Chat iMessage con se stessi; riconoscimento locale dei comandi; risposta soggetta ai Confini; sintesi vocale opzionale |
| Più Bobb | Nome, carattere e profilo; incarichi e browser separati; desktop e singolo connettore serializzati |
| MCP | Server stdio configurati esplicitamente, strumenti scoperti, argomenti visibili prima dell’approvazione |
| Mac virtuale | Installazione da IPSW locale, disco separato, avvio/finestra/arresto; controllo attraverso endpoint MCP nel guest via SSH |

## Primo avvio

Crea il tuo Bobb, collega nei Confini solo le app necessarie, scegli le azioni che può fare da solo e abilita l’esecuzione. Per il web collega un dominio oppure Browser di Bobb. Apri il suo browser per accedere ai siti o risolvere richieste di intervento umano. La lettura dei pixel parte disattivata e richiede Registrazione schermo.

Per un incarico ricorrente abilita anche il lavoro in background. Il Mac deve restare acceso, sveglio e con la sessione disponibile. Il lavoro su giorni è salvato; dopo un arresto, una fase già iniziata viene indicata come interrotta e si riprende solo con un nuovo tentativo esplicito. Il tentativo conserva il resoconto precedente e riceve un nuovo identificatore di audit.

## iMessage da iPhone

Sul Mac configura Messaggi con il tuo account, concedi a Bobb Accesso completo al disco e Automazione di Messaggi, collega Messaggi nei Confini e inserisci il tuo indirizzo esatto. Attiva la lettura della chat con te stesso. La prima attivazione stabilisce una baseline: i vecchi messaggi non diventano comandi.

Scrivi nella chat con te stesso: `/bobb la tua domanda`, `/bobb status`, oppure `/bobb run https://sito.example il tuo incarico`. Le risposte rispettano la regola di invio di Messaggi e, se chiedono, attendono approvazione sul Mac. Nessun server di relay.

## Mac virtuale

Richiede Apple silicon, almeno 24 GB di RAM, spazio per un disco sparso da 64 GB e un IPSW macOS compatibile scelto da te. La rete del guest parte spenta e non ci sono cartelle condivise.

Installa Bobb in `/Applications` dentro il guest. Concedi Accessibilità e configura lì app, esecuzione e Confini. Abilita esplicitamente rete e Login remoto quando vuoi collegarlo. Configura una chiave SSH dedicata e verifica di persona l’impronta dell’host nella tua configurazione SSH. Nella pagina Computer del Mac principale inserisci IPv4 privato, account e chiave; collega Mac virtuale. Il client usa StrictHostKeyChecking, senza inoltro dell’agent, credenziali o porte.

Assegna un incarico al connettore `virtual-mac`. L’endpoint `BobbApp --mcp-guest` offre osservazione e una sola azione su bersagli correnti, con nonce consumato prima dell’effetto. Valgono entrambi i livelli di Confini. Un’azione che chiede nel guest resta bloccata: rivedi la categoria nel guest. Nessun token del modello può sostituire il permesso.

## Verifica e limiti

CI verifica Swift su macOS e Linux, daemon, specialist, strumenti e pacchetto DMG. I test coprono confini, oscuramento, contratti, calendario/DST, persistenza, concorrenza, retry e bersagli visuali. Le schermate sono renderizzate dalle viste reali in italiano e inglese, tema chiaro e scuro.

Cloud con chiavi reali, iMessage con un account reale, installazione IPSW, SSH nel guest e checkpoint grandi richiedono prove sul Mac. L’oscuramento non riconosce ogni dato sensibile e le app senza controlli o testo leggibile possono richiedere intervento. Il modello da 3B mantiene i propri limiti. La visibilità pubblica del repository richiede un’operazione amministrativa GitHub separata.
