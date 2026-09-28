# Roadmap

| Milestone | Goal | State |
|---|---|---|
| v0.1 "It sees" | AX sensors, event bus, menu bar, overlay, Mind, unix-socket contract | in progress |
| v0.2 "It decides" | Typed decisions on a resident local model, confidence floor, audit store | in progress |
| v0.3 "It anticipates" | Background preparation, the Mail.app magic moment end to end | next |
| v0.4 "It learns" | Calibration on real accept/dismiss data, per-user floor | |
| v0.5 "It remembers" | Projects, people, long-term memory, explainable recall | |
| v1.0 "It is a companion" | Broader sensors, permission engine, onboarding, distribution | |

## v0.1 + v0.2 definition of done

A user works normally on a Mac. Without opening Leonard or asking it anything,
Leonard notices a message that needs a reply, decides the interruption is
justified, and offers to prepare a draft at a moment that feels right. Every
decision it did not surface is visible in Mind with the reason it stayed quiet.

Measured, on a fanless M4 with 24 GB:

- event to decision, end to end, under 250 ms after warm-up
- screen path: frames skipped without missing an event
- abstain curve: accuracy against coverage at floors 0.5 / 0.6 / 0.7
