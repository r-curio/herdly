# Claude permission transport (issue #71)

Recorded 2026-10-11 against Claude Code 2.1.296. Raw timeline: [claude-permission-transport.json](claude-permission-transport.json).

## Setup and limits

- **Session mode:** top-level interactive sessions. A first pass launched from inside Claude Code ran
  as nested child sessions, which write no session registry entry or transcript. The driver now clears
  `CLAUDECODE` and `CLAUDE_CODE_*`, and every case below was rerun that way, with the same hook results.
- **Isolation:** `claude --setting-sources project --permission-mode default --model haiku --strict-mcp-config`
  in `output/claude-permission-lab/project`. The user's hooks, permission rules and auto mode were not
  loaded, and no user settings file changed. The only action used was `Write` creating a marker file in
  the lab project, a harmless non-Bash permission request.
- **Helper:** [lab_helper.py](../../scripts/claude-permission-lab/lab_helper.py) mirrors SteerHook's Claude
  approval file protocol (request, heartbeat, receipt, decision, delivery, 30-second deadline from receipt)
  for any tool. The shipped SteerHook decides Bash only, so this proves Claude's side of the transport, not
  the packaged helper or the Steer app.
- **Decisions:** at the operator's explicit direction, the agent scripted every companion decision and
  native keystroke ([run_case.py](../../scripts/claude-permission-lab/run_case.py)). No human clicked a
  decision, which departs from the issue's "human makes every live decision" wording. The Steer notch
  was not involved.

## Results

| Case | What happened | Result |
| --- | --- | --- |
| allow | Receipt, then allow 2 s later. Claude showed "Allowed by PermissionRequest hook"; `PostToolUse` followed; file written. | Pass |
| deny | Receipt, then deny. "Denied by PermissionRequest hook"; no post-tool event; no file. | Pass |
| handoff | Receipt, then `no_decision`. The helper exited with no output; the native prompt stayed; native Yes wrote the file. | Pass |
| native | Native Yes at 3 s while the helper waited. The tool ran immediately. The helper kept running and emitted a deny about 4 s later, after `Stop`; Claude ignored it. | Pass, with a caveat (below) |
| native-no | Native No (Esc) at 3 s while the helper waited. No file. **No hook fired at all** (no post-tool, `PermissionDenied`, `Stop` or `StopFailure`) until `SessionEnd`. The registry went `waiting` to `idle` within 0.1 s. | Pass, with a caveat (below) |
| timeout | Receipt only. The helper exited silently at the 30-second deadline; the native prompt still worked (native No, no file). | Pass |
| helper-loss | The helper was killed with SIGKILL 3 s after receipt. The native prompt stayed and native No worked. A stale `.live` heartbeat file was left behind. | Pass |
| overlap | Two identical `Write` calls in one turn. Native Yes resolved the first; the second request then arrived with the same session, prompt, tool and path. A late allow for the first was emitted while the second waited. The second received only its own deny ("Denied by PermissionRequest hook"). The registry went `waiting`, `busy`, then `waiting` again for the second dialog. | Pass |

## Transport contract for later family proofs

1. **No `tool_use_id`.** `PermissionRequest` carries `session_id`, `prompt_id`, `tool_name`, `tool_input`,
   `permission_mode`, `permission_suggestions`, `cwd`, `transcript_path`, `scratchpad_dir` and `effort`.
   The matching `PreToolUse` fires about 0.08 s earlier with `tool_use_id`.
2. **Claude runs the calls one at a time.** The two `Write` calls from one response ran in sequence: the
   second `PreToolUse` fired only after the first call's `PostToolUse`. At each `PermissionRequest`, exactly
   one unmatched `PreToolUse` existed for that session, prompt and tool, so the existing single-candidate
   rule matched. Tools that Claude runs in parallel were not tested.
3. **Each hook invocation is its own authority.** A fresh helper-minted request id per invocation kept
   decisions isolated. A late decision for an earlier request never reached a later one with identical
   identity and input.
4. **The native prompt is always shown and wins races.** While the hook waits, Claude shows its own
   prompt. A native answer applies at once, and **Claude does not cancel the waiting hook**. A later hook
   decision is ignored. So a written `.delivery` record proves the helper emitted a decision, not that
   Claude applied it. Whether Claude applied it comes from tool evidence: `PostToolUse` for the matched
   `tool_use_id` after an allow, or no tool run after a deny.
5. **Silence hands back.** No stdout (handoff, no receipt, deadline, crash or kill) leaves the native
   prompt as the authority. No case produced an implicit decision.
6. **The session registry shows when Claude's prompt closes.** `<CLAUDE_CONFIG_DIR>/sessions/<pid>.json`
   switched to `waiting` (with `statusUpdatedAt`) 60–120 ms *before* each of the 9 `PermissionRequest`
   records was captured. It changed again within about 0.1 s of every answer, whether a native Yes, a
   native No, or a hook allow or deny. A native No produces no hook event, so this is the only fast
   signal for it. Because Claude shows one prompt at a time per session, a status change *after* a
   request arrived means that request's prompt has closed. Status `waiting` alone is not enough: in the
   overlap case the registry was `waiting` again for the next request.
7. **Prompt-pending signal.** A `Notification` with `notification_type: permission_prompt` arrived about
   6 s after an unanswered request. It carries no request identity.
8. **Cleanup.** A killed helper cannot remove its heartbeat file, so liveness must depend on heartbeat age,
   never on whether the file exists. Records stay in the lab events directory; nothing outside the lab
   was written.

## Follow-ups this suggests

- Done after this proof: when this was recorded, Steer removed a Claude approval row on the matched
  `PostToolUse` (native Yes) at its next scan, and a native No left the direct controls live until the
  30-second deadline. Steer now hands back an actionable Claude approval when the registry shows the
  same session's `statusUpdatedAt` later than the request's arrival
  ([Claude observations](../claude-observations.md)). The `claude agents --json` fallback has no such
  timestamp and keeps the deadline. Since 2026-11-06 the same evidence removes the row instead,
  including a row already handed back, so it no longer waits for a long tool to finish.
- The helper could apply the same check to stop waiting without emitting, so a late click is reported
  as unconfirmed rather than received.
- A human-clicked rerun through the real notch is still needed if the operator wants #71's original
  wording met, and before claiming any non-Bash family in #72–#75.
