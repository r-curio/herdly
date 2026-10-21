import Foundation
import Testing
@testable import HerdlyCore

@Test func theDaemonCardOffersNextUntilTheLastQuestionThenSend() {
    // Three questions, answering the first, nothing selected yet: Next, off.
    #expect(QuestionCardPrimary.make(daemon: true, viewed: 0, current: 0, count: 3, selected: false, ready: true) == .next(enabled: false))
    #expect(QuestionCardPrimary.make(daemon: true, viewed: 0, current: 0, count: 3, selected: true, ready: true) == .next(enabled: true))
    #expect(QuestionCardPrimary.make(daemon: true, viewed: 2, current: 2, count: 3, selected: true, ready: true) == .send(enabled: true))
    // Back on an earlier draft: the button only steps on; the draft is changed by selecting.
    #expect(QuestionCardPrimary.make(daemon: true, viewed: 0, current: 2, count: 3, selected: true, ready: true) == .step(to: 1))
    // A later question can be read but not answered out of order.
    #expect(QuestionCardPrimary.make(daemon: true, viewed: 2, current: 1, count: 3, selected: false, ready: true) == .send(enabled: false))
    #expect(QuestionCardPrimary.make(daemon: true, viewed: 1, current: 0, count: 3, selected: false, ready: true) == .next(enabled: false))
    // Nothing is offered while a send is in flight or after it.
    #expect(QuestionCardPrimary.make(daemon: true, viewed: 2, current: 2, count: 3, selected: true, ready: false) == .send(enabled: false))
    #expect(QuestionCardPrimary.make(daemon: true, viewed: 0, current: 0, count: 1, selected: true, ready: true) == .send(enabled: true))
}

@Test func aKeyRouteCardSendsOneKeyPerSendForTheCurrentQuestionOnly() {
    // Every question's button is Send: each Send types one digit (ADR 0006, ADR 0017).
    #expect(QuestionCardPrimary.make(daemon: false, viewed: 0, current: 0, count: 3, selected: true, ready: true) == .send(enabled: true))
    #expect(QuestionCardPrimary.make(daemon: false, viewed: 0, current: 0, count: 3, selected: false, ready: true) == .send(enabled: false))
    // A sent key is review-only: its step offers only a step on.
    #expect(QuestionCardPrimary.make(daemon: false, viewed: 0, current: 1, count: 3, selected: true, ready: true) == .step(to: 1))
    #expect(QuestionCardPrimary.make(daemon: false, viewed: 2, current: 1, count: 3, selected: false, ready: true) == .send(enabled: false))
    #expect(QuestionCardPrimary.make(daemon: false, viewed: 1, current: 1, count: 3, selected: true, ready: false) == .send(enabled: false))
}

@Test func keyRouteLinesSayWhatWasTypedAndWhere() {
    #expect(QuestionCardLines.typed(digit: 1, noun: "tab", next: 1)
            == "Typed 1 into this session's tab. Codex should now show question 2.")
    #expect(QuestionCardLines.typed(digit: 2, noun: "pane", next: nil)
            == "Typed 2 into this session's pane. Waiting for Codex to record the answer.")
    #expect(QuestionCardLines.typedUnconfirmed(digit: 3, noun: "tab")
            == "Typed 3 into this session's tab, but Codex has not recorded an answer. Check the tab; Herdly will not resend.")
    #expect(QuestionCardLines.typedReview(digit: 1, noun: "tab") == "Typed 1 into this session's tab. It can't be changed here.")
    #expect(QuestionCardLines.stepper(viewed: 1, count: 3) == "question 2 of 3")
    #expect(QuestionCardLines.secret == "Herdly never shows or relays secret answers.")
    #expect(QuestionCardLines.desktopReadOnly == "Herdly can't answer the Codex app. Answer it there.")
}

@Test func aClaudeQuestionSendsOnlyAfterSomethingIsSelected() {
    let labels = ["Version 2", "Keep version 1", "Ask later"]
    let single = ClaudeQuestionSelection(multiSelect: false)
    #expect(!single.canSend && single.answer(labels: labels) == nil)
    let picked = single.toggling(1, of: 3)
    #expect(picked.canSend && picked.answer(labels: labels)?.answer == "Keep version 1")
    #expect(picked.answer(labels: labels)?.kind == .option)
    // Single-select keeps one option; clicking it again keeps it selected.
    #expect(picked.toggling(0, of: 3).answer(labels: labels)?.answer == "Version 2")
    #expect(picked.toggling(1, of: 3).answer(labels: labels)?.answer == "Keep version 1")
    #expect(single.toggling(3, of: 3) == single)

    let multi = ClaudeQuestionSelection(multiSelect: true)
    let two = multi.toggling(2, of: 3).toggling(0, of: 3)
    #expect(two.answer(labels: labels)?.answer == "Version 2, Ask later")
    #expect(two.answer(labels: labels)?.kind == .multiSelect)
    let none = two.toggling(2, of: 3).toggling(0, of: 3)
    #expect(!none.canSend && none.answer(labels: labels) == nil)
    // Labels that no longer hold a ticked option send nothing.
    #expect(two.answer(labels: ["Only one"]) == nil)
}

@Test func aClaudeTypedAnswerAndAnOptionAreNeverSentTogether() {
    let labels = ["Version 2", "Keep version 1"]
    // Typing clears the selected option; Send carries the trimmed text alone.
    let typed = ClaudeQuestionSelection(multiSelect: false).toggling(0, of: 2).typing("  Version 3  ")
    #expect(typed.options.isEmpty)
    #expect(typed.canSend)
    #expect(typed.answer(labels: labels)?.kind == .text)
    #expect(typed.answer(labels: labels)?.answer == "Version 3")
    // Selecting an option clears the text; Send carries the option alone.
    let reselected = typed.toggling(1, of: 2)
    #expect(reselected.text.isEmpty)
    #expect(reselected.answer(labels: labels)?.kind == .option)
    #expect(reselected.answer(labels: labels)?.answer == "Keep version 1")
    // Ticks on a multi-select give way to typing the same way.
    let multi = ClaudeQuestionSelection(multiSelect: true).toggling(0, of: 2).toggling(1, of: 2).typing("Neither")
    #expect(multi.options.isEmpty && multi.answer(labels: labels)?.kind == .text)
    // Blank text neither clears a selection nor counts as an answer.
    let blank = ClaudeQuestionSelection(multiSelect: false).toggling(1, of: 2).typing("   ")
    #expect(blank.options == [1] && blank.answer(labels: labels)?.kind == .option)
    #expect(!ClaudeQuestionSelection(multiSelect: false).typing("  ").canSend)
    // A typed-only question (no options) sends its text.
    #expect(ClaudeQuestionSelection(multiSelect: false).typing("Herdly").answer(labels: [])?.answer == "Herdly")
}
