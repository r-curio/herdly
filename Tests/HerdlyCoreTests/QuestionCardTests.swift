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

private let session = UUID(uuidString: "01A09D9B-7642-7B51-BCCE-9B66CFE5361F")!
private let turn = UUID(uuidString: "01A09DB7-0C51-7F33-9EBC-4E44F91DF22C")!

private func daemonRequest(id: Int, receivedAt: Double = 1, secret: Bool = false) -> AppServerQuestionRequest {
    var book = AppServerQuestionBook()
    let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "item/tool/requestUserInput",
        "params": ["threadId": session.uuidString, "turnId": turn.uuidString, "itemId": "call_1",
                   "questions": [["id": "a", "header": "A", "question": "Which?", "isSecret": secret,
                                  "options": [["label": "One"], ["label": "Two"], ["label": "Three"]]],
                                 ["id": "b", "header": "B", "question": "Name?", "options": NSNull()]]]]
    guard case let .request(request) = book.apply(message: message, now: receivedAt) else { fatalError("request expected") }
    return request
}

private let rolloutCall = AttentionQuestion(source: .cli, session: session, turn: turn, callID: "call_1", arrivedAt: 1,
                                            prompts: [QuestionPrompt(header: "A", question: "Which?", options: ["One", "Two"]),
                                                      QuestionPrompt(header: "B", question: "Where?", options: ["Here", "There"])])

@Test func keyRoutesAreTheOnesThatTypeADigit() {
    let keyed: [QuestionAnswerRoute] = [.ghosttyRelay, .herdrRelay, .terminalRelay]
    #expect(keyed.allSatisfy { $0.isKeyRoute })
    let others: [QuestionAnswerRoute] = [.daemon(daemonRequest(id: 1)), .daemonAnswered, .desktopReadOnly,
                                         .relayUnavailable(.daemonAnswerInProgress)]
    #expect(!others.contains { $0.isKeyRoute })
}

@Test func onlyTheQuestionBeingAnsweredOrAnEarlierDaemonDraftIsSelectable() {
    let request = daemonRequest(id: 1)
    let daemon = QuestionAnswerRoute.daemon(request)
    let fresh = QuestionAnswerProgress(call: rolloutCall.id)
    #expect(QuestionCardOptions.options(route: daemon, question: rolloutCall, at: 0) == ["One", "Two", "Three"])
    #expect(QuestionCardOptions.options(route: .ghosttyRelay, question: rolloutCall, at: 1) == ["Here", "There"])
    #expect(QuestionCardOptions.options(route: .ghosttyRelay, question: rolloutCall, at: 5).isEmpty)
    #expect(QuestionCardOptions.selectable(route: daemon, question: rolloutCall, progress: fresh, viewed: 0, controls: true))
    #expect(!QuestionCardOptions.selectable(route: daemon, question: rolloutCall, progress: fresh, viewed: 1, controls: true))
    // An earlier daemon draft can be changed; an earlier sent key cannot.
    let drafted = fresh.recordingDraft(question: 0, answer: .option(0))
    #expect(QuestionCardOptions.selectable(route: daemon, question: rolloutCall, progress: drafted, viewed: 0, controls: true))
    let keyed = fresh.startingSend(question: 0).recordingSent(question: 0, option: 0, of: rolloutCall, at: 1)
    #expect(!QuestionCardOptions.selectable(route: .ghosttyRelay, question: rolloutCall, progress: keyed, viewed: 0, controls: true))
    #expect(QuestionCardOptions.selectable(route: .ghosttyRelay, question: rolloutCall, progress: keyed, viewed: 1, controls: true))
    // No controls, a secret, a read-only route, or a send in flight: nothing is selectable.
    #expect(!QuestionCardOptions.selectable(route: .ghosttyRelay, question: rolloutCall, progress: fresh, viewed: 0, controls: false))
    #expect(!QuestionCardOptions.selectable(route: .daemon(daemonRequest(id: 2, secret: true)), question: rolloutCall,
                                            progress: fresh, viewed: 0, controls: true))
    for route: QuestionAnswerRoute in [.desktopReadOnly, .daemonAnswered, .relayUnavailable(.daemonAnswerInProgress)] {
        #expect(!QuestionCardOptions.selectable(route: route, question: rolloutCall, progress: fresh, viewed: 0, controls: true))
    }
    #expect(!QuestionCardOptions.selectable(route: .ghosttyRelay, question: rolloutCall, progress: fresh.startingSend(question: 0),
                                            viewed: 0, controls: true))
}

@Test func anEarlierStepsUncommittedTextIsDiscardedWhenTheCardLeavesIt() {
    // What the card shows is what Send sends: an earlier daemon step's draft changes only on Return
    // in the field (or a selection); text left unsubmitted there is discarded on navigating away.
    let route = QuestionAnswerRoute.daemon(daemonRequest(id: 1))
    let progress = QuestionAnswerProgress(call: rolloutCall.id).recordingDraft(question: 0, answer: .text("Old"))
    var typed = QuestionTypedDrafts()
    #expect(typed.text(for: 0, route: route, progress: progress) == "Old")
    typed = typed.editing(0, text: "New", route: route)
    #expect(typed.text(for: 0, route: route, progress: progress) == "New")
    typed = typed.leaving(0, current: progress.questionIndex)
    #expect(typed.text(for: 0, route: route, progress: progress) == "Old")
    // The step being answered keeps its text when the card looks elsewhere: Next or Send sends it.
    typed = typed.editing(1, text: "Herdly", route: route).leaving(1, current: progress.questionIndex)
    #expect(typed.text(for: 1, route: route, progress: progress) == "Herdly")
    // Text equal to what was drafted is no longer an edit.
    let committed = progress.recordingDraft(question: 1, answer: .text("Herdly"))
    #expect(typed.hasEdits && !typed.committing(committed).hasEdits)
    #expect(typed.committing(committed).text(for: 1, route: route, progress: committed) == "Herdly")
}

@Test func textTypedForOneDaemonRequestIsNeverOfferedToAnother() {
    let first = QuestionAnswerRoute.daemon(daemonRequest(id: 1, receivedAt: 1))
    let second = QuestionAnswerRoute.daemon(daemonRequest(id: 2, receivedAt: 5))
    let progress = QuestionAnswerProgress(call: rolloutCall.id).recordingDraft(question: 0, answer: .option(0))
    let typed = QuestionTypedDrafts().editing(1, text: "For the first request", route: first)
    #expect(typed.text(for: 1, route: first, progress: progress) == "For the first request")
    #expect(typed.text(for: 1, route: second, progress: progress) == "")
    // Typing under the new request starts over; the old request's text is gone for good.
    let retyped = typed.editing(0, text: "x", route: second)
    #expect(retyped.text(for: 1, route: second, progress: progress) == "")
    #expect(retyped.text(for: 1, route: first, progress: progress) == "")
}
