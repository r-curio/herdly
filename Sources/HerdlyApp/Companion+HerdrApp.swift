import AppKit
import HerdlyCore

// The Herdr desktop app (not the herdr multiplexer, Companion+Herdr.swift): the two-second binding and visit
// scan, Open through ADR 0016's sequence with ADR 0015's fallback, and replies pasted into the bound terminal
// (ADR 0017) through the shared typed-reply path (`Companion.typeInto`). Codex question digits stay off until a
// live proof (`HerdrAppInput.questionDigitsProvenLive`). Everything runs only while the Herdr app's switch is
// on. Rules are HerdlyCore's (`HerdrApp.swift`,
// `TerminalTabBinding.swift`, `TerminalTypedInput.swift`); this file reads, sends and schedules.

/// Herdr app state held by the companion. Main-actor only; memory only. The Settings card observes it.
@MainActor
final class HerdrAppState: ObservableObject {
    /// Herdr.app is in /Applications or ~/Applications.
    @Published var installed = false
    @Published var scan: HerdrAppScanStatus = .notRead
    /// A live session was seen bound to a Herdr terminal since the switch went on.
    @Published var inUse = false
    /// Herdr.app's version, shown on the card for information only.
    @Published var version: String?
    /// Each session's latest Open in Herdr, for Show diagnostics.
    @Published var lastOpen: [String: String] = [:]
    /// The latest scan's exact binding reasons, for Show diagnostics.
    @Published var diagnostics: [String] = []
    var codexRoutes: [UUID: TerminalReplyRoute] = [:]
    var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
    /// Codex sessions whose title a Herdr terminal carried in the latest scan: their questions follow Herdr's digit
    /// gate (ADR 0017), which is off, so they are answered in Codex.
    var codexSeen: Set<UUID> = []
    /// Every terminal title in the latest readable inventory, for herdr's Codex gate (ADR 0014); nil before one.
    var latestTitles: Set<String>?
    /// ADR 0016's visit interval and dwell run over Herdr terminals, by address.
    var visits = TerminalVisitTracker<String>()
    /// Bumped on every switch change, so a scan started before it applies to nothing.
    var generation = 0
    var checking = false
    var nextScan: Double = 0
}

extension Companion {
    /// The Herdr app's switch is on. Open, typed input and other hosts' question keys then account for it even before
    /// or without a readable scan: an enabled host that cannot be read fails closed (ADR 0013).
    var herdrAppSwitchedOn: Bool {
        previewMode == nil && hostSwitches.mayContact(.herdrApp)
    }

    // MARK: - Switch

    /// At launch and when the switch goes on: whether Herdr.app is installed, and its version for the card.
    /// Herdr needs no Automation access.
    func startHerdrApp() {
        Task { @MainActor in
            herdrApp.installed = await Task.detached { HerdrAppNavigation.binary() != nil }.value
            herdrApp.version = hostSwitches.isOn(.herdrApp) ? await Task.detached { HerdrAppNavigation.version() }.value : nil
        }
    }

    /// The switch moved (`setHostSwitch`). Off forgets every scan result and visit.
    func herdrAppSwitchChanged(_ on: Bool) {
        herdrApp.generation += 1
        herdrApp.scan = .notRead
        herdrApp.inUse = false
        herdrApp.codexRoutes = [:]
        herdrApp.claudeRoutes = [:]
        herdrApp.codexSeen = []
        herdrApp.latestTitles = nil
        herdrApp.diagnostics = []
        herdrApp.nextScan = 0
        herdrApp.visits.reset(at: Date().timeIntervalSince1970)
        if on { startHerdrApp() }
    }

    // MARK: - Scan (bindings, routes, visits)

    /// Every two seconds while the Herdr app is on and a CLI session is live or queued. Visibility needs macOS
    /// to report Herdr frontmost, and then the window is read too; when it is not, Herdr is read only while a queued CLI question, completion or
    /// Claude outcome could show input controls. One check at a time; none during an Open.
    func checkHerdrApp() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard herdrAppSwitchedOn, !herdrApp.checking, !openingTask, uptime >= herdrApp.nextScan else { return }
        let claudeOutcomes = agentQueue.snapshot.outcomes.filter { $0.session.source == .claude && $0.session.surface == .cli }
        let cliQuestions = queue.items.compactMap(\.question).filter { $0.source == .cli }
        guard !cliItems.isEmpty || !cliQuestions.isEmpty || !liveCLI.isEmpty || !claudeOutcomes.isEmpty else { return }
        herdrApp.nextScan = uptime + 2
        let takenAt = Date().timeIntervalSince1970
        // ADR 0016: frontmost comes from macOS as the scan starts.
        let frontmost = TerminalApps.frontmostHost()
        let inputSessions = Set(cliItems.map(\.session)).union(cliQuestions.map(\.session))
        guard frontmost == .herdrApp || !inputSessions.isEmpty || !claudeOutcomes.isEmpty || !codexSessionsAwaitingInventory.isEmpty else {
            herdrApp.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: .nothing))
            return
        }
        guard HerdrAppNavigation.isRunning() else {
            herdrApp.scan = .notRunning
            herdrApp.codexRoutes = [:]
            herdrApp.claudeRoutes = [:]
            herdrApp.codexSeen = []
            herdrApp.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: .nothing))
            return
        }
        herdrApp.checking = true
        let codexSessions = liveCLI.union(inputSessions)
        var claudeRows: [AgentSessionIdentity: [ClaudeInventorySession]] = [:]
        for identity in Set(claudeOutcomes.map(\.session)) {
            claudeRows[identity] = (claudeInventories[identity.sourceScope]?.sessions ?? [])
                .filter { $0.kind == .interactive && $0.sessionID == identity.session }
        }
        let rows = claudeRows
        let others = otherTabHosts
        let generation = herdrApp.generation
        Task { @MainActor in
            let observed = await Task.detached {
                () -> (TerminalTabReads, [AgentSessionIdentity: ClaudeTabProcess], HerdrAppWindowRead) in
                let claude = rows.mapValues(ClaudeTabProcess.read)
                let reads = TerminalTabReads.take(others: others, claudeTTYs: Set(claude.values.compactMap(\.tty)), second: true)
                // The window only matters for the visible test, which needs Herdr frontmost.
                let window = frontmost == .herdrApp ? HerdrAppNavigation.readWindow() : .closed
                return (reads, claude, window)
            }.value
            herdrApp.checking = false
            guard generation == herdrApp.generation, herdrAppSwitchedOn else { return }
            applyHerdrAppScan(observed.0, claude: observed.1, window: observed.2, codexSessions: codexSessions,
                              frontmost: frontmost, takenAt: takenAt)
            refresh()
        }
    }

    private func applyHerdrAppScan(_ reads: TerminalTabReads, claude: [AgentSessionIdentity: ClaudeTabProcess],
                                   window: HerdrAppWindowRead, codexSessions: Set<UUID>, frontmost: TerminalHost?,
                                   takenAt: Double) {
        switch reads.herdrApp {
        case .snapshot(let snapshot):
            herdrApp.scan = .read
            herdrApp.latestTitles = Set(snapshot.terminals.compactMap(\.title))
        case .notRunning: herdrApp.scan = .notRunning
        case .unreadable(let reason): herdrApp.scan = .unreadable(reason)
        }
        recordHostTitles(reads.inventories, takenAt: takenAt)
        var diagnostics = ["scan: \(herdrApp.scan)",
                           "terminals: \(reads.herdrApp.snapshot?.terminals.count ?? 0), window: \(window)",
                           "question digits: \(TerminalHost.herdrApp.typesQuestionDigits ? "on" : "off until proven live")"]
        var codexRoutes: [UUID: TerminalReplyRoute] = [:]
        var codexSeen: Set<UUID> = []
        var codexTargets: [UUID: TerminalTabTarget] = [:]
        for session in codexSessions.sorted(by: { $0.uuidString < $1.uuidString }) {
            // A scan's binding is for presentation and visits; Open and typed input re-run it on fresh reads.
            let binding = herdrAppCodexBinding(session, reads: reads)
            if let title = HerdrCodexBindingRules.title(forSession: session.uuidString.lowercased()),
               case .tabs(let tabs) = reads.herdrApp.inventory,
               TerminalTabOpen.codexStays(in: .herdrApp, carriesTitle: TerminalTabBindingRules.carriesCodexTitle(
                   tabs, title: title, processes: reads.processes), binding: binding) {
                codexSeen.insert(session)
            }
            if let route = TerminalReplyRoute.from(binding) { codexRoutes[session] = route }
            if case .bound(let target) = binding, target.host == .herdrApp { codexTargets[session] = target }
            diagnostics.append("Codex \(session.uuidString.lowercased().prefix(8)): \(binding)")
        }
        var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
        var claudeTargets: [AgentSessionIdentity: TerminalTabTarget] = [:]
        for (identity, process) in claude {
            let binding = herdrAppClaudeBinding(identity, process: process, reads: reads)
            // A session Zellij holds or could hold keeps Zellij's route (#242): its pane has no tab here.
            if zellijClaudeBinding(identity, process: process, read: reads.zellij) == .notInZellij,
               let route = TerminalReplyRoute.from(binding) { claudeRoutes[identity] = route }
            if case .bound(let target) = binding, target.host == .herdrApp { claudeTargets[identity] = target }
            diagnostics.append("Claude \(identity.session.prefix(8)): \(binding)")
        }
        herdrApp.codexRoutes = codexRoutes
        herdrApp.claudeRoutes = claudeRoutes
        herdrApp.codexSeen = codexSeen
        if !codexTargets.isEmpty || !claudeTargets.isEmpty { herdrApp.inUse = true }
        for (session, line) in herdrApp.lastOpen.sorted(by: { $0.key < $1.key }) {
            diagnostics.append("\(session.prefix(8)): \(line)")
        }
        herdrApp.diagnostics = diagnostics

        // ADR 0016: one visit and dwell rule; only completions, only for the session's own bound terminal.
        let reading: TerminalVisibilityReading<String> = frontmost == .herdrApp
            ? TerminalVisibility.herdrApp(reads.herdrApp.snapshot, window: window, frontmost: frontmost)
            : .nothing
        herdrApp.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: reading))
        for (session, target) in codexTargets {
            let completions = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
            acknowledgeCodexCompletions(Array(herdrApp.visits.acknowledged(completions, target: target.tabID)))
        }
        for (identity, target) in claudeTargets {
            let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
            for id in herdrApp.visits.acknowledged(outcomes, target: target.tabID) { agentQueue.dismiss(.outcome(id)) }
        }
        saveCompletions()
    }

    func herdrAppCodexBinding(_ session: UUID, reads: TerminalTabReads) -> TerminalTabBinding {
        TerminalTabBindingRules.codex(sessionID: session.uuidString, liveness: endedSessions.contains(session) ? .ended : .live,
                                      liveSessions: Set(liveCLI.map(\.uuidString)), switches: contactSwitches,
                                      inventories: reads.inventories, processes: reads.processes,
                                      secondRead: reads.secondRead, multiplexerClientTTYs: reads.multiplexerClientTTYs)
    }

    func herdrAppClaudeBinding(_ identity: AgentSessionIdentity, process: ClaudeTabProcess,
                          reads: TerminalTabReads) -> TerminalTabBinding {
        TerminalTabBindingRules.claude(sessionID: identity.session, liveness: .live, process: process.process,
                                       observed: process.observed, switches: contactSwitches,
                                       inventories: reads.inventories, processes: reads.processes)
    }

    // MARK: - Open (ADR 0015, ADR 0016)

    /// Open for a Codex CLI session while the Herdr app is on. A session whose title no Herdr terminal carries
    /// is left to `otherwise` when another host is on; an unreadable Herdr keeps it here, where it is unavailable (ADR 0013).
    func openCodexWithHerdrApp(_ session: UUID, otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask, let title = HerdrCodexBindingRules.title(forSession: session.uuidString.lowercased()) else { return }
        openingTask = true
        let others = otherTabHosts
        let otherRouteOn = ghosttyUsable || rexSwitchedOn || wezTermSwitchedOn || terminalAppSwitchedOn || hostSwitches.mayContact(.iTerm2)
        Task { @MainActor in
            let first = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: false) }.value
            let carries = first.herdrApp.snapshot?.terminals.contains { $0.title == title } ?? false
            // A decoy terminal here leaves a session whose tab is in another host to that host's route (#268).
            let holds = TerminalTabOpen.codexStays(in: .herdrApp, carriesTitle: carries, binding: herdrAppCodexBinding(session, reads: first))
            if TerminalAppOpen.leavesToOtherRoute(otherRouteOn: otherRouteOn, inventory: first.herdrApp.inventory, holdsSession: holds) {
                openingTask = false
                otherwise()
                return
            }
            let latest = LatestHerdrAppReads()
            let run = await runHerdrAppOpen(codexTitle: title, revalidate: { [weak self] in
                let reads = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: true) }.value
                latest.reads = reads
                guard let self else { return (.unavailable(.sessionEnded), reads) }
                return (self.herdrAppCodexBinding(session, reads: reads), reads)
            })
            let switches = contactSwitches
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
                // ADR 0015 amendment: walk from each titled terminal's own `codex`; never a guess past a failed walk.
                result = await openResult(.miss(miss)) { _ in
                    let candidates = await Task.detached {
                        TerminalTabOpen.codexCandidates(carriers, walk: TerminalApps.walk(from:),
                                                        ttyWrittenAt: TerminalTTYReads.writtenAt)
                    }.value
                    return OpenFallback.codexApp(candidates: candidates, switches: switches)
                }
            }
            herdrApp.lastOpen[session.uuidString.lowercased()] = Self.herdrAppDiagnostic(run, result: result)
            recordOpen(result, codex: session)
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// Open for a Claude CLI session while the Herdr app is on. A session whose process tty no Herdr terminal holds is left
    /// to `otherwise`.
    func openClaudeWithHerdrApp(_ identity: AgentSessionIdentity, request: ClaudeOpenRequest?,
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
            let holds = process.tty.map { tty in first.herdrApp.snapshot?.terminals.contains { $0.tty == tty } ?? false } ?? false
            if TerminalAppOpen.leavesToOtherRoute(otherRouteOn: true, inventory: first.herdrApp.inventory, holdsSession: holds) {
                openingTask = false
                otherwise()
                return
            }
            let preOpenAt = Date().timeIntervalSince1970
            let run = await runHerdrAppOpen(codexTitle: nil, revalidate: { [weak self] in
                let fresh = await Task.detached { () -> (ClaudeTabProcess, TerminalTabReads) in
                    let again = ClaudeTabProcess.read(rows)
                    return (again, TerminalTabReads.take(others: others, claudeTTYs: Set([again.tty].compactMap { $0 }),
                                                         second: false))
                }.value
                guard let self, !rows.isEmpty else { return (.unavailable(.sessionEnded), fresh.1) }
                return (self.herdrAppClaudeBinding(identity, process: fresh.0, reads: fresh.1), fresh.1)
            })
            let switches = contactSwitches
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
            herdrApp.lastOpen[identity.session] = Self.herdrAppDiagnostic(run, result: result)
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

    /// ADR 0016's sequence with Herdr's steps, each sent once. `revalidate` returns the binding re-run on fresh
    /// reads and the reads it used.
    private func runHerdrAppOpen(codexTitle: String?,
                            revalidate: @escaping () async -> (TerminalTabBinding, TerminalTabReads))
        async -> TerminalOpenRun<HerdrAppOpenPlan, OpenMiss> {
        await HerdrAppOpen.run(
            now: { Date().timeIntervalSince1970 },
            revalidate: { _ in
                let (binding, reads) = await revalidate()
                switch reads.herdrApp {
                case .unreadable: return .failure(.unavailable(.hostUnreadable(.herdrApp)))
                case .notRunning: return .failure(TerminalTabOpen.miss(binding.unavailableReason ?? .titleNotFound))
                case .snapshot(let snapshot):
                    return HerdrAppOpen.plan(TerminalTabOpen.route(binding), codexTitle: codexTitle, snapshot: snapshot)
                }
            },
            raise: { plan in
                let result = await Task.detached { HerdrAppNavigation.focus(plan) }.value
                // Then activate Herdr as a whole; whether the terminal shows is what verify reads back.
                if case .exited(0, _, _) = result { _ = TerminalApps.activate(.herdrApp) }
                return result
            },
            verifyRead: {
                let observed = await Task.detached { (HerdrAppNavigation.read(), HerdrAppNavigation.readWindow()) }.value
                return (observed.0.snapshot, observed.1.window, TerminalApps.frontmostHost())
            })
    }

    private static func herdrAppDiagnostic(_ run: TerminalOpenRun<HerdrAppOpenPlan, OpenMiss>, result: TerminalOpenResult) -> String {
        switch run {
        case .opened: "Open: verified"
        case .failed(let miss, let step): "Open: \(result) after \(miss) at \(step)"
        }
    }

    // MARK: - Codex question digits (ADR 0017)

    /// The Herdr terminal a Codex question's digit may go to: the latest scan's route, while Herdr types digits.
    func herdrAppQuestionKeyPane(for session: UUID) -> TypedInputPane? {
        guard herdrAppSwitchedOn, case .pane(let pane)? = herdrApp.codexRoutes[session], pane.host == .herdrApp,
              pane.host.typesQuestionDigits else { return nil }
        return pane
    }

    /// The Herdr send behind the shared pane-key route (`answerThroughTerminalKeys`), after
    /// `TerminalQuestionKeys.start` spent the key: immediately before it, the binding is re-run on fresh reads
    /// of every enabled host and the rollout is re-read last. One digit in one `terminal.keys`, never Enter; a
    /// key that may have been written counts as sent and is never resent.
    func sendHerdrAppQuestionKey(_ current: AttentionQuestion, start: TerminalQuestionKeys.Start,
                            question: AttentionQuestion, index: Int, option: Int) {
        answering = true
        relayLedger = start.ledger
        answerProgress[question.id] = start.progress
        noteCodexKeySending(current, index: index)
        refresh()
        let others = otherTabHosts
        let rolloutRoot = Companion.rolloutRoot
        Task { @MainActor in
            let reads = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: true) }.value
            let route = TerminalReplyRoute.from(herdrAppCodexBinding(current.session, reads: reads))
            let outcome = await Task.detached { () -> HerdrQuestionRelay.Outcome in
                // The rollout last, as of this instant: a manual answer Codex already recorded, or an ended
                // turn, sends nothing.
                let evidence = ReminderReader.currentEvidence(for: current.session, in: rolloutRoot)
                if let veto = TerminalQuestionKeys.preSendCheck(question: current, evidence: evidence, route: route,
                                                                spent: start.pane) {
                    return .vetoed(veto)
                }
                let delivery = HerdrAppNavigation.sendKey(start.key, into: start.pane)
                return .delivered(TerminalQuestionKeys.delivery(delivery))
            }.value
            answering = false
            noteCodexKeyAnswer(current, index: index, outcome: outcome)
            guard queue.items.contains(where: { $0.id == .question(question.id) }) else {
                answerProgress[question.id] = nil
                refresh()
                return
            }
            if let progress = answerProgress[question.id] {
                let settled = HerdrQuestionRelay.settle(outcome, progress: progress, ledger: relayLedger, question: current,
                                                        index: index, option: option, now: Date().timeIntervalSince1970)
                answerProgress[question.id] = settled.progress
                relayLedger = settled.ledger
            }
            refresh()
        }
    }

    // MARK: - Settings

    var herdrAppSettingsRow: HerdrAppSettingsRow {
        HerdrAppPresentation.settingsRow(on: hostSwitches.isOn(.herdrApp), installed: herdrApp.installed, scan: herdrApp.scan, inUse: herdrApp.inUse)
    }
}

/// The latest reads a Herdr Open's revalidation took, for the fallback's candidate walks.
@MainActor
private final class LatestHerdrAppReads {
    var reads: TerminalTabReads?
}
