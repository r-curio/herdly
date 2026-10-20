# Direct CLI and Ghostty gate (#3)

## Current scope: tabs only

The user deferred multiple panes within a tab. Issue #3 now targets one Codex session per unsplit tab, across tabs/windows, on the stable runtime. Earlier split-pane test requirements below are historical. Session-to-tab binding remains unresolved; two tabs in one project cannot be distinguished by cwd alone. A prerelease upgrade is not an accepted requirement. See ADR 0004.


Checked 2026-09-11. Status: blocked; exact live session-to-pane binding is not proven. [Issue #3](https://github.com/r-curio/herdly/issues/3).

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

Ran the installed shell CLI with `exec --ephemeral --sandbox read-only` in the existing isolated desktop-hook-lab, reusing its previously trusted recorder without changing hook or permission settings. Default gpt-6-astra failed with a server error requiring a newer Codex version. A per-invocation gpt-5.5 override succeeded and returned the exact marker HERDLY-CLI-LIFECYCLE-3.

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
cd /Users/rmaisog/Documents/ChatGPT/Herdly/output/desktop-hook-lab
codex -m gpt-5.5 -c 'tui.terminal_title=["session-id"]' 'Reply only HERDLY-TAB-CHECK. Do not use tools.'
```

The model override only avoids the independently observed newer-model/older-CLI incompatibility. It changes neither the saved default model nor the title setting. Expected titles are different shortened UUIDs. Capturing and revalidating the actual native tab/window inventory and navigation still require a permitted interaction route; the current Ghostty computer-use restriction remains. Do not run the prerelease merely for this test. Interactive approval checks remain separate.


## Human-assisted title proof — 2026-09-11

The isolated lab recorded SessionStart, UserPromptSubmit and Stop for two CLI sessions at 11:42 UTC: `01a09046-5590-7882-adad-6b7f4ec91925` and `01a09046-56da-7d83-9a38-02e59d7441ec`. The user confirmed that the two unsplit Ghostty tabs show the expected rendered titles `01a09046-5590-7882-adad-6b7f4...` and `01a09046-56da-7d83-9a38-02e59...`. This is hook-file evidence plus human confirmation of displayed titles, not an automated native inventory read.

The session-title link is demonstrated for this run. The probe still has only a pure inventory matcher: live inventory acquisition, selection of the matched tab/window, post-navigation verification and foreground-session observation are not implemented or proved here. The existing Ghostty computer-use restriction blocks agent-driven live navigation testing; alternate UI APIs must not be used to evade it. Interactive CLI approval checks also remain open. Issue #3 is not complete.


## Navigation adapter — offline implementation

`scripts/ghostty_navigation.py` now reuses the session-title matcher to obtain a target from a fresh native inventory. Its JXA adapter rechecks unique title, unsplit structure and all three IDs before activating the window and selecting the tab. A second snapshot must match both the original target and foreground selection before returning `opened`. Failure returns unknown; there are no terminal input or approval commands. The caller must supply current live session IDs and invoke off the UI thread. Each script process has a five-second timeout.

Run `python3 scripts/check_ghostty_navigation.py` for offline transport and native-script checks. The native script runs against a fake dictionary-shaped application in Node, which has no Apple Events bridge. Tests cover selection, background/unverified state, stale or closed targets, duplicate matches, split rejection and transport errors. These checks passed alongside the existing matcher checks.

This issue branch contains the investigation adapter, not the Swift notch application. The adapter has not been installed, connected to Open in Codex, or executed against Ghostty. Live JXA dictionary behavior, native permission handling, cross-window focus, and CLI approvals remain unverified. The prior computer-use restriction remains a genuine live-test blocker; this code is not an alternate route for the agent to bypass it.


## Issue #3 acceptance audit

Added read-only `observe` to the adapter. It returns foreground only for the unique session target matching the active window/tab/terminal; another tab or background app does not acknowledge the session. Missing or malformed focus data, ended sessions and transport failures remain unknown. Offline checks passed. This is not live focus proof.

Completed: two normal CLI sessions in same-project unsplit tabs, separately captured lifecycle hooks, human-confirmed distinct session-ID titles.

Outstanding live proof: native inventory IDs, foreground/background focus and navigation across tabs/windows, native Automation permission behavior, and CLI allow/deny/no-decision. The existing trusted isolated lab has a marker-only PermissionRequest helper; its desktop proof must not be substituted for CLI proof. The helper accepts only `touch HERDLY-APPROVAL-DIRECT-...` commands. No hooks or permission settings were changed during this audit.

Next permitted human-assisted CLI check: in one existing lab session, request exactly `touch HERDLY-APPROVAL-DIRECT-CLI-ALLOW-1` using an explicit approval request, with no retry without approval. Confirm the helper appears before testing Allow once. Then use fresh DENY and HANDOFF markers in separate turns. Record each outcome and file existence independently. If the CLI refuses to request approval under its current policy, record that as a policy limitation; do not loosen the user's policy automatically.


## CLI approval attempt and Stop warning — 2026-09-12

Turn `01a09131-5937-7473-ae0d-d0ffe8d83b39` in session `01a09046-5590-7882-adad-6b7f4ec91925` ran the exact CLI-ALLOW-1 marker command, returned exit 0 and created the file. The runtime trace shows on-request approval policy with danger-full-access sandbox, and an explicit require_escalated tool request. Captured events include UserPromptSubmit, PreToolUse, PostToolUse and Stop, but no matching PermissionRequest or approval outcome. This does not pass the Herdly allow test. Next attempt needs a per-launch read-only sandbox in the disposable lab; saved permission configuration remains unchanged.

The user reported “Stop hook (failed): hook exited without a status code.” Despite this, the matching Stop record was persisted at 15:59:40 UTC. Twenty isolated replays of the exact recorder/interpreter with synthetic Stop input all exited 0, produced no stdout/stderr and saved all twenty records; maximum duration was 0.183 seconds against the configured two-second timeout. The runtime warning is unreproduced and its cause remains unknown. No hook code, trusted-hook configuration or timeout was changed.


## CLI-ALLOW-2 and launcher alias

The user's `.zshrc:31` defines `alias codex='command codex --sandbox danger-full-access'`. Adding `-s read-only` to that alias explains the duplicate-sandbox argument error. Future isolated launch instructions must use `/opt/homebrew/bin/codex` directly, leaving the alias unchanged. The user instead started a normal session and selected Ask for approval.

Session `01a09134-ade6-7fd1-bc6a-cd35b1fa3e5a`, turn `01a09134-e4a4-7f61-97af-6e85d7f1e5ee` delivered PermissionRequest. The helper recorded outcome allow after 3.9467 seconds (request `531a5fab-9666-4bb7-9ed1-c24ea92d805f`), followed by PostToolUse, marker CLI-ALLOW-2 existence and Stop. User-visible CLI warnings nevertheless reported missing status codes for several hooks, including PermissionRequest. This proves helper decision capture and eventual command execution; acceptance of the helper response versus native fallback is not conclusively distinguished while that warning remains. Deny with a fresh marker is the next discriminating check. No hook or shell configuration was changed.


## CLI deny verified — 2026-09-12

In the isolated lab, session `01a09139-df77-7610-b181-6933c455fa3f`, turn `01a0913a-06c7-7453-88d9-45a5932de93a`, request `49441eff-fccb-45b3-bdab-9da913715bee` recorded deny after 2.419 seconds. The user-visible CLI explicitly reported “PermissionRequest hook denied approval” and did not retry. The DENY-1 marker is absent; the matching Stop event was captured. This verifies that the CLI consumed the hook denial despite the separate missing-status warnings. It does not resolve those warnings or complete the no-decision/navigation checks.


## CLI manual no-decision handoff verified

Request `43fbe99e-ad28-4ca4-be2f-aaa9c8f420d1`, turn `01a0913a-ece1-7861-9403-071c1a7835f8` in session `01a09139-df77-7610-b181-6933c455fa3f` returned no_decision after 10.3859 seconds. The user confirmed clicking Open in Codex and subsequently seeing the CLI native approval prompt. At inspection, the HANDOFF-1 marker was absent and the tool call remained pending. This verifies manual handoff without automatic execution; it is not the 30-second timeout test or proof of exact Ghostty navigation.


## User acceptance of timeout — 2026-09-12

The user explicitly requested trusting the untouched 30-second timeout rather than repeating that live test. Treat the behavior as user-accepted with the live timing check waived, not as an instrumented CLI timeout result. The measured 10.3859-second run remains manual Open in Codex handoff evidence.

Reran the navigation transport, native-script fake-application, foreground observation, capability and matching checks: all passed. No live Ghostty UI was queried or selected. The existing computer-use restriction still prevents agent-driven live navigation proof. The adapter is not wired into the Swift notch application, and the CLI missing-status hook warnings remain unresolved. Neither waived timeout timing nor offline navigation checks establish that issue #3 is complete.
