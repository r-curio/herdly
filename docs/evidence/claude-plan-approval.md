# Claude ExitPlanMode approval (issue #74)

Recorded 2026-10-11 against Claude Code 2.1.296. Raw timeline: raw lab record not kept in the repo.

## Setup and limits

- **Isolation:** the #72 lab ([run_family_case.py](../../scripts/claude-permission-lab/run_family_case.py)) with
  `--permission-mode plan`. Claude was asked to write a one-line plan for creating `plan.txt` and present it
  with `ExitPlanMode` at once. Only the `ExitPlanMode` request got a companion decision.
- **Side effect outside the lab:** Claude writes each plan to `~/.claude/plans/<slug>.md` (the `planFilePath`
  input). The three lab plan files were removed after the runs.
- **Decisions:** scripted by the agent at the operator's explicit direction; none were human-clicked.

## Results

| Case | What happened | Result |
| --- | --- | --- |
| plan-allow | `PermissionRequest(ExitPlanMode)` with `plan` and `planFilePath`. The helper emitted a plain allow (no `updatedInput`), and Claude **did not apply it**: its "Ready to code?" dialog stayed open, no `PostToolUse` followed, and the session stayed in plan mode. The driver then answered the still-open dialog No, and Claude showed "User rejected Claude's plan". | Hook allow not applied |
| plan-deny | The helper emitted deny. Claude treated the plan as not approved, replied "DONE", and stayed in plan mode. | Deny applied |
| plan-handoff | `no_decision`; the dialog stayed; native No rejected the plan. | Pass |

Claude Code 2.1.296 marks `ExitPlanMode` as a tool whose dialog *is* the user-interaction surface
(`requiresUserInteraction()`). Its own source text says one-tap Approve/Deny must not be offered for such tools.

## Decision

**Exclude `ExitPlanMode`.** A plain hook allow did not approve the plan, so Steer cannot offer Approve. Claude's
source has a separate path where a hook supplying `updatedInput` satisfies such a tool; that was not exercised,
and it would mean Steer writing Claude's input, which the approval contract never does. A Deny-only
control would be a different product (rejecting a plan without seeing Claude's plan options), and Claude's
dialog also offers choices Steer must never make on the user's behalf: auto mode, manual edits, or feedback.
Plan approval stays in Claude. Steer may keep showing the session as waiting.
