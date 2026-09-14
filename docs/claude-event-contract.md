# Claude event and identity contract

Research resolution for [Establish Claude’s event and identity contract](https://github.com/r-curio/steer/issues/33), under [Claude Code parity: find the path to an implementation backlog](https://github.com/r-curio/steer/issues/32). Checked 2026-09-14.

**Recommendation:** use command hooks as the primary adapter, but keep approval delivery separate from evidence that a request resolved. Do not treat a stopped response as an irrevocably finished prompt. The two live-proof tickets can now proceed; this report resolves research, not runtime compatibility or product policy.

## Evidence boundary

| Evidence | Established here | Not established |
| --- | --- | --- |
| Installed CLI | `claude --version` returned `2.1.270 (Claude Code)`; executable resolves to `/Users/dev/.local/share/claude/versions/2.1.270` | Actual event payloads, ordering, native handoff, or cancellation behavior |
| Local CLI help | Advertises `--settings`, `--setting-sources`, `--session-id`, and `--debug-file` | Complete isolation from managed policy or a working lab launch |
| Read-only binary token inspection | Contains `prompt_id`, `PermissionRequest`, `terminalSequence`, and `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` | Reachability, semantics, or title persistence; string presence is weak evidence |
| Installed Ghostty | Bundle version `1.3.1`; scripting dictionary exposes terminal IDs/titles, tab selection, and terminal focus | Session-to-tab binding or successful navigation |
| Steer source | Inspected commit `ee780d644af99ad612d55ac208ec098695e97a38` | Claude support, tests, or live proof |
| Current official documentation | Contracts below | A version-pinned guarantee for every feature in 2.1.270 |

Only help/version and read-only inspection ran. No model invocation, interactive session, real settings change, or approval experiment occurred. The earlier conversation was a list of leads; findings below were rechecked. Public SDK source describes SDK types, not attachment to an existing terminal session.

## Primary-source findings

### Hook reference: critical caveats

`prompt_id` identifies the current prompt from v2.1.196; it is absent before input. Transcripts can lag. `Stop` excludes user interrupts; `StopFailure` covers API errors. Stop hooks can continue work. Running-tool cancellation need not emit `PostToolUseFailure`. `PermissionDenied` covers auto-mode denials, not manual rejection.

`PermissionRequest` omits `tool_use_id`; sandbox network prompts bypass it. Its decision accepts `allow` or `deny`; permission rules still apply. `updatedPermissions` changes permissions. No decision preserves the permission flow, which can deny where prompting is unavailable. Async hooks cannot decide permissions.

`PostToolBatch` supplies call IDs and serialized results after a batch, worth testing before adding transcript dependencies. `Elicitation`/`ElicitationResult` provide server and optional elicitation identity. `terminalSequence` supports title escapes only in an interactive, displayed interface. `SessionEnd` JSON output is discarded. [Hook reference](https://code.claude.com/docs/en/hooks)

### Coverage and timing

The guide supplies the lifecycle vocabulary: `SessionStart`/`SessionEnd`, `UserPromptSubmit`, `PreToolUse`, tool results, `Stop`/`StopFailure`, `SubagentStart`/`SubagentStop`, and compaction events. Matching hooks execute in parallel; a successful observer does not establish the combined outcome. In a terminal, permission notifications wait roughly six seconds, including sandbox network attention; idle notifications wait roughly sixty seconds. Background completion notifications depend on agent-view context and cannot be assumed universal. [Hook guide](https://code.claude.com/docs/en/hooks-guide)

### Identity cross-check

The official Python SDK declares tool-call IDs on pre-tool, successful-result, and failed-result hook inputs, but not permission-request input. Child tool activity carries `agent_id`; its comments specifically warn that parallel child events interleave. `agent_type` alone does not identify a child. The SDK’s separate permission callback has a tool-call ID, which must not be mistaken for the command-hook contract. Its base hook type omits newer fields such as `prompt_id`, reinforcing that SDK types are a cross-check rather than the complete current CLI schema. [Pinned SDK types](https://github.com/anthropics/claude-agent-sdk-python/blob/37a52c9fb3f0271de017911914b0d42efea6267e/src/claude_agent_sdk/types.py#L239)

### Questions, recovery, and navigation

`AskUserQuestion` carries questions, headers, options, and multi-selection information. The SDK’s callback examples show an application collecting answers, not a companion observing an already-running CLI. [User-input reference](https://code.claude.com/docs/en/agent-sdk/user-input)

Claude keeps session JSONL and child transcripts under its projects directory. Running-session metadata is separate and cleaned after exits/crashes. Transcripts can contain secrets and persistence can be disabled. [Application data](https://code.claude.com/docs/en/claude-directory#application-data)

The official environment-variable search index documents `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`; the current rendered English page did not expose that entry during this research. Local binary presence supports testing this candidate, not declaring it operational. [Environment variables](https://code.claude.com/docs/en/env-vars)

Ghostty’s documented window/tab/terminal hierarchy and focus operations fit the existing adapter approach. They do not identify which Claude session owns a terminal. [Ghostty AppleScript](https://ghostty.org/docs/features/applescript)

## Proposed adapter boundaries — engineering recommendations

These are proposals to take into the later behavior/architecture decisions, not additional upstream guarantees.

| Identity | Proposed boundary |
| --- | --- |
| Conversation | Agent kind plus upstream session ID; project path is display context |
| Prompt | Conversation plus supplied prompt ID; preserve missingness rather than borrowing the last active prompt |
| Tool call | Conversation, child agent when supplied, prompt when supplied, and upstream tool-call ID |
| Live approval | Fresh helper-invocation ID and receipt/deadline; never route a click by command text |
| Child | Parent conversation plus supplied `agent_id`; do not promote each child result into a top-level completion |
| Completion | Preserve the observed stop occurrence separately until experiments establish whether one prompt can yield several meaningful stops |
| Surface | Fresh unique unsplit Ghostty target, independent of conversational identity |

A repeated helper event must not extend its deadline. Two identical commands remain separate requests. Replayed lifecycle observations must not resurrect a resolved item or replay sound. Delayed events from an older prompt must not clear or overwrite newer activity. Local arrival time is observation order, not proof of upstream causal order.

The existing [approval parser](../Sources/SteerCore/ApprovalIngress.swift) requires Codex’s UUID `turn_id` and generates a separate request UUID. Add Claude normalization instead of weakening Codex parsing. [Queue identities](../Sources/SteerCore/AttentionQueue.swift) distinguish `desktop`/`cli`, but not agent kind; qualify agent ownership consistently, including persisted acknowledgments. [Completion visibility](../Sources/SteerCore/CompletionVisibility.swift) currently hides everything when Codex is foreground; Claude needs its own originating-surface evaluation. Preserve the [product’s](product.md) no-decision handoff and evidence-based acknowledgment rules.

Observe questions without emitting answers. Distinguish ordinary questions from MCP forms/browser authentication. Where elicitation identity is missing, do not clear one request from another same-server response.

Start with small bounded event writes. Register the lifecycle/tool/question events that serve these behaviors; measure overhead. Keep direct approval on a separately bounded synchronous path. No hook should inject model context, request continuation, edit tool inputs, or change persistent permissions for this integration.

## Exact gaps and narrow reconciliation

1. **Permission-to-call association:** helper identity safely routes a decision but does not prove which later tool result resolves the reminder. Retain the unresolved relationship when multiple candidates exist; nearest event, identical command text, and shared prompt are insufficient. A lab may establish an association under constrained conditions; do not generalize it to concurrent calls without evidence.
2. **Manual rejection and interruption:** test batch results first. Add bounded incremental transcript reads only for missing cases, using the supplied known session path and matching call identity. Capture actual record shapes before implementing a reader. Missing/truncated files mean unknown, never resolved.
3. **Response stop versus final completion:** no reviewed source establishes an irrevocable post-all-hooks completion receipt. Fresh activity must invalidate provisional stopped state. Notification timing is not a finality guarantee. Whether a provisional response notification is acceptable is a human decision if evidence cannot close this gap.
4. **Session versus process lifetime:** duplicate resumed instances can share conversational identity. Session-end observations must not erase another live instance solely because the session ID matches. Reject ambiguous targeting; establish any process attribution in the lab.
5. **Sandbox network attention:** there is no basis here for direct permission controls through this hook. Keep it native; bring any resulting parity limitation to the behavior ticket.

## Smallest live-proof experiments

Use a disposable project, temporary hook JSON, per-invocation event files, controlled harmless commands, and sanitized evidence. Record CLI/Ghostty versions and effective hook sources before starting. Local help and the [CLI reference](https://code.claude.com/docs/en/cli-reference) support `--settings` and `--setting-sources`; verify their actual isolation and managed-policy effects. Do not use bare/safe modes that disable the hooks being measured. Do not modify real permission settings.

### Prove Claude lifecycle and approval handoff

| Experiment | Minimum evidence and pass condition |
| --- | --- |
| Two prompts, one question, one child | Record full identity fields and event order; answering clears only that question, child completion does not finalize the parent |
| Harmless Bash requiring permission | Separately choose allow, deny, and native handoff; record helper outcome, native prompt, and actual execution/non-execution |
| Timeout, helper failure, user returns | Verify prompt recovery without approval; include a late click and demonstrate it cannot affect a later request |
| Two identical requests | Exercise same prompt/parallel child cases where producible and two sessions; show whether correlation is exact or explicitly unavailable |
| Manual denial and interrupted running tool | Compare individual result hooks, batch payloads, and transcript call IDs; identify the smallest sufficient cleanup evidence |
| Stop continuation and API failure | Use one isolated Stop hook that continues once; record whether provisional completion is retractable. Simulate API failure only in disposable configuration |
| Network permission and MCP form/URL | Use controlled fixtures; keep answers native; record notification latency and missing/available request IDs |
| Restart, duplicate, reorder | Replay sanitized records with missing IDs and interrupted writes; no resurrected buttons, false completion, or cross-request clearing |

Actual live actions need the user for the HITL ticket. Replay checks supplement them; they do not substitute for native behavior. If a scenario cannot be produced, record it as uncovered rather than passed.

### Prove exact Claude tab targeting in Ghostty

Test a previewed title such as `Steer Claude <full-session-id>` using hook output and the title-disable candidate. Begin with two unsplit tabs in the same directory and another window. Observe initial startup, resume, rename, compaction, and exit; record fresh inventories and the exact selected target before/after navigation. A print-mode run cannot prove terminal behavior.

Repeat with a duplicate resumed session, renamed title, closed tab, and a split tab as negative controls. Every ambiguous, stale, split, or missing target must be unavailable; there is no cwd/title-substring fallback. Check restoration of the previous title on clean exit and the behavior after abrupt termination; do not assume SessionEnd can restore it via JSON.

## Resolution and handoff

Research is complete enough to unblock the two proof tickets. No runtime guarantee is marked passed. Live payloads and transport tests determine feasibility; the later grilling tickets decide user-visible uncertainty, capability gaps, setup ownership, and final adapter shape. Additional experiments should be ticketed only when these results expose a precise new question. No product implementation or expanded scope is authorized by this report.
