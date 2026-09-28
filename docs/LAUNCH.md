# Launching Leonard

Everything that can be built, tested and automated is in this repository.
What is left needs a person with legal standing, accounts, money or a Mac:
this file lists it, in order, with what each step unlocks. Nothing here is
optional for selling; the order is the fastest path to a first sale.

| # | Step | Needs | Unlocks |
|---|---|---|---|
| 1 | QA pass on a real Mac | An Apple-silicon Mac, a Mail account | Confidence the 1.0 build does what the site says |
| 2 | Decide name, domain and bundle id | ~€20/year | Every URL and email in the product |
| 3 | Legal entity | Partita IVA (ditta individuale or S.r.l.) | Selling, the legal pages |
| 4 | Apple Developer Program | $99/year | A DMG that opens without warnings |
| 5 | Production license key | 5 minutes, offline | Keys that release builds accept |
| 6 | Lemon Squeezy store | Identity and bank details | Checkout, invoicing, EU VAT |
| 7 | Email + license worker | Resend and Cloudflare accounts (free tiers) | Keys emailed automatically after payment |
| 8 | First release | Steps 4–5 as GitHub secrets | A signed, notarized DMG |
| 9 | Site live | GitHub Pages or Cloudflare Pages | Download and buy pages |
| 10 | Test purchase | Lemon Squeezy test mode | Proof the whole chain works |

## 1. QA pass on a real Mac

CI builds the app on macOS, runs 79 Swift tests and 198 daemon tests, builds
the full DMG with the bundled Python runtime, smoke-tests the bundled daemon,
and renders every screen to PNG. What CI cannot do is click through the app
with real permissions, a real Mail account and the real model on Apple
silicon. Do that once before charging anyone:

```
scripts/package.sh            # or download the Leonard-dmg artifact from CI
open dist/Leonard-1.0.0.dmg
```

1. **Onboarding.** Grant Accessibility and, when asked, Automation for Mail.
   Download the model (1.8 GB; the progress bar and the checksum
   verification must finish without errors). The menu bar icon settles.
2. **Inbox radar.** Send yourself a message that asks for something ("can you
   confirm the quote by Friday?"). Open it in Mail. The card appears once,
   top right, with a one-line reason. "Draft reply" opens a real Mail reply
   window with the draft pasted and **nothing sent**. Open a newsletter: no
   card. Check both in Mind.
3. **Variants and fact check.** In the draft panel try "Decline" and "Ask for
   details". Put a figure in a draft that is not in the email: it is
   highlighted.
4. **Ask (⌥Space).** Ask about something you looked at in Safari a few
   minutes ago; the answer cites it. Select a paragraph in TextEdit, choose
   "Improve", press Replace: the text is replaced in place.
5. **Memory.** Open the Memory window, search, delete one item, delete "last
   hour". Open 1Password or Keychain Access: nothing from them appears.
6. **Settings.** Switch the language to Italian and back; set quiet hours to
   now and check that no card appears; add an app to the protected list.
7. **License.** The trial shows 14 days. Issue a key with the *development*
   key (`tools/license`, `issue --key dev-signing.key …`) and activate it in
   a development build. A release build must reject that key.
8. **Lifecycle.** Quit and relaunch; log out and in with "Open at login" on;
   kill `leonardd` from Activity Monitor and watch it come back.
9. **Speed.** On an idle Mac run `cd leonardd && uv run python -m
   leonardd.bench` and keep the JSON. Only numbers from this run may appear
   in marketing; see `leonardd/README.md` for why.

Anything that fails here is a bug to fix before step 8.

## 2. Name, domain and bundle id

The product uses `leonard.app` as its domain and `com.leonard.app` as its
bundle identifier. Check both are yours to use (domain registration, and a
trademark search for "Leonard" in class 9 at EUIPO and USPTO).

- **Domain.** If it is not `leonard.app`, replace it everywhere:
  `grep -rl "leonard\.app" --exclude-dir=.build --exclude-dir=node_modules .`
  (app URLs in `LeonardApp/Sources/LeonardApp/App/AppPaths.swift`, emails in
  the site and the worker).
- **Bundle id.** Decide it **before the first public release** and never
  change it afterwards: macOS ties the user's Accessibility and Automation
  permissions, login item and settings to it. It lives in
  `LeonardApp/Info.plist` and `ScreenMemoryPolicy.ownBundleId`.
- **Mailboxes.** `support@`, `sales@`, `privacy@` and a sending address for
  licenses, `licenses@`.

## 3. Legal entity

Selling software needs a VAT number. A *ditta individuale* in regime
forfettario is the cheapest start; an S.r.l. separates liability. Ask a
commercialista, who will also tell you how Lemon Squeezy's payouts are
booked (they are the merchant of record: you invoice them, not the buyers).

Then fill the placeholders in bold in `site/privacy.html`, `site/terms.html`,
`site/it/privacy.html` and `site/it/termini.html`: legal entity, reseller
name, hosting provider and the court's city. Have a lawyer read the terms
once; they were written for this product, not copied, but they are not
legal advice.

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
uv run python license_tool.py keygen --out ~/secure/leonard-signing.key
uv run python license_tool.py public --key ~/secure/leonard-signing.key
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
   - *Leonard Personal*, €79, "2 Macs, 1 year of updates"
   - *Leonard Pro*, €149, "3 Macs, 1 year of updates, priority support"

   Turn off Lemon Squeezy's own license keys; Leonard's keys come from the
   worker.
2. Note each product's **variant id** (the product's page, or the API).
3. Copy each product's **checkout link** into `site/assets/config.js`
   (`checkout.personal`, `checkout.pro`). The buy page adds the buyer's
   language to it, so the license email arrives in Italian or English.
4. Settings › Webhooks › add `https://<worker>/webhook`, event
   `order_created`, and a signing secret you generate (keep it for step 7).
5. Enable the 30-day refund promise the site makes, in your own process: a
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
npx wrangler secret put SIGNING_KEY       # the contents of ~/secure/leonard-signing.key
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
| `LEONARD_LICENSE_PUBLIC_KEY` | the public key from step 5 |

Merge the release branch into `main`, then:

```
git tag v1.0.0 && git push origin v1.0.0
```

`.github/workflows/release.yml` builds the bundle, signs every binary with
the hardened runtime, notarizes and staples the DMG, checks it with
`spctl`, and publishes a GitHub release with the DMG, its SHA-256 and the
`CHANGELOG.md` section as notes. It refuses to run without the secrets, with
the development public key, or when the tag and `VERSION` disagree.

Later releases: add a section to `CHANGELOG.md` and to
`site/releases/index.html`, bump `VERSION`, tag. A license covers every
version released within a year of purchase; the app reads the build date,
so nothing else is needed.

## 9. Site

`site/` is static HTML with no third-party requests. In `site/assets/config.js`
set `downloadURL` (the GitHub release asset,
`https://github.com/<owner>/<repo>/releases/download/v1.0.0/Leonard-1.0.0.dmg`,
works if the repository is public; otherwise host the DMG on Cloudflare R2)
and `downloadSHA256` from the `.sha256` file.

GitHub Pages: Settings › Pages › Source: **GitHub Actions**. Every push to
`main` that touches `site/` deploys through `.github/workflows/site.yml`,
which first checks every local link. For the custom domain, add it in the
Pages settings and a file `site/CNAME` containing the domain.

## 10. Test purchase

With Lemon Squeezy in test mode, buy Personal from the live site with a test
card. Within a minute an email arrives with a key; paste it into a release
build: Settings › License shows "Personal, 2 Macs, updates until …". Then
switch the store to live mode.

## The Llama license, briefly

Leonard downloads `mlx-community/Llama-3.2-3B-Instruct-4bit` from Hugging
Face at setup, on the user's machine; the app does not redistribute the
weights. Llama 3.2's Community License asks for "Built with Llama"
attribution (in the app's About box and `THIRD_PARTY_NOTICES.md`) and
acceptance of Meta's Acceptable Use Policy (in the terms). Its restriction on
EU users concerns the *multimodal* Llama 3.2 models only; the 3B model
Leonard uses is text-only. The 700-million-monthly-user threshold is not a
concern for this business.
