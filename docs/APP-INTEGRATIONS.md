# Native app integrations

Bobb stays a Swift/AppKit macOS assistant with Qwen3.5 4B 4-bit generation and
Kev 4B 8-bit decisions. It observes the user's screen and autonomously chooses
steps within their existing boundaries. Optional service connections live in
the native app; the Python inference daemon has no IP networking.

The original comparison used **Sombrace/BoBe** at
`cce8effb93cdc580c72f48b565e30392e648bc8c` and **vox-ai-app/vox** at
`ff47a157826007456b27ae0267bda1c569835e8a` (MIT). Bobb implements useful
capabilities in Swift, without importing their runtimes or replacing its models.

| Route | Implemented coverage | Concrete limits |
| --- | --- | --- |
| User's apps | Accessibility, OCR and CUA fallback; native context menus, increment/decrement controls, settable numeric sliders, observed window activation | Only controls exposed or reliably observed can be used. No universal app guarantee or arbitrary drag coordinates. Browser window changes bind to the exact observed target. |
| Browser and desktop | Native tools, configured MCP and actual app UI in the same task | Keeps the user's browser/profile. Real UI actions retain foreground/window/page binding and the shared screen lease. |
| Calendar | List calendars/events; create, update and delete exact occurrences with readback | Date range/pagination limits. Original start required for edits. Invitations and recurring-series deletion use Calendar's UI. |
| Reminders | List lists/reminders; create, complete/reopen, delete with readback | Exact ids and writable lists; system permission required. |
| Contacts | Name search, exact matching emails/phone numbers | Returns ambiguity; no silent choice between recipients. |
| Shortcuts | Discover/run installed shortcuts, optional text input/output | Extends reach to apps exposing Shortcuts. Uses the existing execute boundary. Process completion does not attest all app effects. |
| Music | Playback state, library search, exact track playback, pause, next/previous, volume | Local library; no purchase API. |
| Mail | Selected/recent inbox, read/flag status, editable drafts | Existing Email archive/reply/translation workflows and UI sending remain. Tool draft creation does not send. |
| Messages | Individual/group iMessage and SMS pages, supported archived text, sender and attachment metadata, paginated document extraction, exact-chat submission | Full Disk Access and Automation required. Complete observed group recipients must match; live membership is checked again. SMS depends on relay setup. Delivery is not attested. Unknown archives are marked unavailable; ambiguous typed streams are not guessed. |
| Files/documents | User-selected folders; list/search, paginated text extraction, new UTF-8 files, exact-version plain-text replacement, move/rename, Trash | Text/code, text PDF, RTF, DOCX, ODT. Relative paths only; symlink traversal blocked. No silent overwrite or rich-document flattening. Images/scanned PDFs use the owning app/screen route. |
| Document memory | Separate opt-in per selected folder; local excerpts while watching and memory are on | Bounded polling, not a complete filesystem index: skips hidden files/packages/links, scans up to 2000 entries per folder with a three-second budget, at most 100 changed documents/pass, 2 MB/file and 8000-character excerpts. Existing memories retain normal deletion/retention behavior. |
| MCP | Local stdio, Streamable HTTP JSON/SSE, legacy HTTP+SSE, common JSON import, paginated tool discovery, exclusions, notification refresh | Up to 200 tools over ten pages. Server validates its schema; all calls use execute boundaries even if annotated read-only. No server-initiated sampling, host tools or credential requests. |
| Authentication | Per-value Keychain environment/HTTP headers; native OAuth discovery, external-browser sign-in, loopback callback, S256 PKCE, dynamic registration or supplied client id, refresh and local sign-out | Service must support the native public-client flow. A service without dynamic registration needs a registered client id allowing loopback redirects. Client metadata-document registration, incremental scope challenges and provider-specific authentication are not implemented. |

The self-chat `/bobb` listener remains separate: only the configured exact self
chat can create commands. Groups, SMS and third-party messages never become
background instructions merely because the conversation tools can read them.

## Use

Use Option–Space, a desktop assignment or a browser assignment. Bobb can choose
`Mac tools`, prepare JSON arguments and invoke a tool, then return to the actual
app. Selection and argument preparation do not execute the tool. Permissions
and current app/action boundaries are rechecked before side effects.

In **Bobb → Computers**, choose folders, optionally enable document memory, or
add/import a connector. Imported connectors start disabled. **Test connection**
initializes the configured server and lists tools without invoking them. Local
processes still run with the user's account permissions.

```json
{
  "mcpServers": {
    "local-app": {
      "command": "/absolute/path/to/server",
      "args": ["--stdio"],
      "env": { "SERVICE_TOKEN": "your-own-token" },
      "excluded_tools": ["delete_everything"]
    },
    "remote-app": {
      "url": "https://service.example/mcp",
      "headers": { "Authorization": "Bearer your-own-token" }
    },
    "browser-sign-in": {
      "url": "https://service.example/mcp",
      "oauth": { "clientId": "your-registered-native-client-id" }
    }
  }
}
```

An empty OAuth client id requests automatic registration where supported. Use
`"type": "sse"` for an explicit legacy endpoint. Modern initialization may
negotiate legacy transport only after HTTP 404/405, before any tool call.

Remote URLs require HTTPS, except explicitly configured HTTP loopback services.
Connector redirects are rejected. Session id/protocol headers are preserved;
JSON and SSE responses are bounded. Credentials, authorization codes and PKCE
verifiers never enter the model context. Services receive their tool arguments;
model inference remains local. Removing a connector deletes its local secrets.
The original imported JSON is not rewritten and may still contain credentials.

OAuth follows MCP's [transport specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
and [authorization specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization).
Discovery requests use neither connector credentials nor shared browser cookies.
Tokens are bound to the configured resource and client, with refresh serialized
per account. Browser login is explicit; background calls never open a login UI.

## Completion, cancellation and uncertainty

Identical Calendar/Reminders creations, Mail drafts, message submissions and
new file creations reuse successful receipts within a task. Read calls and
playback commands remain repeatable. Successful receipts survive a permission
change after the effect, without displaying their content while access is denied.
This is not durable exactly-once execution across crashes.

A timeout, cancellation or adapter error after a potentially effectful call
blocks an identical automatic retry in that task. Verify the owning app before
starting another attempt. MCP writes are never replayed after session expiration.
Cancellation removes pending requests immediately and sends MCP cancellation;
remote cancellation does not guarantee the service has undone its action.

Results have explicit pages rather than silently dropping their tail. Completion
requires a current permitted result; failed or prepared-but-unsubmitted calls
cannot become successful completion. Calendar/Reminder writes and file changes
are read back; Mail drafts, Messages and Shortcuts retain their limited receipts.

## Validation

Core regressions exercise schema/type/range rejection, migrated settings,
URL/header restrictions, SSE decoding/bounds, discovery/form encoding, symlink
and relative-path containment, result paging, receipt reuse, uncertainty,
revocation and TaskLoop denial before an adapter runs.

macOS CI runs `BobbApp --check-integrations ../tests/fixtures/mcp_http_server.py`.
Disposable fixtures exercise native file creation/replacement/readback and RTF,
group Messages database reads and wrong-recipient rejection, HTTP JSON/SSE,
legacy/fallback negotiation, sessions, paginated/excluded tools, authorization
and redirect failures, cancellation, OAuth PKCE and refresh using only loopback
services. They never read the user's Messages database or send a real message.

Real services, consent dialogs, sync, actual delivery and sustained screen tasks
still require a Mac acceptance run. Use disposable events/files/reminders,
verify the visible effect, revoke access mid-task and confirm the next call
stops. OAuth needs an actual compatible service test as well. Build and fixture
success are not claims that every app or provider works.
