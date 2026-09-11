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

The computer-use resolver found both /Applications/ChatGPT.app and /Users/rmaisog/Applications/Codex.app sharing com.openai.codex. Process inspection identified a running /Applications/ChatGPT.app main process. Bundle ID alone is insufficient to choose an installation. Use the running process's bundle path for this probe and avoid blindly selecting the first bundle with that ID.

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
