# Claude tool cleanup and interactive question proof

Task ticket [Prove Claude tool cleanup and interactive question answers](https://github.com/r-curio/steer/issues/66), under [Claude Code parity: find the path to an implementation backlog](https://github.com/r-curio/steer/issues/32). This extends the already-proven [Claude lifecycle lab](claude-lifecycle-proof.md); it records compatibility facts, not product implementation.

## Contract under test

Claude Code's hook reference says `PreToolUse` may return `permissionDecision: "allow"` with `updatedInput`. For `AskUserQuestion`, the output must preserve the original `questions` array and add `answers`, keyed by exact question text. The documentation explicitly establishes this for non-interactive runs with a permission host; this lab tests whether installed Claude Code 2.1.273 also accepts it in an already-running interactive CLI.

The helper accepts one question only. That is enough to prove single choice, multi-select, and per-question free text without adding a form engine to a disposable probe. More than one question hands back to Claude's native UI.

## Isolation and identity

Run from `/private/tmp/steer-claude-tool-question`. `scripts/claude-lifecycle-lab/run.sh` creates a fresh git project and session ID, passes `--setting-sources ""`, and loads only its generated settings file. It does not read or change the user's real Claude, Ghostty, or Codex configuration. Managed policy still applies.

Each request records `session_id`, `prompt_id`, `tool_use_id`, the unchanged tool input, receipt time, and a fresh helper request ID. The companion's answer must repeat all four identities before the helper emits `updatedInput`. Missing, malformed, mismatched, empty, late, or unsupported input produces no hook answer, leaving Claude's native question in control. An answer file is created atomically and cannot be replaced.

## Human checkpoints

Use two unsplit Ghostty tabs. Start only the named checkpoint; compile it before moving to the next one. In tab 1 run the scenario command. It prints the exact tab-2 companion command. In Claude, paste the prompt exactly. In tab 2, type only the answer you personally select.

| Checkpoint | Scenario and prompt | Human action | Evidence |
| --- | --- | --- | --- |
| 1 | `question-single`: `Use AskUserQuestion to ask exactly "Which color do you choose?" with options Red and Blue, single-select. After the answer, reply with exactly "You chose <answer>."` | Type `answer 1 Red` or `answer 1 Blue` in the companion. | Exact identities; accepted `updatedInput`; matching `PostToolUse`; no native question decision. |
| 2 | `question-multi`: ask exactly `Which environments should run?`, options Development, Staging, Production, multi-select. | Type `answer 1 <the labels you choose, comma-separated>`. | Multiple selected labels reach Claude unchanged. |
| 3 | `question-free-text`: ask exactly `What release note should I use?`, options Short and Detailed, single-select. | Type `answer 1 <your own text that is neither option label>`. | Per-question free text reaches Claude unchanged. |
| 4 | `question-one-shot`: repeat checkpoint 1. | Type the same `answer` command twice. | First answer wins; the second atomic write is refused; only one post event. |
| 5 | `question-late`: repeat checkpoint 1 with `STEER_LAB_QUESTION_TIMEOUT=15`. | Type `late-answer 1 20 <your choice>`, then answer the native question yourself when it remains available. | Helper expires at 15 seconds; late file changes nothing; native answer supplies the post event. |
| 6 | `question-helper-crash`: repeat checkpoint 1. | Answer only in Claude's native UI. | Hook exit 1 falls back without answering. |
| 7 | `question-helper-hang`: repeat checkpoint 1. | Answer only in Claude's native UI after waiting for the hook timeout. | Hook timeout falls back without answering. |
| 8 | `question-coexist`: repeat checkpoint 1. | Answer in the companion. | Unrelated observer hook sees the exact event and does not interfere. |
| 9 | `question-restart`: repeat checkpoint 1. | Start companion, wait for its receipt, type `q`, restart the same printed command, then answer. | A restarted companion can answer only while the same exact helper invocation remains live; later restarts cannot revive it. |
| 10 | `tool-cleanup`: in one session run a successful `printf`, a failing `python3 -c 'raise SystemExit(7)'`, a native denial, and an approved foreground command interrupted with Esc. | Make the stated native allow/deny choices. | Success clears on matching `PostToolUse`; failure on matching `PostToolUseFailure` if emitted; denial/interruption retain uncertainty until later prompt, stop, or session evidence if no exact cleanup hook exists. |

After each checkpoint, `/exit` Claude, `q` the companion, then run:

```sh
python3 scripts/claude-lifecycle-lab/compile.py
```

Do not infer a pass from visible UI alone. Preserve the sanitized run until it has been compiled into `docs/evidence/`; raw transcripts, credentials, and unrelated configuration do not belong in the artifact.

## Results

Live checkpoints completed on Claude Code 2.1.273 and macOS 26.5 with isolated settings and disposable projects. Sanitized traces are in [`docs/evidence/claude-tool-question-lab-interactive.json`](evidence/claude-tool-question-lab-interactive.json). The prior [Claude lifecycle proof](claude-lifecycle-proof.md) supplies the matching success, native-denial, and running-tool-interruption cases.

### Interactive question answers

- Installed Claude accepted `PreToolUse` `permissionDecision: "allow"` with the original `questions` plus `answers` in `updatedInput` in an already-running interactive CLI. Matching `PostToolUse` repeated the same `session_id`, `prompt_id`, `tool_use_id`, questions, and answer.
- A single option (`Red`), multi-select labels (`Development, Staging`), and per-question free text (`Ship after QA approval`) all reached Claude unchanged.
- The helper accepted one immutable answer. A second conflicting write was refused and Claude kept the first answer. An answer written after helper expiry had no effect; Claude recorded the human's different native answer instead.
- An injected helper exit and an injected hook timeout each supplied no answer. Claude's native question remained available and its human-selected `Blue` answer produced the normal matching post event.
- An unrelated observer hook saw the same exact question call without interfering. Restarting the companion preserved the first receipt and answered only because the original exact helper invocation was still live; the expired-helper case proves a restart cannot revive it later.

Therefore the Claude adapter may answer `AskUserQuestion` from Steer on 2.1.273 through a live `PreToolUse` helper keyed by session, prompt, tool-use, and fresh helper-request identity. It may return only the human's answer with the unchanged questions. Failure, timeout, mismatch, unsupported question shape, or loss of the live helper returns no answer and leaves Claude native. Lower Claude versions and managed policies that disable or restrict hooks remain unsupported until separately proved.

### Tool-label cleanup

- A successful tool clears its current label on matching `PostToolUse`; the prior lifecycle proof records this on Bash.
- An ordinary tool failure clears its current label on matching `PostToolUseFailure`; the live Read failure carried the exact `session_id`, `prompt_id`, and `tool_use_id`, followed by `PostToolBatch` and `Stop`.
- Native denial and interruption of an already-running foreground Bash call produced no sufficient post hook in the prior live proof. Their transcript result text was also identical, so the adapter must not infer which occurred.

The exact presentation rule is: a `PreToolUse` label is current only while its exact call is unresolved and the live inventory still reports the session busy. Clear it on matching `PostToolUse` or `PostToolUseFailure`. If no matching post arrives, clear the specific label on a later prompt, stop/failure, session end, or a supported inventory observation that the session is no longer busy; fall back to the prompt or general waiting/idle state without classifying denial versus interruption. Never restore a tool label after Steer restarts. If neither hook nor inventory can establish freshness, the specific tool label is unavailable rather than asserted current.

### Downstream decisions

- **Agree Claude parity behavior and capability gaps:** direct single-choice, multi-select, and typed question answers are supported on the evidenced runtime; native fallback is mandatory. Tool labels are prospective only and deliberately lose specificity when cleanup is uncertain.
- **Choose the shared adapter and recovery boundary:** keep question answering in the Claude hook adapter with exact live-call identity. Keep `agents --json` inventory separate and use it only to bound label freshness and session state. Persisted request metadata cannot recreate an answer channel after the helper expires.
- **Agree reversible Claude setup and coexistence:** add the question hook through the same reversible composed settings path; preserve coexisting hooks and report hook policy restrictions instead of changing policy.
