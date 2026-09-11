# Steer

A native macOS companion for Codex desktop and Codex CLI in Ghostty. Keep using Codex normally; Steer shows activity and requests for attention in a compact notch while you work elsewhere.

## Status

Architecture and product decisions are documented. A read-only desktop capability probe runs; the macOS app is not implemented, and live desktop focus, navigation, and approval handoff remain unverified.

## MVP

- Local Codex desktop tasks and Codex CLI running directly in Ghostty, including tabs and split panes.
- One notch on the active display, with separate working and to-check counts and a prioritized queue.
- Approve once, deny, or return to Codex; unanswered requests hand back after 30 seconds from arrival.
- Three-second completion notifications, a short sound with mute, and acknowledgments preserved locally.
- Codex remains usable if Steer is unavailable. Unknown focus keeps notifications and leaves approvals in Codex.

## Project documents

- [Product behavior](docs/product.md)
- [Architecture draft](docs/architecture.md)
- [Domain glossary](CONTEXT.md)
- [Desktop investigation](docs/codex-desktop-investigation.md)
- [Backlog and dependency index](docs/mvp-backlog.md)
- [MVP implementation issues](https://github.com/r-curio/steer/issues?q=is%3Aissue+label%3Amvp)

## Run the existing probe

```sh
python3 scripts/probe_codex_desktop.py --self-test
python3 scripts/probe_codex_desktop.py --app /Applications/ChatGPT.app
```

The probe only inspects bundle metadata and generated protocol definitions. It does not install hooks, change settings, or connect to conversations. Pass the actual installed desktop bundle path when different.
