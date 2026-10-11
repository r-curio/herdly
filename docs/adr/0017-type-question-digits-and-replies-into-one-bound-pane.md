# Type question digits and replies into one bound pane

Accepted with the user on 2026-10-11 ([issue #212](https://github.com/r-curio/steer/issues/212), map [#197](https://github.com/r-curio/steer/issues/197)). This generalizes [ADR 0006](0006-relay-the-users-chosen-question-option-through-ghostty.md) (Ghostty question keys) and [ADR 0010](0010-relay-codex-question-options-as-herdr-pane-keys.md) (herdr question keys) to every terminal host and multiplexer in scope. It also adds a second reply transport beside the daemon's `turn/start` ([session replies](../session-replies.md)), the only reply transport so far, and gives Claude Code sessions their first reply path. Binding is unchanged: [ADR 0013](0013-bind-cli-sessions-to-terminal-tabs-by-tty.md) (terminal tabs) and [ADR 0014](0014-bind-multiplexer-panes-and-join-their-client-to-a-host-tab.md) (multiplexer panes) decide which pane a session runs in.

**Typed input** is a question option's digit or a session reply that Steer types into the one pane a session is bound to, after the user chose or wrote it in the notch. Approvals are never typed input.

The live proofs ([iTerm2](../evidence/iterm2-live.md), [Terminal.app](../evidence/terminal-app-live.md), [WezTerm](../evidence/wezterm-live.md), [tmux](../evidence/tmux-live.md), [Zellij](../evidence/zellij-live.md)) showed that each host's pane-addressed send lands only in its target. Claude submitted text plus CR from one write on every host. Codex left the same write in its composer and needed a separate CR. iTerm2's `write text` follows Broadcast Input, and AppleScript can neither suppress nor detect it. Terminal.app's `do script` always appends a newline. Zellij's `write-chars` to an unknown pane exits 0 and writes nothing. tmux's `send-keys` into a pane in copy mode hung in lab runs. The herdr proof ([herdr-ghostty-live](../evidence/herdr-ghostty-live.md)) showed a Codex question digit alone selects and submits an option (Codex 0.154.0). No other host has been tested with a question digit.

## Hosts

| Host | Send | Codex question digits | Replies |
| --- | --- | --- | --- |
| WezTerm | `send-text --no-paste --pane-id <id>` | yes | yes |
| tmux | `send-keys -t %<pane> -l`; Enter as `send-keys -t %<pane> Enter` | yes | yes |
| Zellij | `write-chars --pane-id <id> --session <name>`; Enter as `write 13` | yes | yes |
| herdr | `agent send_keys` to the pane id (ADR 0010) | yes | only after a live proof of a pane-addressed text send with a separate Enter |
| Ghostty | `send key` (ADR 0006); replies through `input text` | yes | only after a live proof that `input text` plus a separate Enter submits |
| Terminal.app | `do script "<text>" in <tab>` | no | yes |
| iTerm2 | none | no | no |

- **iTerm2 has no typed input.** Broadcast Input could carry a digit or a prompt into other sessions, including another Codex's question, and nothing Steer can read says whether it is on. iTerm2 sessions get Open only. The Python API's `suppress_broadcast` is a separate question on the map, because enabling it is user configuration.
- **Terminal.app has no question digits.** The forced newline could land on the next question's screen and submit its highlighted option.
- **Multiplexers:** a send needs only the pane layer of ADR 0014 to hold: the pane binding, its single-pane window or tab, no nesting, and for tmux a fresh read showing `pane_in_mode` 0. The host-tab join is not required, because the bytes never pass through the host tab. Every tmux, Zellij and herdr call has a bounded wait; a call that does not return in time counts as sent.

## Codex questions

ADR 0010's rules apply on every host in the table, with the host's send in place of `agent send_keys`:

- **Payload:** one digit `1` to `8` per clicked option, never Enter, text, Other, Skip or Escape.
- **Live proof per host:** a host's question route stays unavailable until a live run shows the digit alone commits there.
- **Fresh check** immediately before the key: the session's binding re-run on fresh reads (ADR 0013 or 0014), the agent still in the foreground, and the rollout re-read showing the call pending in its turn. herdr keeps its `blocked` veto.
- **Delivery:** one key per call and question index, spent before it is sent, after a click only. Any write that may have reached the terminal counts as sent and is never resent. A last answer with no rollout output within 10 seconds is unconfirmed. Only resolution evidence or Dismiss clears the question.

Claude questions are never typed. They are answered only through `updatedInput` while the `AskUserQuestion` helper is live. Otherwise the card offers Open and nothing else.

## Replies

- **Payload:** Claude gets the text and a CR in one write. Codex gets the text, then a separate CR one second later. On Terminal.app the forced newline is Claude's CR, and Codex gets a second `do script ""` one second later.
- **Text:** trimmed, 1 to 4000 characters, one line, no control characters. Text starting with `/` or `!` is refused, because it would run a slash command or a shell command; the card says to type it in the session.
- **Draft risk:** Steer cannot read the composer. A half-typed draft there is merged with the reply and submitted. Steer never clears the line first, because that would destroy the draft.
- **Fresh check** immediately before the first write:
  - the card's completion is still on the queue and belongs to the session's latest turn;
  - the session is idle, with no turn running and no pending question or approval. For Claude, a fresh interactive inventory reading must say idle; for Codex, the rollout must show the turn ended;
  - the binding is re-run on fresh reads and the agent is still in the foreground;
  - tmux is not in copy mode.
- **Sent:** any write that may have reached the terminal counts as sent, and nothing is ever resent. If Codex's text went in but its CR failed, the card says the text may be waiting in Codex's composer, and Steer never presses Enter later.
- **Confirmed:** the session's `UserPromptSubmit` within 10 seconds. The session then shows as working, and that turn start acknowledges its earlier completions as any prompt does. Without it, the reply is unconfirmed: "Check the session; Steer will not resend."

## Routes

- **Questions:** the Codex daemon wins whenever it holds the exact thread and call (ADR 0007). Otherwise the session's bound key route is used. Once any answer for a call has left Steer by one route, the rest of that call stays on it (ADR 0010).
- **Replies:** the daemon wins whenever it holds the thread. Otherwise the bound key route is used. One card sends at most one reply, by one route.
- A session that appears bound in two hosts is unavailable for input.
- An Open fallback ([ADR 0015](0015-raise-the-terminal-app-when-open-cannot-reach-the-exact-target.md)) is never an input target.

## Considered options

- **iTerm2 through `write text`:** Broadcast Input cannot be ruled out, so a send could reach an arbitrary terminal.
- **Question digits on Terminal.app:** the forced newline can answer the next question.
- **Claude questions by key:** Claude's dialog has no proven key map, and keys after a handback race the user.
- **Clear the composer before a reply (Ctrl-U):** destroys a draft the user wrote.
- **Digit and Enter for questions:** the herdr proof showed Enter is unnecessary, and a stray Enter can act on the next screen.
- **Require the multiplexer's host-tab join for input:** the host tab plays no part in where the bytes land, and requiring it would block answers whenever Open falls back.
- **Replies through keys only for Claude:** Codex sessions the daemon does not hold would keep no reply path.

## Not yet shown live

- A Codex question digit committing in WezTerm, tmux and Zellij.
- `input text` plus a separate Enter submitting in Ghostty, and a pane-addressed text send in herdr.
- Any typed input sent from a Steer code path on the new hosts, including the race against a manual answer and the copy-mode check.
