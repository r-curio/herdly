# Claude lifecycle and approval handoff proof

Task ticket [Prove Claude lifecycle and approval handoff](https://github.com/r-curio/steer/issues/35), under [Claude Code parity: find the path to an implementation backlog](https://github.com/r-curio/steer/issues/32). Inputs: the [Claude event and identity contract](https://github.com/r-curio/steer/blob/1ff97ebe313a542ce7c00cbd5cec2c8508bfe7f3/docs/claude-event-contract.md).

This document holds the disposable probe, the procedure, the evidence gathered so far, and the human checklist. It records facts. It does not accept reduced parity; that is the later behaviour ticket's decision.

## Probe

`scripts/claude-lifecycle-lab/` (never installed, never touches real configuration):

| File | Role |
| --- | --- |
| `run.sh <scenario>` | Launches one isolated interactive Claude session in a fresh disposable git project under `runs/<scenario>-<time>/project`, with a generated hook settings file, a fresh `--session-id`, `--permission-mode default`, `--model sonnet` (override with `LAB_MODEL`), and `--debug-file`. |
| `probe.py` | The hook handler. Every registered event is appended, sanitized, to `runs/<run>/events/<session_id>.jsonl` with wall/monotonic time, hook pid/ppid and the `CLAUDE_*` identity env. For `PermissionRequest` on Bash it stands in for Steer's helper: publishes one fresh request, waits ≤5 s for a companion receipt, then ≤30 s from the receipt for a decision bound to that exact request. No receipt, no decision, expiry, mismatch, malformed or late records all hand back (no output, exit 0) so Claude's native prompt appears. |
| `companion.py <run>` | Stand-in for the notch, run by the human in a second Ghostty tab. Writes the receipt, prints each request, and only acts on what the human types: `a n` allow, `d n` deny, `h n` hand back, `late a n 45` late click, `dup`/`wrong` invalid records. Auto modes `receipt` and `none` exist only for timing runs. It never decides on its own. |
| `other-hook.sh` | Unrelated coexisting hook for the `coexist` scenario; logs to its own file, never decides. |
| `compile.py [--json out]` | Prints the ordered trace per run, joins events by `tool_use_id`, and lists companion and helper actions. |
| `transcript_peek.py <run> [tool_use_id…]` | Read-only, bounded look at the session transcript for the records tied to given call ids (manual denial / interruption comparison). |

Isolation: `--setting-sources ""` plus `--settings <generated file>`. `~/.claude/settings.json`, project and local settings are not loaded; managed policy would still apply (none is installed: the debug log reports the managed path missing). The user's real hooks, permission rules and terminal settings are never modified. Nothing runs in bypass or print mode for the interactive scenarios.

## Evidence so far (agent, non-interactive)

Recorded 2026-09-15 with Claude Code 2.1.272, Ghostty 1.3.1, print mode (`-p`) only, haiku model, nested from an agent session with the `CLAUDECODE` family of variables unset. Raw compiled trace: [`docs/evidence/claude-lifecycle-lab-noninteractive.json`](evidence/claude-lifecycle-lab-noninteractive.json). These establish payload shapes and isolation, **not** interactive behaviour.

1. **Isolation is real.** The user settings' `env` value reached hooks only when `--setting-sources user` was passed; with `""` it was absent. The user's `Notification`/`Stop` osascript hooks did not appear in the debug log.
2. **Lifecycle order in one prompt:** `SessionStart` (no `prompt_id`, `source: startup`) → `UserPromptSubmit` (`prompt_id`, field is `prompt`, not the documented `prompt_text`) → `Stop` (`prompt_id`, `stop_hook_active`, `last_assistant_message`, plus undocumented `background_tasks`, `session_crons`) → `SessionEnd` (`prompt_id`, `reason: other`). Every hook process received `CLAUDE_CODE_SESSION_ID` equal to the payload session id and `CLAUDE_PID` equal to the CLI pid (hook ppid), so process attribution is available from the environment.
3. **`PermissionRequest` in 2.1.272 carries no `tool_use_id` and no `timeout`**, contrary to the current hook reference. It carries `session_id`, `prompt_id`, `permission_mode`, `tool_name`, `tool_input` (`command`, `description`) and `permission_suggestions`. The preceding `PreToolUse` (0.27 s earlier) carried the `tool_use_id`. Correlation to a call is therefore inferential (same session, same prompt, same tool input, adjacent order), exactly the gap the contract named. The helper's fresh request id still routes the decision safely.
4. **No-decision handoff in print mode:** the helper handed back after its deadline (35.0 s, receipt-only companion). Print mode cannot prompt, so Claude treated the call as unavailable: the next events were `PostToolBatch` with `tool_calls: [id]` and **empty** `tool_outputs`, then `Stop`. **No `PostToolUseFailure` and no `PermissionDenied`** fired. Whether an interactive manual rejection behaves the same is exactly what the human runs must show.
5. **Hook process cost:** every event spawned a Python process; the probe added roughly 0.1–0.3 s between adjacent events in these traces. Measure again with the real helper before deciding registration scope.

## Human procedure

Do each scenario in a fresh run. Tab 1 is the Claude tab, tab 2 the companion; both are unsplit Ghostty tabs. Read the run directory printed by `run.sh` and start the companion with it. After each scenario, `/exit` Claude, `q` the companion, and run `python3 scripts/claude-lifecycle-lab/compile.py` to check the trace before moving on. Use only the harmless commands below. Never type an answer you would not give for real; the point is to observe.

| # | Scenario | Tab 1 (Claude) | Tab 2 (companion) | Pass / record |
| --- | --- | --- | --- | --- |
| 1 | `lifecycle` | Prompt A: `Reply with exactly ok.` Prompt B: `Use the AskUserQuestion tool to ask whether I prefer red or blue, then reply with my answer.` Answer it natively. Prompt C: `Use the Agent tool (subagent_type Explore) to list the files here, then summarize in one line.` Prompt D: `Count slowly from 1 to 300, one number per line.` Press Esc mid-way. Then `/exit`. | not needed | Two distinct `prompt_id`s; question events (which event, which ids, does an answer produce an event); `SubagentStart/Stop` with `agent_id` and parent `Stop` after; what, if anything, fires on Esc (expect no `Stop`); `SessionEnd` reason on `/exit`. |
| 2 | `approval-allow` | `Run the bash command touch ALLOW-1 and reply done.` | when the request prints: `a 1` | Helper outcome `allow`; command ran (`ls` shows the file); no native prompt appeared; `PostToolUse`/`PostToolBatch` ids match the `PreToolUse` id. |
| 3 | `approval-deny` | `Run the bash command touch DENY-1 and reply done.` | `d 1` | Helper outcome `deny`; file absent; which events follow (`PostToolUseFailure`? `PermissionDenied`? batch shape); what Claude says. |
| 4 | `approval-handoff` | `Run the bash command touch HANDOFF-1 and reply done.` | `h 1` | Helper outcome `companion_handoff`; native prompt appears; allow it natively; events after a native allow. |
| 5 | `approval-timeout` | same with `TIMEOUT-1` | start companion as `companion.py <run> receipt`; touch nothing | Native prompt appears ≈30 s after the request; note whether Claude showed anything while waiting; then allow natively. Record the `Notification` `permission_prompt` timing relative to the hook. |
| 6 | `approval-no-companion` | same with `NOCOMP-1` | do not start it | Helper `no_receipt_handoff` after 5 s; native prompt; allow natively. |
| 7 | `helper-crash` | same with `CRASH-1` | not needed | Hook exits 1; native prompt still appears; any stderr shown to the user; nothing published. |
| 8 | `helper-hang` | same with `HANG-1` | any | Hook exceeds its 45 s timeout; record what Claude does (native prompt? error?) and when. |
| 9 | `approval-late` | `Run touch LATE-1 and reply done.` Then a second prompt: `Run touch LATE-2 and reply done.` | request 1: `late a 1 45`; when the native prompt for LATE-1 appears, **deny it natively**; request 2: wait for the native prompt and allow natively | The late `allow` for request 1 changes nothing (LATE-1 absent); request 2 has a fresh id and the late record for 1 never touched it; helper outcomes `expired_handoff` then `no decision`. |
| 10 | `approval-native-deny` | `Run touch NDENY-1 and reply done.` | `h 1` | Deny at the native prompt. Compare `PostToolUseFailure`, `PermissionDenied`, `PostToolBatch` and `transcript_peek.py <run> <tool_use_id>` for that id; identify the smallest sufficient cleanup evidence. |
| 11 | `interrupt-tool` | `Run the bash command touch INTERRUPT-STARTED && python3 -c 'import time; time.sleep(90)' in the foreground. Do not background it. Wait for completion, then reply done.` | `a 1` | Press Esc while it runs. Which of `PostToolUseFailure`, `PostToolBatch`, transcript records, and `Stop` fire, with which ids. A bare `sleep 90` is rejected and then backgrounded by 2.1.273, so it cannot exercise this path. |
| 12 | `parallel` | `In one single response, call Bash twice in parallel: touch PAR-A and touch PAR-B. Then reply done.` | allow both as they print, in either order | Two requests with distinct fresh ids; whether both `PermissionRequest` hooks fire concurrently; whether the helper's inferred call correlation is ambiguous (record it as unavailable if so); `PostToolBatch` lists both ids. |
| 13 | `identical` | `Run touch SAME-1, then run exactly the same command again as a second, separate Bash call. Reply done.` Also open a second `run.sh identical` session in a third tab and run `touch SAME-1` there. | allow each | Identical text yields separate requests and separate `tool_use_id`s; two sessions are told apart by `session_id`; nothing is cleared across them. |
| 14 | `stop-continue` | `Reply with exactly ok.` | not needed | The armed Stop hook asks for one continuation. Record: two `Stop` events for one `prompt_id`, the second with `stop_hook_active: true`; whether the first would have been a false completion. |
| 15 | `api-failure` | `Reply with exactly ok.` | not needed | `ANTHROPIC_BASE_URL` points at a closed port. Record `StopFailure` payload and whether `Stop` also fires. |
| 16 | `coexist` | Scenario 2 again with `COEX-1` | `a 1` | The probe's decision applied while an unrelated second `PermissionRequest`/`PreToolUse` hook also ran (`other-hook.log` shows the same event); no interference. |

Not covered by this probe and to be recorded as unproven: sandbox network prompts, MCP elicitation forms and URL auth, resumed duplicate instances of one session id, and compaction mid-approval.

## Results (human, interactive)

Sanitized traces are compiled in [`docs/evidence/claude-lifecycle-lab-interactive.json`](evidence/claude-lifecycle-lab-interactive.json). Runs use Claude Code 2.1.273, Ghostty 1.3.1 and macOS 26.5 unless noted.

### Lifecycle

- Ordinary prompts each received a distinct `prompt_id`; their matching `Stop` reused that id.
- `AskUserQuestion` produced `PreToolUse` and `PostToolUse` with one `tool_use_id`, not a question-specific event. The post event recorded the human's native `Red` answer under both `tool_input.answers` and `tool_response.answers`; the parent `Stop` followed.
- The Explore child used its own `agent_id` on `SubagentStart`, child Bash events and `SubagentStop`. The parent emitted a `Stop` immediately after launching it, then the child result arrived as another `UserPromptSubmit` with a new `prompt_id` and another parent `Stop`. Two later `SubagentStop` events carried different agent ids without matching observed starts; their meaning is unproven.
- Pressing Esc while Claude streamed a count stopped visibly at 97 and showed `Interrupted · What should Claude do instead?` (human screenshot). The only hook was the original `UserPromptSubmit`: no `Stop`, `StopFailure` or interruption event fired.
- `/exit` emitted `SessionEnd` with `reason: prompt_input_exit` and a fresh `prompt_id`.

### Bash allow and native-prompt race

- A native allow while the helper was still waiting created `ALLOW-1`; `PostToolUse`, `PostToolBatch` and `Stop` arrived before the helper's 30-second expiry. A companion allow written after expiry had no effect.
- The first prompt companion attempt exposed a probe defect: it returned `decision: "allow"`. Claude rejected that exact output and required `decision: {"behavior":"allow"}`. `test_probe.py` now drives the real helper subprocess and locks down the accepted shape.
- With the corrected output, the human typed `a 3`; Claude validated the hook response, logged `permissionDecision: allow`, created `ALLOW-3`, and emitted the matching `PostToolUse`, `PostToolBatch` and `Stop`. The human gave no native decision.
- `Notification(permission_prompt)` still fired about six seconds after `PermissionRequest`, before the companion allow returned at 10.4 seconds. Direct hook decisions therefore race the native prompt after Claude's notification delay; the adapter cannot assume the native prompt remains hidden for its full 30-second window.
- In all three requests, `PermissionRequest` omitted `tool_use_id`; the adjacent `PreToolUse` and later result carried it.

### Deny, explicit handoff, timeout and absent companion

- A companion deny returned in 2.0 seconds, left `DENY-1` absent, then produced only `PostToolBatch` with the call id and empty outputs followed by `Stop`. Neither `PostToolUseFailure` nor `PermissionDenied` fired.
- Explicit `h 1` returned no hook output in 6.3 seconds. Claude's native prompt remained, the human chose Yes, and `HANDOFF-1` was created with matching post-use, batch and stop events.
- With receipt only, the helper expired after 30.2 seconds. Claude had already emitted `Notification(permission_prompt)` at six seconds; the human waited past helper expiry, then chose native Yes and created `TIMEOUT-1`.
- With no companion, Claude exposed and accepted its native prompt while the helper was still inside its five-second receipt wait: `PostToolUse` arrived 1.5 seconds after `PermissionRequest`, then the helper recorded `no_receipt_handoff` at 5.0 seconds. `NOCOMP-1` was created. The native surface is therefore concurrent with the command hook, not something the helper's no-decision return reveals.

### Helper failures and native denial

- An injected helper exit 1 was recorded by Claude as a PermissionRequest hook error, but the concurrently available native Yes still created `CRASH-1`; normal post-use, batch and stop hooks followed.
- An injected 90-second helper sleep did not block the native permission surface. `Notification(permission_prompt)` fired at six seconds; the human waited more than 50 seconds, chose Yes, and `HANG-1` was created. No helper outcome event was recorded, so the runtime terminated or abandoned the hook before it could return normally.
- After explicit no-decision handoff, native `No` left `NDENY-1` absent. No `PostToolUseFailure`, `PermissionDenied`, `PostToolBatch`, `Stop` or `SessionEnd` hook followed. The debug log records `Bash tool permission denied`, but that is not a hook contract.
- A bounded transcript read found the exact call id as a `tool_result` with `is_error: true` and content beginning `The user doesn't want to proceed with this tool use`. This is the only exact durable native-denial evidence observed in the scenario; missing, delayed or disabled transcripts must remain unknown.

### Late decisions and interrupted execution

- Request 1 scheduled a companion allow 45 seconds later, then the human chose native No; `LATE-1` stayed absent. Request 2 used a fresh request id, was allowed natively and created `LATE-2`. Its helper expired after 30 seconds. The late record was written only to request 1 and never affected request 2.
- A bare `sleep 90` did not test interruption: 2.1.273 first rejected standalone sleep, then retried it in the background and completed the parent turn. The corrected foreground command created `INTERRUPT-STARTED`, proving execution began, then the human pressed Esc and saw `Interrupted · What should Claude do instead?`.
- No `PostToolUseFailure`, `PostToolBatch` or `Stop` hook followed that interrupted foreground call. The transcript's exact call-id result had `is_error: true` but reused the same `The user doesn't want to proceed` text as the pre-execution native denial. Call identity plus marker/timing can prove this lab interruption; the transcript text alone cannot distinguish rejection from interruption.
- The corrected interrupt prompt's `UserPromptSubmit` observer timed out after ten seconds and its event was absent, while later tool hooks were captured. This isolated observer failure is recorded, not treated as evidence that the prompt lacked identity.

### Stop continuation and API failure

- One `Stop` hook requested continuation. Claude emitted two `Stop` events for the same `prompt_id`: first `stop_hook_active: false` with `ok`, then `stop_hook_active: true` with `continued`. The first stop was not final.
- A closed-port API endpoint produced the visible `Connection refused` retry UI (human screenshot at attempt 4/10); the debug log recorded 11 total attempts. After about three minutes, `StopFailure` fired for the original prompt with `error: server_error` and the full connection-refused message. No `Stop` fired. `/exit` then emitted `SessionEnd(reason: prompt_input_exit)` with a fresh prompt id.

### Parallel, identical and coexisting requests

- Claude did not run two Bash permission hooks concurrently. In one response it requested, allowed and executed `touch PAR-A`, then did the same for `touch PAR-B`; the final `PostToolBatch` listed both distinct call ids. Each helper invocation had a fresh request id, but neither PermissionRequest carried its call id.
- Two identical `touch SAME-1` calls in one prompt had separate tool-call ids and separate helper request ids. A simultaneous second session used a different session id, prompt id, tool-call id and helper request id for the same command text. All three decisions reached only their own helper invocation.
- In the coexistence run, the unrelated hook recorded the same PreToolUse and PermissionRequest while emitting no decision. The probe's allow still validated, `COEX-1` was created, and normal post-use, batch, stop and session-end events followed. Multiple hooks can observe the event; this run does not establish resolution rules for conflicting decisions.

## Evidence boundary after live proof

Established on Claude Code 2.1.273 in unsplit Ghostty 1.3.1 tabs: isolated hook loading, lifecycle and prompt identities, native questions, child-agent event separation, Stop continuation, API failure, explicit companion allow/deny, concurrent native permission UI, no-decision handoff, helper absence/crash/hang, late-decision isolation, native denial and running-tool interruption cleanup gaps, serialized multi-call permissions, identical commands across sessions, and coexistence with an observer hook.

Still unsupported or unproven: sandbox network prompts, MCP elicitation forms and URL authentication, duplicate live instances of one resumed session id, compaction during approval, a reliable hook-only distinction between native rejection and interruption, and exact PermissionRequest-to-tool-call identity without ordered PreToolUse inference. These are evidence gaps, not accepted parity reductions.
