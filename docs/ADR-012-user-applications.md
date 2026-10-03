# ADR-012: Use the user's actual applications

The user's request is to keep Kev and operate the same apps and browser session they normally use. Production command-bar tasks and scheduled browser assignments now use `UserBrowserComputer`, backed by native Accessibility and the CUA native fallback. The isolated CUA Chromium and WebKit adapters remain explicit developer fixtures only.

Browser candidates come from macOS URL handlers. A browser named in the goal wins, otherwise the browser active when the command bar opened, otherwise the macOS default. The normal `NSWorkspace` URL-opening API reuses the app with `createsNewApplicationInstance = false`. No debugging port, custom data directory, copied cookies or separate sign-in is involved. The browser controls which profile receives external links; multiple logged-in profiles are not independently selected by Bobb.

Other apps are discovered from installed and running applications. Opening an app prefers its existing running instance and otherwise launches the regular installed app. Task cleanup closes Bobb's driver session, leaving the real app and its tabs open.

Both browser and desktop work require Accessibility and the same physical screen lease. The scheduler serializes these surfaces, including across assistants; background work yields to user input. Browser observations attest the focused window's web-area URL and apply both app and website boundaries. Changed apps, windows or unexpected tab URLs stop execution rather than rebinding silently. Initial navigation accepts the requested URL or a changed same-host redirect; cross-host startup redirects may need user intervention. There is no universal browser-tab identity guarantee for two tabs showing the same URL.

Chrome's [remote-debugging restrictions](https://developer.chrome.com/blog/remote-debugging-port) require a nonstandard data directory when using the debugging switches with current Chrome. Native controls allow reuse of the ordinary session without relying on that development route.

Model defaults remain Qwen3.5 4B 4-bit and Kev 4B 8-bit. This change does not increase the model footprint or establish performance on a 16 GB Mac.

## Validation on 2026-10-01

- 147 Swift tests pass, including active/default/explicit browser selection, combined app/site boundaries, Return submission policy and TaskLoop refusal before a prohibited site write.
- All 27 workspace tests pass, including browser/desktop serialization and user-presence gating.
- The rebuilt, ad-hoc signed development bundle passes signature verification, starts only the menu bar icon and answers a synthetic rewrite through the local Qwen/Kev daemon.
- The real-browser check selects `/Applications/Google Chrome.app`, reuses its already-running process and leaves it running after cleanup. It creates no test profile.
- macOS reports Accessibility as **not granted** to this build. The check therefore only focuses the real Chrome instance; typing, clicking and reading the synthetic localhost result are **not verified** in the personal session. The isolated CUA test in ADR-011 is not evidence for that new route. On-device native automation still needs a valid Accessibility grant.
