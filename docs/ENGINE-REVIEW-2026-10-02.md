# Locali and Colibri for Bobb — 2 October 2026

## Decision

Locali has now been tested on Bobb's existing Qwen3.5 weights and on an installed
30B MoE checkpoint. Its resident path produces identical text and uses the same
memory as Bobb. Its expert streaming path makes the 30B usable with substantially
less memory, at a measured latency cost. This proves the larger-model memory
option; it does not establish better proactive judgment. Keep the current
default: speed is essential, and the streamed engine is too slow for the main
interactive path on this Mac. A larger generator for optional background
preparation still needs a separate quality and combined-memory evaluation.
Colibri has not been run locally.

## Direct engine comparison

[compare_locali_engine.py](../scripts/compare_locali_engine.py) loads the actual
Locali checkout through [locali_adapter.py](../scripts/locali_adapter.py).
No upstream source or model weights were modified. Locali's resident loader
needed Qwen's nested `text_config.vocab_size` exposed at the top level. For
this downstream workaround, [upstream issue #1](https://github.com/gabrielekarra/locali/issues/1)
now records the reproduction and suggested constructor fix. The affected
`resident_mlx.py` is on Locali's `system-one-decisions` branch, not `main`.
For
streaming, Locali's `ArenaStore` and `ArenaMoE` are reused, with an adapter
preserving Qwen's original softmax router and indexing the actual converted
safetensors headers. The default Qwen3.5-4B is dense: it has no routed experts
for the expert arena to stream.

Four identical synthetic text prompts were run twice per configuration in
separate processes, using deterministic decoding. Kev was not loaded. The 4B
runs allow 120 output tokens and the 30B runs 100; compare engines within the
same checkpoint, not throughput across different outputs/models.

| Checkpoint / engine | Peak MLX memory | Median first text | Median request duration |
| --- | --- | --- | --- |
| Qwen3.5 4B / Bobb | 2.607 GB | 349 ms | 1.395 s |
| Qwen3.5 4B / Locali resident | 2.607 GB | 348 ms | 1.366 s |
| Qwen3-VL 30B-A3B / Bobb resident, text only | 17.284 GB | 578 ms | 1.429 s |
| Same 30B / Locali, 2 GB expert arena | 2.903 GB | 5.33 s | 13.930 s |
| Same 30B / Locali, 6 GB expert arena | 6.902 GB | 4.64 s | 10.082 s |

The two 4B runs produced identical text on all eight requests. All three 30B
configurations also produced identical text on all eight requests. The streamed
adapter first checks one quantized expert block against resident MLX on a
three-token probe; maximum difference was zero. These checks are strong evidence
for the tested seam and prompts, not proof for every input. Vision was not tested.
The RSS field in the artifacts is not total unified-memory pressure; use the MLX
peak alongside system measurements rather than treating small RSS as proof that
resident weights cost no RAM.

The 2 GB arena read 267.77 GB over eight requests with 46.6% cache hits. The 6 GB
arena read 132.13 GB with 73.7% hits. Runs were sequential on this M4/24 GB;
storage/OS cache and thermal state were not reset. These are observed request
times, not cold-disk throughput or a battery benchmark. No weights were
downloaded and no expert pack was copied.

Artifacts: [Bobb 4B](benchmarks/engine-bobb-qwen35-2026-10-02.json),
[Locali 4B](benchmarks/engine-locali-qwen35-2026-10-02.json),
[resident 30B](benchmarks/engine-bobb-resident-30b-2026-10-02.json),
[streamed 30B, 2 GB](benchmarks/engine-locali-streamed-30b-2026-10-02.json),
[streamed 30B, 6 GB](benchmarks/engine-locali-streamed-30b-6gb-2026-10-02.json).

Reproduce with an installed Locali checkout and checkpoint:

```sh
bobbd/.venv/bin/python scripts/compare_locali_engine.py \
  --backend locali-resident --locali-source /path/to/locali \
  --model .runtime/models/Qwen3.5-4B-4bit --output /tmp/locali-4b.json
bobbd/.venv/bin/python scripts/compare_locali_engine.py \
  --backend locali-streamed --locali-source /path/to/locali \
  --model /path/to/Qwen3-VL-30B-A3B-Instruct-4bit \
  --ceiling-gb 6 --max-tokens 100 --output /tmp/locali-30b.json
```

This adapter is an executable experiment; the production daemon still uses
the existing resident backend. The 30B's developer checklist distinguishes a
local module from a dependency, but its accounting response misstates the
direction of the missing-invoice request. A larger model is not automatically
better for every task. A default switch needs broader usefulness/factuality
evaluation and a complete daemon run with Kev under the combined memory budget.

## Interactive speed with both shipping models

[check_response_latency.py](../scripts/check_response_latency.py) starts the real
Qwen3.5 4B + Kev daemon with an isolated database, waits for readiness and
submits synthetic requests through its Unix socket. Two requests per text path
were measured; the foreground interruption case was measured once per run.
There is no active app workload, UI measurement, thermal reset or battery test.

| Path | Median first streamed text | Median completion |
| --- | --- | --- |
| Direct question | 0.866 s | 2.651 s |
| Automatic intent selection and answer | 1.660 s | 3.410 s |
| Automatic intent selection and rewrite | 1.737 s | 2.346 s |
| Direct foreground request during proactive preparation | 1.183 s | 1.393 s |

Model readiness took 6.655 seconds and is excluded from those request times.
The latest [artifact](benchmarks/response-latency-2026-10-02.json) records the
outputs and timings. This is useful measured evidence, not a latency guarantee.
The general-knowledge output includes an unverified mechanism about chloroplasts;
these timing checks do not score factual correctness of every answer.

Intent readouts now reuse the same user-request prefix in Kev, without treating
selected document text as an instruction. General questions and simple writing
requests can use model knowledge/user instructions while personal facts still
require observed context. The earlier memory-only question prompt refused
“Scrivi solo: Ricevuto, grazie.” The benchmark now asserts the actual requested
text, rather than just a nonempty response.

Proactive generation processes its prompt in 128-token chunks, checks
cancellation between those chunks and releases its generator on cancellation.
Foreground generation keeps the normal 2048-token prefill. Before this change,
the same successful short foreground answer waited 2.067 seconds for first text,
versus 1.183 seconds afterwards. Both runs use the same revised writing/knowledge
prompt; the [prior artifact](benchmarks/response-latency-token-cancel-2026-10-02.json)
retains that comparison. Cancellation produced no initiative or app action.
This one comparison is not a general percentage speedup claim. The older
[baseline](benchmarks/response-latency-baseline-2026-10-02.json) includes the
incorrect refusal and must not be presented as a successful task.

A separate [routing experiment](benchmarks/request-routing-2026-10-02.json)
tested 31 synthetic requests twice, clearing the prefix between variants. A
single nine-way readout reduced median text classification from 857 to 764 ms
but increased app-command classification from 513 to 788 ms. It is not adopted.
Both variants missed a future document-sending request; the existing binary
route also misclassified an arithmetic request as an app action. Those are
release-quality findings. The exact-mode score also treats a general question
classified as “explain” rather than “ask” as a mismatch even though, without a
selection, both produce the same answer task. These development results are
not calibrated safety or general accuracy scores.

## Evidence inspected

Locali's local checkout at commit
`6cd9b9cc8c06e068b2540b2cacb4af6aba42c5b2` includes
`results/deepseek_v4_flash_locali_m4_24gb_20260805.md`, `dsv4_engine.py` and
`deepseek_v4.py`. Its reported M4/24 GB DeepSeek V4 Flash run uses 13.50 GB active
MLX memory, a 92.8 GB checkpoint and an additional 77.91 GB expert pack.
Two 64-token prompt/128-token decode runs report 5.61–5.71 prompt tokens/s,
2.32–2.34 decode tokens/s and 92.14 GB read per run. These are existing Locali
measurements, not new Bobb measurements. The short first-visible-text result
of 3.728 seconds does not establish latency for long screen context.

The required DeepSeek checkpoint, expert index and oMLX source are absent from
that checkout today. No new large model download or DeepSeek inference was
performed. Locali's loader applies process-wide MLX patches; integrating it
inside Bobb's resident model process would require compatibility work. A
separate worker with bounded memory, cancellation and Unix-socket/stdio IPC is
the proposed integration boundary. Bobb's inference daemon must retain its IP
network prohibition. This worker is not implemented in this revision.

[Colibri](https://github.com/JustVugg/colibri) streams MoE experts from storage
and supports several model families, including smaller options. Its
[Metal backend](https://github.com/JustVugg/colibri/blob/main/docs/metal.md) is
documented as experimental. Its
[benchmarks](https://github.com/JustVugg/colibri/blob/main/docs/benchmarks.md)
explicitly distinguish measured hardware/workloads from predictions. The
published GLM Metal results on much larger-memory Macs do not predict Bobb's
latency on this M4. No Colibri runtime was installed or benchmarked locally.
Its typed-choice Brio API also needs Bobb-specific evaluation before replacing
Kev; confidence values cannot inherit Kev's thresholds without calibration.

## Earlier generator comparison

The installed Locali research checkpoint Qwen3-8B-4bit can already run through
Bobb's MLX adapter. Both generators were evaluated with the same Kev backend,
prompt, deterministic decoding and thirteen synthetic development cases:

| Generator | Suggestion/silence matches | Median latency on seven positive contexts | Missed context |
| --- | --- | --- | --- |
| Qwen3.5-4B-4bit | 12/13 | 6.603 s | Migration meeting input |
| Qwen3-8B-4bit | 12/13 | 9.224 s | Missing legal document |

Outputs: [4B](benchmarks/proactivity-2026-10-02.json),
[8B](benchmarks/proactivity-qwen3-8b-2026-10-02.json).
These single sequential runs exclude model loading, are not a controlled
throughput benchmark, and do not score draft correctness. The cases were used
in prompt development. Both correctly stayed silent on the six negative cases;
that sample cannot establish a real-world false-interruption rate.

Manual inspection found defects despite successful presence checks: the 8B
accounting draft invents an accounting-department handoff, and several drafts
repeat an instruction instead of preparing useful work. The 4B follow-up draft
adds an unobserved prior agreement. Both sometimes ignore the requested source
language. The independent model check does not reliably catch these issues.
Drafts remain editable suggestions for user review and cannot execute actions.
Do not present 12/13 as an accuracy score for the generated advice.

Reproduce the alternative run without changing Bobb's default:

```sh
bobbd/.venv/bin/python scripts/check_proactivity.py \
  --generator /path/to/Qwen3-8B-4bit \
  --output /tmp/bobb-proactivity-8b.json
```

## Acceptance criteria for a deeper model

Before making a larger model a product default, compare draft factuality,
specificity and actual task completion on new held-out workflows. Measure time
to a useful suggestion, cancellation, peak memory/system pressure and SSD
traffic with everyday apps open. Test cold and changing contexts, not only
repeated prompts. A large worker should release resources when foreground work
needs them; maintaining both it and Kev resident on a 24 GB Mac is unverified.
The earlier 8B experiment provides no reason to replace the current default.
The direct streamed 30B experiment does establish a viable memory path for a
larger optional generator, with slower response and substantial reads to budget.
