# Desktop activity integration

Herdly reads the metadata-only event records produced by the isolated desktop
hook lab. It never writes Codex settings, emits hook output, or starts a second
Codex runtime. `SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd` are
replayed through `HerdlyCore.DesktopEventReader` and `DesktopState`; CLI sessions
are excluded using their rollout source metadata, and a headless `codex exec`
run (rollout `source: "exec"`) adds no row of any kind (#409, see
[session discovery](session-discovery.md#headless-codex-exec-runs-through-the-hook-path--issue-409)). The recorded real desktop
session evidence in `docs/desktop-approval-investigation.md` identifies
session `01a08f51-a2fd-74c0-a9e9-d7e8a31c634c` as originator `Codex Desktop`,
source `vscode`. Its hooks were enabled after SessionStart, so the captured
UserPromptSubmit and Stop records prove a real desktop turn start/completion,
but do not claim full session-start capture. The original records are capture
`8bedf2d3-754c-4c00-8da4-635e14e82fe8` at 07:26:54.343057Z and
`b4baa09c-eb98-4cb9-b75c-9bd2f3405c24` at 07:26:57.252939Z. The original metadata-only records
stayed in the lab's ignored `output/desktop-hook-lab/events` directory; the redacted
pair in `Tests/HerdlyCoreTests/Fixtures/desktop-turn/` is replayable from a fresh checkout.

## Build and run

```sh
swift test
sh scripts/build-app.sh
open output/Herdly.app --args --desktop-events "$PWD/output/desktop-hook-lab/events" --reminder-rollouts "$HOME/.codex/sessions"
```

Use `--desktop-events "$PWD/Tests/HerdlyCoreTests/Fixtures/desktop-turn"` to replay the checked-in turn.

The `--desktop-events` path is an isolated replay override. The app reads it
off the main actor in the hook scan, on the timing set out in
[architecture](architecture.md) (`HookScanSchedule`). Existing completion records restore
silently; a newly observed completion expands the notch for the "Keep new cards
open" time (Settings › General, 3 seconds by default) and stays queued until it is
dismissed or the desktop app records it read ([desktop read state](desktop-read-state.md)).
The notch stays visible while Codex is in front; foreground changes acknowledge
nothing. Open in Codex sends the manually verified exact-task
`codex://threads/<session-id>` route, but successful native delivery is not
programmatic proof that the task was selected and never dismisses the completion.

For a deterministic local replay, place metadata-only records in a directory
and run the same command with that directory. Records must contain
`hook_event_name`, `session_id`, and `received_at`; turn events also need
`turn_id`. Malformed or oversized records are ignored.

## Evidence boundary

The state/replay checks are runnable in
`Tests/HerdlyCoreTests/DesktopActivityTests.swift`. The repository records the
isolated desktop hook-lab lifecycle experiment and real-session evidence in
`docs/desktop-approval-investigation.md`. This implementation consumes that
event shape without claiming permanent attachment or changing Codex
configuration. Reversible setup is Settings › Agents › Codex (the row's switch
runs Configure Codex; turning it off undoes it). A fresh real-session UI check
still requires the permitted human route described there.

## Codex background jobs (2026-10-08)

Codex runs memory consolidation as a session of its own, with the user's hooks.
Session `01a11757-16e6-7c91-b937-4e67f83d3163` sent `SessionStart`,
`UserPromptSubmit` and 51 tool records. They carried herdr pane `w1:p2`, the
pane in the managed app-server daemon's environment. Codex wrote no rollout for
it. Its log shows the thread shutting down at 01:17:18 local time with no `Stop`
or `SessionEnd` hook. Herdly therefore kept a desktop working row with no end. An
earlier run on 2026-10-07 did send `SessionEnd`, also without `Stop`.

`DesktopState` treats a session whose submitted prompt opens with Codex's
built-in heading `## Memory Writing Agent: Phase 2 (Consolidation)` as Codex's
own. That prompt adds no running row, and the session's later events add no
row or completion. Approvals and questions do not pass through `DesktopState`,
so they still appear. The heading is a constant in Codex CLI 0.154.0, 0.160.1
and 0.161.0 and in the desktop app's bundled CLI. If Codex changes it, the job
shows as working again rather than hiding a user's session. Codex 0.161's hook
schemas also offer optional `agent_id` and `agent_type` fields on
`UserPromptSubmit` and tool hooks. Their values for this job are not recorded,
so Herdly does not rely on them. Covered by
`aMemoryJobThatNeverSendsStopOrSessionEndIsNotLeftWorking` and its neighbours in
`DesktopActivityTests.swift`.

### Next-message suggestion (2026-10-21)

After each finished turn, the desktop app (bundled CLI 0.163.0-alpha.11) runs a
short session of its own to suggest the user's next message in the empty
composer. With thread `01a15cf2` open, sessions `01a15cf5`, `01a15cf6` and
`01a15cf9` each sent `SessionStart`, a `UserPromptSubmit` opening with
`This is an app-generated request for a suggested next user message.`, and
`Stop`, and wrote no rollout. Herdly queued each `Stop` as a completion named
only by its shortened session id. `DesktopState` now treats that heading like
the memory heading above. Covered by
`theDesktopNextMessageSuggestionIsNeverQueuedAsTheUsersWork`. A suggestion
completion already queued before this change stays until dismissed.

## Desktop installation

Probed 2026-09-11 (desktop 26.901.51231, bundled CLI 0.153.4). The desktop app is
`/Applications/ChatGPT.app`, bundle ID `com.openai.codex`. A second installation
(`~/Applications/Codex.app`) shared the same bundle ID, so the bundle ID alone does
not choose an installation: Herdly uses the running process's bundle path, and
`DesktopNavigation` refuses to send the `codex://threads/<id>` link when zero or
several installations are running. `python3 scripts/probe_desktop_process.py`
reports a unique running installation only when exactly one main process matches;
`python3 scripts/probe_codex_desktop.py` (with `--self-test`, and `--app <bundle>`
for another installation) reads bundle metadata and generates the bundled CLI's
protocol schemas in a temporary directory without connecting to any conversation.
A generated schema proves a protocol shape, not that a new connection can observe
or control the desktop's own tasks; Herdly never starts a second app server and
calls its loaded threads the desktop's conversations. No supported signal tells
which conversation is selected, so exact desktop conversation focus stays
deferred. Herdly does not inspect the Codex window's UI; in the 2026-09-11 probe
the computer-use tool refused access to `com.openai.codex`, and no other UI path
was tried.

## Completion notification demonstration (#8)

Controllable-clock tests cover a completion expanding for the card-open time
after it arrives, retaining the item after collapse, and restoring silently.
Queue tests cover duplicate lifecycle records, explicit dismissal, and a later
turn in the same session remaining independent. A Herdly-only walkthrough on
2026-09-12 showed the popup, collapse, retention and reopen with real desktop
completions rendered with Open in Codex and Dismiss; sound, a fresh CLI turn,
Ghostty and the Codex UI were not tested there.
