# The Mail sensor — what the accessibility tree actually requires

Rules extracted from Cua Driver's macOS AX implementation, which is
source-verified in `CUA-INVESTIGATION.md` §1.3 and has been through far more
real-world contact than anything we would write this week. Follow them whether
or not we end up linking Cua Driver itself.

Status: **validated against live Mail.app on macOS 27, 2026-09-20.** Results at
the bottom. One good, one bad, and the bad one changes the sensor's design.

## The five rules

### 1. Walk `AXChildren` ∪ `AXWindows`, never `AXChildren` alone

AppKit omits background windows from `AXChildren` when the app is not
frontmost. Leonard reads Mail precisely while the user is somewhere else, so
walking only `AXChildren` returns an empty or partial tree in the normal case
and a full tree only while the user is already looking at Mail — the case
where Leonard has the least to add.

This is the single easiest way to get a false negative. Our first probe had
exactly this bug.

### 2. Set a messaging timeout

`AXUIElementSetMessagingTimeout(element, 2.0)`. A blocked AX call cannot be
cancelled once dispatched, so without a timeout a hung target hangs the
sensor. Cua uses 2 seconds.

### 3. Bound the walk and report truncation

Depth 25, 2000 elements, and return a `truncated` flag with the partial tree
rather than hanging. Cua names VS Code and Obsidian as the pathological cases.

A truncated tree is a fact the decision layer needs, not an error to swallow.

### 4. Read `AXDescription` separately from `AXTitle`

Some apps put the real label in `AXDescription` and leave `AXTitle` empty.
Collapsing them loses content. Keep `role`, `title`, `value`, `description`,
`identifier`, `help`, `actions`, `frame`, `enabled`, `selected` as distinct
fields — Cua's `AXNode` shape, which is a typed structure and not a text dump.

### 5. Expect and detect the degraded case

An empty tree with rich pixels means the surface is not AX-backed —
canvas-rendered editors, WebGL, terminals. Cua's own skill docs tell the
calling agent to detect this rather than assume universal coverage.

Mail.app is native AppKit, and Cua's `action-support.md` ledger marks AppKit
AX tree reading, capture, background left click, **set value** and **type
text** as proven. The ledger's unproven cells for AppKit are native press-key,
hotkey, and AX-addressed right/double click — none of which the MVP uses.

So on paper Mail should be fine. On paper is not a measurement.

## What the MVP needs from Mail, and nothing more

| Need | Mechanism | Ledger status |
|---|---|---|
| Which message is displayed | AX tree walk | proven for AppKit |
| Sender, subject, body, thread length, unread | AX node attributes | proven |
| Insert a draft into a reply window | AX `set value` / `type text` | proven |
| Send | — | **never. Out of scope by design** |

## The open question the probe answers

Whether Mail.app on macOS 27 exposes the **message body** as an AX value at
all, and under which role and attribute. The ledger proves the tree is
readable; it does not prove this particular content is in it.

If the body is not exposed, the fallback ladder is:

1. Screen capture of the message pane plus OCR, gated by the frame gate. Costs
   a TCC grant for Screen Recording and real latency.
2. Read the local Mail store at `~/Library/Mail`, which needs Full Disk
   Access. Richer and structured, and it is also what `SPECIALIST.md` wants
   for the day-zero cold start from an existing mailbox.

Route 2 is better data and worse onboarding. We should not choose between them
before the probe has told us whether we need to.

## Running the probe

Built and ad-hoc signed at `~/leonard-probe/LeonardProbe.app`, bundle id
`com.leonard.probe`. It walks Mail with all five rules above and writes
`~/leonard-axprobe.txt`.

It needs Accessibility, which cannot be granted from a command line: `tccutil`
only resets permissions, and the TCC database is protected by SIP even with
Full Disk Access. It requires the GUI or an MDM profile.

System Settings → Privacy & Security → Accessibility → enable LeonardProbe,
with a message open in Mail, then run it.

It doubles as the test of ADR-003's unverified claim that an ad-hoc signature
with a stable bundle identifier keeps its TCC grant across rebuilds. If that
turns out to be false, building without Xcode gets considerably more painful
and we need to know early.

---

# Measured, 2026-09-20, live Mail.app on macOS 27

Fanless Apple M4, 24 GB. `LeonardProbe.app`, ad-hoc signed, Accessibility
granted. Mail frontmost, message list displayed, no message selected.

```
AXIsProcessTrusted: true
walk 176057 ms, 2000 nodi (TRUNCATED), 236 nodes with text > 60 chars
roles: AXStaticText=1054 AXCell=244 AXRow=244 AXUnknown=206 AXGroup=206
       AXButton=17 AXTextField=10 AXDisclosureTriangle=4 AXImage=2 AXScrollArea=2
```

## The good result: the text is there

Message content is exposed as `AXStaticText` / `AXValue` and comes back in
full, in both languages, including bodies of over a thousand characters. The
open question this probe existed to answer is answered: **Mail does expose
message text through the accessibility tree, and no screenshot or OCR fallback
is needed for it.**

The MVP sensor is viable, and rule 4 of `VISION.md` — no screenshots in the
loop — survives contact with the real application.

## The bad result: a walk is 176 seconds

That is not a typo. 2000 elements, the bound Cua uses, took **176 seconds**
and was still truncated — roughly 88 ms per element, because each element
costs several cross-process AX round trips for its attributes and children.

A sensor that does this is not slow, it is unusable. Nothing in the product
survives a three-minute observation.

**Bounding the walk does not fix it.** Cua's depth-25 / 2000-element bound was
already applied here and is exactly what produced these numbers. The bound
stops the walk from being infinite; it does not make it fast.

### What this forces

The sensor must **target, never sweep**. Roughly 2000 elements have to become
roughly 20, which is also the cap the action loop already imposes for its own
reasons.

Directions, in the order worth trying:

1. **Navigate, do not enumerate.** Go to the known containers — the message
   pane, the selected row — via `AXFocusedUIElement` and role-targeted lookup,
   instead of walking from the application element down.
2. **Batch the attribute reads.** Each element here paid several separate
   round trips. `AXUIElementCopyMultipleAttributeValues` fetches a set in one
   call and should be the default everywhere.
3. **Observe instead of poll.** `AXObserver` notifications tell us what
   changed, so the steady-state cost is reading one subtree on a real change
   rather than re-reading everything on a timer.
4. **Cache by element identity**, and re-resolve only what the notification
   says moved.

Until that is measured, **no latency claim about the sensor path should be
made**, and the end-to-end numbers in `leonardd/results/` describe the
decision path only, from an event that was handed to it.

### A second observation, smaller but useful

The 1054 `AXStaticText` and 244 `AXRow`/`AXCell` nodes are the **message
list**, not an opened message: each row carries its preview text. So the list
view alone is a rich source — sender, subject and preview for every message on
screen, which is most of what `mail.arrived` and the implicit labeller need,
without opening anything.

That is convenient and it is also a warning. A naive sensor would happily
ingest hundreds of message previews on every window change. The frame gate and
the deduplication in `SCREEN-MEMORY.md` are not optimizations here, they are
what stops the memory filling with the same inbox a hundred times an hour.
