import Foundation

public enum ApprovalTiming {
    public static let handoffTimeout: TimeInterval = 30
    public static let connectionTimeout: TimeInterval = 2
    public static let helperWaitBound: TimeInterval = 31
}

public enum ApprovalDecision: String, Codable, Sendable {
    case pending
    case allowOnce = "allow"
    case deny
    case noDecision = "no_decision"
}

/// Details supplied by Codex. Nil fields are intentionally not filled in by Steer.
public struct ApprovalDetails: Codable, Equatable, Sendable {
    public let taskName: String?
    public let project: String?
    public let action: String?
    public let command: String?
    public let reason: String?
    public let longText: String?

    public init(taskName: String? = nil, project: String? = nil, action: String? = nil,
                command: String? = nil, reason: String? = nil, longText: String? = nil) {
        self.taskName = taskName; self.project = project; self.action = action
        self.command = command; self.reason = reason; self.longText = longText
    }

    private enum CodingKeys: String, CodingKey {
        case taskName = "task_name", project, action, command, reason, longText = "long_text"
    }
}

public struct ApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public let requestID: UUID
    public let sessionID: UUID
    public let turnID: UUID
    public let details: ApprovalDetails
    public let receivedAt: Double
    public let expiresAt: Double
    public var outcome: ApprovalDecision
    public var id: UUID { requestID }

    public init(requestID: UUID, sessionID: UUID, turnID: UUID, details: ApprovalDetails,
                receivedAt: Double, timeout: Double = ApprovalTiming.handoffTimeout, outcome: ApprovalDecision = .pending) {
        self.init(requestID: requestID, sessionID: sessionID, turnID: turnID, details: details,
                  receivedAt: receivedAt, expiresAt: receivedAt + timeout, outcome: outcome)
    }

    public init(requestID: UUID, sessionID: UUID, turnID: UUID, details: ApprovalDetails,
                receivedAt: Double, expiresAt: Double, outcome: ApprovalDecision) {
        self.requestID = requestID; self.sessionID = sessionID; self.turnID = turnID
        self.details = details; self.receivedAt = receivedAt; self.expiresAt = expiresAt
        self.outcome = outcome
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id", sessionID = "session_id", turnID = "turn_id", details,
             receivedAt = "captured_at", expiresAt = "expires_at", outcome
    }
}

public struct ApprovalDecisionRecord: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let decision: ApprovalDecision
    public let decidedAt: Double
    public init(requestID: UUID, decision: ApprovalDecision, decidedAt: Double) {
        self.requestID = requestID; self.decision = decision; self.decidedAt = decidedAt
    }
    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id", decision, decidedAt = "decided_at"
    }
}

public struct ApprovalReceiptRecord: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let receivedAt: Double
    public let expiresAt: Double
    public init(requestID: UUID, receivedAt: Double, expiresAt: Double = 0) {
        self.requestID = requestID; self.receivedAt = receivedAt
        self.expiresAt = expiresAt == 0 ? receivedAt + ApprovalTiming.handoffTimeout : expiresAt
    }
    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id", receivedAt = "received_at", expiresAt = "expires_at"
    }
}

/// A single serialized decision/deadline race for one helper invocation.
public final class ApprovalCoordinator: @unchecked Sendable {
    public let requestID: UUID
    public let expiresAt: Double
    private let lock = NSLock()
    private var finished = false

    public init(requestID: UUID, expiresAt: Double) { self.requestID = requestID; self.expiresAt = expiresAt }

    public func decide(requestID: UUID, decision: ApprovalDecision, at now: Double) -> ApprovalDecision? {
        lock.lock(); defer { lock.unlock() }
        guard requestID == self.requestID, !finished, decision != .pending else { return nil }
        if decision == .noDecision { finished = true; return decision }
        guard now < expiresAt else { return nil }
        finished = true; return decision
    }

    public func expire(at now: Double) -> ApprovalDecision? {
        lock.lock(); defer { lock.unlock() }
        guard !finished, now >= expiresAt else { return nil }
        finished = true; return .noDecision
    }
}

public enum ApprovalStore {
    public static func requestURL(in directory: URL, id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".approval") }
    public static func decisionURL(in directory: URL, id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".decision") }
    public static func receiptURL(in directory: URL, id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".receipt") }

    /// Creates a request without replacing an existing request for another invocation.
    @discardableResult public static func publish(_ request: ApprovalRequest, in directory: URL) -> Bool {
        write(try? JSONEncoder().encode(request), to: requestURL(in: directory, id: request.id))
    }

    /// Writes one decision atomically. A duplicate write fails because the destination is never replaced.
    @discardableResult public static func publish(_ decision: ApprovalDecisionRecord, in directory: URL) -> Bool {
        guard decision.decision == .allowOnce || decision.decision == .deny || decision.decision == .noDecision else { return false }
        return write(try? JSONEncoder().encode(decision), to: decisionURL(in: directory, id: decision.requestID))
    }

    @discardableResult public static func publish(_ receipt: ApprovalReceiptRecord, in directory: URL) -> Bool {
        write(try? JSONEncoder().encode(receipt), to: receiptURL(in: directory, id: receipt.requestID))
    }

    private static func write(_ data: Data?, to destination: URL) -> Bool {
        guard let data, (try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else { return false }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".steer-" + UUID().uuidString)
        do { try data.write(to: temporary, options: .atomic); try FileManager.default.moveItem(at: temporary, to: destination); return true }
        catch { try? FileManager.default.removeItem(at: temporary); return false }
    }
}
