# specialist

Mints Leonard's personal, on-device specialist: a byte-level tiny
transformer that scores `ignore` / `wait` / `prepare` / `suggest` from one
user's own `audit.db`, distilled from the resident model and then fit on
real labels. See `/Users/gabrielekarra/dev/leonard/docs/SPECIALIST.md` for
the design this implements and `docs/CUA-INVESTIGATION.md` sections 2.1-2.6
for the architecture it is adapted from.

**Nothing has been trained yet.** Every test in this package runs on tiny
synthetic tensors and fixtures — `uv run pytest -q` finishes in about 3-5
seconds. `scaling.py`'s real experiment (fit on 100/300/1000/3000 real
labels) is written and runnable but refuses to execute unless
`confirm_heavy=True` is passed explicitly, and nothing in the test suite
passes it — see "What has and has not been validated" below.

## Architecture (`model.py`)

`SpecialistScorer`: a byte embedding (vocabulary 257 = 256 byte values + 1
padding id) plus a learned position embedding, a 2-layer
`nn.TransformerEncoder` over the serialized event context, a 1-layer
`nn.TransformerEncoder` applied to each of the four fixed action
descriptions, mean-pooled, and one `AttentionHead` (LayerNorm both sides,
low-rank query/key/value, one cross-attention pass, `logit = (query ·
attended) / sqrt(rank)` per option) turning that into one score per action.

This is adapted, near-verbatim, from CUA-S1-FORMS's `TinyTransformerScorer`/
`AttentionHead` (`cua_s1/model.py`, MIT, Cua AI Inc.), at its exact default
hyperparameters: width 128, rank 128, layers 2, heads 4, context_tokens 224,
option_tokens 96. CUA-S1-FORMS has two branches — an entity-pointer branch
for "fill this field with that document entity" (a variable-size option
table per example) and a fixed-action branch for "check / click / skip" (a
constant option table). Leonard's action set never changes size or
membership, so `SpecialistScorer` is built entirely on the fixed-action
shape; there is no pointer mechanism anywhere in this codebase.

**Parameter count actually achieved: 706,048** (verified by
`tests/test_model.py::test_parameter_count_matches_cua_s1_forms_target`,
which asserts the exact value, not an approximation) — this is not a
coincidence, it is CUA-S1-FORMS's own published count, reproduced exactly
because the hyperparameters were copied exactly. At float32 that is a
2.82 MB checkpoint, matching the design target in `SPECIALIST.md`.

## Context serialization (`model.serialize_context`)

**This format is versioned in spirit even though it carries no explicit
version field. Changing field order, a character cap, or the history
encoding invalidates every checkpoint trained against it.**

One event plus up to 5 immediately preceding events (`MAX_HISTORY_EVENTS`)
render into one deterministic UTF-8 string, byte-truncated to
`context_tokens` (224) by `SpecialistCollator`. Fields are ordered
most-discriminating-first so byte truncation drops the least useful
information last, and free-text fields are clipped in Python to a fixed
character budget *before* that truncation, so a long body cannot silently
push the sender or subject out of the 224-byte window:

```
K <kind>                  event kind, e.g. mail.opened
A <app or ->
T h<hour 0-23> d<weekday 0=Mon..6=Sun>
U <user_state>             typing / reading / idle / meeting
F <actor>                  sender / to / previous_app, kind-dependent (cap 40 chars)
J <title>                  subject / window title, kind-dependent (cap 60 chars)
N <key>=<value> ...        thread_len, unread, idle_seconds, surrounding — sorted by key
H <kind>:<action>;...      up to 5 preceding events, oldest to newest (cap 60 chars total)
B <body excerpt>           body / draft / selected text / url, kind-dependent (cap 80 chars)
```

A line is omitted entirely when its field is empty for that event kind (for
example `idle.entered` has no actor, title, or body). `user_state` is not
computed by this module — it is folded into the event dict by the caller,
exactly as `leonardd/leonardd/intents.py` folds it into context text rather
than asking the model to predict it, and for exactly the same reason: it
costs nothing to compute deterministically from event history, so there is
no reason to spend a forward pass guessing it.

Known simplification: `T`'s hour/weekday are read off `ts` in UTC, not the
user's local time zone, since `event` carries no time-zone field today. A
caller that wants "hour of day" to mean anything about the user's actual
day/night cycle needs to normalize `ts` to local time first.

## The implicit labeller (`labels.py`) — every rule, and why

`SPECIALIST.md` names five behavioural observations. Two anchor event kinds
are labelled now: `mail.opened` (`leonardd/leonardd/intents.py`'s existing
sensor) and `mail.arrived` (`docs/CONTRACT.md`'s new "a message landed and
has not been opened" kind, added specifically because the first pass of
this module — see "Rules removed" below — showed the labeller was structurally
incapable of seeing the negatives). `mail.closed`, `mail.archived`, and
`mail.deleted`, also new in `docs/CONTRACT.md`, appear only as *subsequent*
evidence, never as anchors, since none of them represent a moment Leonard
would need to decide anything about.

| Rule | Anchor | Fires when | Label | Confidence | Rationale |
|---|---|---|---|---|---|
| `replied_within_hour` | `mail.opened` | A `mail.composing` event to the same thread (matched on `thread_id`, then normalized subject, then sender address) within 3600s | `suggest` | 0.9 | Direct behavioural evidence: the user acted on the thread promptly. `SPECIALIST.md`'s own example, verbatim. |
| `delayed_reply` | `mail.opened` | Same-thread reply between 3600s and 86400s later | `wait` | 0.65 | It mattered, just not urgently. |
| `calendar_after_reading` | `mail.opened` | An `app.activated`/`window.changed` event to a calendar app within 300s | `prepare` | 0.75 | The relevant context was the calendar — Leonard should have prepared it, per `SPECIALIST.md`'s own example. |
| `read_and_abandoned` | `mail.opened` | A same-message `mail.closed` with `dwell_ms >= 40000` and `still_unread: true`, no reply following | `wait` | 0.75 | **The rule this module previously refused to fake.** `docs/CONTRACT.md` added `mail.closed`'s `dwell_ms`/`still_unread` fields specifically so "opened, read for 40 seconds, left it unread" would stop being a guess. Higher confidence than `delayed_reply` because it is now a direct dwell + still-unread observation, not an inferred proxy. Abstains outright if either field is absent rather than approximating from event spacing. |
| `archived_unread` | `mail.arrived` | `mail.archived` or `mail.deleted` for the same message with no `mail.opened` anywhere before it, within 30 days | `ignore` | 0.92 | Highest-confidence rule in the set: archiving something you never opened is about as clear as this signal gets. |
| `never_opened` | `mail.arrived` | No `mail.opened` for the same message anywhere within 3 days, and enough time has actually elapsed to know that (see window reasoning below) | `ignore` | 0.5 | Lowest-confidence rule in the set: pure absence-of-evidence, the weakest form of evidence this module uses. |

Every rule is a pure function of `(event, subsequent_events)`, individually
unit-tested (`tests/test_labels.py`) for both the firing and non-firing
case, and individually disableable via `label_event(..., enabled_rules=...)`.
When more than one rule fires and they disagree on the label,
`label_event` **abstains** rather than picking one — disagreement between
independent behavioural signals is itself evidence the event is ambiguous,
and a wrong label poisons the training set worse than a missing one. When
they fire and *agree* (e.g. `archived_unread` and `never_opened` both firing
`ignore` for the same never-touched message), the combined result keeps the
higher confidence and records both rule names, joined with `+`.

### The two windows, and why those numbers

- **`NEVER_OPENED_WINDOW_SECONDS = 259200` (3 days).** Chosen against an
  explicit failure case: someone who reads mail twice a day. Twice-daily
  checking implies gaps up to roughly 12 hours; a single busy or offline day
  can double that. Three days gives headroom for a missed day plus a
  weekend, or a short trip, without waiting so long the label becomes rare
  and stale. The asymmetry in cost is deliberate: too short and the rule
  actively lies (a real user who reads mail in batches gets falsely told
  "you'd have ignored this"); too long only delays and thins out an
  already-abundant label class. `rule_never_opened` also refuses to fire at
  all until it can see that the full 3-day window actually elapsed in the
  event stream — running out of subsequent rows early (near the end of the
  table, or because a caller passed a shorter lookahead) means "we don't
  know yet," not "never," and the rule abstains rather than guess which one
  it is.
- **`ARCHIVED_UNREAD_MAX_SECONDS = 2592000` (30 days).** Deliberately much
  longer than `never_opened`'s window, because the evidence here is an
  explicit user action (archiving), not absence — an inbox cleanup weeks
  later is still real evidence the message never mattered, so there is no
  reason to cut it off early the way absence-based reasoning requires. The
  bound exists only to cap scan cost and to limit how far a sender+subject
  fallback match (used when `thread_id` is missing) can drift into matching
  an unrelated later message with a coincidentally identical subject line.

Both are exposed as module-level constants specifically so they can be
re-tuned once `data.implicit_explicit_agreement` has real numbers to tune
them against — `data.LOOKAHEAD_SECONDS` is derived from
`max(ARCHIVED_UNREAD_MAX_SECONDS, NEVER_OPENED_WINDOW_SECONDS)` rather than
hardcoded, so the two cannot silently fall out of sync.

### Rules removed

- **`quick_dismissal`** (previously: switched to a different app or went
  idle within 5 seconds of opening, with no reply or calendar visit later →
  `ignore`, confidence 0.55) **has been removed.** It was already flagged as
  the rule most likely not to survive contact with real data, and `mail.
  closed`'s real `dwell_ms` makes the reason concrete: "time until the next
  unrelated event" and "how long this specific message stayed open" are
  different quantities that happen to correlate loosely — the old rule
  measured the former as a proxy for the latter, which is exactly the kind
  of approximation this module exists to avoid (it is the same criticism
  `delayed_reply` used to carry against the dwell-based rule it stood in
  for, now turned back on itself now that a real dwell signal exists).
  `read_and_abandoned` and `archived_unread`/`never_opened` between them
  cover the same territory `quick_dismissal` was reaching for — short real
  dwell versus long real dwell, and no engagement at all — with actual
  telemetry instead of a proxy. No replacement short-dwell rule was written
  in this pass (e.g. "`mail.closed` with `dwell_ms` under some threshold and
  `still_unread: true`, no reply → `ignore`"); it is a natural next rule,
  deliberately left for a future pass rather than added here to keep this
  change to exactly what was asked.

### Rules considered and rejected

- **Picking a label when rules disagree** (e.g. averaging confidences, or
  taking the higher-confidence rule as a tiebreaker). Considered and
  rejected: two independent behavioural signals pointing at different
  labels is evidence of genuine ambiguity in that specific event, not noise
  to be averaged away. `label_event` abstains instead.
- **Approximating `dwell_ms` from event spacing when `mail.closed` omits
  it**, rather than abstaining. Considered and rejected for `read_and_
  abandoned`, for the same reason `quick_dismissal` is being removed: it
  conflates "the user kept reading" with "the user stepped away from the
  computer entirely," and this module's entire premise is that a wrong
  label is worse than a missing one.

## Data assembly (`data.py`)

`build_examples` turns `audit.db` rows into `Example`s three ways:

- **Explicit** — a row with a `response`. `approve` labels the row with the
  action Leonard actually surfaced (confirmed correct); `dismiss` labels it
  `ignore`, since a dismissed suggestion only tells us the surfaced action
  was wrong, not what the right one was, and "the user would rather have
  been left alone" is the closest available proxy. **This is a modeling
  assumption, not an observation** — flagged here and in the module
  docstring so it is easy to revisit once there is enough real dismiss data
  to check it against the implicit labeller's independent signal via
  `data.implicit_explicit_agreement`.
- **Implicit** — `labels.label_event` run against the row and every later
  row in the same table (every event `leonardd` scores gets a `decisions`
  row per `leonardd/leonardd/server.py`'s `_on_event`, so "subsequent
  events" is simply later rows ordered by `ts` — no separate event log was
  needed).
- **Distillation** — the teacher's distribution for the `interrupt`
  question, read off `readouts`.

A row with both an explicit response and a firing implicit rule counts once,
as explicit. `mail.arrived`/`mail.closed`/`mail.archived`/`mail.deleted` rows
never carry a response (`docs/CONTRACT.md`: "they are recorded, not acted
on"), so they only ever reach the implicit path — `mail.arrived` as the
anchor for `archived_unread`/`never_opened`, the other three only as
subsequent evidence for those and for `read_and_abandoned`.

`LOOKAHEAD_SECONDS` (how far forward `build_examples`/`build_distill_
examples` gather `subsequent` events for each row) defaults to 30 days —
`max(labels.ARCHIVED_UNREAD_MAX_SECONDS, labels.NEVER_OPENED_WINDOW_
SECONDS)`, computed rather than hardcoded so it cannot silently fall out of
sync with the rules that need it. `never_opened` in particular would abstain
even on genuinely "never opened" mail if handed a shorter lookahead, since
it cannot distinguish "we waited the full window and saw nothing" from "the
caller only gave us a week" — see that rule's docstring.

**Known data gap, found while building this:** `leonardd/leonardd/
attention.py`'s `_readout_frame` only persists the chosen answer's
confidence (`Decision.confidence`), not `Decision.probabilities` — the full
calibrated distribution `SPECIALIST.md`'s distillation stage needs
("teacher's full distribution as the target, not just its argmax"). Today's
`audit.db` therefore cannot support proper KL distillation as designed.
`data._teacher_distribution` prefers a `probabilities` field if a future
`leonardd` schema adds one to `readouts`, and otherwise falls back to a
peaked pseudo-distribution (the stored confidence on the chosen action, the
remainder split uniformly across the other three) — a materially worse
distillation target, used only because nothing better is currently logged.
**Fixing this properly means widening `leonardd/leonardd/attention.py`'s
`_readout_frame` to persist the full `probabilities` dict, which is a change
to `leonardd/`, out of scope and off limits for this package.** This is the
single most actionable finding in this whole exercise for someone working in
`leonardd/`.

`time_split` splits **by time, not at random**: sort by `ts`, cut by
position. `tests/test_data.py::test_time_split_preserves_chronology_
regardless_of_input_order` checks the no-leakage invariant (nothing in
validation precedes anything in train, nothing in test precedes anything in
validation) even when the input arrives shuffled.

## Training (`train.py`)

Two stages, both AdamW + cosine schedule with linear warmup + gradient
clipping at norm 1.0, CUA-S1's own recipe reused as-is:

1. **Distillation** — `KL(teacher || student)` via
   `F.kl_div(log_softmax(student_logits), teacher_probs)` against
   `DistillExample.teacher_probs`.
2. **Supervised fit** — cross-entropy against `Example.label`, weighted by
   `Example.weight` (1.0 for an explicit response, the labeller's own
   confidence for an implicit one), so a shakier implicit label pulls the
   weights less than a direct human action.

`tests/test_train.py` checks both stages actually reduce their loss on a
tiny fixture (4-8 examples, 15-25 epochs, well under a second each) and that
per-example weighting visibly changes what the model learns.

## Metrics (`metrics.py`)

Accuracy, ECE, MCE, Brier, NLL — all against hand-computed values in
`tests/test_metrics.py`, not just "runs without crashing." **`separation`
(mean top-1 confidence when correct minus mean top-1 confidence when wrong)
is the headline number, not accuracy**: `SPECIALIST.md`'s confidence floor
only works as a safety mechanism if a correct call is reliably more
confident than a wrong one, so this is the number that decides whether a
floor can gate anything at all. `abstain_curve` reports coverage and
selective accuracy at floors 0.5/0.6/0.7, mirroring `leonardd/leonardd/
attention.py`'s own `DEFAULT_FLOOR` gate.

## Synthetic data (`synth.py`)

**Tests plumbing, not the thesis — see the module's own docstring, which
says this in full.** Nine hand-written scenario categories (boss deadlines,
client escalations, calendar invites, newsletters, automated notifications,
etc.), each with a true action label; four hard-negative category pairs
co-located in one event's *preceding history window* (there is no
per-example option table to co-locate confusable fields inside, the way
CUA-S1-FORMS does, since `model.ACTIONS` is always the same four strings);
`random.Random(seed + index * 7919)` per episode, so generation is
order-independent and reproducible; a stable SHA-256 hash of each row's
category signature buckets it into train/validation/test so the same
category (or hard-negative combination) never straddles a split boundary.

## Scaling experiment (`scaling.py`) — written, not run

`SPECIALIST.md` calls fitting on 100/300/1000/3000 labels "the one to run
first." `run_scaling_experiment` is fully implemented — fresh model per
size, trained on that many of the earliest chronological labels, evaluated
on a fixed held-out tail via `metrics.compute_metrics` — but it raises
`RuntimeError` unless called with `confirm_heavy=True`, and nothing in this
package's test suite passes that flag. **No real training run has happened
in this session, by design**: two other agents are running latency
benchmarks on this machine right now, and this session's mandate was to
write and unit-test the pipeline on tiny synthetic data only, not to spend
real compute. To launch it for real once `audit.db` has enough rows:

```python
from data import load_rows, build_examples
from scaling import run_scaling_experiment

rows = load_rows(audit_db_path)
examples = build_examples(rows)
report = run_scaling_experiment(examples, confirm_heavy=True)
```

## What has and has not been validated

**Validated in this session, on synthetic/tiny data only:**
- The architecture reproduces CUA-S1-FORMS's exact 706,048-parameter count.
- The context serialization is deterministic and truncates predictably.
- Every implicit-labelling rule fires and abstains exactly as specified,
  individually, including the conflicting-rules-abstain case.
- The chronological split leaks nothing regardless of input order.
- A distillation step and a supervised step each measurably reduce their
  loss on a tiny fixture; per-example weighting measurably changes what is
  learned.
- Every metric matches hand-computed values, not just "doesn't crash."

**Not validated, and cannot be validated without real data:**
- **Whether the implicit labeller agrees with the user** — `SPECIALIST.md`
  measurement 1. `data.implicit_explicit_agreement` is built and ready to
  run the moment real `audit.db` rows with both an explicit response and a
  fired implicit rule exist, but there are none yet.
- **How many real labels a useful specialist needs** — measurement 2,
  `scaling.py`, deliberately not run this session.
- **Whether the specialist beats the teacher on the user, not just matches
  it** — measurement 3. Currently blocked on the distillation data gap
  above: without the teacher's real distribution in `audit.db`, "beats the
  teacher" cannot yet be measured honestly, only "beats a peaked
  approximation of the teacher."
- **Whether it stays calibrated on real data** — measurement 4. `metrics.py`
  is ready; there is nothing real to point it at yet.

## Label balance

The reason this second pass exists: with the original four rules
(`replied_within_hour` → `suggest`, `delayed_reply` → `wait`,
`calendar_after_reading` → `prepare`, `quick_dismissal` → `ignore`), only one
rule produced negatives at all, and it was both the weakest-evidence rule in
the set *and* structurally blind to the dominant real-world case — most
inbox mail is never opened, or is opened and archived, and no event existed
for either of those before `docs/CONTRACT.md` grew `mail.arrived`/
`mail.archived`/`mail.deleted`/`mail.closed`. A dataset built from the old
four rules would have systematically under-represented `ignore`, because the
single most common real behaviour (indifference) had no rule capturing it —
exactly the failure mode named in the brief: a model over-eager to interrupt.

By rule count the set is now 2 `ignore` (`archived_unread`, `never_opened`),
2 `wait` (`delayed_reply`, `read_and_abandoned`), 1 `suggest`
(`replied_within_hour`), 1 `prepare` (`calendar_after_reading`) — but rule
count was never the right proxy for realized label balance, and still isn't.
What actually changed is *recall on the dominant class*: `archived_unread`
and `never_opened` between them should fire on a large fraction of
`mail.arrived` rows in any real inbox, because most incoming mail — most
newsletters, cc threads, automated notifications — genuinely is ignored,
whereas the old rule set had zero rules that could observe that at all. That
is a structural argument, not a measured one: **this package has no real
`audit.db` to run the new rules against, so "the balance now looks
defensible" is a qualitative judgment about which real-world behaviours are
newly observable, not a class-count I can report.** The only honest way to
turn it into a number is `data.build_examples` against real data, which is
exactly measurement 1 below, still unrun.

## What has and has not been validated

**Validated in this session, on synthetic/tiny data only:**
- The architecture reproduces CUA-S1-FORMS's exact 706,048-parameter count.
- The context serialization is deterministic and truncates predictably, now
  including `mail.arrived`'s sender/subject/body.
- Every implicit-labelling rule fires and abstains exactly as specified,
  individually, including the conflicting-rules-abstain and
  agreeing-rules-combine cases, and including `never_opened`'s
  window-not-yet-elapsed abstention.
- The chronological split leaks nothing regardless of input order.
- A distillation step and a supervised step each measurably reduce their
  loss on a tiny fixture; per-example weighting measurably changes what is
  learned.
- Every metric matches hand-computed values, not just "doesn't crash."

**Not validated, and cannot be validated without real data:**
- **Whether the implicit labeller agrees with the user** — `SPECIALIST.md`
  measurement 1. `data.implicit_explicit_agreement` is built and ready to
  run the moment real `audit.db` rows with both an explicit response and a
  fired implicit rule exist, but there are none yet. This is also now the
  only honest way to answer the label-balance question above.
- **How many real labels a useful specialist needs** — measurement 2,
  `scaling.py`, deliberately not run this session.
- **Whether the specialist beats the teacher on the user, not just matches
  it** — measurement 3. Currently blocked on the distillation data gap
  above: without the teacher's real distribution in `audit.db`, "beats the
  teacher" cannot yet be measured honestly, only "beats a peaked
  approximation of the teacher."
- **Whether it stays calibrated on real data** — measurement 4. `metrics.py`
  is ready; there is nothing real to point it at yet.

## Honest assessment: will implicit labelling survive contact with real data?

Every one of `SPECIALIST.md`'s five named observations now has an
implemented rule behind it. That changes the honest answer from the first
pass: the earlier version of this assessment bet against `quick_dismissal`
specifically because it was a proxy standing in for signal that did not yet
exist; that rule is gone now, replaced by rules built on the real telemetry
it was approximating. The remaining uncertainty is narrower and more
specific than "does the mechanism work at all" — it is about the two new
absence/negative rules, which are a genuinely different kind of evidence
from the four engagement-based rules (replied, composed a delayed reply,
checked the calendar, dwelled and left it unread): those four all observe
the user *doing something*, where `archived_unread` and `never_opened`
partly rest on the user doing *nothing*, which is inherently harder to
attribute to a single cause. `archived_unread` is the one I trust most of
the two — archiving is a deliberate action, not silence, so despite being a
negative it behaves evidentially like the positive rules. `never_opened` is
the one I would bet against first now: three days of silence is consistent
with "this didn't matter," but also with "this user batches email weekly,"
"this user was on vacation," or "this user reads mail in a client Leonard
doesn't instrument yet" — the window was chosen specifically to make the
first explanation more likely than the other three, but I have no real data
to confirm that judgment, only the reasoning behind the window. If
`data.implicit_explicit_agreement`, run on real data, is going to overturn
any rule in this set, `never_opened` is where I would look first — followed
by `read_and_abandoned`, since "read for 40+ seconds" and "found it boring"
are not the same thing as "read for 40+ seconds and consciously decided to
come back to it," and this rule cannot yet distinguish those either. The
honest headline is unchanged in spirit from the first pass: the mechanism is
sound and conservatively built, it now covers the full observation table
`SPECIALIST.md` names instead of three-fifths of it, and the real test —
measurement 1, agreement against a user-confirmed sample — still has not
happened and still cannot be simulated.
