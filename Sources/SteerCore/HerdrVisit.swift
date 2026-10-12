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
