import Foundation

/// A working session that has gone quiet (#419, Paper journey board "I", decision block "Quiet",
/// agreed 2026-11-13): no activity for `after`. Its row adds the amber word "quiet" after its place and
/// its sprite stands still; the opened row says how long. Presentation only: a quiet session stays
/// under Working, counts as working, keeps its queue order, fold, Remove rule and acknowledgment, and
/// becoming quiet sounds, spotlights and alerts nothing.
///
/// "Activity" is each source's own evidence of progress, never a scan or a status refresh
/// (`AgentRunning.activityAt`, `SubagentActivity.lastActivityAt`), so a session Herdly knows only
/// from a scan has no activity time and is never quiet.
public enum QuietRule {
    /// How long a working session goes without activity before it reads quiet.
    public static let after: Double = 10 * 60

    /// Whether a session whose latest activity was at `lastActivity` is quiet at `now`: true from
    /// exactly `after` on. No activity time, or a time that is not finite, is never quiet.
    public static func isQuiet(lastActivity: Double?, now: Double) -> Bool {
        guard let quietAt = quietAt(lastActivity: lastActivity), now.isFinite else { return false }
        return now >= quietAt
    }

    /// When a session with this latest activity becomes quiet, unless new activity comes first; nil
    /// without a usable activity time.
    public static func quietAt(lastActivity: Double?) -> Double? {
        guard let lastActivity, lastActivity.isFinite else { return nil }
        return lastActivity + after
    }
}

extension AgentRunning {
    /// The session's latest activity: its own (`activityAt`), or a listed subagent's, whichever is
    /// newer. Nil when Herdly has no activity time for either.
    public var lastActivityAt: Double? {
        ([activityAt] + subagents.map(\.lastActivityAt)).compactMap { $0 }.filter(\.isFinite).max()
    }
}

extension AgentAttentionItem {
    /// When this row becomes quiet: only a working row (`.running`) with an activity time can.
    public var quietAt: Double? {
        guard kind == .running, let running else { return nil }
        return QuietRule.quietAt(lastActivity: running.lastActivityAt)
    }

    /// Whether this row is a quiet working row at `now`.
    public func isQuiet(at now: Double) -> Bool {
        guard let quietAt, now.isFinite else { return false }
        return now >= quietAt
    }
}

extension Array where Element == AgentAttentionItem {
    /// The moments after `now` at which one of these rows becomes quiet, earliest first: when the
    /// notch must redraw without a new event. Rows already quiet, and rows that cannot become quiet,
    /// add none.
    public func quietChanges(after now: Double) -> [Double] {
        compactMap(\.quietAt).filter { $0 > now }.sorted()
    }
}

/// The opened quiet row's "quiet" line (#419, Paper "Q3 · Opened quiet row"): how long the session has
/// been quiet, in the rows' age format. While the "now" line shows a shell command whose start Herdly
/// recorded, it counts from that start ("14m since this command started"); otherwise from the latest
/// activity ("14m since the last activity"). Presentation only.
public struct QuietLine: Equatable, Sendable {
    public let text: String
    /// What VoiceOver reads after the "quiet" label, with the unit spelled out.
    public let spoken: String

    /// The line for `running` at `now`, or nil while it is not quiet.
    public static func make(_ running: AgentRunning, now: Double) -> QuietLine? {
        guard let activity = running.lastActivityAt, QuietRule.isQuiet(lastActivity: activity, now: now) else { return nil }
        let command = running.action?.isCommand == true ? running.toolStartedAt.flatMap { $0.isFinite ? $0 : nil } : nil
        let since = command ?? activity
        let what = command == nil ? "since the last activity" : "since this command started"
        return QuietLine(text: "\(QueueRowPresentation.age(since: since, now: now)) \(what)",
                         spoken: "\(spokenDuration(since: since, now: now)) \(what)")
    }

    /// "14 minutes", "2 hours", "1 day": the age format's units in words.
    static func spokenDuration(since start: Double, now: Double) -> String {
        let seconds = max(0, now - start)
        func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)\(count == 1 ? "" : "s")" }
        if seconds < 60 { return "less than a minute" }
        if seconds < 3_600 { return unit(Int(seconds / 60), "minute") }
        if seconds < 86_400 { return unit(Int(seconds / 3_600), "hour") }
        return unit(Int(seconds / 86_400), "day")
    }
}
