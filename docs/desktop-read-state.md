# Desktop read state

Herdly acknowledges a Codex desktop completion when the desktop app itself has stopped flagging that thread as unread. This is the only visit signal available for desktop threads: no hook event, app-server notification, or database column exposes it (see the [desktop investigation](codex-desktop-investigation.md), section "Read-state mechanism"). It rides on a private format, so it is one switch away from off and is re-verified after desktop updates.

Accepted by the user on 2026-09-14 with the understanding that the format may change and that testing continues.

## What the desktop app records

The app keeps one flag per thread, `hasUnreadTurn`. It raises the flag when a turn completes (unless the turn is a silent heartbeat or a failed-runs-only automation run) and when any approval or user-input request arrives. It clears the flag only when that thread is the selected view in a focused Codex window, when the user chooses Mark as read, or when the thread is archived or deleted. The flag is per thread: it says the thread was open in front after its latest completion or request, not that a particular reply was scrolled to.

The set of flagged ids is persisted in `~/.codex/.codex-global-state.json`, debounced by about 500 ms, and written by temp-file rename so a reader never sees a partial file. Thread ids equal Codex session ids. Two layouts are known (`/Applications/ChatGPT.app`):

- **Desktop 26.930.61225:** `electron-thread-read-state-v1` → `unreadByIdentity` → identity key → execution host key → ids, with `version: 1`. The identity key is a SHA-256 of the signed-in account (kind, account id, user id); the app deletes an identity's entry when it signs out. Host keys are hashed per execution host, prefixed by kind: `local:<hash>` for this Mac's app server, `durable:<hash>` for cloud threads. On first launch the app migrates the older list into this layout (recording it under `legacyMigration`) and deletes the older key.
- **Desktop 26.901.51231:** `electron-persisted-atom-state` → `unread-thread-ids-by-host-v1` → `local`.

## Herdly's rule

`DesktopReadStateReader` reads the file with the same bounds as other Codex files (regular file, no symlink, at most 20 MB) and returns a snapshot of the local unread set and the file's modification time. When `electron-thread-read-state-v1` is present it is the only source: Herdly cannot recompute either hashed key, so it requires version 1, at least one identity, and exactly one `local:` host within each, and ignores `durable:` and other hosts. With several identities Herdly cannot tell which account is current, so it merges their local sets: a thread flagged unread under any identity stays unread, and only a thread absent from all of them reads as read (agreed with the user on 2026-10-21). No identity (signed out), or an identity with zero or two local hosts, returns no snapshot, because an absent list must never read as "every thread is read". Without that key the older layout is read. Any other deviation from the exact key path or an entry that is not a UUID returns no snapshot.

`DesktopReadAcknowledgment` acknowledges a queued desktop completion when all of these hold:

1. The completion's source is desktop. CLI completions are never touched.
2. The session's rollout header names the desktop app as originator (`Codex Desktop`). A terminal session on Codex's app-server daemon (rollout `source: vscode`, originator `codex-tui` or `herdly`) is labelled desktop until Herdly proves it CLI, and the desktop app never flags its thread unread, so its absence from the set is no evidence (#284). Its completion stays until dismissed or until it is relabelled CLI.
3. The file was written at least 3 seconds after the completion arrived. This covers the app's persistence debounce, so a file written before the flag was raised cannot be read as a cleared flag.
4. The completion's session is absent from the unread set.

A session still in the set stays queued. A file older than the margin is no evidence. A missing or foreign-format file changes nothing, and the controls window says so. Acknowledgment only removes items; nothing is ever marked unread, replayed, or dismissed on error. Uncertain completions restored after a restart follow the same rule, which is how an unobserved visit while Herdly was quit gets recognized.

Known honest limits: a thread cleared by archive or delete also acknowledges its completions, and a completion the app never flagged (silent heartbeat, failed-runs-only automation) is acknowledged once the margin passes. Both are cases where Codex itself would not have alerted the user.

## App integration

Each two-second scan reads the file off the main actor alongside the hook events and rollouts, then applies the rule before presentation decisions, so a completion that finished while its thread was open in front never pops or plays a sound. Acknowledgments persist in Herdly's attention snapshot like dismissals. The controls window has a toggle, "Clear desktop completions Codex marks read" (on by default, stored in UserDefaults as `desktopReadStateEnabled`), and a status line with the file's write time, the unread count, how many completions the last scan cleared, and a note when the installed desktop version differs from the tested one. `--desktop-read-state <path>` points a lab run at a copy of the file.

## Verification

Automated: `Tests/HerdlyCoreTests/DesktopReadStateTests.swift` covers parsing of both real shapes, fail-closed cases (missing key, wrong host shape, no or several identities, no or several local hosts, unknown version, non-UUID entry, symlink, oversize), the margin boundary, CLI exclusion, exclusion of threads the desktop app did not originate, uncertain completions, and persistence of the acknowledgment through rescan and restart.

Read-only probe: `python3 scripts/probe_desktop_read_state.py [--watch]` prints the file's write time and unread count and applies the rule to the desktop completions in Herdly's snapshot, so a human can compare with what the running app cleared.

Live walkthrough to repeat after each desktop update, with two disposable desktop threads A and B:

1. Send a no-tools prompt in A, switch to another app before it finishes. Expect: A's completion appears in the notch; the probe shows A unread.
2. Bring Codex forward with B selected. Expect: A stays queued; the probe still shows A unread.
3. Select A. Expect: within about three seconds A's completion clears without a dismissal; the probe shows A absent and the status line reports one cleared.
4. Send a prompt in A and stay on it until it finishes. Expect: no popup and no sound; the completion is acknowledged on its first scan.
5. Quit Herdly, complete a turn in B, view B, relaunch Herdly. Expect: B's restored uncertain completion clears on the first scan.

Record the desktop version and results in this file. If the status line reports the file unavailable after an update, turn the toggle off and re-run the source inspection described in the investigation document.

### 2026-10-21, two signed-in identities

The live file held two identities: one with 355 local unread threads and one with an empty local list. The reader required exactly one identity, so it returned no snapshot and nothing cleared; viewing thread `01a15cf2` left its completions queued even though it was absent from both local sets. The reader now merges the identities' local sets as described above; `readStateMergesTheLocalHostsOfSeveralSignedInIdentities` covers it, and the probe reads the live file again. The live walkthrough above has not been rerun.

### 2026-10-09, desktop 26.930.61225

The desktop update moved the unread set to the per-identity layout above, so the reader returned no snapshot and nothing cleared: one Mac accumulated 103 queued desktop completions across 26 threads between 2026-10-07 and 2026-10-08, every one of them absent from Codex's unread set. Source inspection of the installed `app.asar` (read-only, nothing copied) established the key derivation and the logout and migration behavior. The reader now accepts the new layout; `DesktopReadStateTests` covers it and its ambiguous-host and signed-out cases, and the probe applied to the live file reported all 103 as clearable. The live walkthrough above has not been rerun on this version.

### 2026-09-14, desktop 26.901.51231

Source inspection and automated checks complete; the probe read the live file. The live walkthrough above has not yet been run.
