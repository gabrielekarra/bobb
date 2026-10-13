# Native app integrations

Bobb remains a Swift 6/AppKit macOS application with its local Python daemon,
Qwen3.5 4B 4-bit language model and Kev 4B 8-bit decision model. The daemon still
has no IP networking. App tools run in the native app, through public macOS APIs
or explicitly configured stdio MCP servers.

## What was brought over

The integration inventory was compared against **Sombrace/BoBe** at
`cce8effb93cdc580c72f48b565e30392e648bc8c` and **vox-ai-app/vox** at
`ff47a157826007456b27ae0267bda1c569835e8a`. Both repositories publish an MIT
license. This is a Swift implementation of useful capabilities, without
vendoring their runtimes or changing Bobb's inference providers.

| Capability | Bobb implementation | Coverage and limits |
| --- | --- | --- |
| General app control | Existing Accessibility, OCR and CUA drivers | Uses installed/running apps and the user's screen. Unsupported controls can block work. |
| Calendar | EventKit | List calendars/events, create/update/delete exact events. Bounded date range and pagination. Edits require the observed id and original start. Invitations use the Calendar UI; recurring-series deletion is excluded. |
| Reminders | EventKit | List lists/reminders, create, complete/reopen and delete exact ids. |
| Contacts | Contacts framework | Search names and return exact matching addresses. Ambiguity remains visible; no automatic recipient selection. |
| Shortcuts | `/usr/bin/shortcuts`, argv only | List and run installed shortcuts with optional text input/output. Reaches third-party apps that expose Shortcuts. Every run requires review; finishing the process does not attest its app effects. |
| Music | Fixed AppleScript handlers | Read state, search local library, play exact track ids, pause, next/previous and volume. No catalog purchase or subscription API. |
| Mail | Existing native Mail bridge/composer | Read selected/recent inbox messages, read/flag changes and editable new drafts. Existing Email workspace, full archive, reply/translation workflows and UI-based sending remain available. |
| Messages | Read-only local SQLite pages, fixed AppleScript, existing self-chat/screen driver | List/read individual iMessage chats on request and submit to an exact previously observed address. Full Disk Access is required. No group/SMS sends, broad background import or automatic replies to other people. Text stored only as an unsupported attributed archive is labelled unavailable; attachment contents are not read. A send receipt does not attest delivery. |
| Third-party services | Configured stdio MCP | Import common `mcpServers` JSON, discover up to 200 tools over up to ten pages, refresh changed lists, exclude tools and store environment values in Keychain. HTTP/SSE transports and OAuth setup are not implemented. |
| Personality, memory, goals, proactivity, voice | Existing Bobb features | Kept in Bobb's existing local architecture; no Copilot, Ollama, Electron or extra model introduced. |

This does **not** claim compatibility with every application. Native integrations,
Shortcuts, Accessibility and optional MCP provide complementary routes. A
connector still needs an installed server, the service's own access and an
explicit boundary. Existing browser tasks remain scoped to the real browser;
native tools are offered in desktop tasks.

## Use

Ask through Option–Space, or choose a **desktop** assignment. The model can open
the `Mac tools` entry, choose a tool, prepare JSON arguments and call it, then
return to an actual app to inspect its screen. These are the same typed action
steps used by the desktop driver. No extra request from the user is required
for ordinary reads and writes allowed by their boundaries.

Examples: “Crea un promemoria Compra il latte per domani alle 18”, “Quali eventi
ho domani?”, “Cerca tutti i contatti chiamati Marco Rossi”, “Metti in pausa la
musica”, or “Esegui il comando rapido che ho chiamato Prepara riunione”.

macOS asks for Calendar, Reminders, Contacts or Music Automation access when an
invocation first requires it. These are app permissions; they do not change
Bobb's action boundaries. Missing/revoked access yields a failed tool result.
Screen tasks still require Accessibility and share the existing screen lease.

In **Boundaries → Optional MCP connectors**, import a local JSON file:

```json
{
  "mcpServers": {
    "my-app": {
      "command": "/absolute/path/to/server",
      "args": ["--stdio"],
      "env": { "SERVICE_TOKEN": "your-own-token" },
      "excluded_tools": ["delete_everything"]
    }
  }
}
```

Imported connectors are disabled until reviewed and enabled. Commands supplied
as a basename are resolved only in `/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/bin` and `/bin`; no shell is used. Secrets become per-value Keychain
references in settings. The original selected JSON file is not rewritten, so
it may still contain secrets. Loader/shell/environment overrides are rejected.
Removing a connector removes its Keychain entries.

## Execution and verification

- App-owned effect categories gate tool calls even if the tool label hides the
  effect. Exclusions, protected apps, working hours and acting/screen ownership
  are checked before calls and after permission requests.
- Selecting a tool and preparing its argument object do not invoke it. Native
  schemas reject missing/unknown keys, wrong types and out-of-range values.
  The MCP server validates its full input schema; MCP calls always use the
  connector's execute boundary, regardless of read-only annotations.
- Calendar/Reminders writes are read back by exact identifier. Contacts return
  every matching person in the selected page. Music returns observed state.
  Mail drafts and Shortcuts expose their limited receipts and require actual
  screen evidence for claims beyond those receipts.
- Identical Calendar/Reminders creations and new Mail drafts reuse their receipt
  within the same task. This prevents immediate repeat creation; it is not
  durable exactly-once delivery after a crash. Read calls and playback commands
  remain repeatable. Integration calls do not advertise a generic Undo button.
- Process calls have bounded text output, a 60-second timeout and cancellation.
  Tool results remain data in the same grounded-report path as screen text.

## Validation

The regression suite covers argument schemas, backward-compatible MCP settings,
environment restrictions, typed effect boundaries, preparation without execution,
revocation, duplicate creations, failure/closed-state completion, and a TaskLoop
refusal before a native delete reaches its adapter. Daemon tests cover full
argument-schema prompts and rejecting non-object/prose output.

Native API behavior, system consent dialogs, Calendar/Reminders sync and real
app effects still need a signed Mac session. A macOS CI build checks compilation;
it is not an end-to-end app compatibility test. On a test Mac, grant each service
individually, use disposable events/reminders, verify ids and readback, revoke a
permission mid-task, exclude the app, and confirm that the next call stops.
