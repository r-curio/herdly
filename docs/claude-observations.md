# Claude observations

Steer observes Claude Code through the per-root helper event directory. Each record is accepted only
when its source marker and installation id match the configured root, and every accepted observation
is bounded before it reaches the shared `AgentAttentionQueue`.

The helper retains event and session identity, source and installation markers, timestamps, a bounded
prompt fallback (240 characters), and only the scalar command or path fields needed for a current
action. An `AskUserQuestion` record retains bounded question text and option labels so the notch can
show the same choices Claude is showing. The separate live request carries the helper invocation
identity; a restart cannot turn its saved request record into an answer capability.

The reader recognizes session, prompt, tool, question, approval, and outcome events. Tool text is
kept only while a matching `PostToolUse`, `PostToolUseFailure`, or `PostToolBatch` has not cleared
the exact call, or while the bounded current tool state is still fresh. A mismatched or late post
event cannot clear a newer call. If Claude denies or interrupts a call without a post event, a later
`Stop` or `SessionEnd` clears the tool detail without inventing a finished outcome. `StopFailure`
records a failed outcome; `Stop` alone never records a terminal outcome.

An unmatched pre-tool action is considered fresh for 30 seconds from its captured timestamp. After
that bound, the reader falls back to the general running prompt until newer evidence supplies a
current action.

Permission observations require exactly one matching, uncompleted `PreToolUse` call in the same
session, prompt, root, and tool name. Ambiguous, malformed, late, repeated, or cross-root records
are ignored. A root that cannot be read is unavailable for reconciliation, so it cannot clear another
root's attention. The root-scoped `claude agents --json` inventory is a weaker source: a valid
interactive `busy`/`waiting` or background `working`/`blocked` row may add only a generic running
row, while idle and background terminal states remove only inventory-derived rows. An unavailable
or duplicate inventory leaves both inventory and hook evidence untouched. A later valid
interactive `idle` observation confirms a previously observed provisional `Stop`; inventory alone
never creates an outcome, tool label, question, approval, sound, or target. Duplicate interactive
resumes therefore remain one session identity with an explicit unavailable-control signal and no
unique direct target until a later poll is unique. Older per-root polls are ignored, so an out-of-
order empty snapshot cannot erase newer generic lifecycle state.

## Evidence status

- **Source inspection:** the Claude hook definitions, bounded helper records, reader, root-scoped
  intake, and queue reconciliation implement the rules above.
- **Automated checks:** `ClaudeObservationTests` covers exact post cleanup, late and ambiguous calls,
session-end uncertainty, installation/root isolation, and late outcomes. `ClaudeInventoryTests`
covers separate interactive/background lifecycle fields, duplicate and unavailable polls, root
isolation, weaker inventory evidence, and provisional `Stop` confirmation. The helper self-test also
checks bounded Claude metadata and tool input. `ClaudeQuestionTests` covers unchanged `updatedInput`,
single-select, multi-select, typed answers, exact identity rejection, one-shot writes, and the
receipt/answer rendezvous.
- **Live application proof:** pending. Restarting Steer during one real Claude session and observing
its current state without replaying sound or fabricating a question was deferred for the user's
walkthrough tomorrow; one live answer of each supported shape and native fallback after helper
timeout are also deferred. This change does not claim those scenarios passed.
