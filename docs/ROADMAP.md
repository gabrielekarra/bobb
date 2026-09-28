# Roadmap

VISION.md describes one product, not phases. This is where each part of it
stands.

| Part of the product | VISION rule | State in 1.0 |
|---|---|---|
| Menu bar presence, overlay, Mind | 7 | shipped |
| Typed attention decisions, calibrated, with a floor you control | — | shipped, mail and chats |
| Drafts grounded in what you saw, with checks | 5 (text model) | shipped, mail and chats |
| Screen memory, text only, redacted, cited in answers | 2 | shipped, plus opt-in OCR |
| Doing any job in any app, from outside, under a permission engine | 1, 4, 6 | shipped (ADR-007) |
| Voice | 7 | shipped, on-device only |
| Calendar: briefs before meetings, schedule in memory | — | shipped (EventKit, read-only) |
| People and what you owe them | — | shipped: promises from sent mail |
| Learning by watching: personal floor, muted senders | 3 | shipped |
| Learning by watching: personal specialist (tier 0) | 3, 5 | shipped (ADR-008) |
| Learning by watching: procedures from tasks and demonstrations | 3 | shipped |
| Byte-level transformer specialist (`specialist/`) | 5 | research, next when data allows |
| Outlook and web mail as first-class lenses | 6 | next; today via screen memory and chats |
| A people view: everything about one person in one place | — | next |
| Promises from chats as well as mail | — | next |

## How the next steps are decided

Leonard has no telemetry, so the order is set by support mail, refund
reasons and design partners ([`BUSINESS.md`](BUSINESS.md)). Every step keeps
the rules in [`VISION.md`](VISION.md): local by architecture, silence as a
measured outcome, never send on the user's behalf without a visible,
explicit action.

## Definition of done for any release

- CI green on macOS and Linux; the DMG builds and the bundled engine passes
  its smoke test.
- The real-Mac checklist in [`LAUNCH.md`](LAUNCH.md#1-qa-pass-on-a-real-mac)
  passes on the release candidate.
- Any number quoted in the release notes has a JSON file under
  `leonardd/results/` behind it.
