# Apple Mail: archivio e risposta direttamente nella bozza

## Revisione di questa chat — 3 ottobre 2026

Il comportamento richiesto è ora **Rispondi → generazione → inserimento nella
risposta aperta**, senza un secondo clic su Genera bozza. La preferenza nativa
`mailInlineReplies` è attiva di default; disattivandola resta disponibile il
precedente percorso con proposta e approvazione. Le preferenze precedenti si
decodificano senza perdere gli altri valori.

La generazione usa un ID indipendente dal pannello Email. Un monitor annulla
il lavoro quando cambia la risposta, l'utente scrive o Mail perde il focus.
Prima dell'inserimento si verificano Message-ID originale, destinatari,
compose ID, finestra, testo ancora vuoto, pausa ed esclusioni. Le regole che
richiedono approvazione per scrivere e la modalità ogni passo impediscono
l'inserimento automatico. I mittenti silenziati sono rispettati nel daemon.
Durante un task sulle app la generazione automatica resta disabilitata.
L'inserimento verifica il contenuto risultante e preserva citazione e firma
esistenti. Non viene premuto Invia.

L'evento nativo viene comunque registrato nel daemon e nella memoria consentita;
il flag `inline_handled` impedisce di mostrare anche la vecchia proposta. Il
menu mostra lo stato di elaborazione e lo conclude quando termina la richiesta.

Il file `mail-inline.jsonl` nei log nativi registra rilevamento, generazione,
cancellazione e inserimento verificato senza salvare contenuto, indirizzi,
oggetti o Message-ID. Permette di distinguere un risultato di Bobb da Siri
nella prossima prova reale.

La sincronizzazione manuale enumera tutti gli account abilitati e le cartelle
annidate accessibili a Mail, comprese quelle locali, e importa a pagine. Mostra
il progresso, può essere fermata e mantiene il cursore nella stessa sessione.
Le singole email non leggibili sono contate e il risultato segnala l'importazione
parziale. Ripetere la sincronizzazione ritenta la lettura. Un import completo
attiva esplicitamente la conservazione dell'archivio email completo, separata
dalla durata della memoria schermo. La scelta è visibile nelle preferenze.

La ricerca e i filtri vengono applicati prima della paginazione, sull'intero
indice: account, cartella, inviate, ricevute, non lette, contrassegnate, allegati,
VIP e richieste aperte. Più copie della stessa email mantengono le loro posizioni
senza duplicare i risultati. Le risposte ad email archiviate cercano anche
nelle altre cartelle. Dal pannello si può cambiare lettura e contrassegno in
Mail; il bridge verifica lo stato. Riassunti, domande, richieste/scadenze,
traduzioni, riscritture, nuove email, reply-all, inoltri, solleciti e promemoria
restano disponibili.

**Verifiche di questa revisione:** 442 test Python passati; 53 casi esclusi
per test lenti/GPU o socket Unix non consentiti dal sandbox. Il file di test
`tests/test_generation.py`, che importa MLX anche con generatori simulati, non
è stato eseguito. 168 test Swift passati; tre test IPC esclusi per lo stesso
blocco sui socket. Il target app compila con SDK 26.5, cache temporanea e
sandbox interno SwiftPM disabilitato. Gli script MailBridge e risposta sono
compilati usando il percorso esplicito dell'app Mail per risolverne il
dizionario nel sandbox. L'indice ha importato 2.500 email sintetiche in circa
0,36 secondi in SQLite in memoria, raggiungendo anche l'ultima pagina: questo
non misura i tempi di lettura della vera Mail.

**Prova reale ancora aperta:** gli strumenti CUA non sono stati esposti a
questa chat anche dopo l'attivazione dichiarata dall'utente. Il sandbox non
consente accesso alla GPU Metal o ai socket locali. Non sono state eseguite
osservazione del clic reale, generazione con i pesi residenti o inserimento
nella vera Mail per il nuovo percorso automatico. I test diretti del daemon
usano un motore simulato; non sostituiscono queste verifiche.

Limiti espliciti: corpo importato fino a 64.000 caratteri, segnalato se lungo;
allegati limitati ai nomi; thread di generazione limitato ai messaggi recenti;
riepilogo inbox limitato a 12 email corrispondenti. Le copie/spostamenti fatti
fuori da Bobb richiedono una nuova osservazione/sincronizzazione; le posizioni
storiche nell'indice non vengono automaticamente eliminate quando Mail sposta
un messaggio. Non è una dichiarazione di copertura universale di Mail.

## Evidenze precedenti, relative al percorso con approvazione

Il caso richiesto è **Mail di Apple**: aprire un'email, premere **Rispondi**,
ricevere la domanda «Vuoi che prepari una bozza di risposta?» e scegliere
**Genera bozza**. La bozza appare in un pannello modificabile. L'utente può
dare istruzioni, scegliere una variante, copiare o inserire il testo nella
risposta già aperta. L'invio rimane un'azione dell'utente.

## Cosa è cambiato

- Il sensore riconosce una risposta ancora vuota e la collega al messaggio
  selezionato attraverso oggetto e destinatari, incluso Reply-To. Una finestra
  di lettura con titolo `Re:` richiede anche il controllo Invia del composer.
- L'ID della bozza distingue sessioni diverse. Una stessa risposta riceve
  una proposta sola, anche passando ad altre app e tornando a Mail.
- Firma automatica e cronologia citata non vengono scambiate per testo scritto
  dall'utente. Una bozza già scritta non provoca l'offerta iniziale.
- Il gesto genera `mail.reply_started`. La proposta segue una regola nativa e
  arriva senza classificazione del modello o attesa nella sua coda. Generare
  la bozza richiede l'approvazione esplicita.
- Pausa, app escluse, mittenti silenziati e quiet hours restano applicati.
  Tre rifiuti espliciti per un mittente insegnano a non riproporre l'aiuto;
  la preferenza può essere azzerata. Un timeout non equivale a un rifiuto.
- L'ID della risposta rimane nel risultato. **Inserisci** controlla che quella
  risposta sia ancora aperta e vuota; se non può identificarla o è cambiata,
  copia il testo e mostra il suggerimento di incollarlo manualmente.
- Corretto un difetto dell'overlay: l'osservazione dello stato leggeva il
  valore precedente e poteva perdere il primo suggerimento. La prova nativa
  ha riprodotto il problema e verificato il popup dopo la correzione.

La prima bozza senza altre istruzioni è neutra. Non deve scegliere al posto
dell'utente se accettare un preventivo, né inventare disponibilità o documenti
già pronti. **Accetta**, **Declina**, **Serve tempo**, **Chiedi dettagli** e le
istruzioni libere permettono di indicare cosa rispondere. Questo è un primo
passaggio: una bozza utile dovrà usare meglio il contesto e le preferenze
verificate dell'utente. I prompt non garantiscono la correttezza del risultato.

## Evidenza disponibile

**Regressioni:** 442 test Python passati, quattro test lenti esclusi; 161 test
Swift passati in 22 suite. Coprono associazione al messaggio, firma e citazioni,
testo già scritto, deduplicazione, approvazione, esclusioni anche dopo l'offerta,
apprendimento e reset. La build di sviluppo è compilata e verificata con firma
ad hoc.

La [prova con i modelli reali](benchmarks/mail-reply-2026-10-03.json) usa
Qwen3.5-4B e Kev, un daemon reale, il socket Unix, un database temporaneo e tre
email sintetiche. Il primo testo generato, escluso il saluto precompilato, è
arrivato dopo **0,93–1,21 secondi**; il completamento dopo **1,57–2,32 secondi**.
La sola proposta ha richiesto **0,29–1,29 ms** nel daemon. Il sensore campiona
ogni secondo: questi millisecondi non rappresentano il tempo dal clic in Mail.
La prova verifica anche rifiuto, deduplicazione e assenza di azioni sulle app.

La [prova dell'interfaccia nativa](benchmarks/mail-reply-ui-2026-10-03.json)
esercita il popup, il suo comando **Genera bozza**, il pannello modificabile e
la generazione reale. Usa un evento sintetico e acquisisce solo le finestre
del processo di prova. Gli AppleScript del sensore sono compilati contro Mail.

**Rilevamento reale ancora da verificare:** i permessi di Accessibilità
risultano concessi, ma l'utente ha poi precisato che il popup visto potrebbe
essere di Siri. Nel registro di Bobb non risultano eventi `mail.reply_started`
per quella prova. La precedente conferma del popup è quindi ritirata: la
prova con un evento sintetico non dimostra il riconoscimento del clic in Mail.

**Ancora da verificare nella vera Mail:** generazione e inserimento nella
risposta, incluso il caso di testo modificato o finestra chiusa nel frattempo.
Il controllo nativo del pannello e i test del contratto non provano questi
passaggi nell'app email.

La selezione deve fornire il messaggio originale e il sensore deve identificare
una sola finestra di composizione corrispondente. Finestre ambigue o dati
mancanti fanno restare Bobb in silenzio. Le citazioni riconosciute coprono i
formati usuali inglesi e italiani e un formato tedesco; non tutte le varianti
di lingua o firma sono ancora validate. Le build ad hoc possono richiedere
di concedere nuovamente Accessibilità dopo una ricompilazione.

## Ripetere la prova

```sh
(cd bobbd && uv run pytest -q -m 'not slow')
(cd BobbApp && swift test -j 1)
bobbd/.venv/bin/python scripts/check_mail_reply.py
```

Per il controllo nativo, avviare un daemon con un database temporaneo e
passare il suo socket alla build Bobb:

```sh
open -n dist/Bobb.app --args --check-mail-reply \
  --socket /private/tmp/bobb-mail-ui.sock \
  --report /private/tmp/bobb-mail-reply-ui.json \
  --screenshots /private/tmp/bobb-mail-reply-screenshots
```

Per la verifica reale: concedere i due permessi a questa build, aprire Mail,
selezionare un'email, premere **Rispondi**, attendere la proposta e generare la
bozza. Controllare anche rifiuto, ritorno alla stessa risposta, testo già
scritto, firma e storico citato, due finestre con lo stesso oggetto, risposta
chiusa o modificata durante la generazione. Nessun messaggio deve essere inviato
dal percorso di preparazione.
