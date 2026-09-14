# Steer

A native macOS companion for Codex desktop and Codex CLI in Ghostty. Keep using Codex normally; Steer shows activity and requests for attention in a compact notch while you work elsewhere.

## Status

Architecture and product decisions are documented. The native app replays metadata-only desktop lifecycle records from the isolated hook lab, while preserving Codex's normal runtime. Task-link navigation has been manually verified; attachment to a fresh existing desktop task still requires the permitted human check.

## MVP

Desktop MVP visibility: hide the notch while Codex is foreground and show eligible activity while away. Desktop completions remain queued until explicitly dismissed; exact-task focus is deferred.

- Local Codex desktop tasks and Codex CLI running directly in Ghostty, with exact unsplit tab targeting; split panes remain unavailable.
- One notch on the active display, fused under the camera housing: a sprite per session that steps while Codex works, a to-check badge, Codex's weekly usage limit, and a prioritized queue on hover.
- Direct CLI approvals use one receipt-bound allow-once or deny decision with a 30-second handoff; desktop approvals stay native until their transport and handoff policy are proven.
- Three-second completion notifications, a short sound with mute, and acknowledgments preserved locally.
- Codex remains usable if Steer is unavailable. Unknown focus keeps notifications and leaves approvals in Codex.

## Project documents

- [Product behavior](docs/product.md)
- [Architecture draft](docs/architecture.md)
- [Domain glossary](CONTEXT.md)
- [Desktop investigation](docs/codex-desktop-investigation.md)
- [User-input requests](docs/user-input-requests.md)
- [Backlog and dependency index](docs/mvp-backlog.md)
- [MVP implementation issues](https://github.com/r-curio/steer/issues?q=is%3Aissue+label%3Amvp)

## Run the prototype

```sh
swift test
sh scripts/build-app.sh
open output/Steer.app
```

Click **Send test** in the Steer controls window, then switch away from Codex. The menu-bar shortcut is **S**; reopening the app restores its controls if the shortcut is hidden by a crowded menu bar. See the [prototype walkthrough and limitations](docs/prototype.md).

To replay desktop activity from an isolated event directory, use the [desktop integration runbook](docs/desktop-live-integration.md).

## Run the existing probe

```sh
python3 scripts/probe_codex_desktop.py --self-test
python3 scripts/probe_codex_desktop.py --app /Applications/ChatGPT.app
```

The probe only inspects bundle metadata and generated protocol definitions. It does not install hooks, change settings, or connect to conversations. Pass the actual installed desktop bundle path when different.
