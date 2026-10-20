import Foundation

/// The bound Ghostty tab of a session on Ghostty's title route, as ADR 0016's visit and dwell rule
/// (`TerminalVisitTracker`) compares it against a scan's visible tab. Nil when the binding does not hold
/// on the fresh inventories, so nothing is acknowledged for that session in that scan.
public enum GhosttyVisitTargets {
    /// A Codex CLI session: the exact unique unsplit tab carrying its shortened identifier (ADR 0005),
    /// among live sessions.
    public static func codex(_ session: UUID, live: Set<UUID>, snapshot: GhosttySnapshot) -> GhosttyTarget? {
        GhosttyMatch.target(session: session, live: live, snapshot: snapshot)
    }

    /// A Claude CLI session: every configured root's inventory is complete and available, the session is
    /// live exactly once in its own root and across all roots, exactly one unsplit tab carries its full
    /// Claude title, and that tab is in Ghostty's front window (Claude tabs are reached only there).
    public static func claude(_ identity: AgentSessionIdentity, liveSessionsByScope: [String: [String]],
                              inventoryAvailable: [String: Bool], configuredScopes: Set<String>,
                              snapshot: GhosttySnapshot) -> GhosttyTarget? {
        guard identity.source == .claude, identity.surface == .cli,
              !liveSessionsByScope.isEmpty,
              Set(liveSessionsByScope.keys) == configuredScopes,
              Set(inventoryAvailable.keys) == configuredScopes,
              inventoryAvailable.values.allSatisfy({ $0 }) else { return nil }
        let live = liveSessionsByScope.values.flatMap { $0 }
        guard liveSessionsByScope[identity.sourceScope]?.filter({ $0 == identity.session }).count == 1,
              live.filter({ $0 == identity.session }).count == 1,
              let target = GhosttyMatch.target(claudeSessionID: identity.session, live: live, snapshot: snapshot),
              GhosttyMatch.isInCurrentWindow(target, snapshot: snapshot) else { return nil }
        return target
    }
}
