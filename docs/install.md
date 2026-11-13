# Install, permissions, and removal

Status: the packaging route below is reproducible from a clean checkout and is checked on every CI run. Whether the packaged app passes the integrated live workflow is recorded separately in [MVP acceptance](mvp-acceptance.md); nothing here claims that pass.

## Requirements

| Component | Tested with | Minimum Herdly accepts |
| --- | --- | --- |
| macOS | 26.5 (build host), 15 (CI runner, `macos-15`) | 14.0 (`LSMinimumSystemVersion`) |
| Toolchain | Xcode 26.6, Swift 6.3.3 | Swift 6.0 tools (`Package.swift`) |
| Codex desktop | 26.901.51231 (`/Applications/ChatGPT.app`, bundle `com.openai.codex`) | 26.901.51231 |
| Codex CLI | 0.145.0 (shell), 0.153.4 (bundled in desktop) | 0.145.0 |
| Ghostty | 1.3.1 | 1.3.1 |

The minimums are the versions the integrations were proven against; Herdly's setup preview reports an older install as unsupported rather than guessing. Newer versions are untested until recorded in a later evidence pass. Herdly runs only against Codex sessions on the local Mac; remote sessions and terminals other than Ghostty are out of scope.

## Build from a clean checkout

```sh
git clone https://github.com/r-curio/herdly.git
cd herdly
swift test
sh scripts/package-app.sh
```

`package-app.sh` builds `output/Herdly.app` with `scripts/build-app.sh`, lints its property list, runs the bundled helper's self-test, signs it, verifies the signature, then writes three files to `output/dist/`:

- `Herdly-<version>+<build>-<label>.zip`, the app bundle;
- `Herdly-<version>+<build>-<label>.zip.sha256`, its checksum, checkable with `shasum -a 256 -c`;
- `Herdly-<version>+<build>-<label>.manifest.json`, the commit, toolchain, host macOS, signing mode, Gatekeeper result, and per-executable hashes.

The build number is the commit count on the checked-out branch, so two people building the same commit get the same bundle version. The CI workflow ([.github/workflows/macos.yml](../.github/workflows/macos.yml)) runs the same script on a clean `macos-15` runner, smoke-tests the packaged app, prints the checksum, and uploads the zip, checksum and manifest as the `Herdly-unsigned-dev` artifact. CI is optional; a local clean-checkout package with its smoke check, helper self-test and checksum is the required evidence.

The [mixed-source package record](evidence/claude-release-candidate-package.json)
lists the automated checks and exact artifact. Integrated live behavior has not
been checked on that artifact; use can proceed without a scripted walkthrough.

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
HERDLY_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" sh scripts/package-app.sh
```

To notarize as well, store an App Store Connect API key or Apple ID once with `xcrun notarytool store-credentials <profile>` and pass it:

```sh
HERDLY_SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" HERDLY_NOTARY_PROFILE=<profile> sh scripts/package-app.sh
```

The script refuses to notarize with anything other than a Developer ID Application identity and fails, rather than relabels, when the submission is not accepted. No Developer ID identity was available to the agent that wrote this route, so no signed or notarized artifact has been produced yet; the recorded artifacts in [MVP acceptance](mvp-acceptance.md) are `unsigned-dev` and `dev-signed`.

## Install

1. Check the checksum: `shasum -a 256 -c Herdly-<version>+<build>-<label>.zip.sha256`.
2. Unzip and move `Herdly.app` to `/Applications` or `~/Applications`. Herdly does not install itself or add a login item unless you explicitly turn on **Launch at login**. Connect Codex copies the helper out of the bundle (see below), so moving or replacing the app later does not break an existing Codex connection. macOS owns login-item registration separately; after moving or replacing the app, open Herdly's General settings and check the status macOS reports.
3. For an `unsigned-dev` or `dev-signed` build, the first open is refused by Gatekeeper. Open **System Settings › Privacy & Security**, scroll to the message about Herdly, and choose **Open Anyway**, or run `xattr -d com.apple.quarantine /Applications/Herdly.app` and open it again. A `notarized` build opens directly.
4. Herdly launches as a menu-bar app (**S**) with no Dock icon, and shows its controls window because no setup exists yet.

### Launch at login

**Launch at login** is off by default. Turn it on in Herdly's **General › Startup** settings if you want macOS to open Herdly when you sign in. The displayed status comes directly from macOS rather than from a saved Herdly preference.

If the setting says **Approval required**, choose **Open Login Items** and allow Herdly under **System Settings › General › Login Items & Extensions**. If it says **Unavailable** after the app was moved or replaced, use the same System Settings panel to remove any stale entry, then reopen Herdly and opt in again. Herdly never repairs or recreates a login item without your action.

### Connect Codex

Connecting is explicit and previewed. In **Settings → Agents**, review the preview from the Codex card's **⋯ → Show Setup Changes…**, then click **Configure Codex**. Herdly then:

- copies `Contents/Helpers/HerdlyHook` from the bundle to `~/Library/Application Support/Herdly/HerdlyHook` (mode 755) after running its self-test, and records the install in `~/Library/Application Support/Herdly/install.json`;
- adds to `~/.codex/hooks.json` one command hook per event for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop` and `SessionEnd`, each running that helper with `--events-dir ~/Library/Application Support/Herdly/events --installation-id <uuid>`;
- adds to `~/.codex/config.toml` exactly three kinds of line: `hooks = true` under `[features]`, `terminal_title = ["session-id"]` under `[tui]`, and one `trusted_hash = "sha256:…"` per installed handler under `[hooks.state."<hooks.json path>:<event>:<group>:<handler>"]`;
- backs up the original `config.toml`, `hooks.json` and any previous helper under `~/Library/Application Support/Herdly/backups/<uuid>/`.

Nothing else in `~/.codex` is touched: approval policy, sandbox settings, model, profiles and every other table stay as they were, and the preview shows every line before it is written. If Codex already has hooks disabled, a different `tui.terminal_title`, or a second Herdly install, Herdly reports a conflict and writes nothing.

Herdly keeps its installed helper in step with the running app. At launch and on each setup refresh, when the bundled helper passes its self-test and differs from the installed one, Herdly replaces the installed helper (mode 755, renamed into place) and updates its record in `install.json`, but only while the installed file is still exactly the one Herdly recorded. It never edits `config.toml` or `hooks.json` to do this. A helper that someone else changed is left alone and reported as a conflict. Hooks already running finish with the old helper; the next hook invocation uses the new one. The same applies to each configured Claude root's helper.

Codex loads hooks when a session starts, so sessions already running keep their old settings until restarted. Codex also asks once whether to trust the new hooks; Herdly records the trust entries, and a hook that Codex reports as changed shows in Herdly as **repair required** rather than being silently re-trusted.

Codex keeps working if Herdly is quit or crashes. Every hook either records metadata or, for `PermissionRequest`, waits at most its bounded deadline and returns no decision, after which Codex shows its own prompt. No companion process is required for normal Codex use.

### Connect Claude Code

Claude is configured separately in **Agents → Claude Code**. Herdly previews the default `~/.claude` root first; use **⋯ → Add Another Claude Folder…** for a manually selected `CLAUDE_CONFIG_DIR` root, which then appears as a row in that card. Each root has its own helper, events, install record, installation identity, and undo path. See [Claude setup](claude-setup.md) for ownership and state details.

Configure Claude adds only Herdly's exact hook entries and `env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` to that root's `settings.json`, then installs the packaged helper under Herdly's Application Support directory. The `SessionStart` entry emits the full-session-ID Ghostty title through Claude's JSON `terminalSequence`, and `SessionEnd` requests a reset. Existing Claude sessions are not restarted; Herdly reports **Configured; restart required** until a newly started session sends a root-matching event. Ghostty Automation readiness remains separate from this connection state.

The optional Claude usage bridge is displayed in the same preview and starts off. When selected, setup runs a bounded cancellation and descendant-exit probe before composing an existing `statusLine`; an incompatible command is left untouched while the core hooks remain independent. The bridge records only sanitized five-hour and seven-day subscription windows for the selected root and can be disabled through the same reversible setup flow. Known managed policy, malformed files, duplicate installs, and changed owned values are reported without writing. The setup snapshot has no project context and cannot resolve arbitrary project or command-line `--settings` precedence, so the preview warns that arbitrary future overrides may win and connection still requires a fresh exact-root SessionStart. Ghostty title application, clean SessionEnd reset, and the live old-session restart-required observation remain deferred operator checks; abrupt-exit restoration remains an unproven operator limitation without a launcher.

### Update an outdated agent

When an installed agent is older than the minimum in [Requirements](#requirements), its card in **Settings → Agents** shows a problem row such as "Codex CLI · Update to 0.145.0 or later". Each such row has one small button that acts on that one app:

- **Claude Code → Update** runs the detected `claude` executable as `claude update`. Claude's own updater routes package-manager installs through their package manager, so the button is always offered.
- **Codex CLI → Update** runs `<prefix>/bin/brew upgrade --cask codex`, and only when the detected `codex`, with every symlink resolved, lives inside a Homebrew `<prefix>/Caskroom/codex/` folder. Any other or unknown install (npm, a manual copy) gets no button; the card says Herdly can't tell how Codex CLI was installed, and you update it the way you installed it, then choose **⋯ → Review Again**.
- **Codex desktop → Open Codex** opens the selected desktop app so it can update itself; Herdly never updates it. The row reads "Waiting for Codex to update itself" until a detection sees the minimum version (Herdly detects again when Codex relaunches).

An update runs off the main thread with empty input, a five-minute limit, and its output kept to itself; then setup detection reruns as Review Again does. While it runs, the row reads "Updating…" with its button disabled; other rows stay usable. It succeeds only when the command exits cleanly and detection then sees a version at or above the minimum: the row disappears, the card notes "Updated <app> to <version>. Sessions already open keep the old version until you restart them.", and the header reads **Restart required** until Herdly receives that agent's next `SessionStart` (Codex and Claude Code are tracked separately). Restart required clears when you start a new session, or when Herdly relaunches, since Herdly keeps it in memory only. Otherwise the row reads "Couldn't update: <reason>" (took too long, `<tool>` not found, or the last error line the command printed) with **Try Again**; nothing retries automatically. Herdly never restarts sessions.

## Permissions macOS may ask for

| Prompt | When | If declined |
| --- | --- | --- |
| **"Herdly" wants access to control "Ghostty"** (Automation) | Right after **Enable Ghostty Controls** in Herdly's first-launch prompt, or after turning on Ghostty under **Settings › Terminals** (if Ghostty is not running, when it next opens). The usage string is in the bundle's `NSAppleEventsUsageDescription`; since #239 it is one app-wide sentence about selecting terminal tabs and typing replies in the terminals you turn on, shown for Ghostty and, once its switch is offered (#244), Terminal.app. | Open in Codex for CLI sessions reports that it cannot read Ghostty's tabs; everything else works. Herdly switches Ghostty controls off; re-enable under **System Settings › Privacy & Security › Automation › Herdly** (Settings › Terminals has a button for it), then turn the controls back on. |
| Gatekeeper "cannot be opened" | First launch of an `unsigned-dev`, `dev-signed`, or `signed` build. | See step 3 above. |
| Codex's own hook-trust prompt | The first Codex session after Configure Codex. This is Codex's prompt, not macOS's. | Codex ignores the untrusted hooks; Herdly shows repair required. |

Herdly does not request Accessibility, Screen Recording, Input Monitoring, notifications, or Full Disk Access, and does not read the Codex desktop app's window contents. Desktop visibility comes from `NSWorkspace` app-activation notifications, desktop read state from `~/.codex/.codex-global-state.json`, thread names from `~/.codex/session_index.jsonl`, and turn state from `~/.codex/sessions` rollouts and the hook records above.

## What Herdly stores

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/Herdly/HerdlyHook` | The installed helper (a copy of the bundle's, kept in step with the running app while unchanged). |
| `~/Library/Application Support/Herdly/install.json` | What Configure Codex wrote, so undo can remove exactly that. |
| `~/Library/Application Support/Herdly/events/` | Metadata-only hook records, approval receipts and decisions. |
| `~/Library/Application Support/Herdly/backups/` | Originals of files Herdly changed. |
| `~/Library/Application Support/Herdly/attention-snapshot.json` (and `.previous`) | Undismissed completions and dismissal identities. |
| `~/Library/Preferences/dev.rcurio.herdly.prototype.plist` | Mute, the events-folder choice, the desktop read-state toggle, the last controls section, and the prototype's test item. Launch-at-login state is not stored here. |

No conversation text or transcripts are stored. Fresh notification spotlights may read bounded prompt and final-response excerpts into process memory; those excerpts disappear when Herdly quits and are excluded from the attention snapshot.

## Uninstall

1. In Herdly's General settings, turn off **Launch at login**. This unregisters only Herdly's main-app login item. If the control is unavailable, open **System Settings › General › Login Items & Extensions** and remove Herdly there.
2. In Herdly's controls window, click **Undo setup**. Herdly removes exactly the hooks and config lines it added, restores the original files byte for byte when they are unchanged since install, deletes its helper, its own event records and its backups, and leaves everything else in `~/.codex` alone. Skip this step if Herdly was never connected.
3. Quit Herdly from its menu.
4. Delete `Herdly.app`.
5. Optionally remove the remaining local state: `~/Library/Application Support/Herdly` (the snapshot of dismissals) and `~/Library/Preferences/dev.rcurio.herdly.prototype.plist`. Neither affects Codex or controls the login item.

Uninstalling in this order leaves Codex exactly as it was before Connect and removes Herdly's login-item registration. Deleting the app first is safe for Codex too: the hooks then point at a helper that still exists in Application Support, or, if that was also deleted, at a missing command, and Codex reports a failed hook without blocking; but the config lines remain until removed by hand as below. A stale Herdly entry can also remain in Login Items until you remove it in System Settings.

### Recovery when Undo setup is unavailable

If Herdly cannot run, `install.json` is gone, or Undo setup reports a conflict, the additions are all visible and removable by hand. Quit Codex sessions first, keep a copy of both files, then:

1. In `~/.codex/hooks.json`, remove every command entry whose `command` contains `Application Support/Herdly/HerdlyHook`. Leave hooks from anything else in place.
2. In `~/.codex/config.toml`, remove each `[hooks.state."…"]` table whose key names one of the hooks removed above, the `terminal_title = ["session-id"]` line under `[tui]` if it was Herdly's (an empty `[tui]` table can go too), and `hooks = true` under `[features]` only if nothing else needs hooks.
3. The originals Herdly saved are under `~/Library/Application Support/Herdly/backups/<uuid>/` as `config.toml` and `hooks.json`; copying them back is only correct if Codex has not rewritten those files since Connect, which Codex desktop does on its own, so prefer removing the lines.
4. Delete `~/Library/Application Support/Herdly`.

Herdly's status check reads these same files, so a reinstall afterwards starts from a clean preview.

## Upgrading from Steer

Herdly was called Steer until 2026-10-20. The rename is a clean break: Herdly has a new bundle identifier (`dev.rcurio.herdly.prototype`), a new folder (`~/Library/Application Support/Herdly`), new hook markers (`herdly-hook-v1`, `herdly-claude-hook-v1`) and a new Claude title prefix (`Herdly Claude `). It does not recognize, migrate or remove anything Steer installed, and Steer's hooks keep calling Steer's helper alongside Herdly's until they are removed.

Remove Steer before connecting Herdly:

1. In Steer, click **Undo setup** for Codex and for each connected Claude root, turn off **Launch at login**, then quit Steer and delete `Steer.app`.
2. If Steer can no longer run, follow [Recovery when Undo setup is unavailable](#recovery-when-undo-setup-is-unavailable) with Steer's names: hooks whose `command` contains `Application Support/Steer/SteerHook`, and the folder `~/Library/Application Support/Steer`.
3. Optionally delete `~/Library/Preferences/dev.rcurio.steer.prototype.plist` and remove any stale Steer entry in **System Settings › General › Login Items & Extensions**.

Herdly starts with default settings, an empty attention snapshot, and no Automation permission: macOS asks again for each terminal you turn on.

## Known limitations

- Exact desktop task focus is deferred: the notch hides whenever Codex desktop is foreground, even while a different thread is visible, and a desktop completion clears only on Dismiss or on Codex's own unread flag clearing.
- Desktop approvals stay in Codex's native prompt; only direct CLI approvals offer Approve (allow once) and Deny, with a 30-second handoff.
- Ghostty targeting covers one Codex session per unsplit tab with session-ID titles; split tabs report unavailable.
- There is no global hotkey; keyboard users click the panel once, then Tab and Escape work.
- Hook records and rollouts are scanned with fixed size caps every two seconds while a session is live or a row is held, and on a hook-folder change or every three seconds otherwise ([architecture](architecture.md)); very large histories are a known, deferred cost.
- The bundle identifier is still `dev.rcurio.herdly.prototype`; changing it would orphan the preferences above.
