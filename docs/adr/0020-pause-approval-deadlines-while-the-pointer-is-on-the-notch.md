# Pause approval deadlines while the pointer is on the notch

Accepted on 2026-10-23, at the user's request. Before this, an approval's 30-second deadline ran from the companion's receipt and nothing the user did could move it. Now, while the user's pointer is on the notch, every live approval Herdly can decide stops counting down. When the pointer leaves, each one picks up with the time it had left. This replaces the "hover never extends it" rule.

## Decision

- **What pauses.** While the pointer is on the panel, every live approval Herdly can decide pauses: Codex CLI requests and Claude CLI requests with a verified live route. Keyboard focus alone does not pause them, because the user asked for hover. Desktop approvals are already handed back on receipt, so they are unaffected.
- **Bound.** No request stays open past 2 minutes after its receipt (`ApprovalTiming.maximumHold`); after that it counts down again even while hovered. A request with less than 1 second left (`holdMargin`) is not held, so the helper always sees the hold before its own deadline.
- **Only the user decides.** Holding never decides anything. Expiry, error, disconnect and uncertainty still hand back with no decision, and only an explicit Approve or Deny reaches the agent.
- **Rule and state.** `ApprovalHoverHold` is the pure rule. It takes the hover flag, the live approvals and the clock, and returns the held deadlines. The app applies them to both queues (`AgentAttentionQueue.hold`, `AttentionQueue.hold`). Holds live in process memory only and are never persisted, so a restart cannot recreate one.
- **Transport.** The app writes `<request>.hold` (Codex) or `<request>.claude.hold` (Claude) beside the receipt, holding `{request_id, held_until}`. It writes the file 1 second ahead of the deadline the notch shows, so the helper never hands back while the notch still offers Approve. The helper reads the file on every 20 ms poll. It bounds the value with `ApprovalTiming.heldDeadline`: later than the receipt deadline only, and at most 90 seconds past it. A missing, malformed or mismatched hold leaves the receipt deadline in force.
- **Hook timeouts.** The helper's wait bound becomes 121 seconds, and the Codex and Claude hook timeouts become 128 seconds. Setup upgrades the earlier 38-second entries in place. Until a session runs with the new timeout, its agent may stop the helper at 38 seconds and show its own prompt; nothing is approved in that case.
- **Countdown.** "Ns left" stands still while held. The bar measures against the request's own 30-second window, so it stands still too.

## Amendment 2026-10-30: Claude questions (#374)

Agreed with the user. A Claude question on the notch was handed back to Claude after a fixed 10 seconds, with no countdown and no pause, so the card could vanish mid-choice. A live Claude question now follows this ADR as a live approval does. Codex questions have no deadline and are unaffected.

- **Window.** 30 seconds from the helper's publish (`ClaudeQuestionTiming.answerTimeout`, equal to `ApprovalTiming.handoffTimeout`).
- **What pauses.** The same signal as approvals: the pointer on the notch, never keyboard focus alone, and only for a Claude question Herdly can answer (a receipt issued by this running companion). The same rule, `ApprovalHoverHold`, keyed by the helper request id, applies the same `holdMargin`.
- **Bound.** No question stays open past 2 minutes after publish (`ClaudeQuestionTiming.heldDeadline`, which caps at `publishedAt + maximumHold`).
- **Transport.** The app writes `<request>.question-hold` in the question rendezvous directory, the same `{request_id, held_until}` record, 1 second ahead of the deadline the notch shows. The helper re-reads it every 20 ms poll and keeps only a later, bounded deadline; an answer decided after the held deadline is refused. A missing, malformed or mismatched hold leaves the 30-second window. The app's own liveness checks, its pruning of expired rendezvous files and the delivery acknowledgment use the held deadline, so neither side gives up while the other still waits. Holds stay in process memory and are never persisted.
- **Hook timeout.** The question hook uses the same 128-second timeout, which covers the 5-second connection wait and the 2-minute bound.
- **Countdown.** The Claude question card and its queue row show "Ns left", standing still while held, with the approval countdown's styling and spoken label. Expiry sends nothing and leaves Claude's native question authoritative; nothing is ever answered on a timer.
- **Considered.** A separate question hold rule and store were rejected as duplicates of the approval ones; keeping the 10-second window with no countdown was the status quo the user asked to change.

## Considered options

- **Keep the fixed 30 seconds.** This was the default recommendation, and the user chose the hold instead.
- **Restart the full 30 seconds after each hover.** Rejected: repeated short hovers could keep the agent blocked without bound.
- **Unbounded pause.** Rejected: the agent stays blocked while Herdly waits, and a stuck hover flag would never release it.

## Not yet shown live

- A Codex CLI and a Claude CLI request held past 30 seconds and then approved from the notch, after setup has upgraded the hook timeouts.
- That Codex and Claude accept a 128-second hook timeout without a cap of their own.
- A Claude question held past 30 seconds by hover, then answered from the notch.
