import AppKit
import HerdlyCore

// Rex: the two-second binding and visit scan, Open through ADR 0016's sequence with ADR 0015's fallback,
// and replies typed into the bound block (ADR 0017) through the shared typed-reply path
// (`Companion.typeInto`). Codex question digits stay off until a live proof (`RexInput.questionDigitsProvenLive`).
// Everything runs only while Rex's switch is on. Rules are HerdlyCore's (`Rex.swift`,
// `TerminalTabBinding.swift`, `TerminalTypedInput.swift`); this file reads, sends and schedules.

/// Rex state held by the companion. Main-actor only; memory only. The Settings card observes it.
@MainActor
final class RexState: ObservableObject {
    /// A `rex` binary is in its fixed locations.
    @Published var installed = false
    @Published var scan: RexScanStatus = .notRead
    /// A live session was seen bound to a Rex block since the switch went on.
    @Published var inUse = false
    /// The running server's version, shown on the card for information only.
    @Published var version: String?
    /// Each session's latest Open in Rex, for Show diagnostics.
    @Published var lastOpen: [String: String] = [:]
    /// The latest scan's exact binding reasons, for Show diagnostics.
    @Published var diagnostics: [String] = []
    var codexRoutes: [UUID: TerminalReplyRoute] = [:]
    var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
    /// Codex sessions whose title a Rex block carried in the latest scan: their questions follow Rex's digit
    /// gate (ADR 0017), which is off, so they are answered in Codex.
    var codexSeen: Set<UUID> = []
    /// Every block title in the latest readable inventory, for herdr's Codex gate (ADR 0014); nil before one.
    var latestTitles: Set<String>?
    /// ADR 0016's visit interval and dwell run over Rex blocks, by block id.
    var visits = TerminalVisitTracker<String>()
    /// Bumped on every switch change, so a scan started before it applies to nothing.
    var generation = 0
    var checking = false
    var nextScan: Double = 0
}

extension Companion {
    /// Rex's switch is on. Open, typed input and other hosts' question keys then account for it even before
    /// or without a readable scan: an enabled host that cannot be read fails closed (ADR 0013).
    var rexSwitchedOn: Bool {
        previewMode == nil && hostSwitches.mayContact(.rex)
    }

    // MARK: - Switch

    /// At launch and when the switch goes on: whether a `rex` binary is in its fixed locations, and the
    /// running server's version for the card. Rex needs no Automation access.
    func startRex() {
        Task { @MainActor in
            rex.installed = await Task.detached { RexNavigation.binary() != nil }.value
            rex.version = hostSwitches.isOn(.rex) ? await Task.detached { RexNavigation.version() }.value : nil
        }
    }

    /// The switch moved (`setHostSwitch`). Off forgets every scan result and visit.
    func rexSwitchChanged(_ on: Bool) {
        rex.generation += 1
        rex.scan = .notRead
        rex.inUse = false
        rex.codexRoutes = [:]
        rex.claudeRoutes = [:]
        rex.codexSeen = []
        rex.latestTitles = nil
        rex.diagnostics = []
        rex.nextScan = 0
        rex.visits.reset(at: Date().timeIntervalSince1970)
        if on { startRex() }
    }

    // MARK: - Scan (bindings, routes, visits)

    /// Every two seconds while Rex is on and a CLI session is live or queued. Visibility needs macOS to
    /// report Rex frontmost; when it is not, Rex is read only while a queued CLI question, completion or
    /// Claude outcome could show input controls. One check at a time; none during an Open.
    func checkRex() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard rexSwitchedOn, !rex.checking, !openingTask, uptime >= rex.nextScan else { return }
        let claudeOutcomes = agentQueue.snapshot.outcomes.filter { $0.session.source == .claude && $0.session.surface == .cli }
        let cliQuestions = queue.items.compactMap(\.question).filter { $0.source == .cli }
        guard !cliItems.isEmpty || !cliQuestions.isEmpty || !liveCLI.isEmpty || !claudeOutcomes.isEmpty else { return }
        rex.nextScan = uptime + 2
        let takenAt = Date().timeIntervalSince1970
        // ADR 0016: frontmost comes from macOS as the scan starts.
        let frontmost = TerminalApps.frontmostHost()
        let inputSessions = Set(cliItems.map(\.session)).union(cliQuestions.map(\.session))
        guard frontmost == .rex || !inputSessions.isEmpty || !claudeOutcomes.isEmpty || !codexSessionsAwaitingInventory.isEmpty else {
            rex.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: .nothing))
            return
        }
        guard RexNavigation.isRunning() else {
            rex.scan = .notRunning
            rex.codexRoutes = [:]
            rex.claudeRoutes = [:]
            rex.codexSeen = []
            rex.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: .nothing))
            return
        }
        rex.checking = true
        let codexSessions = liveCLI.union(inputSessions)
        var claudeRows: [AgentSessionIdentity: [ClaudeInventorySession]] = [:]
        for identity in Set(claudeOutcomes.map(\.session)) {
            claudeRows[identity] = (claudeInventories[identity.sourceScope]?.sessions ?? [])
                .filter { $0.kind == .interactive && $0.sessionID == identity.session }
        }
        let rows = claudeRows
        let others = otherTabHosts
        let generation = rex.generation
        Task { @MainActor in
            let observed = await Task.detached { () -> (TerminalTabReads, [AgentSessionIdentity: ClaudeTabProcess]) in
                let claude = rows.mapValues(ClaudeTabProcess.read)
                let reads = TerminalTabReads.take(others: others, claudeTTYs: Set(claude.values.compactMap(\.tty)), second: true)
                return (reads, claude)
            }.value
            rex.checking = false
            guard generation == rex.generation, rexSwitchedOn else { return }
            applyRexScan(observed.0, claude: observed.1, codexSessions: codexSessions, frontmost: frontmost, takenAt: takenAt)
            refresh()
        }
    }

    private func applyRexScan(_ reads: TerminalTabReads, claude: [AgentSessionIdentity: ClaudeTabProcess],
                              codexSessions: Set<UUID>, frontmost: TerminalHost?, takenAt: Double) {
        switch reads.rex {
        case .snapshot(let snapshot):
            rex.scan = .read
            rex.latestTitles = Set(snapshot.blocks.compactMap(\.title))
        case .notRunning: rex.scan = .notRunning
        case .unreadable(let reason): rex.scan = .unreadable(reason)
        }
        recordHostTitles(reads.inventories, takenAt: takenAt)
        var diagnostics = ["scan: \(rex.scan)",
                           "sessions: \(reads.rex.snapshot?.sessionIDs.count ?? 0), blocks: \(reads.rex.snapshot?.blocks.count ?? 0)",
                           "question digits: \(TerminalHost.rex.typesQuestionDigits ? "on" : "off until proven live")"]
        var codexRoutes: [UUID: TerminalReplyRoute] = [:]
        var codexSeen: Set<UUID> = []
        var codexTargets: [UUID: TerminalTabTarget] = [:]
        for session in codexSessions.sorted(by: { $0.uuidString < $1.uuidString }) {
            // A scan's binding is for presentation and visits; Open and typed input re-run it on fresh reads.
            let binding = rexCodexBinding(session, reads: reads)
            if let title = HerdrCodexBindingRules.title(forSession: session.uuidString.lowercased()),
               case .tabs(let tabs) = reads.rex.inventory,
               TerminalTabOpen.codexStays(in: .rex, carriesTitle: TerminalTabBindingRules.carriesCodexTitle(
                   tabs, title: title, processes: reads.processes), binding: binding) {
                codexSeen.insert(session)
            }
            if let route = TerminalReplyRoute.from(binding) { codexRoutes[session] = route }
            if case .bound(let target) = binding, target.host == .rex { codexTargets[session] = target }
            diagnostics.append("Codex \(session.uuidString.lowercased().prefix(8)): \(binding)")
        }
        var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
        var claudeTargets: [AgentSessionIdentity: TerminalTabTarget] = [:]
        for (identity, process) in claude {
            let binding = rexClaudeBinding(identity, process: process, reads: reads)
            // A session Zellij holds or could hold keeps Zellij's route (#242): its pane has no tab here.
            if zellijClaudeBinding(identity, process: process, read: reads.zellij) == .notInZellij,
               let route = TerminalReplyRoute.from(binding) { claudeRoutes[identity] = route }
            if case .bound(let target) = binding, target.host == .rex { claudeTargets[identity] = target }
            diagnostics.append("Claude \(identity.session.prefix(8)): \(binding)")
        }
        rex.codexRoutes = codexRoutes
        rex.claudeRoutes = claudeRoutes
        rex.codexSeen = codexSeen
        if !codexTargets.isEmpty || !claudeTargets.isEmpty { rex.inUse = true }
        for (session, line) in rex.lastOpen.sorted(by: { $0.key < $1.key }) {
            diagnostics.append("\(session.prefix(8)): \(line)")
        }
        rex.diagnostics = diagnostics

        // ADR 0016: one visit and dwell rule; only completions, only for the session's own bound block.
        let reading: TerminalVisibilityReading<String> = frontmost == .rex
            ? TerminalVisibility.rex(reads.rex.snapshot, frontmost: frontmost)
            : .nothing
        rex.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: reading))
        for (session, target) in codexTargets {
            let completions = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
            acknowledgeCodexCompletions(Array(rex.visits.acknowledged(completions, target: target.tabID)))
        }
        for (identity, target) in claudeTargets {
            let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
            for id in rex.visits.acknowledged(outcomes, target: target.tabID) { agentQueue.dismiss(.outcome(id)) }
        }
        saveCompletions()
    }

    func rexCodexBinding(_ session: UUID, reads: TerminalTabReads) -> TerminalTabBinding {
        TerminalTabBindingRules.codex(sessionID: session.uuidString, liveness: endedSessions.contains(session) ? .ended : .live,
                                      liveSessions: Set(liveCLI.map(\.uuidString)), switches: hostSwitches,
                                      inventories: reads.inventories, processes: reads.processes,
                                      secondRead: reads.secondRead, multiplexerClientTTYs: reads.multiplexerClientTTYs)
    }

    func rexClaudeBinding(_ identity: AgentSessionIdentity, process: ClaudeTabProcess,
                          reads: TerminalTabReads) -> TerminalTabBinding {
        TerminalTabBindingRules.claude(sessionID: identity.session, liveness: .live, process: process.process,
                                       observed: process.observed, switches: hostSwitches,
                                       inventories: reads.inventories, processes: reads.processes)
    }

    // MARK: - Open (ADR 0015, ADR 0016)

    /// Open for a Codex CLI session while Rex is on. A session whose title no Rex block carries is left to
    /// `otherwise` when another host is on; an unreadable Rex keeps it here, where it is unavailable (ADR 0013).
    func openCodexWithRex(_ session: UUID, otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask, let title = HerdrCodexBindingRules.title(forSession: session.uuidString.lowercased()) else { return }
        openingTask = true
        let others = otherTabHosts
        let otherRouteOn = ghosttyEnabled || wezTermSwitchedOn || terminalAppSwitchedOn || hostSwitches.mayContact(.iTerm2)
        Task { @MainActor in
            let first = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: false) }.value
            let carries = first.rex.snapshot?.blocks.contains { $0.title == title } ?? false
            // A decoy block here leaves a session whose tab is in another host to that host's route (#268).
            let holds = TerminalTabOpen.codexStays(in: .rex, carriesTitle: carries, binding: rexCodexBinding(session, reads: first))
            if TerminalAppOpen.leavesToOtherRoute(otherRouteOn: otherRouteOn, inventory: first.rex.inventory, holdsSession: holds) {
                openingTask = false
                otherwise()
                return
            }
            let latest = LatestRexReads()
            let run = await runRexOpen(codexTitle: title, revalidate: { [weak self] in
                let reads = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: true) }.value
                latest.reads = reads
                guard let self else { return (.unavailable(.sessionEnded), reads) }
                return (self.rexCodexBinding(session, reads: reads), reads)
            })
            let switches = hostSwitches
            let result: TerminalOpenResult
            switch run {
            case .opened(_, let preOpenAt):
                result = .opened
                let queued = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
                let acknowledged = TerminalVisitAcknowledgment.afterOpen(queued, result: result, preOpenAt: preOpenAt)
                if !acknowledged.isEmpty {
                    acknowledgeCodexCompletions(Array(acknowledged))
                    saveCompletions()
                }
            case .failed(let miss, _):
                let carriers = latest.reads.map {
                    TerminalTabOpen.codexCarriers(title: title, switches: switches, inventories: $0.inventories,
                                                  processes: $0.processes)
                } ?? []
                // ADR 0015 amendment: walk from each titled block's own `codex`; never a guess past a failed walk.
                result = await openResult(.miss(miss)) { _ in
                    let candidates = await Task.detached {
                        TerminalTabOpen.codexCandidates(carriers, walk: TerminalApps.walk(from:),
                                                        ttyWrittenAt: TerminalTTYReads.writtenAt)
                    }.value
                    return OpenFallback.codexApp(candidates: candidates, switches: switches)
                }
            }
            rex.lastOpen[session.uuidString.lowercased()] = Self.rexDiagnostic(run, result: result)
            recordOpen(result, codex: session)
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// Open for a Claude CLI session while Rex is on. A session whose process tty no Rex block holds is left
    /// to `otherwise`.
    func openClaudeWithRex(_ identity: AgentSessionIdentity, request: ClaudeOpenRequest?,
                           otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask else { return }
        openingTask = true
        let others = otherTabHosts
        let roots = configuredClaudeNavigationRoots()
        Task { @MainActor in
            let rows = await Task.detached { () -> [ClaudeInventorySession]? in
                let scans = roots.map { ClaudeSetupDetection.activeSessionInventory(root: $0.root, capabilities: $0.capabilities) }
                guard !scans.isEmpty, scans.allSatisfy(\.available) else { return nil }
                return scans.flatMap { $0.sessions.filter { $0.kind == .interactive && $0.sessionID == identity.session } }
            }.value
            guard let rows else {
                openingTask = false
                refresh()
                return
            }
            let process = await Task.detached { ClaudeTabProcess.read(rows) }.value
            let first = await Task.detached {
                TerminalTabReads.take(others: others, claudeTTYs: Set([process.tty].compactMap { $0 }), second: false)
            }.value
            let holds = process.tty.map { tty in first.rex.snapshot?.blocks.contains { $0.tty == tty } ?? false } ?? false
            if TerminalAppOpen.leavesToOtherRoute(otherRouteOn: true, inventory: first.rex.inventory, holdsSession: holds) {
                openingTask = false
                otherwise()
                return
            }
            let preOpenAt = Date().timeIntervalSince1970
            let run = await runRexOpen(codexTitle: nil, revalidate: { [weak self] in
                let fresh = await Task.detached { () -> (ClaudeTabProcess, TerminalTabReads) in
                    let again = ClaudeTabProcess.read(rows)
                    return (again, TerminalTabReads.take(others: others, claudeTTYs: Set([again.tty].compactMap { $0 }),
                                                         second: false))
                }.value
                guard let self, !rows.isEmpty else { return (.unavailable(.sessionEnded), fresh.1) }
                return (self.rexClaudeBinding(identity, process: fresh.0, reads: fresh.1), fresh.1)
            })
            let switches = hostSwitches
            let pid = process.pid
            let result: TerminalOpenResult
            switch run {
            case .opened: result = .opened
            case .failed(let miss, _):
                result = await openResult(.miss(miss)) { _ in
                    let walk = await Task.detached { pid.map(TerminalApps.walk(from:)) ?? .failed }.value
                    return OpenFallback.processApp(walks: [walk], agent: .claude, switches: switches)
                }
            }
            rex.lastOpen[identity.session] = Self.rexDiagnostic(run, result: result)
            recordOpen(result, claude: identity)
            // ADR 0015: an Open on an actionable request hands it back with no decision, fallback included;
            // an unavailable one hands nothing back.
            handBackClaudeRequest(request, after: result)
            if case .unavailable = result {} else {
                let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
                for id in TerminalVisitAcknowledgment.afterOpen(outcomes, result: result, preOpenAt: preOpenAt) {
                    agentQueue.dismiss(.outcome(id))
                }
                saveCompletions()
            }
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// ADR 0016's sequence with Rex's steps, each sent once. `revalidate` returns the binding re-run on fresh
    /// reads and the reads it used.
    private func runRexOpen(codexTitle: String?,
                            revalidate: @escaping () async -> (TerminalTabBinding, TerminalTabReads))
        async -> TerminalOpenRun<RexOpenPlan, OpenMiss> {
        await RexOpen.run(
            now: { Date().timeIntervalSince1970 },
            revalidate: { _ in
                let (binding, reads) = await revalidate()
                switch reads.rex {
                case .unreadable: return .failure(.unavailable(.hostUnreadable(.rex)))
                case .notRunning: return .failure(TerminalTabOpen.miss(binding.unavailableReason ?? .titleNotFound))
                case .snapshot(let snapshot):
                    return RexOpen.plan(TerminalTabOpen.route(binding), codexTitle: codexTitle, snapshot: snapshot)
                }
            },
            raise: { plan in
                let result = await Task.detached { RexNavigation.focus(plan) }.value
                // Then activate Rex as a whole; whether the block shows is what verify reads back.
                if case .exited(0, _, _) = result.0 { _ = TerminalApps.activate(.rex) }
                return result
            },
            verifyRead: {
                let observed = await Task.detached { RexNavigation.read() }.value
                return (observed.snapshot, TerminalApps.frontmostHost())
            })
    }

    private static func rexDiagnostic(_ run: TerminalOpenRun<RexOpenPlan, OpenMiss>, result: TerminalOpenResult) -> String {
        switch run {
        case .opened: "Open: verified"
        case .failed(let miss, let step): "Open: \(result) after \(miss) at \(step)"
        }
    }

    // MARK: - Settings

    var rexSettingsRow: RexSettingsRow {
        RexPresentation.settingsRow(on: hostSwitches.isOn(.rex), installed: rex.installed, scan: rex.scan, inUse: rex.inUse)
    }
}

/// The latest reads a Rex Open's revalidation took, for the fallback's candidate walks.
@MainActor
private final class LatestRexReads {
    var reads: TerminalTabReads?
}
