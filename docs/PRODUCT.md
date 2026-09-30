# Bobb — what we are actually building

Supersedes the narrower framing in the first README. 2026-09-20.

## The product

A personal assistant that lives on your Mac, knows everything about your
working life — mail, messages, calendar, files, what you are doing right now —
decides on its own when to act, and can drive the computer itself.

All of it on-device. Not "local where convenient". Local because the product
is impossible any other way.

## Why this is not the same pitch as everyone else's

An assistant is useful in proportion to how much it knows about you. That is
the whole game. An assistant that has read every email you ever sent, sat
through every meeting, and watched how you actually work is a different
category of thing from one you paste context into.

And here is the trap every competitor is in: **the more it needs to know, the
less you can let it phone home.** Their architecture requires your mail, your
messages and your screen to arrive on their servers. So either they stay
shallow, or they ask you for something you should not give.

We do not have that ceiling. The assistant can know everything precisely
because nothing leaves.

> Every other assistant has to choose between knowing you and protecting you.
> Ours does not have to choose.

## The two systems

Kahneman's split, which the industry has now named for us.

**System 2** — a resident general model. Understanding an ambiguous request,
planning an unfamiliar sequence, writing an email, recovering when something
unexpected happens. Slow, general, expensive. Runs on a 4-bit model resident
in unified memory.

**System 1** — a fleet of tiny specialists. Every bounded, repeated decision:
interrupt or stay quiet, which app, which field, which contact, reply or
archive, is this worth saving. Each one is a closed set of options scored in a
single forward pass, with a calibrated probability.

The industry's own numbers for the System 1 half, from Cua's CUA-S1-FORMS:
**706,048 parameters, a 2.8 MB checkpoint, 7–9 ms**, and in its narrow domain
it measured 99.7% against hosted Jev's 83.6%. Their caveats matter and we keep
them: that is a decision-level result on a narrow experiment, the specialist
was trained for the task and Jev was not, and the two latencies measure
different boundaries.

## The thing nobody else can do

A 2.8 MB model can be **trained on the user's own machine, on the user's own
behaviour.**

That is the whole company in one sentence. Bobb does not just run locally.
It *learns* locally, and it mints its own specialists as it goes.

- **Day 1** — a decision goes to the resident general model. ~200 ms. Generic
  judgement. Bobb records what it decided and what you did about it.
- **Day 30** — that decision has been made a few thousand times and Bobb
  has a labelled set of your answers. It trains a specialist. ~8 ms, and
  better than the general model was, because it was fitted to *you*.

**Bobb gets faster the longer you use it.** Not a metaphor — the latency
number goes down on a chart, and the accuracy goes up, and the user can watch
it happen.

Nobody hosted can offer that, because to train a specialist on your behaviour
they would have to hold your behaviour.

## Where the pieces come from

| Layer | Source |
|---|---|
| Actuation, accessibility tree, window state | Cua Driver, MIT — under investigation |
| Specialist architecture and training recipe | CUA-S1-FORMS, MIT, including the synthetic data generator |
| Typed decisions, calibration, abstention, frame gating | `locali`, ours, measured |
| The general resident model | 4-bit MLX, ours to choose |
| Personal specialist minting from the audit store | **Ours. This is the company.** |
| Hosted decision API | Not used. See ADR-004 |

We are not competing with TypeSafe or with Cua. TypeSafe sells a hosted model.
Cua sells cloud desktop infrastructure to teams training agents, and gives the
driver and the specialists away. **Neither is building a personal assistant**,
and their business models are why.

## Scope of the product

The product does everything. This is not a phased ambition we grow into — it
is what Bobb is, and every architectural decision is made against it.

**It knows everything.** Mail, messages, calendar, documents, browser history,
code, meetings, the people you deal with and what you owe each of them. Not a
context window you paste into — a live model of your working life, on disk,
indexed, permanent.

**It sees everything.** Whatever is on screen, in whatever app, through the
accessibility tree first and the screen when it must.

**It decides for itself.** When to stay quiet, when to prepare, when to speak,
when to act. Nobody prompts it.

**It drives the computer.** Opens apps, fills forms, moves files, books the
meeting, replies to the message — under a permission engine, with high-impact
actions gated, and always reversible.

**It learns you.** Every decision and what you did about it becomes a labelled
example, and specialists get minted from them on your own machine.

**None of it leaves the Mac.**

That is the product. The MVP is one slice of it.

## The MVP

**Bobb watches your mail, decides on its own when to speak, prepares the
reply, and after a few thousand decisions mints its first specialist — live,
on the machine, with the latency dropping on screen.**

In scope:

| | |
|---|---|
| Sensors | Mail.app via accessibility, Calendar via EventKit, active app, idle, typing |
| Decision | Typed decisions on the resident 4-bit model, calibrated, confidence floor |
| Surface | Menu bar, non-activating overlay, Mind, Audit |
| Action | **Any application.** Cua Driver drives the live desktop; the permission engine gates what matters |
| Learning | Audit store, and the first minted `interrupt?` specialist |

Out of scope for the MVP, in the product: messages, files, browser history,
meetings, and the rest of the specialist fleet.

### Why general computer use is in the MVP and not after it

Because the decision machinery is identical. Choosing among four interruption
actions and choosing among forty on-screen controls are the same operation: a
closed candidate set scored in one pass, with a floor and an abstention. The
action loop in `CONTRACT.md` is the attention loop with a longer option list.

Restricting the MVP to drafting an email would not have made it smaller, only
narrower, and it would have hidden the thing that makes Bobb a product
rather than a feature: it does the work, in the app, on your machine.

The bound on risk is structural rather than a matter of trusting the model.
The decision layer sees opaque ids with human labels and returns one id. It
cannot express a command, a path or a coordinate, so the worst a wrong score
can do is press a different button that was already on screen and already
enabled. Everything destructive sits behind `ask`, and protected applications
are never observed at all.

The MVP is chosen for one reason beyond being demoable: **it is the slice that
generates the training data the whole product depends on.** Attention
decisions accrue thousands of labelled accept/dismiss events per week from
ordinary use. Nothing else we could build first does that.

And it puts the research risk first instead of last. If a personal specialist
cannot be fitted from a few thousand real decisions, we need to know in week
four, not year two.

## The honest risks

**On-device specialist training from sparse real behaviour is unproven.**
CUA-S1-FORMS was trained on synthetic data for a narrow, well-posed task. Our
bet is that a few thousand real accept/dismiss events are enough to fit a
useful personal specialist. That is the research risk and it is the whole
thesis. We should test it early and cheaply, before building anything else on
top of it.

**A local general model writes worse email than a frontier one.** True today.
Mitigated by the fact that System 2 quality matters less than System 1 timing
for the core promise — but not eliminated, and we should not pretend otherwise.

**Scope.** Everything above is years. The wedge is the defence.

**Trust and permissions.** An assistant that reads everything and can drive
the machine is the most invasive software a person will ever install. The
audit trail and the permission engine are not features, they are the price of
admission.
