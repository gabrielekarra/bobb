# Cua / CUA-S1 technical due diligence

Status: complete, 2026-09-20. Prepared for the Leonard architecture decision
referenced in `PRODUCT.md` ("Actuation, accessibility tree, window state —
Cua Driver, MIT — under investigation") and `SYSTEM-ONE.md`.

Method: cloned `trycua/cua` at commit `9bbfa7d` (main, shallow) into a
scratchpad and read the actual Rust/Swift/Python source — not the README —
for every claim below unless explicitly marked otherwise. All file paths are
relative to the repo root unless given as absolute paths. Line numbers refer
to the clone as of that commit; they will drift as the repo moves. Web
sources (Hugging Face, GitHub issues, Hacker News, arXiv) are marked as such
and are separated from source-verified claims throughout.

**Bottom line up front:** yes, build on Cua Driver plus locally-trained
CUA-S1-style specialists, with no hosted model. Cua Driver gives us real
accessibility-tree reading and real background actuation on the user's live
desktop — genuinely, not as marketing — with two caveats that matter
operationally (a real, if narrow, focus/cursor-stealing mechanism, not a
guarantee; and native-AppKit background delivery is *empirically unproven*
for several action types per Cua's own test ledger). CUA-S1-FORMS's
architecture is small enough to reproduce exactly and retrain for a
different decision; its numbers are real but narrower than the headline
suggests, and the arXiv paper cited as "load-bearing" turns out to be
unrelated to this model family. Full build-vs-reuse table is in §5.

---

## 1. Cua Driver

### 1.1 What it actually is, structurally

`libs/cua-driver/` is not a thin wrapper — it's a ~40,000-line-per-platform
Rust workspace (`libs/cua-driver/rust/Cargo.toml`, 12 workspace crates) with
a shared core (`cua-driver-core`) and three platform crates:
`platform-macos`, `platform-windows`, `platform-linux`. macOS alone is
`libs/cua-driver/rust/crates/platform-macos/src/**/*.rs`, 40,451 lines across
81 files (`wc -l`, verified by me). It ships as a native daemon
(`cua-driver serve`) plus a CLI, spoken to over MCP (stdio) or the CLI's own
`call` subcommand. Python and TypeScript packages
(`libs/cua-driver/python`, `libs/cua-driver/typescript`) are thin client
wrappers over that daemon via UniFFI-generated bindings
(`libs/cua-driver/rust/crates/cua-driver-bindgen`) or the MCP/CLI transports —
there is no separate Python or TS implementation of the accessibility logic.

### 1.2 API surface

Enumerated directly from the macOS tool registry,
`libs/cua-driver/rust/crates/platform-macos/src/tools/mod.rs:3-38`:

- **Pointer/keyboard actuation:** `click`, `double_click`, `right_click`,
  `drag`, `type_text`, `type_text_chars`, `press_key`, `hotkey`, `scroll`,
  `move_cursor`
- **Observation:** `get_accessibility_tree`, `get_window_state`,
  `get_desktop_state`, `get_screen_size`, `get_cursor_position`, `list_apps`,
  `list_windows`
- **App/window lifecycle:** `launch_app`, `kill_app`, `bring_to_front`,
  `set_window_frame`, `invoke_menu`
- **Element mutation:** `set_value` (AX value write, optional/advertised
  capability — see §1.5)
- **Utility:** `clipboard`, `zoom` (pixel-space zoom for `px`-addressed
  clicks), `check_permissions`, `health_report`, `get_config`/`set_config`
- **Session:** `start_session`/`end_session` (seen from the client side,
  `libs/cua-s1/python/src/cua_s1/driver.py:158-162`)
- **Browser family** (Chromium-based, via CDP):
  `browser_prepare`, `browser_navigate`, and DOM/page tools under
  `libs/cua-driver/rust/crates/cua-driver-core/src/browser/*.rs`
  (`binding.rs`, `cdp_ws.rs`, `semantic.rs`, `tools.rs`, `mutation.rs`) —
  confirmed in use in `libs/cua-driver/examples/jev-use/python/core.py`.
- Note: `screenshot`/`screenshot_compat` tools were **removed** in PR #1692;
  a screenshot now always rides along in `get_window_state`'s response
  (comment at `tools/mod.rs:19-23`). There is no separate
  vision/AX capture-mode switch any more — `get_window_state` always returns
  both the AX tree and a PNG (`rust/Skills/cua-driver/MACOS.md:145-150`).

Every mutating tool follows a **snapshot-bound token** contract: you cannot
click "element 7" by bare index — you must hold a `snapshot_id` and
`element_token` from a fresh `get_window_state` call, and a stale token is
rejected (`element_token_missing`, `stale_element_token`,
`snapshot_id_required` — seen from both the Rust core comments and the
Python client's error codes, `libs/cua-s1/python/src/cua_s1/driver.py:81-139`).
This is a real anti-staleness guarantee, not a convention.

### 1.3 Accessibility-tree reading — the actual mechanism

Confirmed at `libs/cua-driver/rust/crates/platform-macos/src/ax/bindings.rs:1-96`:
raw `extern "C"` FFI bindings to the public macOS Accessibility API —
`AXUIElementCreateApplication`, `AXUIElementCopyAttributeValue`,
`AXUIElementCopyAttributeNames`, `AXUIElementCopyActionNames`,
`AXUIElementCopyElementAtPosition`, `AXUIElementPerformAction`,
`AXUIElementSetAttributeValue`, `AXIsProcessTrusted`,
`AXIsProcessTrustedWithOptions`, and the private SPI
`_AXUIElementGetWindow` (maps an `AXUIElementRef` to a `CGWindowID`; this one
symbol is the only private API in the AX binding layer).

Tree walk: `ax/tree.rs:165-300`, `walk_tree_bounded(pid, window_id, query,
max_elements, max_depth)`. Concretely:

- Unions `AXChildren` and `AXWindows` (`tree.rs:210-225`) because AppKit
  omits background windows from `AXChildren` when the app isn't frontmost —
  the driver explicitly compensates for this rather than requiring
  foreground state to see windows.
- Flips `AXManualAccessibility`/enablement attributes for Chromium/Electron
  targets before walking (`ax/tree.rs:186-192`, delegates to
  `ax/enablement.rs`), because those apps build their AX tree lazily and
  return an empty tree on first ask otherwise (documented bug reference
  `#1616`).
- Bounds the walk: `DEFAULT_MAX_DEPTH = 25`, `DEFAULT_MAX_ELEMENTS = 2000`
  (`ax/tree.rs:24-33`), returns a `truncated: true` flag and a partial tree
  rather than hanging on pathological trees (VS Code/Obsidian called out by
  name in the comment).
- Per-element AX call has a 2-second messaging timeout
  (`AX_MESSAGING_TIMEOUT_SECONDS = 2.0`, `ax/tree.rs:38-42`) via
  `AXUIElementSetMessagingTimeout`, because Tokio cannot cancel a blocked
  native AX call once dispatched.
- **Node shape** (`ax/tree.rs:47-95`, `struct AXNode`): `element_index`
  (`Some` only if actionable — has ≥1 AX action or a writable value
  surface), `role`, `title` (AXTitle), `value` (AXValue), `description`
  (AXDescription, kept separate because some apps put the real label there
  and leave AXTitle empty), `identifier`, `help`, `actions` (AXActionNames),
  `frame` (screen-space bounding rect), `value_state`/`value_description`
  (range controls), `min_value`/`max_value`, `enabled`, `selected`,
  `in_web_content` (AXWebArea ancestry flag). This is a genuinely rich,
  typed structure — not just a text dump — and the output format is a
  compact indented markdown tree (`- [N] AXRole "Title" [value="..."
  actions=[...]]`) designed to be token-cheap for an LLM context window.
- **Completeness caveat, in the driver's own docs, not mine:**
  `rust/Skills/cua-driver/MACOS.md:145-165` states plainly that an empty
  `tree_markdown` with `degraded: true` means "the surface isn't AX" —
  canvas-backed editors (Monaco/VS Code, Cursor, xterm, Figma, WebGL) render
  nothing useful into the AX tree; the documented fallback is pixel
  addressing off the screenshot that rides along in the same response. So
  AX-tree completeness is real but app-dependent, and the driver's own
  skill file tells the calling agent to expect and detect this, not assume
  universal AX coverage.

### 1.4 The "without stealing cursor or focus" claim — verified mechanism, with a real caveat

This is not marketing puffery; there is a specific, inspectable mechanism,
and it is also explicitly documented as incomplete by the same team.

**How input is delivered without moving the real cursor** —
`platform-macos/src/input/mouse.rs:1-13, 44-50`: background clicks are
posted via `SLEventPostToPid`, a private SkyLight SPI, with fallback to the
public `CGEvent::post_to_pid` on older macOS. The comment is explicit about
*why*: `SLEventPostToPid` routes through `IOHIDPostEvent`, which triggers
`CGSTickleActivityMonitor` (needed for Catalyst/Chromium windows) and
reaches Mac Catalyst windows the public API misses; mouse events
deliberately omit the `SLSEventAuthenticationMessage` envelope so they don't
route through `cgAnnotatedSessionEventTap`, which Chromium's window handler
subscribes to. Window-local target: `CGEventSetWindowLocation` SPI stamps a
window-local point so WindowServer's hit-test resolves against the target
window directly rather than the physical pointer position
(`mouse.rs:44-50`). There is also a genuinely separate desktop-scope path,
`click_at_xy_desktop` (`mouse.rs:57-70`), which posts to the global HID tap
and *does* land on real screen coordinates honoring real Z-order — used only
when the agent has located a target by vision and there is no pid/window
target, and it is a documented, opt-in different code path, not a fallback
silently taken.

**Routing/refusal ladder** — `cua-driver-core/src/background_input.rs`: a
pure, side-effect-free decision module (no I/O, fully unit-testable —
confirmed by reading it, it does exactly what it says) that classifies every
mutating action into `AxSemantic` (AXPress/AXConfirm/value writes on an
exact element), `WindowPointer` (window-local routed click, real pointer
untouched), `InsertText`/`GenericKey` (process-scoped keyboard), and refuses
with a stable machine-readable code — `window_not_found`,
`owner_pid_mismatch`, `off_space_or_ax_unresolved`,
`minimized_or_hidden_window`, `same_pid_keyboard_ambiguity`,
`element_outside_target_window` — rather than silently falling back to a
less-safe route. Facts feeding this decision must be freshly gathered
immediately before dispatch and "unknown facts must stay unknown... fail
closed" (`background_input.rs:49-56` docstring) — e.g. `target_minimized:
Option<bool>`, `None` never unlocks the pointer/keyboard routes.

**The caveat, in their own words** —
`platform-macos/src/focus_guard.rs:1-40`: Swift's reference implementation
does three layers (enablement, synthetic-focus write/restore, and a
reactive focus-steal suppressor); **this Rust port only ships layer 3**, and
says so directly: *"This Rust port only ships layer 3 (the reactive
suppressor)... This gap is a known, intentional limitation."* Layer 3 works
by arming a targeted suppressor before an AX action that might trigger a
reflexive self-activation (their example: Safari/WebKit pulling itself
frontmost when an `AXSelectedText` write hits a focused input even without
going through `NSApp.activate`), then re-activating the prior frontmost app
if the target activates anyway, with a 50ms grace window to observe the
reflex (`focus_guard.rs:60-70`). **So the guarantee is "we detect and undo a
focus steal after the fact in the majority of cases we've tested," not "the
target physically cannot steal focus."** That is a materially weaker claim
than the marketing phrasing, and worth carrying into any UX promise we make
to the user about never touching their frontmost app.

The team's own internal skill doc,
`rust/Skills/cua-driver/MACOS.md:9-16`, states the actual design intent as
plainly as I could ask for: *"The user's frontmost app MUST NOT change...
Violate this rule and every other nice property the driver gives you (no
cursor warp, no Space switch, no window raise) stops mattering."* It then
enumerates, at length, every macOS API that *does* steal focus (`open`,
`osascript ... activate`, `cliclick`, raw `CGEventPost` at a coordinate over
another app, tab-switching shortcuts like ⌘1..9, omnibox-focus shortcuts
like ⌘L) as things the calling agent must never use — this is a behavioral
contract enforced by convention/documentation for the *agent*, backed by the
layer-3 reactive guard in the *driver*, not a kernel-level guarantee.

**Empirical honesty check** —
`libs/cua-driver/docs/action-support.md` is a machine-generated ledger of
which action/backend/OS combinations have actually been proven by an E2E
harness with observed evidence, versus which are "Gap: unsupported or not
yet proven." For **Native macOS/AppKit** specifically (as opposed to
Electron/Tauri/WKWebView-hosted apps, which are far more thoroughly proven):
*"Native press key, hotkey, AX-addressed right/double click, and broader
control combinations remain unproven."* This is a materially important
finding: the framework's own test ledger says several common background
actions against plain native Cocoa apps are not yet empirically verified,
only implemented. We should treat "works on native AppKit apps" as
per-action-verified, not assumed, for anything outside proven click/set
value/type text.

### 1.5 Invocation and transports

- **Daemon + MCP (primary):** `cua-driver serve`, spoken to over MCP stdio.
  `libs/cua-s1/python/src/cua_s1/driver.py:437-490`, `McpDriver`, opens one
  persistent `cua-driver mcp` subprocess via the `mcp` Python package
  (`stdio_client`/`ClientSession`), keeps it alive across the whole decision
  loop, and does live tool discovery (`list_tools()`) rather than assuming a
  fixed tool set — `supports_value_mutation()` checks whether the connected
  runtime actually advertises `set_value` before trying to use it
  (`driver.py:251-261`), i.e. the client is written defensively against a
  driver version that doesn't expose everything.
- **CLI (fallback/scripting):** `cua-driver call <tool>` with JSON on stdin,
  used by `CliDriver` (`driver.py:349-434`) and discoverable via
  `cua-driver list-tools`.
- **Native/embedded:** UniFFI-generated bindings
  (`libs/cua-driver/rust/crates/cua-driver-bindgen`,
  `cua-driver-sdk/src/embedded.rs`) for in-process embedding (e.g. an
  Electron main process, per `typescript/src/electron.ts`), and a C ABI
  (`rust/include/cua_driver_abi.h`) for non-Rust native hosts. This matters
  for us: a Swift app does not have to shell out to a CLI or speak MCP over
  a pipe — there is a native binding path.
- **Windows/Linux:** separate platform crates using UI Automation
  (`platform-windows/src/uia`) and AT-SPI/X11/Wayland
  (`platform-linux/src/atspi`, `x11`, `wayland`) respectively — out of scope
  for us (macOS-only product) but confirms the AX-tree abstraction is not a
  macOS-only design; the driver core (`cua-driver-core`) is platform-neutral
  and each platform crate implements the same tool contract.

### 1.6 macOS permission requirements

Confirmed directly, `platform-macos/src/permissions/status.rs:1-70`:

- **Accessibility** — `AXIsProcessTrusted()` (live, no caching); prompted via
  `AXIsProcessTrustedWithOptions` with `AXTrustedCheckOptionPrompt`. Required
  for every AX read and action.
- **Screen Recording** — `CGPreflightScreenCaptureAccess()`, prompted via
  `CGRequestScreenCaptureAccess()`. The code comment is worth keeping:
  an earlier version inferred this grant from whether
  `CGWindowListCopyWindowInfo` returned populated windows, which is **wrong**
  — that API returns window IDs/bounds for any process without the grant;
  only titles are gated — and produced false positives after a `tccutil
  reset`. This was fixed to use the real preflight call. Worth knowing this
  bug existed and was caught, as a signal about code quality on the security
  boundary.
- Startup gate (`permissions/gate.rs`) requires **both** grants before AX
  actions are allowed; if only Accessibility is granted the docs direct the
  agent to operate AX-only with `include_screenshot:false` and no pixel
  addressing (`rust/Skills/cua-driver/MACOS.md:230-245`).
- **Automation (Apple Events, `kTCCServiceAppleEvents`) — not documented as
  required anywhere I found, but I could not fully rule it out and flag this
  as an open verification item, not a settled fact.** `launch_app` on macOS
  goes through `NSWorkspace.openApplication(at:configuration:)` and attaches
  a synthetic `aevt/oapp` Apple Event via
  `NSWorkspaceOpenConfiguration.appleEvent`
  (`platform-macos/src/apps/nsworkspace.rs:17-25, 102-113, 533-555`) —
  this is Apple's documented, public API for "open without necessarily
  activating," and it is plausible it's exempt from the Automation TCC
  prompt because it routes through LaunchServices rather than addressing a
  foreign app's own AppleScript dictionary via `NSAppleScript`/`AESend`
  (which is what normally triggers the Automation permission dialog). I did
  not find code in this repo that constructs a `tell application "X"`-style
  scripting bridge — `invoke_menu` drives `AXMenuBar`/`AXPress` directly
  (`platform-macos/src/tools/invoke_menu.rs:137-156`), not AppleScript. But
  I have not run the daemon against a fresh TCC database to confirm no
  Automation prompt appears, and the repo's own permission docs only ever
  mention Accessibility and Screen Recording. **Treat "only two permissions
  needed" as the documented claim, verify empirically before we build a
  permissions-onboarding UX around it.**

### 1.7 VM/sandbox requirement — none, by design

This is the most important fact for us and it is unambiguous in the source.
The entire architecture in §1.4 — background delivery via `SLEventPostToPid`
routed to a specific `pid`/`CGWindowID`, the no-foreground contract, the AX
tree read from the live process — exists specifically to drive **the user's
own live desktop session** without a VM. `Lume` (`libs/lume/README.md:1-20`)
is a wholly separate component: a CLI/framework for creating **isolated**
macOS/Linux VMs on Apple's Virtualization.framework, aimed at cloud fleets
and training/eval sandboxes (`Cua Fleets`, `Cua Bench`), not at driving a
user's real session. Nothing in `cua-driver`'s tool set or transport layer
requires or assumes a VM; `Lume` and `cua-driver` are independent,
separately-installed components in the monorepo (`libs/lume` vs.
`libs/cua-driver`) with no code dependency from driver into lume that I
found. This directly satisfies our "must drive the real desktop, not a VM"
requirement.

### 1.8 License and dependency licenses

- Top-level `LICENSE.md`: MIT, Cua AI, Inc., 2025 — confirmed by reading the
  file. `libs/cua-driver/rust/Cargo.toml:1-15` (workspace manifest) declares
  `license = "MIT"` for the whole Rust workspace.
- **Flagged AGPL/CC-BY dependency is not in Cua Driver or CUA-S1.** The
  top-level `README.md` license section (bottom of file) states: *"Kasm
  (MIT) · OmniParser (CC-BY-4.0) · Optional `cua-agent[omni]` includes
  ultralytics (AGPL-3.0)."* I could not find a `cua-agent` package anywhere
  in this clone (`find . -iname '*cua-agent*'` returns nothing under
  `libs/`) — it appears to be a separate, optional legacy/adjacent component
  not vendored in this repo snapshot, referenced only from the README's
  license roll-up. **This AGPL exposure is specific to an optional
  vision-based screen-parsing agent package we would not use** — our design
  reads the AX tree, not OmniParser-style pixel/vision UI parsing — so it is
  not a licensing concern for the Cua Driver + CUA-S1 slice we'd actually
  build on. Worth remembering only if a later phase reaches for
  vision-based UI parsing as an AX fallback.
- **Rust dependency tree not fully audited.** `Cargo.lock` locks 614
  packages (`grep -c "^name = "`) and, as is normal for `Cargo.lock`, carries
  no license metadata — auditing all 614 transitive crate licenses would
  need `cargo-license`/`cargo-deny` run against the real crates.io registry,
  which I did not do. The Rust ecosystem's default license posture is
  overwhelmingly MIT/Apache-2.0/BSD, and nothing in the workspace
  `Cargo.toml` dependency list I read (`tokio`, `serde`, `objc2*`,
  `core-graphics`, `core-foundation`, `uniffi`, `zstd`, `chacha20poly1305`,
  etc.) is a package known to carry a copyleft license, but I am stating
  plainly that I did not run the audit tool and this is a gap, not a
  clearance.
- **cua-s1's Python deps** (`libs/cua-s1/python/pyproject.toml:23-27`):
  `numpy`, `safetensors`, `torch` only (plus optional `pdfplumber`, `mcp`).
  No `transformers`, no vision libraries — consistent with the architecture
  being hand-rolled rather than built on a heavyweight HF stack.

---

## 2. CUA-S1-FORMS — the specialist architecture

### 2.1 Architecture, precisely (source: `libs/cua-s1/python/src/cua_s1/model.py`)

This is small enough to fully specify. Two encoder variants share one
scoring head:

- **Tokenization** — `_byte_ids` (`model.py:48-49`): raw UTF-8 bytes,
  `byte + 1` (reserving id 0 for padding), truncated to a fixed length. No
  BPE, no tokenizer vocabulary, no external tokenizer dependency. Vocabulary
  size is exactly 257 (256 byte values + pad) —
  `nn.Embedding(257, width, padding_idx=0)` (`model.py:146, 186`).
- **`TinyScorer`** ("tiny" config, `model.py:139-163`): byte embedding + a
  learned position embedding over the context, mean-pools each option's
  token embeddings (no transformer over options at all), then scores via
  `AttentionHead`.
- **`TinyTransformerScorer`** ("tinyx" config — this is the one CUA-S1-FORMS
  ships, `model.py:166-236`): a real `nn.TransformerEncoder` (`layers=2`
  default) over the byte-embedded context, and a **separate** one-layer
  `nn.TransformerEncoder` applied independently to each option's byte
  sequence (batched as `batch*options` rows), mean-pooled over unmasked
  tokens, then scored via the same `AttentionHead`.
- **`AttentionHead`** (`model.py:102-136`) — this is the actual decision
  mechanism, and it's simple enough to fully describe: LayerNorm both
  context and pooled-option representations, project options to queries and
  context to keys/values at a low rank (`rank`, no bias), do one cross-
  attention pass (options attend over context tokens, masked by
  `context_mask`), then the **logit per option** is
  `(query · attended) / sqrt(rank)` — a dot product between the option's own
  query vector and what it attended to in the context, not a separate
  classifier head. Option logits are masked to `-inf` wherever `option_mask`
  is false (variable option-set sizes per example) before the caller applies
  softmax/cross-entropy.
- **Loss** — plain `torch.nn.functional.cross_entropy(logits, labels)`
  (`training/train.py:233`, single scalar over the option dimension per
  example) — this is single-label classification over a *variable-size,
  per-example* candidate set, not a fixed-class classifier. That variable-
  cardinality-option design is the part most worth copying for a different
  decision: the number of "options" (candidates) can differ per example as
  long as they're rendered as text and masked correctly.
- **Default hyperparameters** (`training/train.py:301-307`, argparse
  defaults): `encoder=tinyx, width=128, rank=128, layers=2, heads=4,
  context_tokens=224, option_tokens=96`.

**Independent parameter-count verification.** I hand-computed the parameter
count from these exact defaults rather than trusting the marketing figure:
embedding `257×128=32,896` + position `224×128=28,672` + context encoder
(2× `nn.TransformerEncoderLayer(128,4,512)` @ 198,272 params each =
396,544) + option encoder (1× same layer = 198,272) + `AttentionHead`
(2 LayerNorms @ 256 + 3× `Linear(128,128,bias=False)` @ 16,384 = 49,664) =
**706,048**, exactly matching the publicly reported figure. This is a real,
independently-reproduced number, not a re-quote — see the working in the
commit history of this investigation's scratchpad if it needs to be
re-derived. Confirmed a second, independent way: GitHub issue #3977 (below)
reports loading the *actual published checkpoint* and printing
`trainable params: 706,048` from the real `state_dict`.

**Checkpoint format** — `libs/cua-s1/python/src/cua_s1/checkpoint.py`:
`safetensors` + JSON config only; `resolve_checkpoint_paths` explicitly
rejects `.pt/.pth/.bin/.pkl/.pickle` (pickle-based checkpoints) with a hard
error, specifically so that loading a checkpoint never executes arbitrary
code (`checkpoint.py`, and confirmed in RFC #3962: *"Checkpoint loading must
not execute pickle payloads"*). `706,048 × 4 bytes (float32) = 2,824,192
bytes ≈ 2.8 MB`, matching the reported checkpoint size exactly for an
uncompressed float32 safetensors dump.

**Live bug worth knowing about (GitHub issue #3977, open at time of
writing):** the checkpoint actually published to `huggingface.co/cua-ai/
cua-s1-forms` is a **pickle `.pt` file**, which the MIT-licensed loader in
this same repo rejects by design (the exact error is `"legacy pickle-based
checkpoints are not supported"`). The model card's copy-pasteable quickstart
therefore does not run as published; a one-time local conversion
(`torch.load(..., weights_only=True)` → `save_checkpoint()`) is required
first. The issue author confirmed the real checkpoint contents this way:
`state_dict: 45 tensors`, `trainable params: 706,048`, and reproduced a
sane top-3 prediction on a synthetic phone-number field after conversion.
**Practical implication for us: don't point a Swift build's asset pipeline
at the HF `.pt` file directly — convert to safetensors first, or use one of
the community CoreML/ONNX exports (§2.5), which have already done this
conversion.** One curiosity surfaced by that issue: the recovered checkpoint
config contains an unused field `"hf_model": "Qwen/Qwen2.5-0.5B"`, which the
`tinyx` code path never reads — a provenance leftover (possibly an earlier,
abandoned approach using a much larger backbone) rather than something with
current effect; noting it, not over-reading it.

### 2.2 Synthetic data generator (source: `libs/cua-s1/python/src/cua_s1/synth.py`, `concepts.py`)

This is the piece we would need to reproduce for our own decision, and it is
genuinely cheap and copyable:

- **Concept catalog** — `concepts.py` defines ~55 typed field "concepts"
  across 16 groups (`name, contact, dates, address, insurance, emergency,
  employment, web, ids, vehicle, banking, education, medical, demographic,
  business, claim` — counted directly via `grep -c "group="`), each with a
  set of plausible form-side labels, plausible document-side labels, a
  placeholder pool, and a value generator function seeded off Python's
  `random.Random`.
- **Episode generation** — `sample_form` (`synth.py:82-158`) picks 2-5
  concept groups, 4-16 concepts from them, and deliberately **co-locates
  known confusable pairs** — a hard-coded list of 12 tuples like
  `("email","street")`, `("phone","ec_phone")`, `("dob","incident_date")`
  (`synth.py:92-105`) — into the same form with probability
  `hard_negative_probability=0.35`, specifically to force the model to read
  the full label rather than learn a group-level shortcut. `sample_document`
  (`synth.py:168-201`) generates entities for present fields (with a 12%
  chance of *not* generating the answer at all, forcing a `skip`), plus
  extra/distractor entities that don't map to any field, then shuffles
  order.
- **Context/option rendering is a fixed three-line template**, not a
  generative model call — `schema.py:53-64`:
  `"TASK fill the form from the document, then submit\nFORM <title>\nELEMENT
  <role> \"<label>\" value=\"...\""`, truncated to small fixed character
  budgets (title 64 chars, label 72, value 48, hint 72). Options are
  `"fill <label>: <value>"` per candidate entity plus three fixed actions
  (`check`, `click`, `skip`) — `schema.py:71-73`. This whole pipeline is
  pure string templating plus a PRNG; **no LLM is called anywhere in
  generation**, which is why it's fast and fully deterministic (seeded).
- **Split integrity** — `form_signature` (`synth.py:161-165`) hashes the
  sorted set of field concepts per form, and `write_splits` buckets whole
  episodes into train/validation/test by a stable SHA-256 fraction of that
  signature (`synth.py:268-317`), so the *same field combination* can never
  appear in both train and test. This is a real, sound anti-leakage
  practice, not just a random row-level split.
- **Default generation volume** — CLI defaults in `synth.py:350-353`:
  `--episodes 6000 --seed 2026`, 80/10/10 split. The Hugging Face model card
  (fetched directly, see §2.4) states the *shipped* checkpoint was trained
  on **10,000 synthetic episodes**, not the 6,000 source default — the
  published run used different CLI args than the repo's out-of-the-box
  default. Both numbers are worth carrying (source default vs. actual
  release run) rather than conflating them.

### 2.3 Training loop (source: `libs/cua-s1/training/train.py`)

`AdamW` (`weight_decay=1e-2`), cosine LR schedule with 5% linear warmup
(`train.py:211-219`), gradient clipping at norm 1.0, cross-entropy loss,
deterministic seeding (`torch.use_deterministic_algorithms`, seeded
DataLoader generator/workers) with a documented reproducibility path
(`train.py:73-86`). Default CLI: `epochs=10, batch_size=128,
learning_rate=2e-3` (`train.py:308-311`); the published HF checkpoint used
**6 epochs**, batch 128 (per HF model card, §2.4) — again, differs from the
repo's own CLI default, so cite whichever number matches the artifact you
mean.

**Evaluation methodology is genuinely rigorous** — `train.py:89-149`
(`evaluate()`) reports top-1 accuracy, per-example NLL, a real expected
calibration error computed over 10 confidence buckets, per-action accuracy
breakdown, and throughput; `libs/cua-s1/evals/metrics.py` (read in full)
separately computes accuracy, coverage, abstention rate, **selective**
accuracy (accuracy only among non-abstained predictions), wrong-action rate,
wrong-target rate, and an explicit `unsafe_action_rate` (acted when the gold
answer required abstention) — this abstention-aware metric set is exactly
the shape we'd want for an "interrupt or not" decision, where acting when
you should have stayed silent is the costly failure mode, not just raw
accuracy.

**An ablation ladder exists and is informative for §2.6** —
`libs/cua-s1/training/autoresearch.py:26-54`, `DEFAULT_LADDER`: the repo's
own tooling compares `tiny-64` (mean-pool, width 64), `tiny-256` (width
256), `tinyx-128-l2` (the shipped default), `tinyx-192-l3` (6 heads),
`tinyx-256-l4` (8 heads, lower LR), and a longer-trained (`12 epochs`)
variant of the default — i.e. the team already tested "make it bigger" as a
lever and shipped the *smallest* transformer variant, not the largest one
they tried. This is decent evidence the 706K size was a deliberate choice
within a tested range, not an unexamined default — though the actual
autoresearch *results* (which config won) are not in this source-only repo;
only the harness that would produce them is.

**Training hardware and wall-clock time: not stated anywhere I could find,
and I am flagging this as a genuine gap rather than estimating a number.**
`train.py` uses `select_device("auto")` (CUDA → MPS → CPU) with no fixed
target; `autoresearch.py` has a `--record-timing` flag but no committed
results file with timing populated; the Hugging Face model card (fetched
directly) does not state hardware or wall-clock training time either. What
*can* be said with actual evidence: GitHub issue #3977's author converted
and ran inference for this exact checkpoint on `device: mps` on an Apple M5
and it worked correctly, so MPS is a confirmed working inference target;
whether the *training* run itself used MPS, CUDA, or something else is not
documented. Given the model's size (706K params) and non-huge dataset
(10K episodes, mid-thousands of rows given ~15-25 rows per episode), a
back-of-envelope estimate would put training at low tens of minutes on any
single modern GPU or Apple Silicon MPS device for 6-10 epochs — but I am
explicitly labeling that an estimate, not a sourced number, per the
instruction to carry measurement conditions or say plainly there are none.

### 2.4 Reported results (Hugging Face model card, `cua-ai/cua-s1-forms` — web source, not code)

Fetched directly from the live Hugging Face page (not the repo, which
ships no results):

| Metric | Value | Condition |
|---|---|---|
| Parameters | 706,048 trainable | — |
| Checkpoint size | 2.8 MB | `state_dict` + config + training history + best-validation metrics |
| Training data | 10,000 synthetic episodes | 2-16 fields/form, 55-concept catalog |
| Training | AdamW, cosine+warmup, 6 epochs, batch 128 | splits disjoint by exact form-field signature |
| Synthetic test accuracy | 99.95% | held-out synthetic split |
| Real demo evaluation | 100% | 196 decisions across 3 real forms + PDFs |
| Shuffled-context control | 37% | context tokens shuffled — confirms the model reads the actual element, not a positional/statistical shortcut |
| vs. hosted Jev API | 99.7% (this model) vs. 83.6% (Jev) | same narrow form-decision task |
| License | MIT (per HF card) | model card should be checked directly before relying on this — the repo's own `MODEL_CARD.md` (source, see below) is explicit that *source* is MIT but a future *checkpoint* license may differ and require a commercial agreement for production use |

**I did not independently reproduce the 99.95%/100%/99.7% numbers — they
are vendor-reported, on the vendor's own benchmark, on a task the vendor
defined and the specialist was trained for while the Jev comparator was
not.** That last point (specialist trained for the task, general "System
One" comparator not) is stated candidly by the source repo's own
`MODEL_CARD.md`, not hidden: *"No model result is claimed by this
source-only component."* The 196-decision "real demo evaluation" is a small
n; treat the 100% figure as a demo-scale sanity check, not a statistically
powered claim. The repo's `MODEL_CARD.md` (`libs/cua-s1/MODEL_CARD.md`,
read in full) is unusually candid for a model card — it explicitly lists
"the model may select the wrong target, enter incorrect information, expose
sensitive data, repeat an action, or report success without satisfying the
intended outcome" under Limitations, and states this component "does not
distribute weights, training datasets, or a checkpoint artifact manifest" —
the size/accuracy numbers above are 100% sourced from the separate Hugging
Face artifact page, never from the MIT source repo itself, and the MIT
license explicitly does not extend to "future official model weights."

### 2.5 Running inference — runtime deps, and a real no-Python path

Pure PyTorch (`torch`, `safetensors`, `numpy`) is the only in-repo inference
path — `libs/cua-s1/python/src/cua_s1/model.py:304-319` (`load_checkpoint`),
no GPU required, runs on CPU/MPS/CUDA via `select_device`. An optional MCP
server (`cua-s1-mcp`, `server.py`) wraps this for tool-based invocation, and
`libs/cua-s1/python/src/cua_s1/planner.py:49-60` defines a `PlanningBackend`
`Protocol` that is explicitly model-agnostic (local, remote, or test scorer
all implement the same `plan(form_title, elements, entities) ->
Sequence[Decision]` interface) — this is the seam we'd reuse for a different
decision.

**A CoreML path exists and targets exactly what we need** (community port,
not official — `FluidInference/cua-s1-forms-coreml` on Hugging Face, web
source, fetched directly): targets **iOS 17/macOS 14+, Swift, with Apple
Neural Engine/CPU/GPU compute units**, ships both `.mlpackage` and
precompiled `.mlmodelc`. Conversion notes are candid about what had to
change to make it export cleanly: *"export-compatible masking, a
floating-point clamp constant, finite padded logits, and disabling the
fused PyTorch Transformer fast path during tracing"* — i.e. the standard
`nn.TransformerEncoderLayer` ops needed minor adaptation for CoreML tracing,
nothing exotic. Reported parity: identical top-1 option selection to the
PyTorch original on **24,370 synthetic rows (99.9549%)**, with strict
numerical parity failing on 11 rows (max probability error 0.0205) —
i.e. occasionally a slightly different confidence number, essentially never
a different decision. Package size **1.51 MB (FP16)**, median latency
**0.90–1.85 ms on an Apple M5 Pro**. This is a real, working, Swift-native,
no-Python inference path for the exact architecture we'd be copying.

An ONNX community port also exists (`yasserrmd/cua-s1-forms-onnx`, web
source) targeting ONNX Runtime/ONNX Runtime Web/WASM/WebGPU, ~15ms median on
CPU — less relevant to us than the CoreML port given we're targeting a
native Swift/macOS process, but confirms the architecture has no CoreML- or
PyTorch-specific ops that block portability.

### 2.6 Is 706K parameters plausibly enough for a harder decision, and what would have to change

**For form-field selection specifically, the evidence (vendor-reported, see
caveats in §2.4) is that yes — a sub-1M-parameter byte-level scorer gets
very high accuracy on a narrow, well-posed classification task with a small
closed option set, and the shuffled-context control (37% vs. 99.95%) is
good evidence it's actually reading content rather than pattern-matching
position.** But the honest scope of what was validated is narrow:
single-step, single-element, fully-observed, text-only, closed 4-action
vocabulary (fill/check/click/skip), synthetic training distribution.

**What would have to change for "should I interrupt the user right now?"**
(the Leonard tier-0 decision named in `SYSTEM-ONE.md`), reasoning from the
architecture directly:

1. **Context encoding is byte-level text-only — no screenshots, no
   structured event history beyond what fits in 224 bytes of context.**
   `AttentionHead` takes one flat context sequence; there's no notion of
   *time* or *recency-weighted event sequence* built in. An interruption
   decision needs recent activity (app switches, typing cadence, idle time),
   current app/window state, and message content — this is naturally a
   short *sequence of typed events*, not one paragraph of text. The context
   encoder would need either (a) a longer byte budget with a structured
   serialization of recent events into the same template-string approach
   `render_context` uses (cheap, reuses the existing architecture
   unchanged), or (b) actual positional/temporal structure (e.g. one
   transformer token per recent event rather than per byte) — a real
   architecture change, not a config tweak.
2. **The option set here isn't "pick one of these pre-extracted entities" —
   it's closer to a fixed small action set (interrupt now / prepare
   silently / wait / suppress) with a *graded urgency*, not a pointer into
   document entities.** That's actually a simplification relative to
   CUA-S1-FORMS's "fill" action (which requires the entity-pointer
   mechanism); Leonard's decision is closer to the *scorer's* fixed-action
   branch (`check`/`click`/`skip` in the forms model) than to its
   entity-fill branch — good news, since that's the simpler half of the
   existing head to reuse.
3. **Calibration matters more here than for forms.** A forms specialist
   that's slightly overconfident on a wrong fill just produces a wrong form
   value a human proofreads before submit. An attention specialist that's
   overconfident about *not* interrupting silently drops something
   important. `train.py`'s expected-calibration-error metric
   (`train.py:130-137`) is already computed and already the right thing to
   watch; nothing architectural needs to change here, just the acceptance
   bar on ECE and on `unsafe_action_rate` before trusting the specialist
   unsupervised (this maps directly onto Leonard's own confidence-floor
   design referenced in `CONTRACT.md`).
4. **Training data cannot be template-generated the way form data is.**
   Section 2.2's generator works because "what value goes in this field" is
   a closed, enumerable, synthesizable domain (fictional phone numbers,
   fictional names). "Should I interrupt right now" is a preference
   distribution over one person's actual behavior — this is exactly the gap
   `PRODUCT.md` already names as the open research risk ("on-device
   specialist training from sparse real behaviour is unproven"), and
   nothing in the CUA-S1 source resolves it; CUA-S1-FORMS's specific
   training recipe (synthetic template generation) is not the recipe we'd
   use for this decision — we'd be reusing the *model architecture and
   training loop*, not the *data generator*, for this particular
   specialist. Say this plainly rather than assume the whole CUA-S1
   pipeline transfers.
5. **Model capacity itself is probably not the bottleneck.** Given the
   ablation ladder in §2.3 already tested wider/deeper variants without
   (as far as this source-only repo shows) a documented case for going
   bigger, and given the interruption decision described above has a
   *smaller* action space than forms (no entity-pointer branch), 706K–1M
   parameters is a reasonable starting point, not an obviously undersized
   one. The harder problem is data, not architecture.

---

## 3. jev-use

### 3.1 What it is

`jev-use` (`skills/jev-use/SKILL.md`, runnable reference at
`libs/cua-driver/examples/jev-use/`) is Cua's own published recipe for
pairing Cua Driver with **TypeSafe's hosted Jev** — the same hosted "System
One" API that Leonard's `ADR-004` and `SYSTEM-ONE.md` already discuss and
have already decided not to use on the attention path. Reading the actual
recipe confirms and sharpens what those two docs already assume.

### 3.2 The loop, step by step (source: `skills/jev-use/SKILL.md`, `examples/jev-use/README.md`, `python/jev_adapter.py`)

1. Obtain a fresh Cua Driver observation over one persistent MCP/CLI
   session (browser DOM/semantic state preferred; AX tree otherwise).
2. **The calling application, not Jev, constructs the full candidate
   table.** Each candidate is a complete, executable Driver tool call
   (exact tool name + all arguments) bound to an opaque string ID. `reserve`
   and `abstain` are always included as candidates.
3. The application sends Jev **only**: the goal (free text), a compact
   observation (page/outline/typed visual regions if present — never raw
   screenshot bytes), bounded history, and the candidate table as `{id:
   description}` pairs. Concretely, the wire schema
   (`examples/jev-use/fixtures/jev-choice-request-v1.json`, and the SDK call
   in `jev_adapter.py:31-39, 108-125`) is a TypeSafe `client.system_one()`
   call with `state={goal, observation}` and one `Choice` question whose
   `criteria` is the `{candidate_id: description}` map.
4. Jev returns **exactly one** selected candidate ID plus a confidence and a
   full probability distribution over the candidate set
   (`ProviderChoice` dataclass, `jev_adapter.py:14-19`) — never a tool name,
   never coordinates, never new arguments.
5. The application validates the returned ID against its own original,
   immutable candidate table — an unknown/duplicate/malformed ID is a hard
   error (`jev_adapter.py:41-49`).
6. Cua Driver executes **at most one** action (background delivery by
   default); the application re-observes and verifies against an
   independent oracle (in the reference example, a loopback HTTP `/state`
   endpoint on a fixture server) — never the action's own response or a
   screenshot.

### 3.3 Exactly what crosses the network, and what doesn't

Confirmed by reading both the wire fixture and the explicit prose in
`examples/jev-use/README.md:196-201`:

- **Sent to Jev:** goal string, `capture_id` (an opaque reference, not image
  bytes), typed/bounded region summaries (text + bounding box + confidence,
  when visual grounding is used), bounded history, and **at most 32**
  candidate IDs with short text descriptions.
- **Explicitly rejected/never sent, per the README's own words:** *"Tool
  names, action arguments, screenshot bytes, and environment data are
  rejected."*
- **Returned from Jev:** schema tag, the selected allowlisted ID, provider
  model identity (when available), confidence, and the probability vector.
  Nothing else — the chooser process never executes an action or verifies
  completion; that stays local.
- **Entirely local, never touching Jev:** capture/observation (Cua Driver),
  candidate construction, ID validation, action execution, and outcome
  verification. The recipe's own framing is explicit about this boundary:
  *"Keep the decision layer above Cua Driver... never let Jev invent tool
  names, coordinates, refs, targets, delivery modes, or other arguments."*

This is a genuinely narrow, well-designed interface — Jev is architecturally
reduced to "given a goal, a compact observation, and a closed candidate set
with descriptions, return one ID with a probability distribution," which
happens to be **exactly the interface CUA-S1's `PlanningBackend` Protocol
already implements locally** (§2.5) — same shape: bounded text context in,
one selected discrete option with a distribution out.

### 3.4 What breaks if you swap in a local model

Very little, and this is the strongest evidence in this whole investigation
for "the interface is clean enough to substitute":

- The `jev_adapter.py` module is the **only** file that imports the
  TypeSafe SDK (`from typesafe_sdk import ...`, `jev_adapter.py:29, 105,
  138`) — Driver observation, candidate construction, execution, and
  verification code (`core.py`, `choose_action.py`, `run.py`) never import
  it. Swapping the provider means writing one new adapter function with the
  same signature as `choose_with_typesafe`/`choose_live` — take
  `(candidates, snapshot, visual, history)`, return `(selected_id,
  confidence, probabilities)` — and pointing `run.py`'s provider selection
  at it instead. The example already demonstrates this pattern once, with
  `choose_mock_adapter` (`jev_adapter.py:144-150`), a fully deterministic
  local stand-in used for the credential-free test suite.
- CUA-S1's own `Planner`/`PlanningBackend` (§2.5) is structurally the same
  shape as this adapter contract; the main integration work is a
  serialization adapter — turning `jev-use`'s `{id: description}` candidate
  map into CUA-S1's `(context, options)` byte-encoded batch — not a
  redesign.
- What does **not** carry over automatically: Jev's `Choice`/`Score`/`Bool`
  question *types* (only `Choice` is exercised in this recipe) and whatever
  calibration TypeSafe applies internally (their RLCD method, mentioned but
  not detailed on the HF model card, §2.4) — a local replacement is
  responsible for its own calibration, which is exactly why the ECE metric
  in CUA-S1's training loop (§2.3) matters as the thing we'd need to hit a
  bar on before trusting the local model unsupervised.
- One thing to preserve deliberately, not accidentally lose: the recipe's
  hard boundary that the **decision-maker never sees tool names or raw
  arguments**, only descriptions — this is a real security/robustness
  property (a compromised or hallucinating decision model literally cannot
  emit an unbounded action) that's easy to erode by accident if a future
  local specialist is given richer input "for accuracy." Keep the
  candidate-ID indirection even when the decision-maker is fully local and
  fully trusted.

---

## 4. The critical view

### 4.1 Hacker News thread (`news.ycombinator.com/item?id=49767564`)

Read directly. **This thread does not contain a substantive technical
debate** — worth stating plainly rather than manufacturing a controversy
that isn't there. It is a short thread (8 comments) announcing CUA-S1 and
CUA-S1-FORMS (706K params, 2.8MB, framed via Kahneman's System 1). Content:

- One commenter asked about training methodology (RLCD vs. RLHF) —
  unanswered in the thread.
- One commenter raised a genuine architectural question worth carrying
  forward ourselves: whether explicit model *delegation* (a big model
  calling a small specialist) is the right shape long-term versus
  integrated approaches like mixture-of-experts with specialized
  sub-circuits inside one model — i.e. is a fleet of separately-trained tiny
  specialists the right end-state, or a stepping stone. No resolution in
  thread.
- One commenter asked about applicability to unrelated tasks (cookie-
  consent dismissal, chatbot construction) — off-topic, no technical
  content.
- **No response from anyone identifying as a trycua maintainer appears in
  the thread**, and no corrections to the announced numbers were posted.

The 99.7%-vs-83.6% and 7-9ms-vs-260-280ms figures already cited in
`SYSTEM-ONE.md` and `PRODUCT.md` trace to this same announcement (the
`706,048 parameters`/`2.8 MB` figures match exactly) — this HN thread is
most likely the same launch as the LinkedIn piece `SYSTEM-ONE.md` cites, not
independent confirmation of it. Treat the numbers as one vendor announcement
surfacing in two places, not two independent sources agreeing.

### 4.2 The arXiv paper — important correction to the investigation's premise

**`arxiv.org/pdf/2605.28775`, "Learn from Weaknesses: Automated Domain
Specialization for Small Computer-Use Agents" (Suji Kim, Kangsan Kim, Sung
Ju Hwang — KAIST/Samsung Electronics/DeepAuto.ai), is not about CUA-S1 and
does not establish anything about sub-million-parameter specialists.** I
downloaded the actual PDF, ran `pdftotext` on it, and grepped the full text:
**zero occurrences of "trycua", "cua-s1", "cua driver", "typesafe", or
"jev"** anywhere in the paper. This should be flagged clearly rather than
forced into relevance, since the investigation brief called it "directly
load-bearing."

What the paper actually establishes (read in full, quoting the PDF
directly):

- **"Small" here means 7-8 billion parameters**, not sub-1M. The method,
  LEARNWEAK, specializes **EvoCUA-8B** and **OpenCUA-7B** — open
  vision-language-model-based GUI agents — using **Qwen3.5-27B** (and
  comparisons to Claude Sonnet 4.6, Kimi K2.6) as *teacher* models. This is
  four to five orders of magnitude larger than CUA-S1-FORMS's 706,048
  parameters.
- **The method is architecturally unrelated to CUA-S1's approach.** LEARNWEAK
  is a two-stage pipeline: (1) `LEARNWEAK-GEN` — run a teacher and a student
  policy on the same seed tasks in a real executable environment, use an
  automatic verifier to find tasks where the teacher succeeds and the
  student fails, cluster/rerank screenshots via a VLM to pick informative
  states, then use a task-query generator to synthesize new tasks targeting
  those specific weaknesses (paper §3.1, eq. 6-10); (2) `LEARNWEAK-DPO` — a
  **step-level, error-aware DPO** objective (paper §3.2, eq. 11-16) that
  replays the teacher's trajectory context through the student, builds
  preference pairs only where their tool calls diverge, distinguishes
  *planning-level* vs. *execution-level* errors via a masking function, and
  fine-tunes with **LoRA adapters** on top of a frozen base student. None of
  this — teacher/student trajectory comparison in a live environment, VLM-
  based screenshot clustering, DPO, LoRA — resembles CUA-S1-FORMS's
  from-scratch cross-entropy training on a template-generated synthetic
  dataset. They solve different problems: LEARNWEAK specializes an
  already-capable large open VLM agent to a *new software domain* it's
  weak in (Gimp, VSCode, Calc, etc.), operating over full multi-step
  trajectories with `left_click(x,y)`/`type(text)`-style tool calls;
  CUA-S1-FORMS is a from-scratch tiny classifier over one bounded,
  single-step decision.
- **Headline results** (paper Table, `learnweak.txt` extraction): average
  gains of **+11.6 points on EvoCUA-8B** (50.69% → 62.24%) and **+11.1
  points on OpenCUA-7B** (37.65% → 48.72%) success rate, averaged across 8
  OSWorld domains (GIMP, VSCode, Calc, Impress, Thunderbird, and others),
  and the paper claims the specialized 8B student *surpasses* a 32B teacher
  on some individual domains (Gimp, Thunderbird, Impress — stated in text).
- **No explicit minimum-viable-size claim.** The paper does not state a
  parameter-count floor for a specialist; it demonstrates that *domain-
  specialized* fine-tuning of already-large (7-8B) open models with
  weakness-targeted synthetic data beats naive broad fine-tuning at a
  *matched data budget* — a genuinely useful general principle (targeted,
  failure-driven synthetic data beats generic scaling), but it offers no
  evidence, positive or negative, about whether that principle holds all
  the way down to a 706K-parameter byte-level scorer. Extrapolating "small
  models can be specialized effectively" from this paper down to "sub-1M-
  parameter models are viable" is not something the paper itself supports —
  it's a much larger leap in model size than the paper's own framing of
  "small" implies.

**What is genuinely load-bearing from this paper, stated honestly:** the
core *philosophy* — identify where the student actually fails via a real
teacher-student comparison, generate more data specifically targeting those
failures rather than generic broad data, and use error-type-aware training
signal — is a good template for how we'd design a data-generation loop for
Leonard's own specialists (e.g., mine hard cases from the audit store where
the resident general model and the nascent specialist disagree, rather than
just accumulating all accept/dismiss events uniformly). That transfers as a
*methodology idea*, not as evidence about model size, and not as anything
connected to Cua's codebase.

---

## 5. Build-versus-reuse verdict

**Answer to the governing question: yes.** Leonard can be built on Cua
Driver for actuation/observation plus locally-trained CUA-S1-style
specialists for bounded decisions, with no hosted model anywhere on the hot
path. Cua Driver's background-delivery and AX-tree mechanisms are real,
source-verified, and specifically designed to drive a live user desktop
without a VM — which is the hard requirement. CUA-S1-FORMS's architecture
is small, fully reproducible from source, and has a genuine Swift-native
(CoreML) inference path already demonstrated by a third party. What we
would have to build ourselves is concentrated in exactly the place
`PRODUCT.md` already identifies as the company: the personal, on-device
specialist-minting loop from real behavioral data, which nothing in either
project provides or has validated at Leonard's scale.

| Capability | Cua gives us | We adapt | We build from scratch | Why |
|---|---|---|---|---|
| Accessibility-tree reading (macOS) | **Yes** — `AXUIElement*` FFI + tree walker, real node schema (role/title/value/actions/frame/enabled/selected), depth/element caps, Chromium-enablement workaround | Tune depth/element caps and the markdown-render format for our own context budget; may want richer caching than the built-in `element_cache.rs` for our always-on daemon's long-lived sessions | — | §1.3 — this is the deepest, most mature part of Driver; reinventing `AXUIElementCopyAttributeValue`-level plumbing correctly (timeouts, Chromium lazy-tree, window/menu-bar disambiguation) would cost months we don't need to spend |
| Screen capture (fallback path) | **Yes** — rides along in `get_window_state`; ScreenCaptureKit-based, gated by a separate TCC grant | Decide our own policy for *when* to request it (Leonard's design already treats vision as fallback, not primary — matches Driver's own posture) | — | §1.3, §1.6 |
| Mouse/keyboard actuation without foreground steal | **Yes, with a real caveat** — `SLEventPostToPid`/window-local `CGEventSetWindowLocation`, explicit refusal ladder with stable error codes | Decide our own product-level promise to the user given the documented layer-3-only focus-guard and the native-AppKit "unproven" gaps in `action-support.md` — don't over-promise "never touches your frontmost app" without our own regression suite | Possibly: a stronger layer-1/2 focus-suppression (synthetic-focus write/restore) if the reactive-only guard proves insufficient for apps we specifically care about (Mail.app, Messages, Calendar) | §1.4 — the mechanism is real and non-trivial to build (private SkyLight SPI usage, the whole routing/refusal state machine); the gap is specifically in *completeness of proof* for native Cocoa apps, which we'd need to test against our actual target apps (Mail, Calendar) ourselves regardless of whose driver we use |
| App/window control (launch, list, focus-safe menu invocation, geometry) | **Yes** — `launch_app` (idempotent, `FocusRestoreGuard`), `list_apps/windows`, `invoke_menu` (native `AXMenuBar`), `set_window_frame` | Verify the Automation-permission question (§1.6) empirically for our own onboarding flow before promising "two permissions only" | — | §1.2, §1.6 |
| MCP/CLI/native transport | **Yes** — MCP stdio, CLI, and a real UniFFI/C-ABI native embedding path | Use the native embedding path (not MCP-over-pipe) for `leonardd`, since `CONTRACT.md` already establishes `leonardd` as a no-network-socket local daemon and MCP-over-stdio-subprocess is an unnecessary extra hop when a native binding exists | — | §1.5 |
| Candidate/action-space construction for a bounded decision | **Partially** — `jev-use`'s pattern (app builds the full candidate table, decision-maker only picks an ID) is a good, source-proven pattern; CUA-S1's `PlanningBackend` Protocol is the same shape | **Yes, adapt directly** — this is exactly the seam Leonard's typed-decision engine should sit behind; reuse the "decision-maker sees only IDs + descriptions, never tool names/arguments" boundary as a hard security property, not just a Jev-specific convenience | — | §3.4 |
| Specialist model architecture (byte-embed + tiny transformer + option-attention head) | **Yes** — `model.py`'s `TinyTransformerScorer`/`AttentionHead`, fully specified, 706,048 params reproducible, MIT source | **Yes, adapt** — the "fill" (entity-pointer) branch is forms-specific; Leonard's interrupt-decision is closer to the fixed-action branch (`check`/`click`/`skip` analogue), and context encoding needs a structured recent-event serialization, not free document text | Possibly a sequence-of-events context encoder (one token per event rather than pure byte stream) if the flat-text template proves insufficient for temporal signal | §2.1, §2.6 |
| Training loop / loss / calibration metrics | **Yes** — AdamW+cosine+warmup, cross-entropy, real ECE computation, abstention-aware metric suite (`evals/metrics.py`) directly matches what a confidence-gated interruption decision needs | Reuse largely as-is; add `unsafe_action_rate`-equivalent semantics tuned to "interrupted when shouldn't have" as the primary thing to bound | — | §2.3 |
| Synthetic training-data generator | **No, not transferable** — CUA-S1's generator is entirely forms-domain (concept catalog of address/insurance/medical/etc. fields); the *technique* (template-based, seeded, confusable-pair co-location, signature-disjoint splits) is reusable, the *content* is not | **Adapt the technique**, build the content ourselves | **Yes, from scratch** — Leonard's decision data isn't synthesizable the way form-field values are; it's a labeled record of one person's actual accept/dismiss behavior (per `PRODUCT.md`'s own framing), which is the explicitly-named unproven research risk | §2.2, §2.6 point 4 |
| Inference runtime for a Swift, no-Python daemon | **Partially** — a community (non-official) CoreML export already exists and works, proving the path is real | **Yes, adapt** — build our own export pipeline from our own retrained checkpoints (can't depend on a third-party community HF repo for a production dependency); the conversion notes (§2.5) tell us exactly what had to change for CoreML tracing | — | §2.5 |
| Personal specialist minting from the audit store (train a new specialist overnight from real local behavioral data) | **No** — nothing in either project does this; CUA-S1's whole recipe assumes synthetic, developer-generated training data produced once, offline, by the model's authors | — | **Yes, entirely from scratch** — this is `PRODUCT.md`'s stated moat ("Personal specialist minting from the audit store — Ours. This is the company.") and this investigation found nothing in Cua's codebase, TypeSafe's Jev, or the LEARNWEAK paper that does this for real end-user behavioral data on-device | §2.6 point 4, §4.2 |
| Hosted decision API (Jev or equivalent) | N/A | N/A | **Deliberately not used** — confirmed nothing in the jev-use recipe requires it be hosted; the interface it exposes is narrow enough that a local model can sit behind the identical boundary (§3.4) | Consistent with `ADR-004`, now with source-level confirmation that the substitution point is clean |

### Open items to close before committing further

1. **Empirically verify the Automation (Apple Events) permission question**
   (§1.6) against a fresh TCC database — the repo's own docs only claim
   Accessibility + Screen Recording, but `launch_app`'s AppleEvent usage
   makes this worth a five-minute real test before we build permissions UX
   around "just two grants."
2. **Run our own background-delivery proof against Mail.app, Calendar, and
   Messages specifically** — `action-support.md` itself says native AppKit
   press-key/hotkey/right-click/double-click delivery is "unproven," and
   those are exactly the apps in Leonard's MVP surface (`CONTRACT.md`).
   Don't inherit Cua's proof matrix by assumption; extend it to our actual
   target apps.
3. **Get the published `cua-s1-forms` checkpoint into safetensors ourselves**
   (or start from one of the community CoreML/ONNX conversions) rather than
   hitting the pickle-format bug in GH issue #3977 blind.
4. **Do not budget on the CUA-S1 synthetic-data-generation technique solving
   Leonard's data problem** — it solves a different, easier problem (closed
   synthesizable domain) than "learn one person's interruption preferences
   from sparse real behavior," which remains exactly the open research risk
   `PRODUCT.md` already names, unresolved by anything found in this
   investigation.
