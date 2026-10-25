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
public struct RestartRecheckGate: Equatable, Sendable {
    public static let interval: Double = 5

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
