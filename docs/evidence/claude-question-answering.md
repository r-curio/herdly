# Claude question answering evidence

## Source inspection

`SteerHook --agent claude --question-helper` writes one bounded live request for an `AskUserQuestion`
`PreToolUse` call, waits for a receipt, and emits Claude's `permissionDecision: allow` response with
the unchanged `questions` input plus `answers`. The app issues the receipt and keeps the answer token
only in memory. The request is bound to the installation, normalized Claude configuration root,
separate event directory, session, prompt, tool-use, and fresh request identity; rendezvous files
live in a bounded private subdirectory, expired triplets are pruned, and the answer file is
single-write.

## Automated checks

`swift test --filter ClaudeQuestionTests` covers unchanged input, single-select, multi-select, typed
answers, exact identity rejection, one-shot writes, receipt/answer timing, view-state key isolation,
and stale receipt generation reconciliation. `ClaudeObservationTests` covers prompt labels and helper
identity in the shared queue, including shared-directory noise and expired-triplet cleanup. The full
suite passed with 289 tests;
`sh scripts/build-app.sh`, `sh scripts/package-app.sh`, and
`output/Steer.app/Contents/MacOS/Steer --smoke-test` also passed. The package was ad hoc signed and
is development evidence only.

## Live application proof

Deferred to the operator walkthrough: one human-selected single choice, multi-select, typed answer,
and a helper timeout that leaves Claude's native question available. This document records the
implementation boundary and automated proof only; it does not claim those live scenarios passed.
