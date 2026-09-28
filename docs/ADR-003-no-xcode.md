# ADR-003 — The app builds without Xcode

Status: accepted, 2026-09-20

## Context

The development machine has Command Line Tools, not Xcode. `xcodebuild` is
unavailable.

## Decision

`LeonardApp` is a SwiftPM executable target. `scripts/build.sh` assembles the
`.app` bundle by hand — `Contents/MacOS`, `Contents/Resources`, `Info.plist` —
and ad-hoc signs it with `codesign -s -`.

The bundle identifier is fixed at `com.leonard.app`.

## Correction, measured 2026-09-20: a stable identifier is not enough

This ADR originally claimed that a fixed bundle identifier plus an ad-hoc
signature would keep an Accessibility grant across rebuilds. **That is false**,
and it cost us a confusing hour.

Observed: `LeonardProbe.app`, ad-hoc signed, identifier `com.leonard.probe`.
The TCC entry was created, the user enabled it, and the app still reported
`AXIsProcessTrusted: false`. The signature verified fine — "valid on disk",
"satisfies its Designated Requirement". The cause was that the binary had been
rebuilt after the TCC entry was created.

For an ad-hoc signed binary there is no Team Identifier and no stable
Designated Requirement to key on, so TCC keys on the **cdhash**. Every rebuild
produces a new cdhash, and the grant the user gave refers to a binary that no
longer exists. The UI still shows the app enabled, which is why this is worse
than an outright failure: it looks granted and behaves as denied.

`tccutil reset Accessibility <bundle-id>` clears the stale entry so the user
can grant against the current binary.

### Consequences we now have to live with

During development, every rebuild of the app invalidates its Accessibility
grant. That is not a workable loop for a product whose entire sensor layer
needs that permission, so one of these has to happen:

1. A real Developer ID signature, which gives a stable Designated Requirement
   that survives rebuilds. This is the actual fix and it needs a paid Apple
   Developer account.
2. Failing that, a `tccutil reset` plus a re-grant baked into `build.sh`, and
   the developer clicking the toggle after every build. Tolerable for one
   person, miserable beyond that.

Option 1 is the answer and it is a purchase, not a code change. Until then,
freeze the binary whenever a grant is needed and do not rebuild during a test.

This also changes what we tell users at release: an ad-hoc or unsigned build
distributed to anyone else would lose its permissions on every update. Signing
is a shipping requirement, not a nicety.

## Consequences

No storyboards, no asset catalogs compiled by `actool`, no entitlements that
require a provisioning profile. Icons are drawn in code. This costs a little
and buys a build that runs anywhere Swift does, including CI without an Xcode
image.

Notarization for distribution will need a Developer ID and a real signing
step. That is a release problem, not a development one.
