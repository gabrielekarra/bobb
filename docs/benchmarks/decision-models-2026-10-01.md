# Confronto locale: Kev e CUA-S1 4B

**Con questi risultati manterrei Kev come decisionale predefinito di Bobb.**
Sul campione testato sceglie più spesso l'azione corretta, risponde più
rapidamente e cambia meno spesso scelta quando le opzioni vengono invertite.
CUA-S1 con MLX a 4 bit riduce il consumo di memoria, ma non offre un miglioramento
di precisione o latenza rispetto a Kev.

## Risultati

Mac Apple M4 con 24 GiB di RAM, macOS, inferenza offline con connessioni IP
bloccate dal benchmark. Ogni modello gira in un processo separato, in sequenza,
con il Qwen di generazione di Bobb residente in memoria. Non è un test su un
MacBook Air da 16 GB.

| Decisionale | Scelte corrette, 96 valutazioni | Mediana | P95 | Picco allocator GPU* | Errori con probabilità ≥ 80% |
| --- | ---: | ---: | ---: | ---: | ---: |
| Kev, MLX 8 bit attualmente usato da Bobb | 91/96 (94,8%) | 446 ms | 545 ms | 7,19 GB | 0 |
| CUA-S1 4B 0.2, runtime ufficiale PyTorch/MPS FP16 | 85/96 (88,5%) | 1.470 ms | 2.699 ms | 12,85 GB | 6 |
| CUA-S1 4B 0.2, port sperimentale MLX BF16 | 85/96 (88,5%) | 740 ms | 792 ms | 11,43 GB | 6 |
| CUA-S1 4B 0.2, port sperimentale MLX 4 bit | 86/96 (89,6%) | 698 ms | 816 ms | 5,69 GB | 5 |

*GB decimali. Sono picchi dei contatori GPU, con Qwen residente, non la RAM
totale dell'app o del sistema: MLX `get_peak_memory()` per i runtime MLX;
allocazione del driver Metal rilevata ogni 50 ms durante l'inferenza per MPS.
Il contatore MPS del driver comprende allocazioni/cache Metal di quel processo,
incluse quelle del Qwen MLX residente. I contatori hanno definizioni diverse;
questi valori non sono una misura identica di RAM fisica consumata. Il picco
MPS campionato può perdere transitori brevi e non comprende il caricamento
iniziale. I dettagli RSS e allocator sono conservati nei dati grezzi e non
vanno sommati: la memoria su Apple silicon è condivisa.

### Per tipo di decisione

| Tipo | Kev | CUA-S1 MPS | CUA-S1 MLX BF16 | CUA-S1 MLX 4 bit |
| --- | ---: | ---: | ---: | ---: |
| Prossima azione sull'interfaccia | 61/64 | 55/64 | 55/64 | 56/64 |
| Rispondere oppure operare il computer | 16/16 | 16/16 | 16/16 | 16/16 |
| Informazioni sufficienti per agire | 8/8 | 7/8 | 7/8 | 7/8 |
| Verifica del risultato dichiarato | 6/8 | 7/8 | 7/8 | 7/8 |

Sono 48 scenari scritti per questo confronto: 32 GUI, 8 di instradamento,
4 di chiarimento e 4 di verifica, con testi in italiano e inglese. Ciascuno
viene valutato due volte. Nel primo ordine, senza il secondo passaggio,
Kev ottiene 46/48, CUA-S1 MPS e MLX BF16 41/48, CUA-S1 MLX 4 bit 42/48.

Nei 40 casi `Choice` si inverte realmente l'ordine delle opzioni per entrambi
i modelli. Kev mantiene la scelta in 39/40 casi; ciascun runtime CUA-S1 in
37/40. Nei restanti 8 casi `Bool`, il backend di produzione Kev mantiene
sempre l'ordine nativo no/yes: la seconda valutazione ripete quel calcolo,
rimappando la distribuzione all'ordine esposto dal benchmark. CUA-S1 riceve
invece le lettere invertite anche per quei casi. Per questo il dato di
stabilità confrontabile è limitato ai 40 `Choice`, e le 96 valutazioni non
sono 96 scenari indipendenti.

## Errori che contano per Bobb

Kev a volte sceglie Salva prima di inserire il contenuto: in una bozza email
e in un evento di calendario con titolo ancora vuoto. In un caso di verifica
accetta un report di salvataggio contraddetto dall'osservazione, con probabilità
77,3%. Questo errore rimane sotto il gate di completamento di Bobb, pari all'80%,
ma dimostra che neppure Kev comprende sempre correttamente l'evidenza.

Anche CUA-S1 sceglie prematuramente Salva in quei casi. Inoltre può continuare
a premere Retry dopo tentativi falliti, scegliere un destinatario ambiguo
anziché chiedere chiarimenti, o aprire un risultato quando l'utente ha chiesto
di fermarsi alla lista. Accetta un report di salvataggio contraddetto dallo
stato osservato con probabilità 84,6% nel runtime ufficiale e 99,5% nel port
a 4 bit. Non adotterei le attuali soglie di Bobb su quel backend senza una
nuova calibrazione e verifica.

L'instradamento è corretto per tutti i modelli in questo piccolo campione.
La verifica ha 7/8 risposte corrette per CUA-S1 contro 6/8 per Kev: il
vantaggio su quei quattro scenari non compensa gli altri errori e non basta
per dichiarare un modello superiore nella verifica in generale.

## Controllo del port MLX

Il port applica tutti i tensori dell'adapter PEFT, controlla i nomi e le forme,
usa il prompt, il tokenizer e la lettura delle lettere del codice ufficiale.
Non fonde né riquantizza le delta LoRA. La variante a 4 bit usa una copia
separata della base Qwen MLX già presente in Bobb; non condivide i pesi con
il Qwen di generazione nel benchmark. Il tokenizer del decisionale resta
quello della base originale CUA-S1.

Con i pesi originali BF16, il port MLX concorda con il runtime MPS FP16 sulla
scelta in **96/96 valutazioni**. La differenza assoluta media tra le
probabilità delle opzioni è 0,00324 e la massima 0,03865. Questo controllo
supporta il corretto collegamento dell'adapter nel campione; non prova
equivalenza numerica universale tra i runtime.

La variante a 4 bit concorda con MPS in 91/96 valutazioni; differenza assoluta
media delle probabilità 0,04912, massima 0,47811. Il suo risultato non può
quindi essere attribuito soltanto a una maggiore efficienza: quantizzazione,
base convertita e runtime possono alterare la decisione e la confidenza.

## Implicazioni per il prodotto

Il runtime ufficiale CUA-S1 lascia poco margine su una macchina da 16 GB,
quando si includono sistema operativo, browser, app aperte e voce. Il dato
richiede comunque verifica su hardware da 16 GB: non dimostra che il modello
sia impossibile da eseguire su quella macchina.

Il port MLX a 4 bit è interessante per il risparmio di memoria. In questo
confronto non giustifica una sostituzione del decisionale: peggiora le scelte
e resta più lento di Kev. I driver CUA rimangono utili e indipendenti dalla
scelta del modello.

Questa prova testa esclusivamente il decisionale su stati sintetici già
osservati e alternative predefinite. Non testa pianificazione e generazione
Qwen, navigazione reale, screenshot, esecuzione dei driver, voce, attività
proattiva o successo di compiti a più passaggi. Non è una classifica generale
dei modelli. I gate non eseguono azioni nel benchmark: viene misurata la
scelta più probabile, inclusi gli errori che una soglia potrebbe bloccare.
Le probabilità dei modelli non hanno una calibrazione comune. Le latenze
sono una singola prova locale con processi di sistema e app in background,
senza controllo termico o ripetizioni su più dispositivi.

## Riproduzione e dati

[Casi](../../scripts/decision_benchmark_cases.json),
[benchmark](../../scripts/compare_decision_models.py),
[download degli asset fissati](../../scripts/prepare_decision_benchmark.py),
[risultati grezzi e concordanza tra runtime](decision-models-2026-10-01.json).

Dal root del repository, con le dipendenze e i modelli di Bobb già installati:

```sh
python3 scripts/prepare_decision_benchmark.py --with-base
uv pip install --python bobbd/.venv/bin/python --target .runtime/decision-benchmark/python --no-deps peft==0.18.1 accelerate==1.10.1 torchvision==0.23.0 psutil==7.2.2
bobbd/.venv/bin/python scripts/compare_decision_models.py --model kev --with-generator --output .runtime/decision-benchmark/results/kev.json
bobbd/.venv/bin/python scripts/compare_decision_models.py --model cua-mps --with-generator --output .runtime/decision-benchmark/results/cua-mps.json
bobbd/.venv/bin/python scripts/compare_decision_models.py --model cua-mlx-bf16 --with-generator --output .runtime/decision-benchmark/results/cua-mlx-bf16.json
bobbd/.venv/bin/python scripts/compare_decision_models.py --model cua-mlx4 --with-generator --output .runtime/decision-benchmark/results/cua-mlx4.json
```

Il download aggiuntivo per la ricerca è circa 9,43 GB, fuori dal manifest
distribuito con Bobb. Le dipendenze aggiuntive sono isolate dal virtualenv
di produzione. Versioni della prova: MLX 0.32.2, mlx-lm 0.31.3,
PyTorch 2.8.0 e Transformers 5.17.0.

Revisioni fissate: CUA-S1
`16818868b0cc7813808aae4e87b417657046ab79`; Qwen originale
`851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`; codice CUA
`657a0c9ea5768573af53b43473c1cbcc4021b2c4`. Le revisioni e gli hash dei
file sono nei dati grezzi. Per Kev e Qwen MLX valgono le revisioni del
[manifest di Bobb](../../bobbd/bobbd/model-manifest.json).

Riferimenti primari:
[modello CUA-S1 4B 0.2](https://huggingface.co/cua-ai/cua-s1-4b-0.2/tree/16818868b0cc7813808aae4e87b417657046ab79),
[runtime CUA-S1 usato nella prova](https://github.com/trycua/cua/blob/657a0c9ea5768573af53b43473c1cbcc4021b2c4/libs/cua-s1/python/src/cua_s1/four_b.py),
[Kev locale in Bobb](../../bobbd/bobbd/kev.py).
