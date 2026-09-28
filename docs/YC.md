# Leonard — the YC argument

Working draft. Everything here is either true today or marked `[TBD]`. Nothing
is a number we have not measured.

## One sentence

Leonard is an assistant that watches how you work and offers help before you
ask — and it runs entirely on your own computer, so it can watch things you
would never send to a server.

## The insight

Every proactive assistant dies of noise. Not because its suggestions are bad,
but because it has no principled way to stay quiet. It asks a model in prose
whether to speak, gets prose back, and prose has no threshold.

The fix is not a better prompt. It is to stop generating and start reading:
ask the model a question with a closed answer set, read the logits at one
position masked to the valid answers, and take the probability. Now silence is
a threshold, coverage trades against accuracy, and the whole thing calibrates
against what the user actually did next.

**That technique requires owning the model's logits. Owning the logits
requires running locally. So Leonard is local because proactivity demands it —
privacy is the consequence, not the pitch.**

That inversion is the thing most people get backwards, and it is why the
obvious competitor — a wrapper over a hosted frontier API — cannot copy the
mechanism at any price.

## Why now

Three things became true in the last eighteen months and had not been true
before:

1. A 3B 4-bit model on a fanless laptop answers a constrained question in
   ~150 ms while resident in about 2 GB. Proactivity at desktop event rates
   became affordable on hardware people already own.
2. Apple silicon's unified memory made a model resident alongside a normal
   workload instead of competing with it.
3. Enough people have now used a proactive assistant and turned it off that
   the market understands the problem is interruption, not capability.

## Why us

We did not decide to be local-first and then look for a way. We built the
local inference layer first, measured it, and Leonard is what it is for.

[`locali`](https://github.com/gabrielekarra/locali) is prior work on a fanless
Apple M4 with 24 GB, and every number in it has the JSON behind it in the
repository:

- typed decisions with calibrated confidence, primed decision 149.8 ms on
  Llama-3.2-3B
- an abstain curve: at a 0.60 floor, 55.6% coverage at 0.800 accuracy against
  0.569 at full coverage — the exact trade Leonard's floor slider exposes
- frame gating: 91% of frames skipped, no event missed, 308 ms/frame becomes
  28.2 ms effective
- and a discipline that matters more than any of them: the repository
  withdrew its own model ranking when the sample turned out not to support it

That last one is the real credential. The hard part of this product is knowing
what your numbers do and do not establish, because the whole thing is a
threshold on a confidence.

## What is built

- Frozen IPC contract between the app and the on-device daemon.
- `leonardd`: resident MLX model, typed decisions, confidence floor, frame
  gate, SQLite audit store, unix socket only — with a test that fails the
  build if the process can open a network socket.
- `LeonardApp`: menu bar, non-activating overlay, accessibility sensors
  against real Mail.app, and **Mind**.

## The demo

Two minutes, no slides.

1. Work normally. Mail.app, a few messages. Leonard says nothing.
2. Open a message that actually needs an answer. The overlay appears, quietly:
   *"Vuoi che prepari una risposta a Marco?"* Click Prepara. The draft is
   there, written on the machine.
3. Now open Mind and scroll back. Every message Leonard saw, every decision it
   made, and the twelve times it decided you were not worth interrupting, each
   with the confidence that fell short and the reason.
4. Drag the floor slider. Watch what would have surfaced change live.
5. Turn off the wifi. Do the whole thing again.

Step 3 is the pitch. Step 5 is the moat.

## The honest weaknesses

- The magic moment is currently one app on one platform.
- Calibration needs real accept/dismiss data from real users, which we do not
  have yet. Until then the floor is a default, not a fitted parameter.
- A 3B model's judgement about what deserves a reply is good, not excellent.
  The floor is what makes that shippable; it is not what makes it great.
- `[TBD]` distribution. A menu bar app that needs Accessibility permission is
  a real onboarding cost.

## What we would do with the money

`[TBD — Gabriele]`

## Open questions for us to answer before applying

1. Who is the first user who pays? `[TBD]`
2. Is the wedge email, or is email just the easiest thing to demo? `[TBD]`
3. What does Leonard do on day 30 that it cannot do on day 1? The audit store
   is designed to be the answer; we have not proved it yet.
