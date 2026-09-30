# System One — the category, and where Bobb sits in it

Source: Francesco Bonacci, *"Jev, System One models and the future of computer
use"*, LinkedIn, September 2026. Read 2026-09-20. Supersedes part of ADR-004.

## The category

The framing is Kahneman's. A **System One** model makes a bounded decision
from a set of candidates the application already defined. It does not generate
prose, it does not invent tools, values or coordinates. You supply the context
and the decision to be made; you get back a typed result with a probability.

Jev's primitives are Choice, Score and Noul. Bobb's are Choice, Score and
Bool. The same shape, independently arrived at.

The proposed architecture is a split, not a replacement: a general model for
novel planning and value extraction, specialists for the repetitive bounded
decisions underneath. The stated benefit is that perception and decision can
then improve independently.

## The number that changes our design

The piece reports a specialist called **CUA-S1-FORMS**:

| | CUA-S1-FORMS (local) | Jev (hosted) |
|---|---|---|
| Decision accuracy, narrow form tasks | 99.7% | 83.6% |
| Latency | 7–9 ms | 260–280 ms |
| Size | 706,048 parameters, 2.8 MB | closed, hosted |

Read it carefully before celebrating. The authors are explicit that this
measures narrow form tasks and not general capability, and that the two
latencies measure different boundaries — a local forward pass against a hosted
round trip including network. It is not an apples-to-apples benchmark and it
is not evidence that a tiny model beats a large one at anything general.

What it *is* evidence for is the thing Bobb needs: **inside one bounded
decision, a sub-million-parameter specialist is competitive, and it is two
orders of magnitude cheaper to run.**

## What this changes for Bobb

Bobb's attention engine was designed around a resident 3B at roughly 150 ms
per decision. That is a sound v0.1 and it stays. But it is no longer obviously
the endpoint, because *"should I interrupt right now?"* is precisely the shape
of decision a specialist is for: bounded, repetitive, thousands of times a
day, and with a closed answer set of four.

The target architecture becomes a cascade with no cloud tier:

| Tier | Model | Cost | Role |
|---|---|---|---|
| 0 | Attention specialist, ~1M params | ~10 ms | Every event. `interrupt?` |
| 1 | Resident 4-bit 3B | ~150 ms | Only when tier 0 is uncertain, and for intent reading |
| 2 | — | — | There is no tier 2 |

`locali` already has `cascade.py` and `bench_cascade.py`. The cascade was
being built before we knew we needed it here.

## The prize, which nobody hosted can take

A 2.8 MB model is small enough to **train on the user's own machine, on the
user's own behaviour.**

Bobb's audit store was designed to record every decision alongside what the
user did about it — approve, dismiss, ignore. That is a labelled dataset of
one person's interruption preferences, accumulating from day one, never
leaving the machine. A tier-0 specialist of that size can be fitted to it
overnight on an M4.

So the product's answer to *"what does Bobb do on day 30 that it cannot do
on day 1?"* becomes concrete: **on day 30 the interruption policy is yours,
fitted to when you actually said yes.** A hosted System One cannot offer that
without holding your behavioural data, which is the one thing it must not
hold.

Local stops being a constraint we accept and becomes the only place
personalization can happen.

## The bottleneck the piece names, which we do not have

The authors flag perception as the limiting factor: vision-capable models need
a text representation of the interface, and producing one costs latency — the
OmniParser and OCR steps in the Jev macOS projects.

Bobb does not pay that. The accessibility tree *is* the text representation
of the interface, structured, free, and available synchronously from the OS.
Screen capture is the fallback, gated, not the primary path.

That is a real architectural advantage over every screenshot-driven computer
use agent, and it is worth stating plainly in the pitch.

## What this does not change

ADR-004 stands. Jev is not on the attention path, for the reasons given there,
and the strongest of those reasons is unaffected by any of this: the round
trip carries the user's screen.

If anything the piece strengthens it. Hosted Jev measured 83.6% on a narrow
task where a local 2.8 MB specialist measured 99.7%. The case for sending
sensitive context to a general hosted model, to make a decision a small local
one makes better, is now weak on capability as well as on privacy.
