import Foundation

// ADR 0016: one acknowledgment rule for every terminal host and multiplexer, Ghostty included, for
// Codex and Claude alike. A verified Open, a manual visit (ADR 0009's interval rule) or a five-second
// dwell acknowledges a completion; nothing else here does. Approval requests, question requests and
// reminders clear only on resolution evidence and are never passed in. Everything is a pure function of
// scans SteerApp takes and dates on one clock (Unix seconds); reading a host, asking macOS which app is
// frontmost and scheduling the checks belong to SteerApp.

/// A queued completion of one session: its queue identity and arrival time (Unix seconds).
public struct TerminalCompletionCandidate<ID: Hashable & Sendable>: Equatable, Sendable {
    public let id: ID
    public let arrivedAt: Double

    public init(id: ID, arrivedAt: Double) {
        self.id = id
        self.arrivedAt = arrivedAt
    }
}

extension TerminalCompletionCandidate where ID == CompletionIdentity {
    /// A queued Codex completion, identified as the Codex queue acknowledges it.
    public init(_ completion: AttentionCompletion) {
        self.init(id: completion.id, arrivedAt: completion.arrivedAt)
    }
}

extension TerminalCompletionCandidate where ID == AgentTurnIdentity {
    /// A queued agent outcome, identified as the agent queue dismisses it.
    public init(_ outcome: AgentOutcome) {
        self.init(id: outcome.id, arrivedAt: outcome.arrivedAt)
    }
}

/// What one scan of a host says about its bound targets (ADR 0016, "Visible").
public enum TerminalVisibilityReading<Target: Equatable & Sendable>: Equatable, Sendable {
    /// A fresh read shows this target visible: its host frontmost per macOS, the host's own front tab
    /// or pane is the target, and the binding still holds.
    case visible(Target)
    /// A fresh read shows none of the host's targets visible: another app is frontmost (the host is
    /// not asked), or the host's front tab or pane is not the target.
    case nothing
    /// Only this target could have been visible, but its host was not checked, because a check or an
    /// Open was already in flight or nothing bound to it needed one. Every other target was not visible.
    case unchecked(Target)
    /// The scan failed or was not taken: nothing is known.
    case unknown

    /// Whether this reading proves `target` was not visible.
    public func excludes(_ target: Target) -> Bool {
        switch self {
        case .visible(let shown), .unchecked(let shown): shown != target
        case .nothing: true
        case .unknown: false
        }
    }
}

/// One scan's reading, dated when the scan started.
public struct TerminalVisibilityScan<Target: Equatable & Sendable>: Equatable, Sendable {
    public let takenAt: Double
    public let reading: TerminalVisibilityReading<Target>

    public init(takenAt: Double, reading: TerminalVisibilityReading<Target>) {
        self.takenAt = takenAt
        self.reading = reading
    }
}

public enum TerminalVisitAcknowledgment {
    /// After an Open: only a verified Open (never a fallback or an unavailable Open) acknowledges, and
    /// only the completions that arrived strictly before the pre-Open read started at `preOpenAt`.
    public static func afterOpen<ID>(_ completions: [TerminalCompletionCandidate<ID>], result: TerminalOpenResult,
                                     preOpenAt: Double) -> Set<ID> {
        guard result.acknowledges, preOpenAt.isFinite else { return [] }
        return Set(completions.filter { $0.arrivedAt.isFinite && $0.arrivedAt < preOpenAt }.map(\.id))
    }

    /// A manual visit (ADR 0009's interval rule as ADR 0016 states it): `previous` proves `target` was
    /// not visible and `current`, the next scan, shows it visible. Only completions that arrived before
    /// `previous` started are acknowledged, so one arriving during the interval stays queued.
    public static func manualVisit<ID, Target>(_ completions: [TerminalCompletionCandidate<ID>], target: Target,
                                               previous: TerminalVisibilityScan<Target>?,
                                               current: TerminalVisibilityScan<Target>) -> Set<ID> {
        guard let previous, previous.takenAt.isFinite, current.takenAt.isFinite, previous.takenAt < current.takenAt,
              previous.reading.excludes(target), current.reading == .visible(target) else { return [] }
        return Set(completions.filter { $0.arrivedAt.isFinite && $0.arrivedAt < previous.takenAt }.map(\.id))
    }
}

/// The per-host visible tests (ADR 0016, "Visible"). Frontmost always comes from macOS, passed in as the terminal app it reports (nil for any
/// other app), never from the host: hosts keep reporting a current tab while another app is in front.
public enum TerminalVisibility {
    /// Ghostty's test (ADR 0011): macOS reports Ghostty frontmost, and the inventory's selected tab, in
    /// its front window, is the one returned. Whether that tab is a session's bound target is the
    /// caller's comparison. Ghostty reports `selected` only while it is frontmost itself (Ghostty.js);
    /// both must agree. An inventory that could not be read is unknown.
    public static func ghostty(_ snapshot: GhosttySnapshot?,
                               frontmost: TerminalHost?) -> TerminalVisibilityReading<GhosttyTarget> {
        guard let snapshot, snapshot.status == "ok" else { return .unknown }
        guard frontmost == .ghostty, let selected = snapshot.selected,
              GhosttyMatch.isInCurrentWindow(selected, snapshot: snapshot) else { return .nothing }
        return .visible(selected)
    }
}

/// The interval visit and dwell state for one host's scans, in the order they were taken. SteerApp
/// records each scan's reading, then asks per session with that session's bound target in the latest
/// scan. An Open resets it: the interval spanning an Open is never a visit, so a fallback that happened
/// to raise the target's tab acknowledges nothing (ADR 0015), and a scan taken while it was in flight
/// cannot extend a dwell run.
public struct TerminalVisitTracker<Target: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var previous: TerminalVisibilityScan<Target>?
    public private(set) var latest: TerminalVisibilityScan<Target>?
    public private(set) var dwell = TerminalDwell<Target>()
    private var resetAt = -Double.infinity

    public init() {}

    /// Records the next scan. A scan taken at or before the latest reset, or before the latest scan,
    /// is ignored.
    public mutating func record(_ scan: TerminalVisibilityScan<Target>) {
        guard scan.takenAt.isFinite, scan.takenAt > resetAt,
              latest.map({ $0.takenAt < scan.takenAt }) ?? true else { return }
        previous = latest
        latest = scan
        switch scan.reading {
        case .visible(let target): dwell.observe(target: target, visible: true, at: scan.takenAt)
        case .unchecked(let candidate): dwell.skip(candidate: candidate, pending: nil, at: scan.takenAt)
        case .nothing, .unknown: dwell.reset(at: scan.takenAt)
        }
    }

    /// Forgets every scan up to `at` (an Open, or the host switched off or unreadable).
    public mutating func reset(at: Double) {
        previous = nil
        latest = nil
        dwell.reset(at: at)
        if at.isFinite { resetAt = max(resetAt, at) }
    }

    /// The completions a visit or the dwell acknowledges as of the latest scan, for a session whose
    /// bound target in that scan is `target` (nil when it has none).
    public func acknowledged<ID>(_ completions: [TerminalCompletionCandidate<ID>], target: Target?) -> Set<ID> {
        guard let target, let latest else { return [] }
        return TerminalVisitAcknowledgment.manualVisit(completions, target: target, previous: previous, current: latest)
            .union(dwell.acknowledged(completions, target: target, at: latest.takenAt))
    }
}

/// The dwell rule (ADR 0011, widened to every host by ADR 0016): a completion that arrives while its
/// target is visible is acknowledged once the target has stayed visible for `required` seconds after it
/// arrived. Visibility is sampled per scan, so a switch away and back between two scans goes unseen; a
/// hidden or different target, a failed scan, a scan taken while a check or Open is in flight, or a gap
/// longer than `maxGap` between visible scans restarts the run. The run can begin before the
/// completion; a completion that arrived before the run began is left to the visit rule and dismissal.
/// Steer cannot tell whether the user is looking at the screen; the user accepted that an unattended
/// target acknowledges.
public struct TerminalDwell<Target: Equatable & Sendable>: Equatable, Sendable {
    public static var required: Double { 5 }
    public static var maxGap: Double { 5 }

    /// The target visible on every scan since `since`, or nil when no run is in progress.
    public private(set) var target: Target?
    public private(set) var since: Double = 0
    private var lastSeenAt: Double = 0
    /// The scan time of the latest reset. An observation taken at or before it predates the scan that
    /// ended the run, such as a check still in flight then, and is ignored. A clock set back past it
    /// only withholds acknowledgment until the clock passes it again.
    private var resetAt = -Double.infinity

    public init() {}

    /// Records the check of the scan taken at `at`. `visible` is false when the target was the
    /// candidate but its host did not show it.
    public mutating func observe(target: Target, visible: Bool, at: Double) {
        guard at.isFinite else { reset(at: at); return }
        guard at > resetAt else { return }
        guard visible else { reset(at: at); return }
        if self.target != target || at < lastSeenAt || at - lastSeenAt > Self.maxGap { since = at }
        self.target = target
        lastSeenAt = at
    }

    /// Records a scan taken at `at` that had no check because a check or an Open was in flight.
    /// `pending` is the target an in-flight check is sampling, if any. The scan cannot extend the run,
    /// so it keeps the run and the pending check only while its candidate is that target (or, with no
    /// check in flight, the run's target). A failed scan (nil candidate) or another target restarts the
    /// run, and the pending check, taken before this scan, is then ignored.
    public mutating func skip(candidate: Target?, pending: Target?, at: Double) {
        if candidate == nil || candidate != (pending ?? target) { reset(at: at) }
    }

    /// Ends the run as of the scan taken at `at`. A non-finite time ends it without ignoring anything.
    public mutating func reset(at: Double) {
        target = nil
        since = 0
        lastSeenAt = 0
        if at.isFinite { resetAt = max(resetAt, at) }
    }

    /// Completions for `target` that arrived during the current run, at or after its start, and have
    /// been visible for `required` seconds since arriving by `now`, the latest observed scan.
    public func acknowledged<ID>(_ completions: [TerminalCompletionCandidate<ID>], target: Target,
                                 at now: Double) -> Set<ID> {
        guard self.target == target, now.isFinite, now == lastSeenAt else { return [] }
        return Set(completions.filter {
            $0.arrivedAt.isFinite && $0.arrivedAt >= since && $0.arrivedAt + Self.required <= now
        }.map(\.id))
    }
}
