# CLI notch integration — issue #3

This branch carries the existing desktop reminder integration as a separate baseline commit and adds CLI completions plus Ghostty navigation. The previous worktrees and their uncommitted files remain unchanged.

The selected events folder is read every two seconds. Session identity and source come from the matching Codex rollout metadata. Only CLI Stop records whose exact session/turn also has task_complete enter the CLI queue. Desktop reminders retain their desktop links. CLI reminders and completions route through the Ghostty adapter. Old completions restore silently; new completions expand for three seconds with the existing muteable sound. Explicit dismissals and verified visits persist completion-specific acknowledgments. Later turns are independent.

The app packages the native JXA adapter and includes the Automation usage description. Ghostty controls are opt-in and remembered across launches. On the first interactive launch, before the user has ever chosen, Steer asks once ("Use Ghostty with Steer?"); Enable Ghostty Controls, or turning on the Terminals switch, asks macOS for Automation consent through `AEDeterminePermissionToAutomateTarget`, which shows the system prompt without sending an event to Ghostty. Not Now leaves controls off and the system prompt unused. Only the user's switch or an Automation denial turns controls off and saves that; when Ghostty is not running, controls stay on, Steer stops polling, and it checks consent again when Ghostty launches. Any other failed native access disables further queries for that launch only, keeps the saved choice, and leaves notifications intact. Native calls happen off the UI thread with a five-second process deadline. Matching requires a live tracked session, the exact shortened UUID title, one unique terminal and no splits. The adapter revalidates immediately before selection and verifies the resulting foreground window/tab/terminal. Missing, ambiguous or changed targets are not acknowledged. A focus/navigation result acknowledges only completions captured before its asynchronous query.

## Open fallback (#236)

[ADR 0015](adr/0015-raise-the-terminal-app-when-open-cannot-reach-the-exact-target.md) and its amendment are built for Ghostty's title route (Codex and Claude) and for herdr panes. The decision rules are pure SteerCore functions (`OpenFallback`, `GhosttyTitleOpen`, `HerdrOpenFallback`) over observations SteerApp passes in; `TerminalApps` in SteerApp walks processes, checks whether an app is running, and activates it.

- **Falls back** (raises the app, silently): zero or several Ghostty terminals carrying the title, two live sessions rendering one title, a split tab, a Claude tab outside the front window, a selection Ghostty refused, or a selection that did not verify. For herdr: a split, several clients, a client in a terminal that is not enabled (a client in another enabled terminal is joined to its tab by tty since #241), colliding panes or titles, a Ghostty without `tty` outside ADR 0011's sole-terminal rule, a pane focus or verification that failed, and a verified pane whose Ghostty tab could not be raised or verified (the pane focus is kept).
- **Stays unavailable** with its reason: Ghostty running but unreadable or not answering the selection; the session no longer live; herdr's socket missing or untrusted, herdr not found, an unsupported protocol, a stale Claude integration; herdr's or Ghostty's switch keeping Steer from contacting herdr; a closed or unidentified pane; a client tty that cannot be joined. In the interim, herdr sessions show herdr's existing grouped card line for these, and a Codex session with Ghostty switched off keeps its "Set up Ghostty" button; both stay until product.md's "Open unavailable" card table is built, which this ticket does not own. If macOS does not activate an app that is still running, the click reports "Steer couldn't bring <app> forward." rather than claiming it isn't running.
- **Which app:** Codex in Ghostty — the terminals in Ghostty's own inventory carrying the title are the amendment's candidates, all in Ghostty, because Ghostty still binds by title alone (ADR 0013) until it exposes `tty` (#251); no candidate means the app cannot be identified. Claude — a walk from the registry PID to the nearest app bundle (`X.app/Contents/MacOS/…`), even when Ghostty is switched off. herdr — a walk from every attached client; all must reach the same app. A Codex session whose walk reaches a switched-off app cannot be identified; a Claude one still falls back. The rule for candidates in different apps (latest tty modification time wins; any two within one second, or an unreadable time, cannot be identified) is in `OpenFallback.codexApp` and waits for a second enabled host to feed it walks and tty times (#235).
- **Ghostty not running** counts as an empty inventory (ADR 0013): Codex cannot be identified, Claude follows its process. Steer activates only a running app, never launches one, and never picks a window or tab.
- **What a fallback is not:** it acknowledges nothing, clears nothing and is never an input target; question keys still need the exact unsplit tab or bound pane. An Open on an actionable approval still hands it back with no decision. The click shows no message; unavailable cases show the agreed card line.

Automated coverage: `OpenFallbackTests`, `GhosttyOpenTests`, `HerdrOpenFallbackTests` and the updated `HerdrPresentationTests`. Not run — needs live acceptance: G4 (split Ghostty tab raises Ghostty) and §3d H5/H8 and the cross-host recency line in [MVP acceptance](mvp-acceptance.md).

## One Open sequence and visit rule (#237)

[ADR 0016](adr/0016-open-and-acknowledge-visits-the-same-way-on-every-terminal-host.md) is built for Ghostty's title route (Codex and Claude) and herdr panes. The rules are pure SteerCore functions over scans SteerApp takes and dates; SteerApp reads hosts, asks macOS which app is frontmost (`TerminalApps.frontmostHost`) and schedules checks.

- **Open sequence:** `TerminalOpenSequence` runs revalidate → (multiplexer only) focus and verify the pane → select and raise the host tab → verify, each step once, stopping at the first failure with no retry or rollback. The pre-Open time is read just before revalidation. `GhosttyTitleOpen.run` and `HerdrOpenSequence` supply their steps; their typed failures go unchanged to the #236 fallback decision (`OpenFallback`, `HerdrOpenFallback`).
- **Visible:** `TerminalVisibility.ghostty` needs macOS to report Ghostty frontmost *and* Ghostty's selected tab in its front window; Ghostty's own answer alone is not enough. A session's tab must also still bind on the same inventory (`GhosttyVisitTargets`: ADR 0005 for Codex; complete Claude inventories, one live session, one unsplit tab in the front window for Claude). A herdr pane is visible when herdr focuses it and Ghostty shows its client's tab (ADR 0011's test, including its interim rule without `tty`).
- **Acknowledgment:** `TerminalVisitAcknowledgment` and `TerminalDwell`, through `TerminalVisitTracker` for Ghostty tabs and `HerdrVisitTracker` for herdr panes. A verified Open acknowledges completions that arrived before the pre-Open read; a fallback or unavailable Open never does. A manual visit needs one scan proving the target not visible and the next showing it visible, and acknowledges what arrived before the earlier scan. A completion that arrives while its target is visible is acknowledged once the target has stayed visible for five seconds after it arrived; a hidden or different target, a failed scan, or a gap of more than five seconds restarts the run. After any Open, the visit interval and dwell run start over: a scan or Ghostty check taken at or before the Open's end is ignored, even when it is delivered later (herdr scans run detached), so the interval spanning an Open, including a fallback that happened to raise the target's tab, is never a visit. Only completions are passed in; approvals, questions and reminders keep their resolution rules.
- **Scanning:** herdr's per-scan Ghostty inventory is taken only while macOS reports Ghostty frontmost and the focused pane holds a live or queued session (`HerdrVisitTracker.scan`), at most one in flight; otherwise the pane is not visible and Ghostty is not asked. Ghostty's own two-second inventory still runs whenever Ghostty controls are on, because session discovery and herdr binding read it; its visibility reading counts only while macOS reports Ghostty frontmost.

Behavior that changed on purpose (ADR 0016, "Acknowledgment"):

- **Codex in a Ghostty tab:** a tab selected at any scan no longer clears every queued completion. A switch to the tab (hidden in one scan, visible in the next) clears what arrived before the switch; a completion arriving while the tab is in front clears after five seconds; a restored completion in a tab already in front waits for a switch or dismissal.
- **Claude in a Ghostty tab:** the dwell rule now applies, so a completion arriving while its tab is in front clears after five seconds instead of staying until dismissed. The visit now needs this tab hidden in the earlier scan, not any change of selection.
- **herdr:** returning to Ghostty while the bound pane was already focused is now a visit (the earlier scan had the pane not visible). A pane focused in an earlier scan whose Ghostty half was not checked is still no visit. An Open restarts the dwell run.

Automated coverage: `TerminalVisitTests` (Open and fallback acknowledgment, visit interval, dwell at exactly five seconds and just under, short and interrupted visits, gaps, the Open reset, Ghostty's visible test), `TerminalOpenSequenceTests` (step order, single send, stop at first failure, Ghostty title route), `CLITests` (Claude tab binding for visits, the Codex and Claude changes above) and `HerdrOpenTests` (the herdr tracker: the frontmost check gate, and a scan or check started before an Open and delivered after it). Not run — needs live acceptance: §3d H3/H4 in [MVP acceptance](mvp-acceptance.md) on Ghostty and herdr, and the Ghostty G-lines for direct-return acknowledgment.

Build: `sh scripts/build-app.sh`. Tests: `swift test` (six tests), including real file-reader/queue reconstruction and title matching. Native navigation remains unverified in Ghostty because the agent's computer-use restriction still applies. This is a lab integration, not installation of global hooks or proof that sessions outside the connected lab are monitored.

CLI PermissionRequest hooks now publish the actual session/turn, command,
project, action, reason, and expandable tool input to the connected events
directory. Steer can write one atomic allow-once or deny record for that exact
request; the helper rejects mismatched, duplicate, late, and timed-out records.
The helper waits up to five seconds for the companion receipt; only then does
the 30-second clock start, including queued requests. Its 31-second decision
wait bound is independent of the notch refresh loop. If Ghostty focus is
focused, unknown, or unavailable, the app writes a no-decision handoff and
retains Open in Codex. Desktop requests hand back immediately so Codex keeps its
native prompt until the desktop transport and handoff policy are proven.

A Codex question in a CLI tab can be answered from the notch: the option's digit is relayed to
the matched terminal through Ghostty's `send key` scripting command, never through synthesized
keystrokes. See [user-input requests](user-input-requests.md) and ADR 0006.

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

Global ~/.codex/hooks.json registers an OtherApp helper for SessionStart, UserPromptSubmit, PermissionRequest, Stop and SessionEnd, separate from Steer's project hooks. The installed helper fails codesign verification (resources required by its signature are absent). Its read-only --help invocation terminates with signal 9 and no output. This reproduces a process exit without a normal status code; Codex 0.145.0's command runner obtains output.status.code(), which is absent for signal termination. This explains the corresponding warnings alongside successful Steer captures/decisions.

Steer's exact recorder/interpreter also passed ten isolated /bin/zsh -lc replays (all exit 0, no output, maximum 0.103 seconds), in addition to prior direct recorder replays. A proposed config removing only the five OtherApp entries was prepared under /tmp; the real config was not changed. Removing those hooks would disconnect the other app's Codex integration, so that choice is pending the user's approval. Impeccable hooks and Steer's project hooks are preserved.

## OtherApp removal authorized and applied

The user explicitly requested removing all OtherApp-related installation files. Removed its five global Codex hook entries atomically, preserving the two unrelated Impeccable handlers and all Steer project hooks. Moved both Latch apps, the installed helper/database/support folder, preferences, application scripts, old Xcode build copies and container Data directories to a recoverable Trash folder. No OtherApp processes or startup entries were found in the inspected locations.

macOS denied removal of `.com.apple.containermanagerd.metadata.plist` in the OtherApp and UI-test runner containers. Those protected metadata files and their container shells remain; ordinary application data was removed without changing permissions or bypassing that denial. New Codex sessions no longer have the broken helper configured; already-running sessions may retain previously loaded hooks. A fresh CLI runtime warning check has not yet run.

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
`/Users/dev/Steer/output/desktop-hook-lab`. Its rollout was
`/Users/dev/.codex/sessions/2026/09/12/rollout-2026-09-12T04-51-09-01a0923d-0a94-7de1-aa3a-641a86112456.jsonl`, with `session_meta` source
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

## Tab binding by tty across enabled hosts (#235)

[ADR 0013](adr/0013-bind-cli-sessions-to-terminal-tabs-by-tty.md)'s rules are in
`Sources/SteerCore/TerminalTabBinding.swift` as pure functions. SteerApp passes in each
host's inventory, the `ps -t` reads and the kernel read of Claude's registered process.

- **Inventory:** `TerminalHostInventory` per terminal host: `notRunning` (holds nothing),
  `unreadable`, or `tabs`, where each `TerminalTab` has the host's tab handle, tty, title
  and pane count. Only hosts whose switch is on are read, whatever is passed for the
  others. If an enabled host is unreadable or has no inventory yet, every session is
  `hostUnreadable`. A tab without a tty (Ghostty without `tty`) counts toward Codex title
  uniqueness but never binds under these rules (`ttyUnknown`).
- **Foreground:** `TerminalForegroundProcesses.parse` reads
  `ps -o pid=,stat=,comm= -t <tty>`. A process is in the foreground when its `stat`
  contains `+`, and its name is the basename of `comm`. A malformed row or more than 256
  rows makes the whole read unreadable.
- **Codex:** `TerminalTabBindingRules.codex` checks, in order: the session is among the live
  sessions and its shortened identifier is unique among them; exactly one enabled tab shows that title; the
  tab has a tty and one pane; exactly one foreground `codex` runs on that tty; and a second
  read finds the same tab, tty and title. Codex hook records are never read.
- **Claude Code:** `TerminalTabBindingRules.claude` starts from the one registry process
  (`unidentified` and `ambiguous` both fail). It requires the live PID's start time to
  equal the `procStart` Claude recorded, when Claude recorded one. That process's tty must
  be on exactly one unsplit enabled tab, and the PID must be in that tty's foreground
  group. The title is optional. A Steer Claude title for another session, or any
  shortened Codex identifier, vetoes the binding.
- **Hook identifiers:** both hook writers record `ITERM_SESSION_ID`, `TERM_SESSION_ID`
  and `WEZTERM_PANE` (`iterm_session_id`, `term_session_id`, `wezterm_pane`) for
  diagnostics only. They also record `ZELLIJ_PANE_ID` and `ZELLIJ_SESSION_NAME`.
  `TerminalHookIdentifiers.zellijPane` returns that pane only from a Claude Code record
  that carries both values, as ADR 0014's binding input. The tab rules take no hook
  identifier.
- **Ghostty** keeps ADR 0005's title-only matching (`GhosttyMatch`) until it exposes
  `tty` ([#251](https://github.com/r-curio/steer/issues/251)).

Automated checks: `TerminalTabBindingTests` covers a decoy with the same title, two
`codex` processes on one tty, one title in two hosts, a split tab, an unreadable or unread
host, a switched-off host, the second read, a Claude title veto, a `procStart` mismatch,
and hook identifiers deciding nothing outside Zellij. `SteerHook --self-test` checks the
recorded identifiers. iTerm2's inventory reader, the `ps -t` runner and the Open and visit
paths that call these rules are wired by #238 (below), Terminal.app's reader, Open and
typed replies by #239 (below), WezTerm's by #240 (below), tmux's panes by #241 (below), and Zellij's
panes, with the hook pane as a Claude binding input, by #242 (below).
Live application proof: none. Not run; needs live acceptance (MVP acceptance §3d per host).

## iTerm2 Open (#238)

iTerm2 sessions get Open, visits and a Settings card, and no typed input (ADR 0017). The
switch and card stay hidden (`TerminalHost.showsCard`) until [#243](https://github.com/r-curio/steer/issues/243)
records iTerm2's §3d run. Rules are pure SteerCore functions (`ITerm2.swift`,
`TerminalTabOpen.swift`); SteerApp runs the bundled `ITerm2.js`, `ps` and the Automation check
(`ITerm2Navigation.swift`, `Companion+ITerm2.swift`).

- **Inventory:** `ITerm2.js snapshot` lists every session's GUID `id`, `tty`, window id and
  tab session count, and the current window's current session. The title is
  `terminalWindowName`, else `terminalIconName`; the composite tab `name` and `jobName` are
  never read. A session is a tab whose pane count is its tab's session count, so a split never
  binds. `ITerm2Reading.parse` rejects the whole reply on any malformed part (bad GUID or tty,
  duplicate GUID, more than 512 sessions, over 2 MiB); a tab left with no sessions is skipped.
  A failed read of a running iTerm2 is `unreadable`; `not_running` holds nothing. The script
  checks `running()` first and never launches iTerm2.
- **Binding:** ADR 0013's rules, with `ps -o pid=,stat=,comm= -t` read only for tabs showing a
  tracked Codex title or on a Claude process's tty. Codex's title uniqueness counts Ghostty's
  tabs too while Ghostty is on (`TerminalHostInventory.ghosttyTitles`, no tty until #251); a
  Codex title found only in Ghostty goes to Ghostty's title route. Claude uses the process
  Claude's inventory names, with the `procStart` Claude registered compared against a fresh
  kernel read of the PID's start time, and binds only by tty; a Claude process on no iTerm2
  tab goes on to Ghostty's title route or the process walk as before.
- **Open:** `ITerm2Open.run` over `TerminalOpenSequence`: revalidate on two fresh inventories
  with `ps` between, then `select` (the script rechecks the GUID, the tty and a one-session tab,
  then selects window, tab and session and activates), then a fresh inventory and macOS's
  frontmost app must show the session visible, on the same tty, alone in its tab, and for Codex
  still titled. A select with no reply is "Steer can't read iTerm2. Check Settings › Terminals."
  only when a fresh consent check shows Automation denied; any other script error or timeout
  falls back (ADR 0016). A session gone is "This session has ended."; a refused or unverified
  select falls back. An unreadable inventory at revalidation stays unavailable. Binding
  reasons map to ADR 0015 in `TerminalTabOpen.route`. Only a verified Open acknowledges.
- **Fallback app:** Codex walks from each titled tab's single foreground `codex`
  (`TerminalTabOpen.codexCarriers`/`codexCandidates`, then `OpenFallback.codexApp`); Claude walks
  from its process. A tab with no `codex` to walk from, such as a decoy, leaves the app
  unidentified. iTerm2 runs shells under `iTermServer`; the live proof's hook ancestry showed
  `iTermServer-3.7.4` under `iTerm2`, so the walk should reach the app. When the server has been
  reparented to launchd (iTerm2 restarted while its sessions lived on), the walk reaches no app
  and Open shows "Steer can't tell which terminal this session is in." rather than assuming
  iTerm2 from its own inventory. Neither case has been run from Steer.
- **Visits:** every two seconds while iTerm2 is on and a CLI session is live or queued. A
  session is visible only while macOS reports iTerm2 frontmost; otherwise the scan records
  nothing visible, and iTerm2 is read only while a queued Codex question or completion needs
  its typed-input line kept current. `TerminalVisibility.iTerm2` plus the session's binding on
  the same reads feed a `TerminalVisitTracker`, reset after every Open.
- **Typed input (ADR 0017):** nothing is ever typed into iTerm2. While iTerm2 is on, a Codex
  session whose title an iTerm2 tab shows gets "Steer can't type into iTerm2. Reply in the
  session." in place of Ghostty or herdr question keys (`QuestionRelayRouting`'s `terminalHost`)
  and of the reply field's daemon reason (the typed route `hostCannotType(.iTerm2)`; the daemon
  route still wins when it holds the session); an unreadable or not yet read iTerm2 gives "Steer
  can't reach this session's tab. Reply in the session." (`ITerm2TypedInput.codexBlock`, from
  the latest scan). Immediately before Ghostty's question key, the shared
  `TerminalKeyRelayCheck` reads every enabled host other than Ghostty fresh (iTerm2,
  Terminal.app and WezTerm today), so a Ghostty decoy never gets a key while the real session is in iTerm2.
  With iTerm2 off nothing changes. herdr's key path hides its controls on the same block but has
  no fresh read at click time; Claude has no typed input to guard here.
- **Permission and card:** turning the switch on asks macOS as Ghostty does; a denial turns it
  back off with the denial line and Open Settings…; iTerm2 not running waits for its launch.
  The card shows the switch, Automation badge, status badge (Off, Not in use, Ready, Needs
  attention), problem lines (not found, Automation denied, unreadable), diagnostics (scan,
  typed input none, each session's last Open) and the footer "Steer returns to unsplit tabs;
  otherwise Open raises iTerm2."

Automated checks: `ITerm2Tests` (fixtures modeled on [the live proof](evidence/iterm2-live.md):
inventory, malformed and unreadable replies including titles of the wrong type, Codex decoy
and second read, Claude by tty, split, visible test with another app in front, Open steps and
their verification including denial versus other script errors, the route mapping, fallback
candidates including a failed walk, card lines, the typed-input block for a title in both
Ghostty and iTerm2, an unreadable iTerm2 and iTerm2 off, the process start read, and that
`ITerm2.js` compiles, never writes text and never reads `jobName`), plus `ClaudeInventoryTests`
for the registered `procStart` carried with the PID. Not run — needs live acceptance (#243): §3d H1–H9 and
the iTerm2 line in [MVP acceptance](mvp-acceptance.md), and the lab
`scripts/terminal-lab/iterm2_lab.py`, which drives a real iTerm2.

## Terminal.app: Open and replies (#239)

Built behind Terminal.app's switch, which stays hidden with its card until acceptance (#244). Pure rules are in `TerminalAppHost.swift`, `TerminalTabOpen.swift` and `TerminalTypedInput.swift`; SteerApp's `TerminalAppNavigation.swift` and `Resources/TerminalApp.js` send the Apple Events through the shared JXA runner (`GhosttyNavigation.request`) and consent check (`GhosttyAutomationPermission.check(target:)`), and `Companion+TerminalApp.swift` schedules them.

- **Inventory:** `TerminalApp.js` lists every scripting window front to back with each tab's `tty` and `custom title`; it never launches Terminal. `TerminalAppSnapshot.parse` is bounded (1 MiB, 512 windows, 64 tabs each, 1024-character titles) and refuses anything malformed. Each tab becomes one ADR 0013 tab whose handle is its window id, with one pane: Steer assumes Terminal's split view mirrors one tty, which is unverified (the live proof did not split a tab) and is a line for #244 to check. `ps -t` is read only for tabs titled with a shortened Codex identifier or on a Claude process's tty. Ghostty's titles (`TerminalHostInventory.ghosttyTitles`) and iTerm2's inventory are read beside Terminal.app while each is on, so a Codex title in two hosts counts as two candidates; iTerm2's Open reads Terminal.app beside it in turn.
- **Permission:** Ghostty's flow. Turning the switch on asks macOS (`AEDeterminePermissionToAutomateTarget`); a denial turns it back off; Terminal not running is asked again when it launches. An Automation denial (-1743) or any other failure while reading later keeps the switch on and marks Terminal.app unreadable, which leaves every session it could hold unavailable ("Steer can't read Terminal.app. Check Settings › Terminals.").
- **Ghostty question keys beside it:** Ghostty binds Codex by title alone, so while another terminal host's switch is on, a Ghostty key needs every such host read fresh (`TerminalKeyRelayCheck`, one generic check over the enabled hosts, iTerm2 included). The card offers no key while its latest read is missing, unreadable or denied (`QuestionRelayRouting`'s `unreadHost`), and the send re-reads it immediately before the key: an unreadable host, or one whose tab carries the session's title, sends nothing. A session another host holds is never relayed to Ghostty, whatever that host is. Open reads Terminal.app fresh before leaving a session to Ghostty's route; an unreadable Terminal.app is unavailable rather than left to Ghostty.
- **Open:** a Codex session whose title no Terminal.app tab carries goes on to iTerm2's cross-host Open or Ghostty's title route while either is on, and a Claude session whose process tty no Terminal.app tab holds goes on to iTerm2, Ghostty's title route or the process walk (`TerminalAppOpen.leavesToOtherRoute`). Claude's binding compares the `procStart` Claude registered with a fresh kernel read (`TerminalTTYReads.observation`). Otherwise ADR 0016's sequence runs once: revalidate (both inventories, `ps`, a second inventory) → set the tab-window's `frontmost` and `activate` (`raise`, which first rechecks the window id holds that one tab) → verify. A tab inside a window of several tabs, no unique match, or a split falls back; so does a raise finding the tab moved to another window, its window gained a tab, or its tty shown twice. Automation denied, an unreadable host, an ended session and a tab no window holds any more are unavailable; any other raise error, and a raise that does not verify, fall back. Binding reasons map through the shared `TerminalTabOpen.miss`. Codex's fallback walks each titled tab's single foreground `codex` (`TerminalTabOpen.codexCarriers`/`codexCandidates`) and uses tty recency (`OpenFallback.codexApp`); Claude walks its registry process.
- **Visible:** Terminal frontmost per macOS, its front window a one-tab window, and the window server listing that window on screen (`TerminalVisibility.terminalApp`). The two-second scan feeds `TerminalVisitTracker` for manual visits and dwell, and every Open resets it.
- **Typed input:** replies only, per [session replies](session-replies.md#typed-into-the-bound-tab-239). Codex questions in Terminal.app show "Answer this in Codex."

Automated: `TerminalAppTests` (fixture inventories from the live proof: binding, a decoy title, Claude by tty, an unreadable or switched-off host, Ghostty beside it, a multi-tab window, the visible test, Open plan, raise and verify, the sequence, fallback candidates, card lines) and `TerminalTypedInputTests`. Not run — needs live acceptance (#244): MVP acceptance §3d H1–H9 and the Terminal.app lines, and `scripts/terminal-lab/` (it drives the real Terminal.app).

## WezTerm: Open, replies and question digits (#240)

Built behind WezTerm's switch, which stays hidden with its card until acceptance (#245). Pure rules are in `WezTerm.swift`, `TerminalQuestionKeys.swift` and the shared `TerminalTabOpen.swift` and `TerminalTypedInput.swift`; SteerApp's `WezTermNavigation.swift` runs the binary and `Companion+WezTerm.swift` schedules it.

- **Binary and socket:** `wezterm` runs only from `/Applications/WezTerm.app/Contents/MacOS/wezterm` or the same path under `~/Applications`, never from `PATH`, always with `--no-auto-start`, and with an environment of only `HOME`, a fixed `PATH` and `WEZTERM_UNIX_SOCKET`. That socket is the one `~/.local/share/wezterm/gui-sock-<pid>` whose pid runs WezTerm's app; a stale socket is ignored, and two live instances are unreadable (`WezTermSocket.choose`). It is trusted only when `lstat` shows a Unix socket owned by the user with no group or other permission bits (`WezTermSocket.trust`); otherwise nothing runs and WezTerm is unreadable. Each run is bounded (3 s, 2 MiB of stdout). WezTerm needs no Automation access. The live proof used the socket without auditing its mode, so whether WezTerm's default socket passes this check is for #245 to see; if it does not, WezTerm stays unreadable and the card says its socket isn't private.
- **Inventory:** `list --format json`, parsed by `WezTermSnapshot.parse` (bounded: 2 MiB, 1024 panes, 1024-character titles; any malformed part, a duplicate pane id or a bad tty makes the whole read unreadable). Each pane becomes an ADR 0013 tab whose handle is its pane id and whose pane count is its tab's, so a split never binds. `ps -t` is read only for panes titled with a tracked Codex identifier or on a Claude process's tty. Ghostty's titles, iTerm2 and Terminal.app are read beside WezTerm while each is on, and Terminal.app's, iTerm2's and the Ghostty key's fresh reads include WezTerm in turn (`OtherTabHosts.wezTermRunning`, `CodexTabReads`, `Companion.freshInventories`), with `ps` for WezTerm's titled panes in Terminal.app's reads. Claude binds by tty, so an OSC 1 icon title hiding Steer's Claude title changes nothing.
- **Open:** a Codex session whose title no WezTerm pane carries goes on to Terminal.app, iTerm2 or Ghostty while one is on; a Claude session whose tty no WezTerm pane holds goes on to those or the process walk. Otherwise ADR 0016's sequence runs once (`WezTermOpen.run`): revalidate on fresh reads (`list`, `ps`, `list` again, and `list-clients`); plan only when the one client's `focused_pane_id` is in the target's window, since `activate-pane` cannot raise another window; then `activate-pane --pane-id` and activate WezTerm; then verify with fresh `list` and `list-clients` and macOS's frontmost app that the pane is visible, unsplit, on the same tty and, for Codex, still titled. A target in a window that isn't in front, several clients, no unique match or a split falls back; an unreadable host (including `list-clients`), an untrusted socket, an ended session and "no such pane" are unavailable; any other `activate-pane` error or a failed verify falls back. Fallback apps come from `TerminalTabOpen.codexCarriers`/`codexCandidates` and `OpenFallback`, as for the other hosts.
- **Visible:** WezTerm frontmost per macOS and the one client's `focused_pane_id` is the pane (`TerminalVisibility.wezTerm`); several clients or a failed read is unknown. The two-second scan feeds a `TerminalVisitTracker`, reset after every Open, and runs only while WezTerm is frontmost or a queued CLI question, completion or Claude outcome needs its line kept current.
- **Typed input:** replies per [session replies](session-replies.md#wezterm-240). Codex question digits are built (`TerminalQuestionKeys`, route `terminalRelay`) but off: `WezTermInput.questionDigitsProvenLive` is false until #245 shows a digit alone commits in WezTerm, and until then a Codex question whose title a WezTerm pane carries shows "Answer this in Codex." While WezTerm is on and running but not yet read, or unreadable, Ghostty and herdr keys are withheld (`unreadHost`).
- **Card:** switch, status badge (Off, Not in use, Ready, Needs attention), problem lines (not found in its fixed locations, socket not private, and otherwise the generic "Steer can't read WezTerm. Check Settings › Terminals.", with the exact reason such as several running copies in diagnostics), diagnostics (scan, the digit gate, each session's binding and last Open) and the footer "Steer returns to unsplit tabs in WezTerm's front window; otherwise Open raises WezTerm. Replies are typed into the exact pane." No Permission row. The not-found and socket lines' wording is this build's, not agreed product text.

Automated: `WezTermTests` (fixtures modeled on [the live proof](evidence/wezterm-live.md); one test also covers iTerm2's visit scan reading an enabled Terminal.app beside it, which #240 fixed: inventory and malformed replies, `list-clients`, the fixed binary and environment, socket choice and the owner-only trust check, unreadable reads, Codex decoy, second read, split, another host's title, Claude by tty under an icon title, the visible test, the Open plan for the front and a non-front window and extra clients, `activate-pane` outcomes, verify, the sequence skipping `activate-pane` for a non-front window, reply payloads and `send-text` arguments, delivery, the separate CR and no resend, the digit gate off and on, the digit's spend and fresh check, route merging, the Ghostty key's fresh WezTerm read, and the card lines). Not run — needs live acceptance (#245): MVP acceptance §3d H1–H9 and the WezTerm line, and `scripts/terminal-lab/wezterm_lab.py` and `wezterm_select_probe.py`, which drive the real WezTerm GUI.

## tmux: pane binding, two-layer Open and typed input (#241)

Built behind tmux's switch, which stays hidden with its card until acceptance (#246). Pure rules are in `Tmux.swift`, `TmuxTargeting.swift`, `TmuxInput.swift`, `MultiplexerHostTab.swift` and the shared `TerminalTabBinding.swift`, `TerminalTypedInput.swift` and `TerminalQuestionKeys.swift`; SteerApp's `TmuxRunner.swift` runs the binary and `Companion+Tmux.swift` schedules it. tmux is contacted only while its switch and a terminal are on (`TerminalHostSwitches.mayContact`).

- **Binary and socket (ADR 0014):** `tmux` runs only from `/opt/homebrew/bin`, `/usr/local/bin` or `/usr/bin`, never from `PATH`, always as `tmux -S <default socket> -N …` with an environment of only `HOME`, a fixed `PATH` and `LANG`, so `$TMUX`, `-L` and `-S` sockets are never used and no command starts a server. The default socket is `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default` resolved as tmux resolves it (`TmuxDefaultSocket`). It is read only when `lstat` shows the directory and the socket owned by the user with no permission bit for others (tmux's own directory rule; the default socket is `0660`), and a connection's `getpeereid` shows the server runs as the user (`TmuxSocketTrust`). No socket, or a refused connection, is not running (holds nothing); an untrusted socket, a missing binary beside a socket, a failed command or a malformed listing is unreadable. Each command is bounded to two seconds.
- **Inventory:** `list-panes -a` and `list-clients` in Steer's own `|`-separated formats with the title last (`TmuxListing`), parsed by `TmuxSnapshot.parse` (4 MiB, 1024 panes, 256 clients, 1024-character titles; any malformed row makes the read unreadable). Each read also records the server's `#{pid}|#{start_time}` (`TmuxServerIdentity`) and each client process's ancestry from the kernel. Each pane becomes an ADR 0013 tab whose handle is `%pane`, whose tty is `pane_tty` and whose pane count is `window_panes`; tmux is part of `TerminalHost.ttyBound`, so Codex binds a pane by its exact title, one foreground `codex` on its tty, a second read and uniqueness across every enabled host, and Claude by its registry process's tty. An enabled, unreadable tmux leaves every session unavailable, and every host's fresh reads include it (`TerminalTabReads`, `CodexTabReads`, `WezTermTabReads`, `Companion.freshInventories` and the Ghostty key's `TerminalKeyRelayCheck`). ADR 0014's title-count rule is applied in every host's Codex binding: a terminal tab whose tty is a tmux client's `client_tty` is left out of the count (`multiplexerClientTTYs`).
- **Layout (`TmuxLayout`):** the pane is listed once (a grouped or linked session is unavailable), alone in its window, and not nested: no client of its session runs on a tmux pane's tty, and each client's ancestry is readable and has no `tmux`, `herdr` or `zellij` process above the client (herdr and Zellij list no pane tty, so ancestry is the only sign). Open also needs exactly one attached client on the pane's own session, not a control-mode client; Steer never moves a client to another session.
- **Open (`TmuxOpen.run`, ADR 0014's sequence):** a Codex title or Claude tty that no pane of the default server carries goes on to WezTerm, Terminal.app, iTerm2 or Ghostty; a server that is not running does too. Otherwise: revalidate both layers on fresh reads of every enabled host (binding, layout, client, and the client tty's join to exactly one unsplit tab across the enabled terminals, `MultiplexerHostTab.join`, Ghostty without `tty` decided by ADR 0011's own join), `switch-client -c <client_tty> -t %pane` once, verify on a fresh read that the same client shows the pane, then raise and verify the host tab with that host's own Open (iTerm2's select, Terminal.app's frontmost tab-window alone in its window, WezTerm's `activate-pane` in the focused window, or Ghostty's tty-checked selection). Steer reports Opened only when both verifications pass. A layout, client or join miss falls back; a failed focus or pane verification falls back without touching the host tab; a host-tab failure after the pane verified is a partial reach, keeping the pane focus; an unreadable tmux or host stays unavailable. The fallback walks every client of the pane's session to its app (ADR 0015).
- **Sends (`TmuxRunner.send`):** `switch-client` and every `send-keys` go out only after the socket passes its trust checks again and `display-message` shows the same server identity the fresh check read; a restarted server, which reuses pane ids, gets nothing and nothing counts as written.
- **Visible (ADR 0016):** the frontmost enabled host's visible tab (by its own test: iTerm2's current session, Terminal.app's front tab-window, WezTerm's focused pane, Ghostty's selected terminal with `tty`) runs the one client whose current pane is the bound pane (`MultiplexerHostFront`, `TmuxVisibility`). The two-second scan feeds a `TerminalVisitTracker` by `%pane`, reset after every Open. A Ghostty without `tty` cannot say which tab is in front, so a tmux pane hosted there is never visible until #251.
- **Typed input (ADR 0017):** replies per [session replies](session-replies.md#tmux-241). A send needs only the pane layer (nesting included), `pane_in_mode` 0, a live pane and input on (`TmuxLayout.inputLayer`), so copy mode makes the route unreachable before every write. A session that a control-mode client (iTerm2's `-CC`) shows gets no typed input or digits either, as its Open falls back: the current conservative choice, pending a product decision. Text whose last character is `;` is sent with that `;` escaped as `\;` (`TmuxInput.literal`), because tmux otherwise takes it as a command separator. Codex question digits go through the shared route (`TerminalQuestionKeys`, `terminalRelay`) as one `send-keys -t %pane -l -- <digit>`, never Enter, but are off: `TmuxInput.questionDigitsProvenLive` is false until #246 shows a digit alone commits in tmux, and until then a Codex question whose title a tmux pane carries shows "Answer this in Codex." While tmux is enabled but unread or unreadable, Ghostty and herdr keys are withheld (`unreadHost`).
- **Card (hidden):** switch, status badge and problem lines: "Turn on the terminal you run tmux in." (no terminal on); "Sessions seen on a socket other than the default can't be reached." (product.md), shown while a live Claude session's process descends from a `tmux` process yet no pane of the default server has its tty (`TmuxPresentation.otherSocketSeen`; a card line only, never a binding input); not found in the fixed locations, in WezTerm's pattern; "Steer can't read tmux's default socket. Check that it runs as you." for an ownership failure only; and the shared "Steer can't read tmux. Check Settings › Terminals." for any other failed read. No Permission row. The not-found and ownership lines are this build's wording, not agreed product text.
- **herdr in any enabled host (ADR 0014):** herdr's client verdict accepts a client whose ancestry reaches any enabled terminal and records which (`HerdrScanRequest.clientHostCommands`, `HerdrAttachedClient.host`); its Codex gate reads Ghostty's inventory while Ghostty is on, and otherwise the latest iTerm2, Terminal.app and WezTerm scans' titles (`HerdrHostTitles`); an Open whose client walks to iTerm2, Terminal.app or WezTerm joins that tab by tty (`HerdrHostOpen`) and raises it with that host's Open after ADR 0011's pane focus and verification. With Ghostty alone every rule, card line and the Ghostty Open sequence are unchanged. herdr visits are built only for a Ghostty-hosted client: a client in another host's tab is never visible, so its completions are acknowledged only by a verified Open or dismissal until those visits are built.

Automated: `TmuxTests` (fixtures of saved `list-panes`/`list-clients` output shaped after [the live proof](evidence/tmux-live.md): parsing and malformed or oversized output, a title containing the separator, grouped sessions, the default socket path, the trust check and the fixed binary, unreadable and not-running reads, the Codex decoy, the client-tab title exclusion, an unreadable or unread tmux, a split, Claude by tty, the pane layer, nesting by tty and by herdr, Zellij or tmux ancestry or an unread ancestry, copy mode, input off and a control-mode client, client counts, the host-tab join across hosts including WezTerm and Ghostty without `tty`, the Open plan, `switch-client` arguments and outcomes, pane verification, partial reach, the sequence stopping at the first failure, `send-keys` arguments with the trailing `;` escape, delivery, the server identity check, the reply route and copy-mode veto, the digit gate and its fresh check, the visible test, each host's front tab, and the card lines) and `HerdrHostTabTests` (herdr's Ghostty-only default, other hosts' clients and the host the verdict names, no Ghostty visit for a client in another host, the gate's titles including WezTerm's, the host-tab plan and pane verification). Not run — needs live acceptance (#246): MVP acceptance §3d H1–H9 and the tmux line inside iTerm2, Terminal.app and WezTerm, and `scripts/terminal-lab/tmux_lab.py`, which drives the real WezTerm GUI, Codex and Claude even though its tmux server is isolated.

Lab evidence (source checks, not Steer code paths): an isolated tmux 3.8 server on a private `-S` socket in a fresh temp directory, started with `-f /dev/null` and a clean environment, then killed and removed; no user server or configuration was read. With a client attached through `script(1)`: `list-panes -a -F` and `list-clients -F` in `TmuxListing`'s formats printed the expected 11 and 5 `|`-separated fields (a session grouped with `new-session -t` listed each pane once per session); without a UTF-8 locale tmux printed a tab separator as `_`; `-N` did not stop commands reaching a running server; `switch-client -c <tty> -t %pane` moved the client and `list-clients` read it back, a pane in another session moved the client across sessions, and an unknown client exited 1 ("can't find client"); `send-keys -l -- -hello` typed `-hello`, a separate `Enter` submitted, and `-l -- "one\r"` typed and submitted in one call; `send-keys` to `%999` exited 1 ("can't find pane"); `display-message -p '#{pid}|#{start_time}'` printed both. A trailing `;` was lost (`abc;` typed `abc`, `;` typed nothing, both exiting 0), while `abc\;` typed `abc;`, `\;` typed `;`, `a\\;` typed `a\;` and `a;b` typed `a;b`. The copy-mode hang of the live proof was not reproduced or explained.

## Zellij: pane binding, two-layer Open and typed input (#242)

Built behind Zellij's switch, which stays hidden with its card until acceptance (#247). Pure rules are in `Zellij.swift`, `ZellijTargeting.swift`, `ZellijInput.swift`, `MultiplexerHostTab.swift` and the shared `TerminalTabBinding.swift`, `TerminalTypedInput.swift` and `TerminalQuestionKeys.swift`; SteerApp's `ZellijRunner.swift` runs the binary and `Companion+Zellij.swift` schedules it. Zellij is contacted only while its switch and a terminal are on (`TerminalHostSwitches.mayContact`).

- **Binary, version and sessions (ADR 0014):** `zellij` runs only from `/opt/homebrew/bin` or `/usr/local/bin`, never from `PATH`, with an environment of only `HOME`, a fixed `PATH`, `LANG` and `TMPDIR` set to the user temporary directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`), so no inherited `ZELLIJ*` variable or custom `ZELLIJ_SOCKET_DIR` is used. `zellij --version` must report 0.44.1 or later (`ZellijVersion`). Steer lists `<user temporary directory>/zellij-<uid>/contract_version_1` itself (`ZellijSocketDirectory`), never running `zellij list-sessions`: the directory must be owned by the user and closed to others, its parent not writable by others, and each socket entry a socket owned by the user with no group or other bits (`ZellijSocketTrust`). Every read and every send (`focus-pane-id` and writes included) starts with a fresh listing of that directory and Steer's own connection to each socket (`ZellijReader`): a server running as another user (`getpeereid`, shared with tmux) is untrusted, and a socket that refuses stops the read before any `zellij` command runs (below); a session name that could be read as an option or carries a control character is unreadable (`ZellijSessionName`). Each session is then read with `--session <name> action list-panes --json --all`, `list-tabs --json` and `list-clients` (`ZellijSession.parse`: 4 MiB per listing, 1024 panes, 256 tabs, 64 clients, 1024-character titles; any malformed listing makes the read unreadable). The process table (`ps -axo pid=,ppid=,uid=,tty=,comm=`, with each `zellij` process's arguments and start time read from the kernel) gives each session's `zellij --server <directory>/<name>` and its identity, the user's own `zellij` client processes (a `zellij` of the current uid with a controlling tty that is not `--server`) and ancestry (`ZellijProcessTable`). No session directory, or no binary and no socket accepting, is not running (holds nothing, so a leftover socket file blocks no host's binding); a live session with the binary missing, an untrusted directory or socket, a refusing socket beside an installed Zellij, a failed command, a malformed listing or an unreadable version is unreadable, with the exact reason in diagnostics only (`ZellijUnreadable`); an installed CLI older than 0.44.1 is unreadable while any `zellij` process runs and holds nothing otherwise. Each command is bounded to two seconds. A renamed session keeps its server's original `--server` path, so its server is not found and its panes do not bind until that session restarts.
- **Fail closed beside a stale socket:** on a private socket directory, `zellij --session <name> action list-clients` deleted another socket in the same directory that refused connections, as `list-sessions` does (isolated Zellij 0.45.1 run). ADR 0014 bans `list-sessions` so that reading never changes the user's Zellij state, so Steer runs no `zellij` command at all, reads and sends alike, while any socket in the default directory refuses its connection: the read is unreadable (`ZellijUnreadable.staleSocket`), the card shows only the agreed "Steer can't read Zellij. Check Settings › Terminals." line, and the stale-socket detail appears in diagnostics only. Every session Zellij could hold stays unavailable until the stale socket is gone (Zellij itself removes it the next time the user runs a `zellij` command). Whether to amend ADR 0014 to accept Zellij's own sweep instead is an open product question.
- **Inventory and Codex binding:** each terminal pane (never a plugin, whose numbers collide with terminal panes) is an ADR 0013 tab with no tty, handle `<session>/terminal_<n>` and its tab's visible pane count (`list-tabs`' selectable tiled panes, plus floating panes while shown). Zellij is in `TerminalHost.titleCounted`, so its titles count toward every host's Codex title uniqueness, an unreadable Zellij leaves every session unavailable, and every host's fresh reads include it (`TerminalTabReads`, `CodexTabReads`, `WezTermTabReads`, `Companion.freshInventories` and the Ghostty key's `TerminalKeyRelayCheck`). The shared rule's only titled match in Zellij reads `ttyUnknown(.zellij)`; `ZellijBindingRules.codex` then requires that pane's `pane_command` to start with `codex`, a `codex` process whose ancestry reaches that session's server, a second read showing the same pane with the title, and the pane alone and tiled in its tab. The terminal tab of a Zellij client process (titled `<session> | <pane title>`) is left out of the title count with tmux's clients (`multiplexerClientTTYs`).
- **Claude binding:** `ZellijBindingRules.claude` reads the session's newest Steer hook records (`HerdrHookPaneRecord.zellijPane`, from `TerminalHookIdentifiers.zellijPane`): none, or none naming a Zellij pane, or a registered process with no Zellij server above it, leaves the session to the other hosts' rules. Otherwise the records must agree, the registry process (with `procStart`) must run under the recorded session's server, the recorded pane must be a terminal pane of that session, alone in its tab, and a pane title naming another session vetoes. The title is not required.
- **Layout and clients (`ZellijLayout`):** a live terminal pane, alone and tiled in its tab, under its session's one server, with no `zellij` client process nested in another multiplexer (a `tmux`, `herdr` or `zellij` process above it, or an ancestry that cannot be read). tmux's check already treats a `zellij` above a tmux client as nested. Open also needs exactly one client in the session's `list-clients` and exactly one `zellij` client process for the user.
- **Open (`ZellijOpen.run`, ADR 0014's sequence):** a Codex title no Zellij pane carries, or a Claude session Zellij has nothing to say about, goes on to WezTerm, Terminal.app, iTerm2 or Ghostty, as does everything while no Zellij session runs. Otherwise: revalidate both layers on fresh reads of every enabled host, join the client process's tty to exactly one unsplit tab across the enabled terminals (`MultiplexerHostTab.join`; Ghostty without `tty` by ADR 0011's own join) whose title starts with `<session> | ` (the veto; for Ghostty it is checked on the terminal Ghostty's join chose), `focus-pane-id terminal_<n>` once, verify on a fresh read that the same server, client and client process remain and the client now focuses the pane (an "already focused" exit 2 counts only if this passes), then raise and verify the host tab with that host's own Open. A Zellij client that has not typed yet does not move (zellij-live.md), so that Open fails its verification and falls back. Steer reports Opened only when both verifications pass. Failures resolve as tmux's do; the fallback walks every `zellij` client process to its app (ADR 0015).
- **Sends (`ZellijRunner.send`):** `focus-pane-id` and every write go out only after a read taken just before them shows the bound pane still a live, single, tiled terminal pane of its session under the server identity the fresh check read (`ZellijInput.writeAllowed`), because `write-chars --pane-id` to an unknown pane exits 0 having written nothing.
- **Visible (ADR 0016):** the frontmost enabled host's visible tab runs the one `zellij` client process, exactly one session lists exactly one client, and the pane that client focuses passes the pane layer (`ZellijVisibility`). The two-second scan feeds a `TerminalVisitTracker` by pane handle, reset after every Open.
- **Typed input (ADR 0017):** replies per [session replies](session-replies.md#zellij-242). A send needs only the pane layer. Codex question digits go through the shared route (`TerminalQuestionKeys`, `terminalRelay`) as one `write-chars --pane-id terminal_<n> -- <digit>`, never a carriage return, but are off: `ZellijInput.questionDigitsProvenLive` is false until #247 shows a digit alone commits in Zellij, and until then a Codex question whose title a Zellij pane carries shows "Answer this in Codex." While Zellij is enabled but unread or unreadable, Ghostty and herdr keys are withheld (`unreadHost`).
- **Card (hidden):** switch, status badge and problem lines: "Turn on the terminal you run Zellij in." (no terminal on); "Zellij is older than 0.44.1." and "More than one zellij client process is running." (product.md's two Zellij problems, phrased as sentences by this build); not found in the fixed locations, in WezTerm's and tmux's pattern; and the shared "Steer can't read Zellij. Check Settings › Terminals." for an untrusted directory or any other failed read. No Permission row. The not-found line, the sentence wording of the two Zellij lines, the footer ("Steer returns to a pane alone in its tab, with one Zellij client, in Zellij's default socket directory; otherwise Open raises the terminal running Zellij. Replies are typed into the exact pane.") and the status details ("Steer never scans or contacts Zellij.", "Fix each item below.", "Zellij's default socket directory is readable.", "No Zellij sessions seen.") are this build's wording, not agreed product text.

Automated: `ZellijTests` (a fake of Steer's effects showing that a refusing socket beside an accepting one runs no `zellij` command for a read or a send, that all-accepting sockets read and send normally, and the binary, version and trust outcomes; fixtures of saved `list-panes --json --all`, `list-tabs --json` and `list-clients` output shaped after [the live proof](evidence/zellij-live.md) plus verbatim output from an isolated Zellij 0.45.1: parsing, plugin ids reusing terminal ids, malformed and oversized output, the version floor, the socket directory and its trust check, session names, the fixed binary, the process table, server identity and the user's own client processes, the inventory and client ttys, read states, the Codex binding with the decoy, the pane command, the server ancestry, the second read and a split or visible floating pane, cross-host title uniqueness, an unreadable Zellij and Ghostty's fresh-read veto, the Claude binding by hook pane and ancestry and each disagreement, the pane layer and nesting both ways, client and client-process counts, the Open plan with the host-title veto (Ghostty's included), its ADR 0015 mapping, `focus-pane-id` outcomes and the already-focused case, pane verification, partial reach, the sequence stopping at the first failure, `write-chars`/`write` arguments, the pane recheck before every write, delivery, the reply route, the digit gate and its fresh check, the visible test, the host-tab join and the card lines). Not run — needs live acceptance (#247): MVP acceptance §3d H1–H9 and the Zellij line inside iTerm2, Terminal.app and WezTerm, and `scripts/terminal-lab/zellij_lab.py`, which drives the real WezTerm GUI, Codex and Claude even though its Zellij session is isolated.

Lab evidence (source checks, not Steer code paths): an isolated Zellij 0.45.1 background session (`attach --create-background`) with a private `HOME`, `TMPDIR`, config directory and a relative `ZELLIJ_SOCKET_DIR` under a scratch directory, killed with `kill-session` afterwards; no user session, socket directory or configuration was touched. It confirmed the JSON keys `ZellijSession.parse` reads (`pane_command` on terminal panes only, a suppressed `zellij:link` plugin reported selectable, `list-tabs`' `selectable_tiled_panes_count`), the `list-clients` header with no client, that pane processes are children of `zellij --server <socket path>` with their own ttys, that `write-chars --pane-id terminal_0 -- "-dash; echo semi;"` typed the text exactly, that `write-chars` to `terminal_999` exited 0, that `focus-pane-id terminal_99` exited 2 ("Pane with id Terminal(99) not found"), and the socket deletion above.

## Open unavailable lines on terminal cards (#267)

product.md's "Open unavailable" table, for Codex and Claude CLI cards outside herdr (herdr keeps its own lines). Pure rules are in `TerminalOpenAvailability.swift`; SteerApp's `Companion+OpenAvailability.swift` schedules the reads and `NotchView` renders the line.

- **Scan:** every three seconds (`openAvailabilityInterval`) while such a card other than running work is queued (running cards are classified alongside), one at a time, never during an Open and not before the first reminder scan has set the live Codex sessions. It reads the hosts Steer may contact through `CodexTabReads.read`, the reads the iTerm2 Open's revalidation takes, in `TerminalTabReadAssembly`'s order: every enabled host, `ps` for every tab or pane of a tty-listing host showing a queued Codex title or on a queued Claude tty, then every enabled host again. With Ghostty alone on it reads nothing and reuses the inventory Ghostty's own two-second scan took (no older than `openAvailabilityGhosttyMaxAge`, six seconds). The host scans' inventories are not reused otherwise: the binding needs both inventories and `ps` from one pass. It is skipped while Ghostty controls await Automation or while iTerm2's or Terminal.app's switch is on with consent not yet settled, so a scheduled read never raises macOS's prompt; a skipped scan leaves every card offering Open.
- **Route (`TerminalOpenScan`):** picked in the order a click tries routes past herdr: tmux (a pane carries the Codex title or the Claude tty, or tmux is unreadable), Zellij, WezTerm and Terminal.app unless they leave the session to another route (`TerminalAppOpen.leavesToOtherRoute`), iTerm2, then Ghostty's title route (Codex) or iTerm2's tty binding, Ghostty's title route and the registry process (Claude). Shared with a click: `TerminalTabBindingRules`, `ZellijBindingRules`, `TerminalTabOpen.route`, `TmuxOpen.plan`, `ZellijOpen.plan`, `GhosttyTitleOpen.revalidate`, `OpenFallback` and, with the iTerm2 Open, the read assembly. Not shared: the other hosts' click reads (`TerminalTabReads`, `WezTermTabReads`), which differ in detail; a host's own plan for a bound tab, its select, verify and activation, so a bound target offers Open. A miss is resolved by `OpenFallback` from walks the scan takes off the main actor (each titled tab's `codex`, a Claude registry process, a multiplexer's clients) and tty times: a fallback whose app is identified and running offers Open with no line (ADR 0015); anything else is its `OpenUnavailableReason.cardLine`. A Codex session no enabled tab carries, whose title a switched-on terminal app showed last (`lastSeenHosts`), reads "<app> isn't running." while that app is not running (H7); a switched-off app is never named (H8). A click on such a session would still say "Steer can't tell which terminal this session is in.", since the click's fallback does not consult `lastSeenHosts`; the scan hides Open there, so the click is not offered. A Claude registry process that is gone reads "This session has ended."
- **Click:** every terminal Open records its result on its card (`OpenUnavailableLines.recordOpen`). An unavailable result shows the same line on that card, beside Open, and the item stays. The line lasts until the session's next scan that started after the click (which swaps Open for its own line, or drops the line when Open is offered), a later Open of the session that opened or fell back, or the card leaving the queue. An Open that opened or fell back also makes any scan that started before it say nothing about that session. `navigationMessage` still carries the same text.
- **Card:** the line replaces Open with no disabled button; Dismiss, details, approve and deny, replies and question options keep their own routes. A Codex question whose option cannot be typed while the scan has replaced Open shows one line: "Answer this in Codex." followed by Open's line, and no separate typed-input sentence. VoiceOver reads "Open Session unavailable." (scan) or "Open Session did not open." (click) before the line. The line is static text, so Reduce Motion has nothing to change. The scan's exact internal reasons are not yet listed in a card's Show diagnostics.

Automated: `TerminalOpenAvailabilityTests` (each cause for iTerm2, Terminal.app, WezTerm, tmux and Zellij, Ghostty's title route, the Claude routes and herdr's unchanged lines; fallbacks offering Open with no line; the live #243 decoy; the shared read assembly `ps`-reading an iTerm2 tab; the H7 last-seen app; the click-to-scan swap, its clearing rules, a scan older than an Open that worked and the combined question line). Not run live: MVP acceptance §3d H5–H8 with the build under test.
