# Minting a personal specialist

How Leonard learns one person's interruption preferences on their own machine.
This is the part no one else has built, so it is the part most likely to be
wrong. Written 2026-09-20.

## What shipped in 1.0

The first personal specialist is live, deliberately smaller than the design
below: a logistic regression over hashed features, trained on the Mac in
NumPy from explicit, implicit and teacher labels, turned on only after it
beats or matches the resident model on the user's own newest answers, and
allowed to decide only a confident "this can wait" (ADR-008,
`leonardd/specialist.py`). The implicit labeller (a reply started, a
message left unread within seconds) and the validation gate described here
are in it. The transformer below is the next specialist, behind the same
gate, when there is data to feed it.

## What we are fitting

A replacement for the `interrupt` readout: given an event and its context,
score `ignore / wait / prepare / suggest` and return a calibrated probability.

Target shape, adapted from CUA-S1-FORMS (706,048 parameters, 2.8 MB, MIT,
byte-level embedding plus a 2-layer transformer encoder scoring each option):
a context encoder over a structured serialization of the event and the recent
event history, and an option head scoring a fixed four-way action set.

The forms model's entity-pointer branch does not apply — our action set is
fixed, which is the easier of its two branches.

## Why the CUA-S1 recipe does not transfer

Their training data is synthetic, generated once by the model's authors from a
concept catalog of form-field types. That works because a form field is
synthesizable: you can enumerate plausible address fields forever.

One person's sense of when they want to be interrupted is not synthesizable.
There is exactly one source of truth for it and it is the person.

## The real problem: the labels are censored

This is the part that matters, and it is not a training problem, it is a data
problem.

Leonard only learns the outcome of decisions it *acted on*. Every decision it
abstained on — which at a 0.60 floor is nearly half of them — produces no
label at all. We observe the reward only for the arm we pulled.

Three consequences:

1. **Censoring.** The abstained region, which is exactly where the floor sits
   and exactly where we most need resolution, is unobserved by construction.
2. **Sparsity of positives.** Most events deserve `ignore`. Approvals are rare
   and are what we are trying to predict.
3. **Non-stationarity.** Preferences move. The week before a deadline is not
   the week after one.

A naive fit on approve/dismiss alone learns the policy that generated the
data, not the policy the user wants. It will confidently reproduce Leonard's
current mistakes.

## Three mechanisms, in order of how much they buy

### 1. Implicit labels — by far the largest source

The user does not have to teach Leonard anything. They already answer the
question by what they do next.

| Observation | Label |
|---|---|
| Replied to that thread within the hour | `reply_needed` true, and the interruption would have been welcome |
| Archived or deleted unread | `ignore` was right |
| Opened, read for 40 seconds, left it unread | It mattered, but not then — `wait` |
| Opened the calendar right after reading it | The relevant context was the calendar |
| Never opened it at all | `ignore` |

None of this requires a click, a prompt, or a training mode. It requires
watching what already happens, which Leonard is doing anyway.

This is the mechanism that makes the whole thing tractable: it produces
thousands of labelled examples a month from ordinary use, and crucially **it
is not censored** — it labels events Leonard stayed silent on just as well as
the ones it surfaced.

It is also the answer to the cold-start problem in a second sense: a new
user's existing mailbox is a labelled corpus on day zero. What they replied
to, what they archived, how fast. We can fit a first specialist before Leonard
has ever interrupted anyone.

### 2. Deliberate exploration at the boundary

Implicit labels are dense but indirect. For the `interrupt` decision
specifically we still want the user's actual verdict near the threshold.

So Leonard occasionally surfaces a decision it would have abstained on,
sampled from just below the floor, and treats the response as a label. A small
exploration rate spent precisely where the model is least certain.

This must be visible. Mind marks those interruptions as what they are —
Leonard asking rather than telling — because an assistant that experiments on
you without saying so has broken the only thing it has.

### 3. Distillation for the cold start

Before there is any personal data, the specialist is trained to imitate the
resident 3B on unlabelled events: teacher's full distribution as the target,
not just its argmax, so the student inherits the uncertainty and not only the
answer.

Day 1 the specialist matches the 3B's judgement at a fraction of the cost.
Every day after, real labels pull it away from the teacher and toward the
user. The teacher stops being an authority and becomes a prior.

This also means the tier-0/tier-1 cascade degrades gracefully: at worst the
specialist is as good as the model it was distilled from.

## The loop

```
audit.db  ──  decisions, readouts, responses
    │
    ├── implicit labeller ── watches what the user did next
    │
    ├── explorer ── samples below the floor, marked as such in Mind
    │
    └── trainer ── distil from the 3B, then fit on real labels
            │
        specialist.safetensors  ~2.8 MB
            │
        CoreML export ── runs inside the Swift process, no Python
            │
        tier 0 ── every event, single-digit milliseconds
```

Retraining is an overnight job on an M4. Nothing leaves the machine — not the
data, not the gradients, not the checkpoint.

## What we must measure before believing any of it

1. **Does the implicit labeller agree with the user?** Sample its labels, ask
   the user directly on a small set, and report agreement. If implicit labels
   are noise, the whole design collapses and we need to know first.
2. **How many labels does a useful specialist need?** Fit on 100, 300, 1000,
   3000 and plot accuracy and calibration against the 3B baseline. This is the
   number that decides whether the moat is real.
3. **Does the specialist beat the teacher on the user, rather than only
   matching it?** If a personal specialist never overtakes the general model,
   the product is just a faster version of the same thing, which is worth much
   less.
4. **Does it stay calibrated?** A fast, confident, wrong specialist is worse
   than a slow honest one, because the floor is the whole safety mechanism.

Measurement 2 is the one to run first and it is cheap. Everything else in this
document is downstream of the answer.

## Honest position

The architecture is borrowed and proven. The training loop is borrowed and
proven. **The data is the research risk, and it is entirely ours.** Nothing in
Cua, in TypeSafe's Jev, or in the literature we found does this for real
end-user behavioural data on-device.

If implicit labelling works, the moat is real and compounds per user. If it
does not, Leonard is still a good local assistant, but it is a product anyone
with a GPU budget could copy.
