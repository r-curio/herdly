import Foundation
import Testing
@testable import HerdlyCore

private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/claude", session: "s1", surface: .cli)
private let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s2", surface: .cli)
private let questionID = AgentAttentionID.question(AgentCallIdentity(session: claude, turn: "t1", call: "toolu_q"))
private let otherQuestionID = AgentAttentionID.question(AgentCallIdentity(session: codex, turn: "t2", call: "call_q"))
private let workflows = QuestionPrompt(header: "Scope", question: "Which workflows should close the issue when the PR merges?",
                                       options: ["Only release.yml (Recommended)", "Every workflow that mentions it",
                                                 "None, close it by hand"])

// MARK: - Hold rule: the keyboard holds the spotlight; the deadline still ends (#428)

@Test func aSpotlightCardWithTheKeyboardInItStaysOpenPastItsCardOpenTime() {
    var controller = NotchPresentationController()
    controller.present(questionID, now: 0, duration: .threeSeconds)
    do { let mode = controller.update(interacting: false, keyboardFocus: true, now: 1, queued: [questionID]); #expect(mode == .agentSpotlight(questionID)) }
    // However long the user takes.
    do { let mode = controller.update(interacting: false, keyboardFocus: true, now: 600, queued: [questionID]); #expect(mode == .agentSpotlight(questionID)) }
}

@Test func onceTheKeyboardLeavesTheCardTheCardOpenTimeStartsOverLikeHover() {
    var controller = NotchPresentationController()
    controller.present(questionID, now: 0, duration: .threeSeconds)
    _ = controller.update(interacting: false, keyboardFocus: true, now: 100, queued: [questionID])
    do { let mode = controller.update(interacting: false, keyboardFocus: false, now: 102, queued: [questionID]); #expect(mode == .agentSpotlight(questionID)) }
    do { let mode = controller.update(interacting: false, keyboardFocus: false, now: 104, queued: [questionID]); #expect(mode == .collapsed) }
}

@Test func escapeEndsTheKeyboardHoldOnASpotlightCard() {
    var controller = NotchPresentationController()
    controller.present(questionID, now: 0, duration: .threeSeconds)
    _ = controller.update(interacting: false, keyboardFocus: true, now: 1, queued: [questionID])
    #expect(controller.escape() == .collapse)
    do { let mode = controller.update(interacting: false, keyboardFocus: true, now: 2, queued: [questionID]); #expect(mode == .collapsed) }
}

@Test func theKeyboardHoldIsNotInteractionSoNoCountdownPauses() {
    // ADR 0020 is unchanged: the hold lives in the presentation controller only. Approval and Claude
    // question holds read the pointer, and keyboard focus alone is not interaction.
    #expect(!NotchInteraction.isActive(pointerInside: false, keyboardFocus: true))
}

@Test func whenTheCountdownEndsWithTheCardFocusedTheCardHandsBack() {
    var card = SpotlightKeyboardCard()
    let window = SpotlightKeyboardCard.Window(askedAt: 100, deadline: 130)
    do { let phase = card.observe(card: questionID, answerable: true, window: window, now: 110); #expect(phase == .answering) }
    // The helper's deadline passes: Herdly can no longer answer, and the card says it handed back.
    do { let phase = card.observe(card: questionID, answerable: false, window: nil, now: 130.5); #expect(phase == .handedBack(askedAt: 100)) }
    // It stays handed back for as long as the keyboard is in it.
    do { let phase = card.observe(card: questionID, answerable: false, window: nil, now: 200); #expect(phase == .handedBack(askedAt: 100)) }
}

@Test func losingAnswerabilityBeforeTheDeadlineIsReadOnlyNotAHandBack() {
    // Open handed the question to Claude, or the helper went away: the countdown did not end.
    var card = SpotlightKeyboardCard()
    _ = card.observe(card: questionID, answerable: true, window: .init(askedAt: 100, deadline: 130), now: 110)
    do { let phase = card.observe(card: questionID, answerable: false, window: nil, now: 115); #expect(phase == .readOnly) }
}

@Test func aHeldDeadlineIsReadAfreshEachTime() {
    // The pointer held the question (ADR 0020): the later deadline is the one that counts.
    var card = SpotlightKeyboardCard()
    _ = card.observe(card: questionID, answerable: true, window: .init(askedAt: 100, deadline: 130), now: 110)
    _ = card.observe(card: questionID, answerable: true, window: .init(askedAt: 100, deadline: 160), now: 125)
    do { let phase = card.observe(card: questionID, answerable: false, window: nil, now: 140); #expect(phase == .readOnly) }
}

@Test func anotherCardStartsFresh() {
    var card = SpotlightKeyboardCard()
    _ = card.observe(card: questionID, answerable: true, window: .init(askedAt: 100, deadline: 130), now: 110)
    _ = card.observe(card: questionID, answerable: false, window: nil, now: 131)
    do { let phase = card.observe(card: otherQuestionID, answerable: true, window: nil, now: 132); #expect(phase == .answering) }
    do { let phase = card.observe(card: nil, answerable: false, window: nil, now: 133); #expect(phase == nil) }
}

// MARK: - No key sends without Return or Send, and none after hand-back (#428)

private let allKeys: [SpotlightCardKey] = (0...10).map(SpotlightCardKey.digit)
    + [.returnKey, .open, .dismiss, .previousQuestion, .nextQuestion]

@Test func onlyReturnOnACardHerdlyCanAnswerReachesSend() {
    let answer = SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], picks: [.options([1])])
    let phases: [SpotlightCardPhase] = [.answering, .readOnly, .handedBack(askedAt: 0), .sent(answer)]
    for phase in phases {
        for key in allKeys {
            let action = SpotlightCardKeys.action(for: key, phase: phase)
            if action == .primary {
                #expect(key == .returnKey && phase == .answering)
            }
        }
    }
}

@Test func whileAnsweringADigitOnlySelectsAndTheLettersActAsTheirButtons() {
    #expect(SpotlightCardKeys.action(for: .digit(2), phase: .answering) == .select(2))
    #expect(SpotlightCardKeys.action(for: .open, phase: .answering) == .open)
    #expect(SpotlightCardKeys.action(for: .dismiss, phase: .answering) == .dismiss)
    #expect(SpotlightCardKeys.action(for: .previousQuestion, phase: .answering) == .step(-1))
    #expect(SpotlightCardKeys.action(for: .nextQuestion, phase: .answering) == .step(1))
    // Digit 0 is not an option.
    #expect(SpotlightCardKeys.action(for: .digit(0), phase: .answering) == .none)
}

@Test func afterHandBackDigitsAreInertAndReturnOpensTheAgent() {
    let phase = SpotlightCardPhase.handedBack(askedAt: 0)
    #expect((1...9).allSatisfy { SpotlightCardKeys.action(for: .digit($0), phase: phase) == .none })
    #expect(SpotlightCardKeys.action(for: .returnKey, phase: phase) == .open)
    #expect(SpotlightCardKeys.action(for: .open, phase: phase) == .open)
    // "Open in <agent>" is the only button.
    #expect(SpotlightCardKeys.action(for: .dismiss, phase: phase) == .none)
}

@Test func aReadOnlyCardTakesNoDigitsAndReturnOpens() {
    #expect(SpotlightCardKeys.action(for: .digit(1), phase: .readOnly) == .none)
    #expect(SpotlightCardKeys.action(for: .returnKey, phase: .readOnly) == .open)
    #expect(SpotlightCardKeys.action(for: .dismiss, phase: .readOnly) == .dismiss)
}

@Test func onceSentNoKeyDoesAnything() {
    let phase = SpotlightCardPhase.sent(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], picks: [.options([1])]))
    #expect(allKeys.allSatisfy { SpotlightCardKeys.action(for: $0, phase: phase) == .none })
}

@Test func pickSeveralDigitsToggleAndReturnSendsTheTickedSet() {
    let several = QuestionPrompt(header: "Labels", question: "Which labels?", options: ["bug", "docs", "ui"], multiSelect: true)
    var call = ClaudeQuestionCallSelection(prompts: [several])
    // Nothing ticked: Send stays disabled, so Return does nothing.
    #expect(call.primary(viewed: 0) == .send(enabled: false))
    for digit in [1, 2, 3, 3] {
        guard case let .select(number) = SpotlightCardKeys.action(for: .digit(digit), phase: .answering) else {
            Issue.record("a digit must select"); return
        }
        call = call.toggling(number - 1, at: 0)
    }
    // 3 was ticked then unticked; a digit past the last option is ignored.
    call = call.toggling(8, at: 0)
    #expect(call.selection(at: 0).options == [0, 1])
    #expect(call.primary(viewed: 0) == .send(enabled: true))
    #expect(call.answers(prompts: [several]) == [ClaudeQuestionAnswerEntry(kind: .multiSelect, answer: "bug, docs")])
}

// MARK: - Sent (Paper L "4 · Sent")

@Test func theSentLineNamesTheAgentTheOptionAndItsLabel() {
    let answer = SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], picks: [.options([1])])
    #expect(answer.line == "Sent to Claude: 2 · Every workflow that mentions it")
    #expect(answer.chosen == [1])
    #expect(answer.options == ["Only release.yml (Recommended)", "Every workflow that mentions it", "None, close it by hand"])
}

@Test func theSentLineDropsTheRecommendedMarkAndListsTicksInOrder() {
    #expect(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], picks: [.options([2, 0])]).line
            == "Sent to Claude: 1, 3 · Only release.yml, None, close it by hand")
    #expect(SpotlightSentAnswer.make(agent: "Codex", prompts: [workflows], picks: [.typed("  only main  ")]).line
            == "Sent to Codex: only main")
    #expect(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows, workflows, workflows],
                                     picks: [.options([0]), .options([1]), .typed("x")]).line
            == "Sent to Claude: 3 answers")
}

@Test func theCardShowsSentOnlyAfterTheSendLeftHerdlyAndFoldsASecondLater() {
    var card = SpotlightKeyboardCard()
    let answer = SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], picks: [.options([1])])
    _ = card.observe(card: questionID, answerable: true, window: nil, now: 10)
    // A send the route refused records nothing, so the card keeps answering.
    card.arm(answer, for: questionID)
    do { let phase = card.observe(card: questionID, answerable: true, window: nil, now: 11); #expect(phase == .answering) }
    #expect(!card.foldDue(now: 100))
    // The send left Herdly.
    do { let confirmed = card.confirmSent(for: questionID, now: 12); #expect(confirmed) }
    do { let phase = card.observe(card: questionID, answerable: false, window: nil, now: 12.5); #expect(phase == .sent(answer)) }
    #expect(!card.foldDue(now: 12.9))
    #expect(card.foldDue(now: 13))
}

@Test func aSendOnAnotherCardOrWithoutArmingIsNotConfirmed() {
    var card = SpotlightKeyboardCard()
    _ = card.observe(card: questionID, answerable: true, window: nil, now: 10)
    do { let confirmed = card.confirmSent(for: questionID, now: 11); #expect(!confirmed) }
    card.arm(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], picks: [.options([0])]), for: questionID)
    do { let confirmed = card.confirmSent(for: otherQuestionID, now: 11); #expect(!confirmed) }
}

// MARK: - Wait rule: an arrival waits behind the focused card (Paper L "8 · Another one arrives")

@Test func aFreshCardDoesNotReplaceTheSpotlightTheKeyboardIsIn() {
    var controller = NotchPresentationController()
    controller.present(questionID, now: 0, duration: .threeSeconds)
    _ = controller.update(interacting: false, keyboardFocus: true, now: 1, queued: [questionID, otherQuestionID])
    #expect(!controller.acceptsAgentSpotlight(interacting: false, draftInProgress: false, keyboardFocus: true, now: 10))
    // Without the keyboard the card has timed out by now, and the next card may take its place.
    var unfocused = NotchPresentationController()
    unfocused.present(questionID, now: 0, duration: .threeSeconds)
    #expect(unfocused.acceptsAgentSpotlight(interacting: false, draftInProgress: false, keyboardFocus: false, now: 10))
}

@Test func theWaitingLineNamesTheMostUrgentArrivalAndItsDeadlineIsItsOwn() {
    var queue = AgentAttentionQueue()
    queue.apply(.question(AgentQuestion(session: claude, turn: "t1", call: "toolu_q", arrivedAt: 1, prompts: [workflows])))
    queue.apply(.approval(AgentApproval(session: codex, turn: "t3", call: "approval", arrivedAt: 5)))
    queue.apply(.question(AgentQuestion(session: codex, turn: "t2", call: "call_q", arrivedAt: 4, prompts: [workflows])))
    let items = queue.items(at: 6)
    let approvalID = AgentAttentionID.approval(AgentCallIdentity(session: codex, turn: "t3", call: "approval"))
    let fresh: Set<AgentAttentionID> = [questionID, otherQuestionID, approvalID]
    let waiting = SpotlightKeyboardWait.waiting(behind: questionID, items: items, fresh: fresh)
    #expect(waiting?.id == approvalID)
    #expect(waiting.map { SpotlightKeyboardWait.line($0, name: "Scheduler build") } == "Scheduler build needs approval · next")
    // Waiting moves nothing: the approval's deadline is still 30 seconds from its own arrival.
    #expect(waiting?.approval?.expiresAt == 35)
    let question = items.first { $0.id == otherQuestionID }
    #expect(question.map { SpotlightKeyboardWait.line($0, name: "strata") } == "strata needs an answer · next")
}

@Test func onlyRequestsWaitAndTheFocusedCardIsNeverItsOwnArrival() {
    var queue = AgentAttentionQueue()
    queue.apply(.question(AgentQuestion(session: claude, turn: "t1", call: "toolu_q", arrivedAt: 1)))
    queue.apply(.outcome(AgentOutcome(session: codex, turn: "done", status: .finished, arrivedAt: 2)))
    let items = queue.items(at: 3)
    let outcomeID = AgentAttentionID.outcome(AgentTurnIdentity(session: codex, turn: "done"))
    #expect(SpotlightKeyboardWait.waiting(behind: questionID, items: items, fresh: [questionID, outcomeID]) == nil)
}

// MARK: - Foot line (Paper L frames 1, 2, 4, 5, 7)

@Test func beforeTheKeyboardIsInTheFootNamesTheHotkeyOnlyWhenItIsOn() {
    #expect(SpotlightCardFoot.line(phase: .answering, hasKeyboard: false, questionCount: 1, viewedIsLast: true,
                                   returnApp: nil, hotkey: "⌃⌥Space") == "⌃⌥Space to answer here")
    #expect(SpotlightCardFoot.line(phase: .answering, hasKeyboard: false, questionCount: 1, viewedIsLast: true,
                                   returnApp: nil, hotkey: nil) == nil)
    // A card Herdly cannot answer does not invite an answer.
    #expect(SpotlightCardFoot.line(phase: .readOnly, hasKeyboard: false, questionCount: 1, viewedIsLast: true,
                                   returnApp: nil, hotkey: "⌃⌥Space") == nil)
}

@Test func withTheKeyboardInTheFootNamesTheKeysAndTheAppItReturnsTo() {
    func foot(_ phase: SpotlightCardPhase, count: Int = 1, last: Bool = true, app: String? = "Ghostty") -> String? {
        SpotlightCardFoot.line(phase: phase, hasKeyboard: true, questionCount: count, viewedIsLast: last,
                               returnApp: app, hotkey: "⌃⌥Space")
    }
    #expect(foot(.answering) == "1–9 pick · ⏎ send · esc back to Ghostty")
    #expect(foot(.answering, count: 3, last: false) == "1–9 pick · ⏎ next · ← → step · esc back to Ghostty")
    #expect(foot(.answering, count: 3, last: true) == "1–9 pick · ⏎ send · ← → step · esc back to Ghostty")
    #expect(foot(.handedBack(askedAt: 0)) == "⏎ open · esc back to Ghostty")
    #expect(foot(.readOnly) == "⏎ open · esc back to Ghostty")
    #expect(foot(.sent(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], picks: [.options([1])])))
            == "Back to Ghostty in 1s")
    #expect(foot(.answering, app: nil) == "1–9 pick · ⏎ send · esc close")
}

@Test func theHandedBackLineSaysWhenItWasAsked() {
    #expect(SpotlightCardLines.handedBack(askedAt: 100, now: 130) == "Handed back with no answer · asked 30s ago")
    #expect(SpotlightCardLines.handedBack(askedAt: 100, now: 400) == "Handed back with no answer · asked 5m ago")
}
