# Direct CLI and Ghostty gate (#3)

## Current scope: tabs only

The user deferred multiple panes within a tab. Issue #3 now targets one Codex session per unsplit tab, across tabs/windows, on the stable runtime. Earlier split-pane test requirements below are historical. Session-to-tab binding remains unresolved; two tabs in one project cannot be distinguished by cwd alone. A prerelease upgrade is not an accepted requirement. See ADR 0004.


Checked 2026-09-11. Status: blocked; exact live session-to-pane binding is not proven. [Issue #3](https://github.com/r-curio/steer/issues/3).

## Installed evidence

```sh
python3 scripts/probe_ghostty.py --self-test
python3 scripts/probe_ghostty.py
```

Both passed. This probe reads the app's plist and scripting dictionary plus four allowlisted variables from its own environment and its stdin TTY. It sends no Apple Events, controls no UI and changes no settings. Running it inside the Codex tool runner yielded no terminal context; that is not evidence about a direct Ghostty shell.

Installed Ghostty is `1.3.1`. Its scripting dictionary provides:

| Object | Relevant properties/actions |
| --- | --- |
| Application | Frontmost flag and front window |
| Window | Stable ID and selected tab |
| Tab | Stable ID and focused terminal |
| Terminal | Stable ID, title, working directory, focus action |

The installed terminal object does **not** expose TTY or process ID. A read-only string check of the installed binary found `GHOSTTY_RESOURCES_DIR` but neither `GHOSTTY_SURFACE_ID` nor `GHOSTTY_SESSION_ID`; the bundled shell integrations also had no matching ID/TTY variable assignments. This is static evidence, not a complete runtime environment test.

The [official AppleScript documentation](https://ghostty.org/docs/features/applescript) establishes the candidate focus/navigation API. A stable pane ID is useful only after it is reliably bound to the originating Codex session. Two sessions in the same directory cannot be distinguished by directory. Titles and whichever pane is frontmost when a hook arrives are also unsafe identifiers. Process ancestry/TTY alone cannot join to a dictionary that exposes neither.

Do not substitute one of those heuristics to pass the gate. A future runtime exposing a verifiable inherited pane identifier or a supported process/TTY mapping could resolve this gap; that would need its own installed-version test. No Ghostty upgrade or shell-launch wrapper was installed.

The independent CLI contract check in #2 ran against `/opt/homebrew/bin/codex`, version `0.145.0`. It confirmed lifecycle and approval schema definitions, not hook invocation or native terminal prompt behavior. Desktop uses `0.153.4`; do not inherit desktop approval results for this CLI.

## Live test blocker and remaining exercise

The computer-use tool rejected `/Applications/Ghostty.app` (`com.mitchellh.ghostty`) for safety reasons. No alternate UI-control route was attempted. No new tab, split, CLI session or approval prompt was created. macOS Automation permission availability is untested; the tool rejection does not prove a macOS permission denial.

In a permitted environment, run two disposable, normally launched Codex sessions in the same project: first in splits, then separate tabs/windows. Capture each session ID and authoritative pane binding from within the session; the probe above can record candidate terminal context without dumping other environment variables. Collect the frontmost app, selected tab, focused pane, requested target and independently observed result while moving between both sessions and another app.

Pass requires exact return to the originating pane, including from background, and no acknowledgment of A when only B is viewed. Close the target and revoke/unavailable observation in the test environment: the result must become unknown/unavailable without targeting another pane or typing keys. An accepted focus command alone is not proof of the final selected pane.

Separately exercise actual CLI lifecycle hooks and explicit allow once, deny, 30-second no-decision, disconnect, manual return and late-reply cases using disposable actions and isolated configuration. Capture request correlation and native resolution. Neither these approval cases nor same-directory focus/navigation cases have run. #6 remains blocked.


## Fresh investigation — 2026-09-11

Installed capability checks still pass for Ghostty 1.3.1 and CLI 0.145.0. The installed terminal dictionary still lacks PID and TTY. The probe now reports those capabilities explicitly and tests exact TTY matching, including same-directory panes, missing/closed targets and duplicate matches. It never falls back to the current pane, cwd or title and sends no UI commands.

A supported upstream fix exists: commit [9a900220](https://github.com/ghostty-org/ghostty/commit/9a9002202b8767e6e99c2bb48fad09fc0ae02870) adds read-only terminal PID/TTY getters. Upstream issue [11592](https://github.com/ghostty-org/ghostty/issues/11592) is closed as completed. The current upstream scripting dictionary includes id, name, pid, tty and working directory. This supersedes the earlier suggestion that no upstream implementation exists. It is not in the installed stable dictionary. The official download page still offers 1.3.1; [official prerelease builds](https://ghostty.org/docs/install/pre) track main. No installed app was replaced, no running terminal was closed, and no update-channel setting was changed.

### Independent CLI lifecycle proof

Ran the installed shell CLI with `exec --ephemeral --sandbox read-only` in the existing isolated desktop-hook-lab, reusing its previously trusted recorder without changing hook or permission settings. Default gpt-6-astra failed with a server error requiring a newer Codex version. A per-invocation gpt-5.5 override succeeded and returned the exact marker STEER-CLI-LIFECYCLE-3.

CLI session 01a08ffb-8606-77b1-af6c-6f63169781a8, turn 01a08ffb-86de-7ea1-85e5-95b6ca2c8a56 produced independently captured SessionStart, UserPromptSubmit, Stop and SessionEnd hooks. Output and stderr are in ignored output/cli-lifecycle.*. This verifies CLI exec lifecycle delivery, not interactive Ghostty behavior or CLI approvals. No hook-trust bypass was used.

### Earlier blockers (superseded by the tab-only title decision below)

At this stage, exact live pane proof needs a runtime exposing the new TTY API and a permitted Ghostty interaction route. The prior computer-use denial still applies; no alternate Apple Events/AX route was used to evade it. Running a prerelease terminal as the user's normal terminal is a product/runtime decision, not permission to silently replace their stable install. The two-session split/tab/window proof and CLI allow/deny/no-decision matrix remain unverified. Issue #3 must stay open and blocked until those checks pass or the user explicitly changes its scope.

### Prepared prerelease artifact

Downloaded the official tip asset `ghostty-macos-universal.zip` and extracted it only under `output/ghostty-tip/Ghostty.app`. The bundle reports version `44f2a44df`, team `24VZTF6M5V`, and a 2026-09-10 signing timestamp. `codesign --verify --deep --strict` passed. Running the read-only dictionary probe against that bundle confirmed both native_tty_mapping_available and native_pid_mapping_available. The app was not launched or installed. Switching the user's terminal runtime and performing live tests still require an explicit choice/permitted interaction route; the bundle shares the normal Ghostty ID, so it must not be used to evade the existing computer-use restriction.

## Open Island comparison and stable title candidate

Rechecked upstream HEAD 334c58073ec0ea8a1b34da0c71f969b1affd0959. In `Sources/OpenIslandCore/CodexHooks.swift` (withRuntimeContext, lines 612 onward), Ghostty's focused-terminal locator runs only on SessionStart and UserPromptSubmit. The locator (lines 809 onward) reads `id` and `name` of `focused terminal of selected tab of front window`. Thus the initial session-to-terminal association is inferred from focus when a user-driven hook arrives, not a shared Codex/Ghostty identifier. Later background hook events skip this locator to avoid capturing another focused pane.

`Sources/OpenIslandApp/TerminalJumpService.swift`, ghosttyJumpScript (lines 817 onward), searches by stored terminal ID first, then takes the first matching working directory, then a title substring. It selects the containing window/tab and focuses the terminal. The stored-ID path retries and compares the final focused ID. These fallbacks can select another same-project tab; a stored ID does not correct an initially misbound focus capture. This is source inspection, not a live reproduction of an upstream bug.

A stronger stable-version candidate is Codex's built-in terminal-title setting. Inspection of the exact CLI release source `rust-v0.145.0`, `codex-rs/tui/src/chatwidget/status_surfaces.rs`, confirms TerminalTitleItem::SessionId. However it passes the 36-character session UUID through a 32-character title-part truncation function. Therefore do not describe its output as the complete ID or assume exact full-UUID parsing. A title-based binding must account for the actual rendered value, uniqueness among live sessions, stale/custom titles, and unsupported split tabs. No title configuration was changed and no live title capture was performed.

References: https://github.com/Octane0411/open-vibe-island/blob/334c58073ec0ea8a1b34da0c71f969b1affd0959/Sources/OpenIslandCore/CodexHooks.swift ; https://github.com/Octane0411/open-vibe-island/blob/334c58073ec0ea8a1b34da0c71f969b1affd0959/Sources/OpenIslandApp/TerminalJumpService.swift ; https://github.com/openai/codex/blob/rust-v0.145.0/codex-rs/tui/src/chatwidget/status_surfaces.rs


## Session-title mapping implementation

The user selected the session-ID title approach. `session_title` and `tab_for_session` in the probe now implement the exact CLI 0.145.0 truncation (29 UUID characters plus `...`), whole-title equality, unique live-session prefix, unique terminal match and unsplit-tab validation. Tests pass for two distinct tabs, colliding shortened IDs, missing tabs, malformed inventories, duplicate matches and split rejection. No Apple Events are emitted and no live Ghostty inventory has been read.

For the human-assisted test, open two unsplit Ghostty tabs in the same existing isolated lab. In each, run:

```sh
cd /Users/rmaisog/Documents/ChatGPT/Steer/output/desktop-hook-lab
codex -m gpt-5.5 -c 'tui.terminal_title=["session-id"]' 'Reply only STEER-TAB-CHECK. Do not use tools.'
```

The model override only avoids the independently observed newer-model/older-CLI incompatibility. It changes neither the saved default model nor the title setting. Expected titles are different shortened UUIDs. Capturing and revalidating the actual native tab/window inventory and navigation still require a permitted interaction route; the current Ghostty computer-use restriction remains. Do not run the prerelease merely for this test. Interactive approval checks remain separate.
