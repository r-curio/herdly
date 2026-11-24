import Foundation

public enum ClaudeInventoryKind: String, Equatable, Sendable {
    case interactive
    case background
}

public enum ClaudeInventoryLifecycle: Equatable, Sendable {
    case interactive(status: String)
    /// `claude agents --json`'s background state: working, blocked, done, failed, or stopped.
    case background(state: String)
    /// A session registry `bg` entry's status, in the interactive vocabulary (`busy`, `waiting`,
    /// `idle`; `shell` reads `idle`), nil when Claude wrote none or one Herdly does not know. It says
    /// only that the job's process is live and what it last reported; it is never a turn result, so
    /// an idle job confirms no Stop and a busy one adds no Working row.
    case backgroundJob(status: String?)

    public var isActive: Bool {
        switch self {
        case let .interactive(status): return Self.isActiveStatus(status)
        case let .background(state): return state == "working" || state == "blocked"
        case let .backgroundJob(status): return Self.isActiveStatus(status)
        }
    }

    /// Whether Setup counts the session as needing a restart once it is old enough. A registry
    /// background job never does (#393): Setup's count is unchanged by listing jobs.
    public var needsRestart: Bool {
        switch self {
        case .interactive: return true
        case let .background(state): return state == "working" || state == "blocked"
        case .backgroundJob: return false
        }
    }

    /// The interactive vocabulary's active statuses, shared by interactive sessions and registry jobs.
    private static func isActiveStatus(_ status: String?) -> Bool {
        status == "busy" || status == "waiting"
    }

    public var isIdleInteractive: Bool {
        if case .interactive(status: "idle") = self { return true }
        return false
    }
}

/// The app a Claude session runs in, from the session registry's `entrypoint` (#471). Claude Desktop
/// starts Claude Code itself, with no terminal, and registers `claude-desktop`; every other value, and
/// a source without the field, is a terminal session.
public enum ClaudeSessionHost: Equatable, Hashable, Sendable {
    case terminal
    case claudeDesktop

    /// The registry's `entrypoint` value Claude Desktop writes.
    public static let claudeDesktopEntrypoint = "claude-desktop"

    public init(entrypoint: Any?) {
        self = entrypoint as? String == Self.claudeDesktopEntrypoint ? .claudeDesktop : .terminal
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
    /// The start time Claude registered for `pid` (`procStart`), nil when it recorded none or no
    /// process is identified. Binding rules compare it with a fresh read (ADR 0013).
    public let procStart: String?
    /// The session's working directory as Claude reported it. Presentation only (the row's
    /// "project @ branch"); never used for targeting or identity.
    public let directory: String?
    /// When Claude last changed the interactive status, in seconds, when the source reports it
    /// (the session registry's `statusUpdatedAt`). nil from `claude agents --json` or a missing or
    /// malformed value.
    public let statusUpdatedAt: Double?
    /// The app the session runs in. `.terminal` from `claude agents --json`, which does not say.
    public let host: ClaudeSessionHost

    public init(sessionID: String, name: String = "", kind: ClaudeInventoryKind, startedAt: Double,
                lifecycle: ClaudeInventoryLifecycle, pid: Int32? = nil, directory: String? = nil,
                statusUpdatedAt: Double? = nil, procStart: String? = nil, host: ClaudeSessionHost = .terminal) {
        self.sessionID = sessionID
        self.name = name
        self.kind = kind
        self.startedAt = startedAt
        self.lifecycle = lifecycle
        self.pid = pid
        self.procStart = procStart
        self.directory = directory
        self.statusUpdatedAt = statusUpdatedAt
        self.host = host
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
    /// a live background holder it could not list as one row (two holders, or an entry without a
    /// readable directory, start time, or name). Never includes a session that also has a row.
    public let backgroundSessionIDs: Set<String>
    /// The process holding each background session whose job a live interactive process parked and
    /// now displays: the registry links the background entry's `jobId` to that process's
    /// `parkedJobId`. `.ambiguous` when the link is not one-to-one. Empty when unavailable.
    public let parkedJobProcesses: [String: ClaudeSessionProcess]

    /// Every session a live Claude process holds in this scan: its rows, interactive or background,
    /// and background holders without a row. Empty when unavailable, where absence proves nothing.
    public var listedSessionIDs: Set<String> {
        available ? Set(sessions.map(\.sessionID)).union(backgroundSessionIDs) : []
    }

    /// Setup's count of active sessions that need a restart to load Herdly's hooks: those whose
    /// lifecycle needs one and, when `installedAt` is known, started before it without a delivered
    /// startup hook. Every one counts while the installation time is unknown.
    public func restartCount(installedAt: Double?, deliveredSessionIDs: Set<String>) -> Int {
        sessions.filter { session in
            guard session.lifecycle.needsRestart else { return false }
            guard let installedAt else { return true }
            return session.startedAt < installedAt && !deliveredSessionIDs.contains(session.sessionID)
        }.count
    }

    public func isBackgroundSession(_ sessionID: String) -> Bool {
        available && (backgroundSessionIDs.contains(sessionID)
            || sessions.contains { $0.sessionID == sessionID && $0.kind == .background })
    }

    public init(sourceScope: String, observedAt: Double, sessions: [ClaudeInventorySession] = [],
                available: Bool = true, failure: String? = nil,
                ambiguousSessionIDs: Set<String> = [], backgroundSessionIDs: Set<String> = [],
                parkedJobProcesses: [String: ClaudeSessionProcess] = [:]) {
        self.sourceScope = URL(fileURLWithPath: sourceScope).standardizedFileURL.path
        self.observedAt = observedAt
        self.sessions = sessions
        self.available = available
        self.failure = failure
        self.ambiguousSessionIDs = ambiguousSessionIDs
        self.backgroundSessionIDs = available ? backgroundSessionIDs.subtracting(sessions.map(\.sessionID)) : []
        self.parkedJobProcesses = available ? parkedJobProcesses : [:]
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
            guard let sessionID = canonicalSessionID(row["sessionId"]), let shared = SharedFields(row) else {
                return .unavailable(sourceScope: sourceScope, observedAt: observedAt, reason: incompleteMessage)
            }
            let (directory, startedAt, name) = (shared.directory, shared.startedAt, shared.name)

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
            // Optional and advisory: a missing or malformed value never makes the inventory unavailable.
            let statusUpdatedAt = kind == .interactive ? timestamp(row["statusUpdatedAt"]) : nil
            sessions.append(ClaudeInventorySession(sessionID: sessionID, name: name, kind: kind,
                                                   startedAt: startedAt, lifecycle: lifecycle, directory: directory,
                                                   statusUpdatedAt: statusUpdatedAt))
        }
        return ClaudeInventoryScan(sourceScope: sourceScope, observedAt: observedAt, sessions: sessions)
    }

    /// The fields every row needs besides its session ID: a nonempty `cwd`, a `startedAt` time, and
    /// an optional nonempty `name` ("" when absent). nil when any is missing or malformed.
    struct SharedFields {
        let directory: String
        let startedAt: Double
        let name: String

        init?(_ row: [String: Any]) {
            guard let directory = ClaudeInventoryDecoder.nonempty(row["cwd"] as? String),
                  let startedAt = ClaudeInventoryDecoder.timestamp(row["startedAt"]) else { return nil }
            var name = ""
            if let rawName = row["name"] {
                guard let validated = ClaudeInventoryDecoder.nonempty(rawName as? String) else { return nil }
                name = validated
            }
            (self.directory, self.startedAt, self.name) = (directory, startedAt, name)
        }
    }

    static func canonicalSessionID(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count == 36,
              let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 4 * 1024,
              !value.contains(where: { $0.isNewline || $0 == "\u{1b}" || $0 == "\u{7}" }) else { return nil }
        return value
    }

    static func timestamp(_ value: Any?) -> Double? {
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
