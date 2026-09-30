# Bobb

A personal assistant for your Mac. Named assistants, connected apps, persistent work and boundaries you control. Local AI by default; an optional cloud brain uses your own key and redacts requests on the Mac.

Bobb uses `BobbApp` and `BobbCore` for the Swift app and `bobbd` for its Python daemon. App data lives in `~/Library/Application Support/Bobb`.

## What you can do

- Create multiple Bobbs with a name, character and development, secretary or general profile.
- Connect apps and websites explicitly. Set navigate, write, send, pay, delete, publish, settings and execute to allow, ask or never; add constraints in your words and working hours.
- Run desktop tasks through Accessibility, with keyboard, cursor and revalidated screen-text targets. Secure fields and protected apps stay blocked. Visual targets always require confirmation.
- Give each Bobb an isolated, persistent local WebKit browser. Inspect it and sign in yourself when needed.
- Create projects with reviewed subtasks and saved reports. Schedule standing assignments once, daily, weekly or on an observed event. Failed or interrupted actions require an explicit retry.
- Review routine suggestions based on repeated completed tasks, then choose whether to create an assignment.
- Ask from an iPhone through your iMessage self chat and optionally hear spoken answers.
- Choose a local MLX checkpoint, with RAM guidance, or configure an HTTPS chat-completions API and a Keychain-held key. Inspect the exact redacted cloud request log.
- Configure optional stdio MCP servers or install an experimental macOS VM and connect its Bobb endpoint through a dedicated SSH identity.

The UI uses native Liquid Glass on macOS 26 with the macOS 26 SDK, and system vibrancy on earlier versions. Reduced transparency is respected. The black glasses mark looks up and left.

## Build and run

Apple silicon, macOS 14+, Swift 6, Python 3.12 and uv. Xcode 26 is recommended for the native Liquid Glass implementation.

```sh
scripts/run.sh
```

This creates `dist/Bobb.app` and uses the checkout's daemon. `scripts/package.sh` creates the self-contained app and DMG. `--release` requires your Apple signing and notarization credentials. GitHub Actions builds and tests the app, daemon, specialist, tools and complete DMG.

Connect apps in **Bobb → Boundaries**, enable acting, then create work. Background work also requires its own switch and an awake, signed-in Mac. Onboarding offers the pinned 3B checkpoint; larger checkpoints are selected from a local directory. Model weights carry their own licenses.

## Privacy and limits

The daemon has no network access. Browser traffic, explicit MCP servers, optional VM networking and opt-in cloud are separate capabilities. API keys stay in Keychain. Cloud redaction recognizes patterns, names and configured private terms; it cannot recognize every sensitive fact. Never assume a redacted request is anonymous.

Desktop work yields when you return and holds one shared screen lease. Browsers can work concurrently across Bobbs. Browser challenges, secret fields, unsupported controls and guest actions that require approval need human intervention. No automatic replay of uncertain side effects. Local 3B capability remains limited; larger models and cloud do not guarantee success.

[iMessage, VM and full capability guide](docs/BOBB.md) · [Architecture](docs/ADR-009-bobb-work-and-boundaries.md) · [Contributing](CONTRIBUTING.md)

## Tests

```sh
cd BobbApp
swift test -j 1
# from the repository root:
cd bobbd
uv sync --frozen
uv run pytest -q -m "not slow"
```

Linux daemon tests additionally need the matching `mlx[cpu]` build; CI configures it. Integration with real accounts, API providers, large checkpoints and a macOS guest needs on-device testing.

## License

MIT. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md). License tools remain available; Bobb has no paid activation gate.
