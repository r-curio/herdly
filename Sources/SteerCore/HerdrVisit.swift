import Foundation

// ADR 0016's acknowledgment rule (`TerminalVisitAcknowledgment`, `TerminalDwell`) for herdr panes. A
// pane is visible when herdr reports it focused with exactly one Ghostty-hosted client and that client's
// Ghostty tab is visible (ADR 0011's test). On a Ghostty without `tty`, ADR 0011's interim rule
// (issue #155) accepts Ghostty frontmost in place of the TTY join.

/// One scheduled herdr scan as the visit rule needs it. Only a scan with exactly one Ghostty-hosted
/// client produces an observation.
public struct HerdrFocusObservation: Equatable, Sendable {
    /// When the scan started, Unix seconds.
    public let takenAt: Double
    public let focusedPaneID: String?
    public let clientPID: Int32
    /// The client's TTY, normalized; nil when unusable.
    public let clientTTY: String?

    public init(takenAt: Double, focusedPaneID: String?, clientPID: Int32, clientTTY: String?) {
        self.takenAt = takenAt
        self.focusedPaneID = focusedPaneID
        self.clientPID = clientPID
        self.clientTTY = clientTTY
    }

    public static func from(_ outcome: HerdrScanOutcome?, takenAt: Double) -> HerdrFocusObservation? {
        guard takenAt.isFinite, let scan = outcome?.scan, let client = HerdrOpen.attachedClient(outcome) else { return nil }
        return HerdrFocusObservation(takenAt: takenAt, focusedPaneID: HerdrOpen.focusedPane(in: scan.snapshot),
                                     clientPID: client.pid, clientTTY: client.tty)
    }
}

/// A Ghostty check SteerApp must take for one herdr scan: the scan, its focused pane, and the scan
/// before it, for the visit interval.
public struct HerdrVisitCheck: Equatable, Sendable {
    public let current: HerdrFocusObservation
    public let pane: String
    public let previous: TerminalVisibilityScan<String>?
}

/// A check that returned and still counts, with what it read.
public struct HerdrVisitCheckResult: Sendable {
    public let check: HerdrVisitCheck
    public let support: GhosttyTTYSupport
    public let ghostty: GhosttySnapshot?
    public let ghosttyTakenAt: Double
}

/// The visit interval and dwell run over scheduled herdr scans (ADR 0016). Scans arrive from a detached
/// monitor and Ghostty checks return asynchronously, so each carries its scan time: after `reset(at:)` (an
/// Open ended), a scan or check taken at or before that time is ignored. The interval spanning an Open is
/// therefore never a visit, and a fallback acknowledges nothing (ADR 0015).
public struct HerdrVisitTracker: Equatable, Sendable {
    /// The latest scan's reading. A scan whose Ghostty check is in flight reads `.unchecked` until the
    /// check returns; nil after a reset.
    public private(set) var lastScan: TerminalVisibilityScan<String>?
    public private(set) var dwell = TerminalDwell<String>()
    /// The pane a Ghostty check is sampling, while one is in flight.
    public private(set) var checkingPaneID: String?
    private var resetAt = -Double.infinity

    public init() {}

    /// Records one scheduled scan started at `takenAt` (`current` is nil when it had no single
    /// Ghostty-hosted client) and returns the Ghostty check to take, if any. Ghostty is asked only while macOS reports
    /// it `frontmost`, the focused pane holds a live or queued session, and no check or Open is in flight;
    /// with another app in front the pane is not visible and nothing is asked.
    public mutating func scan(_ current: HerdrFocusObservation?, takenAt: Double, openInFlight: Bool,
                              holdsLiveBoundTarget: (String) -> Bool, frontmost: TerminalHost?) -> HerdrVisitCheck? {
        guard takenAt.isFinite, takenAt > resetAt else { return nil }
        let previous = lastScan
        // Until a Ghostty check says otherwise, only the focused pane is known.
        lastScan = TerminalVisibilityScan(takenAt: takenAt, reading: HerdrOpenAcknowledgment.reading(
            current, ghosttyShowsVisit: nil, ghosttyTakenAt: takenAt))
        guard checkingPaneID == nil, !openInFlight else {
            // A failed scan or another pane still restarts the run, so a check in flight from an earlier
            // scan cannot extend it past this one.
            dwell.skip(candidate: current?.focusedPaneID, pending: checkingPaneID, at: takenAt)
            return nil
        }
        guard let current, let pane = current.focusedPaneID, holdsLiveBoundTarget(pane) else {
            dwell.reset(at: takenAt)
            return nil
        }
        // ADR 0016, "Presentation and scanning": a host that macOS does not report frontmost has nothing
        // visible, so it is not asked.
        guard frontmost == .ghostty else {
            lastScan = TerminalVisibilityScan(takenAt: takenAt, reading: .nothing)
            dwell.observe(target: pane, visible: false, at: takenAt)
            return nil
        }
        checkingPaneID = pane
        return HerdrVisitCheck(current: current, pane: pane, previous: previous)
    }

    /// Records a returned check. Nil when its scan was taken at or before the latest reset: it then
    /// counts for nothing. An unreadable inventory (`ghostty` nil) is unknown.
    public mutating func finish(_ check: HerdrVisitCheck, support: GhosttyTTYSupport, ghostty: GhosttySnapshot?,
                                ghosttyTakenAt: Double) -> HerdrVisitCheckResult? {
        checkingPaneID = nil
        let takenAt = check.current.takenAt
        guard takenAt > resetAt else { return nil }
        let reading: TerminalVisibilityReading<String> = ghostty.map {
            HerdrOpenAcknowledgment.reading(check.current, ghosttyShowsVisit: HerdrOpenAcknowledgment.ghosttyShowsVisit(
                clientTTY: check.current.clientTTY, support: support, ghostty: $0), ghosttyTakenAt: ghosttyTakenAt)
        } ?? .unknown
        // A later scan has replaced this one already: leave its reading.
        if lastScan?.takenAt == takenAt { lastScan = TerminalVisibilityScan(takenAt: takenAt, reading: reading) }
        dwell.observe(target: check.pane, visible: reading == .visible(check.pane), at: takenAt)
        return HerdrVisitCheckResult(check: check, support: support, ghostty: ghostty, ghosttyTakenAt: ghosttyTakenAt)
    }

    /// Ends a check without a result (Ghostty switched off meanwhile): the run restarts at its scan.
    public mutating func cancel(_ check: HerdrVisitCheck) {
        checkingPaneID = nil
        dwell.reset(at: check.current.takenAt)
    }

    /// The completions of a session bound to the checked pane that a manual visit or the dwell
    /// acknowledges as of the returned check.
    public func acknowledged<ID>(_ completions: [TerminalCompletionCandidate<ID>],
                                 after result: HerdrVisitCheckResult) -> Set<ID> {
        let check = result.check
        return HerdrOpenAcknowledgment.manualVisit(completions, boundPaneID: check.pane, previous: check.previous,
                                                   current: check.current, support: result.support,
                                                   ghostty: result.ghostty, ghosttyTakenAt: result.ghosttyTakenAt)
            .union(dwell.acknowledged(completions, target: check.pane, at: check.current.takenAt))
    }

    /// Forgets every scan up to `at` (an Open ended): the next visit needs two scans taken after it.
    public mutating func reset(at: Double) {
        lastScan = nil
        dwell.reset(at: at)
        if at.isFinite { resetAt = max(resetAt, at) }
    }
}

public enum HerdrOpenAcknowledgment {
    /// After an Open: only when it reported Opened, the completions that arrived strictly before the
    /// pre-Open herdr scan started.
    public static func afterOpen<ID>(_ completions: [TerminalCompletionCandidate<ID>], result: HerdrOpenResult) -> Set<ID> {
        guard case .opened(let plan) = result else { return [] }
        return TerminalVisitAcknowledgment.afterOpen(completions, result: .opened, preOpenAt: plan.preOpenSnapshotAt)
    }

    /// A herdr scan's reading. `ghosttyShowsVisit` is the host half for the focused pane: the answer of a
    /// Ghostty inventory taken at `ghosttyTakenAt`, false without asking Ghostty when macOS reports it
    /// not frontmost, or nil when Ghostty was not checked for this scan. An inventory taken before the
    /// scan started says nothing about it.
    public static func reading(_ current: HerdrFocusObservation?, ghosttyShowsVisit: Bool?,
                               ghosttyTakenAt: Double) -> TerminalVisibilityReading<String> {
        guard let current else { return .unknown }
        guard let pane = current.focusedPaneID else { return .nothing }
        guard let ghosttyShowsVisit, ghosttyTakenAt.isFinite, current.takenAt <= ghosttyTakenAt else {
            return .unchecked(pane)
        }
        return ghosttyShowsVisit ? .visible(pane) : .nothing
    }

    /// A manual visit: `previous` proves the bound pane was not visible (another pane focused, or
    /// Ghostty not showing herdr's client) and `current`, with a Ghostty inventory taken at or after it,
    /// shows it visible. Only completions that arrived before `previous` started are acknowledged.
    public static func manualVisit<ID>(
        _ completions: [TerminalCompletionCandidate<ID>],
        boundPaneID: String,
        previous: TerminalVisibilityScan<String>?,
        current: HerdrFocusObservation?,
        support: GhosttyTTYSupport,
        ghostty: GhosttySnapshot?,
        ghosttyTakenAt: Double
    ) -> Set<ID> {
        guard let current else { return [] }
        let shows = ghostty.map { ghosttyShowsVisit(clientTTY: current.clientTTY, support: support, ghostty: $0) }
        let scan = TerminalVisibilityScan(takenAt: current.takenAt,
                                          reading: reading(current, ghosttyShowsVisit: shows, ghosttyTakenAt: ghosttyTakenAt))
        return TerminalVisitAcknowledgment.manualVisit(completions, target: boundPaneID, previous: previous, current: scan)
    }

    /// Whether a Ghostty inventory shows the herdr client's tab to the user: with `tty`, the
    /// TTY-matched tab selected with Ghostty frontmost; without it (interim, issue #155), Ghostty frontmost.
    public static func ghosttyShowsVisit(clientTTY: String?, support: GhosttyTTYSupport,
                                         ghostty: GhosttySnapshot) -> Bool {
        switch support {
        case .supported:
            guard let clientTTY,
                  case .matched(let target) = GhosttyTTYMatch.join(clientTTY: clientTTY, support: support,
                                                                   snapshot: ghostty) else { return false }
            return ghostty.selected == target
        case .unsupported:
            // `selected` is present only while Ghostty is frontmost (Ghostty.js).
            return ghostty.selected != nil
        }
    }
}
