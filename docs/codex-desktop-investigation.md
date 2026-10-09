# Codex desktop feasibility: first pass

Checked 2026-09-11. This pass produces a runnable capability probe and source-level findings. It does not establish live focused-conversation detection or approval handoff.

## Run the probe

```sh
python3 scripts/probe_codex_desktop.py --self-test
python3 scripts/probe_codex_desktop.py
```

Both commands passed. The probe reads bundle metadata and asks the bundled CLI to generate its protocol schemas in a temporary directory. It does not connect to conversations, start a server or model turn, install hooks, change settings, or control the UI.

Use --app with an explicit bundle path for a different installation.

## Findings

| Capability | Evidence | What is still missing |
| --- | --- | --- |
| Identify desktop installation | /Applications/ChatGPT.app, bundle ID com.openai.codex, app version 26.901.51231, bundled CLI 0.153.4 | Handle multiple installations and choose the actual running process |
| Lifecycle protocol | Generated schema defines turn/started, turn/completed and thread/status/changed | Prove access to events from the existing desktop runtime |
| Approval protocol | Generated schema defines command, file and permission approval requests, plus serverRequest/resolved | Prove hook coverage, response ownership and no-decision fallback in the existing desktop |
| Navigate to a conversation | Bundle registers codex scheme; installed deep-link handler recognizes threads and returns a localConversation route | Live route test and verification that the intended conversation became selected |
| Know which conversation is selected | No focus/read-receipt-named method found in generated app-server methods | A dependable desktop-specific observation mechanism |
| Know whether results were checked | Installed renderer contains thread-read-state-changed and markConversationAsRead logic | Public access, live behavior, persistence and per-completion correlation |

The official [app-server reference](https://learn.chatgpt.com/docs/app-server) documents data and runtime APIs. thread/read retrieves a conversation; it is not a user-view receipt. A generated schema proves a protocol shape, not that a new connection can observe or control existing desktop tasks.

## Multiple app installations

The computer-use resolver found both /Applications/ChatGPT.app and /Users/dev/Applications/Codex.app sharing com.openai.codex. Process inspection identified a running /Applications/ChatGPT.app main process. Bundle ID alone is insufficient to choose an installation. Use the running process's bundle path for this probe and avoid blindly selecting the first bundle with that ID.

## Read-state detail

Read-only inspection of the installed app.asar found an internal thread-read-state-changed broadcast carrying hostId, conversationId and hasUnreadTurn. The renderer supports marking a conversation read or unread and propagates that flag to its stores and runtime settings. The observed broadcast does not itself identify a specific completed turn or establish which window is focused now.

This narrows the earlier uncertainty: a private mechanism exists in this build, but it is not established as a stable external API. Do not equate a conversation-level flag with acknowledgment of every completion or connect to private IPC as a production dependency based on these source strings alone. No private IPC connection was attempted.

Source locations in the installed archive: .vite/build/src-VqXTPopo.js, .vite/build/window-all-closed-KNH8jchn.js and webview/assets/app-initial-cadb12d4a15e.js. These filenames are build-specific. No app code was copied into the product.

## Live UI limitation

A read-only AppleScript query of the front window's active tab URL returned a browser error-page data URL, not a Codex conversation locator. That generic browser-tab property is not sufficient evidence of the selected Codex task.

The computer-use tool then rejected access to com.openai.codex for safety reasons. No alternative UI-control path was used after that rejection. No conversation was switched, so jump-back and focus changes remain untested. The app's active-voice-only screen-context tool was not used.

## Architecture consequence

Keep desktop observation behind its own integration boundary. It must report unknown when it cannot reliably identify a session, allowing the already-agreed indicator/native-approval fallback. Keep saved acknowledgments independent of the private desktop read-state format. Do not start a second app server and call its loaded threads the desktop's current conversations.

Before shipping desktop support, obtain a permitted live verification path and demonstrate exact conversation selection, verified deep-link return, and independently safe approval handoff. Capability metadata and source inspection do not satisfy those acceptance checks.

## Original ticket #1 execution: 2026-09-11 (superseded scope)

Status: blocked, not completed. [Issue #1](https://github.com/r-curio/steer/issues/1).

`python3 scripts/probe_desktop_process.py` now identifies main processes using their executable path and bundle metadata. It reports a unique running installation only when exactly one matches; zero or multiple matches are unknown. It never infers conversation focus. The live read-only result was `/Applications/ChatGPT.app`, version `26.901.51231`. Process IDs are transient and are not saved as surface identities.

Both probe self-checks and the installed desktop schema probe passed. The process parser covers spaces in paths, helper exclusion, malformed lines and multiple installations. This verifies discovery, not app navigation.

| Required proof | Result |
| --- | --- |
| Identify actual running bundle despite duplicate installation | Read-only process probe passed |
| Select A and B independently, including two windows | Blocked by computer-use access restriction |
| Return to A while B is selected | Not executed; static route evidence only |
| Background/uncertain focus does not acknowledge A | Required behavior; no live observer yet |
| Per-completion acknowledgment rather than conversation unread flag | Not established by installed public protocol |

To resume this gate, use a permitted test environment and two disposable local conversations A and B. Record their IDs, installed app version, selected window/conversation before and after each switch, and the observer result. Complete A, visit B, then visit A; only the last visit may acknowledge A's completion. Repeat with the app backgrounded and with the target closed or unavailable. Open A's deep link against the identified running bundle and independently verify A is selected. A successful URL-open call alone is not a pass.

Human navigation alone will not solve the integration: a standalone companion still needs a supported or explicitly evaluated focus observation mechanism. The Codex app's built-in task tools are not evidence of an API available to Steer. No private IPC adapter or acknowledgment heuristic has been adopted.

The next bounded exercise is the [manual jump-back test](desktop-manual-test.md). It collects user observations of navigation only; no focus watcher is running. Do not ask the user to switch tasks while claiming an unimplemented observer is measuring those switches.

## Focus feasibility conclusion after manual navigation

The user confirmed both task links and external jump-back from Apple Notes in the [manual evidence](desktop-manual-test.md). Those later results supersede the earlier untested navigation status above. Exact installation routing and automatic selected-task observation remain unverified.

A further review of the official [hook event catalog](https://learn.chatgpt.com/docs/hooks) and [app-server API](https://learn.chatgpt.com/docs/app-server), plus a fresh schema probe of desktop engine 0.153.4, did not establish an external selected-task signal. Hook events describe execution lifecycle; loaded threads and stored thread reads are not selected-task observations. Private read-state source strings do not establish a usable supported subscription.

Exact-task focus is therefore blocked by an unverified integration contract, not by another manual clicking test. Do not build an observer that substitutes running state, latest activity, task title, or a successful URL launch for focus. Do not treat a generated-schema check as proof that no private capability can exist.

### Accepted scope adjustment — desktop MVP

The user accepted app-level visibility for desktop MVP: hide the notch while Codex is foreground and show it while away when attention items exist. Keep completions queued until explicit dismissal; foregrounding Codex never marks all tasks read. A future verified selected-task signal can restore the original task-specific behavior. Native app activation is the candidate implementation, not live-tested in this investigation.

Tradeoff: while viewing task B, the notch would also hide task A's notification. This replaces the earlier exact-task desktop focus requirement. Product code and live app-activation verification are still pending; exact-task focus no longer blocks the desktop MVP. Under the existing unknown-focus rule, direct desktop approvals remain native unless a separate accepted policy and safe approval integration are established. This adjustment alone does not complete #2 or unblock direct approvals.

## Read-state mechanism in the installed desktop app: 2026-09-14

Read-only inspection of `/Applications/ChatGPT.app` (bundle `com.openai.codex`, the running installation) by extracting `Contents/Resources/app.asar` into a scratch directory. No app code was copied into the product and no IPC connection was attempted. Build-specific files: `webview/assets/app-initial-cadb12d4a15e.js` (renderer), `webview/assets/local-conversation-thread-40db5af470f5.js` (conversation view), `.vite/build/window-all-closed-KNH8jchn.js` (main-process state store).

### What "unread" means to the desktop app

Unread is a per-thread boolean, `hasUnreadTurn`, not a per-turn or per-message receipt. It is set to true in four places:

1. `turn/completed` when `shouldMarkUnread` is true. That is true unless the turn's notification decision is `DONT_NOTIFY` (heartbeat turns with empty output, automations with `failed_runs_only` policy) or the turn completed inside an active goal continuation that the app is still streaming as owner. Note that a turn completed while the user is looking at the thread still sets the flag; the view then clears it immediately (below).
2. `item/permissions/requestApproval`, `item/commandExecution/requestApproval`, `item/fileChange/requestApproval` and `item/tool/requestUserInput` when the request arrives.
3. A plan-implementation request after a turn completes with an incomplete plan.
4. Manual "Mark as unread" from the sidebar context menu, and an import path that marks imported threads unread.

An `unreadMessageCount` per thread is kept alongside it. Completing a turn with `DONT_NOTIFY` subtracts that turn's messages, and the flag drops back to false only if the thread had no unread turn before and the count reaches zero.

### What clears it

Only `markConversationAsRead(conversationId)`, reached from:

- The conversation thread view. On mount and on every reactive change it runs a watcher (`$4o` in this build) that requires the Electron window to be focused (`electron-window-focus-changed` → focus atom). While focused and the thread is selected, it calls mark-read whenever the thread is unread, or when the last request, last turn id, last turn status, or a new turn-completed event for this exact thread changes. So the rule is: window focused AND this thread is the selected view AND (a turn completed or a request arrived) → read. A background window never clears anything; switching back to the window re-runs the watcher and clears the selected thread.
- Clicking a sidebar row for a thread with `hasUnreadTurn`.
- The sidebar context menu ("Mark as read") and a bulk mark-read action (up to 8 at a time).
- Cache eviction on archive or delete, which clears the persisted flag.

Read state therefore claims only "the selected thread was visible in a focused window after its latest completion or request". It does not know whether the user scrolled to or read the result, and it does not identify which completed turn was read.

### Where it is stored and how it propagates

- Persisted set: `~/.codex/.codex-global-state.json`, key `electron-persisted-atom-state` → `unread-thread-ids-by-host-v1`, shaped `{ "<hostId>": ["<threadId>", …] }` with host `local` for the local app server. A thread is unread if and only if its id is in the array. The renderer writes it through `setThreadHasUnreadTurn` whenever the in-memory flag changes. Superseded in desktop 26.930.61225 by `electron-thread-read-state-v1`, keyed by signed-in identity and execution host; see [desktop read state](desktop-read-state.md).
- The main process persists that key debounced by 500 ms, writing a temp file then renaming over `.codex-global-state.json` and again over `.codex-global-state.json.bak` (atomic replace, so a reader never sees a partial file). On this machine the file is about 1.8 MB and holds many unrelated keys.
- Cross-window sync: the changing window broadcasts `thread-read-state-changed { hostId, conversationId, hasUnreadTurn }` over the app's private IPC (`~/.codex/ipc/ipc.sock`); other windows apply it without re-broadcasting. This is an internal Electron IPC protocol, not an app-server method, and is versioned per message (`thread-read-state-changed` is at version 2 in this build).
- Not in the app server: `~/.codex/state_5.sqlite` `threads` has no read column, and the generated app-server schema has no read-state notification. The desktop's own app-server session is the only client that could know, and it keeps the state in the renderer.

### Consequences for Steer

- A supported subscription still does not exist. The only externally observable artifact is the persisted JSON key, which is private, build-specific, debounced, and rewritten as one large file.
- If Steer ever reads it, the honest interpretation is: "thread X was viewed in a focused Codex window after its most recent completion or request at or before file time T". That is a thread-level fact, not per-completion acknowledgment. Steer could use it conservatively only as evidence to acknowledge a completion whose turn completed before the thread left the unread set and while no newer turn or request has since arrived, with the flag's absence never treated as "unread". Removal by archive or delete also clears the flag, so absence must not be read as viewed either; a thread never in the set at all is indistinguishable from one read long ago.
- The mechanism matches the glossary: it can only ever downgrade an uncertain completion to acknowledged, never the reverse, and it must fail closed when the file is missing, unreadable, over the size bound, or lacks the key.
- Adopting it means depending on a private format that can change with any desktop release. If pursued, gate it on the tested desktop version, verify live with two disposable threads (complete A, view B, view A; only the last step may drop A from the set), and keep the dismissal path independent.

### Hook events and Open Vibe Island comparison: 2026-09-14

Hook events in the installed binaries (CLI 0.145.0 and desktop engine 0.153.4): PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, SessionStart, SessionEnd, UserPromptSubmit, SubagentStart, SubagentStop, Stop, Interrupt. None fires on viewing, focusing, or marking a thread read. Hooks describe execution, not attention.

Open Vibe Island (github.com/Octane0411/open-vibe-island, commit 334c580, 2026-09-03) was read for comparison. It does not detect read state at all and never touches the desktop app's unread set:

- Completion is a session phase set by the Stop hook or by `turn/completed` from its own app-server client. The completion card auto-dismisses on a timer, and the row simply stays in its list until the session ends or the Codex desktop process exits. There is no per-completion acknowledgment and no "read" concept.
- Its only attention check happens at presentation time: before showing a completion, it asks whether the session's terminal is already frontmost (Ghostty focused terminal id, Terminal tty, iTerm session via AppleScript). If so it suppresses the popup. For the Codex desktop app it returns false, so desktop completions always present.
- Desktop-app sessions are discovered by connecting a second app-server client and listing threads; visibility is "desktop app is running and thread not ended". That is the approach this project already rejected as not proving which task the user is viewing.

Steer's uncertain-completion and explicit-dismissal model is therefore already stricter than Open Vibe Island's. The desktop unread set described above remains the only source that could add a verified visit signal for desktop threads. It was adopted the same day; see [desktop read state](desktop-read-state.md).
