# User-input requests

Steer surfaces a question Codex is asking the user (the desktop panel with a question, numbered options, a Skip button and a free-text field, or the equivalent CLI prompt) as a "Codex needs an answer" item in the notch, and clears it when Codex records the answer. It reads the question from the session rollout Steer already scans for turn completions, so it needs no new permission, hook, or app-server connection. Accessibility inspection of the Codex window remains rejected (see the [desktop investigation](codex-desktop-investigation.md)).

Accepted by the user on 2026-09-14 with a chime for fresh questions, a Dismiss control, and the session's "working" row withheld while it waits. Answering from the notch for CLI sessions in Ghostty was accepted the same day ([ADR 0006](adr/0006-relay-the-users-chosen-question-option-through-ghostty.md)); see "Answering from the notch" below.

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

## Answering from the notch

Codex offers no way for another program to answer a question: the question tool provides no PreToolUse hook payload, the desktop engine is an embedded stdio app-server nothing can attach to, and the `codex://threads/<id>` link takes no parameters. Ghostty 1.3.1, however, scripts `send key` (a key event to one terminal object), and Codex's terminal question pane binds a digit to "select that option and move to the next question, or submit on the last" (`codex-rs/tui/src/bottom_pane/request_user_input/mod.rs`). So for a CLI session in Ghostty the card's options are controls, and a click relays one digit to that session's own tab. For a desktop session the options are a pick that opens the thread and stays highlighted on the card; nothing is sent.

The rule, in `QuestionAnswer.swift`, fails closed at every step:

1. A key is sent only after a click on an option button; never on a timer, retry, restart, or error.
2. Only the unique unsplit Ghostty terminal whose title equals the session's shortened id receives it, re-inventoried inside the same osascript call (`Ghostty.js`, action `answer`); any mismatch sends nothing. The window is not activated; the key goes to the terminal object.
3. Immediately before sending, the rollout is re-read (`ReminderReader.currentEvidence`); if it cannot be read, shows an output for the call, or shows the turn ended, nothing is sent (`QuestionAnswerGuard`).
4. One key per call and question index; a second press for the same question is refused (`QuestionAnswerPolicy`, which judges the queue's current copy of the question, never the rendered row).
5. Only `1` through `9` (and `enter`, if the live check below proves the digit alone does not commit) can leave Steer. No text, no Other, no Skip, no Escape.
6. Sending never dismisses the question; only rollout evidence or Dismiss clears it.
7. A sent last answer with no output within 10 seconds becomes "unconfirmed": the card says so and offers Open in Codex; Steer never resends.
8. Progress (`QuestionAnswerProgress`) is in memory only; after a restart the question is plain pending.
9. Ghostty disabled, desktop source, unreadable arguments, a typed answer, an option list Steer cannot number exactly (more than eight, or an unreadable label, `optionsComplete`), or a question beyond the eight parsed: no sending controls. `isOther` questions offer only the listed options; Codex's Other row is never sent.
10. Desktop: a pick is a highlight plus the deep link; no key or RPC is ever sent.

Because the rollout records nothing until the whole call is answered, a multi-question call is tracked optimistically: after a non-last digit the card says which question Codex should now be on and offers that question's options. Option positions are preserved when parsing, so a digit always names the option Codex lists at that position; a label Steer cannot read ends the list and takes the question back to Codex.

## App integration

Each two-second scan carries pending and answered calls into `AttentionQueue.apply(scan:…)`. A fresh question (one recorded after Steer launched) opens its own card for three seconds under the same away-from-Codex rule as a completion and plays the completion sound once; a question already pending at launch is listed silently. The card shows the current question as Codex's own panel does (header, "1 of N", question, numbered option labels), a disclosure for the remaining questions, and Open in Codex and Dismiss. With Ghostty controls on, a CLI question's options are buttons (`Companion.chooseOption`); a CLI question with Ghostty controls off shows Set up Ghostty instead of Open in Codex. A desktop question's options are buttons that record the pick and open the thread. A chosen option is drawn in the pressed look until Codex records the answer, and one status sentence names the phase: sending, sent and waiting, unconfirmed, refused, or the pick. Open in Codex returns to the session without dismissing. The badge counts the question. `--preview-queue expanded` includes a CLI sample with two questions and a desktop sample. The restart report lists question rows with their call id and, when Steer relayed something, the answer phase.

## Verification

Automated: `Tests/SteerCoreTests/UserInputRequestTests.swift` covers the recorded shape, answered and sequential calls, unreadable arguments and caps, missing identity fields, unreadable rollouts leaving a queued question alone, CLI relabeling through the scan, sessions without hook records, a replay of the committed recording (pending before the answer line, answered after it), option positions kept when a label is unreadable, `isOther`, the raw question count past the cap, and the unique rollout lookup. `QuestionAnswerTests.swift` covers the offer rule, the policy table (not in queue, desktop, Ghostty off, wrong question, out of range, every non-ready phase, a repeated pick), the digit key, advancing through a multi-question call, the 10-second unconfirmed rule, failure without retry, the pre-send guard, and the desktop pick. `AttentionQueueTests.swift` covers priority, every clearing rule, dismissal, the snapshot, and the withheld running row; `NotchPlacementTests.swift` covers the badge and sprite.

Read-only probe: `python3 scripts/probe_user_input.py [--days 2] [--watch]` prints pending and answered calls in recent rollouts with their headers and option labels, what the notch would offer for each question (digits, or continue in Codex with the reason), `isOther`, and for answered calls the recorded labels with the digit each corresponds to; it flags any call shape Steer would not read and has a `--self-test`.

Live walkthrough to repeat after each Codex update:

1. In Codex desktop, ask: "Use request_user_input to ask me two multiple-choice questions before doing anything." Switch to another app. Expect within about two seconds: the notch opens on a "Codex needs an answer" card with the first header, "1 of 2", the question and its options; one chime; the badge increments; the probe lists the same call id; the session shows no "working" row.
2. Hover. Expect: the question sits ahead of any handed-back request and completions; "Show all 2 questions" expands.
3. Bring Codex forward, then leave again. Expect: the panel hides while Codex is in front and the card does not chime again.
4. Answer in Codex. Expect within about two seconds: the item clears without a dismissal; the probe shows the call answered; the turn's completion arrives as usual.
5. Repeat and press Skip; repeat and stop the turn while the question is open. Record which line Codex writes in each case (an output for the call id, or `turn_aborted`) and that the item clears.
6. Repeat from Codex CLI in Ghostty. Expect: the card reads as CLI and Open in Codex uses the Ghostty path.
7. Quit Steer with a question pending and relaunch. Expect: the question reappears without a chime, then clears when answered.

Record the desktop version and results here.

Answering walkthrough (Codex CLI in Ghostty 1.3.1, the trusted lab project with `-c 'tui.terminal_title=["session-id"]'`, Ghostty controls enabled; no user configuration changed). Keep `python3 scripts/probe_user_input.py --watch` running beside the notch.

0. Key names: in a disposable Ghostty tab running `cat -v`, with that window not frontmost, run `osascript -l JavaScript -e 'const a=Application("com.mitchellh.ghostty"); const t=a.windows[0].tabs[0].terminals[0]; a.sendKey("1",{to:t})'` (adjust the indices to the disposable tab). Expect `1` echoed. Record whether the digit name is accepted, whether a release event is needed, and whether the window had to be frontmost. If a key is dropped while unfocused, change `Ghostty.js` to select the tab before sending and note it here.
1. One question, two options: ask "Use request_user_input to ask me one multiple-choice question with two options." Leave the tab. Click option 2. Expect the card to read "Sent 2 for question 1 of 1. Waiting for Codex to record the answer.", the row to clear within about two seconds, the probe to show `recorded: [<label 2>] (digit 2)`, and the TUI to continue the turn. If the TUI only highlighted option 2 and waits for Enter, the installed keymap differs from source: set `keys` to the digit plus `enter` in `Companion.chooseOption`, amend ADR 0006, and repeat.
2. Three questions: click 1, then 2, then 1. Expect "Sent 1 for question 1 of 3. Codex should now show question 2." with question 2's buttons, then the same for 3, then the clear; the probe's recorded digits must read 1, 2, 1.
3. An `isOther` question: only the listed options are buttons; Codex's Other row is never chosen.
4. Race: answer in the TUI first, then click in the notch within two seconds. Expect "Codex already has an answer or the turn ended; nothing was sent." or the row already gone, and no stray digit in the composer.
5. Ghostty controls off: Set up Ghostty and Dismiss, no option buttons.
6. Split the session's tab: the buttons refuse with "No unique live, unsplit tab", nothing sent.
7. Restart mid-call: click option 1 of a two-question call, quit Steer, relaunch. Expect the card back as pending on question 1 with no chime and nothing re-sent; finish in Codex.
8. Unconfirmed: interrupt the turn right after clicking the last option. Expect "Steer sent n but has not seen Codex record an answer" within ten seconds and no second digit in the probe or the tab.
9. A typed-answer question: "This question takes a typed answer. Answer it in Codex." with Open in Codex only.
10. Desktop: click an option on a desktop card. Expect Codex to open the thread and the card to keep the pick highlighted until the answer is recorded.

### 2026-09-14, desktop 26.901.51231 (engine 0.153.4)

Source recording, automated checks and the probe against the live rollouts complete; the recording in `docs/evidence/desktop-user-input-request.json` is a real question answered 65 seconds later. The live walkthrough above has not yet been run; the Skip and interrupt shapes are unrecorded.

### 2026-09-14, answering from the notch (CLI 0.145.0, Ghostty 1.3.1)

Source inspection: Ghostty's scripting dictionary (`sdef /Applications/Ghostty.app`) defines `send key` with a key-name text, optional press/release action and modifiers, and a `to` terminal parameter; Codex's question pane source on `main` selects and advances on a digit. Automated checks: `swift test` (151 tests), `python3 scripts/probe_user_input.py --self-test`, `sh scripts/build-app.sh` with strict codesign verification, and the `--preview-queue expanded` render showing the option controls. The probe against the day's real rollouts mapped every recorded answer to its digit. The answering walkthrough (steps 0 through 10) has not yet been run by a person; until step 1 passes on the installed CLI, the digit-commits-and-advances behavior is a source-level finding, not a proven capability.
