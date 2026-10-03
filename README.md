# Bobb

**A personal assistant that notices the next useful step.**

Bobb lives on your Mac, learns from your work and brings you suggestions before
you have to ask. It can help prepare a missing document, follow up on a promise,
get ready for a meeting or recognize a routine worth automating. You can also
ask it to explain, write, research or work in your apps with Option–Space.

[▶ Watch the Bobb introduction](dist/intro/bobb-intro.mp4)

Local intelligence. Your usual apps and browser. No inference subscription,
external AI API or API key. English and Italian interface and responses.

**Current status: developer preview for Apple silicon Macs.** The core flows are
tested, but reliable completion in every app and profession is still a release
goal. This is not a claim that Bobb knows everything or can operate every control.
See the [product review and validation](docs/PRODUCT-REVIEW-2026-10-01.md).
The [feature backlog](docs/FEATURES.md) lists the desired capabilities and their priorities.

## A step ahead, in your work

Open **Bobb → For you** to see context suggestions, commitments, prepared
suggestions, learned routines and work that needs attention in one place.

| Your work | A useful next step Bobb can suggest from observed context |
| --- | --- |
| Legal practice | Prepare a checklist when a client document is missing. |
| Accounting | Prepare a request for the invoice needed to reconcile a payment. |
| Architecture | Identify the measurements needed before comparing design alternatives. |
| Development | Prepare an investigation of an observed build failure. |
| Everyday life | Prepare the questions needed before planning a dinner or an appointment. |

These are example opportunities, not separate profession-specific models or
validated professional advice. Bobb needs the relevant context in an app it can
read. It cannot infer information it has never seen, and its local knowledge
is not a live or authoritative source of legal, tax or technical rules.

Context suggestions are grounded in local screen memory. Each shows **why it
might help**, the **source app**, an **exact excerpt** and when that source was
observed, with a draft you can expand and copy for review. Drafts can contain
mistakes or assumptions; an exact source quote does not verify every generated
sentence. Choose **Prepare with me**, **In an hour** or **Not useful**. Preparation
opens an answer or draft without operating another app. Nothing is sent or
submitted just because it appeared in a suggestion.

Bobb checks at most one new context every five minutes, keeps at most one pending
context suggestion per app, and expires suggestions after a day. It avoids
starting these checks during recognized calls, composition and quiet hours.
A source deletion or app exclusion removes its derived suggestions. A discreet card can surface once when you pause typing, with at most one card every 15 minutes; it never takes focus. After three
explicit dismissals for an app, Bobb pauses its context suggestions; **What I
learned** lets you reset that choice. Existing mail feedback also adjusts how
readily Bobb interrupts, and repeated completed tasks can suggest routines.

When observed text changes in the same document, Bobb withdraws its previous
context suggestion and requires a new evaluation. A direct request takes
priority and cancels proactive draft generation between tokens.

### Work with Apple Mail

Click **Reply** in Apple Mail. With automatic replies enabled, Bobb generates
an editable draft and inserts it into that same empty reply. It checks the
original message and composer again before insertion; typing, closing or
switching the reply cancels the operation. It preserves Mail's quoted history,
restores the clipboard only when it has not changed, and verifies the inserted
text. You review and send from Mail. Disable automatic replies in **Email →
Preferences** to keep the proposal-and-approval workflow.

Open **Bobb → Email** and choose **Synchronize** to import all accessible folders
and enabled accounts, including older archived and sent messages. Import is
paged, shows progress and can be stopped and resumed during the session.
A full import explicitly enables **Keep the full imported archive**: older
email then remains searchable until forgotten, independently of screen-memory
retention. Disable that preference and save to reapply general retention.

Search sender, recipient, subject or content; filter by account, folder, sent,
received, unread, flagged, attachments, VIP or pending response; load successive
pages. A message appearing in multiple folders is indexed once and remains
searchable in each location. Messages expose up to 64,000 characters of text;
a longer message is labelled. Attachments currently expose names, not contents.

Summarize conversations, extract requests and deadlines, ask questions about
an email, create an inbox brief, translate, rewrite, draft replies/reply-all,
write new email, follow up, or prepare a forwarding introduction. Reading tools
cite the email sources they use. Conversation generation uses a bounded recent
history and the inbox brief uses at most 12 matching emails; neither is a claim
to have summarized every indexed message. You can mark messages read/unread or
add/remove flags in Mail and create reminders with VIP, style and signature
preferences. New inbox and sent messages refresh in the background.

This adapter targets Apple Mail and requires macOS Accessibility and Mail
Automation permissions. Gmail and Outlook applications need their own adapters.
The [email workflow check](docs/MAIL-REPLY-2026-10-03.md) distinguishes current
code/contract checks from the real Mail detection and insertion still requiring
native validation. Automatic insertion is implemented, not yet verified in
real Mail in this revision.

## Try Bobb

You need an Apple silicon Mac, macOS 14+, Swift 6, Python 3.12 and
[uv](https://docs.astral.sh/uv/). Xcode 26 is recommended for native Liquid Glass.
Plan for about 7.6 GB of model downloads plus 121 MB for the optional neural voice.
The default resource budget targets 16 GB Macs; that hardware still needs direct
performance validation.

```sh
git clone https://github.com/gabrielekarra/bobb.git
cd bobb
scripts/run.sh
```

1. Click the glasses in the menu bar. Local models download in the background;
   progress and retry are shown there.
2. Grant **Accessibility** to let Bobb read and use supported app controls.
   Calendar and Mail features require their corresponding macOS permissions.
   Screen Recording is only needed if you enable reading text from images.
3. Review **Bobb → Boundaries**. Exclude private apps and choose which actions
   Bobb may perform, must ask about or must never perform.
4. Work normally, then open **For you**. Local memory and observation must be
   enabled for context suggestions. Pause observation from the menu bar at any time.
5. Press **Option–Space** for a direct request. **Option–Shift–Space** starts a
   voice request. Spoken responses are reserved for microphone conversations.

**Suggestions do not require the Background switch.** Background enables
execution of assignments you configured. The Mac must be awake and signed in;
desktop and browser tasks share the screen, run one at a time and yield when you
return. Existing sessions, browser profiles and sign-ins are reused.

The development app is built at `dist/Bobb.app` and remembers this checkout's
daemon and model directory. Keep the checkout in place. `scripts/package.sh`
builds a self-contained app and DMG; `--release` additionally requires your Apple
signing and notarization credentials. The intro video is kept in the repository;
built apps, models and runtime data are not.

## What else it can do

- Answer questions and transform selected text using local generation and
  relevant local memory, with source references when memory is used.
- Propose and execute steps through macOS Accessibility, with a typed CUA fallback
  and verification against observed results. Unsupported controls can still block work.
- Prepare meeting briefs and keep track of promises found in sent Apple Mail.
- Run projects with reviewed subtasks, saved reports and explicit retry after a
  failed or interrupted action. Schedule assignments once, daily, weekly or on an event.
- Learn reusable procedures from successful tasks and demonstrations.
- Create named assistants with their own character and assignments.
- Receive requests through an opt-in iMessage self chat. Configure optional MCP
  servers or an experimental macOS guest when needed.

Read the [capability guide](docs/BOBB.md) for those advanced features.

## Models and evidence

The default pair is **Qwen3.5 4B at 4 bit** for language and **Kev 4B at 8 bit**
for typed decisions, both through MLX. The existing local
[decision comparison](docs/benchmarks/decision-models-2026-10-01.md) favors Kev
over the tested CUA-S1 variants on its small synthetic sample. CUA-S1 is therefore
not a justified replacement on the evidence currently available. The CUA driver
is independent of that model choice.

The [proactivity smoke test](scripts/check_proactivity.py) exercises synthetic
contexts across professions, completed work, navigation noise and adversarial
text. Its [latest recorded outputs](docs/benchmarks/proactivity-v6-2026-10-02.json) are a
small development check, not a measure of real-world task success. A larger model
is not a substitute for observing, checking and recovering correctly. Other
local generation checkpoints can be selected in **Brain**; quality and memory
use need verification for each choice.

The [Locali/Colibri evaluation](docs/ENGINE-REVIEW-2026-10-02.md) includes direct
Locali experiments on these same weights and a 30B model. Locali's streamed
30B used 2.9–6.9 GB peak MLX memory versus 17.3 GB resident, with slower responses
and identical text on the tested prompts. The executable adapter is experimental;
the production default is unchanged. This establishes a memory option for larger
models, not a general quality improvement.

Speed is a product requirement. On the development M4/24 GB Mac, the
[real-daemon latency check](docs/benchmarks/response-latency-2026-10-02.json)
measured median first streamed text at **0.87 s** for a direct answer and
**1.66 s** with automatic intent selection, after the models were ready.
A foreground request during proactive preparation started responding in
**1.18 s**. Background preparation can stop during prompt processing as well
as between output tokens. Locali's streamed 30B took **10–14 s** to finish the
short engine requests, so it is not the default path. These small synthetic
runs measure daemon latency, not the UI, cold startup or every workflow.

## Privacy and control

Inference runs locally and the daemon forbids IP networking. Model downloads,
websites, Messages and explicitly configured connectors use their respective
network services. Memory, the imported email archive and feedback live on this Mac under
`~/Library/Application Support/Bobb`; there is no telemetry.

Protected apps, secure fields and private windows are excluded. Recognizable
secrets are redacted before storage. Reading images is opt-in. You can delete
memory and history, reset learning, stop observation and exclude apps. Sending,
paying, deleting and publishing ask by default; a model suggestion cannot grant
itself permission. Web challenges and actions that cannot be verified require
your intervention. See [architecture](docs/ARCHITECTURE.md).

## Development and validation

```sh
(cd BobbApp && swift test -j 1)
(cd bobbd && uv sync --frozen && uv run pytest -q -m 'not slow')
# With the default models installed:
bobbd/.venv/bin/python scripts/check_local_brain.py
bobbd/.venv/bin/python scripts/check_proactivity.py
bobbd/.venv/bin/python scripts/check_proactive_flow.py
bobbd/.venv/bin/python scripts/check_response_latency.py
bobbd/.venv/bin/python scripts/check_mail_reply.py
```

Use a matching SDK and Swift toolchain. If your Command Line Tools installation
selects an incomplete newer SDK, `BOBB_SWIFT_SDK` and
`BOBB_SWIFT_BUILD_SYSTEM` can select a compatible installed SDK/build system for
`scripts/build.sh` and `scripts/package.sh`. Details and the commands used for
this revision are in the [product review](docs/PRODUCT-REVIEW-2026-10-01.md).

Contribute a reproducible workflow, a fix, a translation or an evaluation:
[contribution guide](CONTRIBUTING.md).

## License

**Source available, with contributions welcome.** The
[Bobb Source Available License 1.0](LICENSE) allows inspection, unmodified
personal and internal professional use, and forks/modifications for contributing
to Bobb. It prohibits redistributing or rebranding Bobb as another product,
unofficial binary distribution and offering it as a hosted service without
separate permission. This is **not an OSI open source license**.

[Third-party components](THIRD_PARTY_NOTICES.md) retain their own licenses.
Previously granted MIT rights to earlier versions are not revoked. Bobb has no
paid activation gate. The new custom license should receive legal review before
public release; publishing source cannot technically prevent copying.
