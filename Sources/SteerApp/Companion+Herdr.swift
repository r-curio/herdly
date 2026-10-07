import Foundation
import SteerCore

/// Companion's herdr state (ADR 0008, ADR 0009): one `HerdrMonitor`, the hook records it was last
/// gated on, and the latest scan outcome. Companion holds one instance (`herdr`); everything that
/// needs a binding goes through the `Companion` API below rather than this object.
@MainActor
final class HerdrSessionBindings: ObservableObject {
    /// The latest herdr scan for settings; nil before the first scan and whenever the ADR 0009 gate
    /// is closed (Ghostty controls off, or no live session's newest hook event recorded a pane).
    @Published fileprivate(set) var scanOutcome: HerdrScanOutcome?
    /// True while the gate is open, so settings can tell "not in use" from "waiting for a scan".
    @Published fileprivate(set) var inUse = false

    let monitor: HerdrMonitor
    /// The same client the monitor scans with, for the one-shot focus of an Open (#125).
    let client: HerdrClient
    let defaultSocketPath: String
    /// Open's typed failures and manual-visit tracking (Companion+Navigation.swift).
    let open = HerdrOpenState()
    /// Each session's newest hook records from the last read.
    fileprivate var hookRecords: [HerdrHookPaneRecord] = []
    fileprivate var recordCache: [String: HerdrHookPaneRecord?] = [:]
    fileprivate var reading = false

    init(client: HerdrClient = HerdrClient()) {
        monitor = HerdrMonitor(client: client)
        self.client = client
        defaultSocketPath = client.configuration.socketPath
    }
}

extension Companion {
    // MARK: - Boundary for Open (#125), question relay (#126) and presentation (#127)

    /// The herdr binding of a live CLI session, from the latest scan. `notInHerdr` means herdr has
    /// nothing to say and the Ghostty tab rules apply; `unavailable` means the session runs in
    /// herdr but Steer cannot target its pane, so Open and relay stay disabled. A `bound` result
    /// is not enough to act on: call `revalidateHerdrBinding(for:)` immediately before any focus
    /// or key. Reading this never contacts herdr.
    func herdrBinding(for session: HerdrSessionKey) -> HerdrSessionBinding {
        HerdrBindingInputs.binding(for: session, liveness: herdrLiveness(of: session), hookRecords: herdr.hookRecords,
                                   ghosttyControlsEnabled: ghosttyEnabled, outcome: herdr.scanOutcome,
                                   defaultSocketPath: herdr.defaultSocketPath)
    }

    /// A fresh herdr scan, off the main actor, and the session's binding against it, for an Open or
    /// relay about to act (ADR 0009 freshness). `outcome` is nil, and no request is made, when the
    /// gate is closed; a session in herdr is then `unavailable(.notScanned)` or
    /// `.ghosttyControlsOff`. The hook records are those of the last scheduled read (at most one
    /// scan interval old). The fresh outcome does not replace the published one.
    func revalidateHerdrBinding(for session: HerdrSessionKey) async -> (binding: HerdrSessionBinding,
                                                                       outcome: HerdrScanOutcome?) {
        let outcome = await herdr.monitor.revalidate()
        let binding = HerdrBindingInputs.binding(for: session, liveness: herdrLiveness(of: session),
                                                 hookRecords: herdr.hookRecords,
                                                 ghosttyControlsEnabled: ghosttyEnabled,
                                                 outcome: outcome, defaultSocketPath: herdr.defaultSocketPath)
        return (binding, outcome)
    }

    /// The latest herdr scan outcome for settings (also published by `herdr.scanOutcome`).
    var herdrScanOutcome: HerdrScanOutcome? { herdr.scanOutcome }

    /// Agents with a live session whose newest hook event reported a herdr pane, for the settings
    /// row's integration problems (#127). Reading this never contacts herdr.
    var herdrAgentsSeen: Set<HerdrAgentKind> {
        let live = herdrLiveSessions()
        return Set(HerdrBindingInputs.newestRecords(herdr.hookRecords).filter {
            $0.paneID != nil && live.contains(HerdrSessionKey(agent: $0.agent, sessionID: $0.sessionID))
        }.map(\.agent))
    }

    // MARK: - Scan

    /// Called once per completed hook scan. Reads the newest hook records off the main actor, then
    /// ticks the monitor with Ghostty controls and the pane IDs of live sessions' newest events.
    /// The monitor contacts herdr only when both gate inputs hold.
    func scanHerdr() {
        guard previewMode == nil, !CommandLine.arguments.contains("--smoke-test"), !herdr.reading else { return }
        let live = herdrLiveSessions()
        let directories = herdrEventDirectories()
        guard !live.isEmpty, !directories.isEmpty else {
            herdr.hookRecords = []
            herdr.recordCache = [:]
            tickHerdrMonitor(paneIDs: [])
            return
        }
        herdr.reading = true
        let cache = herdr.recordCache
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                HerdrHookRecordReader.read(directories: directories, cache: cache)
            }.value
            herdr.reading = false
            herdr.hookRecords = result.records
            herdr.recordCache = result.cache
            // Liveness is re-read here: sessions may have ended while the records were read.
            tickHerdrMonitor(paneIDs: HerdrBindingInputs.gatePaneIDs(records: result.records,
                                                                     liveSessions: herdrLiveSessions()))
        }
    }

    private func tickHerdrMonitor(paneIDs: Set<String>) {
        let monitor = herdr.monitor
        if monitor.onScan == nil {
            monitor.onScan = { [weak self] outcome in
                self?.publishHerdrScan(outcome)
                self?.observeHerdrVisit(outcome)
            }
        }
        monitor.tick(now: ProcessInfo.processInfo.systemUptime, ghosttyControlsEnabled: ghosttyEnabled,
                     herdrPaneIDs: paneIDs)
        publishHerdrScan(monitor.latest)
    }

    private func publishHerdrScan(_ outcome: HerdrScanOutcome?) {
        let inUse = herdr.monitor.isGateOpen
        guard herdr.scanOutcome != outcome || herdr.inUse != inUse else { return }
        objectWillChange.send()
        herdr.scanOutcome = outcome
        herdr.inUse = inUse
    }

    // MARK: - Inputs

    /// Codex CLI sessions Steer considers live, and Claude sessions in a complete inventory.
    private func herdrLiveSessions() -> Set<HerdrSessionKey> {
        let codex = liveCLI.subtracting(endedSessions).map {
            HerdrSessionKey(agent: .codex, sessionID: $0.uuidString)
        }
        let claude = liveClaudeSessions.values.flatMap { $0 }.map {
            HerdrSessionKey(agent: .claude, sessionID: $0)
        }
        return Set(codex).union(claude)
    }

    private func herdrLiveness(of session: HerdrSessionKey) -> HerdrSessionLiveness {
        herdrLiveSessions().contains(session) ? .live : .ended
    }

    /// Codex's hook event directory and every connected Claude root's.
    private func herdrEventDirectories() -> [URL] {
        let claudePaths = claude.roots.filter { $0.status == .connected }.map(\.eventsPath)
        return Set([eventsPath] + claudePaths).filter { !$0.isEmpty }.sorted()
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
