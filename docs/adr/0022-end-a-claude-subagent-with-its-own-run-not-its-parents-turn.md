# End a Claude subagent with its own run, not its parent's turn

Accepted on 2026-11-10, with the user's agreement in two owner-decision comments on #404 (the 30-minute bound, and keeping the row working while subagents run). Before this, a Claude subagent ended when its session's turn ended (`Stop`, `StopFailure` or `SessionEnd`, #395). A subagent started with `run_in_background` keeps working after that, so its well left the opened working row (#397) while it still ran, and its later permission request could be dropped with its parent turn.

## Decision

- **A subagent has its own run.** The run starts at its `SubagentStart` and ends at its first `SubagentStop` at or after that start, or at its session's `SessionEnd`. When the parent turn has ended, an open run also ends 30 minutes after it started (`ClaudeObservationReader.maximumSubagentAge`). A parent turn has ended once a `Stop`, a `StopFailure` or a submit of another prompt follows the start. A subagent inside a live turn has no age bound, so a long foreground subagent is never cut short.
- **One rule, two readers.** `ClaudeSubagentLifetimes` decides each run from one hook directory's records. The Claude reader uses it for the switcher, the cache expiry and which requests are a running subagent's. `HookEventRetention` uses it for which calls are still open and which starts to keep. The two never decide separately, so pruning can never bring back a request the reader resolved or drop one it still shows. The rule also bounds `agent_id` and `prompt_id` the same way on both sides.
- **The row stays working while a subagent runs.** While a Claude session's working row lists a running subagent, `AgentAttentionQueue` does not confirm the provisional `Stop` from an idle registry reading and does not apply the two-minute idle grace. Once no subagent is listed, the usual rules resume: the session's next idle reading confirms its pending `Stop` and the result goes to check, which is how the owner's "next stop produces the to-check card" works in the queue. The hold covers `Stop` only, because a `StopFailure` is a result the user must see at once.
- **A subagent's request follows its run.** A request whose call belongs to a run Herdly saw start carries that subagent's id (`AgentApproval.subagentID`, not persisted). The parent turn's result, a newer prompt and the parent's `Stop` do not resolve it. The run's end does. A request with no usable id resolves by the same evidence as before. Only the user's choice decides any request, and deadlines are unchanged.

## Considered options

- **Show the subagents on the to-check card.** Rejected: the agreed design (Paper H2) puts the switcher only in an opened working row, and a card that lists running work blurs working and to check.
- **Accept the row flickering between working and to check.** Rejected: the well would come and go with each subagent tool call, which is the bug in a different form.
- **Apply the 30-minute bound always.** Rejected: it would drop foreground subagents that legitimately run longer inside a live turn.
- **Keep separate rules in the reader and retention.** Rejected after review: they drifted on stops captured before a call, session resumes, ties in capture time and malformed prompt ids, and each drift either resurrected a reminder after a restart or dropped a live one.

## Consequences

- A session with a background subagent counts as working, not to check, until the subagent ends. Its result card arrives later.
- A lost `SubagentStop` keeps a well for at most 30 minutes after its parent's turn ended.
- A subagent start with no valid prompt id is bounded only by its parent's `Stop` or `StopFailure`, not by a newer prompt.
- A request from a subagent Herdly never saw start is not tied to a run. After a `StopFailure` it stays in Claude's own prompt.
