# Relay the user's chosen question option through Ghostty's send key

Accepted with the user on 2026-09-14.

When Codex asks a question through `request_user_input` in a CLI session running in Ghostty, the notch shows the listed options as controls. A click relays that one option to the exact matched Ghostty terminal as a single key event, the option's one-based digit, through Ghostty 1.3's own `send key` scripting command. Codex's terminal question pane binds a digit to "select this option and move on", so the key is the same input the user would type.

Scope: `request_user_input` questions only; CLI sessions in Ghostty only; exactly one key press per option the user clicked, plus Enter only if a live check on the installed CLI proves the digit alone does not commit. The key goes to the terminal object, not to the frontmost window, and only after the same unique-unsplit-tab recheck that tab selection uses. Immediately before sending, the session rollout is re-read; an answer already recorded or an ended turn sends nothing. Herdly never sends on a timeout, an error, or after a restart, and never resends. Only the listed options are offered: no free text, no "Other", no Skip, no Escape.

This narrows the architecture rule "do not synthesize terminal keystrokes" to approvals, where it stands. A question option is the user's own choice relayed verbatim; an approval decision still travels through the hook helper's decision record.

Desktop sessions are excluded. The desktop app runs its engine as an embedded stdio app-server with no listener, its `codex://threads/<id>` link takes no parameters, and no hook fires for the question tool, so nothing outside the app can answer or pre-select. A desktop card offers the options only as a highlighted pick that opens the thread.

Rejected alternatives: Codex hooks (the question tool provides no PreToolUse payload); `input text` (a paste event, not a key, and Codex's pane may treat it as notes); synthesized global keystrokes (need Accessibility and can land in the wrong pane). Deferred: a JSON-RPC client on Codex's app-server daemon socket that answers `item/tool/requestUserInput` by call id for CLI and desktop threads alike; it needs a running daemon and is the follow-up recorded in the backlog.
