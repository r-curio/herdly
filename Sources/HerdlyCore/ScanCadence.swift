/// How often the companion's background refresh runs (#301). The notch's own animations and
/// countdowns redraw through `TimelineView`, and every decision rechecks its deadline when chosen,
/// so the tick only needs to be fast while a card or the queue is showing, the pointer or keyboard
/// is on the notch, or an approval's deadline can pass. Otherwise once a second is enough.
public enum RefreshCadence {
    public static let active: Double = 0.2
    public static let idle: Double = 1

    public static func interval(presenting: Bool, interacting: Bool, actionableApproval: Bool) -> Double {
        presenting || interacting || actionableApproval ? active : idle
    }
}

/// How often the scheduled herdr scan runs while its gate holds (ADR 0009). Every two seconds while
/// its result can matter within seconds: a terminal app is frontmost (a pane can be visited, ADR 0016),
/// Herdly is in use (a row may be opened), or something waits for the user (a visit may acknowledge
/// it). Otherwise every ten: nobody is looking at a pane or a row. The rule is asked again each time
/// a hook scan completes (every two seconds while a session is live, `HookScanSchedule`), so once
/// any of the three turns true the next of those scans herdr if two seconds have passed since the
/// last. An Open or relay never waits for this: it revalidates with its own fresh read.
public enum HerdrScanCadence {
    public static let near: Double = 2
    public static let away: Double = 10

    public static func interval(terminalFrontmost: Bool, herdlyInUse: Bool, needsUser: Bool) -> Double {
        terminalFrontmost || herdlyInUse || needsUser ? near : away
    }

    /// Whether a scan is due at the monotonic `now`: none has started since the gate opened, or the
    /// last one started `interval` ago.
    public static func isDue(lastStartedAt: Double?, now: Double, interval: Double) -> Bool {
        guard let lastStartedAt else { return true }
        return now - lastStartedAt >= interval
    }
}

/// Which hosts one shared scheduled tab read serves (#301). Every scheduled read already reads
/// every enabled host, so when any eligible host is due, all eligible hosts take the same read and
/// move to one clock. A host that is scanning, gated off, or has nothing to bind is not eligible.
public enum SharedTabScan {
    public static let interval: Double = 2

    /// `eligible` maps each eligible host to its next scan time; empty when none is due at `now`.
    public static func hostsToRead<Host: Hashable>(eligible: [Host: Double], now: Double) -> Set<Host> {
        eligible.values.contains { now >= $0 } ? Set(eligible.keys) : []
    }
}

/// Whether a scheduled scan may reuse a reading another scheduled scan took (#306): its read began no
/// earlier than this scan read the frontmost app (`notBefore`, ADR 0016), and less than `maxAge` ago.
public enum SharedReading {
    public static func reusable(takenAt: Double, notBefore: Double, now: Double, maxAge: Double) -> Bool {
        takenAt.isFinite && takenAt >= notBefore && now - takenAt < maxAge
    }
}

/// When the scan may re-check Claude roots waiting for a new session (#364). Each check decodes every
/// listed hook record, so one starts at most every `interval` after the last finished, never two at once.
/// Times are monotonic seconds (system uptime), so a wall-clock change cannot stall it.
public struct RestartRecheckGate: Sendable {
    private static let interval: Double = 5

    private enum State: Equatable, Sendable {
        case idle(due: Double)
        case running
    }

    private var state = State.idle(due: -.infinity)

    public init() {}

    /// Starts a check and returns true when a root is waiting, none is running, and one is due.
    public mutating func start(now: Double, anyWaiting: Bool) -> Bool {
        guard anyWaiting, case .idle(let due) = state, now >= due else { return false }
        state = .running
        return true
    }

    public mutating func finish(now: Double) {
        state = .idle(due: now + Self.interval)
    }
}

/// What can change the hook scan's result without a record arriving in a watched hook directory
/// (#306). The scan also reads Codex rollouts, the process table, Claude's session registry and usage
/// files, thread names, the desktop read state and git branches, and applies rules that depend on the
/// time; none of those is watched. While any of these holds, the scan keeps its fixed cadence.
public struct HookScanNeeds: Equatable, Sendable {
    /// No scan has been applied since launch: nothing below is known yet.
    public var nothingAppliedYet = false
    /// A row is queued or a result is held: a scan can end, acknowledge, rename or re-date it.
    public var rowsHeld = false
    /// A Codex or Claude session, subagent or daemon thread is live: its process can exit and its
    /// rollout or registry entry can change without a hook record.
    public var sessionsLive = false
    /// A Codex CLI process or the Codex desktop app was running at the last scan, or the process table
    /// could not be read: a rollout alone can then show a working session (docs/session-discovery.md).
    public var codexMayRun = false
    /// The last scan could not read a source, or a Claude root is read without a watched hook
    /// directory (not connected, or waiting for a restart): its sessions are only seen by reading.
    public var sourceUnwatchedOrUnreadable = false
    /// The scan holds state that ends at a time within the safety interval (`claudeUsageResetDue`).
    public var timedStateDue = false
    /// The notch is open or Herdly is the active app: what the scan reads is on screen.
    public var herdlyInUse = false

    public init() {}

    public var fastCadence: Bool {
        nothingAppliedYet || rowsHeld || sessionsLive || codexMayRun || sourceUnwatchedOrUnreadable
            || timedStateDue || herdlyInUse
    }

    /// Whether any held Claude usage window resets by `wallNow` (Unix time) plus one safety interval,
    /// or has already: the scan stops showing a window at its reset, so a safety scan could be late for
    /// it. A reset or clock that is not a number counts as due. Codex's usage needs no such rule: the
    /// app applies `CodexUsageReading.current(now:)` each time it shows the ring, not in the scan.
    public static func claudeUsageResetDue(_ readings: [ClaudeUsageReading], wallNow: Double) -> Bool {
        readings.contains { reading in
            [reading.fiveHour, reading.sevenDay].contains { window in
                window.map { !($0.resetsAt > wallNow + HookScanSchedule.safetyInterval) } ?? false
            }
        }
    }
}

/// When the hook scan runs (#306). A change in a watched hook directory, app activation, or an
/// explicit request makes a scan due; scans stay at least `interval` apart, so a burst of records
/// costs one scan per interval, as the fixed clock did. With no such evidence a scan still runs every
/// `interval` while the watch cannot be trusted or `HookScanNeeds.fastCadence` holds, and every
/// `safetyInterval` otherwise. Times are monotonic seconds (system uptime).
///
/// Evidence stays pending until a scan starts. One that arrives while a scan runs, or after that scan
/// listed its directories, is noted after the start and makes the next scan due.
public struct HookScanSchedule: Sendable {
    /// Minimum spacing, and the cadence whenever anything is uncertain: the scan's former fixed clock,
    /// which the hook helper's connection timeout is sized against (`ApprovalTiming`).
    public static let interval: Double = ApprovalTiming.scanInterval
    /// The cadence when nothing is held, live, uncertain or changed. It bounds how long a wrong
    /// "nothing can have changed" lasts, including a hook record whose file-system event never came:
    /// a safety scan, the slowest refresh tick and a second of scan time still fit inside the helper's
    /// connection timeout, so such a request is receipted rather than handed back.
    public static let safetyInterval: Double = ApprovalTiming.connectionTimeout - RefreshCadence.idle - 1

    private var lastStartedAt: Double?
    private var changePending = false

    public init() {}

    /// A watched directory changed, its watch lost events, or an app was activated.
    public mutating func noteChange() {
        changePending = true
    }

    /// The next ask is due whatever the spacing: a setting changed, or a row needs its status now.
    public mutating func requestNow() {
        lastStartedAt = nil
    }

    public func isDue(now: Double, watchTrusted: Bool, needs: HookScanNeeds) -> Bool {
        guard let lastStartedAt else { return true }
        // A clock that is not a number or ran backwards proves nothing about the spacing: scan.
        guard now.isFinite, now >= lastStartedAt else { return true }
        guard now >= lastStartedAt + Self.interval else { return false }
        if changePending || !watchTrusted || needs.fastCadence { return true }
        return now >= lastStartedAt + Self.safetyInterval
    }

    /// Starts a scan when one is due and returns true; the pending evidence is then that scan's.
    public mutating func start(now: Double, watchTrusted: Bool, needs: HookScanNeeds) -> Bool {
        guard isDue(now: now, watchTrusted: watchTrusted, needs: needs) else { return false }
        lastStartedAt = now.isFinite ? now : nil
        changePending = false
        return true
    }
}
