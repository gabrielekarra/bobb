# Leonard

**The assistant that knows when to stay quiet — and does the work when you ask.**

Leonard lives in your Mac's menu bar. It reads what you read — mail, chats,
the window in front of you — remembers it as text, and decides with a
measured confidence whether something deserves your attention. When it does,
it drafts the reply. When you ask it for something, it does it, in your
apps, the way you would. When nothing needs you, it says nothing, and shows
you why. Two local models, one Mac, nothing ever leaves it.

<p align="center">
  <img src="docs/images/overlay-en.png" width="360" alt="Leonard's card: Marco Rossi is waiting for your reply">
  &nbsp;
  <img src="docs/images/task-asking-en.png" width="420" alt="Leonard doing a task, asking before it sends a message">
</p>

Built for people whose work is confidential — lawyers, accountants,
doctors, consultants, founders — and for anyone who would rather their
assistant knew everything and told no one.

## What it does

| | |
|---|---|
| **Knows what needs you** | Open a message in Mail, or a conversation in Slack, WhatsApp, Messages, Teams, Telegram and the rest. If someone is asking you for something, a small card appears once, with a one-line reason. Newsletters, receipts and FYIs never get a word. |
| **Writes like you** | Replies in the language and register of the message, grounded in what you have seen on screen, with sources. One click turns a draft into a yes, a polite no, a request for time or for details. Figures that appear nowhere else are flagged. It goes into Mail's reply window or the chat's message box; you press Send. |
| **Does it for you, in any app** | ⌥Space: "put on my Focus playlist", "make a new sheet with these totals", "tell Giulia on Slack I'll be ten minutes late". Leonard plans, then works the apps from outside — pressing, typing, scrolling, opening — one checked step at a time, and asks before anything that sends, pays or deletes. ⎋ stops it; Undo takes the last step back. |
| **Talk to it** | ⌥⇧Space and just say it. Speech is recognized on the Mac, never on a server. |
| **Remembers everything you saw** | The text of every window you work in (and, if you allow it, the words in images), searchable and cited in answers. Password managers, Keychain and private windows are never read; card numbers, keys and codes are redacted. Forget an item, an app, the last hour or everything. |
| **Remembers what you promised** | "I'll send you the contract by Friday" in a mail you sent becomes a promise with a date, waiting under "For you" until you mark it done. |
| **Briefs you before meetings** | Ten minutes before a meeting with other people: what you saw about it, what you promised them, one question worth asking. From your calendar, read on the Mac. |
| **Learns you, on your Mac** | Your answers train a personal specialist that decides alone when it is sure — in under a millisecond instead of half a second — and only after it has proved it agrees with you. Tasks that worked, and the ones you show it ("Show me how"), become the way it does them next time. |
| **Shows its work** | Mind lists every decision, every silence and how close it came, every task and every step, what it learned and how well it agrees with you. |

<p align="center">
  <img src="docs/images/ask-en.png" width="520" alt="Ask Leonard answering from screen memory, with sources">
</p>

## Private by architecture, not by policy

- **On-device model.** Llama 3.2 3B, 4-bit, running on Apple silicon through
  MLX. No API keys, no usage caps, works offline.
- **The engine cannot reach the network.** `leonardd` binds no TCP port and
  opens no connection; a test fails the build if it can
  ([ADR-002](docs/ADR-002-the-daemon-binds-no-network-socket.md)).
- **One download, ever**, started by you: the model, verified by SHA-256
  ([ADR-005](docs/ADR-005-the-one-download.md)). No telemetry, no account, no
  crash reporting, no auto-updater.
- **Voice, calendar and pixels stay local too.** Speech recognition is
  required to run on-device; the calendar is read through EventKit on the
  Mac; text in images is recognized by Vision on the Mac and only the text
  is kept.
- **It acts from outside, under a permission engine.** Leonard works your
  apps through the accessibility tree like a person, never through plugins
  or accounts. The model only ever picks among ids the app offered; anything
  that sends, pays, deletes or runs a command waits for you
  ([ADR-007](docs/ADR-007-acting-from-outside.md)).
- **Offline licenses.** Ed25519-signed keys checked on the Mac.

## Pricing

A one-time purchase, 14-day free trial with every feature.

| Personal | Pro | Firm |
|---|---|---|
| **€79** once | **€149** once | **€119** per seat, 5+ |
| 2 Macs | 3 Macs, priority support | Volume keys, invoicing |

Each license includes a year of updates; versions released in that year keep
working forever. 30-day refund, no questions. Rationale in
[BUSINESS.md](docs/BUSINESS.md).

**Requirements:** a Mac with Apple silicon (M1 or later), macOS 14 Sonoma or
later, 16 GB of memory recommended, 1.8 GB for the model.

## Repository

| Path | What it is |
|---|---|
| [`LeonardApp/`](LeonardApp) | The Mac app (Swift 6, SwiftUI + AppKit). `LeonardCore` is platform-independent and tested on Linux too. |
| [`leonardd/`](leonardd) | The on-device engine (Python, MLX): typed decisions, drafting, screen memory, learning. |
| [`specialist/`](specialist) | Research: distilling personal specialists from the engine's decisions. |
| [`tools/license/`](tools/license) | License key tool and the fulfillment worker that emails keys after payment. |
| [`scripts/`](scripts) | `package.sh` builds the self-contained, signed, notarized DMG. |
| [`docs/`](docs) | Architecture, protocol, decisions, launch checklist. |

### Build and run

```
scripts/package.sh --app-only && scripts/run.sh   # dev: app + engine from source (needs uv)
scripts/package.sh                               # full DMG with the bundled Python runtime
cd leonardd && uv run pytest -q -m "not slow"    # engine tests
cd LeonardApp && swift test                      # app tests
```

CI (`.github/workflows/ci.yml`) runs every suite on macOS and Linux, builds
the DMG, smoke-tests the bundled engine and renders the screenshots.
Tagging `vX.Y.Z` runs `release.yml`: signed, notarized, published.

## Documents

| | |
|---|---|
| [`LAUNCH.md`](docs/LAUNCH.md) | **What is left to sell it**: accounts, keys, store, the QA pass |
| [`BUSINESS.md`](docs/BUSINESS.md) | Who buys it, why, at what price, and how they hear about it |
| [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) | How the pieces fit, with the reasons |
| [`CONTRACT.md`](docs/CONTRACT.md) | The app ↔ engine protocol |
| [`VISION.md`](docs/VISION.md) | The governing logic |
| [`PRODUCT.md`](docs/PRODUCT.md) · [`ROADMAP.md`](docs/ROADMAP.md) | What the product is becoming |
| [`SCREEN-MEMORY.md`](docs/SCREEN-MEMORY.md) · [`SENSOR-MAIL.md`](docs/SENSOR-MAIL.md) · [`SPECIALIST.md`](docs/SPECIALIST.md) · [`SYSTEM-ONE.md`](docs/SYSTEM-ONE.md) | Design notes |
| [`ADR-001`](docs/ADR-001-attention-is-a-typed-decision.md) … [`ADR-008`](docs/ADR-008-tier-zero.md) | Decisions and why |
| [`leonardd/README.md`](leonardd/README.md) | What was measured, how, and what was not |
| [`CHANGELOG.md`](CHANGELOG.md) | Releases |

## Why Leonard exists

### The trap everyone else is in

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

### Two systems

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

### Why that matters more than it looks

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

*Where 1.0 is on this path:* it records every decision and your answer to
it — including the implicit ones, like the reply you started — and mints its
first personal specialist from them, on the Mac. Once it has proved on your
own newest answers that it agrees with you at least as well as the general
model, it decides the confident "this can wait" cases alone, in under a
millisecond, and Mind shows how often and how well
([ADR-008](docs/ADR-008-tier-zero.md)). The byte-level transformer in
[`specialist/`](specialist) is the next specialist, for when there is enough
data to feed it.

### Silence is the product

Most of the time the right answer is to say nothing. Leonard is built so that
"nothing" is a measured outcome rather than a missing feature: every candidate
interruption is a typed decision with a calibrated probability, and a
confidence floor you control decides what reaches you.

And because silence is invisible, Leonard ships **Mind** — a live window onto
what it noticed, what it decided, and every time it decided you were not worth
interrupting, with the confidence that fell short. Near-misses are shown more
prominently than hits.

## Status

**1.0.0.** The product described in [VISION.md](docs/VISION.md), built and
green in CI on macOS and Linux: typed attention across mail and chats, tasks
in any app, voice, screen memory with OCR, promises, meeting briefs, a
personal specialist and learned procedures. Before the first sale it needs the owner's accounts and one pass on
a real Mac: see [LAUNCH.md](docs/LAUNCH.md). Quality measurements and their
limits are in [`leonardd/README.md`](leonardd/README.md); numbers quoted from
other projects are theirs, on their conditions.
