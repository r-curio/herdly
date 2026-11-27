<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/herdly-wordmark-white.svg">
    <img src="docs/brand/herdly-wordmark.svg" alt="Herdly" height="56">
  </picture>
</h1>

A native macOS companion for local Codex and Claude Code sessions. Keep using your agents normally; Herdly shows activity and requests for attention in a compact notch while you work elsewhere.

## Status

All MVP feature tickets are merged. A reproducible, checksummed development build is produced by `scripts/package-app.sh` and by CI; it is ad-hoc signed and labelled `unsigned-dev` until the maintainer signs and notarizes it with a Developer ID identity. The integrated live acceptance pass on the packaged app is still to be run by the operator; see [MVP acceptance](docs/mvp-acceptance.md) for what is proven and what is not.

## What it covers

The notch stays visible in every app, including Codex itself. Desktop completions stay queued until dismissed or until Codex records them read; exact Codex desktop conversation focus is deferred.

- **Agents:** the Codex desktop app, Codex CLI, Claude Code in a terminal, and Claude Code sessions in Claude Desktop's Code tab, all local. Each agent has its own switch and reversible setup in Settings › Agents.
- **Terminals:** Ghostty, iTerm2, Terminal.app and WezTerm tabs, Rex blocks, Herdr app terminals, and tmux, Zellij and herdr panes running inside them, each switched on in Settings › Terminals. Open returns to the exact tab or pane; when it can't be reached exactly (a split, colliding titles), Open raises the terminal app instead and never picks an arbitrary tab.
- **Notch:** one notch on the active display, fused under the camera housing: a sprite per session that steps while it works, a to-check badge, each agent's usage limits (five-hour, weekly, both or neither, chosen per agent in Settings › General › Usage), and a prioritized queue on hover.
- **Approvals:** Codex CLI and Claude Code approvals use one receipt-bound allow-once or deny decision with a 30-second handoff and never decide on their own; Codex desktop approvals stay native until their transport and handoff policy are proven.
- **Questions:** answer Codex and Claude questions from the notch through a supported route, with a fresh check that the question is still pending.
- **Completions:** short completion notifications, a sound with mute, and acknowledgments preserved locally.
- **Fail-safe:** every agent remains usable if Herdly is unavailable. Unknown focus keeps notifications and leaves approvals in the agent.

## Project documents

- [Product behavior](docs/product.md)
- [Architecture draft](docs/architecture.md)
- [Domain glossary](CONTEXT.md)
- [Desktop investigation](docs/codex-desktop-investigation.md)
- [User-input requests](docs/user-input-requests.md)
- [Install, permissions, and removal](docs/install.md)
- [MVP acceptance record and operator checklist](docs/mvp-acceptance.md)
- [Backlog and dependency index](docs/mvp-backlog.md)
- [MVP implementation issues](https://github.com/r-curio/herdly/issues?q=is%3Aissue+label%3Amvp)

## Build and install

```sh
swift test
sh scripts/package-app.sh    # output/dist/Herdly-<version>+<build>-<label>.zip, .sha256, manifest
```

`sh scripts/build-app.sh && open output/Herdly.app` is the shorter development loop. Installation, the permissions macOS asks for, supported versions, and a clean uninstall are in [docs/install.md](docs/install.md).

## Replay desktop activity

To replay desktop activity from an isolated event directory, use the [desktop integration runbook](docs/desktop-live-integration.md).

## Run the existing probe

```sh
python3 scripts/probe_codex_desktop.py --self-test
python3 scripts/probe_codex_desktop.py --app /Applications/ChatGPT.app
```

The probe only inspects bundle metadata and generated protocol definitions. It does not install hooks, change settings, or connect to conversations. Pass the actual installed desktop bundle path when different.

## Contributing and license

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md) and report security issues as described in [SECURITY.md](SECURITY.md). Herdly is released under the [MIT License](LICENSE).

Herdly is an independent project and is not affiliated with or endorsed by OpenAI or Anthropic. Codex, ChatGPT, and Claude are trademarks of their respective owners.
