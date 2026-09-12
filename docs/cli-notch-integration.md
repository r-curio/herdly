# CLI notch integration — issue #3

This branch carries the existing desktop reminder integration as a separate baseline commit and adds CLI completions plus Ghostty navigation. The previous worktrees and their uncommitted files remain unchanged.

The selected events folder is read every two seconds. Session identity and source come from the matching Codex rollout metadata. Only CLI Stop records whose exact session/turn also has task_complete enter the CLI queue. Desktop reminders retain their desktop links. CLI reminders and completions route through the Ghostty adapter. Old completions restore silently; new completions expand for three seconds with the existing muteable sound. Explicit dismissals and verified visits persist completion-specific acknowledgments. Later turns are independent.

The app packages the native JXA adapter and includes the Automation usage description. Ghostty controls start disabled every launch. The user enables them in Steer controls; failed native access disables further queries and leaves notifications intact. Native calls happen off the UI thread with a five-second process deadline. Matching requires a live tracked session, the exact shortened UUID title, one unique terminal and no splits. The adapter revalidates immediately before selection and verifies the resulting foreground window/tab/terminal. Missing, ambiguous or changed targets are not acknowledged. A focus/navigation result acknowledges only completions captured before its asynchronous query.

Build: `sh scripts/build-app.sh`. Tests: `swift test` (six tests), including real file-reader/queue reconstruction and title matching. Native navigation remains unverified in Ghostty because the agent's computer-use restriction still applies. This is a lab integration, not installation of global hooks or proof that sessions outside the connected lab are monitored.

CLI PermissionRequest hooks now publish the actual session/turn, command,
project, action, reason, and expandable tool input to the connected events
directory. Steer can write one atomic allow-once or deny record for that exact
request; the helper rejects mismatched, duplicate, late, and timed-out records.
The helper waits up to two seconds for the companion receipt; only then does
the 30-second clock start, including queued requests. Its 31-second decision
wait bound is independent of the notch refresh loop. If Ghostty focus is
focused, unknown, or unavailable, the app writes a no-decision handoff and
retains Open in Codex. Desktop requests hand back immediately so Codex keeps its
native prompt until the desktop transport and handoff policy are proven.

For human navigation testing, run Codex directly in two unsplit Ghostty tabs in the already trusted lab using `/opt/homebrew/bin/codex -m gpt-5.5 -s read-only -a on-request -c 'tui.terminal_title=["session-id"]'`. Connect the lab events directory in Steer if needed, then manually enable Ghostty controls and grant Automation permission if macOS asks. Send distinct no-tools completion prompts, switch to another app, then use each completion's Open in Codex button. Verify the correct tab is selected, and repeat across two windows. No saved Codex hooks, permission policies or terminal settings are modified by this build.

## Live Steer UI proof

The release build and strict code-sign verification passed. Replaced the running older Steer instance with this build, leaving its files intact. Computer use inspected only Steer: after reading the existing selected lab directory, controls reported one reminder and six CLI completions. Expanding the actual notch showed CLI completion rows, the CLI reminder, Dismiss actions and disabled Open buttons while Ghostty controls remained off. No Ghostty API, native selection or Automation permission prompt was invoked. The new build remains running from `output/Steer.app`.

## Reminder-only expansion fix

Reproduced a real one-item notch that would not expand. CLI reminders were counted and rendered as visible over Codex Desktop, but their shared presentation timer still applied desktop-only suppression. The presentation now uses the same visible-reminder list as the count and rows. Added a focused regression covering a CLI reminder with desktop foreground, plus its three-second collapse.

When Ghostty is disabled, CLI completion and reminder rows now expose Set up Ghostty rather than an unexplained disabled Open button. This opens Steer controls without enabling native access automatically. Setup guidance also covers reminder-only queues. Seven Swift tests, release build and strict signing verification passed. Live Steer UI confirmed the single reminder expands visibly and Set up Ghostty opens controls. Native Ghostty access remained off.

## Missing title configuration during navigation test

The user reported the generic navigation failure for reminder session 01a09139. Inspection found saved `terminal_title = []`; the earlier denial-test launch instructions omitted the session-title override. This explains why that test did not establish the required title binding; live inventory was not inspected, so other navigation failure causes remain possible. No saved settings were changed. Navigation feedback now distinguishes unreadable inventory, no unique matching live title (showing the expected title), rejected selection and unverified foreground state. Use a fresh session with the explicit per-launch title override for the next test.

## Human-verified Ghostty navigation

After launching a fresh CLI session with the explicit session-ID title override, the user confirmed that Open in Codex navigated correctly. The user then repeated the workflow with a second session in another Ghostty tab and confirmed that it worked. This is human-reported success for distinguishing two sessions and opening their corresponding tabs from another app, using the connected notch build. The agent did not control Ghostty. Separate-window navigation, direct-return acknowledgment and native failure-state behavior remain separate live checks; the prior hook status warnings are still unresolved.

## Group repeated completions from one session

The two visually identical rows were different completed turns in the same session. The UI now groups CLI completions by session, shows the number of completed replies, and counts one completion group per session. Dismiss acknowledges only the turns captured in that displayed group; later arrivals remain independent. Approval reminders remain separate. Eight tests passed, including duplicate-event rejection, session grouping, restart persistence and a newer-turn race. The rebuilt app is running. At UI inspection the completion queue was already empty and only the old approval reminder remained, so the multi-reply row itself was verified through the automated test rather than a live two-row fixture.

## Canceled-turn reminder cleanup

The old HANDOFF-1 reminder persisted because its exact turn recorded turn_aborted rather than task_complete. Added separate canceled-turn parsing in the existing bounded rollout reader. Reminder resolution consumes completed or canceled identities, while CLI completion notifications still require task_complete. No session-wide cancellation inference is used.

A disk-level regression failed before the fix and passed afterward: exact-turn cleanup, unrelated session/turn preservation, partial-file retention, restart reconstruction, no resurrection after a later read failure, and no false completion notification. All nine tests passed; release build and strict signature verification passed. The updated running app reads the unchanged real lab records and shows zero reminders and zero queued notifications.

## Human-verified direct-return acknowledgment

The user explicitly confirmed that returning manually to the originating Ghostty tab clears its completion from Steer, without clicking the notch Open action. Combined with prior user-confirmed two-tab and cross-window navigation, this establishes the tested happy-path navigation and focus behavior. Native error-state behavior and CLI missing-status hook warnings remain separate unresolved checks.

## Missing-status warning root cause

Global ~/.codex/hooks.json registers an AttentionRouter helper for SessionStart, UserPromptSubmit, PermissionRequest, Stop and SessionEnd, separate from Steer's project hooks. The installed helper fails codesign verification (resources required by its signature are absent). Its read-only --help invocation terminates with signal 9 and no output. This reproduces a process exit without a normal status code; Codex 0.145.0's command runner obtains output.status.code(), which is absent for signal termination. This explains the corresponding warnings alongside successful Steer captures/decisions.

Steer's exact recorder/interpreter also passed ten isolated /bin/zsh -lc replays (all exit 0, no output, maximum 0.103 seconds), in addition to prior direct recorder replays. A proposed config removing only the five AttentionRouter entries was prepared under /tmp; the real config was not changed. Removing those hooks would disconnect the other app's Codex integration, so that choice is pending the user's approval. Impeccable hooks and Steer's project hooks are preserved.

## AttentionRouter removal authorized and applied

The user explicitly requested removing all AttentionRouter-related installation files. Removed its five global Codex hook entries atomically, preserving the two unrelated Impeccable handlers and all Steer project hooks. Moved both Latch apps, the installed helper/database/support folder, preferences, application scripts, old Xcode build copies and container Data directories to a recoverable Trash folder. No AttentionRouter processes or startup entries were found in the inspected locations.

macOS denied removal of `.com.apple.containermanagerd.metadata.plist` in the AttentionRouter and UI-test runner containers. Those protected metadata files and their container shells remain; ordinary application data was removed without changing permissions or bypassing that denial. New Codex sessions no longer have the broken helper configured; already-running sessions may retain previously loaded hooks. A fresh CLI runtime warning check has not yet run.

## Final clean-run acceptance — 2026-09-12

The user confirmed all three checks in a fresh ordinary `codex` session: automatic session-ID title, no missing-status hook warnings, and completion appearing in Steer. The lab independently captured SessionStart, UserPromptSubmit and Stop for session `01a0916c-337b-70b2-963e-9cf848bd2a48`, turn `01a0916c-5828-7b63-b568-b4d127a048fb` at 17:03 UTC.

Issue #3's scoped feasibility proof is complete: CLI lifecycle/decision evidence, human-tested exact tab/window navigation and direct-return acknowledgment, plus offline conservative failure-case checks. The untouched 30-second CLI timing retest was explicitly waived by the user. This does not claim live tests of every invalid/split topology, general approval-category coverage, a distributed signed release, or merged PRs. Split-pane support remains deferred; first-launch automatic setup is tracked in #5.

## Issue #6 lifecycle wiring — 2026-09-12

The companion now replays CLI lifecycle hooks through `CLIState`: session start
adds a live session, prompt submission adds one running turn, Stop removes only
that turn while the completion queue retains its exact session/turn identity,
and SessionEnd removes the session and all running turns. CLI running rows and
desktop running rows use the same shared notch counts while desktop and CLI
identities remain separate. Session-title matching remains exact and rejects
duplicate, closed, malformed, or split targets.

Checks passed: `swift test` (25 tests), `sh scripts/build-app.sh`, strict
`codesign --verify --deep --strict`, the controls-window smoke check, and the
offline Ghostty matcher/navigation checks. A read-only capability probe against
the installed `/Applications/Ghostty.app` reported version 1.3.1 with no
native PID/TTY properties. No live Ghostty inventory or pane selection was
attempted because the existing computer-use restriction blocks that route; the
native live boundary remains human-verification evidence, not an agent claim.

The current `a344971` build was also launched and inspected through the
allowed Steer UI route. Its controls reported Ghostty 1.3.1 available and the
unchanged real events directory showed `0 reminders · 1 working · 0 sessions
to check`, proving the live CLI lifecycle row in the companion. Combined with
the existing human-verified two-tab/cross-window navigation and direct-return
acknowledgment above, this closes the issue's happy-path evidence boundary.
CUA still forbids agent access to Ghostty itself; no new tab selection,
Automation permission change, or user configuration change was made.

## Completion notification demonstration (#8)

The automated CLI replay and queue tests demonstrate exact-session/turn
completion capture, duplicate-event rejection, later-turn retention, restart
acknowledgment persistence, and source-aware presentation gating. Existing
Steer-only evidence above records the live CLI completion rows, grouped replies,
and verified direct-return acknowledgment.

This patch did not inspect or control Ghostty, request Automation access, or alter
terminal/configuration state. Ghostty focus timing remains bounded by the matcher
and controllable-clock regression; a fresh native popup/sound run in Ghostty still
requires the permitted human route.

An earlier native CLI demonstration was blocked by the locked Mac and failed
allowed CUA unlock attempt. Prior Steer-only CLI rows, grouped replies,
verified navigation, and direct-return acknowledgment remain the available
CLI evidence; no fresh Ghostty popup or sound observation is claimed here.

The later allowed CUA walkthrough exercised only the branch's connected desktop
evidence (17 real desktop completions plus one test item). It did not trigger a
fresh CLI turn or access Ghostty, so no new CLI-native popup/sound evidence is
claimed.

### Fresh CLI completion proof (2026-09-12)

An interactive Codex TUI session `01a0923d-0a94-7de1-aa3a-641a86112456` ran in
`/Users/rmaisog/Documents/ChatGPT/Steer/output/desktop-hook-lab`. Its rollout was
`/Users/rmaisog/.codex/sessions/2026/09/12/rollout-2026-09-12T04-51-09-01a0923d-0a94-7de1-aa3a-641a86112456.jsonl`, with `session_meta` source
`cli` and the lab cwd. Turn `01a0923d-c536-7b73-b750-cd011719d5f0` completed
with the exact response `STEER-CLI-TUI-COMPLETE`.

The matching hook captures were SessionStart
`5a07abef-c71b-4865-84b9-871472f2dc1b`, UserPromptSubmit
`711f297a-ff02-48c6-9f04-0cbbb9a93fea`, Stop
`4103507e-29c8-4e4b-87a4-d5503b5c7d03`, and SessionEnd
`9c365965-fd2c-42ee-9bb9-1281953ea5cb`. The exact built app from this branch
showed 20 notifications; its first row read **Codex CLI finished Session
01A0923D-0A94** and rendered **Open in Codex** and **Dismiss** controls.

This proves the fresh CLI lifecycle-to-completion path and native row rendering
through the allowed Steer route. Sound audibility/mute and Ghostty-focused
suppression remain human-only boundaries and are not proven here.
