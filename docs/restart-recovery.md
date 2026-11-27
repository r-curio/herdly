# Restoring activity and acknowledgments after restart — issue #11

Status: implemented and checked against the built app in an isolated lab. Agreed behavior is in [product.md](product.md); the persistence shape is in [architecture.md](architecture.md).

## What is saved

`AttentionSnapshotStore` keeps one small JSON file, `~/Library/Application Support/Herdly/attention-snapshot.json`, containing only the completions the user has not dismissed and the completion identities they have (`AttentionSnapshot`, version 1). Nothing else is persisted:

- **Requests are never restored from the snapshot.** Their files in Herdly's events directory are the record, and the reader rebuilds them on every scan.
- **Running work is never restored.** Each scan rebuilds it from current hook records, so a session that ended while Herdly was quit cannot appear as running.
- No conversation text, titles, or transcripts. The pre-snapshot `cliAcknowledgments`/`desktopAcknowledgments` lists in UserDefaults are read once as a migration when no snapshot file exists yet.

Saves happen at launch (a checkpoint of what was restored, only when a snapshot file already exists) and whenever the snapshot content changes: after a scan, after Dismiss, and after a verified visit to a session's exact tab or pane on any terminal host ([ADR 0016](adr/0016-open-and-acknowledge-visits-the-same-way-on-every-terminal-host.md)). Each save writes a sibling temporary file and renames it over the destination, so an interrupted save leaves the previous snapshot intact; before the rename it copies the current file, if it is valid, to `attention-snapshot.json.previous`. A load that cannot decode the current file falls back to that previous one, so a corrupted or truncated snapshot loses at most the changes since the last save rather than every dismissal. The store reads only regular files up to 4 MiB, ignores symlinks, and refuses to replace a directory or symlink at its path. When both files are unusable the snapshot loads as empty and the app starts normally; the next save replaces it. The store never touches `~/.codex`.

## What restart does

1. **Completions restore silently and uncertain.** Every completion that arrived before this process started observing, whether it came from the snapshot or from hook records that arrived while Herdly was quit, is marked `uncertain`: the user may have viewed that result while nothing was observing. The queue decides this from the completion's arrival time against the process start, so a completion whose rollout evidence only matches on a later scan is still uncertain and still silent. The row says so ("Queued before Herdly last started. You may already have seen this result; Herdly cannot verify it.") and offers Open in Codex and Dismiss. The presentation for uncertain completions is created already presented, so no popup expands and no sound plays. A completion that arrived after launch is certain and presents with its sound once, even in the same session as an uncertain one; an uncertain arrival never silences a certain one already queued.
2. **Dismissals stay dismissed.** An acknowledged completion identity is skipped when the same hook records are scanned again. Acknowledgment is per completion, so a later turn in the same session is independently eligible. Desktop acknowledgment comes from Dismiss or from the desktop app's own read state ([desktop read state](desktop-read-state.md)); focus, navigation, and app activation are never inferred as visits, and terminal hosts keep their separately verified per-pane acknowledgment (ADR 0016).
3. **No saved approval record restores Approve or Deny.** `AttentionQueue` records the receipts this process issued (`recordReceipts(_:now:)`). A request the reader reports as actionable from a receipt on disk that this process did not write is entered as handed back and returned from `apply(scan:...)`; when a helper receipt file exists for it, the app writes a no-decision record at once so the helper releases the request to Codex's own prompt within its next poll instead of at its deadline. The row shows Continue in Codex with only Open in Codex. A request receipted by this process keeps its controls until its own 30-second deadline, unchanged. Connecting a different events folder rebuilds the queue from its own snapshot: completions are kept as uncertain, and receipts from the old folder are forgotten.
4. **Sessions reconcile from evidence.** A handed-back request still clears only on its recorded answer, the end of its exact turn, or the end of its session, as in [approval reconciliation](approval-reconciliation.md).

## Automated checks

`swift test` (87 tests). New in `Tests/HerdlyCoreTests/RestartRecoveryTests.swift`: snapshot round trip with no stray files; missing, corrupt, unknown-version, truncated, oversized, directory and symlink snapshots all loading as empty without a save through a symlink or over a directory; atomic replacement beside a leftover temporary file; a corrupt snapshot falling back to the previous good one so dismissals survive, and a corrupt file never becoming the backup; legacy UserDefaults acknowledgment lists migrating into a snapshot; a snapshot never carrying running work or requests; restored completions being uncertain, silent and independently dismissible while a dismissed one stays cleared and a later turn stays eligible; completions that arrived before observation being uncertain even when matched on a later scan while later arrivals are certain; a saved receipt alone yielding a handed-back row that is released exactly once; a receipt issued by the running process keeping its controls to its deadline; and running work rebuilt only from current evidence. `AttentionQueueTests` now distinguishes a reader-reported receipt from a live one.

## App-level lab (2026-09-12)

`scripts/restart_lab.py` drives the release `output/Herdly.app` with `--desktop-events`, `--reminder-rollouts` and `--attention-snapshot` pointed at a disposable directory, and `--restart-report`, which makes the app write its post-first-scan queue to JSON and quit. The recorded result is summarised in the table below; the raw lab record is not kept in the repo. No Codex configuration, hook, or real rollout was read or written; the lab's rollout stand-in hashed identical before and after.

| Run | Setup | Result |
| --- | --- | --- |
| A | Prior desktop completion records; a pending CLI request with a receipt from a previous run and no decision | Completion restored as uncertain, presentation already presented (no popup, no sound); request handed back with no controls; one `no_decision` record written; nothing running |
| B | Live completion arrives 3.5 s after launch; SIGKILL 4.5 s later | Snapshot on disk valid and holds both completions |
| C | Restart after the kill | Both completions restored, both uncertain, no replayed sound; request still handed back, nothing re-released |
| C2 | Snapshot edited as Dismiss would persist it (turn 1 acknowledged), restart | Only turn 2 returns; the launch checkpoint writes the previous-snapshot fallback |
| D | Snapshot truncated mid-object plus a leftover temporary file beside it | Ordinary startup; the fallback keeps turn 1 dismissed, turn 2 rebuilt from hook records; a valid snapshot written |
| E | Turn 2 acknowledged as well; a turn 3 completion arrived while quit | Both dismissed completions stay cleared; turn 3 returns, uncertain |

## Human check: viewing a result in Codex while Herdly runs hidden

Not performed by the agent: it requires the Codex desktop app's UI, which is outside the permitted automation. The state rules it exercises are covered by `AttentionTests` (a completion received while Codex is foreground stays queued and presents once when away) and by the checks above. Steps for the operator, with Herdly connected to the isolated desktop hook lab as in [desktop-live-integration.md](desktop-live-integration.md):

1. With Herdly running and Codex desktop foreground, finish a turn in the lab task while another thread is selected. The notch stays visible; the card does not pop and nothing plays while Codex is in front.
2. Switch to another app. The completion presents once with its sound and stays queued: Codex being in front did not acknowledge it. (Selecting the lab task's own thread in a focused Codex window would instead let the desktop read state acknowledge it.)
3. Quit Herdly from its menu, relaunch it, and switch away from Codex again. The same completion returns marked as possibly already seen, with no popup and no sound, offering Open in Codex and Dismiss.
4. Dismiss it, quit and relaunch Herdly: it does not return. A new turn in the same task still notifies.

## Boundaries

- Uncertainty is about observation, not read status: Herdly never claims a restored result is unread. Since 2026-09-14 the Codex desktop app's read state is a read signal for desktop threads ([desktop read state](desktop-read-state.md)), and restored desktop completions follow it like any other; CLI completions have no such signal.
- The lab drives hook records and snapshot files, not the Dismiss button or the desktop app; runs C2 and E stand in for the button by writing what Dismiss persists, which `restoredCompletionsAreUncertainSilentAndIndependentlyDismissible` covers end to end in process.
- The acknowledged set is not pruned; it grows by one identity per dismissal. A cap or age-out is deferred until it matters.
- Receipt liveness is defined as "issued by this process". A restart within a request's 30-second window hands it back a few seconds earlier than the helper would have; nothing is approved. If the no-decision record cannot be written, it is not retried: the helper still hands back at its own deadline, and the row already says only that Herdly has not seen an answer.
- `--attention-snapshot` and `--restart-report` are lab overrides compiled into the app alongside the existing `--desktop-events`, `--reminder-rollouts` and `--smoke-test` flags. They change nothing unless passed.
- The migration from the UserDefaults lists runs only when no snapshot file exists; the lab machine had legacy entries, which is why the recorded acknowledgment counts start above zero.
