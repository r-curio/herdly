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

public struct ClaudeApprovalLiveness: Codable, Equatable, Sendable {
    public let requestID: String
    public let publishedAt: Double
    public let heartbeatAt: Double

    public init(requestID: String, publishedAt: Double, heartbeatAt: Double) {
        self.requestID = requestID
        self.publishedAt = publishedAt
        self.heartbeatAt = heartbeatAt
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

/// Written by the hook only after Claude's response has been emitted on stdout.
public struct ClaudeApprovalDelivery: Codable, Equatable, Sendable {
    public let requestID: String
    public let decision: ApprovalDecision
    public let decidedAt: Double
    public let deliveredAt: Double

    public init(requestID: String, decision: ApprovalDecision, decidedAt: Double, deliveredAt: Double) {
        self.requestID = requestID
        self.decision = decision
        self.decidedAt = decidedAt
        self.deliveredAt = deliveredAt
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
    public static let livenessTimeout: TimeInterval = 0.25

    public static func receiptURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id + ".claude.receipt")
    }

    public static func livenessURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id + ".claude.live")
    }

    public static func decisionURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id + ".claude.decision")
    }

    public static func deliveryURL(in directory: URL, id: String) -> URL {
        directory.appendingPathComponent(id + ".claude.delivery")
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
    public static func publish(_ liveness: ClaudeApprovalLiveness, in directory: URL) -> Bool {
        guard isSafeRequestID(liveness.requestID), liveness.publishedAt.isFinite,
              liveness.heartbeatAt.isFinite else { return false }
        return replace(try? JSONEncoder().encode(liveness), to: livenessURL(in: directory, id: liveness.requestID))
    }

    @discardableResult
    public static func publish(_ decision: ClaudeApprovalDecision, in directory: URL) -> Bool {
        guard isSafeRequestID(decision.requestID), decision.decision.isUserDecision || decision.decision == .noDecision else {
            return false
        }
        return write(try? JSONEncoder().encode(decision), to: decisionURL(in: directory, id: decision.requestID))
    }

    @discardableResult
    public static func publish(_ delivery: ClaudeApprovalDelivery, in directory: URL) -> Bool {
        guard isSafeRequestID(delivery.requestID), delivery.decision.isUserDecision,
              delivery.decidedAt.isFinite, delivery.deliveredAt.isFinite else { return false }
        return write(try? JSONEncoder().encode(delivery), to: deliveryURL(in: directory, id: delivery.requestID))
    }

    public static func receipt(for id: String, in directory: URL) -> ClaudeApprovalReceipt? {
        guard isSafeRequestID(id), let data = SafeFile.read(receiptURL(in: directory, id: id), limit: 4096) else { return nil }
        guard let value = try? JSONDecoder().decode(ClaudeApprovalReceipt.self, from: data),
              value.requestID == id, value.receivedAt.isFinite, value.expiresAt.isFinite,
              abs(value.expiresAt - (value.receivedAt + ApprovalTiming.handoffTimeout)) < 0.001 else { return nil }
        return value
    }

    public static func liveness(for id: String, in directory: URL) -> ClaudeApprovalLiveness? {
        guard isSafeRequestID(id), let data = SafeFile.read(livenessURL(in: directory, id: id), limit: 4096) else { return nil }
        guard let value = try? JSONDecoder().decode(ClaudeApprovalLiveness.self, from: data),
              value.requestID == id, value.publishedAt.isFinite, value.heartbeatAt.isFinite else { return nil }
        return value
    }

    public static func removeLiveness(for id: String, in directory: URL) {
        guard isSafeRequestID(id) else { return }
        try? FileManager.default.removeItem(at: livenessURL(in: directory, id: id))
    }

    public static func decision(for id: String, in directory: URL) -> ClaudeApprovalDecision? {
        guard isSafeRequestID(id), let data = SafeFile.read(decisionURL(in: directory, id: id), limit: 4096) else { return nil }
        guard let value = try? JSONDecoder().decode(ClaudeApprovalDecision.self, from: data),
              value.requestID == id, value.decidedAt.isFinite else { return nil }
        return value
    }

    public static func delivery(for id: String, in directory: URL) -> ClaudeApprovalDelivery? {
        guard isSafeRequestID(id), let data = SafeFile.read(deliveryURL(in: directory, id: id), limit: 4096) else { return nil }
        guard let value = try? JSONDecoder().decode(ClaudeApprovalDelivery.self, from: data),
              value.requestID == id, value.decision.isUserDecision,
              value.decidedAt.isFinite, value.deliveredAt.isFinite else { return nil }
        return value
    }

    private static func write(_ data: Data?, to destination: URL) -> Bool {
        guard let data,
              (try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else {
            return false
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".herdly-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: .atomic)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    private static func replace(_ data: Data?, to destination: URL) -> Bool {
        guard let data,
              (try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else {
            return false
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".herdly-" + UUID().uuidString)
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
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
                                    liveness: ClaudeApprovalLiveness? = nil,
                                    connectionTimeout: TimeInterval = ApprovalTiming.connectionTimeout) -> ClaudeApprovalReceipt? {
        let deadline = ProcessInfo.processInfo.systemUptime + connectionTimeout
        repeat {
            if let liveness,
               !ClaudeApprovalStore.publish(ClaudeApprovalLiveness(requestID: requestID,
                                                                   publishedAt: liveness.publishedAt,
                                                                   heartbeatAt: Date().timeIntervalSince1970),
                                            in: directory) {
                return nil
            }
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
                                     liveness: ClaudeApprovalLiveness? = nil,
                                     handoffTimeout: TimeInterval = ApprovalTiming.handoffTimeout,
                                     waitBound: TimeInterval = ApprovalTiming.helperWaitBound) -> ApprovalDecision {
        awaitDecisionRecord(for: requestID, receipt: receipt, in: directory,
                            liveness: liveness,
                            handoffTimeout: handoffTimeout, waitBound: waitBound)?.decision ?? .noDecision
    }

    public static func awaitDecisionRecord(for requestID: String, receipt: ClaudeApprovalReceipt, in directory: URL,
                                           liveness: ClaudeApprovalLiveness? = nil,
                                           handoffTimeout: TimeInterval = ApprovalTiming.handoffTimeout,
                                           waitBound: TimeInterval = ApprovalTiming.helperWaitBound) -> ClaudeApprovalDecision? {
        // The bounded timeout is injectable for labs and tests; production uses the receipt's
        // exact 30-second deadline.
        let expiresAt = min(receipt.expiresAt, receipt.receivedAt + handoffTimeout)
        let coordinator = ClaudeApprovalCoordinator(requestID: requestID, expiresAt: expiresAt)
        let started = ProcessInfo.processInfo.systemUptime
        let hardDeadline = min(started + handoffTimeout + 1, started + waitBound)
        while ProcessInfo.processInfo.systemUptime < hardDeadline {
            if let liveness,
               !ClaudeApprovalStore.publish(ClaudeApprovalLiveness(requestID: requestID,
                                                                   publishedAt: liveness.publishedAt,
                                                                   heartbeatAt: Date().timeIntervalSince1970),
                                            in: directory) {
                return nil
            }
            let now = Date().timeIntervalSince1970
            if let record = ClaudeApprovalStore.decision(for: requestID, in: directory),
               record.decidedAt >= receipt.receivedAt,
               record.decidedAt <= now,
               let decision = coordinator.decide(requestID: record.requestID, decision: record.decision, at: record.decidedAt) {
                return decision.isUserDecision ? record : nil
            }
            if coordinator.expire(at: now) != nil { return nil }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        _ = coordinator.expire(at: Date().timeIntervalSince1970)
        return nil
    }

    public static func awaitDelivery(for requestID: String, decision: ClaudeApprovalDecision,
                                     in directory: URL,
                                     timeout: TimeInterval = 0.5) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let now = Date().timeIntervalSince1970
            if let delivery = ClaudeApprovalStore.delivery(for: requestID, in: directory),
               delivery.requestID == requestID,
               delivery.decision == decision.decision,
               delivery.decidedAt == decision.decidedAt,
               delivery.deliveredAt >= decision.decidedAt,
               delivery.deliveredAt <= now {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return false
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
