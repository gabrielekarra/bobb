# ADR-009: Bobb work and boundaries

SQLite in the network-free daemon is the authoritative work ledger. App-side supervisors claim leases, execute through a closed candidate set and persist reports. Scheduling coalesces missed executions using local calendar time, including DST. Restart interrupts in-flight work; uncertain actions are never automatically replayed. Explicit retries create new audit task IDs and retain prior evidence.

An explicit connected-app list governs reading as well as acting. Default-protected apps and secure fields remain denied. Consequential actions evaluate every matching boundary; deny takes precedence. Natural-language constraints never grant permissions. Settings are revalidated before action execution and after approval. Visual targets are reread and always ask.

Each assistant owns a persistent WebKit data store. Physical desktop leases include an OS file lock; user input interrupts background desktop work, with synthetic events tagged separately. A configured MCP computer is serialized across assistants. Servers receive a clean environment and cannot request host tools or sampling.

Optional cloud belongs to the app, uses a Keychain key, local request-specific redaction, a full redacted egress record and ephemeral HTTPS without redirects. It does not weaken the daemon's network isolation. Redaction is limited and cannot establish anonymity. Browser and explicitly configured connectors can use the network independently of cloud.

The optional VM has a separate disk and default-off networking. Its stdio MCP endpoint is reached over explicitly configured SSH, validates fresh candidate IDs and nonce, and independently enforces guest boundaries. No shared folders or credential forwarding.

Bobb is MIT licensed and has a community entitlement. Swift modules are `BobbApp` and `BobbCore`, the daemon is `bobbd`, the bundle identifier is `com.bobb.app`, and app data lives in `~/Library/Application Support/Bobb`. Liquid Glass uses native macOS 26 APIs when compiled with the new SDK, with system vibrancy fallback and reduced-transparency support.
