# Hook event retention — issue #109

Status: implemented and covered by automated checks. No live soak has been recorded yet.

Herdly's helper writes one JSON record per hook event into Herdly's own events directories: the Codex `events` folder and one `claude-events/<root>` folder per connected Claude root. Nothing else removes them. Codex alone produced about 10,000 records a day. Before this change, every reader refused a directory holding more than 4,096 entries, so after about a day of normal use Herdly showed no hook-driven status at all.

## Retention (app)

The app runs `HookEventRetention.prune` on the Codex events directory and on every configured Claude root's events directory, connected or not. It runs at launch and then every ten minutes, off the main actor. Preview and smoke-test runs skip it. Expired records are **deleted**, not archived. Age is the file's creation date.

| Record | Kept for |
| --- | --- |
| Tool records: `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch` | 1 hour. About 95% of the volume; readers use them only to label the current tool. |
| Every other Herdly record (session start/end, prompt, stop, permission request, …) | 7 days |

Retention never removes:

- **Open tool calls.** A `PreToolUse` with no completion for its tool id, no later `Stop`/`StopFailure` for its turn, and no later `SessionEnd` is kept for the full 7 days. A Claude question waits in such a record. A completion is kept while the call it completes is kept.
- **Records a handoff reminder depends on.** Approval request files (`.approval`), receipts and decisions are never deleted. A session with a request the reminder reader would still show keeps its non-tool records past 7 days, so the session end that resolves its reminder survives a restart. That covers `pending` or `no_decision` requests in either the current or the legacy reminder format, but not requests the user already decided.
- **Anything it cannot identify as Herdly's own record.** Malformed or foreign JSON, oversized files, symlinks, directories (including `.herdly-claude-questions`), and Claude approval rendezvous files stay. Abandoned `.herdly-*` temporary writes older than 7 days are removed.

The helper is unchanged: hooks stay fast and Codex-compatible output stays clean.

## Bounded reads

`HookEventListing` replaces the old all-or-nothing cap. A reader lists names and creation dates of up to 65,536 entries and fails closed beyond that. It then decodes only the newest 4,096 `.json` records. `DesktopEventReader`, `ClaudeObservationReader` and `ReminderReader` share this view.

- `ReminderReader` always reads every approval request file. When a request's session has no `SessionEnd` inside the window, it looks back through up to 4,096 older records, newest first, for that session's end only.
- Pruning runs every ten minutes and tool records expire after an hour, so the 4,096-record window normally spans days of session and turn records.
- If sessions together write more than 4,096 records in roughly 70 minutes, older records can still fall out of the window, though they remain on disk. Those records include a running turn's prompt, a CLI session's start, or a waiting Claude question's `PreToolUse`. That item then stops showing until newer records arrive.
- The session-end look-back repeats on every scan while a reminded session is still running. A scan then decodes up to 8,192 records.
- The Claude setup connection check (`ClaudeSetupInstaller.status`) lists entries within the same 65,536 bound but does not use the 4,096-record window. It decodes oldest first and stops at the first startup record that proves delivery, which normally sits near the front because startup records outlive tool-record retention. With no such record it decodes every listed entry. It runs off the main actor. Setup undo and the delivered-session scan still refuse a directory of more than 4,096 entries.
- Restart recovery is unaffected. Completions are restored from the attention snapshot, not from old hook records (see [restart recovery](restart-recovery.md)), and Claude readers ignore records captured before launch.

## Automated checks

Local gate on this branch: `swift test`, `sh scripts/build-app.sh`, `sh scripts/package-app.sh`, and `output/Herdly.app/Contents/MacOS/Herdly --smoke-test` all passed. These are build and smoke checks, not live operator acceptance.


`Tests/HerdlyCoreTests/HookEventRetentionTests.swift` covers:

- per-kind expiry
- open tool calls and Claude questions kept, interrupted and batched calls pruned
- lifecycle records of sessions with unresolved requests kept, including the legacy reminder format; decided requests protect nothing
- malformed, foreign, symlinked and non-record entries left alone, and stale temporary writes removed
- symlinked or missing directories refused
- Codex, Claude and reminder readers staying available above the old 4,096-entry cap with the current session visible
- a reminder's out-of-window session end still being found
- the listing bound failing closed

## Remaining limits

- Approval request, receipt and decision files are not pruned. They are low volume, roughly three files per CLI approval.
- One pass over an overgrown directory reads every record once. The 2026-10-07 machine held about 179,000 Codex records. Readers report that directory unavailable until the first pass finishes. Later passes see about a week of non-tool records.
- Tool-call closure is matched by session and tool id. Herdly trusts any record with its own source tag in its own directory, as the readers do.
