import Foundation
import Testing
@testable import HerdlyCore

// #440, Paper K "D · Walk the to-check list": ← → walk what needs the user, one card at a time.

private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/claude", session: "c1", surface: .cli)
private let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "x1", surface: .cli)

private func item(_ id: AgentAttentionID, _ kind: AgentAttentionKind) -> AgentAttentionItem {
    AgentAttentionItem(id: id, kind: kind, session: claude, arrivedAt: 100, approval: nil, question: nil,
                       outcome: nil, running: nil, unavailableReason: nil)
}

private let approval = AgentAttentionID.approval(AgentCallIdentity(session: claude, turn: "t1", call: "a1"))
private let laterApproval = AgentAttentionID.approval(AgentCallIdentity(session: codex, turn: "t5", call: "a5"))
private let question = AgentAttentionID.question(AgentCallIdentity(session: codex, turn: "t2", call: "q2"))
private let handedBack = AgentAttentionID.approval(AgentCallIdentity(session: claude, turn: "t0", call: "a0"))
private let result = AgentAttentionID.outcome(AgentTurnIdentity(session: codex, turn: "t3"))
private let otherResult = AgentAttentionID.outcome(AgentTurnIdentity(session: claude, turn: "t4"))
private let earlier = AgentAttentionID.outcome(AgentTurnIdentity(session: claude, turn: "t-old"))
private let working = AgentAttentionID.running(AgentTurnIdentity(session: codex, turn: "t6"))
private let unknown = AgentAttentionID.unavailable(claude)

/// A queue as `AgentAttentionQueue.items` orders it: live approval, question, handed back, results,
/// status unknown, Earlier, then running work.
private let queue = [item(approval, .actionableApproval), item(question, .question), item(handedBack, .handedBackApproval),
                     item(result, .outcome), item(otherResult, .outcome), item(unknown, .statusUnavailable),
                     item(earlier, .earlierOutcome), item(working, .running)]

@Test func theWalkFollowsTheQueuesOwnOrderWithoutRunningWorkOrEarlierResults() {
    #expect(ToCheckWalk.order(of: queue) == [approval, question, handedBack, result, otherResult, unknown])
}

@Test func enteringTheWalkOpensTheFirstItemAsOneOfN() {
    let walk = ToCheckWalk(items: queue)
    #expect(walk?.screen == .card(approval))
    #expect(walk?.position == ToCheckWalk.Position(index: 1, count: 6))
}

@Test func thereIsNoWalkWhenNothingNeedsTheUser() {
    #expect(ToCheckWalk(items: [item(working, .running), item(earlier, .earlierOutcome)]) == nil)
    #expect(ToCheckWalk(items: []) == nil)
}

@Test func arrowsStepInQueueOrderAndStopAtEitherEndWithoutWrapping() {
    var walk = ToCheckWalk(items: queue)!
    do { let result = walk.step(.previous, items: queue, now: 1); #expect(result == .stop) }
    #expect(walk.screen == .card(approval))
    do { let result = walk.step(.next, items: queue, now: 1) == .card(question); #expect(result) }
    #expect(walk.position == ToCheckWalk.Position(index: 2, count: 6))
    for expected in [handedBack, result, otherResult, unknown] {
        do { let result = walk.step(.next, items: queue, now: 1) == .card(expected); #expect(result) }
    }
    do { let result = walk.step(.next, items: queue, now: 1); #expect(result == .stop) }
    #expect(walk.screen == .card(unknown))
    do { let result = walk.step(.previous, items: queue, now: 1) == .card(otherResult); #expect(result) }
}

@Test func steppingPastAResultLeavesItToCheck() {
    var walk = ToCheckWalk(items: queue)!
    for _ in 0..<5 { walk.step(.next, items: queue, now: 1) }
    // Passed every result and reached the end: nothing left the walk, nothing says "All checked".
    #expect(walk.order == ToCheckWalk.order(of: queue))
    #expect(walk.screen == .card(unknown))
    #expect(!walk.foldDue(now: 1_000))
    do { let result = walk.step(.previous, items: queue, now: 1) == .card(otherResult); #expect(result) }
    do { let result = walk.step(.previous, items: queue, now: 1) == .card(result); #expect(result) }
}

@Test func onACardWithSeveralQuestionsArrowsStepItsQuestionsFirst() {
    var walk = ToCheckWalk(items: queue)!
    walk.step(.next, items: queue, now: 1)
    // Question 1 of 3: → shows question 2, then 3; past the last it moves to the next card.
    do { let result = walk.step(.next, items: queue, question: .init(viewed: 0, count: 3), now: 1) == .question(1); #expect(result) }
    #expect(walk.screen == .card(question))
    do { let result = walk.step(.next, items: queue, question: .init(viewed: 1, count: 3), now: 1) == .question(2); #expect(result) }
    do { let result = walk.step(.next, items: queue, question: .init(viewed: 2, count: 3), now: 1) == .card(handedBack); #expect(result) }
    // ← mirrors it: back onto the question card, then its questions down to the first, then the card before.
    do { let result = walk.step(.previous, items: queue, now: 1) == .card(question); #expect(result) }
    do { let result = walk.step(.previous, items: queue, question: .init(viewed: 2, count: 3), now: 1) == .question(1); #expect(result) }
    do { let result = walk.step(.previous, items: queue, question: .init(viewed: 0, count: 3), now: 1) == .card(approval); #expect(result) }
}

@Test func aSingleQuestionCardStepsStraightToTheNextCard() {
    var walk = ToCheckWalk(items: queue)!
    walk.step(.next, items: queue, now: 1)
    do { let result = walk.step(.next, items: queue, question: .init(viewed: 0, count: 1), now: 1) == .card(handedBack); #expect(result) }
}

@Test func anItemArrivingMidWalkTakesItsQueuePositionAndTheCountFollows() {
    var walk = ToCheckWalk(items: queue)!
    walk.step(.next, items: queue, now: 1)
    #expect(walk.position == ToCheckWalk.Position(index: 2, count: 6))
    // A new live approval sorts ahead of the question: the card stays, its place and the count move.
    let arrived = [item(approval, .actionableApproval), item(laterApproval, .actionableApproval)] + queue.dropFirst()
    walk.observe(items: arrived, now: 2)
    #expect(walk.screen == .card(question))
    #expect(walk.position == ToCheckWalk.Position(index: 3, count: 7))
    do { let result = walk.step(.previous, items: arrived, now: 2) == .card(laterApproval); #expect(result) }
}

@Test func anItemLeavingElsewhereKeepsTheCardOnScreen() {
    var walk = ToCheckWalk(items: queue)!
    walk.step(.next, items: queue, now: 1)
    walk.observe(items: queue.filter { $0.id != approval }, now: 2)
    #expect(walk.screen == .card(question))
    #expect(walk.position == ToCheckWalk.Position(index: 1, count: 5))
}

@Test func whenTheCardOnScreenIsDoneTheWalkMovesToTheItemAfterIt() {
    var walk = ToCheckWalk(items: queue)!
    walk.step(.next, items: queue, now: 1)
    // Answered: the question leaves to-check.
    walk.observe(items: queue.filter { $0.id != question }, now: 2)
    #expect(walk.screen == .card(handedBack))
    #expect(walk.position == ToCheckWalk.Position(index: 2, count: 5))
}

@Test func whenTheLastCardIsDoneWithOthersLeftTheWalkMovesBackToTheOneBeforeIt() {
    let short = [item(approval, .actionableApproval), item(result, .outcome)]
    var walk = ToCheckWalk(items: short)!
    walk.step(.next, items: short, now: 1)
    // X dismissed the result; the approval passed earlier still needs the user.
    walk.observe(items: [item(approval, .actionableApproval)], now: 2)
    #expect(walk.screen == .card(approval))
    #expect(!walk.foldDue(now: 100))
}

@Test func whenTheLastItemIsDoneTheWalkSaysAllCheckedThenFolds() {
    let one = [item(result, .outcome), item(working, .running)]
    var walk = ToCheckWalk(items: one)!
    walk.observe(items: [item(working, .running)], now: 10)
    #expect(walk.screen == .allChecked)
    #expect(walk.position == nil)
    #expect(!walk.foldDue(now: 10.5))
    #expect(walk.foldDue(now: 10 + ToCheckWalk.allCheckedHold))
    // An arrival during the hold does not reopen the walk, and the arrows do nothing.
    walk.observe(items: [item(approval, .actionableApproval)], now: 10.6)
    #expect(walk.screen == .allChecked)
    do { let result = walk.step(.next, items: [item(approval, .actionableApproval)], now: 10.7); #expect(result == .stop) }
}

@Test func aCardThatLeavesWhileOnlyNewItemsRemainOpensTheFirstOfThem() {
    let one = [item(result, .outcome)]
    var walk = ToCheckWalk(items: one)!
    walk.observe(items: [item(approval, .actionableApproval), item(otherResult, .outcome)], now: 2)
    #expect(walk.screen == .card(approval))
    #expect(walk.position == ToCheckWalk.Position(index: 1, count: 2))
}

@Test func theHeaderReadsItsPlaceAloud() {
    #expect(ToCheckWalk.Position(index: 3, count: 4).spoken == "Item 3 of 4 to check")
}

// MARK: The walk in the notch's presentation

private func hotkeyQueue() -> NotchPresentationController {
    var controller = NotchPresentationController()
    controller.openQueueForKeyboard()
    _ = controller.update(interacting: false, keyboardFocus: true, now: 0)
    return controller
}

@Test func rightArrowInTheHotkeysQueueOpensTheFirstToCheckItemAsItsCard() {
    var controller = hotkeyQueue()
    do { let result = controller.enterWalk(items: queue); #expect(result) }
    #expect(controller.walk?.position == ToCheckWalk.Position(index: 1, count: 6))
    let mode = controller.update(interacting: false, keyboardFocus: true, now: 1, walkItems: queue)
    #expect(mode == .walkCard(approval))
    #expect(mode.singleCard == approval)
    #expect(!mode.showsAll)
}

@Test func onlyTheHotkeysQueueStartsAWalk() {
    var clicked = NotchPresentationController()
    clicked.openQueue()
    do { let result = clicked.enterWalk(items: queue); #expect(!result) }
    var empty = hotkeyQueue()
    do { let result = empty.enterWalk(items: [item(working, .running)]); #expect(!result) }
    do { let result = empty.update(interacting: false, keyboardFocus: true, now: 1); #expect(result == .queue) }
}

@Test func theWalkCardMovesWithTheQueueAndEndsOnAllChecked() {
    var controller = hotkeyQueue()
    let two = [item(approval, .actionableApproval), item(result, .outcome)]
    controller.enterWalk(items: two)
    // Approved: once the approval leaves to-check the walk moves on to the result.
    let afterDecision = [item(result, .outcome)]
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 1, walkItems: afterDecision) == .walkCard(result); #expect(result) }
    // X dismissed the result: nothing is left.
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 2, walkItems: []); #expect(result == .allChecked) }
    #expect(controller.walkFoldDue(now: 2 + ToCheckWalk.allCheckedHold))
}

@Test func decidingOnAWalkCardStaysOnItUntilItsItemLeaves() {
    var controller = hotkeyQueue()
    controller.enterWalk(items: queue)
    // The clicked card's D10 return to the queue does not apply to a walk card: it stays until its item leaves.
    do { let result = controller.leaveCard(after: approval); #expect(!result) }
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 1, walkItems: queue) == .walkCard(approval); #expect(result) }
}

@Test func escapeLeavesTheWalkForTheQueueWithThatItemsRow() {
    var controller = hotkeyQueue()
    controller.enterWalk(items: queue)
    controller.stepWalk(.next, items: queue, now: 1)
    do { let result = controller.escape() == .walkToQueue(selecting: question); #expect(result) }
    #expect(controller.walk == nil)
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 2, walkItems: queue); #expect(result == .queue) }
}

@Test func escapeOnAllCheckedCollapses() {
    var controller = hotkeyQueue()
    controller.enterWalk(items: [item(result, .outcome)])
    _ = controller.update(interacting: false, keyboardFocus: true, now: 1, walkItems: [])
    do { let result = controller.escape(); #expect(result == .collapse) }
}

@Test func theWalkFoldsWhenTheKeyboardGoesElsewhere() {
    var controller = hotkeyQueue()
    controller.enterWalk(items: queue)
    do { let result = controller.update(interacting: false, keyboardFocus: false, now: 1, walkItems: queue); #expect(result == .collapsed) }
    #expect(controller.walk == nil)
}

@Test func aFreshCardWaitsBehindTheWalkAndJoinsItInstead() {
    var controller = hotkeyQueue()
    controller.enterWalk(items: queue)
    #expect(!controller.acceptsAgentSpotlight(interacting: false, draftInProgress: false, keyboardFocus: true, now: 1))
    controller.present(laterApproval, now: 1)
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 1.5, walkItems: queue) == .walkCard(approval); #expect(result) }
}

@Test func theHeadersWellsStepByItemNotByQuestion() {
    var controller = hotkeyQueue()
    controller.enterWalk(items: queue)
    do { let result = controller.stepWalk(.next, items: queue, now: 1) == .card(question); #expect(result) }
    do { let result = controller.stepWalk(.next, items: queue, now: 1) == .card(handedBack); #expect(result) }
    do { let result = controller.update(interacting: false, keyboardFocus: true, now: 2, walkItems: queue) == .walkCard(handedBack); #expect(result) }
}

// MARK: A result card's keys in the walk

@Test func aResultCardWithTheKeyboardTakesOForOpenAndXForDismiss() {
    #expect(ResultCardKeys.action(for: .open, keyboard: true) == .open)
    #expect(ResultCardKeys.action(for: .dismiss, keyboard: true) == .dismiss)
}

@Test func aResultCardWithoutTheKeyboardTakesNoKeys() {
    #expect(ResultCardKeys.action(for: .open, keyboard: false) == .none)
    #expect(ResultCardKeys.action(for: .dismiss, keyboard: false) == .none)
    #expect(!ResultCardAction.none.consumesKey)
}

@Test func aWalkCardWithSeveralQuestionsShowsItsStepperOnItsOwnRowUnderTheWalkHeader() {
    #expect(QuestionStepperPlacement.resolve(mode: .walkCard(question), card: question, questionCount: 3) == .ownRow)
    #expect(QuestionStepperPlacement.resolve(mode: .walkCard(question), card: question, questionCount: 1) == .none)
}

// MARK: Review round 1

@Test func aResultThatAgesIntoEarlierMidWalkStaysInTheWalk() {
    let one = [item(result, .outcome), item(working, .running)]
    var walk = ToCheckWalk(items: one)!
    // Five minutes pass: the result moves under Earlier. Nothing was dismissed, so nothing is checked.
    let aged = [item(result, .earlierOutcome), item(working, .running)]
    walk.observe(items: aged, now: 400)
    #expect(walk.screen == .card(result))
    #expect(walk.position == ToCheckWalk.Position(index: 1, count: 1))
    #expect(!walk.foldDue(now: 1_000))
    // Dismissed: now it has left, and the walk ends.
    walk.observe(items: [item(working, .running)], now: 401)
    #expect(walk.screen == .allChecked)
}

@Test func anEarlierResultThatWasNotInTheWalkDoesNotJoinIt() {
    var walk = ToCheckWalk(items: [item(approval, .actionableApproval)])!
    walk.observe(items: [item(approval, .actionableApproval), item(earlier, .earlierOutcome)], now: 1)
    #expect(walk.order == [approval])
}
