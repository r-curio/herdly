# Desktop activity integration

Steer reads the metadata-only event records produced by the isolated desktop
hook lab. It never writes Codex settings, emits hook output, or starts a second
Codex runtime. `SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd` are
replayed through `SteerCore.DesktopEventReader` and `DesktopState`; CLI sessions
are excluded using their rollout source metadata. The recorded real desktop
session evidence in `docs/desktop-approval-investigation.md` identifies
session `01a08f51-a2fd-74c0-a9e9-d7e8a31c634c` as originator `Codex Desktop`,
source `vscode`. Its hooks were enabled after SessionStart, so the captured
UserPromptSubmit and Stop records prove a real desktop turn start/completion,
but do not claim full session-start capture. The original records are capture
`8bedf2d3-754c-4c00-8da4-635e14e82fe8` at 07:26:54.343057Z and
`b4baa09c-eb98-4cb9-b75c-9bd2f3405c24` at 07:26:57.252939Z. The original metadata-only records
are at `/Users/dev/Steer/output/desktop-hook-lab/events`;
the redacted pair in `docs/evidence/` is replayable from a fresh checkout.

## Build and run

```sh
swift test
sh scripts/build-app.sh
open output/Steer.app --args --desktop-events "$PWD/output/desktop-hook-lab/events" --reminder-rollouts "$HOME/.codex/sessions"
```

Use `--desktop-events "$PWD/docs/evidence"` to replay the checked-in turn.

The `--desktop-events` path is an isolated replay override. The app polls it
every two seconds off the main actor. Existing completion records restore
silently; a newly observed completion expands the notch for three seconds and
stays queued until its own Dismiss action. Codex foreground hides the whole
shared panel without acknowledging activity; unknown activation keeps it
visible. Open in Codex sends the manually verified exact-task
`codex://threads/<session-id>` route, but successful native delivery is not
programmatic proof that the task was selected and never dismisses the completion.

For a deterministic local replay, place metadata-only records in a directory
and run the same command with that directory. Records must contain
`hook_event_name`, `session_id`, and `received_at`; turn events also need
`turn_id`. Malformed or oversized records are ignored.

## Evidence boundary

The state/replay checks are runnable in
`Tests/SteerCoreTests/DesktopActivityTests.swift`. The repository records the
isolated desktop hook-lab lifecycle experiment and real-session evidence in
`docs/desktop-approval-investigation.md`. This implementation consumes that
event shape without claiming permanent attachment or changing Codex
configuration; reversible connection/setup is tracked separately in #5. A
fresh real-session UI check still requires the permitted human route described
there.

## Codex background jobs (2026-10-08)

Codex runs memory consolidation as a session of its own, with the user's hooks.
Session `01a11757-16e6-7c91-b937-4e67f83d3163` sent `SessionStart`,
`UserPromptSubmit` and 51 tool records. They carried herdr pane `w1:p2`, the
pane in the managed app-server daemon's environment. Codex wrote no rollout for
it. Its log
shows the thread shutting down at 01:17:18 local time with no `Stop` or
`SessionEnd` hook. Steer therefore kept a desktop working row with no end. An
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
so Steer does not rely on them. Covered by
`aMemoryJobThatNeverSendsStopOrSessionEndIsNotLeftWorking` and its neighbours in
`DesktopActivityTests.swift`.

## Completion notification demonstration (#8)

The controllable-clock tests cover a completion staying queued while Codex is
foreground, expanding for three seconds only after an eligible away state,
retaining the item after collapse, and restoring silently. Queue tests cover
duplicate lifecycle records, explicit dismissal, and a later turn in the same
session remaining independent.

The existing Steer-only walkthrough in `docs/prototype.md` records the compact
popup, expansion, foreground hiding, switching-away retention, restart
restoration, explicit dismissal, and the menu mute control. This patch did not
alter Codex hooks, permissions, or user configuration. A fresh real desktop turn
was not triggered here; native UI timing and sound remain separately
human-observable.

An earlier native UI attempt was blocked by the Mac being locked; the allowed
CUA unlock attempt could not recover that session. The later walkthrough below
records the safe Steer-only evidence obtained after the Mac was unlocked.

### Allowed Steer-only CUA walkthrough (2026-09-12)

After the Mac was unlocked, the exact `79081ec` build was launched and its
controls connected to the existing evidence directory. The controls showed 17
real desktop completions. **Send test** increased the count to 18; closing the
controls left the compact `18 to check` notch, which auto-collapsed. Reopening
the notch expanded the same 18 items and rendered each desktop completion with
**Open in Codex** and explicit **Dismiss**, alongside the test item.

This proves the branch build's native popup, collapse, retention, reopen, and
desktop action rendering through Steer only. CUA could not click **Dismiss**
without destructive-action confirmation. Sound/mute hearing, a fresh CLI turn,
Ghostty, and Codex UI were not tested and are not claimed here.
