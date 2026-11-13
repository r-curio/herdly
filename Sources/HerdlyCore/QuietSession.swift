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

/// A call the session started and has not finished, as the opened row's "now" line names it.
public struct OpenCall: Equatable, Sendable {
    public let name: String
    public let input: [String: String]
    /// When the call started; nil when the source did not record it.
    public let startedAt: Double?

    public init(name: String, input: [String: String], startedAt: Double?) {
        self.name = name
        self.input = input
        self.startedAt = startedAt
    }
}

extension AgentRunning {
    /// Whether the session is quiet at `now` (`QuietRule`).
    public func isQuiet(at now: Double) -> Bool {
        QuietRule.isQuiet(lastActivity: lastActivityAt, now: now)
    }

    /// The call the opened row's "now" names at `now`: the fresh call the source reports (`toolName`),
    /// or, once the session is quiet (#419, owner decision 2026-11-13), the session's newest unfinished
    /// call (`openCall`) however old, so the user sees what it stopped on. A finished call is never
    /// `openCall`. Decided at render time, so the line changes at the quiet moment itself.
    public func shownCall(at now: Double) -> OpenCall? {
        if let toolName {
            let started = openCall.flatMap { $0.name == toolName && $0.input == toolInput ? $0.startedAt : nil }
            return OpenCall(name: toolName, input: toolInput, startedAt: started)
        }
        return isQuiet(at: now) ? openCall : nil
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
        kind == .running && running?.isQuiet(at: now) == true
    }

    /// Whether the row's sprite steps at `now`: its session is working and not quiet.
    public func spriteSteps(at now: Double) -> Bool {
        running?.status == .working && !isQuiet(at: now)
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

    /// The line for `running` at `now`, or nil while it is not quiet. Only a shell command counts from
    /// its own start: the frame and the word "command" are a shell's, and another open call reads
    /// "since the last activity".
    public static func make(_ running: AgentRunning, now: Double) -> QuietLine? {
        guard let activity = running.lastActivityAt, QuietRule.isQuiet(lastActivity: activity, now: now) else { return nil }
        let shown = running.shownCall(at: now)
        let isCommand = shown.flatMap { ToolAction(name: $0.name, input: $0.input) }?.isCommand == true
        let command = isCommand ? shown?.startedAt.flatMap { $0.isFinite ? $0 : nil } : nil
        let since = command ?? activity
        let what = command == nil ? "since the last activity" : "since this command started"
        return QuietLine(text: "\(QueueRowPresentation.age(since: since, now: now)) \(what)",
                         spoken: "\(QueueRowPresentation.spokenDuration(since: since, now: now)) \(what)")
    }
}
