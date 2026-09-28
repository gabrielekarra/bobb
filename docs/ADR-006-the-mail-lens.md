# ADR-006 — The Mail lens

Status: accepted, 2026-09-28

## Context

VISION rule 1 says: never integrate, only use. No plugin, no connector, no
OAuth, no API key; drive applications from outside the way a person does.

`SENSOR-MAIL.md` records what reading Mail through the accessibility tree
alone actually takes: the message body is reachable, but the Message-ID,
the exact sender address, the thread and the "is this the same message"
question are guesswork from pixels and labels, and opening a reply by
synthesizing clicks is fragile across macOS versions and localizations.

The first product moment — "this message needs you; here is the draft, in a
real reply window" — has to be reliable before anything else matters.

## Decision

For Apple Mail, Leonard uses Mail's own scripting dictionary through Apple
Events, the interface Shortcuts and Automator use. It is a lens, not an
integration:

- **Read-only, narrow.** Two reads: the id of the selected message, and —
  only when that id changes — its sender, subject, date, body and
  Message-ID. The compose window is read after a pause in typing.
- **Only while Mail is in front.** The sensor never launches or wakes Mail
  and polls only when Mail is the active app.
- **One write, never send.** "Reply in Mail" opens Mail's own reply window
  for the message (found by Message-ID) and pastes the draft at the cursor.
  The user reads, edits and presses Send. No script in Leonard can send,
  move, delete or flag a message.
- **Nothing inside Mail.** No Mail bundle, no extension, no account access,
  no server credentials. Mail's permission prompt ("Leonard wants to control
  Mail") is the user's explicit, revocable consent, and the app explains it
  before it appears.

Everything else — every other app, and screen memory — goes through the
accessibility tree, as rule 1 intends.

## Why this does not break rule 1

Rule 1 forbids what costs per app and couples Leonard to an app's internals
or a vendor's servers: plugins, connectors, OAuth. Apple Events is the
operating system's user-level automation surface — the programmatic
equivalent of the menu bar — available for any scriptable app without the
app's cooperation. It is closer to "using" than the accessibility tree's
synthesized clicks, and it goes no deeper into Mail than a person pressing
Reply does.

## Consequences

Mail is the only first-class mail client in 1.0. Outlook and Gmail in a
browser still feed screen memory and Ask through the accessibility tree, but
get no inbox radar until an equivalent lens exists for them (Outlook has a
scripting dictionary; the web needs the accessibility path). The Automation
permission is a second prompt in onboarding; the onboarding screen explains
it in one sentence before macOS asks.
