# Handed-back reminder integration (#2)

Branch: codex/2-reminder-queue, based on the desktop prototype. Earlier approval-proof changes remain untouched in the original worktree.

Build with `sh scripts/build-app.sh`. In Herdly controls, choose Connect approval reminders and select the isolated lab events folder. It reads the selected folder and ~/.codex/sessions; it does not install or alter Codex hooks. Optional --reminder-events and --reminder-rollouts launch arguments permit isolated input directories without saving those overrides.

Verified 2026-09-11:
- `swift test`: all four tests passed, including a disk-level approval/rollout/queue test. It exercises partial completion writes, unrelated turns, direct allow filtering, missing logs, restart reconstruction and no resurrection.
- Release app build and signing passed.
- Computer use launched the built app and connected two disposable metadata records. The record for an already completed real lab turn was filtered, while the unresolved synthetic turn remained. Expanding the actual notch showed Continue in Codex, the originating task suffix/prefix label, and only Open in Codex.
- Relaunched the final build and connected the existing isolated lab events folder. UI reported zero reminders, matching the completed historical handoffs. The app remains running with that connection.

Limits: no fresh native approval was triggered during this turn. A newly appended real completion clearing a visible reminder still needs end-to-end confirmation; automated tests cover that transition. The existing helper only emits this metadata for its marker-command allowlist. This is connected lab functionality, not general Codex approval coverage. No new Accessibility permissions, real hook changes, commits or PR updates were made.

Fresh live handoff (2026-09-11): task turn 01a08ff5-d074-70e1-8e83-6c7e9ae99feb requested `touch HERDLY-APPROVAL-DIRECT-QUEUE-E2E-1`. Request 7b8732b1-40df-4c80-8c8a-599c829d62cd handed back with no_decision after 30.136 seconds. The marker was absent, task status was waitingOnApproval, and computer use verified one real notch reminder with Continue in Codex and Open in Codex only. Native user decision and subsequent automatic cleanup remain pending.

Fresh live cleanup verified: after the user denied the request, the same turn completed and its rollout contained matching task_complete. The marker remained absent. Computer use then read the running Herdly app showing `0 notifications queued` and `0 reminders · checks every 2 seconds`, without manual dismissal or reconnection. This completes the native denial → turn completion → automatic queue cleanup proof for this marker request. Exact elapsed cleanup latency was not measured; allow-path and broader approval categories remain separate coverage.
