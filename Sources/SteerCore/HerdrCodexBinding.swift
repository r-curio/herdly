import Foundation

// ADR 0012: a Codex CLI session binds to a herdr pane from what the pane itself shows. The CLI in
// the pane writes the session's shortened identifier as the title, and herdr reads the pane's
// foreground process from the pane's own terminal; a shared Codex daemon can affect neither.
// Codex hook records, herdr's `agent_session` and herdr's Codex integration are not read. Every
// rule here is a pure function of the scan and Steer's own session list; SteerApp owns the socket,
// scheduling and the Ghostty inventory (ADR 0009).

public enum HerdrCodexBindingRules {
    /// The only foreground process name that counts as Codex. `argv` is never consulted: a script
    /// or editor whose arguments mention codex is not Codex.
    public static let processName = "codex"

    /// The title Codex renders for a session with `tui.terminal_title = ["session-id"]` (ADR 0005),
    /// or nil when `sessionID` is not a UUID.
    public static func title(forSession sessionID: String) -> String? {
        UUID(uuidString: sessionID).map(GhosttyMatch.title)
    }

    /// Decides whether `sessionID` is bound to exactly one pane of `scan`.
    ///
    /// - Parameters:
    ///   - liveSessions: every live tracked Codex session ID, including this one when it is live.
    ///     The session's shortened identifier must be unique among them.
    ///   - scan: one fresh scan, with `pane.process_info` for the panes carrying live titles.
    /// - Returns: `.bound` only when every ADR 0012 rule and ADR 0008 target check holds;
    ///   otherwise the first failing reason. The order of panes in the scan does not matter.
    public static func evaluate(sessionID: String, liveness: HerdrSessionLiveness, liveSessions: Set<String>,
                                scan: HerdrScan) -> HerdrBinding {
        if liveness == .ended { return .unavailable(.sessionEnded) }
        let snapshot = scan.snapshot
        guard HerdrBindingRules.allowedProtocols.contains(snapshot.protocolVersion) else {
            return .unavailable(.unsupportedProtocol(snapshot.protocolVersion))
        }
        guard let title = title(forSession: sessionID) else { return .unavailable(.titleNotInHerdr) }
        let sharing = Set(liveSessions.map { $0.lowercased() }).filter { self.title(forSession: $0) == title }.count
        guard sharing == 1 else { return .unavailable(.sessionPrefixNotUnique(sharing)) }

        guard let panes = uniquePanes(snapshot.panes) else { return .unavailable(.conflictingPaneObservations) }
        let titled = panes.values.filter { $0.terminalTitle == title }.map(\.paneID).sorted()
        guard let paneID = titled.first, let pane = panes[paneID] else { return .unavailable(.titleNotInHerdr) }
        guard titled.count == 1 else { return .unavailable(.duplicateTitles(titled)) }

        // herdr does not say whether `agent` came from screen detection or an integration report
        // (ADR 0012), so it can only veto.
        if let agent = pane.agent, agent != processName { return .unavailable(.detectedAgent(String(agent.prefix(64)))) }
        guard HerdrBindingInputs.panesInTab(pane.tabID, snapshot: snapshot) == 1 else { return .unavailable(.split) }
        switch scan.client {
        case .success: break
        case .failure(.wrongClientCount(let count)) where count > 1: return .unavailable(.multipleClients(count))
        case .failure(.nonGhosttyClient): return .unavailable(.nonGhosttyClient)
        case .failure: return .unavailable(.noClient)
        }

        switch scan.processInfo[paneID] {
        case nil:
            return .unavailable(.processInfoUnavailable(nil))
        case .failure(let reason)?:
            return .unavailable(.processInfoUnavailable(reason))
        case .success(let info)?:
            guard info.paneID == paneID else { return .unavailable(.processInfoUnavailable(.malformedReply)) }
            let count = HerdrForegroundProcess.count(named: processName, in: info.foregroundProcesses)
            guard count == 1 else { return .unavailable(.foregroundProcesses(.codex, count: count)) }
        }
        return .bound(HerdrPaneTarget(sessionID: sessionID, agent: .codex, paneID: paneID))
    }

    /// Panes keyed by ID; identical repeats collapse and differing repeats return `nil`.
    private static func uniquePanes(_ panes: [HerdrPane]) -> [String: HerdrPane]? {
        var unique: [String: HerdrPane] = [:]
        for pane in panes {
            if let existing = unique[pane.paneID], existing != pane { return nil }
            unique[pane.paneID] = pane
        }
        return unique
    }
}

/// What the Codex rules need from Steer besides the herdr scan: its live Codex sessions and the
/// terminal titles of the latest complete Ghostty inventory (nil when none is known).
public struct HerdrCodexTitles: Equatable, Sendable {
    public let liveSessions: Set<String>
    public let ghostty: Set<String>?

    public init(liveSessions: Set<String>, ghostty: Set<String>?) {
        self.liveSessions = Set(liveSessions.map { HerdrBindingInputs.normalizedSessionID($0, agent: .codex) })
        self.ghostty = ghostty
    }

    public static let none = HerdrCodexTitles(liveSessions: [], ghostty: nil)

    /// The titles of live sessions that no Ghostty terminal shows: the ones herdr may host, and the
    /// ones each scan asks `pane.process_info` about. Empty while no Ghostty inventory is known.
    public var outsideGhostty: Set<String> {
        guard let ghostty else { return [] }
        return Set(liveSessions.compactMap(HerdrCodexBindingRules.title(forSession:))).subtracting(ghostty)
    }
}
