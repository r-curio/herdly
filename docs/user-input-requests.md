# User-input requests

Steer surfaces a question Codex is asking the user (the desktop panel with a question, numbered options, a Skip button and a free-text field, or the equivalent CLI prompt) as a "Codex needs an answer" item in the notch, and clears it when Codex records the answer. It reads the question from the session rollout Steer already scans for turn completions, so it needs no new permission, hook, or app-server connection. Accessibility inspection of the Codex window remains rejected (see the [desktop investigation](codex-desktop-investigation.md)).

Accepted by the user on 2026-09-14 with a chime for fresh questions, a Dismiss control, and the session's "working" row withheld while it waits.

## What Codex records

Codex asks through its `request_user_input` tool. The session rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session>.jsonl`) records the call the moment the panel opens and the answer the moment the user submits it, as two `response_item` lines:

```
{"timestamp":"…T02:20:36.895Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input",
  "call_id":"call_…","internal_chat_message_metadata_passthrough":{"turn_id":"<turn>"},
  "arguments":"{\"questions\":[{\"id\":\"…\",\"header\":\"Nested choices\",\"question\":\"Should different variant paths…?\",
                \"options\":[{\"label\":\"Flexible paths (Recommended)\",\"description\":\"…\"},{\"label\":\"Same levels throughout\",\"description\":\"…\"}]}]}"}}
{"timestamp":"…T02:21:41.908Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_…",
  "output":"{\"answers\":{\"…\":{\"answers\":[\"Flexible paths (Recommended)\"]}}}"}}
```

One call carries one or more questions (three is typical), and one turn can pose several calls in sequence, each answered before the next. A free-text answer appears as the answer string. The call carries the turn id in the same passthrough field the approval matcher already reads, and rollout turn ids equal the hook `turn_id` values in Steer's events directory. While the question waits, the turn is still running: the Stop hook fires only after the answer. Recorded from desktop 26.901.51231 (engine 0.153.4, `source` "vscode") in `docs/evidence/desktop-user-input-request.json`, with the option descriptions redacted.

Codex desktop also raises its per-thread unread flag when the request arrives (`item/tool/requestUserInput`), so the [desktop read state](desktop-read-state.md) shows the thread unread until it is viewed. Steer does not use that for questions; the rollout gives exact per-call evidence.

## Steer's rule

`ReminderReader.evidence` makes one pass over each scanned rollout (the same pass that finds ended turns) and collects every `function_call` named `request_user_input`. A question is:

- **Pending** while the file has no `function_call_output` for its call id. That is what the notch shows.
- **Answered** once an output for the call id exists. Any output counts; its content is not inspected, because Steer never needs to know the answer, only that Codex has one. No Skip or interrupt sample has been recorded yet; the walkthrough below records their shapes.
- **Ended** when the rollout records `task_complete` or `turn_aborted` for its turn, a desktop Stop hook completes the turn, or a SessionEnd hook arrives after the question. An ended turn also refuses a late question for that turn.

Identity is the session and call id, with the source (desktop or CLI) from the session's `session_meta`, like every other rollout-derived item. Fail-closed cases: a call without a call id (1 to 256 bytes), a UUID turn id, or a readable timestamp is not recorded, since Steer could neither clear nor open it; a rollout with any unreadable line yields no evidence at all, which the queue treats as "nothing new", never as an answer. Unreadable or oversize `arguments` (over 64 KB) still yield a question, shown without text, because the call itself is the evidence Codex is blocked. Display text is capped: eight questions, 80-character headers and option labels, 240-character questions, eight options; a capped prompt says so on the card. Option descriptions and the free-text field are never shown.

In the queue a question ranks after actionable approvals and ahead of handed-back requests: Codex is blocked on it and the user has not seen it, while a handed-back request was already surfaced once. Questions are rebuilt from rollout evidence on every scan and are not saved in the attention snapshot; a dismissal is in memory only, so a question still pending after a restart returns, without a chime. A session with a pending question has its "working" row withheld and its sprite standing still.

## App integration

Each two-second scan carries pending and answered calls into `AttentionQueue.apply(scan:…)`. A fresh question (one recorded after Steer launched) opens its own card for three seconds under the same away-from-Codex rule as a completion and plays the completion sound once; a question already pending at launch is listed silently. The card shows the first question as Codex's own panel does (header, "1 of N", question, numbered option labels), a disclosure for the remaining questions, and Open in Codex and Dismiss. Open in Codex returns to the session without dismissing. The badge counts the question. `--preview-queue expanded` includes a sample question. The restart report lists question rows with their call id.

## Verification

Automated: `Tests/SteerCoreTests/UserInputRequestTests.swift` covers the recorded shape, answered and sequential calls, unreadable arguments and caps, missing identity fields, unreadable rollouts leaving a queued question alone, CLI relabeling through the scan, sessions without hook records, and a replay of the committed recording (pending before the answer line, answered after it). `AttentionQueueTests.swift` covers priority, every clearing rule, dismissal, the snapshot, and the withheld running row; `NotchPlacementTests.swift` covers the badge and sprite.

Read-only probe: `python3 scripts/probe_user_input.py [--days 2] [--watch]` prints pending and answered calls in recent rollouts with their headers and option labels, flags any call shape Steer would not read, and has a `--self-test`.

Live walkthrough to repeat after each Codex update:

1. In Codex desktop, ask: "Use request_user_input to ask me two multiple-choice questions before doing anything." Switch to another app. Expect within about two seconds: the notch opens on a "Codex needs an answer" card with the first header, "1 of 2", the question and its options; one chime; the badge increments; the probe lists the same call id; the session shows no "working" row.
2. Hover. Expect: the question sits ahead of any handed-back request and completions; "Show all 2 questions" expands.
3. Bring Codex forward, then leave again. Expect: the panel hides while Codex is in front and the card does not chime again.
4. Answer in Codex. Expect within about two seconds: the item clears without a dismissal; the probe shows the call answered; the turn's completion arrives as usual.
5. Repeat and press Skip; repeat and stop the turn while the question is open. Record which line Codex writes in each case (an output for the call id, or `turn_aborted`) and that the item clears.
6. Repeat from Codex CLI in Ghostty. Expect: the card reads as CLI and Open in Codex uses the Ghostty path.
7. Quit Steer with a question pending and relaunch. Expect: the question reappears without a chime, then clears when answered.

Record the desktop version and results here.

### 2026-09-14, desktop 26.901.51231 (engine 0.153.4)

Source recording, automated checks and the probe against the live rollouts complete; the recording in `docs/evidence/desktop-user-input-request.json` is a real question answered 65 seconds later. The live walkthrough above has not yet been run; the Skip and interrupt shapes are unrecorded.
