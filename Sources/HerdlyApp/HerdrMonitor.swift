import Foundation
import HerdlyCore

/// Polls herdr on the 2-second scan, and only while the gate in ADR 0009 holds: herdr's switch
/// allows contact (`TerminalHostSwitches.mayContact(.herdr)`) and either a live Claude Code session's newest Herdly hook event recorded
/// a `HERDR_PANE_ID` or a live or daemon-loaded Codex terminal session exists beside a known Ghostty inventory while herdr's
/// default socket is trusted (ADR 0012). Outside the gate Herdly does not contact herdr and the
/// last scan is dropped.
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

    private let scanner: @Sendable (HerdrScanRequest) -> HerdrScanOutcome
    private var nextScan: Double = 0
    private var inFlight = false
    /// Bumped whenever the gate closes, so a scan that finishes afterwards is discarded.
    private var generation = 0
    private(set) var isGateOpen = false

    init(scanner: @escaping @Sendable (HerdrScanRequest) -> HerdrScanOutcome) {
        self.scanner = scanner
    }

    convenience init(client: HerdrClient = HerdrClient()) {
        self.init(scanner: { client.scan($0) })
    }

    /// Called on every refresh with the monotonic `now` in seconds. Starts a scan reading `request`
    /// when the gate is open, none is in flight, and the interval has passed, and returns its task
    /// so callers and tests can await completion; otherwise nil.
    @discardableResult
    func tick(now: Double, herdrEnabled: Bool, herdrPaneIDs: Set<String>, codexGate: Bool = false,
              request: HerdrScanRequest = HerdrScanRequest()) -> Task<Void, Never>? {
        let gate = HerdrBindingInputs.allowsContact(herdrEnabled: herdrEnabled, paneIDs: herdrPaneIDs,
                                                    codexGate: codexGate)
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
            let outcome = await Task.detached(priority: .utility) { scanner(request) }.value
            self?.finish(outcome, startedAt: now, generation: generation)
        }
    }

    /// A fresh scan reading `request` off the main actor for an Open or relay about to act,
    /// independent of the schedule. Nil when the gate is closed, because then Herdly must not
    /// contact herdr.
    func revalidate(_ request: HerdrScanRequest = HerdrScanRequest()) async -> HerdrScanOutcome? {
        guard isGateOpen else { return nil }
        let scanner = scanner
        return await Task.detached(priority: .userInitiated) { scanner(request) }.value
    }

    private func finish(_ outcome: HerdrScanOutcome, startedAt: Double, generation: Int) {
        inFlight = false
        guard generation == self.generation else { return }
        latest = outcome
        latestStartedAt = startedAt
        onScan?(outcome)
    }
}
