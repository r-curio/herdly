import Foundation

/// One subagent a running session started and has not yet finished, as its working row lists it
/// (#395, Paper H2 "E · Switcher"). Source-neutral: Claude fills it from its subagent hooks; a Codex
/// subagent can fill the same fields. Presentation data only: it never orders the queue, counts as
/// work, acknowledges anything, or targets navigation.
public struct SubagentActivity: Identifiable, Equatable, Sendable {
    /// The source's own subagent id (Claude's `agent_id`), unique within its session.
    public let id: String
    /// What the row calls it: the subagent's type or nickname, numbered "Explore 2" when two running
    /// subagents of one session would otherwise read the same.
    public let name: String
    /// A role shown beside the name, when the source names one apart from `name`. Nil for Claude.
    public let role: String?
    /// The task the subagent was given. Nil when the source does not report it; no Claude hook does.
    public let asked: String?
    /// When the subagent started; the row shows how long it has run.
    public let startedAt: Double
    /// The subagent's current tool call, shaped like the opened row's "now" line. Nil while it is
    /// between calls or its call is no longer fresh.
    public let latestAction: RunningRowDetails.Now?
    /// The subagent's latest activity (#419): its start, or its newest tool start or finish. Nil when
    /// the source gives none; it then adds nothing to its session's activity.
    public let lastActivityAt: Double?

    public init(id: String, name: String, role: String? = nil, asked: String? = nil, startedAt: Double,
                latestAction: RunningRowDetails.Now? = nil, lastActivityAt: Double? = nil) {
        self.id = id
        self.lastActivityAt = lastActivityAt
        self.name = name
        self.role = role
        self.asked = asked
        self.startedAt = startedAt
        self.latestAction = latestAction
    }

    /// Start order, oldest first: the earlier start, then the smaller id.
    static func startsBefore(_ lhs: (startedAt: Double, id: String), _ rhs: (startedAt: Double, id: String)) -> Bool {
        lhs.startedAt == rhs.startedAt ? lhs.id < rhs.id : lhs.startedAt < rhs.startedAt
    }

    /// The name a subagent of an unknown or empty type reads as.
    public static let unnamed = "Subagent"

    /// Display names for one session's running subagents, given oldest first as (id, base name):
    /// the first of each base name keeps it, later ones read "<name> 2", "<name> 3" in start order.
    /// An empty base name reads `unnamed`.
    public static func names(_ subagents: [(id: String, base: String?)]) -> [String: String] {
        var seen: [String: Int] = [:]
        var result: [String: String] = [:]
        for subagent in subagents {
            let trimmed = subagent.base?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let base = trimmed.isEmpty ? unnamed : trimmed
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            result[subagent.id] = count == 1 ? base : "\(base) \(count)"
        }
        return result
    }
}
