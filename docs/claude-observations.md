# Claude observations

Steer observes Claude Code through the per-root helper event directory. Each record is accepted only
when its source marker and installation id match the configured root, and every accepted observation
is bounded before it reaches the shared `AgentAttentionQueue`.

The helper retains event and session identity, source and installation markers, timestamps, a bounded
prompt fallback (240 characters), and only the scalar command or path fields needed for a current
action. A longer prompt keeps its first 240 characters with an ellipsis and a `prompt_shortened`
mark instead of being dropped, so its working row still shows it; the row's disclosure then says the
text is shortened and the full prompt is in Claude. Helpers before 2026-10-08 dropped any prompt over
240 bytes, so a working row started under one has no prompt text.
An `AskUserQuestion` record retains bounded question text and option labels so the notch can
show the same choices Claude is showing. The separate live request carries the helper invocation
identity, the normalized Claude configuration root, and the separate normalized event directory; its
helper-owned liveness marker is refreshed only while the hook waits, and a delivery acknowledgment
is written only after Claude's response is emitted. A restart cannot turn its saved request record
into an answer capability.

The reader recognizes session, prompt, tool, question, approval, and outcome events. Tool text is
kept only while a matching `PostToolUse`, `PostToolUseFailure`, or `PostToolBatch` has not cleared
the exact call, or while the bounded current tool state is still fresh. A mismatched or late post
event cannot clear a newer call. If Claude denies or interrupts a call without a post event, a later
`Stop` or `SessionEnd` clears the tool detail without inventing a finished outcome. `StopFailure`
records a failed outcome; `Stop` alone never records a terminal outcome.

Each `UserPromptSubmit` also yields reply evidence for its exact session and root, timed at the
prompt's earliest capture. The queue acknowledges that session's outcomes from other turns that
arrived strictly before it, whichever of the two is observed first, and records them as acknowledged
so rescans and restart recovery cannot restore them. Reply evidence never creates a row and never
touches another session, root, or source ([product](product.md), 2026-10-08).

An unmatched pre-tool action is considered fresh for 30 seconds from its captured timestamp. After
that bound, the reader falls back to the general running prompt until newer evidence supplies a
current action.

Permission observations require exactly one matching, uncompleted `PreToolUse` call in the same
session, prompt, root, and tool name. Only `Bash` creates a direct approval observation. The helper
adds a bounded request token because `PermissionRequest` does not supply `tool_use_id`; Steer
publishes a receipt only for that exact candidate while the helper's short-lived heartbeat is fresh,
and accepts one allow or deny before the request's 30-second deadline. The helper acknowledges a user decision only after emitting Claude's response;
missing acknowledgment leaves delivery uncertain and never claims that Bash executed. Ambiguous,
malformed, late, repeated, or cross-root records are ignored. A missing receipt, helper crash,
restart, interruption, expiry, or handoff emits no decision and leaves Claude's native prompt
available. A root that cannot be read is unavailable for reconciliation, so it cannot clear another
root's attention. The root-scoped inventory (Claude's session registry,
`<CLAUDE_CONFIG_DIR>/sessions/<pid>.json`, read first, with `claude agents --json` as the
fallback; see [Claude setup](claude-setup.md)) is a weaker source: a valid interactive `busy`/`waiting` row may add only a generic running row; background
lifecycle rows alone do not create queue items. Idle and background terminal states remove
inventory-derived rows. As a fallback for a Stop that never ends the row (missed, pruned, or not
sent), an interactive `idle` reading also ends a hook-derived running row once that turn's hooks have
been quiet for two minutes; it creates no outcome, and only newer hook evidence reopens the row. A
session reading `busy` or `waiting` keeps its row however long it is quiet, because a long tool call
or answer fires no hooks.
An unavailable or duplicate inventory leaves both inventory and hook evidence untouched. A later
valid interactive `idle` observation confirms a previously observed provisional `Stop`. When that
turn's result was already acknowledged (dismissed, replied to, or acknowledged before a restart), the
confirmation creates no new result but still ends the turn's running row, and running evidence no
newer than the confirmation cannot reopen it; newer tool evidence for the same prompt still can. Inventory
alone never creates an outcome, tool label, question, approval, sound, or target. Duplicate
interactive resumes therefore remain one session identity with an explicit unavailable-control signal
and no unique direct target until a later poll is unique. Older per-root polls are ignored, so an
out-of-order empty snapshot cannot erase newer generic lifecycle state.

## Evidence status

- **Source inspection:** the Claude hook definitions, bounded helper records, reader, root-scoped
  intake, and queue reconciliation implement the rules above.
- **Automated checks:** `ClaudeObservationTests` covers exact post cleanup, late and ambiguous calls,
session-end uncertainty, installation/root isolation, and late outcomes. `ClaudeInventoryTests`
covers separate interactive/background lifecycle fields, duplicate and unavailable polls, root
isolation, weaker inventory evidence, and provisional `Stop` confirmation. The helper self-test also
checks bounded Claude metadata and tool input. `ClaudeQuestionTests` covers unchanged `updatedInput`,
single-select, multi-select, typed answers, exact identity rejection, one-shot writes, and the
receipt/answer rendezvous. `ClaudeApprovalTests` covers the one-winner deadline,
atomic receipt/decision/delivery records, one-winner concurrency, helper crash handback, and Claude's exact allow/deny output shape. The app/helper build,
packaged smoke check, and helper self-test pass on this branch.
- **Live application proof:** pending. Restarting Steer during one real Claude session and observing
its current state without replaying sound or fabricating a question was deferred for the user's
walkthrough tomorrow; one live answer of each supported shape and native fallback after helper
timeout are also deferred. This change does not claim those scenarios passed.
