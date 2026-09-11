# Desktop activity integration

Steer reads the metadata-only event records produced by the isolated desktop
hook lab. It never writes Codex settings, emits hook output, or starts a second
Codex runtime. `SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd` are
replayed through `SteerCore.DesktopEventReader` and `DesktopState`; CLI sessions
are excluded using their rollout source metadata. The recorded real-session
evidence in `docs/desktop-approval-investigation.md` includes session
`01a0916c-337b-70b2-963e-9cf848bd2a48` with SessionStart, UserPromptSubmit, and
Stop records in `/Users/rmaisog/Documents/ChatGPT/Steer/output/desktop-hook-lab/events`.

## Build and run

```sh
swift test
sh scripts/build-app.sh
open output/Steer.app --args --desktop-events "$PWD/output/desktop-hook-lab/events" --reminder-rollouts "$HOME/.codex/sessions"
```

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
