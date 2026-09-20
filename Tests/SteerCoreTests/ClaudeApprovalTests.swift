import Foundation
import Testing
@testable import SteerCore

@Test func claudeApprovalDeadlineAndWinnerAreExact() {
    let coordinator = ClaudeApprovalCoordinator(requestID: "request", expiresAt: 30)

    #expect(coordinator.decide(requestID: "request", decision: .allowOnce, at: 29.999) == .allowOnce)
    #expect(coordinator.decide(requestID: "request", decision: .deny, at: 29) == nil)
    #expect(coordinator.decide(requestID: "other", decision: .deny, at: 29) == nil)
}

@Test func claudeApprovalExpiryHandsBackAtTheBoundary() {
    let coordinator = ClaudeApprovalCoordinator(requestID: "request", expiresAt: 30)

    #expect(coordinator.decide(requestID: "request", decision: .deny, at: 30) == nil)
    #expect(coordinator.expire(at: 30) == .noDecision)
    #expect(coordinator.expire(at: 31) == nil)
}

@Test func claudeHelperUsesTheReceiptDeadlineAndFailsClosedWithoutAReceipt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-timeout-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let publishedAt = Date().timeIntervalSince1970
    let receipt = ClaudeApprovalReceipt(requestID: "request", receivedAt: publishedAt)
    let started = Date()

    #expect(ClaudeApprovalHelper.awaitReceipt(for: "missing", publishedAt: publishedAt,
                                              in: directory, connectionTimeout: 0.05) == nil)
    #expect(ClaudeApprovalHelper.awaitDecision(for: "request", receipt: receipt, in: directory,
                                               handoffTimeout: 0.15, waitBound: 1) == .noDecision)
    #expect(Date().timeIntervalSince(started) < 0.8)
}

@Test func claudeApprovalStoreDoesNotReplaceAFirstWinnerAndOutputMatchesClaude() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("steer-claude-approval-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let receipt = ClaudeApprovalReceipt(requestID: "request", receivedAt: 10)
    #expect(ClaudeApprovalStore.publish(receipt, in: directory))
    #expect(!ClaudeApprovalStore.publish(ClaudeApprovalReceipt(requestID: "request", receivedAt: 11), in: directory))
    #expect(ClaudeApprovalStore.receipt(for: "request", in: directory) == receipt)
    #expect(!ClaudeApprovalStore.publish(ClaudeApprovalDecision(requestID: "request", decision: .pending, decidedAt: 12), in: directory))

    let output = try #require(ClaudeApprovalHelper.hookOutput(for: .allowOnce))
    let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    let specific = try #require(object["hookSpecificOutput"] as? [String: Any])
    #expect(specific["hookEventName"] as? String == "PermissionRequest")
    #expect((specific["decision"] as? [String: String])?["behavior"] == "allow")
    #expect(ClaudeApprovalHelper.hookOutput(for: .noDecision) == nil)
}
