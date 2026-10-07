import Foundation
import SteerCore

/// Polls herdr on the 2-second scan, and only while the gate in ADR 0009 holds: Ghostty controls
/// are on in this launch and at least one live session's newest Steer hook event recorded a
/// `HERDR_PANE_ID`. Outside the gate Steer does not contact herdr and the last scan is dropped.
///
/// Scans run off the main actor; at most one is in flight, and a failed scan simply waits for the
/// next interval. The monitor holds only the latest outcome: binding sessions to panes, presenting
/// reasons, and Open or relay are later work, which must call `revalidate()` for a fresh read
/// immediately before any focus or key rather than trusting `latest`.
@MainActor
final class HerdrMonitor {
    static let scanInterval: Double = 2

    /// The most recent scan's outcome while the gate holds; nil before the first scan and whenever
    /// the gate is closed.
    private(set) var latest: HerdrScanOutcome?
    /// The `now` the latest scan started at.
    private(set) var latestStartedAt: Double?
    /// Called on the main actor after each scheduled scan completes inside the gate.
    var onScan: ((HerdrScanOutcome) -> Void)?

    private let scanner: @Sendable () -> HerdrScanOutcome
    private var nextScan: Double = 0
    private var inFlight = false
    /// Bumped whenever the gate closes, so a scan that finishes afterwards is discarded.
    private var generation = 0
    private(set) var isGateOpen = false

    init(scanner: @escaping @Sendable () -> HerdrScanOutcome) {
        self.scanner = scanner
    }

    convenience init(client: HerdrClient = HerdrClient()) {
        self.init(scanner: { client.scan() })
    }

    /// Called on every refresh with the monotonic `now` in seconds. Starts a scan when the gate is
    /// open, none is in flight, and the interval has passed, and returns its task so callers and
    /// tests can await completion; otherwise nil.
    @discardableResult
    func tick(now: Double, ghosttyControlsEnabled: Bool, herdrPaneIDs: Set<String>) -> Task<Void, Never>? {
        let gate = ghosttyControlsEnabled && !herdrPaneIDs.isEmpty
        guard gate else {
            if isGateOpen || latest != nil {
                generation += 1
                latest = nil
                latestStartedAt = nil
                nextScan = 0
            }
            isGateOpen = false
            return nil
        }
        isGateOpen = true
        guard !inFlight, now >= nextScan else { return nil }
        inFlight = true
        nextScan = now + Self.scanInterval
        let generation = generation, scanner = scanner
        return Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { scanner() }.value
            self?.finish(outcome, startedAt: now, generation: generation)
        }
    }

    /// A fresh scan off the main actor for an Open or relay about to act, independent of the
    /// schedule. Nil when the gate is closed, because then Steer must not contact herdr.
    func revalidate() async -> HerdrScanOutcome? {
        guard isGateOpen else { return nil }
        let scanner = scanner
        return await Task.detached(priority: .userInitiated) { scanner() }.value
    }

    private func finish(_ outcome: HerdrScanOutcome, startedAt: Double, generation: Int) {
        inFlight = false
        guard generation == self.generation else { return }
        latest = outcome
        latestStartedAt = startedAt
        onScan?(outcome)
    }
}
