# MVP acceptance — issue #13

Status: **packaging complete; live acceptance pass not yet run.** This page separates what has been proven by automated checks, what has been proven by earlier human walkthroughs on unpackaged builds, and what the operator still has to run against the packaged app before the MVP can be called verified. Nothing below is checked off on the strength of source inspection.

Install, permissions, supported versions and removal are in [install.md](install.md).

Launch-at-login installed checks are tracked separately in [launch-at-login evidence](evidence/launch-at-login.md) because they require changing the test account's Login Items state and signing out and back in.

## 1. Automated evidence (agent-run, 2026-09-14)

Recorded from a clean `main` checkout at the commit named in `docs/evidence/packaging-manifest.json`; that file is the manifest `scripts/package-app.sh` wrote, copied verbatim.

| Check | Result |
| --- | --- |
| `swift test` | 138 tests pass (host: macOS 26.5, Xcode 26.6, Swift 6.3.3). |
| `sh scripts/package-app.sh` (no identity) | Builds, lints `Info.plist`, `SteerHook --self-test` passes, ad-hoc signature verifies with `codesign --verify --deep --strict`, artifact `Steer-0.1.0+<build>-unsigned-dev.zip` written with `.sha256` and manifest. |
| Issue #88 candidate package (clean source commit `6b3664c`) | `Steer-0.1.0+175-unsigned-dev.zip`, SHA-256 `35826f78ea907926f0a52acc9169d2b4d2e4c6232d15cefe7563ecf7866e1f8f`; packaged smoke, helper self-test, checksum, and signature verification passed. Full record: [Claude release candidate package](evidence/claude-release-candidate-package.json). |
| Round trip of the artifact | Zip extracted to a scratch directory; `shasum -a 256 -c` OK; extracted bundle's signature verifies; extracted helper self-test passes. |
| Identity signing path | Run once with the only identity in the maintainer's keychain, `Apple Development: … (<team id>)`. Signs with hardened runtime and the Apple Events entitlement and labels the result `dev-signed`. This is not a Developer ID identity, so Gatekeeper still rejects it and it is not a release artifact. |
| Notarization | Not run: no Developer ID identity or notarytool profile is available. The script refuses to notarize with any other identity. |
| CI (`.github/workflows/macos.yml`, optional) | Not required for acceptance; local checks above are the gate. Runs test, package, `Steer --smoke-test` on the packaged app, prints the checksum, uploads the zip, checksum and manifest as the `Steer-unsigned-dev` artifact on a clean `macos-15` runner. First run on the packaging PR: [run 34806216904](https://github.com/r-curio/steer/actions/runs/34806216904), all steps green on macOS 15.7.9, artifact `Steer-0.1.0+94-unsigned-dev.zip` (built from the PR merge commit `1ed3034`), SHA-256 `a8e34afaec89f9524e22ade02678aaef847eff1b3f59c52166d45306c636e6d0`. |

Existing automated coverage that the packaged binary carries unchanged: desktop lifecycle replay, attention queue ordering, approval receipt binding and resolution, restart recovery from snapshot and hook records, notch placement geometry, user-input requests, thread names, desktop read state, and setup plan/undo (`Tests/SteerCoreTests`).

Isolated app-level labs recorded on earlier builds, each with its JSON under `docs/evidence/`: restart recovery (`restart_lab.py`, runs A–E), notch placement probe, CLI approval runtime and resolution, desktop turn start/complete replay, and a real desktop `request_user_input` recording.

## 2. Human evidence already on file (unpackaged builds)

These were reported by the user against `output/Steer.app` builds of earlier tickets, not against the zip above. They establish that the behaviours exist; the packaged-app pass in section 3 re-runs each of them once.

- Desktop foreground hides the notch, other apps restore it, repeated switching does not replay sound, dismissal survives restart ([prototype.md](prototype.md), "User-confirmed foreground walkthrough").
- `codex://threads/<id>` returns to the exact desktop task from another app; a nonexistent id does nothing ([desktop-manual-test.md](desktop-manual-test.md)).
- CLI session in an unsplit Ghostty tab: automatic session-id title, completion appears in Steer, exact tab/window navigation, direct-return acknowledgment ([cli-notch-integration.md](cli-notch-integration.md), "Final clean-run acceptance").
- Direct CLI approval: allow once, deny, 30-second handoff with the native prompt returning, and reconciliation of an answer given in Codex ([approval-reconciliation.md](approval-reconciliation.md), live evidence on CLI 0.145.0).

## 3. Operator pass against the packaged app

Run this on the artifact named in `docs/evidence/packaging-manifest.json` after checking its checksum. Use a disposable Codex task and a disposable CLI session; the agent must not drive the Codex UI, so every line is the operator's report. Record each line as **pass**, **fail**, or **uncertain** with the date, and attach the manifest's `sha256`. Leave a line blank rather than inferring it. Lines marked *deferred* are known MVP exclusions and are listed so they are not silently assumed.

### 3a. Install and connect

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| I1 | `shasum -a 256 -c` on the zip, unzip, move to `/Applications`, open. | Gatekeeper refuses an `unsigned-dev` build once; Open Anyway launches it as a menu-bar app showing its controls window. | |
| I2 | Before Configure Codex, copy `~/.codex/config.toml` and `~/.codex/hooks.json` aside. Click **Check Codex setup**. | Preview lists the versions from the requirements table as supported and shows every line it would add. | |
| I3 | **Configure Codex**. Diff both files against the copies. | Only the lines listed under "Connect Codex" in install.md were added; approval and sandbox settings unchanged. Helper present at `~/Library/Application Support/Steer/SteerHook`. | |
| I4 | Start a new `codex` session in Ghostty and answer Codex's trust prompt. | Steer shows connected; the session's row appears with a session-id title. | |
| I5 | Move `Steer.app` to a different folder while connected, relaunch. | Still connected; no repair required (helper placement does not depend on the bundle). | |

### 3b. Desktop workflow

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| D1 | With Codex desktop foreground, run a short turn in the disposable task. | Notch stays hidden; no sound. | |
| D2 | Switch to another app. | The completion card opens for three seconds with the sound, then collapses to the strip with a **1** badge. | |
| D3 | Return to Codex, leave again, twice. | Hidden while foreground; the item stays queued; sound does not replay. | |
| D4 | Hover the strip, click **Open in Codex**. | Codex comes forward on that task; the item stays queued (not acknowledged). | |
| D5 | Read the result in Codex, wait a few seconds, leave. With **Clear desktop completions Codex marks read** on: | The item clears from Codex's own unread flag. With it off: the item stays until Dismiss. | |
| D6 | **Dismiss** an item; quit and relaunch Steer. | Stays cleared. A new turn in the same task still notifies. | |
| D7 | *Deferred:* viewing thread B while A completes. | Notch hidden in either case; exact desktop task focus is not claimed. | n/a |
| D8 | Trigger an approval in the desktop task. | Codex's native prompt appears; Steer shows the request with only Open in Codex, never Approve/Deny (desktop approvals stay native). | |
| D9 | Have Codex ask a question (`request_user_input`) and leave the app. | "Codex needs an answer" card with the first question and numbered options; answer it in Codex and the item clears. | |

### 3c. Ghostty CLI workflow

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| G1 | Enable **Enable Ghostty controls**; macOS asks for Automation access to Ghostty; allow. | Steer reports the permission verified after the first navigation. | |
| G2 | Two unsplit tabs in the same project, one `codex` session each. Complete a turn in tab A while tab B is focused. | A's completion presents; B stays unaffected. | |
| G3 | **Open in Codex** on A's item. | Exactly tab A in its window is selected; the item is acknowledged by the verified visit. | |
| G4 | Split a tab and run a session in one pane. | Open in Codex reports unavailable; nothing selects an arbitrary pane. | |
| G5 | Trigger a permission request in the CLI session and leave the tab. | Card with command, project and reason (when given), Approve once, Deny, Open in Codex, and a 30-second countdown that hovering does not extend. | |
| G6 | Approve once. | Codex runs that one command; the next request asks again. | |
| G7 | Deny. | Codex reports the denial; nothing runs. | |
| G8 | Let one expire. | At 30 s the row becomes Continue in Codex with only Open in Codex; Codex's native prompt is showing; nothing was approved. | |
| G9 | Answer an expired one in Codex. | The row clears on Codex's recorded answer, not before. | |
| G10 | While a request is pending in the notch, force-quit Steer (`kill -9`). | Codex's native prompt appears within the helper's deadline; nothing approved. Relaunch: the request shows handed back with no buttons. | |

### 3d. Sound, mute, restart, displays

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| S1 | **Mute sound** in the menu, complete a turn while away. | Card opens silently; unmute and the next one sounds once. | |
| S2 | Quit Steer, complete a turn while it is quit, relaunch, leave Codex. | The completion returns marked as possibly already seen, silently, with Open in Codex and Dismiss. | |
| S3 | Kill Steer with `kill -9` after a completion queued, relaunch. | Same item returns silently; dismissals made before the kill are kept. | |
| M1–M7 | The seven lines of the operator walkthrough in [notch-placement.md](notch-placement.md): two displays, freeze during interaction, disconnect/reconnect, deadline independence, keyboard, VoiceOver, Spaces and full screen. | As written there. | |

### 3e. Remove

| # | Step | Expected | Result |
| --- | --- | --- | --- |
| R1 | **Undo setup**, then diff `config.toml` and `hooks.json` against the copies from I2. | Identical to the copies, or differing only in lines Codex itself rewrote since. Helper, events and backups gone. | |
| R2 | Quit Steer, delete the app, start a new `codex` session. | Codex runs normally with no hook errors; nothing references Steer. | |
| R3 | Delete `~/Library/Application Support/Steer` and the preferences plist. | Nothing else on the system changes. | |

## 4. What this does and does not establish

- The build and packaging route is reproducible and machine-checked; the artifact carries a checksum and a manifest naming the commit and toolchain. Reproducible means the same steps and version from the same commit, not byte-identical binaries: two local builds of unchanged app sources produced different `Contents/MacOS/Steer` hashes while the helper's hash matched, so a checksum identifies one artifact rather than the commit.
- The artifact is an ad-hoc signed development build. A signed or notarized release needs the maintainer's Developer ID identity and has not been produced.
- Desktop session detection, approval handoff, Ghostty navigation, and restart recovery each have earlier live human evidence on unpackaged builds and automated evidence in the tests and labs, but the integrated pass in section 3 has **not** been run on the packaged app. Until every non-deferred line there is recorded as pass, the MVP is packaged, not verified.
- Exact desktop task focus (D7) and split-pane targeting (G4 as unavailable) remain deferred by decision, not by omission.
