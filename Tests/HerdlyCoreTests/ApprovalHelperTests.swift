import Foundation
import Testing
@testable import HerdlyCore

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func pendingRequest() -> ApprovalRequest {
    ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(command: "ls"),
                    receivedAt: 0, expiresAt: 0, outcome: .pending)
}

@Test func helperAcceptsOnlyAMatchingWellFormedReceiptWithinTheConnectionDeadline() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = pendingRequest()
    let publishedAt = Date().timeIntervalSince1970
    #expect(ApprovalHelper.awaitReceipt(for: request, publishedAt: publishedAt, in: root, connectionTimeout: 0.15) == nil)
    let receipt = ApprovalReceiptRecord(requestID: request.id, receivedAt: publishedAt + 0.01)
    #expect(ApprovalStore.publish(receipt, in: root))
    #expect(ApprovalHelper.awaitReceipt(for: request, publishedAt: publishedAt, in: root, connectionTimeout: 0.15) == receipt)
    let other = pendingRequest()
    let wrongDeadline = ApprovalReceiptRecord(requestID: other.id, receivedAt: publishedAt, expiresAt: publishedAt + 5)
    #expect(ApprovalStore.publish(wrongDeadline, in: root))
    #expect(ApprovalHelper.awaitReceipt(for: other, publishedAt: publishedAt, in: root, connectionTimeout: 0.15) == nil)
}

@Test func helperReturnsTheFirstValidDecisionAndIgnoresMismatchedRecords() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date().timeIntervalSince1970
    let request = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                  receivedAt: now, timeout: 2)
    let writer = Thread {
        Thread.sleep(forTimeInterval: 0.1)
        _ = ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .deny, decidedAt: now + 0.1), in: root)
    }
    writer.start()
    #expect(ApprovalHelper.awaitDecision(for: request, in: root, handoffTimeout: 2, waitBound: 2.5) == .deny)

    let stale = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                receivedAt: now, timeout: 0.3)
    #expect(ApprovalStore.publish(ApprovalDecisionRecord(requestID: stale.id, decision: .allowOnce, decidedAt: now - 5), in: root))
    #expect(ApprovalHelper.awaitDecision(for: stale, in: root, handoffTimeout: 0.3, waitBound: 0.5) == .noDecision)
}

@Test func helperHandsBackAtTheDeadlineAndAtTheIndependentWaitBound() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date().timeIntervalSince1970
    let request = ApprovalRequest(requestID: UUID(), sessionID: UUID(), turnID: UUID(), details: ApprovalDetails(),
                                  receivedAt: now, timeout: 0.2)
    let started = Date()
    #expect(ApprovalHelper.awaitDecision(for: request, in: root, handoffTimeout: 0.2, waitBound: 5) == .noDecision)
    #expect(Date().timeIntervalSince(started) < 1)
    let bounded = Date()
    #expect(ApprovalHelper.awaitDecision(for: request, in: root, handoffTimeout: 5, waitBound: 0.2) == .noDecision)
    #expect(Date().timeIntervalSince(bounded) < 1)
}

@Test func helperOutputCarriesOnlyUserDecisions() throws {
    #expect(ApprovalHelper.hookOutput(for: .noDecision) == nil)
    #expect(ApprovalHelper.hookOutput(for: .pending) == nil)
    let allow = try #require(ApprovalHelper.hookOutput(for: .allowOnce))
    let object = try #require(JSONSerialization.jsonObject(with: allow) as? [String: Any])
    let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
    #expect(specific["hookEventName"] as? String == "PermissionRequest")
    #expect((specific["decision"] as? [String: Any])?["behavior"] as? String == "allow")
    let deny = try #require(ApprovalHelper.hookOutput(for: .deny))
    #expect(String(decoding: deny, as: UTF8.self).contains("\"behavior\":\"deny\""))
}

@Test func safeReadRejectsSymlinksAndOversizedFiles() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    try Data("ok".utf8).write(to: target)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(SafeFile.read(target, limit: 2) == Data("ok".utf8))
    #expect(SafeFile.read(target, limit: 1) == nil)
    #expect(SafeFile.read(link, limit: 16) == nil)
}
