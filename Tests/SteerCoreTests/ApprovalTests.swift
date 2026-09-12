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

@Test func rescanningKeepsTheOriginalReceiptDeadline() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                  receivedAt: 0, expiresAt: 0, outcome: .pending)
    #expect(ApprovalStore.publish(request, in: root))
    let first = ReminderReader.scan(events: root, rollouts: root).attentionRequests.first
    Thread.sleep(forTimeInterval: 0.05)
    let second = ReminderReader.scan(events: root, rollouts: root).attentionRequests.first
    #expect(first?.arrivedAt == second?.arrivedAt)
    #expect(first?.expiresAt == second?.expiresAt)
}

@Test func permissionPayloadBindsSessionTurnAndProvidedDetailsOnly() throws {
    let session = UUID(), turn = UUID()
    let payload: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": session.uuidString,
                                  "turn_id": turn.uuidString, "tool_name": "Bash", "cwd": "/tmp/lab",
                                  "tool_input": ["command": "touch MARKER"]]
    let request = try #require(ApprovalRequestParser.request(from: payload))
    #expect(request.sessionID == session && request.turnID == turn)
    #expect(request.outcome == .pending && request.receivedAt == 0 && request.expiresAt == 0)
    #expect(request.details.command == "touch MARKER")
    #expect(request.details.project == "/tmp/lab")
    #expect(request.details.action == "Bash")
    #expect(request.details.taskName == nil && request.details.reason == nil)
    #expect(request.details.longText?.contains("touch MARKER") == true)
    #expect(ApprovalRequestParser.request(from: payload) != request) // a fresh identity per invocation
}

@Test func unsupportedOrIncompletePermissionPayloadsStayInCodexFlow() {
    let session = UUID().uuidString, turn = UUID().uuidString
    let mcp: [String: Any] = ["session_id": session, "turn_id": turn, "tool_name": "mcp_tool", "tool_input": ["x": 1]]
    #expect(ApprovalRequestParser.request(from: mcp) == nil)
    let noTurn: [String: Any] = ["session_id": session, "tool_name": "Bash", "tool_input": ["command": "ls"]]
    #expect(ApprovalRequestParser.request(from: noTurn) == nil)
    let badSession: [String: Any] = ["session_id": "nope", "turn_id": turn, "tool_name": "Bash", "tool_input": ["command": "ls"]]
    #expect(ApprovalRequestParser.request(from: badSession) == nil)
    let untyped: [String: Any] = ["session_id": session, "turn_id": turn, "tool_input": ["command": "ls"]]
    #expect(ApprovalRequestParser.request(from: untyped) == nil)
    let patch: [String: Any] = ["session_id": session, "turn_id": turn, "tool_name": "apply_patch", "tool_input": ["patch": "x"]]
    #expect(ApprovalRequestParser.request(from: patch) == nil)
}

@Test func desktopRequestsHandBackImmediatelyAndCLIRequestsNeedVerifiedAwayFocus() {
    for focus in [CompletionFocus.disabled, .checking, .away, .focused, .unknown] {
        #expect(ApprovalHandoff.mustHandBack(source: .desktop, paneFocus: focus))
    }
    #expect(!ApprovalHandoff.mustHandBack(source: .cli, paneFocus: .away))
    #expect(!ApprovalHandoff.mustHandBack(source: .cli, paneFocus: .checking))
    #expect(ApprovalHandoff.mustHandBack(source: .cli, paneFocus: .disabled))
    #expect(ApprovalHandoff.mustHandBack(source: .cli, paneFocus: .focused))
    #expect(ApprovalHandoff.mustHandBack(source: .cli, paneFocus: .unknown))
}

@Test func onlyDesktopRequestsReleaseOnReceipt() {
    #expect(ApprovalHandoff.releasesOnReceipt(source: .desktop))
    #expect(!ApprovalHandoff.releasesOnReceipt(source: .cli))
}

@Test func receiptDeadlineOutlastsOneCompanionScanInterval() {
    #expect(ApprovalTiming.connectionTimeout > ApprovalTiming.scanInterval + 1)
    #expect(Double(CodexSetupRequirements.hookTimeout) >= ApprovalTiming.connectionTimeout + ApprovalTiming.helperWaitBound + 1)
}

@Test func abandonedRequestIsHandedBackWithoutAReceipt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                  receivedAt: 0, expiresAt: 0, outcome: .pending)
    #expect(ApprovalStore.publish(request, in: root))
    let stale = Date(timeIntervalSinceNow: -(ApprovalTiming.connectionTimeout + 5))
    try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: ApprovalStore.requestURL(in: root, id: request.id).path)
    let scan = ReminderReader.scan(events: root, rollouts: root)
    #expect(scan.attentionRequests.first?.state == .handedBack)
    #expect(!FileManager.default.fileExists(atPath: ApprovalStore.receiptURL(in: root, id: request.id).path))
}

@Test func onlyAllowOnceAndDenyAreUserDecisions() {
    #expect(ApprovalDecision.allowOnce.isUserDecision && ApprovalDecision.deny.isUserDecision)
    #expect(!ApprovalDecision.pending.isUserDecision && !ApprovalDecision.noDecision.isUserDecision)
}
