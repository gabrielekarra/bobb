# ADR-005 — The one download

Status: accepted, 2026-09-28

## Context

ADR-002 makes the engine incapable of networking. But a product has to get a
1.8 GB model onto the Mac somehow, and shipping it inside the DMG would make
every update a 2 GB download, push the DMG past what most people will wait
for, and put Meta's weights inside a file we redistribute.

Every other network path a Mac app usually has — telemetry, crash reports,
license activation, update checks — is a reason for a careful buyer to say
no, and each one is another claim that has to be audited rather than
believed.

## Decision

Bobb makes exactly one kind of network request in its life: downloading
the model files, from Hugging Face, when the user presses the button in
onboarding (or, later, "Download again" in Settings).

- **The app downloads, not the engine.** `ModelDownloader` in the Swift app
  fetches the files; `bobbd` stays networkless and is told to `reload`
  when the files are in place.
- **Pinned, verified bytes.** `ModelManifest` pins the repository, the
  revision, and each file's size and SHA-256. A file that does not match is
  deleted, not used. A launch-time check (presence and size) catches a
  damaged install cheaply; the full hash runs after download.
- **No other request.** Licenses are verified offline (Ed25519, public key in
  the bundle). "Check for updates" opens the releases page in the browser.
  Diagnostics are a zip the user chooses to email. There is no analytics SDK.
- The **download survives bad networks**: files already verified in the
  staging directory are kept across attempts, and a dropped connection is
  retried with backoff and resumed from the bytes already received. It shows
  real progress, because a 1.8 GB download that silently restarts on a café
  network would be the first thing a new user remembers about the product.

## Alternatives rejected

**Model in the DMG.** A 2 GB DMG, redistribution of the weights, and a full
re-download for every app update. Rejected.

**Engine downloads its own model.** Would require the engine to have a
network path, which ADR-002 exists to forbid.

**Our own CDN mirror.** Would add a server we run and whose logs we hold, for
no gain over Hugging Face with pinned hashes.

## Consequences

The privacy page can say "the only request is the one you start", and it is
checkable with Little Snitch or LuLu. A future model is a new manifest and a
new download the user starts, never a silent swap. If Hugging Face ever
removes the pinned revision, a release with a new manifest is needed; the
hash pinning means a changed file is refused rather than trusted.
