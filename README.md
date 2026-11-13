# Herdly

A native macOS companion for Codex desktop and Codex CLI in Ghostty. Keep using Codex normally; Herdly shows activity and requests for attention in a compact notch while you work elsewhere.

## Status

All MVP feature tickets are merged. A reproducible, checksummed development build is produced by `scripts/package-app.sh` and by CI; it is ad-hoc signed and labelled `unsigned-dev` until the maintainer signs and notarizes it with a Developer ID identity. The integrated live acceptance pass on the packaged app is still to be run by the operator; see [MVP acceptance](docs/mvp-acceptance.md) for what is proven and what is not.

## MVP

Desktop MVP visibility: hide the notch while Codex is foreground and show eligible activity while away. Desktop completions remain queued until explicitly dismissed; exact-task focus is deferred.

- Local Codex desktop tasks and Codex CLI running directly in Ghostty, with exact unsplit tab targeting; when the exact tab can't be reached (a split, colliding titles), Open raises the terminal app instead.
- One notch on the active display, fused under the camera housing: a sprite per session that steps while Codex works, a to-check badge, Codex's weekly usage limit (and its five-hour one when Codex reports it), and a prioritized queue on hover.
- Direct CLI approvals use one receipt-bound allow-once or deny decision with a 30-second handoff; desktop approvals stay native until their transport and handoff policy are proven.
- Three-second completion notifications, a short sound with mute, and acknowledgments preserved locally.
- Codex remains usable if Herdly is unavailable. Unknown focus keeps notifications and leaves approvals in Codex.

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

## Run the prototype controls

Click **Send test** in the Herdly controls window, then switch away from Codex. The menu-bar shortcut is **S**; reopening the app restores its controls if the shortcut is hidden by a crowded menu bar. See the [prototype walkthrough and limitations](docs/prototype.md).

To replay desktop activity from an isolated event directory, use the [desktop integration runbook](docs/desktop-live-integration.md).

## Run the existing probe

```sh
python3 scripts/probe_codex_desktop.py --self-test
python3 scripts/probe_codex_desktop.py --app /Applications/ChatGPT.app
```

The probe only inspects bundle metadata and generated protocol definitions. It does not install hooks, change settings, or connect to conversations. Pass the actual installed desktop bundle path when different.

## License

Herdly is free software, released under the [GNU General Public License v3.0](LICENSE).
