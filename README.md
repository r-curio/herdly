# Steer

A native macOS companion for Codex desktop and Codex CLI in Ghostty. Keep using Codex normally; Steer shows activity and requests for attention in a compact notch while you work elsewhere.

## Status

All MVP feature tickets are merged. A reproducible, checksummed development build is produced by `scripts/package-app.sh` and by CI; it is ad-hoc signed and labelled `unsigned-dev` until the maintainer signs and notarizes it with a Developer ID identity. The integrated live acceptance pass on the packaged app is still to be run by the operator; see [MVP acceptance](docs/mvp-acceptance.md) for what is proven and what is not.

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
- [Install, permissions, and removal](docs/install.md)
- [MVP acceptance record and operator checklist](docs/mvp-acceptance.md)
- [Backlog and dependency index](docs/mvp-backlog.md)
- [MVP implementation issues](https://github.com/r-curio/steer/issues?q=is%3Aissue+label%3Amvp)

## Install

Download the latest disk image from [Releases](https://github.com/r-curio/steer/releases), open it, and drag Steer to Applications. Releases marked pre-release are unsigned development builds and need **Open Anyway** in System Settings on first launch; [docs/install.md](docs/install.md) has the steps, permissions, and uninstall.

## Build from source

```sh
swift test
sh scripts/package-app.sh    # output/dist/Steer-<version>+<build>-<label>.zip, .sha256, manifest
```

`sh scripts/build-app.sh && open output/Steer.app` is the shorter development loop. Pushing a `v*` tag publishes a release with the same artifacts.

## Run the prototype controls

Click **Send test** in the Steer controls window, then switch away from Codex. The menu-bar shortcut is **S**; reopening the app restores its controls if the shortcut is hidden by a crowded menu bar. See the [prototype walkthrough and limitations](docs/prototype.md).

To replay desktop activity from an isolated event directory, use the [desktop integration runbook](docs/desktop-live-integration.md).

## Run the existing probe

```sh
python3 scripts/probe_codex_desktop.py --self-test
python3 scripts/probe_codex_desktop.py --app /Applications/ChatGPT.app
```

The probe only inspects bundle metadata and generated protocol definitions. It does not install hooks, change settings, or connect to conversations. Pass the actual installed desktop bundle path when different.
