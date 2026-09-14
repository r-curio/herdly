# Desktop read state

Steer acknowledges a Codex desktop completion when the desktop app itself has stopped flagging that thread as unread. This is the only visit signal available for desktop threads: no hook event, app-server notification, or database column exposes it (see the [desktop investigation](codex-desktop-investigation.md), section "Read-state mechanism"). It rides on a private format, so it is one switch away from off and is re-verified after desktop updates.

Accepted by the user on 2026-09-14 with the understanding that the format may change and that testing continues.

## What the desktop app records

The app keeps one flag per thread, `hasUnreadTurn`. It raises the flag when a turn completes (unless the turn is a silent heartbeat or a failed-runs-only automation run) and when any approval or user-input request arrives. It clears the flag only when that thread is the selected view in a focused Codex window, when the user chooses Mark as read, or when the thread is archived or deleted. The flag is per thread: it says the thread was open in front after its latest completion or request, not that a particular reply was scrolled to.

The set of flagged ids is persisted in `~/.codex/.codex-global-state.json` under `electron-persisted-atom-state` → `unread-thread-ids-by-host-v1` → `local`, debounced by about 500 ms, and written by temp-file rename so a reader never sees a partial file. Thread ids equal Codex session ids. Observed in desktop 26.901.51231 (`/Applications/ChatGPT.app`).

## Steer's rule

`DesktopReadStateReader` reads the file with the same bounds as other Codex files (regular file, no symlink, at most 20 MB) and returns a snapshot of the local unread set and the file's modification time. Any deviation from the exact key path or an entry that is not a UUID returns no snapshot.

`DesktopReadAcknowledgment` acknowledges a queued desktop completion when all of these hold:

1. The completion's source is desktop. CLI completions are never touched.
2. The file was written at least 3 seconds after the completion arrived. This covers the app's persistence debounce, so a file written before the flag was raised cannot be read as a cleared flag.
3. The completion's session is absent from the unread set.

A session still in the set stays queued. A file older than the margin is no evidence. A missing or foreign-format file changes nothing, and the controls window says so. Acknowledgment only removes items; nothing is ever marked unread, replayed, or dismissed on error. Uncertain completions restored after a restart follow the same rule, which is how an unobserved visit while Steer was quit gets recognized.

Known honest limits: a thread cleared by archive or delete also acknowledges its completions, and a completion the app never flagged (silent heartbeat, failed-runs-only automation) is acknowledged once the margin passes. Both are cases where Codex itself would not have alerted the user.

## App integration

Each two-second scan reads the file off the main actor alongside the hook events and rollouts, then applies the rule before presentation decisions, so a completion that finished while its thread was open in front never pops or plays a sound. Acknowledgments persist in Steer's attention snapshot like dismissals. The controls window has a toggle, "Clear desktop completions Codex marks read" (on by default, stored in UserDefaults as `desktopReadStateEnabled`), and a status line with the file's write time, the unread count, how many completions the last scan cleared, and a note when the installed desktop version differs from the tested one. `--desktop-read-state <path>` points a lab run at a copy of the file.

## Verification

Automated: `Tests/SteerCoreTests/DesktopReadStateTests.swift` covers parsing of the real shape, fail-closed cases (missing key, wrong host shape, non-UUID entry, symlink, oversize), the margin boundary, CLI exclusion, uncertain completions, and persistence of the acknowledgment through rescan and restart.

Read-only probe: `python3 scripts/probe_desktop_read_state.py [--watch]` prints the file's write time and unread count and applies the rule to the desktop completions in Steer's snapshot, so a human can compare with what the running app cleared.

Live walkthrough to repeat after each desktop update, with two disposable desktop threads A and B:

1. Send a no-tools prompt in A, switch to another app before it finishes. Expect: A's completion appears in the notch; the probe shows A unread.
2. Bring Codex forward with B selected. Expect: A stays queued; the probe still shows A unread.
3. Select A. Expect: within about three seconds A's completion clears without a dismissal; the probe shows A absent and the status line reports one cleared.
4. Send a prompt in A and stay on it until it finishes. Expect: no popup and no sound; the completion is acknowledged on its first scan.
5. Quit Steer, complete a turn in B, view B, relaunch Steer. Expect: B's restored uncertain completion clears on the first scan.

Record the desktop version and results in this file. If the status line reports the file unavailable after an update, turn the toggle off and re-run the source inspection described in the investigation document.

### 2026-09-14, desktop 26.901.51231

Source inspection and automated checks complete; the probe read the live file. The live walkthrough above has not yet been run.
