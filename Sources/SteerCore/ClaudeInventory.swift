import Foundation

public enum ClaudeInventoryKind: String, Equatable, Sendable {
    case interactive
    case background
}

public enum ClaudeInventoryLifecycle: Equatable, Sendable {
    case interactive(status: String)
    case background(state: String)

    public var isActive: Bool {
        switch self {
        case let .interactive(status): return status == "busy" || status == "waiting"
        case let .background(state): return state == "working" || state == "blocked"
        }
    }

    public var needsRestart: Bool {
        switch self {
        case .interactive: return true
        case let .background(state): return state == "working" || state == "blocked"
        }
    }

    public var isIdleInteractive: Bool {
        if case .interactive(status: "idle") = self { return true }
        return false
    }
}

public struct ClaudeInventorySession: Equatable, Sendable {
    public let sessionID: String
    /// Claude's supplied display name. It identifies the session only for presentation; it is not
    /// used for targeting or persisted attention identity.
    public let name: String
    public let kind: ClaudeInventoryKind
    public let startedAt: Double
    public let lifecycle: ClaudeInventoryLifecycle
    /// The live process holding the session, when the source identifies it (Claude's session
    /// registry, with its start time verified when Claude recorded `procStart`). nil from
    /// `claude agents --json`.
    public let pid: Int32?

    public init(sessionID: String, name: String = "", kind: ClaudeInventoryKind, startedAt: Double,
                lifecycle: ClaudeInventoryLifecycle, pid: Int32? = nil) {
        self.sessionID = sessionID
        self.name = name
        self.kind = kind
        self.startedAt = startedAt
        self.lifecycle = lifecycle
        self.pid = pid
    }
}

public struct ClaudeInventoryScan: Equatable, Sendable {
    public let sourceScope: String
    public let observedAt: Double
    public let sessions: [ClaudeInventorySession]
    public let available: Bool
    public let failure: String?
    public let ambiguousSessionIDs: Set<String>
    /// Sessions known to run in the background without a lifecycle row: the session registry names
    /// a live background holder but carries no background state. Never includes a session that also
    /// has a row.
    public let backgroundSessionIDs: Set<String>

    public func isBackgroundSession(_ sessionID: String) -> Bool {
        available && (backgroundSessionIDs.contains(sessionID)
            || sessions.contains { $0.sessionID == sessionID && $0.kind == .background })
    }

    public init(sourceScope: String, observedAt: Double, sessions: [ClaudeInventorySession] = [],
                available: Bool = true, failure: String? = nil,
                ambiguousSessionIDs: Set<String> = [], backgroundSessionIDs: Set<String> = []) {
        self.sourceScope = URL(fileURLWithPath: sourceScope).standardizedFileURL.path
        self.observedAt = observedAt
        self.sessions = sessions
        self.available = available
        self.failure = failure
        self.ambiguousSessionIDs = ambiguousSessionIDs
        self.backgroundSessionIDs = available ? backgroundSessionIDs.subtracting(sessions.map(\.sessionID)) : []
    }

    public static func unavailable(sourceScope: String, observedAt: Double, reason: String,
                                   ambiguousSessionIDs: Set<String> = []) -> Self {
        Self(sourceScope: sourceScope, observedAt: observedAt, available: false, failure: reason,
             ambiguousSessionIDs: ambiguousSessionIDs)
    }
}

/// Decodes the bounded JSON payload returned by `claude agents --json`.
/// Unknown additive fields are ignored; invalid required identity or lifecycle data makes the
/// complete poll unavailable so callers cannot treat a partial result as an empty root.
public enum ClaudeInventoryDecoder {
    public static let invalidMessage = "Unavailable: Claude returned an invalid agents inventory."
    public static let incompleteMessage = "Unavailable: Claude returned an incomplete or duplicate agents inventory."
    public static let unknownInteractiveStateMessage = "Unavailable: Claude returned an unknown interactive session state."
    public static let unknownBackgroundStateMessage = "Unavailable: Claude returned an unknown background session state."
    public static let unsupportedKindMessage = "Unavailable: Claude returned an unsupported session kind."

    public static func decode(_ data: Data, sourceScope: String, observedAt: Double) -> ClaudeInventoryScan {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .unavailable(sourceScope: sourceScope, observedAt: observedAt, reason: invalidMessage)
        }
        return decode(rows: rows, sourceScope: sourceScope, observedAt: observedAt)
    }

    /// Validates inventory rows already parsed from JSON, with the same rules as `decode(_:)`.
    static func decode(rows: [[String: Any]], sourceScope: String, observedAt: Double) -> ClaudeInventoryScan {
        var seenKinds: [String: ClaudeInventoryKind] = [:]
        var sessions: [ClaudeInventorySession] = []
        for row in rows {
            guard let sessionID = canonicalSessionID(row["sessionId"]),
                  nonempty(row["cwd"] as? String) != nil,
                  let startedAt = timestamp(row["startedAt"]) else {
                return .unavailable(sourceScope: sourceScope, observedAt: observedAt, reason: incompleteMessage)
            }
            let name: String
            if let rawName = row["name"] {
                guard let validated = nonempty(rawName as? String) else {
                    return .unavailable(sourceScope: sourceScope, observedAt: observedAt, reason: incompleteMessage)
                }
                name = validated
            } else {
                name = ""
            }

            let kind: ClaudeInventoryKind
            switch row["kind"] as? String {
            case "interactive": kind = .interactive
            case "background": kind = .background
            default:
                return .unavailable(sourceScope: sourceScope, observedAt: observedAt, reason: unsupportedKindMessage)
            }
            if let previousKind = seenKinds[sessionID] {
                let ambiguous = previousKind == .interactive && kind == .interactive ? [sessionID] : []
                return .unavailable(sourceScope: sourceScope, observedAt: observedAt, reason: incompleteMessage,
                                    ambiguousSessionIDs: Set(ambiguous))
            }
            seenKinds[sessionID] = kind

            let lifecycle: ClaudeInventoryLifecycle
            switch kind {
            case .interactive:
                guard let status = row["status"] as? String,
                      ["busy", "waiting", "idle"].contains(status) else {
                    return .unavailable(sourceScope: sourceScope, observedAt: observedAt, reason: unknownInteractiveStateMessage)
                }
                lifecycle = .interactive(status: status)
            case .background:
                guard let state = row["state"] as? String,
                      ["working", "blocked", "done", "failed", "stopped"].contains(state) else {
                    return .unavailable(sourceScope: sourceScope, observedAt: observedAt, reason: unknownBackgroundStateMessage)
                }
                lifecycle = .background(state: state)
            }
            sessions.append(ClaudeInventorySession(sessionID: sessionID, name: name, kind: kind,
                                                   startedAt: startedAt, lifecycle: lifecycle))
        }
        return ClaudeInventoryScan(sourceScope: sourceScope, observedAt: observedAt, sessions: sessions)
    }

    private static func canonicalSessionID(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count == 36,
              let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 4 * 1024,
              !value.contains(where: { $0.isNewline || $0 == "\u{1b}" || $0 == "\u{7}" }) else { return nil }
        return value
    }

    private static func timestamp(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber {
            guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value) ?? ISO8601DateFormatter().date(from: value)?.timeIntervalSince1970
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number > 100_000_000_000 ? number / 1_000 : number
    }
}
