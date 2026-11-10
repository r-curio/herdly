# Send a Claude question call as one answer set

Accepted on 2026-11-10, with the user's agreement on the design (Paper artboard "G · Claude: answer several questions", #382). Before this, Herdly answered a Claude `AskUserQuestion` call only when it held exactly one question; calls with two to four questions were for reading only. Now the notch steps through every question and one Send hands Claude the whole set.

## Decision

- **One set, one send.** Next keeps each answer in Herdly's memory. Send on the last question writes one answer record for the call. The helper emits `updatedInput.answers` with one entry per question, keyed by the question's text, only when the record holds exactly one valid answer for every question in order. A partial, reordered, extra, blank or mismatched set emits nothing and Claude asks natively.
- **What stays in Claude.** Calls over four questions (`ClaudeQuestionAnswerPolicy.maximumAnswerableQuestions`, Claude's own limit), calls with an unreadable or secret question, and calls where two questions share text, because one text key cannot carry two answers. The helper does not publish these, so the card is read-only.
- **Timer.** One countdown per call, under ADR 0020's Claude question amendment.
- **Record format.** `ClaudeQuestionAnswer` stores `answers`, a list of `{kind, answer}`. A one-answer set also writes the pre-#382 `kind` and `answer` fields, so a helper still running from an older build reads it as before. A multi-answer set omits them, so an older helper cannot decode it and sends nothing. A record with only the old fields reads as a one-answer set. Old fields that disagree with `answers` make the record unreadable.

## Considered options

- **New-only format.** Rejected: during an upgrade, a helper started by the old build would fail to read single answers from the new app and every single question would fall back to Claude.
- **Always write the old fields.** Rejected: an older helper would read the first answer of a multi-question set and could send a partial answer.
- **Send each question as it is answered.** Rejected: Claude's hook output takes the whole call at once, and the product rule is that a partial set is never sent.
- **Reuse the Codex daemon's progress model.** Rejected for the selection state: it cannot hold a choose-several answer, and widening it would touch every Codex answer path. The Claude card reuses Codex's step rail and Next/Send rule (`QuestionCardPrimary`) instead.

## Amendment, 2026-11-10 (#388)

Agreed with the user after a live report: a Claude card is answered in any order (Paper "G · Claude: answer several questions", step 2 and the "One send" rule). Every question is selectable at any time, however the card reached it; Next only moves on. "One set, one send" is unchanged: Send on the last question is enabled only for a complete set and writes it once, in question order, and the helper's in-order check still applies to the record. The Claude card therefore no longer follows Codex's answering-position rule (`QuestionCardPrimary.make`); `ClaudeQuestionCallSelection.primary` gives Next or Send directly, and Codex cards are unchanged because key routes must type digits in order.
