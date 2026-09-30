> Historical Bobb document. For current Bobb capabilities, licensing and setup, see [BOBB.md](BOBB.md) and the [README](../README.md).

# Launching Bobb

Everything that can be built, tested and automated is in this repository.
What is left needs a person with legal standing, accounts, money or a Mac:
this file lists it, in order, with what each step unlocks. Nothing here is
optional for selling; the order is the fastest path to a first sale.

| # | Step | Needs | Unlocks |
|---|---|---|---|
| 1 | QA pass on a real Mac | An Apple-silicon Mac, a Mail account | Confidence the build does what it promises |
| 2 | Decide name, domain and bundle id | ~€20/year | Every URL and email in the product |
| 3 | Legal entity | Partita IVA (ditta individuale or S.r.l.) | Selling, the legal pages |
| 4 | Apple Developer Program | $99/year | A DMG that opens without warnings |
| 5 | Production license key | 5 minutes, offline | Keys that release builds accept |
| 6 | Lemon Squeezy store | Identity and bank details | Checkout, invoicing, EU VAT |
| 7 | Email + license worker | Resend and Cloudflare accounts (free tiers) | Keys emailed automatically after payment |
| 8 | First release | Steps 4–5 as GitHub secrets | A signed, notarized DMG |
| 9 | Test purchase | Lemon Squeezy test mode | Proof the whole chain works |

## 1. QA pass on a real Mac

CI builds the app on macOS, runs 79 Swift tests and 198 daemon tests, builds
the full DMG with the bundled Python runtime, smoke-tests the bundled daemon,
and renders every screen to PNG. What CI cannot do is click through the app
with real permissions, a real Mail account and the real model on Apple
silicon. Do that once before charging anyone:

```
scripts/package.sh            # or download the Bobb-dmg artifact from CI
open dist/Bobb-1.0.0.dmg
```

1. **Onboarding.** Grant Accessibility, Automation for Mail and (optional)
   Calendar. Download the model (1.8 GB; progress and checksum verification
   finish without errors). The glasses in the menu bar settle, eyes up.
2. **Mail.** Send yourself "can you confirm the quote by Friday?" and open
   it: one card, with a one-line reason. "Draft reply" opens a real Mail
   reply window with the draft and **nothing sent**. A newsletter: no card.
   Try "Decline" and "Ask for details" in the draft panel.
3. **Chats.** In Slack or WhatsApp, open a conversation where someone asks
   you something: a card; "Draft reply" puts the text in the message box,
   without pressing Return.
4. **Ask (⌥Space).** Ask about something you looked at in Safari; the answer
   cites it. Select a paragraph in TextEdit, "Improve", Replace.
5. **Do (⌥Space).** "Put on my Focus playlist on Spotify" (or any app you
   have): the task panel shows the plan and each step; the app is driven.
   "Tell <a colleague> on Slack I'll be ten minutes late": Bobb stops and
   asks before pressing Return in the message box. Press ⎋ mid-task: it
   stops. Ask for something impossible: it blocks and offers "Show me how";
   do it yourself, press Done, then ask again: the panel says it learned.
6. **Voice (⌥⇧Space).** Say a question; the words appear and the answer
   follows. With on-device dictation not installed, the bar says how to
   install it and nothing is sent anywhere.
7. **Promises.** Send a mail that says "I'll send you the contract
   tomorrow". Within ten minutes it appears under "For you" with its date;
   Done removes it.
8. **Meetings.** Create a calendar event with an attendee starting in eleven
   minutes: at about ten minutes, a card; "Brief me" cites what you saw.
9. **Memory.** Search, delete one item, delete "last hour". Open 1Password or
   Keychain Access: nothing from them appears, and a task refuses to act in
   them. Turn on "Also read text in images", open a scanned PDF: its words
   become searchable.
10. **Mind.** Decisions, silences, tasks and steps are listed; after enough
    answers, "Your specialist" reports its checks.
11. **Settings.** Language switch; quiet hours; protected apps; "Ask me
    before every step"; remove an "Always" rule.
12. **License.** The trial shows 14 days. A key signed with the development
    key activates a development build; a release build rejects it.
13. **Lifecycle.** Quit and relaunch; log out and in with "Open at login";
    kill `bobbd` in Activity Monitor and watch it come back.
14. **Speed.** On an idle Mac run `cd bobbd && uv run python -m
    bobbd.bench` and keep the JSON. Only numbers from this run may appear
    in marketing; see `bobbd/README.md` for why.

Anything that fails here is a bug to fix before step 8.

## 2. Name, domain and bundle id

The product uses `bobb.app` as its domain and `com.bobb.app` as its
bundle identifier. Check both are yours to use (domain registration, and a
trademark search for "Bobb" in class 9 at EUIPO and USPTO).

- **Domain.** If it is not `bobb.app`, replace it everywhere:
  `grep -rl "bobb\.app" --exclude-dir=.build --exclude-dir=node_modules .`
  (app URLs in `BobbApp/Sources/BobbApp/App/AppPaths.swift`, emails in
  the worker).
- **Bundle id.** Decide it **before the first public release** and never
  change it afterwards: macOS ties the user's Accessibility and Automation
  permissions, login item and settings to it. It lives in
  `BobbApp/Info.plist` and `ScreenMemoryPolicy.ownBundleId`.
- **Mailboxes.** `support@`, `sales@`, `privacy@` and a sending address for
  licenses, `licenses@`.

## 3. Legal entity

Selling software needs a VAT number. A *ditta individuale* in regime
forfettario is the cheapest start; an S.r.l. separates liability. Ask a
commercialista, who will also tell you how Lemon Squeezy's payouts are
booked (they are the merchant of record: you invoice them, not the buyers).

Publish a privacy policy and terms of sale wherever the product is sold (the
store's product page is enough to start): Bobb sends nothing anywhere, so
the policy only has to cover orders and support mail.

## 4. Apple Developer Program

Enroll at developer.apple.com (as the legal entity from step 3 if it is a
company; a D-U-N-S number is needed, which takes days). Then:

1. Xcode › Settings › Accounts › Manage Certificates › "+" › **Developer ID
   Application**. Export it from Keychain Access as a `.p12` with a password.
2. appleid.apple.com › Sign-In and Security › **App-Specific Passwords**:
   create one for notarization.
3. Note the **Team ID** (developer.apple.com › Membership).

## 5. Production license key

On a trusted machine, offline if possible:

```
cd tools/license
uv run python license_tool.py keygen --out ~/secure/bobb-signing.key
uv run python license_tool.py public --key ~/secure/bobb-signing.key
```

The first file is the business. Back it up twice, offline (a password
manager plus an encrypted USB stick). If it leaks, anyone can mint keys; if
it is lost, you cannot issue keys that existing builds accept. The second
command prints the **public key**, which is safe to publish and goes into
the app at build time. `dev-signing.key` in the repository is for
development only; the release workflow refuses to ship its public key.

## 6. Lemon Squeezy

Lemon Squeezy is the merchant of record: it charges the card, issues the
invoice, and collects and remits VAT in every country, which a small
Italian seller otherwise cannot do sanely for EU consumers. Paddle is the
alternative; the worker would need a different payload parser.

1. Create the store (currency EUR) and two products, **one-time payment**:
   - *Bobb Personal*, €79, "2 Macs, 1 year of updates"
   - *Bobb Pro*, €149, "3 Macs, 1 year of updates, priority support"

   Turn off Lemon Squeezy's own license keys; Bobb's keys come from the
   worker.
2. Note each product's **variant id** (the product's page, or the API).
3. Use each product's **checkout link** wherever you sell. Adding
   `checkout[custom][lang]=it` to the link makes the license email arrive in
   Italian.
4. Settings › Webhooks › add `https://<worker>/webhook`, event
   `order_created`, and a signing secret you generate (keep it for step 7).
5. Honour a 30-day refund in your own process: a
   refund does not revoke the key (keys are checked offline, by design).

The Firm edition (5+ seats, €119 per seat) is sold by email: issue its key
by hand with `license_tool.py issue --edition team --seats N`.

## 7. Email and the license worker

1. **Resend** (resend.com): add and verify the domain from step 2, create an
   API key. The free tier covers the first thousands of emails a month.
2. **Cloudflare** (workers, free tier):

```
cd tools/license/worker
npx wrangler login
# in wrangler.toml: PUBLIC_KEY, VARIANT_PERSONAL, VARIANT_PRO, FROM_EMAIL, SUPPORT_EMAIL
npx wrangler secret put WEBHOOK_SECRET    # from step 6.4
npx wrangler secret put SIGNING_KEY       # the contents of ~/secure/bobb-signing.key
npx wrangler secret put RESEND_API_KEY
npx wrangler deploy
curl https://<worker>/health              # prints the public key it signs for
```

The worker stores nothing. A key is a pure function of the order, so a
retried webhook re-sends the same key. To re-send a lost key, run
`license_tool.py issue` with the order's name, email, edition and seats plus
`--id lic_ls_<order id> --issued <order date>`: it reproduces the worker's
key byte for byte (a test checks this).

## 8. First release

In GitHub › Settings › Secrets and variables › Actions, add:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | `base64 -i DeveloperID.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | its export password |
| `DEVELOPER_ID_APPLICATION` | `Developer ID Application: <Name> (<TEAMID>)` |
| `APPLE_ID` | your Apple ID email |
| `APPLE_TEAM_ID` | the Team ID |
| `APPLE_APP_PASSWORD` | the app-specific password |
| `BOBB_LICENSE_PUBLIC_KEY` | the public key from step 5 |

Merge the release branch into `main`, then:

```
git tag v1.0.0 && git push origin v1.0.0
```

`.github/workflows/release.yml` builds the bundle, signs every binary with
the hardened runtime, notarizes and staples the DMG, checks it with
`spctl`, and publishes a GitHub release with the DMG, its SHA-256 and the
`CHANGELOG.md` section as notes. It refuses to run without the secrets, with
the development public key, or when the tag and `VERSION` disagree.

Later releases: add a section to `CHANGELOG.md`, bump `VERSION`, tag. A license covers every
version released within a year of purchase; the app reads the build date,
so nothing else is needed.

## 9. Test purchase

With Lemon Squeezy in test mode, buy Personal through the checkout link with
a test card. Within a minute an email arrives with a key; paste it into a release
build: Settings › License shows "Personal, 2 Macs, updates until …". Then
switch the store to live mode.

## The Llama license, briefly

Bobb downloads `mlx-community/Llama-3.2-3B-Instruct-4bit` from Hugging
Face at setup, on the user's machine; the app does not redistribute the
weights. Llama 3.2's Community License asks for "Built with Llama"
attribution (in the app's About box and `THIRD_PARTY_NOTICES.md`) and
acceptance of Meta's Acceptable Use Policy (in the terms). Its restriction on
EU users concerns the *multimodal* Llama 3.2 models only; the 3B model
Bobb uses is text-only. The 700-million-monthly-user threshold is not a
concern for this business.
