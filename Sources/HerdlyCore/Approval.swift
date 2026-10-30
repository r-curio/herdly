import Foundation

public enum ApprovalTiming {
    public static let handoffTimeout: TimeInterval = 30
    /// The companion scans the events directory on this cadence; a receipt can only follow a scan.
    public static let scanInterval: TimeInterval = 2
    /// Covers one full scan interval plus scan time before the helper gives up on the companion.
    public static let connectionTimeout: TimeInterval = 5
    /// While the pointer is on the notch a live approval's countdown pauses (ADR 0020), but never
    /// past this long after its receipt: the hold adds at most `maximumHold - handoffTimeout`.
    public static let maximumHold: TimeInterval = 120
    /// A hold starts only with at least this much of the window left, so the helper reads the
    /// hold before its own deadline passes.
    public static let holdMargin: TimeInterval = 1
    /// The app writes each hold file this far ahead of the deadline the notch shows, so a helper
    /// never hands back while the notch still offers the choice. Questions' helper cap keeps it too.
    public static let holdLead: TimeInterval = 1
    public static let helperWaitBound: TimeInterval = maximumHold + 1

    /// The deadline a hook helper keeps for a request whose receipt says `expiresAt`: the hold's
    /// deadline when it is later, bounded by `maximumHold`. A missing or malformed hold leaves it.
    public static func heldDeadline(expiresAt: Double, held: Double?) -> Double {
        guard let held, held.isFinite else { return expiresAt }
        return min(max(expiresAt, held), expiresAt + maximumHold - handoffTimeout)
    }
}

/// The companion's request to keep one live approval open past its receipt deadline, written only
/// while the user's pointer is on the notch. The hook helper reads it each poll and bounds it with
/// `ApprovalTiming.heldDeadline`; it never decides anything.
public struct ApprovalHoldRecord: Codable, Equatable, Sendable {
    public let requestID: String
    public let heldUntil: Double

    public init(requestID: String, heldUntil: Double) {
        self.requestID = requestID
        self.heldUntil = heldUntil
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id", heldUntil = "held_until"
    }
}

public enum ApprovalHoldStore {
    public static func codexURL(in directory: URL, id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".hold") }
    public static func claudeURL(in directory: URL, id: String) -> URL { directory.appendingPathComponent(id + ".claude.hold") }

    /// Replaces the hold atomically; a hold only ever moves later while the request is live.
    @discardableResult public static func publish(_ hold: ApprovalHoldRecord, to url: URL) -> Bool {
        guard hold.heldUntil.isFinite, let data = try? JSONEncoder().encode(hold),
              (try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else {
            return false
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// The held deadline for exactly `requestID`, or nil when there is no readable, matching hold.
    public static func heldUntil(at url: URL, requestID: String) -> Double? {
        guard let bytes = SafeFile.read(url, limit: 4096),
              let value = try? JSONDecoder().decode(ApprovalHoldRecord.self, from: bytes),
              value.requestID == requestID, value.heldUntil.isFinite else { return nil }
        return value.heldUntil
    }
}

public enum ApprovalDecision: String, Codable, Sendable {
    case pending
    case allowOnce = "allow"
    case deny
    case noDecision = "no_decision"

    /// Only an explicit user answer may reach Codex as a hook decision.
    public var isUserDecision: Bool { self == .allowOnce || self == .deny }
}

/// Details supplied by Codex. Nil fields are intentionally not filled in by Herdly.
public struct ApprovalDetails: Codable, Equatable, Sendable {
    public let taskName: String?
    public let project: String?
    public let action: String?
    public let command: String?
    public let reason: String?
    public let longText: String?
    /// What `command` holds when it is not a command, such as "path" for a Claude file request. Nil means a command.
    public let commandLabel: String?

    public init(taskName: String? = nil, project: String? = nil, action: String? = nil,
                command: String? = nil, reason: String? = nil, longText: String? = nil, commandLabel: String? = nil) {
        self.taskName = taskName; self.project = project; self.action = action
        self.command = command; self.reason = reason; self.longText = longText
        self.commandLabel = commandLabel
    }

    private enum CodingKeys: String, CodingKey {
        case taskName = "task_name", project, action, command, reason, longText = "long_text", commandLabel = "command_label"
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
    public private(set) var expiresAt: Double
    private let lock = NSLock()
    private var finished = false

    public init(requestID: UUID, expiresAt: Double) { self.requestID = requestID; self.expiresAt = expiresAt }

    /// Moves the deadline later for a hold (ADR 0020); never earlier, and never once settled.
    public func extend(to deadline: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, deadline.isFinite, deadline > expiresAt else { return }
        expiresAt = deadline
    }

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
        guard decision.decision.isUserDecision || decision.decision == .noDecision else { return false }
        return write(try? JSONEncoder().encode(decision), to: decisionURL(in: directory, id: decision.requestID))
    }

    @discardableResult public static func publish(_ receipt: ApprovalReceiptRecord, in directory: URL) -> Bool {
        write(try? JSONEncoder().encode(receipt), to: receiptURL(in: directory, id: receipt.requestID))
    }

    private static func write(_ data: Data?, to destination: URL) -> Bool {
        guard let data, (try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else { return false }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".herdly-" + UUID().uuidString)
        do { try data.write(to: temporary, options: .atomic); try FileManager.default.moveItem(at: temporary, to: destination); return true }
        catch { try? FileManager.default.removeItem(at: temporary); return false }
    }
}
