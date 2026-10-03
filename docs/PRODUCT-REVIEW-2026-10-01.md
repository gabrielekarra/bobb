# Bobb product review — 1–2 October 2026

## Product direction

Bobb should notice a useful next step in the work already happening on a Mac,
explain why it matters and help prepare or carry it out within the user's
boundaries. Profession-independent understanding of observed text is a better
foundation than separate hardcoded workflows for lawyers, accountants,
architects and developers. Universal app competence and omniscience are not
capabilities this revision can claim.

## Findings from the existing implementation

The repository already contained the Swift app, a local Python daemon, Qwen
language generation, Kev decisions, Accessibility and CUA drivers, browser
session reuse, memory, meeting preparation, commitments, projects, scheduled
assignments, routine detection, feedback and demonstrations. Those substantial
existing changes were preserved.

The main gaps were product integration and evidence:

- Proactive help centered on mail/chat and upcoming meetings. Screen memory
  answered questions but did not independently propose next steps from general
  work. Commitments and routines existed in separate views.
- The default workspace opened identity configuration rather than useful work.
- The browser picker still said “Hidden browser” despite using the user's browser.
- Promise tracking was not explicitly conveyed in daemon settings. Context
  inference needed revocation checks after asynchronous work, not just before it.
- The packaging script removed the previous app before compilation succeeded.
- The selected sidebar row's glass background obscured its text in native rendering.
- Rendering an empty agent snapshot exposed an unchecked array access; the UI
  now supplies the default Bobb agent when the snapshot contains no agents.
- A local crash report identified a speech authorization callback inheriting
  MainActor isolation on a system queue. Permission callbacks now explicitly
  use Sendable closures and hop to MainActor for UI updates. Compilation and
  regression checks passed; a fresh speech-permission prompt is not replayed.
- Existing benchmark results compared decision selection, not actual task
  success, proactive usefulness or generation quality.

## Changes

**For you is the home.** Context initiatives, commitments, mail/chat suggestions,
routines and work requiring intervention are visible together. Setup status is
explained in the page, and users can pause context suggestions. Preparation is
explicitly a text request, with action routing disabled.

**General context initiatives.** A newly stored, redacted screen/OCR observation
can trigger a bounded local evaluation. Kev classifies whether there is an
unresolved need; Qwen proposes a short next step and exact source excerpt; a
separate Kev decision checks support. A prepared draft is also stored and can
be expanded and copied from the home page. Both decisions respect the user's floor
with a minimum of 0.60. These probabilities are not a calibrated reliability
guarantee. A source excerpt is checked literally in code. Malformed output,
unsupported evidence or low confidence results in silence.

The earlier implementation used a much higher second threshold and missed most
useful contexts. The threshold is now the same explicit user setting for both
stages; suggestion preparation cannot execute actions. Prompts were iterated on
the recorded development cases, so those cases are not a held-out evaluation.
The remaining false negatives and language weaknesses must be taken seriously.

**Persistence and learning.** Suggestions survive restart, expire after 24 hours,
can be deferred one hour and support explicit prepare/dismiss feedback. Three
explicit dismissals stop context suggestions for that app. The learned rule is
visible and reversible. An unanswered overlay is not counted as a rejection.
The existing mail floor learning, muted senders, routines and demonstrations
remain separate mechanisms with their own controls.

**Initiative delivery.** A nonactivating card can appear after a typing pause,
when the user is present and no draft, answer, desktop task or overlay occupies
Bobb. Recognized call apps, quiet hours, exclusions and pause suppress it. The
persistent store permits each initiative to be announced once and limits cards
to one per 15 minutes. Suggestions remain in For you after the card disappears.
Browser calls and attention state are not universally detectable.

**Resource and privacy bounds.** At most one new context is evaluated every five
minutes and one pending initiative is retained per app, with eight visible at
most. Observation, local memory and the setting must be enabled. Permission and
source validity are checked after inference and before display/response.
New text for the same observed document supersedes its prior suggestion,
including appended completion updates that still contain the old quote. A late
result cannot resurrect that prior revision. Changing to a different URL does
not erase work on the previous page. Foreground model work cancels proactive
text generation between tokens, so a draft does not hold the inference queue
until its entire output completes. It can now also stop between 128-token
prompt-processing chunks, before producing the first token; foreground
generation keeps its normal larger prefill for throughput.
Deleting the source, deleting history or revoking access cannot publish a late
result. No network is added to inference.

**Release materials.** README now introduces the product, setup, realistic
examples, limits and the intro video. The updated film found as
`dist/intro/bobb-launch.mp4` is also available at the requested
`dist/intro/bobb-intro.mp4`; only that release video is exempted from the build
output ignore rule. The original code uses the Bobb Source Available License
1.0 and the contribution guide explains contributor rights.

## Model decision

Keep Kev as the default decision model based on the existing
[comparison](benchmarks/decision-models-2026-10-01.md). In that development sample,
Kev selected the expected option in 91/96 evaluations, versus 85–86/96 for the
tested CUA-S1 variants, with lower median latency. These were synthetic states
and half the evaluations repeated the same scenarios; they do not measure
end-to-end app competence or calibrate the new initiative decisions.

Qwen3.5 4B remains the generator. The new tests demonstrate useful local
preparation but also generic wording and missed opportunities. There is no
measured evidence here that installing a larger generator would improve the
whole product enough to justify making it mandatory on a 16 GB Mac. Evaluate
larger models against real workflows and memory pressure before changing the
default. The installed Llama research checkpoint is not a validated replacement.

The subsequent [Locali/Colibri review](ENGINE-REVIEW-2026-10-02.md) includes an
installed Qwen3 8B comparison. Both generators matched suggestion presence in
12/13 development cases, with different misses, but manual draft inspection
found unsupported assumptions in both. The secondary check is not a factuality
guarantee. The 8B run did not justify a default change.
Subsequent direct Locali runs on Qwen3.5 4B produced identical text and the same
2.607 GB MLX peak. A Qwen3-VL 30B-A3B adapter reused Locali's streaming arena and
preserved Qwen's routing; peak memory was 2.903 GB with a 2 GB arena or 6.902 GB
with a 6 GB arena, versus 17.284 GB resident. The tested outputs were identical,
but streamed response was slower. These experiments make larger local models
a concrete option; they do not yet change the production backend or prove
better end-to-end proactivity. See the engine review for full artifacts and scope.

Speed is a requirement, so the streamed 30B remains an experiment. The real
shipping daemon now has a [latency check](benchmarks/response-latency-2026-10-02.json):
median first text was 0.866 seconds directly or 1.660 seconds with automatic
intent selection. Foreground first text during proactive preparation improved
from 2.067 to 1.183 seconds after cancellation was added during prompt processing.
These are small synthetic runs on the M4/24 GB after model readiness, not UI
latency, cold startup or a hardware-independent guarantee.

Automatic text-mode classification reuses Kev's user-request prefix and never
treats selected text as the user's instruction. A separate single-readout
experiment was not adopted: it saved little text-classification time and made
app-command classification slower. It also exposed existing routing defects
for arithmetic and a future sending request. The knowledge prompt now permits
general questions and simple writing rather than requiring all answers to be
in personal memory. Personal/work facts must still come from observed context.
The timing check verifies the literal short response that previously received
an erroneous refusal; it does not establish overall knowledge accuracy.

## Verification and remaining release work

The pre-change daemon baseline passed 401 tests; the updated regression suite
covers source revocation/deletion, late results, restart, snooze, feedback and
notification frequency. Swift tests cover compatible decoding, pause settings
and notification suppression. Native rendering uses synthetic fixtures only.
See [latest proactivity outputs](benchmarks/proactivity-v6-2026-10-02.json) and the
[real daemon flow](benchmarks/proactive-flow-2026-10-02.json) for executable
scope and results. These tests do not establish reliable operation in every app.
The October 3 regression run passed 442 Python tests (four slow tests deselected)
and 161 Swift tests in 22 suites. The [email reply workflow check](MAIL-REPLY-2026-10-03.md)
separately records real model and native UI checks and their limits.
The real-daemon flow with stored draft passed; its current timings and output
are in the linked artifact. The release
app built and its ad-hoc signature verified; the native Italian home rendered
with a synthetic initiative. A Safari automation attempt reported
`accessibilityGranted: false`, `automationVerified: false`, `passed: false`.
After permissions were granted, LaunchServices launched Bobb under its own app
identity and the [Safari test](benchmarks/user-browser-safari-2026-10-02.json)
verified typing, submitting and observing the expected synthetic result. Direct
terminal launch still had a different permission attribution. A
[Chrome attempt](benchmarks/user-browser-chrome-2026-10-02.json) initially had
Accessibility but failed to observe the requested page (`browserPageUnavailable`).
The app now retries transient full-tree activation failures and reports which
preparation check failed. After rebuilding, the latest Chrome attempt reports
Accessibility unavailable. The ad-hoc designated requirement is the executable's
code hash, which changed during rebuild; the current build needs an OS grant
before this retry can verify the fix. Chrome is not counted as successful
automation. Both checks use the repository's synthetic localhost form and log
no personal page contents.

The revised draft prompt removes unobserved conversation/agreement and deadline
claims in the recorded legal/accounting/follow-up examples. It still matched
presence/silence in 12/13 development cases and missed the migration meeting.
The developer draft still states an installation interpretation too strongly;
its title and preparation style also need improvement. This is evidence of
partial quality improvement, not a factuality guarantee or readiness for
autonomous professional work.

On this Mac, the default CLT configuration selected a macOS 27 SDK without a
working SwiftUI macro plugin. These explicit settings use the installed 26.5
SDK and Testing framework:

```sh
cd BobbApp
swift test --build-system native -j 1 \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks
# From repository root:
BOBB_SWIFT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
BOBB_SWIFT_BUILD_SYSTEM=native scripts/build.sh
```

Release work that remains outside what these checks prove:

- Repeated real-app tasks on a clean Mac, including Safari/Chrome, Mail, document
  editors, spreadsheets and specialist apps, with recovery and completion evidence.
- A consented user study measuring useful suggestions, false interruptions,
  missed opportunities, clarity and learning over multiple days.
- Measured battery, latency and memory pressure with everyday apps on 16 GB
  hardware; the available local results are from a 24 GB M4.
- Signed/notarized distribution and first-run permission checks on a second Mac.
- Legal review of the custom license and third-party distribution obligations.

The [OSI definition](https://opensource.org/osd) requires redistribution and
modification freedoms inconsistent with a contribution-only product fork policy.
This is therefore source available. A new license cannot withdraw rights already
granted under MIT for earlier versions, prevent independent reimplementation,
or technically stop someone copying a published repository. Third-party
components retain their own licenses. No publication or release is performed by
this review.
