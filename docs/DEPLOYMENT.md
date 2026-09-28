# Deploying Leonard on managed Macs

For firms rolling Leonard out with an MDM (Jamf Pro, Kandji, Mosyle, Intune,
Apple Business Essentials…). Everything here is optional: on an unmanaged Mac
the user does each step in onboarding.

What an administrator can do:

| Step | How | Without it |
|---|---|---|
| Install the app | Deploy `Leonard.app` from the notarized DMG | User drags it to Applications |
| Grant Accessibility and Mail automation | PPPC configuration profile | User approves two prompts |
| License every seat | Managed preference `LicenseKey` | User pastes the key |
| Pre-install the model | Copy the verified folder | 1.8 GB download per Mac |

Requirements: Apple silicon, macOS 14 or later, 16 GB of memory recommended.

## 1. Install

Take `Leonard.app` from the signed, notarized DMG on the release page and
deploy it to `/Applications` as you would any app (most MDMs accept the DMG
directly). Leonard does not update itself: deploy new versions the same way.
The release page lists each version's SHA-256.

## 2. Privacy permissions (PPPC)

Leonard needs **Accessibility** (to read the text of the window in front of
the user, and to paste a draft) and **Automation of Mail** (to read the open
message and open a reply window). It never needs Screen Recording, Full Disk
Access, Contacts or Calendars.

A PPPC profile (payload type `com.apple.TCC.configuration-profile-policy`)
must be installed by a user-approved or supervised MDM. Replace `TEAMID`
with the Team ID in the app's signature
(`codesign -dr - /Applications/Leonard.app` prints the exact requirement):

```xml
<key>Services</key>
<dict>
  <key>Accessibility</key>
  <array>
    <dict>
      <key>Identifier</key><string>com.leonard.app</string>
      <key>IdentifierType</key><string>bundleID</string>
      <key>CodeRequirement</key>
      <string>identifier "com.leonard.app" and anchor apple generic and certificate leaf[subject.OU] = "TEAMID"</string>
      <key>Authorization</key><string>Allow</string>
    </dict>
  </array>
  <key>AppleEvents</key>
  <array>
    <dict>
      <key>Identifier</key><string>com.leonard.app</string>
      <key>IdentifierType</key><string>bundleID</string>
      <key>CodeRequirement</key>
      <string>identifier "com.leonard.app" and anchor apple generic and certificate leaf[subject.OU] = "TEAMID"</string>
      <key>AEReceiverIdentifier</key><string>com.apple.mail</string>
      <key>AEReceiverIdentifierType</key><string>bundleID</string>
      <key>AEReceiverCodeRequirement</key>
      <string>identifier "com.apple.mail" and anchor apple</string>
      <key>Authorization</key><string>Allow</string>
    </dict>
  </array>
</dict>
```

Onboarding then shows both permissions as already allowed.

## 3. Licensing every seat

A Firm order comes with one key for all its seats. Deploy it as a managed
preference for the domain `com.leonard.app`, key `LicenseKey` (a custom
settings / Application & Custom Settings payload):

```xml
<key>LicenseKey</key>
<string>LEONARD-eyJ2Ijox….xxxx</string>
```

The key is verified on each Mac against the public key built into the app;
nothing is sent anywhere. A key the user pastes themselves takes precedence.
To move a license, remove the profile; to renew updates, deploy the renewed
key.

## 4. Pre-installing the model (optional)

To avoid a 1.8 GB download per Mac, download the model once (on any Mac,
through Leonard's onboarding), then copy the folder

```
~/Library/Application Support/Leonard/Models/Llama-3.2-3B-Instruct-4bit/
```

to the same path in each user's home. Leonard checks the files' presence and
sizes at every launch and their SHA-256 on demand (Settings › Model ›
Verify integrity); if anything does not match, Leonard says so and offers
the download again.

## What stays on each Mac

Each user's data stays in their own home folder and never leaves the Mac:

| Path | Contents |
|---|---|
| `~/Library/Application Support/Leonard/` | Decisions, screen memory (text only), settings, license, the model |
| `~/Library/Logs/Leonard/` | Timings and error types, never content |

There is no server, no account and no telemetry to configure, allow-list or
audit. The only outbound request is the model download (from
`huggingface.co`), which step 4 removes. A network filter can therefore block
Leonard entirely once the model is in place, and it keeps working.

Protected apps (never read, never remembered) include password managers,
Keychain Access and System Settings by default; users can add more in
Settings › Privacy.
