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

@Test func aClaudeQuestionsDeadlineExpiresWhileItsCardHasTheKeyboard() {
    // Asked at 100 with 30 seconds; the card has the keyboard from 105 and the pointer never rests on
    // the notch. The hover hold reads the pointer only, so the deadline stays at 130.
    var controller = NotchPresentationController()
    var holds = ApprovalHoverHold<String>()
    var card = SpotlightKeyboardCard()
    let asked = 100.0
    let receiptDeadline = asked + ApprovalTiming.handoffTimeout
    controller.present(questionID, now: asked, duration: .threeSeconds)
    var deadline = receiptDeadline
    for now in stride(from: 105.0, through: 129.0, by: 1) {
        holds.update(hovering: NotchInteraction.isActive(pointerInside: false, keyboardFocus: true),
                     live: [.init(key: "request", expiresAt: receiptDeadline)], now: now)
        deadline = holds.deadline(for: "request", expiresAt: receiptDeadline)
        let phase = card.observe(card: questionID, answerable: now < deadline,
                                 window: .init(askedAt: asked, deadline: deadline), now: now)
        let mode = controller.update(interacting: false, keyboardFocus: true, keyboardHoldEnded: card.endsKeyboardHold,
                                     now: now, queued: [questionID])
        #expect(phase == .answering)
        #expect(mode == .agentSpotlight(questionID))
    }
    #expect(deadline == 130)
    // At the deadline Herdly can no longer answer: the card hands back with no answer.
    let phase = card.observe(card: questionID, answerable: false, window: nil, now: 130)
    #expect(phase == .handedBack(askedAt: 100))
}

@Test func handingBackEndsTheKeyboardHoldAndTheCardOpenTimeRunsAsIfFocusHadJustLeft() {
    var controller = NotchPresentationController()
    var card = SpotlightKeyboardCard()
    controller.present(questionID, now: 100, duration: .threeSeconds)
    _ = card.observe(card: questionID, answerable: true, window: .init(askedAt: 100, deadline: 130), now: 129)
    _ = controller.update(interacting: false, keyboardFocus: true, keyboardHoldEnded: card.endsKeyboardHold,
                          now: 129, queued: [questionID])
    #expect(!card.endsKeyboardHold)
    _ = card.observe(card: questionID, answerable: false, window: nil, now: 130)
    #expect(card.endsKeyboardHold)
    // Still focused, still visible: Return opens the agent while it shows.
    do { let mode = controller.update(interacting: false, keyboardFocus: true, keyboardHoldEnded: card.endsKeyboardHold,
                                      now: 131, queued: [questionID]); #expect(mode == .agentSpotlight(questionID)) }
    // Its 3-second open time, counted from the last held moment, then runs out.
    do { let mode = controller.update(interacting: false, keyboardFocus: true, keyboardHoldEnded: card.endsKeyboardHold,
                                      now: 132.5, queued: [questionID]); #expect(mode == .collapsed) }
    // A fresh card may take the spotlight once the held card no longer holds.
    var other = NotchPresentationController()
    other.present(questionID, now: 100, duration: .threeSeconds)
    #expect(other.acceptsAgentSpotlight(interacting: false, draftInProgress: false, keyboardFocus: true,
                                        keyboardHoldEnded: true, now: 200))
}

@Test func theSentCardStaysForItsWholeSecondEvenIfItsQuestionLeavesTheQueue() {
    var card = SpotlightKeyboardCard()
    let answer = SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], lastPick: .options([1]))
    _ = card.observe(card: questionID, answerable: true, window: nil, now: 10)
    card.arm(answer, for: questionID)
    _ = card.confirmSent(for: questionID, now: 12)
    // Claude recorded the answer at once: the question has left the queue, but the card is kept.
    #expect(card.keepsSentCard(now: 12.4) == questionID)
    do { let phase = card.observe(card: questionID, answerable: false, window: nil, now: 12.4); #expect(phase == .sent(answer)) }
    var controller = NotchPresentationController()
    controller.present(questionID, now: 0, duration: .threeSeconds)
    let queued: Set<AgentAttentionID> = Set([card.keepsSentCard(now: 12.4)].compactMap { $0 })
    do { let mode = controller.update(interacting: false, keyboardFocus: true, now: 12.4, queued: queued); #expect(mode == .agentSpotlight(questionID)) }
    // After the second it is no longer kept, and the fold is due.
    #expect(card.keepsSentCard(now: 13) == nil)
    #expect(card.foldDue(now: 13))
}

@Test func withoutTheKeyboardACardTakesOnlyDigitsAndReturnAndOnlyWhenItCanBeAnswered() {
    #expect(SpotlightCardKeys.action(for: .digit(2), card: .withoutKeyboard(answerable: true)) == .select(2))
    #expect(SpotlightCardKeys.action(for: .returnKey, card: .withoutKeyboard(answerable: true)) == .primary)
    for key in [SpotlightCardKey.open, .dismiss, .previousQuestion, .nextQuestion] {
        #expect(SpotlightCardKeys.action(for: key, card: .withoutKeyboard(answerable: true)) == .none)
    }
    #expect(allKeys.allSatisfy { SpotlightCardKeys.action(for: $0, card: .withoutKeyboard(answerable: false)) == .none })
}

@Test func aTypedAnswerWinsOverOptionsInTheSentPick() {
    #expect(SpotlightSentAnswer.Pick(typed: "  main  ", options: [1]) == .typed("main"))
    #expect(SpotlightSentAnswer.Pick(typed: "   ", options: [2, 0]) == .options([0, 2]))
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
    let answer = SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], lastPick: .options([1]))
    let phases: [SpotlightCardPhase] = [.answering, .readOnly, .handedBack(askedAt: 0), .sent(answer)]
    for phase in phases {
        for key in allKeys {
            let action = SpotlightCardKeys.action(for: key, card: .keyboard(phase))
            if action == .primary {
                #expect(key == .returnKey && phase == .answering)
            }
        }
    }
}

@Test func whileAnsweringADigitOnlySelectsAndTheLettersActAsTheirButtons() {
    #expect(SpotlightCardKeys.action(for: .digit(2), card: .keyboard(.answering)) == .select(2))
    #expect(SpotlightCardKeys.action(for: .open, card: .keyboard(.answering)) == .open)
    #expect(SpotlightCardKeys.action(for: .dismiss, card: .keyboard(.answering)) == .dismiss)
    #expect(SpotlightCardKeys.action(for: .previousQuestion, card: .keyboard(.answering)) == .step(-1))
    #expect(SpotlightCardKeys.action(for: .nextQuestion, card: .keyboard(.answering)) == .step(1))
    // Digit 0 is not an option.
    #expect(SpotlightCardKeys.action(for: .digit(0), card: .keyboard(.answering)) == .none)
}

@Test func afterHandBackDigitsAreInertAndReturnOpensTheAgent() {
    let phase = SpotlightCardPhase.handedBack(askedAt: 0)
    // Frame 7: "digits do nothing", silently. The key is consumed, so macOS does not beep.
    #expect((1...9).allSatisfy { SpotlightCardKeys.action(for: .digit($0), card: .keyboard(phase)) == .consume })
    #expect(SpotlightCardKeys.action(for: .returnKey, card: .keyboard(phase)) == .open)
    #expect(SpotlightCardKeys.action(for: .open, card: .keyboard(phase)) == .open)
    // "Open in <agent>" is the only button.
    #expect(SpotlightCardKeys.action(for: .dismiss, card: .keyboard(phase)) == .none)
}

@Test func aReadOnlyCardTakesNoDigitsAndReturnOpens() {
    #expect((1...9).allSatisfy { SpotlightCardKeys.action(for: .digit($0), card: .keyboard(.readOnly)) == .consume })
    #expect(SpotlightCardKeys.action(for: .returnKey, card: .keyboard(.readOnly)) == .open)
    #expect(SpotlightCardKeys.action(for: .dismiss, card: .keyboard(.readOnly)) == .dismiss)
}

@Test func onceSentNoKeyDoesAnything() {
    let phase = SpotlightCardPhase.sent(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], lastPick: .options([1])))
    #expect(allKeys.allSatisfy { SpotlightCardKeys.action(for: $0, card: .keyboard(phase)) == .none })
}

@Test func pickSeveralDigitsToggleAndReturnSendsTheTickedSet() {
    let several = QuestionPrompt(header: "Labels", question: "Which labels?", options: ["bug", "docs", "ui"], multiSelect: true)
    var call = ClaudeQuestionCallSelection(prompts: [several])
    // Nothing ticked: Send stays disabled, so Return does nothing.
    #expect(call.primary(viewed: 0) == .send(enabled: false))
    for digit in [1, 2, 3, 3] {
        guard case let .select(number) = SpotlightCardKeys.action(for: .digit(digit), card: .keyboard(.answering)) else {
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
    let answer = SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], lastPick: .options([1]))
    #expect(answer.line == "Sent to Claude: 2 · Every workflow that mentions it")
    #expect(answer.chosen == [1])
    #expect(answer.options == ["Only release.yml (Recommended)", "Every workflow that mentions it", "None, close it by hand"])
}

@Test func theSentLineDropsTheRecommendedMarkAndListsTicksInOrder() {
    #expect(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], lastPick: .options([2, 0])).line
            == "Sent to Claude: 1, 3 · Only release.yml, None, close it by hand")
    #expect(SpotlightSentAnswer.make(agent: "Codex", prompts: [workflows], lastPick: .typed("  only main  ")).line
            == "Sent to Codex: only main")
    #expect(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows, workflows, workflows],
                                     lastPick: .typed("x")).line
            == "Sent to Claude: 3 answers")
}

@Test func theCardShowsSentOnlyAfterTheSendLeftHerdlyAndFoldsASecondLater() {
    var card = SpotlightKeyboardCard()
    let answer = SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], lastPick: .options([1]))
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
    card.arm(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], lastPick: .options([0])), for: questionID)
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

private func foot(_ card: SpotlightCardFocus, count: Int = 1, last: Bool = true, app: String? = "Ghostty",
                  hotkey: String? = "⌃⌥Space", openOffered: Bool = true) -> SpotlightCardFoot? {
    SpotlightCardFoot.make(card: card, questionCount: count, viewedIsLast: last, returnApp: app, hotkey: hotkey,
                           openOffered: openOffered)
}

@Test func theFootAdvertisesReturnOnlyWhenTheCardShowsAnOpen() {
    // A Claude card handed back with no reachable Open, or a Codex card waiting for terminal setup:
    // there is nothing for Return to open, so the line names no Return.
    #expect(foot(.keyboard(.handedBack(askedAt: 0)), openOffered: false)?.text == "esc back to Ghostty")
    #expect(foot(.keyboard(.readOnly), count: 2, openOffered: false)?.text == "← → step · esc back to Ghostty")
    #expect(foot(.keyboard(.readOnly), openOffered: false)?.spoken == "Escape goes back to Ghostty")
    // Answering, Return is the card's own Send, whatever Open does.
    #expect(foot(.keyboard(.answering), openOffered: false)?.text == "1–9 pick · ⏎ send · esc back to Ghostty")
}

@Test func beforeTheKeyboardIsInTheFootNamesTheHotkeyOnlyWhenItIsOn() {
    #expect(foot(.withoutKeyboard(answerable: true))?.text == "⌃⌥Space to answer here")
    #expect(foot(.withoutKeyboard(answerable: true), hotkey: nil) == nil)
    // A card Herdly cannot answer does not invite an answer: "answer here" would be false there.
    #expect(foot(.withoutKeyboard(answerable: false)) == nil)
}

@Test func withTheKeyboardInTheFootNamesTheKeysAndTheAppItReturnsTo() {
    #expect(foot(.keyboard(.answering))?.text == "1–9 pick · ⏎ send · esc back to Ghostty")
    #expect(foot(.keyboard(.answering), count: 3, last: false)?.text == "1–9 pick · ⏎ next · ← → step · esc back to Ghostty")
    #expect(foot(.keyboard(.answering), count: 3, last: true)?.text == "1–9 pick · ⏎ send · ← → step · esc back to Ghostty")
    #expect(foot(.keyboard(.handedBack(askedAt: 0)))?.text == "⏎ open · esc back to Ghostty")
    #expect(foot(.keyboard(.readOnly))?.text == "⏎ open · esc back to Ghostty")
    #expect(foot(.keyboard(.sent(SpotlightSentAnswer.make(agent: "Claude", prompts: [workflows], lastPick: .options([1])))))?.text
            == "Back to Ghostty in 1s")
    #expect(foot(.keyboard(.answering), app: nil)?.text == "1–9 pick · ⏎ send · esc close")
}

@Test func voiceOverReadsTheFootLineKeysByName() {
    #expect(foot(.keyboard(.answering), count: 3, last: false)?.spoken
            == "1 to 9 picks, Return goes to the next question, left and right arrows step between questions, Escape goes back to Ghostty")
    #expect(foot(.keyboard(.handedBack(askedAt: 0)))?.spoken == "Return opens the agent, Escape goes back to Ghostty")
}

@Test func theHandedBackLineSaysWhenItWasAsked() {
    #expect(SpotlightCardLines.handedBack(askedAt: 100, now: 130) == "Handed back with no answer · asked 30s ago")
    #expect(SpotlightCardLines.handedBack(askedAt: 100, now: 400) == "Handed back with no answer · asked 5m ago")
}

@Test func aConsumedDigitIsHandledButNeverSelectsOrSends() {
    #expect(SpotlightCardAction.consume.consumesKey)
    #expect(!SpotlightCardAction.none.consumesKey)
    #expect(SpotlightCardAction.select(1).consumesKey)
    // Only the keyboard card's read-only and handed-back phases swallow digits; elsewhere a digit
    // past the options, or on a card without the keyboard Herdly cannot answer, goes on to macOS.
    #expect(SpotlightCardKeys.action(for: .digit(0), card: .keyboard(.readOnly)) == .none)
    #expect(SpotlightCardKeys.action(for: .digit(1), card: .withoutKeyboard(answerable: false)) == .none)
}

// MARK: - A clicked card with the keyboard takes the same keys (#438, Paper K "C · Answer keys")

@Test func aClickedCardWithTheKeyboardTakesTheSpotlightCardsKeys() {
    let card = SpotlightCardFocus.clickedWithKeyboard(answerable: true)
    #expect(card == .keyboard(.answering))
    #expect(SpotlightCardKeys.action(for: .digit(2), card: card) == .select(2))
    #expect(SpotlightCardKeys.action(for: .returnKey, card: card) == .primary)
    #expect(SpotlightCardKeys.action(for: .open, card: card) == .open)
    #expect(SpotlightCardKeys.action(for: .dismiss, card: card) == .dismiss)
    #expect(SpotlightCardKeys.action(for: .previousQuestion, card: card) == .step(-1))
    #expect(SpotlightCardKeys.action(for: .nextQuestion, card: card) == .step(1))
}

@Test func onAClickedCardOnlyReturnReachesSendAndOnlyWhileHerdlyCanAnswerIt() {
    for answerable in [true, false] {
        // With the keyboard (#438), and without it, as before (#321).
        for card in [SpotlightCardFocus.clickedWithKeyboard(answerable: answerable), .withoutKeyboard(answerable: answerable)] {
            for key in allKeys where SpotlightCardKeys.action(for: key, card: card) == .primary {
                #expect(key == .returnKey && answerable)
            }
        }
    }
}

@Test func aClickedCardHerdlyCannotAnswerSwallowsDigitsAndReturnOpens() {
    // The Codex app without the daemon, or a Claude question whose countdown ended: the card is left
    // to read, with Open and Dismiss as its buttons. Return opens only where the card shows an Open;
    // the view's Open (`questionOpen`) does nothing where it shows none.
    let card = SpotlightCardFocus.clickedWithKeyboard(answerable: false)
    #expect(card == .keyboard(.readOnly))
    #expect((1...9).allSatisfy { SpotlightCardKeys.action(for: .digit($0), card: card) == .consume })
    #expect(SpotlightCardKeys.action(for: .returnKey, card: card) == .open)
    #expect(SpotlightCardKeys.action(for: .open, card: card) == .open)
    #expect(SpotlightCardKeys.action(for: .dismiss, card: card) == .dismiss)
}

@Test func aFocusedClickedCardStillRunsOutAtItsDeadline() {
    // ADR 0020 is unchanged by #438: holds read the pointer, and keyboard focus is not interaction.
    // A Claude question asked at 100 has its clicked card focused from 110 with the pointer away.
    var holds = ApprovalHoverHold<String>()
    let receiptDeadline = 100 + ApprovalTiming.handoffTimeout
    var card = SpotlightCardFocus.clickedWithKeyboard(answerable: true)
    for now in stride(from: 110.0, through: receiptDeadline, by: 1) {
        holds.update(hovering: NotchInteraction.isActive(pointerInside: false, keyboardFocus: true),
                     live: [.init(key: "question", expiresAt: receiptDeadline)], now: now)
        let deadline = holds.deadline(for: "question", expiresAt: receiptDeadline)
        #expect(deadline == receiptDeadline)
        card = .clickedWithKeyboard(answerable: now < deadline)
    }
    // At the deadline the card is read-only: Return opens the agent and can no longer send.
    #expect(card == .keyboard(.readOnly))
    #expect(SpotlightCardKeys.action(for: .returnKey, card: card) == .open)
}
