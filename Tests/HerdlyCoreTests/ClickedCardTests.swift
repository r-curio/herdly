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
    // The deadline's owners: the source-neutral queue (a Claude approval) and the Codex queue (a CLI
    // request), both arriving at 100 with the 30-second handoff, driven on one explicit clock.
    var agentQueue = AgentAttentionQueue()
    agentQueue.apply(.approval(AgentApproval(session: claude, turn: "t1", call: "toolu_1", arrivedAt: 100)), now: 100)
    let id = AgentAttentionID.approval(AgentCallIdentity(session: claude, turn: "t1", call: "toolu_1"))
    var codexQueue = AttentionQueue(observingSince: 0)
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 100)
    codexQueue.recordReceipts([request], now: 100)

    var controller = NotchPresentationController()
    controller.openQueue()
    controller.openCard(id)
    // Interaction right up to the deadline: hover, a draft, Escape back and a reopen, then hover again.
    let steps: [(at: Double, act: (inout NotchPresentationController) -> Void)] = [
        (105, { _ = $0.update(interacting: true, now: 105, queued: [id]) }),
        (110, { _ = $0.update(interacting: false, draftInProgress: true, now: 110, queued: [id]) }),
        (120, { _ = $0.escape(); $0.openCard(id) }),
        (129.999, { _ = $0.update(interacting: true, now: 129.999, queued: [id]) }),
    ]
    for step in steps {
        step.act(&controller)
        agentQueue.expire(at: step.at)
        codexQueue.expire(at: step.at)
        let approval = agentQueue.items(at: step.at).first { $0.id == id }
        #expect(approval?.kind == .actionableApproval)
        #expect(approval?.approval?.expiresAt == 130)
        let codex = codexQueue.items.compactMap(\.request).first { $0.id == request.id }
        #expect(codex?.state == .actionable)
        #expect(codex?.expiresAt == 130)
    }

    // Handback lands exactly at arrival + 30 s, and the clicked card stays on that request in place.
    agentQueue.expire(at: 130)
    codexQueue.expire(at: 130)
    let handedBack = agentQueue.items(at: 130).first { $0.id == id }
    #expect(handedBack?.kind == .handedBackApproval)
    #expect(handedBack?.approval?.expiresAt == 130)
    #expect(codexQueue.items.compactMap(\.request).first { $0.id == request.id }?.state == .handedBack)
    do { let result = controller.update(interacting: true, now: 130, queued: [id]); #expect(result == .clickedCard(id)) }
}

@Test func onlyApprovalsAndQuestionsAreRequests() {
    let session = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s3", surface: .desktop)
    #expect(approvalID.isRequest)
    #expect(questionID.isRequest)
    #expect(!AgentAttentionID.outcome(AgentTurnIdentity(session: session, turn: "t")).isRequest)
    #expect(!AgentAttentionID.running(AgentTurnIdentity(session: session, turn: "t")).isRequest)
    #expect(!AgentAttentionID.unavailable(session).isRequest)
}

@Test func selectableRowsSkipAClosedWorkingFoldAndASelectionThereClears() {
    let session = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s4", surface: .cli)
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: claude, turn: "t1", call: "toolu_1", arrivedAt: 10)), now: 10)
    queue.apply(.running(AgentRunning(session: session, turn: "t9", arrivedAt: 11)), now: 11)
    let items = queue.items(at: 12)
    let running = AgentAttentionID.running(AgentTurnIdentity(session: session, turn: "t9"))
    let sections = QueueSections.make(items, grouping: .none, project: { _ in nil })
    #expect(sections.foldsWorking)
    #expect(sections.selectableRows(workingOpen: false) == [approvalID])
    #expect(sections.selectableRows(workingOpen: true) == [approvalID, running])

    var selection = QueueRowSelection(selected: running)
    selection.reconcile(rows: sections.selectableRows(workingOpen: false))
    #expect(selection.selected == nil)

    // With nothing needing the user the working rows are the queue, never folded away.
    let unfolded = QueueSections.make(items.filter { $0.id == running }, grouping: .none, project: { _ in nil })
    #expect(unfolded.selectableRows(workingOpen: false) == [running])
    #expect(!sections.isEmpty)
    #expect(QueueSections.make([], grouping: .state, project: { _ in nil }).isEmpty)
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

@Test func returnOpensASelectedApprovalOrQuestionAsItsCard() throws {
    var queue = AgentAttentionQueue()
    queue.apply(.approval(AgentApproval(session: claude, turn: "t1", call: "toolu_1", arrivedAt: 10)))
    queue.apply(.question(AgentQuestion(session: codex, turn: "t2", call: "call_2", arrivedAt: 10)))
    let items = queue.items(at: 11)
    let approval = try #require(items.first { $0.id == approvalID })
    let question = try #require(items.first { $0.id == questionID })
    // A request opens as its card whatever its session's reach.
    for target in [ResultRowTarget.reachable, .unreachable] {
        #expect(QueueRowSelection.action(for: approval, target: target) == .openCard(approvalID))
        #expect(QueueRowSelection.action(for: question, target: target) == .openCard(questionID))
    }
}

@Test func singleCardModesNameTheirOneItem() {
    #expect(NotchPresentationMode.clickedCard(approvalID).singleCard == approvalID)
    #expect(NotchPresentationMode.clickedCard(approvalID).clickedCard == approvalID)
    #expect(NotchPresentationMode.agentSpotlight(questionID).singleCard == questionID)
    #expect(NotchPresentationMode.agentSpotlight(questionID).clickedCard == nil)
    #expect(NotchPresentationMode.agentSpotlight(questionID).showsSingleCard)
    for mode: NotchPresentationMode in [.queue, .collapsed] {
        #expect(mode.singleCard == nil)
        #expect(!mode.showsSingleCard)
    }
}

@Test func aDecisionOnTheClickedCardReturnsToTheQueueForClaudeAndCodexCLI() {
    let codexApprovalID = AgentAttentionID.approval(AgentCallIdentity(session: codex, turn: "t3", call: "call_3"))

    // Claude: Approve or Deny records the row's "Sending…" note on the still-queued request, and
    // the card it was clicked from returns to the queue, where the note shows.
    for decision in [ApprovalDecision.allowOnce, .deny] {
        var controller = NotchPresentationController()
        controller.openQueue()
        controller.openCard(approvalID)
        var notes = RowNotes()
        // Both decisions write "Sending…" at the click (`decideClaudeApproval`); delivery settles later.
        #expect(decision.isUserDecision)
        let recorded = notes.apply(.record(.sending), for: approvalID, pending: [approvalID])
        #expect(recorded)
        do { let left = controller.leaveCard(after: approvalID); #expect(left) }
        let mode = controller.update(interacting: true, now: 1, queued: [approvalID])
        #expect(mode == .queue)
        #expect(notes.note(for: approvalID) == .sending)
    }

    // Codex CLI: the request leaves the queue once its decision is written, with no note; the card
    // returns to the queue explicitly, never to another item.
    var controller = NotchPresentationController()
    controller.openQueue()
    controller.openCard(codexApprovalID)
    do { let left = controller.leaveCard(after: codexApprovalID); #expect(left) }
    do { let mode = controller.update(interacting: true, now: 1, queued: [approvalID]); #expect(mode == .queue) }

    // A decision on another request never moves the user off the card they have open.
    controller.openCard(approvalID)
    do { let left = controller.leaveCard(after: otherApprovalID); #expect(!left) }
    do { let mode = controller.update(interacting: true, now: 2, queued: [approvalID, otherApprovalID]); #expect(mode == .clickedCard(approvalID)) }
}
