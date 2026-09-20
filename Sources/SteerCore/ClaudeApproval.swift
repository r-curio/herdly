import Foundation

/// The small file protocol shared by the Claude hook and the companion. It uses string request
/// identities because Claude's session, prompt, and tool ids are opaque strings.
public struct ClaudeApprovalReceipt: Codable, Equatable, Sendable {
    public let requestID: String
    public let receivedAt: Double
    public let expiresAt: Double

    public init(requestID: String, receivedAt: Double,
                expiresAt: Double = 0) {
        self.requestID = requestID
        self.receivedAt = receivedAt
        self.expiresAt = expiresAt == 0 ? receivedAt + ApprovalTiming.handoffTimeout : expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case receivedAt = "received_at"
        case expiresAt = "expires_at"
    }
}

public struct ClaudeApprovalDecision: Codable, Equatable, Sendable {
    public let requestID: String
    public let decision: ApprovalDecision
    public let decidedAt: Double

    public init(requestID: String, decision: ApprovalDecision, decidedAt: Double) {
        self.requestID = requestID
        self.decision = decision
        self.decidedAt = decidedAt
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case decision
        case decidedAt = "decided_at"
    }
}

/// Serializes the one-winner race between an explicit notch decision and the deadline.
public final class ClaudeApprovalCoordinator: @unchecked Sendable {
    public let requestID: String
    public let expiresAt: Double
    private let lock = NSLock()
    private var finished = false

    public init(requestID: String, expiresAt: Double) {
        self.requestID = requestID
        self.expiresAt = expiresAt
    }

    public func decide(requestID: String, decision: ApprovalDecision, at now: Double) -> ApprovalDecision? {
        lock.lock(); defer { lock.unlock() }
        guard requestID == self.requestID, !finished, decision != .pending else { return nil }
        if decision == .noDecision {
            finished = true
            return decision
        }
        guard decision.isUserDecision, now < expiresAt else { return nil }
        finished = true
        return decision
    }

    public func expire(at now: Double) -> ApprovalDecision? {
        lock.lock(); defer { lock.unlock() }
        guard !finished, now >= expiresAt else { return nil }
        finished = true
        return .noDecision
    }
}

public enum ClaudeApprovalStore {
    public static func receiptURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id + ".claude.receipt")
    }

    public static func decisionURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id + ".claude.decision")
    }

    public static func isSafeRequestID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256
            && !id.contains(where: { $0.isNewline || $0 == "\u{0}" || $0 == "/" || $0 == "\\" })
    }

    @discardableResult
    public static func publish(_ receipt: ClaudeApprovalReceipt, in directory: URL) -> Bool {
        guard isSafeRequestID(receipt.requestID) else { return false }
        return write(try? JSONEncoder().encode(receipt), to: receiptURL(in: directory, id: receipt.requestID))
    }

    @discardableResult
    public static func publish(_ decision: ClaudeApprovalDecision, in directory: URL) -> Bool {
        guard isSafeRequestID(decision.requestID), decision.decision.isUserDecision || decision.decision == .noDecision else {
            return false
        }
        return write(try? JSONEncoder().encode(decision), to: decisionURL(in: directory, id: decision.requestID))
    }

    public static func receipt(for id: String, in directory: URL) -> ClaudeApprovalReceipt? {
        guard isSafeRequestID(id), let data = SafeFile.read(receiptURL(in: directory, id: id), limit: 4096) else { return nil }
        guard let value = try? JSONDecoder().decode(ClaudeApprovalReceipt.self, from: data),
              value.requestID == id, value.receivedAt.isFinite, value.expiresAt.isFinite,
              abs(value.expiresAt - (value.receivedAt + ApprovalTiming.handoffTimeout)) < 0.001 else { return nil }
        return value
    }

    public static func decision(for id: String, in directory: URL) -> ClaudeApprovalDecision? {
        guard isSafeRequestID(id), let data = SafeFile.read(decisionURL(in: directory, id: id), limit: 4096) else { return nil }
        guard let value = try? JSONDecoder().decode(ClaudeApprovalDecision.self, from: data),
              value.requestID == id, value.decidedAt.isFinite else { return nil }
        return value
    }

    private static func write(_ data: Data?, to destination: URL) -> Bool {
        guard let data,
              (try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else {
            return false
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".steer-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }
}

public enum ClaudeApprovalHelper {
    static let pollInterval: TimeInterval = 0.02

    public static func awaitReceipt(for requestID: String, publishedAt: Double, in directory: URL,
                                    connectionTimeout: TimeInterval = ApprovalTiming.connectionTimeout) -> ClaudeApprovalReceipt? {
        let deadline = ProcessInfo.processInfo.systemUptime + connectionTimeout
        repeat {
            if let receipt = ClaudeApprovalStore.receipt(for: requestID, in: directory),
               receipt.receivedAt.isFinite,
               receipt.receivedAt >= publishedAt,
               receipt.receivedAt <= Date().timeIntervalSince1970,
               abs(receipt.expiresAt - (receipt.receivedAt + ApprovalTiming.handoffTimeout)) < 0.001 {
                return receipt
            }
            Thread.sleep(forTimeInterval: pollInterval)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    public static func awaitDecision(for requestID: String, receipt: ClaudeApprovalReceipt, in directory: URL,
                                     handoffTimeout: TimeInterval = ApprovalTiming.handoffTimeout,
                                     waitBound: TimeInterval = ApprovalTiming.helperWaitBound) -> ApprovalDecision {
        // The bounded timeout is injectable for labs and tests; production uses the receipt's
        // exact 30-second deadline.
        let expiresAt = min(receipt.expiresAt, receipt.receivedAt + handoffTimeout)
        let coordinator = ClaudeApprovalCoordinator(requestID: requestID, expiresAt: expiresAt)
        let started = ProcessInfo.processInfo.systemUptime
        let hardDeadline = min(started + handoffTimeout + 1, started + waitBound)
        while ProcessInfo.processInfo.systemUptime < hardDeadline {
            let now = Date().timeIntervalSince1970
            if let record = ClaudeApprovalStore.decision(for: requestID, in: directory),
               record.decidedAt >= receipt.receivedAt,
               record.decidedAt <= now,
               let decision = coordinator.decide(requestID: record.requestID, decision: record.decision, at: record.decidedAt) {
                return decision
            }
            if let expired = coordinator.expire(at: now) { return expired }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return coordinator.expire(at: Date().timeIntervalSince1970) ?? .noDecision
    }

    public static func hookOutput(for decision: ApprovalDecision) -> Data? {
        guard decision.isUserDecision else { return nil }
        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": decision == .allowOnce ? "allow" : "deny"]
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
