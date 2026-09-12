import Foundation

/// Bounded reads of regular files only; symlinks and oversized files are rejected.
public enum SafeFile {
    public static func read(_ url: URL, limit: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
        return bytes
    }
}

/// The hook helper's side of the approval protocol: wait for the companion receipt,
/// then for one decision, on one serialized path with bounded monotonic waits.
public enum ApprovalHelper {
    static let pollInterval: TimeInterval = 0.02

    /// Returns the companion receipt for exactly this request, or nil once the connection deadline passes.
    public static func awaitReceipt(for request: ApprovalRequest, publishedAt: Double, in directory: URL,
                                    connectionTimeout: TimeInterval = ApprovalTiming.connectionTimeout) -> ApprovalReceiptRecord? {
        let deadline = ProcessInfo.processInfo.systemUptime + connectionTimeout
        repeat {
            if let bytes = SafeFile.read(ApprovalStore.receiptURL(in: directory, id: request.id), limit: 4096),
               let value = try? JSONDecoder().decode(ApprovalReceiptRecord.self, from: bytes),
               value.requestID == request.id, value.receivedAt.isFinite,
               value.receivedAt >= publishedAt, value.receivedAt <= Date().timeIntervalSince1970,
               abs(value.expiresAt - (value.receivedAt + ApprovalTiming.handoffTimeout)) < 0.001 { return value }
            Thread.sleep(forTimeInterval: pollInterval)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    /// Waits for allow-once or deny bound to this request. Expiry, the independent wait bound,
    /// and any malformed, mismatched, late, or duplicate record all resolve to no decision.
    public static func awaitDecision(for request: ApprovalRequest, in directory: URL,
                                     handoffTimeout: TimeInterval = ApprovalTiming.handoffTimeout,
                                     waitBound: TimeInterval = ApprovalTiming.helperWaitBound) -> ApprovalDecision {
        let coordinator = ApprovalCoordinator(requestID: request.id, expiresAt: request.expiresAt)
        let started = ProcessInfo.processInfo.systemUptime
        let expiry = started + handoffTimeout
        let hardDeadline = min(expiry + 1, started + waitBound)
        while ProcessInfo.processInfo.systemUptime < hardDeadline {
            let now = Date().timeIntervalSince1970
            if let bytes = SafeFile.read(ApprovalStore.decisionURL(in: directory, id: request.id), limit: 4096),
               let record = try? JSONDecoder().decode(ApprovalDecisionRecord.self, from: bytes),
               record.decidedAt >= request.receivedAt, record.decidedAt <= now,
               let decision = coordinator.decide(requestID: record.requestID, decision: record.decision, at: record.decidedAt) {
                return decision
            }
            if ProcessInfo.processInfo.systemUptime >= expiry, let expired = coordinator.expire(at: request.expiresAt) { return expired }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return coordinator.expire(at: request.expiresAt) ?? .noDecision
    }

    /// Codex hook output for an explicit user decision; nothing for a handoff.
    public static func hookOutput(for decision: ApprovalDecision) -> Data? {
        guard decision.isUserDecision else { return nil }
        let value: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": decision == .allowOnce ? "allow" : "deny"]
        ]]
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
