# Le funzionalità che Bobb dovrebbe avere

Aggiornato il 3 ottobre 2026. Questo è il backlog di prodotto, non una promessa
che tutte le funzionalità siano già affidabili. Il requisito centrale è che Bobb
riconosca e prepari il prossimo passo utile prima di ricevere una richiesta.
Deve servire persone con lavori diversi, usando le loro app e imparando dalle
loro preferenze. Velocità e qualità sono entrambe requisiti.

**Stati:** “presente” indica codice funzionante in alcuni flussi; “da rafforzare”
indica implementazione parziale o qualità insufficiente; “da costruire” indica
lavoro ancora necessario. La [revisione del prodotto](PRODUCT-REVIEW-2026-10-01.md)
riporta quali verifiche sono effettivamente passate.

## P0 — indispensabili per un prodotto usabile

| Funzionalità | Comportamento atteso | Stato |
| --- | --- | --- |
| Iniziativa dal contesto | Riconoscere richieste aperte, errori, scadenze e informazioni mancanti nelle app osservate, senza aspettare un prompt. | Presente, da rafforzare |
| Aiuto quando inizio una risposta email | Dopo **Rispondi**, chiedere se preparare una bozza basata sul messaggio originale, una volta sola; lasciarla modificabile e inserirla nella risposta già aperta. | Apple Mail: archivio completo, ricerca paginata e bozza automatica nella risposta implementati; 442 test Python e 168 Swift passati con esclusioni del sandbox; clic e inserimento reali ancora da validare |
| Preparazione concreta | Proporre una bozza utile, una checklist o un breve piano; distinguere una richiesta a una persona da un’indagine tecnica. | Da rafforzare |
| Prossimo passo comprensibile | Dire cosa propone, perché adesso e quale risultato aiuta a ottenere. Evitare suggerimenti generici che ripetono soltanto il problema. | Da rafforzare |
| Fonti verificabili | Collegare ogni suggerimento al documento, messaggio o osservazione che lo giustifica, con citazione e data. | Presente, da validare su più flussi |
| Contesto aggiornato | Ritirare consigli superati quando il lavoro cambia o risulta completato. Riprendere una preparazione interrotta quando il modello è libero, senza duplicarla. | Parziale |
| Interruzioni appropriate | Rispettare scrittura, chiamate, quiet hours, pausa ed esclusioni. Restare silenzioso quando non ha un motivo concreto per intervenire. | Presente, da misurare nell’uso quotidiano |
| Velocità percepita | Mostrare subito lo stato e trasmettere le risposte mentre vengono scritte. Il lavoro proattivo deve cedere alla richiesta dell’utente. | Presente, da validare anche su M4/16 GB |
| Comprensione della richiesta | Distinguere spiegazione, calcolo, bozza, trasformazione del testo e operazione sulle app. Chiedere i dettagli essenziali senza inventarli. | Da rafforzare |
| Scrittura affidabile | Conservare destinatario, voce, negazioni, importi e scadenze; usare la lingua giusta e una grammatica naturale. | Da rafforzare |
| Conoscenza utile | Rispondere a domande generali e ragionare sui dati. Separare ciò che ha osservato, ciò che conosce e ciò che deve verificare. | Parziale |
| Un’unica pagina utile | Riunire iniziative, impegni, riunioni, routine e lavori bloccati in **Per te**. | Presente |
| App e browser abituali | Lavorare nella sessione dell’utente e usare app già aperte, senza richiedere nuovi account o profili. | Presente, copertura da ampliare |
| Completamento reale | Verificare il risultato richiesto nell’app; gestire errori, controlli non leggibili e tentativi senza effetto. Non confondere un clic con un lavoro concluso. | Da rafforzare |
| Controllo dell’utente | Confini per app e azione, Stop immediato, anteprima degli effetti importanti, esclusioni e cancellazione dei dati. | Presente, da verificare nell’intero flusso |
| Apprendimento correggibile | Imparare da accetta, modifica, rinvia e rifiuta; mostrare le preferenze apprese e permettere di modificarle o azzerarle. | Parziale |
| Primo avvio semplice | Spiegare il valore, preparare i modelli, chiedere i permessi quando servono e rendere chiaro come risolvere un blocco. | Da rafforzare |

## P1 — fare di Bobb un assistente personale

- **Preferenze di scrittura e di lavoro:** tono, lingua, lunghezza, formati,
  orari e tipi di preparazione, appresi dalle correzioni esplicite. Un rifiuto
  occasionale non deve diventare una preferenza permanente.
- **Memoria di persone, progetti e decisioni:** collegare documenti, messaggi,
  impegni e risultati dello stesso lavoro; distinguere fatti confermati da
  ipotesi e conservare la provenienza.
- **Impegni da più canali:** riconoscere promesse anche nelle chat e nei
  documenti, riconciliare aggiornamenti e chiusure, evitare solleciti duplicati.
- **Preparazione delle riunioni:** agenda, decisioni ancora aperte, materiali
  mancanti e domande utili, usando calendario e contesto consentito.
- **Suggerimenti con priorità:** scegliere ciò che sblocca il lavoro o evita una
  scadenza, considerando urgenza, utilità, confidenza e costo dell’interruzione.
- **Azioni su iniziativa:** preparare un piano da un bisogno osservato e
  proporne l’esecuzione. Per le azioni autorizzate dai Confini, operare e
  verificarne gli effetti; chiedere quando la regola lo richiede.
- **Routine personali:** proporre procedure dopo attività ripetute riuscite,
  imparare da dimostrazioni e correzioni e spiegare cosa verrà ripetuto.
- **Lavoro lungo e programmato:** checkpoint, ripresa, dipendenze, risultati
  trasferiti tra fasi, scheduling e spiegazione dei ritardi o blocchi.
- **Ricerca con prove:** consultare fonti attraverso il browser e i connettori
  autorizzati, citare i risultati e verificare informazioni che possono cambiare.
- **Contesto oltre la finestra attiva:** indicizzazione locale delle cartelle e
  delle fonti scelte dall’utente, con limiti chiari e aggiornamenti incrementali.
- **Voce naturale:** riconoscimento locale, risposta nella lingua richiesta,
  interruzione immediata e gestione degli errori senza perdere la richiesta.
- **Continuità da iPhone:** richieste, stato del lavoro e approvazioni tramite
  il canale configurato, senza una seconda memoria incoerente.

## P2 — estendere capacità e personalizzazione

- Modelli locali più capaci quando migliorano il lavoro misurato: scelta in
  base a RAM, latenza, contesto e qualità, con un percorso veloce sempre disponibile.
- Un eventuale motore per modelli grandi separato e cancellabile, con limiti
  di RAM e traffico SSD; Locali e Colibri vanno adottati sulla base di prove.
- Competenze per strumenti professionali attraverso interfacce, documentazione
  e connettori: CAD/BIM, contabilità, gestionali legali, IDE e altri ambienti.
  Il mestiere non deve limitare le altre capacità dell’assistente.
- Assistenti con responsabilità diverse, memoria condivisa solo quando
  consentito e coordinamento che evita operazioni concorrenti sullo schermo.
- Specialisti personali addestrati localmente, attivati soltanto dopo aver
  dimostrato un vantaggio rispetto al modello generale e con rollback disponibile.
- Accessibilità, uso completo da tastiera, traduzioni dell’interfaccia e
  supporto verificato per altre lingue.
- Importazione, esportazione, backup e migrazione della memoria locale.
- Un sistema di contributi per integrazioni, esempi e valutazioni riproducibili,
  con licenze e responsabilità di manutenzione chiare.

## Esempi che devono diventare prove di prodotto

| Persona | Esempio di iniziativa utile | Risultato da verificare |
| --- | --- | --- |
| Avvocato | Nota un documento mancante in una pratica e prepara la richiesta corretta. | Documento richiesto, cliente e vincoli corretti; nessuna regola legale inventata. |
| Commercialista | Nota una fattura mancante nella riconciliazione e prepara la richiesta della copia. | Importo, direzione della richiesta e riferimento al pagamento conservati. |
| Architetto | Rileva che mancano misure prima di confrontare alternative e prepara la raccolta degli input. | Informazioni pertinenti, nessuna misura o conclusione tecnica inventata. |
| Sviluppatore | Riconosce un errore e prepara un’indagine che distingue cause possibili. | Verifiche utili prima di suggerire una modifica o installazione. |
| Persona senza competenze tecniche | Riconosce una risposta o informazione mancante per un’attività quotidiana. | Proposta chiara, pronta da rivedere, senza configurazione professionale. |

## Come decidere se una funzionalità è pronta

1. Valutarla su casi nuovi, oltre agli esempi usati per sviluppare i prompt.
2. Misurare utilità e correttezza del risultato, non soltanto la presenza di un suggerimento.
3. Provare il flusso nelle app reali, includendo errori, revoca dei permessi,
   cambiamenti del documento, interruzione e ripresa.
4. Misurare prima risposta, completamento, RAM e batteria con le app quotidiane
   aperte, anche sul Mac di riferimento da 16 GB.
5. Verificare che l’apprendimento migliori le scelte su più giorni e che
   l’utente possa correggerlo.
6. Ripetere installazione e primo avvio sul pacchetto firmato destinato alla distribuzione.

I documenti [PRODUCT.md](PRODUCT.md), [VISION.md](VISION.md) e la
[roadmap storica](ROADMAP.md) descrivono la visione. Questo elenco e la revisione
del prodotto distinguono le capacità desiderate dalle verifiche attuali.
