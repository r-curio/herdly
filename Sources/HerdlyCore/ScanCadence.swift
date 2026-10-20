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
