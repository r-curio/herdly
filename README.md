# Steer

A native macOS companion for Codex desktop and Codex CLI in Ghostty. Keep using Codex normally; Steer shows activity and requests for attention in a compact notch while you work elsewhere.

## Status

Architecture and product decisions are documented. A read-only desktop capability probe runs; the macOS app is not implemented. Task-link navigation has been manually verified. Desktop app-level visibility and approval handoff still need live implementation proof.

## MVP

Desktop MVP visibility: hide the notch while Codex is foreground and show eligible activity while away. Desktop completions remain queued until explicitly dismissed; exact-task focus is deferred.

- Local Codex desktop tasks and Codex CLI running directly in Ghostty, including tabs and split panes.
- One notch on the active display, with separate working and to-check counts and a prioritized queue.
- Direct approvals are separately gated by integration proof; until then, desktop approvals stay native. The planned notch flow offers approve once, deny, or return, with a 30-second handoff.
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

