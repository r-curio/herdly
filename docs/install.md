# Install, permissions, and removal

Status: the packaging route below is reproducible from a clean checkout and is checked on every CI run. Whether the packaged app passes the integrated live workflow is recorded separately in [MVP acceptance](mvp-acceptance.md); nothing here claims that pass.

## Requirements

| Component | Tested with | Minimum Steer accepts |
| --- | --- | --- |
| macOS | 26.5 (build host), 15 (CI runner, `macos-15`) | 14.0 (`LSMinimumSystemVersion`) |
| Toolchain | Xcode 26.6, Swift 6.3.3 | Swift 6.0 tools (`Package.swift`) |
| Codex desktop | 26.901.51231 (`/Applications/ChatGPT.app`, bundle `com.openai.codex`) | 26.901.51231 |
| Codex CLI | 0.145.0 (shell), 0.153.4 (bundled in desktop) | 0.145.0 |
| Ghostty | 1.3.1 | 1.3.1 |

The minimums are the versions the integrations were proven against; Steer's setup preview reports an older install as unsupported rather than guessing. Newer versions are untested until recorded in a later evidence pass. Steer runs only against Codex sessions on the local Mac; remote sessions and terminals other than Ghostty are out of scope.

## Build from a clean checkout

```sh
git clone https://github.com/r-curio/steer.git
cd steer
swift test
sh scripts/package-app.sh
```

`package-app.sh` builds `output/Steer.app` with `scripts/build-app.sh`, lints its property list, runs the bundled helper's self-test, signs it, verifies the signature, then writes three files to `output/dist/`:

- `Steer-<version>+<build>-<label>.zip`, the app bundle;
- `Steer-<version>+<build>-<label>.zip.sha256`, its checksum, checkable with `shasum -a 256 -c`;
- `Steer-<version>+<build>-<label>.manifest.json`, the commit, toolchain, host macOS, signing mode, Gatekeeper result, and per-executable hashes.

The build number is the commit count on the checked-out branch, so two people building the same commit get the same bundle version. The CI workflow ([.github/workflows/macos.yml](../.github/workflows/macos.yml)) runs the same script on a clean `macos-15` runner, smoke-tests the packaged app, prints the checksum, and uploads the zip, checksum and manifest as the `Steer-unsigned-dev` artifact.

### Labels

The artifact name says what the signature is; the script never labels a build as more than it verified.

| Label | Meaning | Who can open it |
| --- | --- | --- |
| `unsigned-dev` | Ad-hoc signature, no identity. This is what CI and a plain `sh scripts/package-app.sh` produce. | The machine that built it, or any Mac after the Gatekeeper override below. Not for distribution. |
| `dev-signed` | Signed with a non-Developer ID identity (for example `Apple Development: …`). Hardened runtime and the Apple Events entitlement are applied. | Same as above. Confirms the signing path, not a release. |
| `signed` | Signed with `Developer ID Application: …`, hardened runtime, timestamped, not notarized. | Other Macs after a Gatekeeper warning. |
| `notarized` | Developer ID signature plus an accepted notarytool submission, stapled. | Other Macs without a warning. |

To sign with the maintainer's identity:

```sh
STEER_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" sh scripts/package-app.sh
```

To notarize as well, store an App Store Connect API key or Apple ID once with `xcrun notarytool store-credentials <profile>` and pass it:

```sh
STEER_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" STEER_NOTARY_PROFILE=<profile> sh scripts/package-app.sh
```

The script refuses to notarize with anything other than a Developer ID Application identity and fails, rather than relabels, when the submission is not accepted. No Developer ID identity was available to the agent that wrote this route, so no signed or notarized artifact has been produced yet; the recorded artifacts in [MVP acceptance](mvp-acceptance.md) are `unsigned-dev` and `dev-signed`.

## Install

1. Check the checksum: `shasum -a 256 -c Steer-<version>+<build>-<label>.zip.sha256`.
2. Unzip and move `Steer.app` to `/Applications` or `~/Applications`. Steer does not install itself or add a login item unless you explicitly turn on **Launch at login**. Connect Codex copies the helper out of the bundle (see below), so moving or replacing the app later does not break an existing Codex connection. macOS owns login-item registration separately; after moving or replacing the app, open Steer's General settings and check the status macOS reports.
3. For an `unsigned-dev` or `dev-signed` build, the first open is refused by Gatekeeper. Open **System Settings › Privacy & Security**, scroll to the message about Steer, and choose **Open Anyway**, or run `xattr -d com.apple.quarantine /Applications/Steer.app` and open it again. A `notarized` build opens directly.
4. Steer launches as a menu-bar app (**S**) with no Dock icon, and shows its controls window because no setup exists yet.

### Launch at login

**Launch at login** is off by default. Turn it on in Steer's **General › Startup** settings if you want macOS to open Steer when you sign in. The displayed status comes directly from macOS rather than from a saved Steer preference.

If the setting says **Approval required**, choose **Open Login Items** and allow Steer under **System Settings › General › Login Items & Extensions**. If it says **Unavailable** after the app was moved or replaced, use the same System Settings panel to remove any stale entry, then reopen Steer and opt in again. Steer never repairs or recreates a login item without your action.

### Connect Codex

Connecting is explicit and previewed. In the controls window, review the setup preview, then click **Configure Codex**. Steer then:

- copies `Contents/Helpers/SteerHook` from the bundle to `~/Library/Application Support/Steer/SteerHook` (mode 755) after running its self-test, and records the install in `~/Library/Application Support/Steer/install.json`;
- adds to `~/.codex/hooks.json` one command hook per event for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop` and `SessionEnd`, each running that helper with `--events-dir ~/Library/Application Support/Steer/events --installation-id <uuid>`;
- adds to `~/.codex/config.toml` exactly three kinds of line: `hooks = true` under `[features]`, `terminal_title = ["session-id"]` under `[tui]`, and one `trusted_hash = "sha256:…"` per installed handler under `[hooks.state."<hooks.json path>:<event>:<group>:<handler>"]`;
- backs up the original `config.toml`, `hooks.json` and any previous helper under `~/Library/Application Support/Steer/backups/<uuid>/`.

Nothing else in `~/.codex` is touched: approval policy, sandbox settings, model, profiles and every other table stay as they were, and the preview shows every line before it is written. If Codex already has hooks disabled, a different `tui.terminal_title`, or a second Steer install, Steer reports a conflict and writes nothing.

Codex loads hooks when a session starts, so sessions already running keep their old settings until restarted. Codex also asks once whether to trust the new hooks; Steer records the trust entries, and a hook that Codex reports as changed shows in Steer as **repair required** rather than being silently re-trusted.

Codex keeps working if Steer is quit or crashes. Every hook either records metadata or, for `PermissionRequest`, waits at most its bounded deadline and returns no decision, after which Codex shows its own prompt. No companion process is required for normal Codex use.

### Connect Claude Code

Claude is configured separately in **Agents → Claude Code**. Steer previews the default `~/.claude` root first; use **Add alternate Claude root** for a manually selected `CLAUDE_CONFIG_DIR` root. Each root has its own helper, events, install record, installation identity, and undo path. See [Claude setup](claude-setup.md) for ownership and state details.

Configure Claude adds only Steer's exact hook entries and `env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` to that root's `settings.json`, then installs the packaged helper under Steer's Application Support directory. The `SessionStart` entry emits the full-session-ID Ghostty title through Claude's JSON `terminalSequence`, and `SessionEnd` requests a reset. Existing Claude sessions are not restarted; Steer reports **Configured; restart required** until a newly started session sends a root-matching event. Ghostty Automation readiness remains separate from this connection state.

The optional Claude usage bridge is displayed in the same preview and starts off. This setup slice does not change an existing `statusLine`; usage composition is independently reversible and belongs to the later usage slice. Known managed policy, malformed files, duplicate installs, and changed owned values are reported without writing. The setup snapshot has no project context and cannot resolve arbitrary project or command-line `--settings` precedence, so the preview names that limit and connection still requires a fresh exact-root SessionStart. Clean SessionEnd title reset is covered by the helper route; abrupt-exit restoration remains an unproven operator limitation without a launcher.

## Permissions macOS may ask for

| Prompt | When | If declined |
| --- | --- | --- |
| **"Steer" wants access to control "Ghostty"** (Automation) | The first time Ghostty controls are enabled in Steer and it selects a tab through `osascript`. The usage string is in the bundle's `NSAppleEventsUsageDescription`. | Open in Codex for CLI sessions reports that it cannot read Ghostty's tabs; everything else works. Re-enable under **System Settings › Privacy & Security › Automation › Steer**. |
| Gatekeeper "cannot be opened" | First launch of an `unsigned-dev`, `dev-signed`, or `signed` build. | See step 3 above. |
| Codex's own hook-trust prompt | The first Codex session after Configure Codex. This is Codex's prompt, not macOS's. | Codex ignores the untrusted hooks; Steer shows repair required. |

Steer does not request Accessibility, Screen Recording, Input Monitoring, notifications, or Full Disk Access, and does not read the Codex desktop app's window contents. Desktop visibility comes from `NSWorkspace` app-activation notifications, desktop read state from `~/.codex/.codex-global-state.json`, thread names from `~/.codex/session_index.jsonl`, and turn state from `~/.codex/sessions` rollouts and the hook records above.

## What Steer stores

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/Steer/SteerHook` | The installed helper (a copy of the bundle's). |
| `~/Library/Application Support/Steer/install.json` | What Configure Codex wrote, so undo can remove exactly that. |
| `~/Library/Application Support/Steer/events/` | Metadata-only hook records, approval receipts and decisions. |
| `~/Library/Application Support/Steer/backups/` | Originals of files Steer changed. |
| `~/Library/Application Support/Steer/attention-snapshot.json` (and `.previous`) | Undismissed completions and dismissal identities. |
| `~/Library/Preferences/dev.rcurio.steer.prototype.plist` | Mute, the events-folder choice, the desktop read-state toggle, the last controls section, and the prototype's test item. Launch-at-login state is not stored here. |

No conversation text or transcripts are stored. Fresh notification spotlights may read bounded prompt and final-response excerpts into process memory; those excerpts disappear when Steer quits and are excluded from the attention snapshot.

## Uninstall

1. In Steer's General settings, turn off **Launch at login**. This unregisters only Steer's main-app login item. If the control is unavailable, open **System Settings › General › Login Items & Extensions** and remove Steer there.
2. In Steer's controls window, click **Undo setup**. Steer removes exactly the hooks and config lines it added, restores the original files byte for byte when they are unchanged since install, deletes its helper, its own event records and its backups, and leaves everything else in `~/.codex` alone. Skip this step if Steer was never connected.
3. Quit Steer from its menu.
4. Delete `Steer.app`.
5. Optionally remove the remaining local state: `~/Library/Application Support/Steer` (the snapshot of dismissals) and `~/Library/Preferences/dev.rcurio.steer.prototype.plist`. Neither affects Codex or controls the login item.

Uninstalling in this order leaves Codex exactly as it was before Connect and removes Steer's login-item registration. Deleting the app first is safe for Codex too: the hooks then point at a helper that still exists in Application Support, or, if that was also deleted, at a missing command, and Codex reports a failed hook without blocking; but the config lines remain until removed by hand as below. A stale Steer entry can also remain in Login Items until you remove it in System Settings.

### Recovery when Undo setup is unavailable

If Steer cannot run, `install.json` is gone, or Undo setup reports a conflict, the additions are all visible and removable by hand. Quit Codex sessions first, keep a copy of both files, then:

1. In `~/.codex/hooks.json`, remove every command entry whose `command` contains `Application Support/Steer/SteerHook`. Leave hooks from anything else in place.
2. In `~/.codex/config.toml`, remove each `[hooks.state."…"]` table whose key names one of the hooks removed above, the `terminal_title = ["session-id"]` line under `[tui]` if it was Steer's (an empty `[tui]` table can go too), and `hooks = true` under `[features]` only if nothing else needs hooks.
3. The originals Steer saved are under `~/Library/Application Support/Steer/backups/<uuid>/` as `config.toml` and `hooks.json`; copying them back is only correct if Codex has not rewritten those files since Connect, which Codex desktop does on its own, so prefer removing the lines.
4. Delete `~/Library/Application Support/Steer`.

Steer's status check reads these same files, so a reinstall afterwards starts from a clean preview.

## Known limitations

- Exact desktop task focus is deferred: the notch hides whenever Codex desktop is foreground, even while a different thread is visible, and a desktop completion clears only on Dismiss or on Codex's own unread flag clearing.
- Desktop approvals stay in Codex's native prompt; only direct CLI approvals offer Approve once and Deny, with a 30-second handoff.
- Ghostty targeting covers one Codex session per unsplit tab with session-ID titles; split tabs report unavailable.
- There is no global hotkey; keyboard users click the panel once, then Tab and Escape work.
- Hook records and rollouts are scanned fully every two seconds with fixed size caps; very large histories are a known, deferred cost.
- The bundle identifier is still `dev.rcurio.steer.prototype`; changing it would orphan the preferences above.
