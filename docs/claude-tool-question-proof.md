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
| 5 | `question-late`: repeat checkpoint 1. | Type `late-answer 1 35 <your choice>`, then answer the native question yourself when it remains available. | Helper expires at 30 seconds; late file changes nothing; native answer supplies the post event. |
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

Pending live human checkpoints on Claude Code 2.1.273. Prior lifecycle evidence already establishes success cleanup and the lack of sufficient hook cleanup for native denial and an interrupted foreground Bash call; this ticket will confirm the remaining ordinary tool-failure case and decide the exact product rule together with the question results.
