import Foundation
import SteerCore

/// Companion's herdr state (ADR 0008, ADR 0009, ADR 0012): one `HerdrMonitor`, the hook records it
/// was last gated on, and the latest scan outcome. Companion holds one instance (`herdr`); everything that
/// needs a binding goes through the `Companion` API below rather than this object.
@MainActor
final class HerdrSessionBindings: ObservableObject {
    /// The latest herdr scan for settings; nil before the first scan and whenever the ADR 0009 gate
    /// is closed (Ghostty controls off, or neither a live Claude session's newest hook event
    /// recorded a pane nor a live Codex title is outside Ghostty with herdr's socket trusted).
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
    /// Pane IDs from live Claude sessions' newest hook events at the last read: the hook-record half
    /// of the gate, and whether a scan reads Claude's integration status.
    fileprivate var claudePaneIDs: Set<String> = []
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
    /// herdr (or, for Codex, its title is in both herdr and Ghostty) but Steer cannot target its
    /// pane, so Open and relay stay disabled. A `bound` result is not enough to act on: call
    /// `revalidateHerdrBinding(for:)` immediately before any focus or key. Reading this never
    /// contacts herdr.
    func herdrBinding(for session: HerdrSessionKey) -> HerdrSessionBinding {
        HerdrBindingInputs.binding(for: session, liveness: herdrLiveness(of: session), hookRecords: herdr.hookRecords,
                                   ghosttyControlsEnabled: ghosttyEnabled, outcome: herdr.scanOutcome,
                                   defaultSocketPath: herdr.defaultSocketPath, codex: herdrCodexTitles())
    }

    /// A fresh herdr scan, off the main actor, and the session's binding against it, for an Open or
    /// relay about to act (ADR 0009 freshness). The scan re-reads `pane.process_info`, so ADR 0012's
    /// whole rule runs again for a Codex session. `outcome` is nil, and no request is made, when the
    /// gate is closed; a Claude session in herdr is then `unavailable(.notScanned)` or
    /// `.ghosttyControlsOff`, and a Codex session is `notInHerdr`. Claude hook records are those of
    /// the last scheduled read (at most one scan interval old); Codex sessions and Ghostty titles
    /// are Steer's current ones. The fresh outcome does not replace the published one.
    func revalidateHerdrBinding(for session: HerdrSessionKey) async -> (binding: HerdrSessionBinding,
                                                                       outcome: HerdrScanOutcome?) {
        let codex = herdrCodexTitles()
        let outcome = await herdr.monitor.revalidate(
            HerdrBindingInputs.scanRequest(paneIDs: herdr.claudePaneIDs, codex: codex))
        let binding = HerdrBindingInputs.binding(for: session, liveness: herdrLiveness(of: session),
                                                 hookRecords: herdr.hookRecords,
                                                 ghosttyControlsEnabled: ghosttyEnabled,
                                                 outcome: outcome, defaultSocketPath: herdr.defaultSocketPath,
                                                 codex: herdrCodexTitles())
        return (binding, outcome)
    }

    /// The latest herdr scan outcome for settings (also published by `herdr.scanOutcome`).
    var herdrScanOutcome: HerdrScanOutcome? { herdr.scanOutcome }

    /// Agents with a live session whose newest hook event reported a herdr pane, for the settings
    /// row's integration problems (#127). Only Claude Code counts: Codex needs no herdr
    /// integration and its hook records are not read (ADR 0012). Reading this never contacts herdr.
    var herdrAgentsSeen: Set<HerdrAgentKind> {
        herdr.claudePaneIDs.isEmpty ? [] : [.claude]
    }

    // MARK: - Scan

    /// Called once per completed hook scan. Reads the newest hook records and checks herdr's
    /// default socket off the main actor, then ticks the monitor with Ghostty controls, the pane IDs
    /// of live Claude sessions' newest events, and the Codex half of the gate (ADR 0012). The monitor
    /// contacts herdr only when the gate holds.
    func scanHerdr() {
        guard previewMode == nil, !CommandLine.arguments.contains("--smoke-test"), !herdr.reading else { return }
        let live = herdrLiveSessions()
        let directories = herdrEventDirectories()
        guard !live.isEmpty else {
            herdr.hookRecords = []
            herdr.recordCache = [:]
            herdr.claudePaneIDs = []
            tickHerdrMonitor(paneIDs: [], codexGate: false, codex: .none)
            return
        }
        herdr.reading = true
        let cache = herdr.recordCache
        let socketPath = herdr.defaultSocketPath
        let checkSocket = ghosttyEnabled && !herdrCodexTitles().outsideGhostty.isEmpty
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) {
                (directories.isEmpty ? HerdrHookRecordReader.Result.empty
                    : HerdrHookRecordReader.read(directories: directories, cache: cache),
                 checkSocket && HerdrSocketTrust.reason(at: socketPath) == nil)
            }.value
            herdr.reading = false
            herdr.hookRecords = result.0.records
            herdr.recordCache = result.0.cache
            // Liveness and titles are re-read here: sessions may have ended while the records were read.
            let codex = herdrCodexTitles()
            let paneIDs = HerdrBindingInputs.gatePaneIDs(records: result.0.records, liveSessions: herdrLiveSessions())
            herdr.claudePaneIDs = paneIDs
            tickHerdrMonitor(paneIDs: paneIDs,
                             codexGate: HerdrBindingInputs.codexGateOpens(codex, defaultSocketTrusted: result.1),
                             codex: codex)
        }
    }

    private func tickHerdrMonitor(paneIDs: Set<String>, codexGate: Bool, codex: HerdrCodexTitles) {
        let monitor = herdr.monitor
        if monitor.onScan == nil {
            monitor.onScan = { [weak self] outcome in
                self?.publishHerdrScan(outcome)
                self?.observeHerdrVisit(outcome)
            }
        }
        monitor.tick(now: ProcessInfo.processInfo.systemUptime, ghosttyControlsEnabled: ghosttyEnabled,
                     herdrPaneIDs: paneIDs, codexGate: codexGate,
                     request: HerdrBindingInputs.scanRequest(paneIDs: paneIDs, codex: codex))
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

    /// Live Codex sessions and the titles of the latest complete Ghostty inventory (ADR 0012).
    private func herdrCodexTitles() -> HerdrCodexTitles {
        HerdrCodexTitles(liveSessions: Set(liveCLI.subtracting(endedSessions).map(\.uuidString)),
                         ghostty: ghosttyEnabled ? knownGhosttySnapshot?.terminalNames : nil)
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
