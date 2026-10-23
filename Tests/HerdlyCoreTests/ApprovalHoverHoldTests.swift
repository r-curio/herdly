import Foundation
import Testing
@testable import HerdlyCore

private let call = AgentCallIdentity(session: AgentSessionIdentity(source: .claude, sourceScope: "/tmp/root", session: "s",
                                                                   surface: .cli),
                                     turn: "t1", call: "a1")

private func live(_ expiresAt: Double) -> [ApprovalHoverHold<String>.Live] { [.init(key: "a", expiresAt: expiresAt)] }

@Test func heldDeadlineMovesOnlyLaterAndNeverPastTheMaximumHold() {
    #expect(ApprovalTiming.heldDeadline(expiresAt: 30, held: nil) == 30)
    #expect(ApprovalTiming.heldDeadline(expiresAt: 30, held: 20) == 30)
    #expect(ApprovalTiming.heldDeadline(expiresAt: 30, held: 45) == 45)
    #expect(ApprovalTiming.heldDeadline(expiresAt: 30, held: 500) == 120)
    #expect(ApprovalTiming.heldDeadline(expiresAt: 30, held: .infinity) == 30)
    #expect(ApprovalTiming.heldDeadline(expiresAt: 30, held: .nan) == 30)
}

@Test func hoverPausesTheCountdownAndLeavingResumesItFromWhereItStopped() {
    var hold = ApprovalHoverHold<String>()
    // Receipt at 0, deadline 30. The pointer arrives at 10 with 20 seconds left.
    hold.update(hovering: false, live: live(30), now: 5)
    #expect(hold.deadlines.isEmpty)
    hold.update(hovering: true, live: live(30), now: 10)
    hold.update(hovering: true, live: live(30), now: 25)
    #expect(hold.deadline(for: "a", expiresAt: 30) == 45)
    // The pointer leaves at 40: still 20 seconds left, and the deadline stops moving.
    hold.update(hovering: true, live: live(30), now: 40)
    hold.update(hovering: false, live: live(30), now: 40.2)
    hold.update(hovering: false, live: live(30), now: 50)
    #expect(hold.deadline(for: "a", expiresAt: 30) == 60)
    // A second hover keeps what was left then (10 seconds at 50).
    hold.update(hovering: true, live: live(30), now: 50)
    hold.update(hovering: true, live: live(30), now: 70)
    #expect(hold.deadline(for: "a", expiresAt: 30) == 80)
}

@Test func aHoverHoldNeverRunsPastTwoMinutesFromReceipt() {
    var hold = ApprovalHoverHold<String>()
    hold.update(hovering: true, live: live(30), now: 1)
    for now in stride(from: 2.0, through: 200, by: 1) { hold.update(hovering: true, live: live(30), now: now) }
    #expect(hold.deadline(for: "a", expiresAt: 30) == ApprovalTiming.maximumHold)
}

@Test func aRequestTooCloseToItsDeadlineIsNotHeldAndALeftRequestLosesItsHold() {
    var hold = ApprovalHoverHold<String>()
    hold.update(hovering: true, live: live(30), now: 29.5)
    hold.update(hovering: true, live: live(30), now: 29.9)
    #expect(hold.deadlines.isEmpty)

    var other = ApprovalHoverHold<String>()
    other.update(hovering: true, live: live(30), now: 10)
    other.update(hovering: true, live: live(30), now: 20)
    #expect(other.deadlines["a"] == 40)
    other.update(hovering: true, live: [], now: 21)
    #expect(other.deadlines.isEmpty)
}

@Test func theQueueKeepsAHoldThroughARescanAndHandsBackAtTheHeldDeadline() {
    var queue = AgentAttentionQueue()
    let approval = AgentApproval(session: call.session, turn: call.turn, call: call.call, arrivedAt: 0, hookRequestID: "r")
    queue.apply(.approval(approval))
    queue.hold([call: 50])
    // A rescan repeats the receipt deadline; the hold stays.
    queue.apply(.approval(approval))
    queue.expire(at: 49.9)
    #expect(queue.items(at: 49.9).first?.kind == .actionableApproval)
    #expect(queue.items(at: 49.9).first?.approval?.expiresAt == 50)
    #expect(queue.liveApprovals.first?.expiresAt == 30)
    queue.expire(at: 50)
    #expect(queue.items(at: 50).first?.kind == .handedBackApproval)
    // A handed-back request is never held again.
    queue.hold([call: 90])
    queue.expire(at: 60)
    #expect(queue.items(at: 60).first?.kind == .handedBackApproval)
}

@Test func theCodexQueueHoldsOnlyALiveRequestAndOnlyLater() {
    let request = AttentionRequest(id: UUID(), source: .cli, session: UUID(), turn: UUID(), arrivedAt: 0)
    var queue = AttentionQueue()
    queue.apply(requests: [request], now: 0)
    queue.hold(request.identity, until: 20)
    #expect(queue.items.first?.request?.expiresAt == 30)
    queue.hold(request.identity, until: 45)
    queue.expire(at: 44)
    #expect(queue.items.first?.kind == .actionableRequest)
    #expect(ApprovalDecisionPolicy.accepts(queue.items.first!.request!, decision: .allowOnce, now: 44))
    queue.expire(at: 45)
    #expect(queue.items.first?.kind == .handedBackRequest)
    queue.hold(request.identity, until: 80)
    #expect(queue.items.first?.request?.expiresAt == 45)
}

@Test func aHeldCountdownBarStandsStill() {
    // 20 seconds left of the 30-second window, before and during a hold.
    #expect(ApprovalCountdown(arrivedAt: 0, expiresAt: 30, now: 10)?.fraction == ApprovalCountdown(arrivedAt: 0, expiresAt: 60, now: 40)?.fraction)
    #expect(ApprovalCountdown(arrivedAt: 0, expiresAt: 60, now: 40)?.seconds == 20)
}

@Test func coordinatorsExtendOnlyLaterAndNotOnceSettled() {
    let codex = ApprovalCoordinator(requestID: UUID(), expiresAt: 30)
    codex.extend(to: 20)
    #expect(codex.expiresAt == 30)
    codex.extend(to: 50)
    #expect(codex.decide(requestID: codex.requestID, decision: .allowOnce, at: 40) == .allowOnce)
    codex.extend(to: 90)
    #expect(codex.expiresAt == 50)

    let claude = ClaudeApprovalCoordinator(requestID: "r", expiresAt: 30)
    claude.extend(to: 50)
    #expect(claude.expire(at: 40) == nil)
    #expect(claude.expire(at: 50) == .noDecision)
}

@Test func theCodexHelperWaitsForAHoldAndAcceptsADecisionWithinIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date().timeIntervalSince1970
    let request = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                  receivedAt: now, timeout: 0.3)
    #expect(ApprovalHoldStore.publish(ApprovalHoldRecord(requestID: request.id.uuidString, heldUntil: now + 1.2),
                                      to: ApprovalHoldStore.codexURL(in: root, id: request.id)))
    let writer = Thread {
        Thread.sleep(forTimeInterval: 0.6)
        _ = ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .allowOnce,
                                                         decidedAt: Date().timeIntervalSince1970), in: root)
    }
    writer.start()
    #expect(ApprovalHelper.awaitDecision(for: request, in: root, handoffTimeout: 0.3, waitBound: 5) == .allowOnce)

    // A hold for another request is ignored: the deadline passes and nothing is decided.
    let other = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                receivedAt: now, timeout: 0.2)
    #expect(ApprovalHoldStore.publish(ApprovalHoldRecord(requestID: request.id.uuidString, heldUntil: now + 5),
                                      to: ApprovalHoldStore.codexURL(in: root, id: other.id)))
    let started = Date()
    #expect(ApprovalHelper.awaitDecision(for: other, in: root, handoffTimeout: 0.2, waitBound: 5) == .noDecision)
    #expect(Date().timeIntervalSince(started) < 1)
}

@Test func theClaudeHelperWaitsForAHoldAndAcceptsADecisionWithinIt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-claude-hold-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date().timeIntervalSince1970
    let receipt = ClaudeApprovalReceipt(requestID: "request", receivedAt: now)
    #expect(ApprovalHoldStore.publish(ApprovalHoldRecord(requestID: "request", heldUntil: now + 1.2),
                                      to: ApprovalHoldStore.claudeURL(in: directory, id: "request")))
    let writer = Thread {
        Thread.sleep(forTimeInterval: 0.6)
        _ = ClaudeApprovalStore.publish(ClaudeApprovalDecision(requestID: "request", decision: .deny,
                                                               decidedAt: Date().timeIntervalSince1970), in: directory)
    }
    writer.start()
    #expect(ClaudeApprovalHelper.awaitDecision(for: "request", receipt: receipt, in: directory,
                                               handoffTimeout: 0.3, waitBound: 5) == .deny)
}

@Test func setupUpgradesTheThirtyEightSecondHookTimeout() {
    #expect(CodexSetupRequirements.legacyHookTimeouts.contains(38))
    #expect(CodexSetupRequirements.hookTimeout == 128)
    #expect(ClaudeSetupRequirements.hookTimeout == 128)
    let handler: [String: Any] = ["type": "command", "command": "/herdly", "timeout": 38]
    #expect(ClaudeSetupPlanner.handlerIsLegacy(handler, command: "/herdly"))
}
