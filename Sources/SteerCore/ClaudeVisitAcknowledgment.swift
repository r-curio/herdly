import Foundation

/// Evidence produced by a manual visit to a Claude terminal. The caller supplies a fresh
/// configured-root inventory and a Ghostty snapshot taken after the observed focus transition.
/// The transition lower bound is the previous snapshot time, so an outcome that arrives during
/// the observation interval remains queued rather than being cleared on uncertain ordering.
public enum ClaudeVisitAcknowledgment {
    public static func outcomes(
        _ outcomes: [AgentOutcome],
        liveSessionsByScope: [String: [String]],
        inventoryAvailable: [String: Bool],
        snapshot: GhosttySnapshot,
        snapshotTakenAt: Double,
        transitionAfter: Double
    ) -> Set<AgentTurnIdentity> {
        guard snapshotTakenAt.isFinite, transitionAfter.isFinite,
              transitionAfter <= snapshotTakenAt,
              !liveSessionsByScope.isEmpty,
              Set(liveSessionsByScope.keys) == Set(inventoryAvailable.keys),
              inventoryAvailable.values.allSatisfy({ $0 }) else { return [] }

        let live = liveSessionsByScope.values.flatMap { $0 }
        return Set(outcomes.compactMap { outcome in
            let identity = outcome.session
            guard identity.source == .claude, identity.surface == .cli,
                  outcome.arrivedAt.isFinite, outcome.arrivedAt < transitionAfter,
                  liveSessionsByScope[identity.sourceScope]?.filter({ $0 == identity.session }).count == 1,
                  live.filter({ $0 == identity.session }).count == 1,
                  let target = GhosttyMatch.target(claudeSessionID: identity.session, live: live, snapshot: snapshot),
                  GhosttyMatch.isInCurrentWindow(target, snapshot: snapshot),
                  snapshot.selected == target else { return nil }
            return outcome.identity
        })
    }
}
