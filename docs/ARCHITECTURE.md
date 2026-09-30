# Architecture

Bobb is two processes on one Mac, joined by a unix socket, plus the tools
that build, sell and license it. This page says where each responsibility
lives and why it lives there. The protocol between the processes is
[`CONTRACT.md`](CONTRACT.md); the decisions behind the shape are the ADRs.

```
┌──────────────────────────── Bobb.app (Swift 6) ────────────────────────────┐
│ Sensors                         Coordinator              Surfaces             │
│ MailSensor (Apple Events) ──┐                         ┌─ Overlay card          │
│ SentMailSensor (Sent box) ──┤                         ├─ Draft panel           │
│ ScreenMemorySensor (AX, OCR)┼─ events ─▶ AppState ────┼─ Command bar ⌥Space    │
│   └ ConversationTracker ────┤   request/response      ├─ Voice ⌥⇧Space         │
│ CalendarSensor (EventKit) ──┘   over IPCClient        ├─ Task panel            │
│                                                       ├─ Menu bar, For you     │
│ Acting: TaskLoop ─ AXDriver ─ ActionPolicy            └─ Mind, Memory, Settings│
│ DaemonSupervisor · ModelDownloader · LicenseController                        │
└─────────────────────────────────────────┬─────────────────────────────────────┘
                     unix socket, NDJSON, 0600
┌─────────────────────────────── bobbd (Python) ─────────────────────────────┐
│ server.py ── status, handlers, streaming, cancellation                        │
│   attention.py ─ specialist.py (tier 0) ─ intents.py ─ decide.py ─ policy.py  │
│   agent.py ── tasks: plan, one checked step at a time, text only for TYPE     │
│   compose.py ── replies (mail, chat), briefs, ask modes, grounding, checks    │
│   commitments.py ── promises in sent mail, due dates   procedures.py ── how   │
│   memory.py ── FTS5 screen memory    audit.py ── decisions, tasks, labels     │
│ engine.py ── MLX, Llama 3.2 3B Instruct 4-bit, resident                       │
│ No network: tests/test_no_network.py (ADR-002)                                │
└───────────────────────────────────────────────────────────────────────────────┘
```

## The two processes

**Why two.** The model runtime (MLX) and the tooling around it are Python;
the product surface must be a native Mac app. A process boundary also makes
the privacy claim structural: the process that sees content has no network
path, and the process that has one network path (the model download) never
holds content it did not put on screen itself.

**Who owns what.**

| Concern | Owner | Why there |
|---|---|---|
| Reading the screen and Mail | App | Needs Accessibility and Automation permissions, which belong to the signed app |
| Deciding whether to speak | Daemon | Needs the model; deterministic policy after the readout |
| Drafting, answering | Daemon | Needs the model and screen memory |
| Screen memory storage | Daemon | One SQLite store next to the audit log; the app only sends text |
| Protected apps | Both | The app never reads them; the daemon refuses to store them anyway |
| Settings | App, pushed to daemon | The app is the UI; the daemon echoes back what it stored |
| Licensing, trial | App | Offline, no daemon involvement; an expired trial stops asking the daemon |
| The model download | App | The daemon cannot network (ADR-002, ADR-005) |

## Lifecycle

1. The app starts `bobbd` through `DaemonSupervisor`: in a release, the
   Python runtime bundled in `Bobb.app/Contents/Resources/daemon`, with a
   clean environment and `--parent-pid`, so the daemon exits if the app dies.
2. The daemon takes a single-instance lock (exit 3 if another holds it),
   binds the socket **before** loading the model, and reports `loading`,
   `model_missing`, `error` or `ready`. The app shows exactly that.
3. A missing model sends onboarding to the download; after verification the
   app sends `reload`.
4. Crashes are restarted with backoff; five exits in two minutes is reported
   as failed with "Export diagnostics" rather than retried forever.

## A decision, end to end

1. `MailSensor` notices a new selected message in Mail (while Mail is in
   front), reads it once, and emits `mail.opened` with `typing` and `idle`.
2. `attention.py` asks the model narrow factual questions — what kind of
   message, how urgent, which tone, is the user stuck — each read at a single
   logit position over its own labels (ADR-001). `message_type` is read in
   both option orders and averaged, which removes letter-order bias.
3. `policy.py` maps the readouts to `ignore`, `wait`, `prepare` or `suggest`
   deterministically, and `learning.py` supplies the personal floor for this
   kind of event. Below the floor the daemon abstains, and says by how much.
4. The decision is written to `audit.py` and sent. `suggest` shows the card;
   `prepare` waits under "For you"; everything appears in Mind.
5. On "Draft reply", `compose.py` retrieves related screen memory, writes the
   reply as the user (salutation prefix, language and register rules) and
   streams it into the draft panel, with citations and a fact check of
   figures and names against the email and the sources.
6. "Reply in Mail" opens Mail's own reply window and pastes the draft
   (ADR-006). Bobb never sends.
7. The user's answer (approve, dismiss, or the card timing out) goes back to
   the audit log, and `learning.py` updates on the next decision.

## Screen memory

`ScreenMemorySensor` reads the focused window's text through the
accessibility tree when the user pauses, skipping protected apps, private
browser windows and secure fields (`ScreenMemoryPolicy`). The daemon redacts
card numbers, keys, tokens, one-time codes and password lines, merges
repeated or growing views of the same window, and indexes the rest in FTS5.
Retention sweeps run at start-up and every six hours. See
[`SCREEN-MEMORY.md`](SCREEN-MEMORY.md).

## Doing things: tasks

The command bar's Do mode, or any request the engine routes to "do", starts
a task (ADR-007). `TaskLoop` (BobbCore, tested on Linux with fakes) asks
the engine for a plan — or reuses a learned procedure as the plan — then
repeats: `AXDriver` reads the front app's window and menu bar into element
snapshots; `CandidateRanker` narrows hundreds of elements to the few worth
scoring, by the words of the request and the plan; `CandidateTable` gives
them fresh opaque ids; the engine (`agent.py`) answers with one operation
and one id from a single prefill; `ActionPolicy` allows, asks or denies;
`AXDriver` re-resolves the id and presses, types, scrolls or opens an app;
the loop waits for the screen to settle and reports the step. The task panel
shows all of it, with Stop (⎋), permission prompts, Undo and "Show me how".

## Tier 0: the personal specialist

Before the resident model reads a mail or chat message, `specialist.py`
scores it with the user's own model: a logistic regression over hashed
sender, subject, body and circumstance features, trained on the Mac from
the user's answers, implicit signals and the resident model's verdicts. It
decides alone only a confident "this can wait", and only once it has been
validated against the user's newest answers (ADR-008). Mind shows how often
it decided, how fast, and how well it agrees with the user.

## Conversations, promises and meetings

- **Chats.** The screen sensor's reads of chat apps feed
  `ConversationTracker`, which turns an opened conversation or new lines in
  it into `message.opened`. The engine judges it like an email and writes a
  chat-sized reply, which `ChatInserter` puts in that app's message box.
- **Promises.** `SentMailSensor` reads Mail's Sent mailbox (read-only, only
  while Mail runs). `commitments.py` asks one typed question — does this
  message promise something? — phrases the promise with the text model and
  parses its due date in code. Promises wait under "For you".
- **Meetings.** `CalendarSensor` reads EventKit on the Mac: events go into
  screen memory, and ten minutes before a meeting with other people a
  `calendar.upcoming` event lets the engine offer a brief built from memory
  and from what the user promised the attendees.

## Voice and pixels

`SpeechInput` uses Apple's speech recognizer with on-device recognition
required; when a language is not installed offline it says so rather than
use a server. `ScreenTextRecognizer`, only when the user enables it, reads
the words in windows whose accessibility tree has almost none, with
ScreenCaptureKit and Vision on the Mac; only the text is kept.

## Learning procedures

A task that ends done, and a demonstration recorded by
`DemonstrationWatcher` after "Show me how", are kept by `procedures.py`.
The closest procedure to a new request is shown to the engine in every
step's context as a guide, and becomes the plan when the match is close.

## BobbCore and BobbApp

`BobbCore` (contract types, IPC, state, coordinator, license
verification, Mail parsing, settings, localization) has no AppKit and builds
and tests on Linux, so most logic is covered by `swift test` on both
platforms. `BobbApp` is AppKit and SwiftUI: sensors, windows, panels,
the hotkey, the supervisor. UI strings live in one table (`L10n.swift`) with
English and Italian for every key; a test fails if one is missing.

The contract is pinned from both sides by fixture files: the real daemon
writes `daemon_frames.jsonl`, which the Swift tests decode; the Swift
encoders write `app_frames.jsonl`, which the daemon tests replay.

## Packaging

`scripts/package.sh` builds the Swift app in release mode, installs a
relocatable CPython 3.12 (python-build-standalone) into the bundle, installs
the engine's locked dependencies from hash-checked wheels only, byte-compiles
and slims them, smoke-tests the bundled engine (it must start and report
`model_missing` with no network), signs inside-out with the hardened runtime,
builds the DMG and, with `--release`, notarizes and staples it. The DMG is
about 200 MB; the model is downloaded once at setup.

## Selling

```
buyer ── Lemon Squeezy checkout ── order_created webhook ──▶
    tools/license/worker (Cloudflare): verify HMAC → sign Ed25519 key → email (Resend)
buyer pastes key ──▶ Bobb verifies offline with the public key in Info.plist
```

The key's payload carries edition, seats and `updates_until`; the app
compares that with its own build date, so a license keeps working forever
with every version released within its year. No server is asked, ever. See
[`LAUNCH.md`](LAUNCH.md) for setting it up.
