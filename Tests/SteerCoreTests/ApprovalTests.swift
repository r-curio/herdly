import Foundation
import Testing
@testable import SteerCore

@Test func approvalCoordinatorBindsIdentityAndRejectsLateOrDuplicateDecisions() {
    let id = UUID(), other = UUID()
    let coordinator = ApprovalCoordinator(requestID: id, expiresAt: 130)
    #expect(coordinator.decide(requestID: other, decision: .allowOnce, at: 101) == nil)
    #expect(coordinator.decide(requestID: id, decision: .allowOnce, at: 129.9) == .allowOnce)
    #expect(coordinator.decide(requestID: id, decision: .deny, at: 129.9) == nil)
    let expired = ApprovalCoordinator(requestID: id, expiresAt: 130)
    #expect(expired.expire(at: 130) == .noDecision)
    #expect(expired.decide(requestID: id, decision: .deny, at: 130) == nil)
    let handoff = ApprovalCoordinator(requestID: id, expiresAt: 130)
    #expect(handoff.decide(requestID: id, decision: .noDecision, at: 101) == .noDecision)
    #expect(handoff.decide(requestID: id, decision: .allowOnce, at: 101) == nil)
}

@Test func approvalCoordinatorSerializesConcurrentButtonAndDeadlineWriters() {
    let coordinator = ApprovalCoordinator(requestID: UUID(), expiresAt: 100)
    final class Counter: @unchecked Sendable { let lock = NSLock(); var value = 0 }
    let accepted = Counter()
    DispatchQueue.concurrentPerform(iterations: 32) { index in
        let result = coordinator.decide(requestID: coordinator.requestID,
                                        decision: index.isMultiple(of: 2) ? .allowOnce : .deny, at: 99)
        if result != nil { accepted.lock.lock(); accepted.value += 1; accepted.lock.unlock() }
    }
    #expect(accepted.value == 1)
}

@Test func approvalStoreDoesNotReplaceAFirstDecision() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = UUID()
    #expect(ApprovalStore.publish(ApprovalDecisionRecord(requestID: id, decision: .deny, decidedAt: 10), in: directory))
    #expect(!ApprovalStore.publish(ApprovalDecisionRecord(requestID: id, decision: .allowOnce, decidedAt: 11), in: directory))
    let saved = try JSONDecoder().decode(ApprovalDecisionRecord.self, from: Data(contentsOf: ApprovalStore.decisionURL(in: directory, id: id)))
    #expect(saved.decision == .deny)
}

@Test func pendingApprovalKeepsReceiptDeadlineAndProvidedDetails() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(),
                                  details: ApprovalDetails(project: "/tmp/lab", command: "touch MARKER", reason: "Need permission"),
                                  receivedAt: 100)
    #expect(ApprovalStore.publish(request, in: root))
    let scan = ReminderReader.scan(events: root, rollouts: root)
    #expect(scan.attentionRequests.first?.expiresAt == 130)
    #expect(scan.attentionRequests.first?.details?.command == "touch MARKER")
    #expect(scan.attentionRequests.first?.details?.reason == "Need permission")
}

@Test func companionReceiptStartsTheDeadlineForAWaitingHelperRequest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                  receivedAt: 0, expiresAt: 0, outcome: .pending)
    #expect(ApprovalStore.publish(request, in: root))
    let before = Date().timeIntervalSince1970
    let scan = ReminderReader.scan(events: root, rollouts: root)
    let receipt = try JSONDecoder().decode(ApprovalReceiptRecord.self,
                                           from: Data(contentsOf: ApprovalStore.receiptURL(in: root, id: request.id)))
    #expect(receipt.receivedAt >= before)
    #expect(scan.attentionRequests.first?.arrivedAt == receipt.receivedAt)
    #expect(scan.attentionRequests.first?.expiresAt == receipt.expiresAt)
}
