# Business

How Leonard makes money, from whom, and why they will pay. Every figure
below is either a price we set or an assumption marked as one; there is no
customer data yet, and there will be no telemetry to collect it (ADR-002),
so the measurement plan is part of this document.

## Positioning

**The assistant that knows when to stay quiet.** A private AI for the Mac
that reads your mail and your screen, tells you what needs you, drafts the
reply, and never sends a byte of it anywhere.

Two claims carry it, and both are checkable by the buyer:

1. **It stays quiet.** Every interruption is a measured decision with a
   threshold the user controls, and Mind shows every time it chose not to
   speak. Proactive assistants are switched off because of noise; this one
   is built around silence.
2. **Nothing leaves the Mac.** Not "we don't train on your data": the engine
   cannot open a network connection. A firewall like Little Snitch shows one
   request in the product's life, the model download the user starts.

## Who buys it

**Primary: professionals whose inbox is confidential and who work on a Mac.**

| Segment | Why the cloud is a problem for them | What Leonard does for them |
|---|---|---|
| Lawyers (avvocati, solicitors) | Professional secrecy; client mail cannot go to a third-party AI provider without a processing agreement and often not at all | Triage, drafts, "what did the client say about the deadline" |
| Accountants and tax advisors (commercialisti) | Client financial data, GDPR, deadlines everywhere | Urgent notices surfaced, figures fact-checked in drafts |
| Doctors, therapists | Health data is a special category (GDPR art. 9) | Patient mail triaged and answered without leaving the Mac |
| Consultants, advisors under NDA | Contractual confidentiality | Drafts and recall across client work |
| Founders and executives | Board, deal and HR mail | The same, with a firm-wide policy they can defend |

They share three traits: high inbox volume where most messages do not need
them, a real cost to missing the few that do, and a hard constraint against
the obvious cloud tools. They already pay for software and value time at
well over €100 an hour; saving ten minutes a day pays for Personal in a
month.

**Where we launch:** Italy first, then the EU. The product, the site, the
emails and the license flow are fully bilingual (Italian, English); Italian
professionals are underserved by US-first AI tools, GDPR makes the privacy
argument concrete, and the founder can sell to them in their language.

**Honest limits of the market:** Mac only, Apple silicon only, Apple Mail
only for the inbox radar in 1.0. Many Italian *studi* run Windows and
Outlook; the Mac share is higher among solo professionals, boutiques,
founders and creative businesses. Outlook for Mac (it has a scripting
dictionary) is the first expansion to test demand for.

## Why they choose Leonard

| Alternative | Where it falls short for this buyer |
|---|---|
| Cloud chat assistants (ChatGPT, Claude, Gemini, Copilot) | Client mail has to be pasted into a third party; reactive only |
| AI email clients (Superhuman-style) | Cloud, a new mail client, and a monthly subscription |
| Apple Intelligence | On-device and free, but generic: summaries and rewrites on request, no triage decision with a threshold, no memory of what you have read, no fact check |
| Screen-memory recorders | Screenshots rather than text, and none of them decide or draft |
| Doing it by hand | The status quo, and the real competitor |

Apple is the largest risk and the reason Leonard competes on *judgement*
(when to speak, with a number and an explanation), *memory* (grounded,
cited answers) and *transparency* (Mind), not on generic writing tools.

## Pricing

| Edition | Price | For |
|---|---|---|
| Personal | **€79** once | 2 Macs, 1 year of updates |
| Pro | **€149** once | 3 Macs, 1 year of updates, priority support |
| Firm | **€119 per seat**, 5 or more | Volume keys, invoicing, onboarding call |

14-day trial with every feature, no account. 30-day refund, no questions.
After the first year the app keeps working forever; renewing updates is
optional.

**Why one-time and not a subscription.**

- Our marginal cost is close to zero: no servers, no inference bills, the
  user's Mac does the work. A subscription would charge for a cost we do not
  have, and this buyer notices.
- Owning the software is part of the privacy story: nothing to renew
  monthly, nothing that stops working when a server does.
- Indie Mac buyers are subscription-fatigued; a one-time price removes the
  main objection at checkout.
- Recurring revenue comes from **update renewals** (planned at about half
  the new price, when the first paid-for version ships) and from Firm seats.

**Why these numbers.** €79 sits where serious, single-purpose Mac utilities
are priced, below the monthly cost of most cloud AI subscriptions over a
year, and above impulse pricing, which signals a professional tool. Pro at
€149 exists for the buyer who wants a third Mac and a named person on
support; it anchors Personal as the sensible choice. Firm is priced per seat
because firms buy per head and want one invoice.

**Unit economics (per sale, before VAT; Lemon Squeezy fee assumed 5% +
€0.50):** Personal nets about €74.55, Pro about €141.05. Other costs are
fixed and small: Apple Developer Program ($99/year), a domain, and free
tiers for the site, the license worker and email.

## How people hear about it

In order of expected return for a solo founder, all testable in the first
90 days:

1. **Professional communities, in Italian.** Guides and talks on "using AI
   without breaking professional secrecy" for bar and accountant
   associations (continuing-education events are always looking for this
   topic), LinkedIn posts from the founder, and direct conversations with
   ten *studi* for the Firm edition.
2. **Launch moments.** Show HN ("a local assistant that knows when to stay
   quiet", with the typed-decision write-up), Product Hunt, r/macapps. The
   engineering story — logit readouts, abstention, a networkless engine — is
   unusual enough to be shared on its own merits.
3. **Mac and privacy press.** Mac-focused writers and privacy-focused
   newsletters: the checkable claim ("watch it in Little Snitch") is the hook.
4. **The product itself.** Every draft opened in Mail is a demo to whoever
   is watching over the shoulder; Firm grows from one Pro buyer in a studio.

## Measuring without telemetry

Leonard will never report usage, so the business is steered by what the
business itself sees:

| Question | Signal |
|---|---|
| Is the site converting? | Downloads (release asset counts or server logs) against visits from the host's aggregate stats |
| Is the trial converting? | Sales against downloads, weekly |
| Are buyers happy? | Refund rate and reasons (asked, optional), support email themes |
| Which edition wins? | Lemon Squeezy reports |
| What to build next? | A one-question survey link in the release notes, and support mail |

Targets to beat, as assumptions to be replaced by data: a 3% download-to-sale
rate, refunds under 5%.

## Risks

| Risk | Mitigation |
|---|---|
| Apple ships proactive triage in Mail | Compete on judgement, memory and transparency; Leonard works across every app, not only Mail |
| A 3B model makes a visible mistake in a client email | It never sends; figures are fact-checked; it abstains when unsure; the terms say to review |
| Mac-only, Mail-only limits the market | Outlook for Mac next; the engine is app-agnostic by design |
| The license signing key leaks | Kept offline; a leaked key means a new key pair in the next release |
| One founder | Everything automated: CI, release, fulfillment; LAUNCH.md documents every account |

## The next 90 days

1. Weeks 1–2: the steps in [`LAUNCH.md`](LAUNCH.md), a real-Mac QA pass,
   and ten design-partner professionals using a free license.
2. Weeks 3–4: public launch in Italy, then Show HN and Product Hunt.
3. Weeks 5–12: weekly releases driven by support mail; Outlook for Mac if
   demand shows up; first Firm customers.
