# Leonard

A personal assistant that lives on your Mac, knows your working life, decides
for itself when to act, and drives the computer.

> **Read [`docs/VISION.md`](docs/VISION.md) first.** It is the governing logic
> and everything else is subordinate to it. Seven rules: never integrate — only
> use; remember everything on screen; learn by watching, never by asking; speed
> from the architecture, not from optimization; two local models, one job each;
> any job, not a list of jobs; it lives in the menu bar like Siri. All of it
> local, by architecture.

All of it on-device. Not local where convenient — local because the product is
impossible any other way.

## The trap everyone else is in

An assistant is useful in proportion to how much it knows about you. An
assistant that has read every email you sent, sat through every meeting and
watched how you actually work is a different category of thing from one you
paste context into.

And that is the trap: **the more it needs to know, the less you can let it
phone home.** Every competitor's architecture requires your mail, your
messages and your screen to arrive on their servers. So they stay shallow, or
they ask for something you should not give.

> Every other assistant has to choose between knowing you and protecting you.
> Leonard does not have to choose.

## Two systems

**System 2** — a resident 4-bit model. Ambiguous requests, unfamiliar plans,
writing, recovery. Slow, general.

**System 1** — a fleet of tiny specialists. Every bounded repeated decision:
interrupt or stay quiet, which app, which field, which contact, reply or
archive. A closed set of options scored in one forward pass with a calibrated
probability.

The industry's numbers for the System 1 half, from Cua's open CUA-S1-FORMS:
706,048 parameters, a 2.8 MB checkpoint, 7–9 ms. In its narrow domain it
measured 99.7% against hosted Jev's 83.6% — a decision-level result on a
narrow experiment, with the specialist trained for the task and Jev not, and
the two latencies measuring different boundaries. Their caveats, kept.

## Why that matters more than it looks

A 2.8 MB model can be **trained on the user's machine, on the user's
behaviour.**

Leonard does not only run locally. It *learns* locally, and mints its own
specialists as it goes.

- **Day 1** — the decision goes to the resident general model. Generic
  judgement. Leonard records what it decided and what you did about it.
- **Day 30** — it has thousands of your answers, fits a specialist, and
  answers in single-digit milliseconds, better than the general model was,
  because it was fitted to you.

**Leonard gets faster the longer you use it.** The latency goes down on a
chart and the accuracy goes up, and you can watch it happen.

No hosted service can offer that, because training on your behaviour means
holding your behaviour.

## Silence is the product

Most of the time the right answer is to say nothing. Leonard is built so that
"nothing" is a measured outcome rather than a missing feature: every candidate
interruption is a typed decision with a calibrated probability, and a
confidence floor you control decides what reaches you.

And because silence is invisible, Leonard ships **Mind** — a live window onto
what it noticed, what it decided, and every time it decided you were not worth
interrupting, with the confidence that fell short. Near-misses are shown more
prominently than hits.

## Architecture

```
  Mail · Calendar · any app · the screen
            │
     Sensors — AX tree first, screen when it must
            │
        Frame gate — skips what cannot have changed the answer
            │
   Tier 0   personal specialist    ~10 ms   every event
   Tier 1   resident 4-bit model   ~150 ms  when tier 0 is unsure
   Tier 2   —                      there is no tier 2
            │
   ignore   wait   prepare   suggest
                               │
                     Overlay — Prepara / Ignora
```

Two processes over a unix socket at
`~/Library/Application Support/Leonard/leonardd.sock`. `leonardd` binds no TCP
port and opens no outbound connection; a test fails the build if it can.

## Documents

| | |
|---|---|
| [`VISION.md`](docs/VISION.md) | **The governing logic. Read first.** |
| [`PRODUCT.md`](docs/PRODUCT.md) | What the product is, and what the MVP is |
| [`SCREEN-MEMORY.md`](docs/SCREEN-MEMORY.md) | Remembering everything on screen, and why it must be local |
| [`SPECIALIST.md`](docs/SPECIALIST.md) | How a personal specialist is minted, and the censored-label problem |
| [`SYSTEM-ONE.md`](docs/SYSTEM-ONE.md) | The category, and where Leonard sits in it |
| [`CUA-INVESTIGATION.md`](docs/CUA-INVESTIGATION.md) | Source-verified due diligence on Cua and CUA-S1 |
| [`CONTRACT.md`](docs/CONTRACT.md) | The frozen wire protocol |
| [`SENSOR-MAIL.md`](docs/SENSOR-MAIL.md) | What the accessibility tree actually requires |
| [`ADR-001`](docs/ADR-001-attention-is-a-typed-decision.md) … [`ADR-004`](docs/ADR-004-why-not-jev.md) | Why typed decisions, why no network, why no Xcode, why not Jev |

## Status

v0.1, in active development. Measurements land in `leonardd/results/` and
`specialist/` as they are taken. Numbers quoted from
[`locali`](https://github.com/gabrielekarra/locali) or from Cua are theirs, on
their conditions, and are not interchangeable with ours.
