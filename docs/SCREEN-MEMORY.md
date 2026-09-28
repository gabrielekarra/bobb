# Screen memory

Leonard remembers everything it has seen on your screen, and everything you
did with it. That memory never leaves the machine.

This is how Leonard gets to know you without integrating with anything. No
OAuth, no connectors, no per-app work, no embedding inside Mail or Excel or
Spotify. It watches, the way a colleague sitting beside you watches, and it
remembers.

## Text, not pixels

The memory is built from the accessibility tree, not from screenshots.

That is the same choice `jev-ultrafast` makes for its action loop and it pays
the same way here. A screenshot has to be run through a vision model before it
means anything, which costs hundreds of milliseconds and produces a lossy
transcription of text the operating system already had in structured form. The
AX tree hands over the text, the role of the thing holding it, whether it is
enabled, and where it sits — synchronously, for free.

So a day of screen memory is a few megabytes of text with structure, not
gigabytes of images. It is searchable with `LIKE` and an FTS index rather than
re-inferred. And it can be read by a person, which matters for a store like
this one.

Screen capture stays in the design as a fallback for surfaces that are not
AX-backed — canvas editors, WebGL, terminals — gated, on demand, never the
primary path.

## What gets stored

Each observation, deduplicated:

| | |
|---|---|
| When | timestamp, and how long it stayed |
| Where | app, window title, and the pane within it |
| What | the indexed element table: role, label, value, enabled |
| Text | the readable content, as displayed |
| Why it is here | the event that triggered the observation |

And separately, what the user did: which control they used, what they typed,
what they opened next, what they ignored. That is the behavioural half, and it
is what `SPECIALIST.md` trains on.

## Deduplication is the whole cost model

A screen is nearly always the same as it was a moment ago. Storing every
observation would be enormous and useless.

`gate.py` already solves this for frames and the same reasoning applies to
structure: compare a cheap signature of the element table against the last
observation that was actually *stored*, never against the previous one, or a
slow drift walks past the threshold one imperceptible step at a time.

For text the right signal is how much of the content changed, not how far it
moved — the caret-versus-word distinction `locali` measured at 9x apart by
area and within 1x by magnitude.

## Retrieval

Two paths, both local:

1. **Lexical** — SQLite FTS5 over the stored text. Fast, exact, explainable,
   and enough for "what was the invoice number from Atlas".
2. **Semantic** — local embeddings over the same rows, for "what was that
   thing about the vesting clause". Optional, built lazily, and only worth its
   cost once the store is large.

Both feed the resident model as retrieved context when it writes. That is what
makes "write a reply to Marco" produce a reply that knows what Marco said last
month, without anyone having connected anything.

## The two models, and what each is for

| | Role | Cost |
|---|---|---|
| **Decision model** | Picks the operation and the target. Knows how to use applications. | Single-digit to low tens of milliseconds |
| **Text model** | Writes, summarizes, answers, using what the memory retrieved. | Hundreds of milliseconds to seconds |

The decision model runs on every step. The text model runs only when the step
is `TYPE_TEXT`, or when the user asks something in words.

Jev gives up generation entirely. That is correct for a decision API and wrong
for an assistant: an assistant has to write the email, not merely conclude
that one should be written. So: two local models, one job each, neither doing
the other's work badly.

## This is the most invasive thing we could build

A record of everything on your screen is worth more to an attacker than your
password manager, because it contains the contents of your password manager.

Which is exactly why it has to be local, and why "local" has to mean
something stronger here than elsewhere in the product:

- **Protected applications are never observed at all.** Password managers,
  banking, private browsing, security tools, and anything the user adds. Not
  filtered after reading — the tree is not read, so there is nothing to
  filter, nothing to leak, and nothing to recover from a deleted row.
- **Fields that look like secrets are never stored**, whatever the app.
  `AXSecureTextField` is the obvious case; there are others.
- **The store is encrypted at rest** and lives only on this machine.
- **The user can read it.** All of it, in plain language, searchable. A memory
  you cannot inspect is a memory you cannot trust.
- **The user can delete any of it**, by row, by app, by time range, by search
  result, and deletion is real.
- **Retention is a setting**, with a default that forgets rather than a
  default that hoards.
- **Nothing is uploaded. There is no sync, no backup to us, no telemetry.**
  The daemon binds no network socket, which is enforced by a test.

Microsoft shipped a screen memory and had to withdraw it, because it stored
screenshots, on by default, in a form the user could neither inspect nor
meaningfully control. The lesson is not that screen memory is wrong. It is
that it is only defensible when it is text you can read, local by
architecture, off in the places that matter, and deletable for real.

We should say this out loud rather than hope nobody asks. It is the strongest
part of the argument, not the weakest.

## What it unlocks

Once Leonard has watched you work for a month it can do the job rather than
assist with it: write the email in your voice because it has read a thousand
of yours, open the playlist because it has watched you open it every Tuesday,
find the number in the spreadsheet because it saw the spreadsheet, fix the
code because it saw the error.

None of that requires a single integration. It requires having been in the
room.
