# Desktop read state

Herdly acknowledges a Codex desktop completion when the desktop app itself has stopped flagging that thread as unread. This is the only visit signal available for desktop threads: no hook event, app-server notification, or database column exposes it (see "Source inspection of the desktop app" below). It rides on a private format, so it fails closed when the format changes and is re-verified after desktop updates. Since #492 it is always on, with no switch.

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
2. The session's rollout header names the desktop app as originator (`Codex Desktop`). A terminal session on Codex's app-server daemon (rollout `source: vscode`, originator `codex-tui` or `herdly`) is labelled desktop until Herdly proves it CLI, and the desktop app never flags its thread unread, so its absence from the set is no evidence (#284). Its completion stays until dismissed or until the scan classifies the session CLI; from then on the session's next prompt acknowledges it exactly as it does a CLI completion (from other turns, arrived strictly before the prompt; `CodexReplyAcknowledgment`, #359). A daemon proof is remembered until a list the connected daemon has polled lacks the session, so a reconnect does not label it desktop again.
3. The file was written at least 3 seconds after the completion arrived. This covers the app's persistence debounce, so a file written before the flag was raised cannot be read as a cleared flag.
4. The completion's session is absent from the unread set.

A session still in the set stays queued. A file older than the margin is no evidence. A missing or foreign-format file changes nothing; desktop completions then clear only when dismissed. Acknowledgment only removes items; nothing is ever marked unread, replayed, or dismissed on error. Uncertain completions restored after a restart follow the same rule, which is how an unobserved visit while Herdly was quit gets recognized.

Known honest limits: a thread cleared by archive or delete also acknowledges its completions, and a completion the app never flagged (silent heartbeat, failed-runs-only automation) is acknowledged once the margin passes. Both are cases where Codex itself would not have alerted the user.

## App integration

Each hook scan (two seconds apart while a session is live or a row is held, [architecture](architecture.md)) reads the file off the main actor alongside the hook events and rollouts, then applies the rule before presentation decisions, so a completion that finished while its thread was open in front never pops or plays a sound. Acknowledgments persist in Herdly's attention snapshot like dismissals. The rule is always on, with no Settings switch: a missing or unparsable file clears nothing, so desktop completions then clear only when dismissed. The `desktopReadStateEnabled` UserDefaults key from earlier builds is ignored. `--desktop-read-state <path>` points a lab run at a copy of the file.

## Source inspection of the desktop app (2026-09-14)

Read-only inspection of the installed `app.asar` of desktop 26.901.51231 (bundle `com.openai.codex`), extracted into a scratch directory. No app code was copied into Herdly and no IPC connection was attempted. The file names involved are build-specific.

**What sets the flag.** `hasUnreadTurn` is set to true in four places:

1. `turn/completed`, unless the turn's notification decision is `DONT_NOTIFY` (heartbeat turns with empty output, automations with a `failed_runs_only` policy) or the turn completed inside an active goal continuation the app is still streaming as owner. A turn that completes while the user is looking at the thread still sets the flag; the view then clears it at once (below).
2. `item/permissions/requestApproval`, `item/commandExecution/requestApproval`, `item/fileChange/requestApproval` and `item/tool/requestUserInput`, when the request arrives.
3. A plan-implementation request after a turn completes with an incomplete plan.
4. Manual "Mark as unread" from the sidebar context menu, and an import path that marks imported threads unread.

An `unreadMessageCount` per thread is kept alongside it. Completing a turn with `DONT_NOTIFY` subtracts that turn's messages, and the flag drops back to false only if the thread had no unread turn before and the count reaches zero.

**What clears it.** Only `markConversationAsRead(conversationId)`, reached from:

- The conversation thread view, while the Electron window is focused and the thread is the selected view: it marks the thread read whenever it is unread, or when its last request, last turn id, last turn status or a new turn-completed event changes. A background window never clears anything; switching back to the window clears the selected thread.
- Clicking a sidebar row for a thread with `hasUnreadTurn`.
- The sidebar context menu ("Mark as read") and a bulk mark-read action (up to 8 at a time).
- Cache eviction on archive or delete, which clears the persisted flag.

So read state claims only "the selected thread was visible in a focused window after its latest completion or request". It does not know whether the user scrolled to or read the result, and it does not identify which completed turn was read.

**Storage and propagation.** The main process persists the set debounced by 500 ms, writing a temp file and renaming it over `.codex-global-state.json` and again over `.codex-global-state.json.bak`. The file holds many unrelated keys (about 1.8 MB on the Mac inspected). Other windows learn of a change through a private Electron IPC broadcast, `thread-read-state-changed { hostId, conversationId, hasUnreadTurn }` over `~/.codex/ipc/ipc.sock`; that is not an app-server method, and Herdly does not use it. The app server has no read state: `~/.codex/state_5.sqlite` `threads` has no read column and the generated app-server schema has no read-state notification. No hook event fires on viewing, focusing or marking a thread read (CLI 0.145.0 and desktop engine 0.153.4: PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, SessionStart, SessionEnd, UserPromptSubmit, SubagentStart, SubagentStop, Stop, Interrupt).

**Consequences for the rule.** The persisted key is private, build-specific, debounced and rewritten as one large file, so Herdly reads it as a thread-level fact, never per-completion acknowledgment. It can only downgrade an uncertain completion to acknowledged, never the reverse, and it fails closed when the file is missing, unreadable, over the size bound or lacks the key. Absence from the set is not proof of a visit on its own (archive and delete also clear it, and a thread never flagged is indistinguishable from one read long ago), which is why the rule above also requires the file to postdate the completion. Herdly's own dismissals stay independent of this format.

## Verification

Automated: `Tests/HerdlyCoreTests/DesktopReadStateTests.swift` covers parsing of both real shapes, fail-closed cases (missing key, wrong host shape, no or several identities, no or several local hosts, unknown version, non-UUID entry, symlink, oversize), the margin boundary, CLI exclusion, exclusion of threads the desktop app did not originate, uncertain completions, and persistence of the acknowledgment through rescan and restart.

Read-only probe: `python3 scripts/probe_desktop_read_state.py [--watch]` prints the file's write time and unread count and applies the rule to the desktop completions in Herdly's snapshot, so a human can compare with what the running app cleared.

Live walkthrough to repeat after each desktop update, with two disposable desktop threads A and B:

1. Send a no-tools prompt in A, switch to another app before it finishes. Expect: A's completion appears in the notch; the probe shows A unread.
2. Bring Codex forward with B selected. Expect: A stays queued; the probe still shows A unread.
3. Select A. Expect: within about three seconds A's completion clears without a dismissal; the probe shows A absent.
4. Send a prompt in A and stay on it until it finishes. Expect: no popup and no sound; the completion is acknowledged on its first scan.
5. Quit Herdly, complete a turn in B, view B, relaunch Herdly. Expect: B's restored uncertain completion clears on the first scan.

Record the desktop version and results in this file. If completions stop clearing after a desktop update, run the probe against the live file and, if it returns no snapshot, re-run the source inspection described below.

### 2026-10-21, two signed-in identities

The live file held two identities: one with 355 local unread threads and one with an empty local list. The reader required exactly one identity, so it returned no snapshot and nothing cleared; viewing thread `01a15cf2` left its completions queued even though it was absent from both local sets. The reader now merges the identities' local sets as described above; `readStateMergesTheLocalHostsOfSeveralSignedInIdentities` covers it, and the probe reads the live file again. The live walkthrough above has not been rerun.

### 2026-10-09, desktop 26.930.61225

The desktop update moved the unread set to the per-identity layout above, so the reader returned no snapshot and nothing cleared: one Mac accumulated 103 queued desktop completions across 26 threads between 2026-10-07 and 2026-10-08, every one of them absent from Codex's unread set. Source inspection of the installed `app.asar` (read-only, nothing copied) established the key derivation and the logout and migration behavior. The reader now accepts the new layout; `DesktopReadStateTests` covers it and its ambiguous-host and signed-out cases, and the probe applied to the live file reported all 103 as clearable. The live walkthrough above has not been rerun on this version.

### 2026-09-14, desktop 26.901.51231

Source inspection and automated checks complete; the probe read the live file. The live walkthrough above has not yet been run.
