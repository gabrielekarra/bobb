# ADR-004 — Why Bobb does not call Jev

Status: accepted, 2026-09-20

## Context

TypeSafe launched **Jev** on 2026-09-15: a "System One" model that takes a
block of text and a list of typed questions and returns answers with
probability distributions rather than generated text. Question types are
Choice, Score and Bool.

That is the same mechanism Bobb's attention engine is built on, and it
arrived as a product one day before the vision document that started this
project. It deserves a written answer rather than an instinct.

Vendor-stated facts as of launch:

| | |
|---|---|
| Weights | Closed. No download, no published self-host path |
| Deployment | US-hosted API, early-access waitlist |
| Latency | 70–500 ms |
| Price | $0.042 / M input tokens, output free |
| Data | Every decision round-trips to the vendor |

The macOS projects built on it — `jev-voice`, `jev-macos-loop`,
`computer-use-jev` — are frequently described as running locally. They do not.
Whisper, OmniParser and the automation layer are local; the *decision* is a
network call. `jev-voice` is explicit about it: local whisper.cpp plus one Jev
call per command.

## Decision

Jev is not used on the attention path. The attention path runs on a resident
local model and always will.

Jev may be used as a **measurement baseline**, against synthetic or explicitly
consented fixtures only, never against captured user data.

## Why

**It inverts the product's only hard constraint.** The attention path sees
message bodies, accessibility trees and screen contents — the most sensitive
surface on a personal machine. Routing it through a hosted API sends exactly
the data the product exists to keep local.

**It deletes the test that makes the claim credible.** ADR-002 is enforced by
`tests/test_no_network.py`. A Jev dependency means deleting that test, and a
privacy claim that rests on a policy instead of an architecture is worth
nothing.

**It makes Bobb a wrapper.** If the core loop is `POST /v1/systemone`, the
defensible asset belongs to the vendor, and the vendor can ship the overlay
themselves. The overlay is not the moat. Owning the decision is.

**Latency and cost are the weakest arguments, not the strongest.** 70–500 ms
and $0.042/M are good numbers. We are not choosing local because Jev is
expensive or slow. We are choosing it because of what the round trip carries.

## What Jev is worth to us

A baseline. Running the same typed question set through Jev and through the
resident local model on a fixture with no real user data gives a number the
pitch needs: how far a fully local System One sits from a hosted one. If the
gap is small, that measurement is the argument. If it is large, we need to
know before we present, not after.

## Strategic consequence

Jev's existence is net positive. It establishes the category, gives the
mechanism a name people have heard, and defines our position in one line:

> Jev proved typed decisions work. Bobb is the one that runs them on your
> machine.

The macOS agents built on Jev are the market evidence. Every one of them ships
a Mac user's screen to a US vendor to decide what to do next. That is the gap.
