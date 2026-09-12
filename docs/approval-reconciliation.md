# Reconciling approvals answered in Codex — issue #10

Status: implemented for the verified CLI integration; desktop remains native-only. Agreed behavior is in [product.md](product.md); the transport is described in [desktop-approval-investigation.md](desktop-approval-investigation.md) and [cli-notch-integration.md](cli-notch-integration.md).

## What changes

A handed-back request ("Continue in Codex") now clears on three kinds of evidence, and on nothing else:

1. **Native resolution recorded in the session rollout.** Codex writes the exec tool call and its output into `~/.codex/sessions/.../rollout-*.jsonl`. `ApprovalResolutionReader` matches a request to the earliest exec call in its exact turn with its exact command whose terminal output was recorded after the companion receipt, and classifies the runtime wrapper text: `Script completed`/`Chunk ID`/`Process exited` → executed, `Script failed`/`exec_command failed` with `Rejected(` → rejected, `aborted by user` → interrupted, anything else terminal → unclassified. `Script running with cell ID n` is not evidence; the reader follows the later `wait`/`write_stdin` calls for that cell until one records a terminal output. One exec script can await several commands; each command is registered under the same call and consumed once.
2. **The exact turn ended** (`task_complete` or `turn_aborted`), as before.
3. **The session ended** (a SessionEnd hook received after the request arrived). A native prompt cannot outlive its process.

Matching keys on session, turn, command and receipt time together, never on session or command alone. A request whose payload carried no command, or whose rollout lacks turn metadata, is never matched; it waits for its turn or session to end. Output text after the wrapper is never inspected, because command output can contain any wording. Malformed or partial rollout lines are skipped, which can delay evidence but cannot invent it.

`AttentionQueue.resolve(requests:)` removes exactly the matched identities and records them so a later scan that cannot read the rollout does not revive them. Completions and other requests are untouched.

## Release, reconnection and restart

- **Open in Codex** on an actionable CLI request writes the no-decision record first, then navigates. Codex shows its own prompt within the helper's next poll (20 ms), not at the 30-second deadline. Returning to the originating Ghostty pane still hands back through the focus check. Desktop requests are released on receipt, unchanged.
- **Regained focus knowledge** never reactivates a request: the queue keeps a handed-back state even when a later scan reports the same request as pending with a receipt, and `ApprovalDecisionPolicy` accepts a decision only for an actionable, unexpired, CLI request as the queue currently holds it. The decision path re-reads the queue's copy rather than trusting the row that was rendered.
- **Restart revalidation**: while a request file still says `pending`, a saved decision record decides its state (a no-decision record → handed back; allow/deny → answered by Steer, not queued). A helper-written `no_decision` outcome is authoritative on its own, so a late allow record written for a request whose helper already timed out cannot hide the reminder.
- **Companion loss**: the helper hands back at its own deadline (30 s from receipt) or 5 s connection timeout with no decision and no hook output. Codex then shows its native prompt. Nothing is approved and no policy changes.
- **Honest absence of evidence**: the handed-back row says the request was handed back with no decision and that Steer has not seen an answer yet, and names what clears it. It no longer implies that permission is still pending.

## Automated checks

`swift test` (74 tests). New in `Tests/SteerCoreTests/ApprovalResolutionTests.swift`: native deny via cell follow-up, native allow from direct output, a still-running prompt and an earlier identical command are not evidence, simultaneous requests by command and order (including twin commands), one exec script with several commands, missing turn/command/session identity, malformed and partial lines, interrupted output, the legacy `function_call` shape, reader-to-queue clearing of only the matched request, session-end resolution ordering, hook SessionEnd parsing, regained focus not reactivating, restart revalidation from decision records, the decision policy, and a late decision for an older request never reaching a newer one.

`Tests/SteerCoreTests/LiveResolutionEvidenceTests.swift` runs the real reader against a recorded lab directory when `STEER_LIVE_EVENTS` is set; it is a no-op otherwise.

## Live evidence (2026-09-12, Codex CLI 0.145.0)

Records: `docs/evidence/cli-approval-resolution.json`, produced by `scripts/cli-approval-lab/resolution_run.py`, `helper_race.py` and the live reader test. Each CLI case ran a real interactive Codex TUI in the trusted `output/desktop-hook-lab` project through a pseudo-terminal with `-s read-only -a on-request`, the lab's `.codex/hooks.json` swapped to this branch's release `SteerHook` for the run and restored afterwards, and hook trust bypassed per invocation only. The companion receipt came from `companion_standin.py`; after the helper handed back, the driver answered **Codex's own prompt** by keystroke ("Yes, proceed (y)" or esc, which in this TUI cancels the request and interrupts the turn). No global hook, permission policy, sandbox setting or user configuration changed.

| Case | Handoff | Native answer | Codex result | Reader evidence |
| --- | --- | --- | --- | --- |
| native-allow | helper deadline, 30 s after receipt | y | marker created, `task_complete` | executed, from the exec call output |
| native-deny | helper deadline | esc | no marker, `turn_aborted` | interrupted, from the `wait` follow-up output |
| companion-killed | stand-in SIGKILLed 3 s after receipt; helper handed back 30 s after receipt | y | marker created, `task_complete` | executed |
| open-in-codex | no-decision record 2 s after receipt (what Open in Codex writes) | esc | native prompt appeared at once; no marker; `turn_aborted` | interrupted |
| parallel (two requests, one turn) | no-decision records 2 s after each receipt | y for B, driver cancel for A | B created; turn aborted | both requests resolved from the one multi-command exec call |
| parallel-both-allowed | same | y, y | both created, `task_complete` | both executed from the same call |

In every case the reader left no request in the queue and cleared nothing else. The stand-in's decision writes never reached Codex in these runs; every answer was native.

Helper race checks (`helper_race.py`, real release helper, no Codex): a click 27 s after receipt produced `allow`; a click 31 s after receipt found the helper already handed back with no output; after a disconnect the helper handed back 30.0 s after receipt with no output, and a late allow record for that old request was never consumed while a newer request in the same session and turn received its own `deny`; two simultaneous requests in one session and turn received `deny` and `allow` on their own ids.

## Boundaries

- A native answer in the **Codex desktop app** was not exercised: desktop requests are still released on receipt by policy, no desktop approval transport is verified, and computer use of the desktop app is prohibited for the agent. The reader's desktop shape (a yielded exec followed by `wait` outputs carrying `Rejected("rejected by user")` or `Script completed`) is taken from the real desktop rollouts recorded on 2026-09-11 and covered by fixtures, not by a fresh desktop run.
- The rollout is written by Codex after the fact; the companion polls every two seconds, so clearing lags the native answer by a few seconds. A yielded exec script that awaits several commands reports one output for all of them, so a request in such a script clears when the script finishes, not when its own prompt is answered.
- Answers in these runs were driven by keystrokes into the lab TUI rather than a person; the return-to-Ghostty-pane handoff and the notch button click remain the human checks recorded for issue #9 and #3.
