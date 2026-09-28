# Roadmap

| Milestone | Goal | State |
|---|---|---|
| v0.1 "It sees" | AX sensors, event bus, menu bar, overlay, Mind, unix-socket contract | done |
| v0.2 "It decides" | Typed decisions on a resident local model, confidence floor, audit store | done |
| v0.3 "It anticipates" | Background preparation, the Mail.app moment end to end | done in 1.0 |
| v0.4 "It learns" | Per-user floor from real accept/dismiss data, muted senders | done in 1.0 (per kind) |
| v0.5 "It remembers" | Screen memory, grounded and cited answers | done in 1.0 (text memory, Ask) |
| **1.0 "A product"** | Onboarding, one verified download, command bar, drafts with variants and fact check, settings, licensing, bundled runtime, signed DMG, website, fulfillment | **built and green; release waits on [LAUNCH.md](LAUNCH.md)** |
| 1.1 "Fits in" | Outlook for Mac lens; managed-preference policies for firms (memory off, retention) | next |
| 1.2 "Knows you" | First personal specialist distilled from the audit log (`specialist/`), shown in Mind with its latency and agreement | |
| 1.3 "Does it" | `observe`/`act` driving other apps, with the permission engine and a visible undo | |

## How the next milestones are decided

Leonard has no telemetry, so the order after 1.0 is set by support mail,
refund reasons and the design partners in [`BUSINESS.md`](BUSINESS.md).
Every milestone keeps the rules in [`VISION.md`](VISION.md): local by
architecture, silence as a measured outcome, never send on the user's behalf
without a visible, explicit action.

## Definition of done for any release

- CI green on macOS and Linux; the DMG builds and the bundled engine passes
  its smoke test.
- The real-Mac checklist in [`LAUNCH.md`](LAUNCH.md#1-qa-pass-on-a-real-mac)
  passes on the release candidate.
- Any number quoted in the release notes has a JSON file under
  `leonardd/results/` behind it.
