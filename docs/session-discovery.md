# Session discovery — issue #44

Herdly shows Codex sessions that were already working before it launched, or before their first hook event reached it, instead of waiting for the next hook. Like [thread names](thread-names.md) and the [weekly limit](codex-usage.md), this rides on a private Codex format and fails soft: a session it cannot place is simply not shown as working, and discovery never creates a completion, request, question, or sound.

## What Codex records

Every rollout under `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session id>.jsonl` opens with a `session_meta` line whose payload carries the session `id`, its `cwd`, and its `source`: `"cli"` for the terminal, `"vscode"` for the desktop app, `"exec"` for `codex exec`, and an object (`{"subagent":{"thread_spawn":…}}`) for a subagent thread. A turn begins with `{"type":"event_msg","payload":{"type":"task_started","turn_id":"…"}}` and ends with `task_complete` or `turn_aborted` for that `turn_id`. Every line written during the turn names it: event messages such as `item_completed` and `token_usage_record` carry `turn_id` in their payload, and response items carry it in `internal_chat_message_metadata_passthrough.turn_id`. A live turn keeps writing: a desktop thread that had been running for five hours while waiting on subagents was seen appending every minute. Observed with CLI 0.153.4 and desktop 26.901.51231.

## Herdly's rule

`SessionDiscovery.candidates` reads the 24 most recently modified rollouts from the newest day directories, skipping any not written within the last hour (`maximumAge`), any symlink, and any irregular file. For each it reads the first 64 KB for the `session_meta` line and the last 512 KB for turn events; a file smaller than that is read once. Only `cli` and `vscode` sessions are candidates: an `exec` run has no tab or thread to return to, and a subagent thread is Codex's own, not the user's.

`SessionDiscovery.open` takes the last turn any line names that no later `task_complete` or `turn_aborted` ended. This finds a long turn whose `task_started` line lies beyond the tail; its `startedAt` is then the earliest line seen for it, a lower bound on how long it has run, used only to order rows. A line written after an end seen in the same read (a trailing token count) does not reopen the turn; an end that itself fell just before the tail cut is not seen, so such a trailing line could name an ended turn until the next scan or the freshness bound clears it. A line that names no turn is skipped, including a partial line mid-append and the cut first line of a tail read.

`SessionDiscovery.running` decides which candidates are shown as working. A rollout alone never proves a session is alive, because a turn that died with its process leaves its start dangling:

- A desktop candidate needs the Codex desktop app running (`NSWorkspace`).
- A CLI candidate needs its session-ID title on a Ghostty tab right now (`GhosttyMatch.sessions`, when Ghostty controls are on and a snapshot is held) or, failing that, any Codex CLI process on this Mac (`CodexCLIProcesses` over `ps -axo args=`: an executable named `codex`, `codex.js`, or `codex-…` that is not an `app-server`, which is the desktop app's own backend). The process check is per machine, not per session; the one-hour freshness bound limits what it can misattribute.
- A SessionEnd hook recorded after the turn started rules the session out whatever else is running.

A discovered session enters the queue through `AttentionQueue.apply(discovered:)`, keyed by session and turn like hook-derived work, so a later hook event for it merges into the same row and never duplicates it; when a hook has reported the session's running turn in the same scan, the hook's row stands. Completion evidence for its turn ends the row and the discovered turn cannot revive it. Discovered sessions get the thread name and Open in Codex target rules of any other session: a CLI session is added to the live set so its Ghostty tab can be matched, and a desktop session opens by its thread link. The process check is the one deliberate looseness: the issue asked for a live process for that session, which needs the session's open files (`lsof`) and a proof that Codex holds its rollout open; until then the machine-wide check plus the freshness bound stand in, and a CLI session that died within the hour while another runs would show as working.

## App integration

Each two-second scan reads the candidates and the process list off the main actor alongside the hook events, rollouts, read state, names, and usage, then assembles `SessionLiveness` on the main actor from the desktop app's running state, the last Ghostty snapshot, and the scan's SessionEnd times. `--reminder-rollouts <path>` points a lab run at a copy of the sessions tree, as it does for reminders and usage. Restarts restore nothing here: discovery is re-derived from current evidence on every scan.

## Verification

Automated: `Tests/HerdlyCoreTests/SessionDiscoveryTests.swift` covers the real shapes for an open, ended, aborted, and reopened turn; the CLI, desktop, exec, and subagent sources; a partial tail and unreadable lines; inference of the open turn from later items when its start is beyond the tail, including a trailing line after the end; file selection by freshness with a refused symlink and a tail read of a large rollout; the liveness gate for each source and for SessionEnd; process-list recognition; Ghostty title membership; and the queue merge with a later hook event, completion evidence, and the no-notification rule.

Live: a check linked against `HerdlyCore` read `~/.codex/sessions` on the inspected machine in 45 ms and returned the two desktop threads whose turns were open, including the five-hour parent thread whose `task_started` was 30 MB before the tail, and excluded the subagent thread written at the same time. The full app walkthrough (start two sessions, launch Herdly, see both sprites, jump back to each) is still to be recorded.
