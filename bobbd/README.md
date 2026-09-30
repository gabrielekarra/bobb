# bobbd

Bobb's on-device decision daemon. A resident 4-bit local model
(`mlx-community/Llama-3.2-3B-Instruct-4bit`) is read at single logit
positions for narrow, schema-constrained readouts (`bobbd/decide.py`),
never sampled from except when actually drafting text. A unix socket carries
the IPC contract in `docs/CONTRACT.md` to the Swift app.

This file records what was measured, when, and on what machine, so the
numbers below can be checked against `results/*.json` rather than taken on
faith.

Measured on a fanless Apple M4, 24 GB, macOS 27.

## Bobb 1.0: what changed in the daemon

Everything below this section is the v0.1 record and stays as it was
measured. 1.0 changed these things, each with tests in `tests/`:

| Area | Module | Change |
|---|---|---|
| Protocol 1 | `server.py` | Binds before the model loads and reports `loading` / `model_missing` / `error` / `ready`; streaming `prepared.delta` and `answer.delta`; `ask`, `cancel`, `regenerate`, memory, stats, learning and settings frames. See `docs/CONTRACT.md`. |
| Letter-order bias | `decide.py`, `intents.py` | Fixed, not just measured: `message_type` is read twice, options in forward and reversed order, and the two distributions averaged (`debias=True`). |
| Automated but critical | `intents.py` | The urgency rubric now describes consequential automated notices (security alerts, overdue invoices, expiring deadlines); they get a summary, not a reply. |
| Tone | `intents.py` | `tone` is a three-way `Choice` (warm or neutral / firm / curt or hostile) instead of a score that collapsed to the middle. |
| Drafts | `compose.py`, `generation.py` | Written as the user, never as the sender (salutation prefix, role rules); same language and register as the email; four variants (accept, decline, more time, ask for details); grounded in screen memory with `[n]` citations; a fact check lists figures, dates and names that appear in neither the email nor the sources. |
| Ask | `compose.py` | Eight modes (ask, write, reply, rewrite, translate, summarize, explain, compute) over the selection and screen memory. |
| Screen memory | `memory.py` | SQLite FTS5, text only; redaction of cards, keys, tokens, one-time codes and password lines (IBANs preserved); dedup and window growth merge; retention sweep. |
| Learning | `learning.py` | Per-kind Beta(2,2) approval estimate moves a personal floor within [0.40, 0.90] after 6 answers; three explicit dismissals from one sender mute it; every rule is visible and undoable. Timeouts are not dismissals. |
| Settings | `settings.py` | Floor, language, which event kinds may interrupt, quiet hours, protected apps, retention; applied live. |
| Lifecycle | `__main__.py` | `--parent-pid` watchdog, single-instance lock (exit 3), log file, data dir. |
| Tasks | `agent.py` | Doing a job in any app (ADR-007): a plan, then per step one prefill answering the operation and a typed target question per kind (press, text, scroll, app), each with "none of these"; text only for TYPE; a Bool for "press Return after"; blocks below the floor, on "none", on a step that changes nothing, after 30 steps. `route_request` tells a question from a job. |
| Tier 0 | `specialist.py` | The personal specialist (ADR-008): hashed-feature logistic regression trained on the Mac from explicit, implicit and teacher labels, validated on the user's newest answers before it may decide, deciding alone only a confident "this can wait", with 5% shadow checks. |
| Chats | `intents.py`, `compose.py` | `message.opened` judged on the mail questions; a chat-sized reply. |
| Promises | `commitments.py` | One Bool readout (does this sent message promise something?), then the promise phrased by the text model and its due date parsed by code (EN/IT). |
| Meetings | `intents.py`, `compose.py` | `calendar.upcoming`: one Bool (worth preparing?), and a cited brief that includes open promises to the attendees. |
| Procedures | `procedures.py` | Tasks that ended done and user demonstrations, matched to new requests: a guide in every step's context, and the plan itself when the match is close. |

### Judgement A/B, 1.0 against v0.1

The same 25-message fixture (`judgement_eval.py`), run through the three
prompt configurations. Because this machine could not run MLX at a usable
speed, the run used `tools/torch_reference.py`: the **same 4-bit checkpoint,
dequantized to bf16 and evaluated with PyTorch on CPU**. That makes the
comparison between configurations fair (same weights, same engine), but the
absolute numbers are not the MLX 4-bit numbers above, and **no latency from
this run is quotable**. File: `results/reference/judgement_ab_1790592569.json`.

| Configuration | Floor | Coverage | Precision | Recall |
|---|---|---|---|---|
| v0.1 | 0.60 | 0.28 | 1.000 | 0.538 (7/13) |
| v0.1 + debias only | 0.60 | 0.28 | 1.000 | 0.538 (7/13) |
| **1.0** | **0.60** | **0.48** | **0.833** | **0.769 (10/13)** |
| 1.0 | 0.50 | 0.52 | 0.846 | 0.846 |
| 1.0 | 0.70 | 0.40 | 0.900 | 0.692 |

Read honestly: 1.0 catches three more of the thirteen messages that need the
user, and pays for it with two false positives at the default floor. Both are
`prepare`, not `suggest`: they wait silently under "For you" and never pop an
overlay, so the cost is an item the user can ignore, not an interruption.
Every `suggest` in the 1.0 run was correct. Letter order moved no final
decision in either debiased configuration.

What this does not show: behaviour on real inboxes (25 fixtures is a smoke
test, not a benchmark), MLX 4-bit latency on the 1.0 prompts, and calibration
of the personal floor, which needs weeks of a real user's answers.

## The core change: ask facts, not judgements

The daemon used to ask the model `interrupt`: "what should Bobb do about
this?", with `ignore`/`wait`/`prepare`/`suggest` as the options. Measured
against a 25-event hand-labelled `mail.opened` fixture
(`bobbd/judgement_eval.py`), it answered `wait` on 20 of 25 events at
confidence 0.38-0.55 against a 0.25 baseline -- the model had no real
opinion. Alongside it, `reply_needed` (`Bool`, "this email requires a reply
or action") answered `true` on all 25 events, including newsletters and
receipts: a constant wearing a feature's clothes.

`urgency`, once its five levels were each defined in the question text
instead of left to "how urgent is this", worked well from the start: 0 on
10/12 events that should not surface, >=2 on 12/13 that should. Defining the
levels was the entire difference between a coin flip and a working readout.

The conclusion, applied here: **do not ask the model what to do; ask it what
is true, and let code decide what to do.** `interrupt` was removed entirely.
`reply_needed` was replaced. `bobbd/policy.py` is new: a pure,
deterministic function from the model's factual readouts plus `user_state`
to an action, unit-tested with no model loaded (`tests/test_policy.py`).

### The factual question set

`bobbd/intents.py`, `mail.opened`:

- **`message_type`** (`Choice`): `broadcast` / `transactional` /
  `personal_no_ask` / `personal_request`, each defined in the question text.
  This is the direct replacement for `reply_needed`: a newsletter, a receipt,
  an FYI with no ask, and a real request are four different things, and a
  `Bool` cannot say which of four it is even when it answers correctly --
  it can only agree or disagree with one fixed statement. This is also the
  question the fixture cares about most: separating a request from
  everything else is most of what "should this surface" comes down to.
- **`urgency`** (`Score`, unchanged from the prior fix): the five anchored
  levels already established as the one readout that reliably works.

Two more facts were tried and dropped. `deadline_stated` and
`sender_waiting_on_user`, each a `Bool` anchored as narrowly as urgency's own
levels ("states or clearly implies a specific deadline... a general sense of
importance... does not count"), both came back `true` on all 25 events --
the exact failure diagnosed in `reply_needed`, just moved to two new names.
Careful anchoring did not fix it; only forcing a choice among several
mutually exclusive labels did (`message_type`, `urgency`). This is recorded
in `intents.py`'s module docstring and `policy.py`'s `_mail_opened_action`
docstring, not just here, because it is a design constraint on every future
`Bool` in this system, not a one-off bug: **a bound on the answer's meaning
in the question text is not the same as a bound on the answer's yes-bias; a
`Bool` in this scheme should be treated as a weak default, a `Choice`
between exhaustive, mutually exclusive labels as the strong one.**

`whether this is a first contact or an ongoing thread` was considered and
skipped: `thread_len` already arrives in `event.payload` as a plain
integer, so it is decidable from the payload directly and asking the model
to re-derive it would cost a forward pass for nothing.

The other four `mail.opened`-adjacent kinds keep their existing readouts
(`stuck`/`tone_risk`, `actionable`/`action_kind`, `relevant`) with
`interrupt` dropped from each; `policy.py` derives their actions the same
way (see `_mail_composing_action`, `_text_selected_action`,
`_relevance_action`).

### `policy.py`

Pure, total, no `Engine` or forward pass anywhere in it. Per-kind functions
(`_mail_opened_action` etc.) because the facts and their meaning differ by
kind; a single flat formula across all of them would not mean the same
thing twice. `message_type == "broadcast"` short-circuits to `ignore`
regardless of urgency -- a mass mailing is never addressed to the user
personally, whatever tone it takes. `user_state` never enters the
per-fact confidence math (it carries no model confidence, being derived
from payloads, not asked of the model); instead it caps the result
afterward: a `suggest` is downgraded to `prepare` when the user is
`typing` or in a `meeting`, the same weighing the old prompt asked the model
to do in prose, now a rule instead of a hope.

**Confidence composition.** An action is the conclusion of a deterministic
rule over a handful of facts, not independent evidence pooled together, so
its confidence is the *minimum* confidence among the facts the taken branch
actually used -- the chain is only as strong as its weakest link. A fact a
branch never inspects does not lower the confidence, because correctness
never depended on it. `min` over `multiply`: multiplying would treat the
facts as independent evidence, which two readouts about the same email are
not.

One refinement earned its own function
(`policy._urgency_side_confidence`), because it was not obvious until
measured: `urgency.confidence` is the point-mass on one specific integer
among five adjacent levels, and a well-calibrated model rarely stacks much
mass on a single integer when its neighbour is nearly as plausible -- 2 vs.
3 is a real disagreement about *how* urgent, not about *whether* to act at
all, and every branch in `_mail_opened_action` only ever asks the second
question. Using the point-mass directly meant floor coverage collapsed to
essentially nothing above floor 0.5 even after the `Bool` facts were fixed
(see the middle column of the table below). Replacing it with the
cumulative probability on whichever side of the tier-2 boundary the argmax
agrees with fixed that, without changing what any branch's condition
means -- see the docstring on `_urgency_side_confidence` for the exact
reasoning, and `tests/test_policy.py::test_urgency_confidence_is_cumulative_across_the_surfacing_boundary_not_point_mass`
for a hand-built distribution where this changes the reported confidence
from 0.45 to 0.90.

## Judgement evaluation: before, and three iterations of after

`uv run python -m bobbd.judgement_eval`, `results/latest_judgement_eval.json`,
25 hand-labelled `mail.opened` events (13 that should surface, 12 that
should not), evaluated at `floor=0.0` and swept post hoc. `judgement_eval.py`
has no idle gate -- it measures correctness, not latency, so machine load
changes how long it takes, not what it reports -- but for the record, the
three post-rework runs (`judgement_eval_1789922581.json`,
`_1789922868.json`, `_1789923215.json`) ran between 18:43 and 18:53, while
`load1` was still in the 1.6-3.4 range, before the later spike to 9.37
described in "Benchmark" below.

| | before (`interrupt`+`reply_needed`) | 4 facts, `Bool`s included | 2 facts, point-mass confidence | 2 facts, cumulative confidence (final) |
|---|---|---|---|---|
| reply-needed-equivalent accuracy | 0.60-0.64 (~base rate) | 0.88 | 0.88 | 0.88 |
| coverage @ floor 0.0 | 0.0 | 0.44 | 0.40 | 0.40 |
| coverage @ floor 0.5 | 0.0 | 0.08 | 0.08 | **0.36** |
| coverage @ floor 0.6 (production default) | 0.0 | 0.04 | 0.04 | **0.32** |
| coverage @ floor 0.7 | 0.0 | 0.0 | 0.0 | **0.24** |
| precision @ floor 0.5/0.6/0.7 | n/a (nothing surfaced) | 1.0 / 1.0 / n/a | 1.0 / 1.0 / n/a | **1.0 / 1.0 / 1.0** |
| recall @ floor 0.6 | 0.0 | 0.077 | 0.077 | **0.615** |

Files: `results/judgement_eval_1789921484.json` (before, inherited at the
start of this task), `results/judgement_eval_4q_with_broken_bools.json`,
`results/judgement_eval_2q_point_mass_confidence.json`, and
`results/latest_judgement_eval.json` (final). Each intermediate step is kept
rather than overwritten, because the middle columns are themselves findings:
dropping the broken `Bool`s barely moved coverage (0.04 -> 0.04 at floor
0.6) because the real ceiling was the confidence formula, not the extra
facts; only fixing *that* moved it.

**Reading the final column honestly.** At the production floor (0.6):
8 of 13 events that should surface do (`recall` 0.615), zero of 12 that
should not surface do (`precision` 1.0 across every floor from 0.5 to 0.9 --
no newsletter, receipt, or notification ever crosses the floor in this
fixture). The four misses at floor 0.6: `evt_en_client_question` and
`evt_it_colloquio` fall just under the floor (confidence 0.596 and 0.554);
`evt_en_invoice_overdue` and `evt_en_security_alert` are `urgency` scored 0
outright -- both are automated notices where the model's `message_type`
call (`transactional`) is correct but the urgency rubric's own levels do
not have good language for "an automated notice that is nonetheless
critical" (a compromised account, an overdue invoice with a real
consequence). This is a real, unresolved limitation of the `urgency`
rubric, not a floor problem, and it existed before this task's changes too.

**The floor still trades recall for precision as it always did** -- coverage
falls from 0.36 to 0.08 between floor 0.5 and floor 0.9 -- but for the first
time the trade is a real curve instead of a cliff to zero. Before this
change, `results/judgement_eval_1789921484.json` shows coverage at exactly
0.0 for every floor from 0.5 up: nothing would ever have surfaced in
production at the default floor of 0.6.

## Letter-order bias

Every `Choice`/`Score` readout is answered by reading logits at a lettered
position (A, B, C, ...), and models are known to favour early letters
independent of content. `judgement_eval._letter_bias_check` answers
`message_type` a second time per event with its four options in reversed
order and diffs the results: **7 of 25 answers moved (28%)**
(`results/latest_judgement_eval.json`, key `letter_order_bias`). All seven
moves were between `transactional` and `personal_no_ask` -- non-actionable
categories on both sides -- and none flipped an event into or out of
`personal_request`, so none of the seven changed the final `should_surface`
outcome in this fixture. That is a fact about this fixture, not a proof the
bias is harmless: a 28% answer-flip rate on a 4-option `Choice` is large
enough that it will eventually land on a boundary that matters, and this
was checked for one question, not for every `Choice` in the system. **This
generalizes: every `Choice`/`Score` readout in `bobbd` is subject to the
same risk**, and the fix (averaging over multiple option orderings, or
otherwise correcting for position) is unimplemented future work, not
something this task closed out.

## Benchmark (Task 3)

`bobbd/bench.py`'s idle gate (`_check_idle`) now **refuses** -- raises
`NotIdleError`, writes nothing to `results/` -- rather than proceeding on a
loaded machine and labelling the result contaminated. The previous
`results/latest_bench.json` (load1 4.68 against ceiling 3.0, measured
anyway) is superseded.

**Before the question-set rework** (`results/bench_before_question_rework.json`,
also `results/bench_1789921676.json`), captured on a quiet machine
(`load1: 1.65`, `load5: 1.68`, ceiling 3.0, `settled: true`, 6 repetitions,
variants interleaved per repetition):

| | median | min | max |
|---|---|---|---|
| `mail.opened` decide (3 questions: `reply_needed`, `urgency`, `interrupt`) | 1243.32 ms | 1184.55 ms | 1332.51 ms |
| `mail.composing` decide (3 questions) | 550.80 ms | 526.11 ms | 587.94 ms |
| `text.selected` decide (3 questions) | 550.98 ms | 531.93 ms | 589.04 ms |
| socket round trip (event -> trace -> decision) | 1256.08 ms | 1201.21 ms | 1341.22 ms |
| `decide_many` vs sequential `decide`, k=8 | 1196.52 ms vs 3104.19 ms (2.594x) | | |

**After the question-set rework: not captured cleanly in this session.**
The machine was quiet (`load1: 1.65`) for exactly long enough to take the
"before" measurement above, then loaded steadily for the remainder of the
task -- `load1` observed at 3.58, 4.47, 4.50, 4.87, and finally spiking to
9.37 against the 3.0 ceiling, `top_processes` showing a mix of
`mediaanalysisd` (200%+ CPU, sustained), `swift-frontend` (an Xcode/Swift
build), and other agents' own processes. `bench.py`'s hardened
`_check_idle` refused every one of these -- raised `NotIdleError`, wrote
nothing to `results/` -- rather than writing a number against a 3-9x
overloaded machine and calling it a benchmark. That refusal is the
correct, intended behaviour this task asked for, not a shortfall in it:
`results/latest_bench.json` is still the clean pre-rework run above, and no
contaminated post-rework file exists anywhere in `results/`.

The post-rework number remains genuinely outstanding. It costs one command
on a quiet machine:

```
uv run python -m bobbd.bench
```

Expected shape of the change, from the design alone rather than a
measurement: `mail.opened` now asks 2 questions (`message_type`, `urgency`)
instead of 3 (`reply_needed`, `urgency`, `interrupt`), so its per-decision
latency should fall roughly in proportion -- `decide_many`'s own k=2 vs. k=4
figures above (479.62 ms vs. 718.32 ms median) are the closest same-machine
analogue already on record, but this is a plausibility check, not a
substitute for re-running `bench.py` itself.

## Task 4: scoring action candidates (`bobbd/act.py`)

Implements `docs/CONTRACT.md`'s "action loop": `observe` -> `act`. Two
readouts, `operation` (8-way `Choice`: `CLICK`/`TYPE_TEXT`/`SELECT`/
`SCROLL_UP`/`SCROLL_DOWN`/`WAIT`/`DONE`/`BLOCKED`) and `target` (one `Choice`
per candidate id), answered together by one `decide_many` call off a single
prefill -- not two calls. `text` is generated with the resident model, via
`mlx_lm.generate`, only when `operation == "TYPE_TEXT"` and the step did not
abstain; every other step is the constrained readout alone.

**Candidate cap.** `MAX_CANDIDATES = 20` (documented, includes `done` and
`escalate`); `score_action` raises a clear `ValueError` naming the count and
the cap before ever calling the model if an `observe` exceeds it, rather
than letting `decide.py`'s own 26-letter alphabet ceiling be the first
thing a caller hits.

**Security boundary.** `tests/test_act.py` enforces, not just documents,
that this module never sees or emits a tool name, a coordinate, an argument
or a file path: `Candidate` and `ActResult`'s dataclass fields are asserted
exactly (`id`/`label`/`role`/`enabled` and
`operation`/`candidate_id`/`confidence`/`schema_mass`/
`operation_probabilities`/`probabilities`/`text`/`latency_ms`/`abstained`),
the module's own source (docstrings excluded) is scanned for a banned-symbol
list (`subprocess`, `AppKit`, `CGEvent`, `pyautogui`, `Quartz`, `shell=True`,
...), and behavioural tests assert `operation` is always one of the
declared eight and `candidate_id` is always one of the ids the caller
offered. Any of these failing means the boundary was crossed.

## Task 5: mail lifecycle events

`mail.arrived`, `mail.closed`, `mail.archived`, `mail.deleted` now have
`EventIntent` entries in `intents.py` with `questions=()`, the same
zero-forward-pass pattern `idle.entered`/`idle.left` already used:
`attention.decide_event`'s `if intent.questions:` guard means
`decide_many` is never called for these kinds at all --
`tests/test_attention.py::test_mail_lifecycle_events_cost_no_forward_pass`
monkeypatches `decide_many` to raise if it is ever called and asserts these
four kinds never trigger it. They record a deterministic `ignore` decision
to the audit store and exist purely as training-data signal for the
personal-specialist pipeline, per `docs/CONTRACT.md`.

## What did not work / is not closed out

v0.1 items, with their 1.0 status:

- **`deadline_stated` / `sender_waiting_on_user`**: designed, measured,
  found broken (constant `true`), removed. Still removed.
- **Letter-order bias**: fixed in 1.0 by reading `message_type` in both
  orders and averaging (above).
- **`urgency` missed "automated but critical"**: addressed by the 1.0 rubric;
  measured only on the reference engine.
- **Full-pipeline sensitivity to letter order**: measured on the reference
  engine for 1.0 (no final action moved); not re-measured on MLX.
- **The post-rework MLX latency figure** was never captured cleanly, and 1.0
  added readouts (the debiased `message_type`, `tone`). Re-run
  `python -m bobbd.bench` on an idle Apple-silicon Mac before quoting any
  1.0 latency.
- **`observe`/`act`** is now wired into `server.py` (`_on_observe`); the app
  does not drive other applications yet in 1.0.

## Running things

```
uv run pytest -q                        # full suite, includes test_no_network.py and the slow real-model tests
uv run python -m bobbd.judgement_eval # writes results/judgement_eval_<ts>.json and results/latest_judgement_eval.json
uv run python -m bobbd.bench          # writes results/bench_<ts>.json and results/latest_bench.json; refuses under load
uv run pytest -q -m "not slow"          # the fast suite CI runs on Linux
uv run python tools/reference_eval.py   # the A/B above, on the CPU reference engine (slow)
uv run python tools/quality_probe.py    # read actual drafts and answers side by side
uv run python tools/export_contract_fixtures.py  # regenerate the Swift contract fixtures
```
