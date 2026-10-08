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

The Ghostty relay is not a second path. It delivers one key name to a matched tab and was verified for that alone (ADR 0006); nothing proves it can type a whole prompt and a Return into one unsplit tab, so a session the daemon does not hold has no reply path in Steer at all. `turn/steer`, which interjects into a running turn, is not used either: a completion card is about a turn that has ended.

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
- **working** — Codex started a turn on the session, and a late turn still counts. That turn start also acknowledges the completion (below), so the card leaves the queue in the same scan and the session's working row is the confirmation the user sees; the card's own sentence ("Codex started a turn; this session is working again.") is not shown. The phase stays recorded, so the card never sends again.
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
