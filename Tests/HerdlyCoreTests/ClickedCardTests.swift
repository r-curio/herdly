import Foundation
import Testing
@testable import HerdlyCore

private let claude = AgentSessionIdentity(source: .claude, sourceScope: "/claude", session: "s1", surface: .cli)
private let codex = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s2", surface: .cli)
private let approvalID = AgentAttentionID.approval(AgentCallIdentity(session: claude, turn: "t1", call: "toolu_1"))
private let questionID = AgentAttentionID.question(AgentCallIdentity(session: codex, turn: "t2", call: "call_2"))
private let otherApprovalID = AgentAttentionID.approval(AgentCallIdentity(session: claude, turn: "t1", call: "toolu_9"))

@Test func escapeOnAClickedCardReturnsToTheQueueAndASecondEscapeCollapses() {
    var controller = NotchPresentationController()
    controller.openQueue()
    do { let result = controller.update(interacting: true, now: 1); #expect(result == .queue) }
    do { let result = controller.openCard(approvalID); #expect(result) }
    do { let result = controller.update(interacting: true, now: 2, queued: [approvalID]); #expect(result == .clickedCard(approvalID)) }

    do { let result = controller.escape(); #expect(result == .backToQueue) }
    do { let result = controller.update(interacting: true, now: 3, queued: [approvalID]); #expect(result == .queue) }

    do { let result = controller.escape(); #expect(result == .collapse) }
    do { let result = controller.update(interacting: false, now: 4, queued: [approvalID]); #expect(result == .collapsed) }
}

@Test func escapeOnTheQueueOrASpotlightCollapses() {
    var controller = NotchPresentationController()
    controller.openQueue()
    do { let result = controller.escape(); #expect(result == .collapse) }
    controller.present(questionID, now: 10)
    do { let result = controller.escape(); #expect(result == .collapse) }
    do { let result = controller.update(interacting: false, now: 10.5); #expect(result == .collapsed) }
}

@Test func backToQueueLeavesTheCardWithoutDismissingAnything() {
    var controller = NotchPresentationController()
    controller.openQueue()
    controller.openCard(questionID)
    controller.backToQueue()
    do { let result = controller.update(interacting: true, now: 1, queued: [questionID]); #expect(result == .queue) }
}

@Test func onlyApprovalsAndQuestionsOpenAsClickedCards() {
    var controller = NotchPresentationController()
    controller.openQueue()
    let session = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s3", surface: .desktop)
    do { let result = controller.openCard(.outcome(AgentTurnIdentity(session: session, turn: "t"))); #expect(!result) }
    do { let result = controller.openCard(.running(AgentTurnIdentity(session: session, turn: "t"))); #expect(!result) }
    do { let result = controller.openCard(.unavailable(session)); #expect(!result) }
    do { let result = controller.update(interacting: true, now: 1); #expect(result == .queue) }
}

@Test func aClickedCardHasNoTimedCloseAndHoverCannotSwapItAway() {
    var controller = NotchPresentationController()
    controller.openQueue()
    controller.openCard(approvalID)
    // Far past the three-second spotlight close, still interacting.
    do { let result = controller.update(interacting: true, now: 100, queued: [approvalID, questionID]); #expect(result == .clickedCard(approvalID)) }
    // A fresh card neither takes the spotlight nor replaces the clicked card.
    #expect(!controller.acceptsAgentSpotlight(interacting: true, draftInProgress: false, now: 101))
    controller.present(questionID, now: 101)
    do { let result = controller.update(interacting: true, now: 101.5, queued: [approvalID, questionID]); #expect(result == .clickedCard(approvalID)) }
    // Unsent text holds it through a hover gap.
    do { let result = controller.update(interacting: false, draftInProgress: true, now: 102, queued: [approvalID]); #expect(result == .clickedCard(approvalID)) }
}

@Test func aClickedCardClosesWithThePanelWhenInteractionEnds() {
    var controller = NotchPresentationController()
    controller.openQueue()
    controller.openCard(approvalID)
    do { let result = controller.update(interacting: false, now: 5, queued: [approvalID]); #expect(result == .collapsed) }
    // Hovering again opens the queue, not the card.
    do { let result = controller.update(interacting: true, now: 6, queued: [approvalID]); #expect(result == .queue) }
}

@Test func aClickedCardWhoseItemLeavesTheQueueFallsBackToTheQueueNeverAnotherItem() {
    var controller = NotchPresentationController()
    controller.openQueue()
    controller.openCard(approvalID)
    do { let result = controller.update(interacting: true, now: 1, queued: [otherApprovalID, questionID]); #expect(result == .queue) }
    // Its identity returning later does not reopen it.
    do { let result = controller.update(interacting: true, now: 2, queued: [approvalID]); #expect(result == .queue) }
}

@Test func headerOpenFromAClickedCardShowsTheQueue() {
    var controller = NotchPresentationController()
    controller.openQueue()
    controller.openCard(approvalID)
    controller.openQueue()
    do { let result = controller.update(interacting: true, now: 1, queued: [approvalID]); #expect(result == .queue) }
}

@Test func clickingHoveringAndEscapeNeverMoveTheApprovalDeadline() {
    var queue = AgentAttentionQueue()
    let call = AgentCallIdentity(session: claude, turn: "t1", call: "toolu_1")
    queue.apply(.approval(AgentApproval(session: claude, turn: "t1", call: "toolu_1", arrivedAt: 100, handoffAfter: 30)), now: 100)
    let id = AgentAttentionID.approval(call)
    var controller = NotchPresentationController()
    controller.openQueue()
    controller.openCard(id)
    let queued = Set(queue.items(at: 120).map(\.id))
    do { let result = controller.update(interacting: true, now: 120, queued: queued); #expect(result == .clickedCard(id)) }
    do { let result = controller.update(interacting: true, draftInProgress: true, now: 125, queued: queued); #expect(result == .clickedCard(id)) }
    do { let result = controller.escape(); #expect(result == .backToQueue) }
    controller.openCard(id)
    #expect(queue.items(at: 129.9).first?.approval?.expiresAt == 130)
    #expect(queue.items(at: 129.9).first?.kind == .actionableApproval)

    // At expiry the clicked card stays on the same request, now handed back in place.
    queue.expire(at: 130)
    let handedBack = queue.items(at: 130)
    #expect(handedBack.first?.kind == .handedBackApproval)
    #expect(handedBack.first?.approval?.expiresAt == 130)
    do { let result = controller.update(interacting: true, now: 130, queued: Set(handedBack.map(\.id))); #expect(result == .clickedCard(id)) }
}

@Test func arrowKeysMoveTheRowSelectionAndItFollowsItsRow() {
    let rows = [approvalID, questionID, otherApprovalID]
    var selection = QueueRowSelection()
    selection.move(.down, in: rows)
    #expect(selection.selected == approvalID)
    selection.move(.down, in: rows)
    selection.move(.down, in: rows)
    selection.move(.down, in: rows)
    #expect(selection.selected == otherApprovalID)
    selection.move(.up, in: rows)
    #expect(selection.selected == questionID)

    // Reordered rows keep the selection on the same row.
    selection.reconcile(rows: [otherApprovalID, questionID])
    #expect(selection.selected == questionID)
    // A row that leaves takes the selection with it.
    selection.reconcile(rows: [otherApprovalID])
    #expect(selection.selected == nil)

    var fromTop = QueueRowSelection()
    fromTop.move(.up, in: rows)
    #expect(fromTop.selected == otherApprovalID)
    var empty = QueueRowSelection()
    empty.move(.down, in: [])
    #expect(empty.selected == nil)
}

@Test func returnOpensASelectedApprovalOrQuestionAsItsCardAndLeavesOtherRowsToLaterWork() {
    let session = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s3", surface: .desktop)
    #expect(QueueRowSelection.returnAction(for: approvalID) == .openCard(approvalID))
    #expect(QueueRowSelection.returnAction(for: questionID) == .openCard(questionID))
    let outcome = AgentAttentionID.outcome(AgentTurnIdentity(session: session, turn: "t"))
    #expect(QueueRowSelection.returnAction(for: outcome) == .openSession(outcome))
}
