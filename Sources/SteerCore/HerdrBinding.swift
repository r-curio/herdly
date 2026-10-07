import Foundation

// ADR 0008: a Claude Code session in herdr binds to a pane only when Steer's own newest hook record
// for the session names that `HERDR_PANE_ID` and herdr's fresh snapshot shows exactly that one
// pane reporting the session as its `agent_session`. Codex CLI sessions bind by title and
// foreground process instead (ADR 0012, HerdrCodexBinding.swift), and their hook records are
// ignored here: under Codex's shared daemon they name another pane. Everything here is a pure function of the
// values passed in; SteerApp owns the socket, subprocesses, and scheduling (ADR 0009). The
// inputs are deliberately plain so they can be filled from the hook record and snapshot models.
// `HerdrAgentKind` comes from HerdrSnapshot.swift.

/// Steer's own record from a session's newest hook event. `paneID` is `HERDR_PANE_ID` and
/// `socketPath` is `HERDR_SOCKET_PATH`, each `nil` when the event did not carry it.
/// `recordedAt` is the event's arrival time on the same clock as `HerdrServerInstance.startedAt`.
public struct HerdrHookPaneRecord: Equatable, Hashable, Sendable {
    public let sessionID: String
    public let agent: HerdrAgentKind
    public let paneID: String?
    public let socketPath: String?
    public let recordedAt: Double

    public init(sessionID: String, agent: HerdrAgentKind, paneID: String?, socketPath: String?, recordedAt: Double) {
        self.sessionID = sessionID
        self.agent = agent
        self.paneID = paneID
        self.socketPath = socketPath
        self.recordedAt = recordedAt
    }
}

/// The running herdr server, identified by when it started. A server that started at or after a
/// hook record's arrival cannot be the server that record ran under.
public struct HerdrServerInstance: Equatable, Hashable, Sendable {
    public let startedAt: Double

    public init(startedAt: Double) { self.startedAt = startedAt }
}

/// Which herdr session the snapshot describes. Only the default session is targetable.
public enum HerdrSessionName: Equatable, Hashable, Sendable {
    case defaultSession
    case named(String)
}

/// One attached herdr TUI client, from `lsof` peers and the client's process ancestry.
public struct HerdrClientObservation: Equatable, Hashable, Sendable {
    public let processID: Int32
    public let ancestryReachesGhostty: Bool

    public init(processID: Int32, ancestryReachesGhostty: Bool) {
        self.processID = processID
        self.ancestryReachesGhostty = ancestryReachesGhostty
    }
}

/// One pane in a fresh herdr snapshot. `panesInTab` counts every pane in the pane's tab,
/// including panes hidden by a zoomed split.
public struct HerdrPaneObservation: Equatable, Hashable, Sendable {
    public let paneID: String
    public let agent: HerdrAgentKind?
    public let agentSession: String?
    public let panesInTab: Int
    public let terminalTitle: String?

    public init(paneID: String, agent: HerdrAgentKind?, agentSession: String?, panesInTab: Int, terminalTitle: String?) {
        self.paneID = paneID
        self.agent = agent
        self.agentSession = agentSession
        self.panesInTab = panesInTab
        self.terminalTitle = terminalTitle
    }
}

/// Everything read from herdr in one scan: the socket's protocol and snapshot, the server's start
/// identity, `lsof` client checks, integration status per agent, and `pane.process_info` per pane
/// the scan asked about. `protocolVersion` is `nil` when the reply did not report one.
public struct HerdrObservation: Equatable, Sendable {
    public let protocolVersion: Int?
    public let server: HerdrServerInstance
    public let session: HerdrSessionName
    public let clients: [HerdrClientObservation]
    public let integrations: [HerdrAgentKind: HerdrIntegrationState]
    public let panes: [HerdrPaneObservation]
    /// Absent for a pane the scan did not ask about.
    public let processInfo: [String: Result<HerdrProcessInfo, HerdrUnavailableReason>]

    public init(
        protocolVersion: Int?,
        server: HerdrServerInstance,
        session: HerdrSessionName,
        clients: [HerdrClientObservation],
        integrations: [HerdrAgentKind: HerdrIntegrationState],
        panes: [HerdrPaneObservation],
        processInfo: [String: Result<HerdrProcessInfo, HerdrUnavailableReason>]
    ) {
        self.protocolVersion = protocolVersion
        self.server = server
        self.session = session
        self.clients = clients
        self.integrations = integrations
        self.panes = panes
        self.processInfo = processInfo
    }
}

/// Whether the session is still running, as Steer's own records say.
public enum HerdrSessionLiveness: Equatable, Sendable {
    case live
    case ended
}

/// The one pane a session is bound to.
public struct HerdrPaneTarget: Equatable, Hashable, Sendable {
    public let sessionID: String
    public let agent: HerdrAgentKind
    public let paneID: String

    public init(sessionID: String, agent: HerdrAgentKind, paneID: String) {
        self.sessionID = sessionID
        self.agent = agent
        self.paneID = paneID
    }
}

/// Why a session has no usable pane binding. Every reason disables Open and question relay; none
/// clears attention, grants a decision, or falls back to another pane.
public enum HerdrBindingUnavailable: Equatable, Hashable, Sendable {
    /// The session ended.
    case sessionEnded
    /// Steer has no hook record for the session.
    case noHookRecord
    /// The session's newest hook event did not carry `HERDR_PANE_ID`.
    case notInHerdr
    /// Two hook records for the session share its newest arrival time but disagree.
    case conflictingHookRecords
    /// The herdr protocol is not on the allowlist (or was not reported).
    case unsupportedProtocol(Int?)
    /// The hook record did not carry `HERDR_SOCKET_PATH`, so the socket cannot be confirmed.
    case socketUnknown
    /// The session runs under a named herdr session or a non-default socket.
    case namedSession
    /// The herdr server started at or after the hook record; void until a new hook event.
    case herdrRestarted
    /// The pane's newest Steer hook event belongs to a different session.
    case paneReusedBySession(String)
    /// The snapshot lists the same pane more than once with different contents.
    case conflictingPaneObservations
    /// Two or more panes report the session as their `agent_session`.
    case duplicateMatches([String])
    /// The recorded pane is not in the snapshot.
    case paneMissing
    /// The recorded pane reports no `agent_session` (including before Codex's first turn).
    case agentSessionNull
    /// The recorded pane reports a different session or agent, or herdr reports the session in
    /// a pane other than the recorded one.
    case agentSessionMismatch
    /// The pane title is a shortened Codex session identifier naming a different session.
    case conflictingTitle
    /// The pane's tab holds more than one pane (split or zoomed split).
    case split
    /// herdr's integration for the session's agent is not `current`.
    case integrationNotCurrent(HerdrAgentKind, HerdrIntegrationState?)
    /// No herdr client is attached.
    case noClient
    /// More than one herdr client is attached.
    case multipleClients(Int)
    /// The one attached client's ancestry does not reach Ghostty.
    case nonGhosttyClient

    // ADR 0012 (Codex CLI sessions).
    /// No pane in the snapshot has the session's shortened identifier as its title.
    case titleNotInHerdr
    /// Several panes, listed by ID, have the session's title.
    case duplicateTitles([String])
    /// Not exactly one live tracked session renders this shortened identifier; `count` do.
    case sessionPrefixNotUnique(Int)
    /// The title is both a herdr pane's and a Ghostty terminal's, so the route is unknown.
    case titleInHerdrAndGhostty
    /// herdr detected another agent in the pane; its name, truncated.
    case detectedAgent(String)
    /// `pane.process_info` for the pane failed with this reason, or named another pane
    /// (`malformedReply`); nil when the scan did not ask about the pane.
    case processInfoUnavailable(HerdrUnavailableReason?)
    /// The pane's foreground processes include `count` named for the agent, not the number its
    /// rule requires.
    case foregroundProcesses(HerdrAgentKind, count: Int)
}

/// The result of ADR 0008's binding rules for one session.
public enum HerdrBinding: Equatable, Sendable {
    case bound(HerdrPaneTarget)
    case unavailable(HerdrBindingUnavailable)
}

public enum HerdrBindingRules {
    /// herdr protocols Steer has verified, starting with protocol 22 (herdr 0.9.3).
    public static let allowedProtocols: Set<Int> = [22]

    /// Decides whether `sessionID` is bound to exactly one herdr pane.
    ///
    /// - Parameters:
    ///   - hookRecords: Steer's hook records for every live herdr-capable session, newest event
    ///     per session or more, in any order. Records for other sessions are needed to detect a
    ///     pane whose newest event belongs to a different session. Codex records are ignored
    ///     (ADR 0012), so a Codex session never binds here.
    ///   - defaultSocketPath: herdr's default socket (`~/.config/herdr/herdr.sock`) as resolved by
    ///     the caller.
    /// - Returns: `.bound` only when every ADR 0008 rule holds, including a foreground process named
    ///   for the agent (`claude`) in the pane's `pane.process_info`; otherwise the first failing reason.
    ///   The result depends only on the inputs, not on their order.
    public static func evaluate(
        sessionID: String,
        liveness: HerdrSessionLiveness,
        hookRecords: [HerdrHookPaneRecord],
        observation: HerdrObservation,
        defaultSocketPath: String
    ) -> HerdrBinding {
        if liveness == .ended { return .unavailable(.sessionEnded) }

        let newestBySession: [String: NewestRecord] = newestRecords(hookRecords.filter { $0.agent != .codex })
        guard let newest = newestBySession[sessionID] else { return .unavailable(.noHookRecord) }
        guard case .unique(let record) = newest else { return .unavailable(.conflictingHookRecords) }
        guard let paneID = record.paneID else { return .unavailable(.notInHerdr) }

        guard let version = observation.protocolVersion, allowedProtocols.contains(version) else {
            return .unavailable(.unsupportedProtocol(observation.protocolVersion))
        }
        guard let socketPath = record.socketPath else { return .unavailable(.socketUnknown) }
        guard socketPath == defaultSocketPath, observation.session == .defaultSession else {
            return .unavailable(.namedSession)
        }
        // A server that started at or after the hook event may have restored a stale
        // `agent_session`; only a newer hook event from the pane can restore the binding.
        guard observation.server.startedAt < record.recordedAt else { return .unavailable(.herdrRestarted) }

        if let other = newerOccupant(of: paneID, than: record, among: newestBySession) {
            return .unavailable(.paneReusedBySession(other))
        }

        guard let panes = uniquePanes(observation.panes) else {
            return .unavailable(.conflictingPaneObservations)
        }
        let matches = panes.values.filter { $0.agentSession == sessionID }.map(\.paneID).sorted()
        if matches.count > 1 { return .unavailable(.duplicateMatches(matches)) }
        guard let pane = panes[paneID] else { return .unavailable(.paneMissing) }
        guard let reported = pane.agentSession else { return .unavailable(.agentSessionNull) }
        guard reported == sessionID, pane.agent == record.agent, matches == [paneID] else {
            return .unavailable(.agentSessionMismatch)
        }
        if titleConflicts(pane.terminalTitle, sessionID: sessionID) {
            return .unavailable(.conflictingTitle)
        }
        guard pane.panesInTab == 1 else { return .unavailable(.split) }

        let integration = observation.integrations[record.agent]
        guard case .current = integration else {
            return .unavailable(.integrationNotCurrent(record.agent, integration))
        }

        let clients = Set(observation.clients)
        switch clients.count {
        case 0: return .unavailable(.noClient)
        case 1: break
        default: return .unavailable(.multipleClients(clients.count))
        }
        guard clients.first?.ancestryReachesGhostty == true else { return .unavailable(.nonGhosttyClient) }

        // The agent must still be in the pane's foreground: `agent_session` can linger after it
        // exits. Checked on every scan, including Open's revalidation.
        switch observation.processInfo[paneID] {
        case nil:
            return .unavailable(.processInfoUnavailable(nil))
        case .failure(let reason)?:
            return .unavailable(.processInfoUnavailable(reason))
        case .success(let info)?:
            guard info.paneID == paneID else { return .unavailable(.processInfoUnavailable(.malformedReply)) }
            let count = HerdrForegroundProcess.count(named: record.agent.rawValue, in: info.foregroundProcesses)
            guard count >= 1 else { return .unavailable(.foregroundProcesses(record.agent, count: count)) }
        }

        return .bound(HerdrPaneTarget(sessionID: sessionID, agent: record.agent, paneID: paneID))
    }

    /// True when `title` is shaped like Steer's shortened Codex session-ID title
    /// (`GhosttyMatch.title`: 29 lowercase UUID characters and `...`) and names a different
    /// session. A missing or free-form title, including every Claude Code title, never vetoes.
    public static func titleConflicts(_ title: String?, sessionID: String) -> Bool {
        guard let title, isShortenedCodexSessionTitle(title) else { return false }
        return title != String(sessionID.lowercased().prefix(29)) + "..."
    }

    static func isShortenedCodexSessionTitle(_ title: String) -> Bool {
        let scalars = Array(title.unicodeScalars)
        guard scalars.count == 32, title.hasSuffix("...") else { return false }
        for (index, scalar) in scalars.prefix(29).enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard scalar == "-" else { return false }
            } else {
                guard ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar) else { return false }
            }
        }
        return true
    }

    private enum NewestRecord {
        case unique(HerdrHookPaneRecord)
        case conflicting(recordedAt: Double)

        var recordedAt: Double {
            switch self {
            case .unique(let record): return record.recordedAt
            case .conflicting(let recordedAt): return recordedAt
            }
        }
    }

    /// The newest record per session. Identical duplicates collapse; differing records at the
    /// same newest time are conflicting, so the result never depends on input order.
    private static func newestRecords(_ records: [HerdrHookPaneRecord]) -> [String: NewestRecord] {
        var newest: [String: NewestRecord] = [:]
        for record in records {
            guard let current = newest[record.sessionID] else {
                newest[record.sessionID] = .unique(record)
                continue
            }
            if record.recordedAt > current.recordedAt {
                newest[record.sessionID] = .unique(record)
            } else if record.recordedAt == current.recordedAt, case .unique(let existing) = current, existing != record {
                newest[record.sessionID] = .conflicting(recordedAt: record.recordedAt)
            }
        }
        return newest
    }

    /// Another session whose newest hook event names the same pane at or after this record. A tie
    /// is uncertain, so it also voids the binding.
    private static func newerOccupant(
        of paneID: String,
        than record: HerdrHookPaneRecord,
        among newest: [String: NewestRecord]
    ) -> String? {
        newest
            .filter { sessionID, entry in
                guard sessionID != record.sessionID, case .unique(let other) = entry else { return false }
                return other.paneID == paneID && other.recordedAt >= record.recordedAt
            }
            .keys
            .sorted()
            .first
    }

    /// Panes keyed by ID; identical repeats collapse and differing repeats return `nil`.
    private static func uniquePanes(_ panes: [HerdrPaneObservation]) -> [String: HerdrPaneObservation]? {
        var unique: [String: HerdrPaneObservation] = [:]
        for pane in panes {
            if let existing = unique[pane.paneID], existing != pane { return nil }
            unique[pane.paneID] = pane
        }
        return unique
    }
}
