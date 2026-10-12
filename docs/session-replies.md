# Replying to a session from its completion card

A CLI completion card carries a single-line field: the user reads that a session finished, types "now add tests", and sends it to that session without switching applications. The reply starts a new turn on that exact thread through the local app-server daemon, the same verified transport that answers questions by call id ([user-input requests](user-input-requests.md), [ADR 0007](adr/0007-connect-to-the-codex-daemon-socket-as-the-same-user.md)). Desktop completion cards omit the reply field, Send button, and reply status because Steer has no supported desktop reply transport. Open in Codex and dismissal remain available.

## The only transport

`turn/start` on the daemon socket carries the reply:

```
{"jsonrpc":"2.0","id":7,"method":"turn/start",
 "params":{"threadId":"01a09d9b-…","input":[{"type":"text","text":"now add tests"}]}}
```

Params and shapes follow the schema the installed CLI generates (`codex app-server generate-json-schema --out <dir>`, 0.154.0): `TurnStartParams` requires `threadId` and `input`, and every other field is an override of the thread's model, effort, sandbox policy, approval policy, working directory or service tier. Steer sends none of them, so the reply inherits exactly the settings the session already has.

The socket itself is proven: a second client connects, subscribes and receives a real `item/tool/requestUserInput` ([ADR 0007](adr/0007-connect-to-the-codex-daemon-socket-as-the-same-user.md), `docs/evidence/app-server-daemon-live.json`). `turn/start` is not: no run on the installed CLI has yet started a turn from Steer, so this is a source-level finding about the method, not a proven capability. The live walkthrough below is what would establish it.

The Ghostty relay is not a second path. It delivers one key name to a matched tab and was verified for that alone (ADR 0006); nothing proves it can type a whole prompt and a Return into one unsplit tab, so a session the daemon does not hold has no reply path in Steer at all. Amended on 2026-10-11 by [ADR 0017](adr/0017-type-question-digits-and-replies-into-one-bound-pane.md): typing the reply into the session's one bound pane is a second path, used only when the daemon does not hold the thread, on the hosts that ADR lists. It is built for Terminal.app (#239, below) and WezTerm (#240, below), and is the only reply path for Claude Code sessions. `turn/steer`, which interjects into a running turn, is not used either: a completion card is about a turn that has ended.

## Typed into the bound tab (#239)

[ADR 0017](adr/0017-type-question-digits-and-replies-into-one-bound-pane.md)'s second route is built host-neutrally in `Sources/SteerCore/TerminalTypedInput.swift`; Terminal.app is its first host. Other hosts reuse it when their tickets set `TerminalHost.typesReplies` and supply their send.

- **Route:** each scan turns the session's tab binding (ADR 0013) into a `TerminalReplyRoute`: `pane` for the exact binding on a host that types replies, `unreachable` for no exact binding ("Steer can't reach this session's tab. Reply in the session."), `hostCannotType(.iTerm2)` ("Steer can't type into iTerm2. Reply in the session."), or none, which leaves the daemon's reasons below. `SessionReplyRouting.target` checks ended, then working, then the daemon (which wins whenever it holds the thread), then the typed route. An Open fallback is never an input target.
- **Text:** trimmed, 1 to 4000 characters, one line without control characters, never starting with `/` or `!` (`TypedReplyText`). The daemon route keeps its existing rules.
- **Writes:** Claude gets text and submit in one write; Codex gets the text, then a separate submit one second later (`TypedReplyWrites`). On Terminal.app each write is one `do script … in <tab>`, which appends the newline itself, so Codex's submit is an empty `do script` (`TerminalAppInput`).
- **Fresh check before every write** (`TypedReplyCheck`): the completion still queued and the session's latest; the session idle (Codex: not in a turn and the rollout shows the turn ended; Claude: a fresh interactive inventory reads idle); no pending question or approval; the daemon not holding the thread; and the binding re-run on fresh reads (two Terminal.app inventories and `ps -t`) naming the same tab. Any veto before the first write sends nothing. The card then refuses another send, including when the daemon took over the thread after the click ("Codex's daemon now holds this session; nothing was sent. Reply in Codex."). That is the current conservative choice, applying "one card sends at most one reply" to a send that started; whether a card whose send sent nothing may send again is an open product decision, not agreed behavior.
- **Sent:** `TypedReplySequence` sends each write at most once. A write that may have reached the tab counts as sent and is never resent. If Codex's text went in but its submit was vetoed or not written, the card says the text may be waiting in Codex's composer, and Steer never presses Return later. Confirmation is the session working again within ten seconds; otherwise "Check the session; Steer will not resend."
- **Claude cards** show the field only while a host that types replies is on (`ClaudeReplyRouting`), with the same one-reply rules.

Automated: `TerminalTypedInputTests` (hosts and routes, the daemon winning, text rules, write plans, Terminal.app delivery, every fresh-check veto, the check before every write, the one-second submit, no resend, the composer case, Claude routing) and `TerminalAppTests`. Live application proof: none; not run — needs live acceptance (#244).

### WezTerm (#240)

WezTerm is the route's second host (`TerminalHost.wezTerm.typesReplies`), behind its hidden switch. Each write is one `wezterm cli --no-auto-start send-text --no-paste --pane-id <id> -- <payload>` (`WezTermInput`): Claude's payload is the text and a CR, Codex's is the text, then a CR alone one second later, as the live proof required. `--` keeps text starting with `-` from being read as an option. The fresh check before every write re-runs the binding on fresh reads of every enabled host (WezTerm read twice with `ps -t` between). A send that exited 0 is written; nothing run (no binary, no trusted socket) or WezTerm's "no such pane" is not written; any other error or a timeout may have typed and counts as sent. Terminal.app's and WezTerm's latest scans each give a route, merged so that anything other than one exact pane wins (`TerminalReplyRoute.merging`). Automated: `WezTermTests`. Live application proof: none; not run — needs live acceptance (#245).

## When the field is offered

For CLI cards, `SessionReplyRouting.target` reads what Steer can see at that instant, in this order:

| Evidence | Card |
| --- | --- |
| Codex recorded the session's end | disabled: "This session has ended; there is nothing to reply to." |
| The session is in a turn | disabled: "This session is working again; send your next prompt in Codex." |
| No daemon connection | disabled: "No Codex daemon is running, so Steer cannot reach this session; reply in Codex." |
| The daemon does not list the thread as loaded | disabled: "Codex's daemon is not holding this session; reply in Codex." |
| The daemon holds the thread | the field and Send are live |

An ended session has nowhere to put a turn; a session that started another turn is an ambiguous target, because a `turn/start` against it is not the interjection the user is imagining (`turn/steer`, which does interject, is a different method with an `expectedTurnId` precondition and is not used here). Both are told plainly rather than attempted.

"In a turn" is read from `AttentionQueue.sessionsInTurn`, not from the rows on screen: a session blocked on a question has its running row withheld from the display but is mid-turn all the same, and a reply to it would be exactly the ambiguous send this rule exists to refuse.

## One card, one reply

Enter in the field or the Send button sends once. The policy is re-applied against the queue's current copy of the completion and the target as they are at that moment, never the row that was rendered, and the text is trimmed, non-empty and at most 4000 characters. Then the card follows one path only:

- **sending** — the request is in flight; the field and button are disabled.
- **sent** — the daemon accepted it: "Sent “now add tests”. Waiting for Codex to record the turn."
- **working** — Codex started a turn on the session, and a late turn still counts. That turn start also acknowledges the completion (below), so the card leaves the queue in the same scan and the session's working row is the confirmation the user sees; the card's own sentence ("Codex started a turn; this session is working again.") is not shown. The card still never sends again: the acknowledged completion is off the queue, so another send is refused as no longer on the queue.
- **unconfirmed** — ten seconds passed with no turn: "Check Codex; Steer will not resend."
- **failed** — the daemon refused the request or the write never left: the reason, and "Steer will not retry."

No phase but `.ready` sends anything, no timer sends anything, and a failure is final: Steer never resends a prompt it cannot prove failed to arrive. Progress is in memory, so a restart returns the card with an empty field and nothing is re-sent.

## Sending is not acknowledgment

Sending leaves the completion exactly where it was: a send Codex never takes acknowledges nothing. Amended on 2026-10-08: once Codex records the turn the reply started (its `UserPromptSubmit`), that turn start acknowledges the session's earlier completions, as any prompt in a CLI session does ([product behavior](product.md)). The card then leaves the queue and the session shows as working.

## Verification

Source inspection: the generated schema defines `TurnStartParams` and `UserInput` as used above. Nothing here has been run against a live daemon.

Automated: `Tests/SteerCoreTests/SessionReplyTests.swift` covers the target for a loaded thread, each unavailable reason, the `turn/start` shape, send-once (in flight, after the daemon took it, after it failed), refusal for an absent completion and unusable text, a session blocked on a question counting as in a turn, the waiting-then-confirmed/unconfirmed rule, and that sending acknowledges nothing. `Tests/SteerCoreTests/CodexReplyAcknowledgmentTests.swift` covers the turn start acknowledging only that session's earlier completions from other turns, and the acknowledgment reaching the shared queue's card.

Automated against the real binary: `scripts/daemon_lab.py` seeds a second, finished session beside the one holding the pending question, and records where each completion card's reply field would send, without sending anything — `daemon(thread: …)` behind a private socket, `unavailable(noDaemon)` with no socket (`docs/evidence/app-server-daemon-lab.json`).

Live walkthrough, once a daemon is running (`codex app-server daemon start`):

1. Finish a turn in a CLI session attached to the daemon and switch away. Expect: the completion card with a live reply field.
2. Type "now add tests" and press Enter. Expect: "Waiting for Codex to record the turn", then the card leaving the queue and the session shown as working, and that prompt as the next turn in Codex — in that session and no other.
3. If Codex never records the turn, the completion stays on the queue until it is dismissed or its tab is visited.
4. Stop the daemon and finish another turn. Expect: the field disabled and the card saying no daemon is running.
