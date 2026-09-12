# Restoring activity and acknowledgments after restart — issue #11

Status: implemented and checked against the built app in an isolated lab. Agreed behavior is in [product.md](product.md); the persistence shape is in [architecture.md](architecture.md).

## What is saved

`AttentionSnapshotStore` keeps one small JSON file, `~/Library/Application Support/Steer/attention-snapshot.json`, containing only the completions the user has not dismissed and the completion identities they have (`AttentionSnapshot`, version 1). Nothing else is persisted:

- **Requests are never restored from the snapshot.** Their files in Steer's events directory are the record, and the reader rebuilds them on every scan.
- **Running work is never restored.** Each scan rebuilds it from current hook records, so a session that ended while Steer was quit cannot appear as running.
- No conversation text, titles, or transcripts. The pre-snapshot `cliAcknowledgments`/`desktopAcknowledgments` lists in UserDefaults are read once as a migration when no snapshot file exists yet.

Saves happen whenever the snapshot content changes: after a scan, after Dismiss, and after a verified Ghostty visit. Each save writes a sibling temporary file and renames it over the destination, so an interrupted save leaves the previous snapshot intact. The store reads only regular files up to 4 MiB, ignores symlinks, and refuses to replace a directory or symlink at its path. An unreadable, truncated, oversized, or unknown-version snapshot loads as empty and the app starts normally; the next successful save replaces it. The store never touches `~/.codex`.

## What restart does

1. **Completions restore silently and uncertain.** Every completion the first scan after launch holds, whether it came from the snapshot or from hook records that arrived while Steer was quit, is marked `uncertain`: the user may have viewed that result while nothing was observing. The row says so ("Queued before Steer last started. You may already have seen this result; Steer cannot verify it.") and offers Open in Codex and Dismiss. The restored presentation is created already presented, so no popup expands and no sound plays. A completion observed live later in the same process is certain and presents with its sound once, even in the same session as an uncertain one. A restoring scan never downgrades a completion the process already observed live.
2. **Dismissals stay dismissed.** An acknowledged completion identity is skipped when the same hook records are scanned again. Acknowledgment is per completion, so a later turn in the same session is independently eligible. Desktop acknowledgment still comes only from Dismiss; focus, navigation, and app activation are never inferred as visits, and Ghostty keeps its separately verified per-pane acknowledgment.
3. **No saved approval record restores Approve or Deny.** `AttentionQueue` records the receipts this process issued (`receipt(_:now:)`). A request the reader reports as actionable from a receipt on disk that this process did not write is entered as handed back and returned from `apply(scan:...)`; the app writes a no-decision record at once so the helper releases the request to Codex's own prompt within its next poll instead of at its deadline. The row shows Continue in Codex with only Open in Codex. A request receipted by this process keeps its controls until its own 30-second deadline, unchanged.
4. **Sessions reconcile from evidence.** A handed-back request still clears only on its recorded answer, the end of its exact turn, or the end of its session, as in [approval reconciliation](approval-reconciliation.md).

## Automated checks

`swift test` (85 tests). New in `Tests/SteerCoreTests/RestartRecoveryTests.swift`: snapshot round trip with no stray files; missing, corrupt, unknown-version, truncated, oversized, directory and symlink snapshots all loading as empty without a save through a symlink or over a directory; atomic replacement beside a leftover temporary file; a snapshot never carrying running work or requests; restored completions being uncertain, silent and independently dismissible while a dismissed one stays cleared and a later turn stays eligible; a restoring scan marking its completions uncertain while a live scan does not and cannot be downgraded; a saved receipt alone yielding a handed-back row that is released exactly once; a receipt issued by the running process keeping its controls to its deadline; and running work rebuilt only from current evidence. `AttentionQueueTests` now distinguishes a reader-reported receipt from a live one.

## App-level lab (2026-09-12)

`scripts/restart_lab.py` drives the release `output/Steer.app` with `--desktop-events`, `--reminder-rollouts` and `--attention-snapshot` pointed at a disposable directory, and `--restart-report`, which makes the app write its post-first-scan queue to JSON and quit. The recorded result is `docs/evidence/restart-recovery.json`. No Codex configuration, hook, or real rollout was read or written; the lab's rollout stand-in hashed identical before and after.

| Run | Setup | Result |
| --- | --- | --- |
| A | Prior desktop completion records; a pending CLI request with a receipt from a previous run and no decision | Completion restored as uncertain, presentation already presented (no popup, no sound); request handed back with no controls; one `no_decision` record written; nothing running |
| B | Live completion arrives 3.5 s after launch; SIGKILL 4.5 s later | Snapshot on disk valid and holds both completions |
| C | Restart after the kill | Both completions restored, both uncertain, no replayed sound; request still handed back, nothing re-released |
| D | Snapshot truncated mid-object plus a leftover temporary file beside it | Ordinary startup; completions rebuilt from hook records; a valid snapshot written |
| E | Snapshot edited as Dismiss would persist it (one completion acknowledged) | Only the other completion returns; the dismissed one stays cleared |

## Human check: viewing a result in Codex while Steer runs hidden

Not performed by the agent: it requires the Codex desktop app's UI, which is outside the permitted automation. The state rules it exercises are covered by `AttentionTests` (a completion received while Codex is foreground stays queued and presents once when away) and by the checks above. Steps for the operator, with Steer connected to the isolated desktop hook lab as in [desktop-live-integration.md](desktop-live-integration.md):

1. With Steer running and Codex desktop foreground, finish a turn in the lab task and read the result in Codex. The notch stays hidden; nothing plays.
2. Switch to another app. The completion presents once with its sound and stays queued: reading it in Codex did not acknowledge it.
3. Quit Steer from its menu, relaunch it, and switch away from Codex again. The same completion returns marked as possibly already seen, with no popup and no sound, offering Open in Codex and Dismiss.
4. Dismiss it, quit and relaunch Steer: it does not return. A new turn in the same task still notifies.

## Boundaries

- Uncertainty is about observation, not read status: Steer has no Codex read-status signal, so it never claims a restored result is unread.
- The lab drives hook records and snapshot files, not the Dismiss button or the desktop app; run E stands in for the button by writing what Dismiss persists, which `restoredCompletionsAreUncertainSilentAndIndependentlyDismissible` covers end to end in process.
- The acknowledged set is not pruned; it grows by one identity per dismissal. A cap or age-out is deferred until it matters.
- Receipt liveness is defined as "issued by this process". A restart within a request's 30-second window hands it back a few seconds earlier than the helper would have; nothing is approved.
