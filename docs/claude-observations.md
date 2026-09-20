# Claude observations

Steer observes Claude Code through the per-root helper event directory. Each record is accepted only
when its source marker and installation id match the configured root, and every accepted observation
is bounded before it reaches the shared `AgentAttentionQueue`.

The reader recognizes session, prompt, tool, question, approval, and outcome events. Tool text is
kept only while a matching `PostToolUse`, `PostToolUseFailure`, or `PostToolBatch` has not cleared
the exact call, or while the bounded current tool state is still fresh. A mismatched or late post
event cannot clear a newer call. If Claude denies or interrupts a call without a post event, a later
`Stop` or `SessionEnd` clears the tool detail without inventing a finished outcome. `StopFailure`
records a failed outcome; `Stop` alone never records a terminal outcome.

Permission observations require exactly one matching, uncompleted `PreToolUse` call in the same
session, prompt, root, and tool name. Ambiguous, malformed, late, repeated, or cross-root records
are ignored. A root that cannot be read is unavailable for reconciliation, so it cannot clear another
root's attention.

## Evidence status

- **Source inspection:** the Claude hook definitions, bounded helper records, reader, root-scoped
  intake, and queue reconciliation implement the rules above.
- **Automated checks:** `ClaudeObservationTests` covers exact post cleanup, late and ambiguous calls,
  session-end uncertainty, installation/root isolation, and late outcomes. The helper self-test also
  checks bounded Claude metadata and tool input.
- **Live application proof:** pending. The isolated run of a real Claude tool followed by continued
  `Stop` was deferred for a separate manual check tomorrow; this change does not claim that scenario
  passed.
