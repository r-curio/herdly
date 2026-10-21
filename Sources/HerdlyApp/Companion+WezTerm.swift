import AppKit
import HerdlyCore

// WezTerm (#240): the two-second binding and visit scan, Open through ADR 0016's sequence with ADR 0015's
// fallback, replies typed into the bound pane (ADR 0017), and the Codex question-digit relay, offered
// since a live proof turned on `WezTermInput.questionDigitsProvenLive` (#245).
// Everything runs only while WezTerm's switch is on; the switch and card are shown since its
// acceptance (#245). Rules are HerdlyCore's (`WezTerm.swift`, `TerminalTabBinding.swift`,
// `TerminalTypedInput.swift`, `TerminalQuestionKeys.swift`); this file reads, sends and schedules.

/// WezTerm state held by the companion. Main-actor only; memory only. The Settings card observes it.
@MainActor
final class WezTermState: ObservableObject {
    /// A `wezterm` binary is in its fixed locations.
    @Published var installed = false
    @Published var scan: WezTermScanStatus = .notRead
    /// A live session was seen bound to a WezTerm pane since the switch went on.
    @Published var inUse = false
    /// `wezterm --version`, shown on the card for information only (product.md, "Settings").
    @Published var version: String?
    /// Each session's latest Open in WezTerm, for Show diagnostics.
    @Published var lastOpen: [String: String] = [:]
    /// The latest scan's exact binding reasons, for Show diagnostics.
    @Published var diagnostics: [String] = []
    /// Each queued Codex session's typed route, from the latest scan.
    var codexRoutes: [UUID: TerminalReplyRoute] = [:]
    /// Each queued Claude session's typed route, from the latest scan.
    var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
    /// Codex sessions whose title a WezTerm pane carried in the latest scan: their questions follow
    /// WezTerm's digit gate (ADR 0017).
    var codexSeen: Set<UUID> = []
    /// ADR 0016's visit interval and dwell run over WezTerm panes, by pane id.
    var visits = TerminalVisitTracker<String>()
    /// Every pane title in the latest readable `list`, for herdr's Codex gate (ADR 0014, #241); nil before one.
    var latestTitles: Set<String>?
    /// Bumped on every switch change, so a scan started before it applies to nothing.
    var generation = 0
    var checking = false
    var nextScan: Double = 0
}

/// One set of fresh reads across the enabled hosts for a WezTerm binding (ADR 0013): WezTerm and the
/// other enabled hosts, `ps` for WezTerm's panes that could bind, then WezTerm again when asked.
struct WezTermTabReads: Sendable {
    let wezTerm: WezTermRead
    /// The `list-clients` read taken with the first `list`, when asked; nil when not taken or unreadable.
    let clients: WezTermClients?
    let inventories: [TerminalHost: TerminalHostInventory]
    let processes: [String: [TerminalProcess]]
    let secondRead: [TerminalHost: TerminalHostInventory]
    /// tmux's attached clients and Zellij's client processes in the first read, whose host tabs ADR 0014
    /// leaves out of the Codex title count (#241, #242); empty while both are off.
    var multiplexerClientTTYs: Set<String> = []
    /// The first read's Zellij sessions; `.notRunning` while Zellij is off (#242).
    var zellij: ZellijRead = .notRunning

    /// Blocking: call off the main actor. `others` says which other hosts are on and running.
    static func take(running: Bool, others: OtherTabHosts, codexTitles: Set<String>, claudeTTYs: Set<String>,
                     second: Bool, clients: Bool = false) -> WezTermTabReads {
        let (read, clientRead) = WezTermNavigation.read(running: running, clients: clients)
        var inventories: [TerminalHost: TerminalHostInventory] = [.wezTerm: read.inventory]
        if others.ghosttyOn {
            inventories[.ghostty] = .ghosttyTitles(others.ghosttyRunning ? GhosttyNavigation.snapshot() : nil,
                                                   running: others.ghosttyRunning)
        }
        if let iTerm2 = others.iTerm2Running {
            inventories[.iTerm2] = iTerm2 ? ITerm2Navigation.inventory(ITerm2Navigation.snapshot()) : .notRunning
        }
        if let terminal = others.terminalAppRunning {
            inventories[.terminalApp] = terminal ? TerminalAppNavigation.snapshot().inventory : .notRunning
        }
        // tmux beside it (#241): its panes count toward uniqueness, and its clients' host tabs do not.
        let tmux: TmuxRead = others.tmuxOn ? TmuxRunner.read() : .notRunning
        if others.tmuxOn { inventories[.tmux] = tmux.inventory }
        // Zellij beside it (#242): its panes count toward uniqueness, and its clients' host tabs do not.
        let zellij: ZellijRead = others.zellijOn ? ZellijRunner.read() : .notRunning
        if others.zellijOn { inventories[.zellij] = zellij.inventory }
        // Every tab of every tty-listing host carrying one of `codexTitles`, so a title decoy is told apart
        // from a tab whose `ps` was not read, which fails closed (#268).
        let ttys = (read.snapshot?.ttysToRead(codexTitles: codexTitles, claudeTTYs: claudeTTYs) ?? [])
            .union(tmux.snapshot?.ttysToRead(claudeTTYs: claudeTTYs) ?? [])
            .union(TerminalTabReadAssembly<Void>.ttysToRead(inventories, codexTitles: codexTitles, claudeTTYs: claudeTTYs))
        let processes = TerminalTTYReads.processes(on: ttys)
        var secondRead = inventories
        if second {
            secondRead[.wezTerm] = WezTermNavigation.read(running: running).0.inventory
            if others.tmuxOn { secondRead[.tmux] = TmuxRunner.read().inventory }
            if others.zellijOn { secondRead[.zellij] = ZellijRunner.read().inventory }
        }
        return WezTermTabReads(wezTerm: read, clients: clientRead, inventories: inventories, processes: processes,
                               secondRead: secondRead,
                               multiplexerClientTTYs: (tmux.snapshot?.clientTTYs ?? []).union(zellij.snapshot?.clientTTYs ?? []),
                               zellij: zellij)
    }

    func carries(title: String) -> Bool {
        read(\.title, equals: title)
    }

    func holds(tty: String) -> Bool {
        read(\.tty, equals: tty)
    }

    private func read(_ field: KeyPath<WezTermPane, String?>, equals value: String) -> Bool {
        wezTerm.snapshot?.panes.contains { $0[keyPath: field] == value } ?? false
    }
}

extension Companion {
    /// WezTerm's switch is on. Open, typed input and other hosts' question keys then account for it even
    /// before or without a readable scan: an enabled host that cannot be read fails closed (ADR 0013).
    var wezTermSwitchedOn: Bool {
        previewMode == nil && hostSwitches.mayContact(.wezTerm)
    }

    /// The other enabled hosts a WezTerm read is taken beside (ADR 0013). Read on the main actor. Terminal.app
    /// counts by its switch, as for every other host: a Terminal.app that isn't running holds nothing even
    /// before its Automation access is verified (which needs it running), and one that is running but not
    /// yet allowed reads as unreadable (#245).
    var wezTermOtherHosts: OtherTabHosts {
        let ghosttyOn = ghosttyEnabled && ghosttyPermissionVerified
        return OtherTabHosts(ghosttyOn: ghosttyOn, ghosttyRunning: ghosttyOn && TerminalApps.isRunning(.ghostty),
                             iTerm2Running: hostSwitches.mayContact(.iTerm2) ? TerminalApps.isRunning(.iTerm2) : nil,
                             terminalAppRunning: terminalAppSwitchedOn ? TerminalApps.isRunning(.terminalApp) : nil,
                             tmuxOn: tmuxContactAllowed, zellijOn: zellijContactAllowed)
    }

    // MARK: - Switch

    /// At launch: whether a `wezterm` binary is in its fixed locations, and its version for the card.
    /// WezTerm needs no Automation access.
    func startWezTerm() {
        Task { @MainActor in
            wezTerm.installed = await Task.detached { WezTermNavigation.binary() != nil }.value
            wezTerm.version = await Task.detached { WezTermNavigation.version() }.value
        }
    }

    /// The switch moved (`setHostSwitch`). Off forgets every scan result and visit.
    func wezTermSwitchChanged(_ on: Bool) {
        wezTerm.generation += 1
        wezTerm.scan = .notRead
        wezTerm.inUse = false
        wezTerm.codexRoutes = [:]
        wezTerm.claudeRoutes = [:]
        wezTerm.codexSeen = []
        wezTerm.latestTitles = nil
        wezTerm.diagnostics = []
        wezTerm.nextScan = 0
        wezTerm.visits.reset(at: Date().timeIntervalSince1970)
        if on { startWezTerm() }
    }

    // MARK: - Scan (bindings, routes, visits)

    /// Every two seconds while WezTerm is on and a CLI session is live or queued. Visibility needs macOS to
    /// report WezTerm frontmost; when it is not, nothing there is visible, and WezTerm is read only while a
    /// queued CLI question, completion or Claude outcome could show input controls. One check at a time;
    /// none during an Open.
    func checkWezTerm() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard wezTermSwitchedOn, !wezTerm.checking, !openingTask, uptime >= wezTerm.nextScan else { return }
        let claudeOutcomes = agentQueue.snapshot.outcomes.filter { $0.session.source == .claude && $0.session.surface == .cli }
        let cliQuestions = queue.items.compactMap(\.question).filter { $0.source == .cli }
        guard !cliItems.isEmpty || !cliQuestions.isEmpty || !liveCLI.isEmpty || !claudeOutcomes.isEmpty else { return }
        wezTerm.nextScan = uptime + 2
        let takenAt = Date().timeIntervalSince1970
        // ADR 0016: frontmost comes from macOS as the scan starts; WezTerm's own answer must agree.
        let frontmost = TerminalApps.frontmostHost()
        let inputSessions = Set(cliItems.map(\.session)).union(cliQuestions.map(\.session))
        guard frontmost == .wezTerm || !inputSessions.isEmpty || !claudeOutcomes.isEmpty || !codexSessionsAwaitingInventory.isEmpty else {
            wezTerm.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: .nothing))
            return
        }
        let running = TerminalApps.isRunning(.wezTerm)
        guard running else {
            wezTerm.scan = .notRunning
            wezTerm.codexRoutes = [:]
            wezTerm.claudeRoutes = [:]
            wezTerm.codexSeen = []
            wezTerm.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: .nothing))
            return
        }
        wezTerm.checking = true
        let codexSessions = liveCLI.union(inputSessions)
        let titles = Set(codexSessions.compactMap { HerdrCodexBindingRules.title(forSession: $0.uuidString.lowercased()) })
        var claudeRows: [AgentSessionIdentity: [ClaudeInventorySession]] = [:]
        for identity in Set(claudeOutcomes.map(\.session)) {
            claudeRows[identity] = (claudeInventories[identity.sourceScope]?.sessions ?? [])
                .filter { $0.kind == .interactive && $0.sessionID == identity.session }
        }
        let rows = claudeRows
        let others = wezTermOtherHosts
        let generation = wezTerm.generation
        Task { @MainActor in
            let observed = await Task.detached { () -> (WezTermTabReads, [AgentSessionIdentity: ClaudeTabProcess]) in
                let claude = rows.mapValues(ClaudeTabProcess.read)
                let reads = WezTermTabReads.take(running: true, others: others, codexTitles: titles,
                                                 claudeTTYs: Set(claude.values.compactMap(\.tty)), second: true,
                                                 clients: frontmost == .wezTerm)
                return (reads, claude)
            }.value
            wezTerm.checking = false
            guard generation == wezTerm.generation, wezTermSwitchedOn else { return }
            applyWezTermScan(observed.0, claude: observed.1, codexSessions: codexSessions, frontmost: frontmost,
                             takenAt: takenAt)
            refresh()
        }
    }

    private func applyWezTermScan(_ reads: WezTermTabReads, claude: [AgentSessionIdentity: ClaudeTabProcess],
                                  codexSessions: Set<UUID>, frontmost: TerminalHost?, takenAt: Double) {
        switch reads.wezTerm {
        case .snapshot(let snapshot):
            wezTerm.scan = .read
            wezTerm.latestTitles = Set(snapshot.panes.compactMap(\.title))
        case .notRunning: wezTerm.scan = .notRunning
        case .unreadable(let reason): wezTerm.scan = .unreadable(reason)
        }
        recordHostTitles(reads.inventories, takenAt: takenAt)
        var diagnostics = ["scan: \(wezTerm.scan)",
                           "question digits: \(TerminalHost.wezTerm.typesQuestionDigits ? "on" : "off until proven live (#245)")"]
        var codexRoutes: [UUID: TerminalReplyRoute] = [:]
        var codexSeen: Set<UUID> = []
        var codexTargets: [UUID: TerminalTabTarget] = [:]
        for session in codexSessions.sorted(by: { $0.uuidString < $1.uuidString }) {
            // A scan's binding is for presentation and visits; Open and typed input re-run it on fresh
            // reads immediately before acting.
            let binding = wezTermCodexBinding(session, reads: reads)
            // A title decoy here, or one beside a session another host holds, is not this host's (#268).
            if let title = HerdrCodexBindingRules.title(forSession: session.uuidString.lowercased()),
               case .tabs(let tabs) = reads.wezTerm.inventory,
               TerminalTabOpen.codexStays(in: .wezTerm, carriesTitle: TerminalTabBindingRules.carriesCodexTitle(
                   tabs, title: title, processes: reads.processes), binding: binding) {
                codexSeen.insert(session)
            }
            if let route = TerminalReplyRoute.from(binding) { codexRoutes[session] = route }
            if case .bound(let target) = binding, target.host == .wezTerm { codexTargets[session] = target }
            diagnostics.append("Codex \(session.uuidString.lowercased().prefix(8)): \(binding)")
        }
        var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
        var claudeTargets: [AgentSessionIdentity: TerminalTabTarget] = [:]
        for (identity, process) in claude {
            let binding = wezTermClaudeBinding(identity, process: process, reads: reads)
            // A session Zellij holds or could hold keeps Zellij's route (#242): its pane has no tab here.
            if zellijClaudeBinding(identity, process: process, read: reads.zellij) == .notInZellij,
               let route = TerminalReplyRoute.from(binding) { claudeRoutes[identity] = route }
            if case .bound(let target) = binding, target.host == .wezTerm { claudeTargets[identity] = target }
            diagnostics.append("Claude \(identity.session.prefix(8)): \(binding)")
        }
        wezTerm.codexRoutes = codexRoutes
        wezTerm.claudeRoutes = claudeRoutes
        wezTerm.codexSeen = codexSeen
        if !codexTargets.isEmpty || !claudeTargets.isEmpty { wezTerm.inUse = true }
        for (session, line) in wezTerm.lastOpen.sorted(by: { $0.key < $1.key }) {
            diagnostics.append("\(session.prefix(8)): \(line)")
        }
        wezTerm.diagnostics = diagnostics

        // ADR 0016: one visit and dwell rule; only completions, only for the session's own bound pane.
        let reading: TerminalVisibilityReading<String> = frontmost == .wezTerm
            ? TerminalVisibility.wezTerm(reads.wezTerm.snapshot, clients: reads.clients, frontmost: frontmost)
            : .nothing
        wezTerm.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: reading))
        for (session, target) in codexTargets {
            let completions = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
            acknowledgeCodexCompletions(Array(wezTerm.visits.acknowledged(completions, target: target.tabID)))
        }
        for (identity, target) in claudeTargets {
            let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
            for id in wezTerm.visits.acknowledged(outcomes, target: target.tabID) { agentQueue.dismiss(.outcome(id)) }
        }
        saveCompletions()
    }

    private func wezTermCodexBinding(_ session: UUID, reads: WezTermTabReads) -> TerminalTabBinding {
        TerminalTabBindingRules.codex(sessionID: session.uuidString, liveness: endedSessions.contains(session) ? .ended : .live,
                                      liveSessions: Set(liveCLI.map(\.uuidString)), switches: hostSwitches,
                                      inventories: reads.inventories, processes: reads.processes,
                                      secondRead: reads.secondRead, multiplexerClientTTYs: reads.multiplexerClientTTYs)
    }

    private func wezTermClaudeBinding(_ identity: AgentSessionIdentity, process: ClaudeTabProcess,
                                      reads: WezTermTabReads) -> TerminalTabBinding {
        TerminalTabBindingRules.claude(sessionID: identity.session, liveness: .live, process: process.process,
                                       observed: process.observed, switches: hostSwitches,
                                       inventories: reads.inventories, processes: reads.processes)
    }

    // MARK: - Open (ADR 0015, ADR 0016)

    /// Open for a Codex CLI session while WezTerm is on. A session whose title no WezTerm pane carries is
    /// left to `otherwise` (Terminal.app, iTerm2 or Ghostty) when another host is on; an unreadable
    /// WezTerm keeps it here, where it is unavailable (ADR 0013).
    func openCodexWithWezTerm(_ session: UUID, otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask, let title = HerdrCodexBindingRules.title(forSession: session.uuidString.lowercased()) else { return }
        openingTask = true
        let others = wezTermOtherHosts
        let running = TerminalApps.isRunning(.wezTerm)
        let otherRouteOn = ghosttyEnabled || terminalAppSwitchedOn || hostSwitches.mayContact(.iTerm2)
        Task { @MainActor in
            let first = await Task.detached {
                WezTermTabReads.take(running: running, others: others, codexTitles: [title], claudeTTYs: [], second: false)
            }.value
            // A decoy pane here leaves a session whose tab is in another host to that host's route (#268).
            let holds = TerminalTabOpen.codexStays(in: .wezTerm, carriesTitle: first.carries(title: title),
                                                   binding: wezTermCodexBinding(session, reads: first))
            if TerminalAppOpen.leavesToOtherRoute(otherRouteOn: otherRouteOn, inventory: first.wezTerm.inventory,
                                                  holdsSession: holds) {
                openingTask = false
                otherwise()
                return
            }
            let latest = LatestWezTermReads()
            let run = await runWezTermOpen(codexTitle: title, revalidate: { [weak self] in
                let reads = await Task.detached {
                    WezTermTabReads.take(running: running, others: others, codexTitles: [title], claudeTTYs: [],
                                         second: true, clients: true)
                }.value
                latest.reads = reads
                guard let self else { return (.unavailable(.sessionEnded), reads) }
                return (self.wezTermCodexBinding(session, reads: reads), reads)
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
                // ADR 0015 amendment: walk from each titled pane's own `codex`; never a guess past a failed walk.
                result = await openResult(.miss(miss)) { _ in
                    let candidates = await Task.detached {
                        TerminalTabOpen.codexCandidates(carriers, walk: TerminalApps.walk(from:),
                                                        ttyWrittenAt: TerminalTTYReads.writtenAt)
                    }.value
                    return OpenFallback.codexApp(candidates: candidates, switches: switches)
                }
            }
            wezTerm.lastOpen[session.uuidString.lowercased()] = Self.wezTermDiagnostic(run, result: result)
            recordOpen(result, codex: session)
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// Open for a Claude CLI session while WezTerm is on. A session whose process tty no WezTerm pane holds
    /// is left to `otherwise` (Terminal.app, iTerm2, Ghostty's title route or the process walk).
    func openClaudeWithWezTerm(_ identity: AgentSessionIdentity, approval: AgentApproval?,
                               otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask else { return }
        openingTask = true
        let others = wezTermOtherHosts
        let running = TerminalApps.isRunning(.wezTerm)
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
                WezTermTabReads.take(running: running, others: others, codexTitles: [],
                                     claudeTTYs: Set([process.tty].compactMap { $0 }), second: false)
            }.value
            if TerminalAppOpen.leavesToOtherRoute(otherRouteOn: true, inventory: first.wezTerm.inventory,
                                                  holdsSession: process.tty.map(first.holds) ?? false) {
                openingTask = false
                otherwise()
                return
            }
            let preOpenAt = Date().timeIntervalSince1970
            let run = await runWezTermOpen(codexTitle: nil, revalidate: { [weak self] in
                let fresh = await Task.detached { () -> (ClaudeTabProcess, WezTermTabReads) in
                    let again = ClaudeTabProcess.read(rows)
                    return (again, WezTermTabReads.take(running: running, others: others, codexTitles: [],
                                                        claudeTTYs: Set([again.tty].compactMap { $0 }), second: false,
                                                        clients: true))
                }.value
                guard let self, !rows.isEmpty else { return (.unavailable(.sessionEnded), fresh.1) }
                return (self.wezTermClaudeBinding(identity, process: fresh.0, reads: fresh.1), fresh.1)
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
            wezTerm.lastOpen[identity.session] = Self.wezTermDiagnostic(run, result: result)
            recordOpen(result, claude: identity)
            if case .unavailable = result {} else {
                // ADR 0015: an Open on an actionable request hands it back with no decision, fallback included.
                if let approval,
                   let current = orderedAgentAttentionItems.compactMap(\.approval).first(where: { $0.id == approval.id }) {
                    handBackClaudeApproval(current)
                }
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

    /// ADR 0016's sequence with WezTerm's steps, each sent once. `revalidate` returns the binding re-run on
    /// fresh reads and the reads it used, whose `list-clients` names the front window.
    private func runWezTermOpen(codexTitle: String?,
                                revalidate: @escaping () async -> (TerminalTabBinding, WezTermTabReads))
        async -> TerminalOpenRun<WezTermOpenPlan, OpenMiss> {
        await WezTermOpen.run(
            now: { Date().timeIntervalSince1970 },
            revalidate: { _ in
                let (binding, reads) = await revalidate()
                switch reads.wezTerm {
                case .unreadable: return .failure(.unavailable(.hostUnreadable(.wezTerm)))
                case .notRunning: return .failure(TerminalTabOpen.miss(binding.unavailableReason ?? .titleNotFound))
                case .snapshot(let snapshot):
                    return WezTermOpen.plan(TerminalTabOpen.route(binding), codexTitle: codexTitle, snapshot: snapshot,
                                            clients: reads.clients)
                }
            },
            activate: { plan in
                let result = await Task.detached { WezTermNavigation.activate(plan.target) }.value
                // Then activate WezTerm as a whole; whether the pane shows is what verify reads back.
                if case .exited(0, _, _) = result { _ = TerminalApps.activate(.wezTerm) }
                return result
            },
            verifyRead: {
                let observed = await Task.detached { WezTermNavigation.read(running: true, clients: true) }.value
                return (observed.0.snapshot, observed.1, TerminalApps.frontmostHost())
            })
    }

    private static func wezTermDiagnostic(_ run: TerminalOpenRun<WezTermOpenPlan, OpenMiss>, result: TerminalOpenResult) -> String {
        switch run {
        case .opened: "Open: verified"
        case .failed(let miss, let step): "Open: \(result) after \(miss) at \(step)"
        }
    }

    // MARK: - Typed replies (ADR 0017)

    /// Types a Codex reply into the bound WezTerm pane, after the click's policy passed: a fresh check
    /// before every send, Codex's text then a separate CR a second later, nothing ever resent.
    func sendWezTermCodexReply(_ completion: AttentionCompletion, send: SessionReplySending.TerminalSend,
                               progress: SessionReplyProgress) {
        guard !terminalApp.replying else { return }
        terminalApp.replying = true
        replyProgress[completion.id] = progress
        refresh()
        let others = wezTermOtherHosts
        let rolloutRoot = Companion.rolloutRoot
        let title = HerdrCodexBindingRules.title(forSession: completion.session.uuidString.lowercased())
        Task { @MainActor in
            let run = await TypedReplySequence.run(
                writes: send.writes,
                check: { [weak self] in
                    guard let self else { return .notInQueue }
                    let running = TerminalApps.isRunning(.wezTerm)
                    let fresh = await Task.detached { () -> (WezTermTabReads, ReminderReader.RolloutEvidence) in
                        (WezTermTabReads.take(running: running, others: others, codexTitles: Set([title].compactMap { $0 }),
                                              claudeTTYs: [], second: true),
                         ReminderReader.currentEvidence(for: completion.session, in: rolloutRoot))
                    }.value
                    let route = TerminalReplyRoute.from(self.wezTermCodexBinding(completion.session, reads: fresh.0))
                    return TypedReplyCheck.veto(self.codexReplyState(completion, route: route, evidence: fresh.1), spent: send.pane)
                },
                write: { write in
                    let payload = WezTermInput.payload(write)
                    return WezTermInput.delivery(await Task.detached { WezTermNavigation.send(payload, into: send.pane) }.value)
                },
                pause: { seconds in try? await Task.sleep(for: .seconds(seconds)) })
            terminalApp.replying = false
            replyProgress[completion.id] = reply(for: completion).settling(run, at: Date().timeIntervalSince1970)
            refresh()
        }
    }

    /// One Send on a Claude card bound to a WezTerm pane: text and its CR in one `send-text`, after a fresh
    /// check. Shares Terminal.app's Claude reply memory, so one card still sends at most one reply.
    func sendWezTermClaudeReply(_ outcome: AgentOutcome, send: SessionReplySending.TerminalSend,
                                progress: ReplyProgress<AgentTurnIdentity>) {
        guard !terminalApp.replying else { return }
        terminalApp.replying = true
        terminalApp.claudeReplies[outcome.id] = progress.startingSend(text: send.writes.first.map(Self.replyText) ?? "",
                                                                      route: .terminal(send.pane))
        refresh()
        let others = wezTermOtherHosts
        let roots = configuredClaudeNavigationRoots().filter { $0.root.path == outcome.session.sourceScope }
        Task { @MainActor in
            let run = await TypedReplySequence.run(
                writes: send.writes,
                check: { [weak self] in
                    guard let self else { return .notInQueue }
                    let running = TerminalApps.isRunning(.wezTerm)
                    let fresh = await Task.detached { () -> (ClaudeInventorySession?, ClaudeTabProcess, WezTermTabReads)? in
                        let scans = roots.map { ClaudeSetupDetection.activeSessionInventory(root: $0.root, capabilities: $0.capabilities) }
                        guard scans.count == 1, scans[0].available else { return nil }
                        let rows = scans[0].sessions.filter { $0.kind == .interactive && $0.sessionID == outcome.session.session }
                        let process = ClaudeTabProcess.read(rows)
                        let reads = WezTermTabReads.take(running: running, others: others, codexTitles: [],
                                                         claudeTTYs: Set([process.tty].compactMap { $0 }), second: false)
                        return (rows.count == 1 ? rows[0] : nil, process, reads)
                    }.value
                    guard let fresh else { return .unreachable }
                    let route = TerminalReplyRoute.from(self.wezTermClaudeBinding(outcome.session, process: fresh.1, reads: fresh.2))
                    return TypedReplyCheck.veto(self.claudeReplyState(outcome, row: fresh.0, route: route), spent: send.pane)
                },
                write: { write in
                    let payload = WezTermInput.payload(write)
                    return WezTermInput.delivery(await Task.detached { WezTermNavigation.send(payload, into: send.pane) }.value)
                },
                pause: { seconds in try? await Task.sleep(for: .seconds(seconds)) })
            terminalApp.replying = false
            terminalApp.claudeReplies[outcome.id] = claudeReply(for: outcome).settling(run, at: Date().timeIntervalSince1970)
            refresh()
        }
    }

    private static func replyText(_ write: TypedWrite) -> String {
        switch write {
        case .text(let text), .textAndSubmit(let text): text
        case .submit: ""
        }
    }

    // MARK: - Codex question digits (ADR 0017; offered only once proven live)

    /// One click on a question whose session is bound to a pane of a host that types question digits
    /// (`.terminalRelay`). Reached only while that host's `typesQuestionDigits` is on; for WezTerm that
    /// waits for `WezTermInput.questionDigitsProvenLive` (#245). One digit, spent before it is sent, to the
    /// spent pane after a fresh binding on that same pane and a fresh rollout read showing the call
    /// pending; never Enter, never resent, never on a timer, retry or error.
    func answerThroughTerminalKeys(_ question: AttentionQuestion, question index: Int, option: Int) {
        guard !answering else { return }
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        // Later questions in a keyed call go to the pane the first key went to; the send rechecks it.
        let pane: TypedInputPane?
        if case let .terminal(spent)? = relayLedger.keyRoute(for: question.id) {
            pane = spent
        } else if wezTermSwitchedOn, case let .pane(bound)? = wezTerm.codexRoutes[question.session],
                  bound.host.typesQuestionDigits {
            pane = bound
        } else if let bound = tmuxQuestionKeyPane(for: question.session) {
            // tmux (#241), behind its own live-proof gate.
            pane = bound
        } else if let bound = zellijQuestionKeyPane(for: question.session) {
            // Zellij (#242), behind its own live-proof gate.
            pane = bound
        } else {
            pane = nil
        }
        let start: TerminalQuestionKeys.Start
        switch TerminalQuestionKeys.start(current: current, progress: progress(for: question), ledger: relayLedger,
                                          pane: pane, question: index, option: option) {
        case .failure(.policy):
            refresh(); return
        case .failure(.noPane):
            refresh(); return
        case .failure(.alreadySent):
            refresh(); return
        case let .success(value):
            start = value
        }
        // Unreachable in practice: `start` succeeded only for a queued question, and `pane` came from the
        // ledger or a WezTerm route whose host types digits. Kept as a last guard so nothing is sent to a
        // host without its send here, or in preview.
        // tmux's pane keys type through tmux's own send (#241).
        if let current, previewMode == nil, start.pane.host == .tmux, start.pane.host.typesQuestionDigits {
            sendTmuxQuestionKey(current, start: start, question: question, index: index, option: option)
            return
        }
        // Zellij's pane keys type through Zellij's own send (#242).
        if let current, previewMode == nil, start.pane.host == .zellij, start.pane.host.typesQuestionDigits {
            sendZellijQuestionKey(current, start: start, question: question, index: index, option: option)
            return
        }
        guard let current, previewMode == nil, start.pane.host == .wezTerm, start.pane.host.typesQuestionDigits else { return }
        answering = true
        relayLedger = start.ledger
        answerProgress[question.id] = start.progress
        updateRowNote(RowNote.codexKeySending(final: current.isFinalQuestion(index)), for: Self.rowNoteID(current),
                      userAction: true)
        refresh()
        let rolloutRoot = Companion.rolloutRoot
        let others = wezTermOtherHosts
        let running = TerminalApps.isRunning(.wezTerm)
        let switches = hostSwitches
        let liveIDs = Set(liveCLI.map(\.uuidString))
        let liveness: HerdrSessionLiveness = endedSessions.contains(current.session) ? .ended : .live
        let title = HerdrCodexBindingRules.title(forSession: current.session.uuidString.lowercased())
        Task { @MainActor in
            let outcome = await Task.detached { () -> HerdrQuestionRelay.Outcome in
                let reads = WezTermTabReads.take(running: running, others: others, codexTitles: Set([title].compactMap { $0 }),
                                                 claudeTTYs: [], second: true)
                let binding = TerminalTabBindingRules.codex(sessionID: current.session.uuidString, liveness: liveness,
                                                            liveSessions: liveIDs, switches: switches,
                                                            inventories: reads.inventories, processes: reads.processes,
                                                            secondRead: reads.secondRead,
                                                            multiplexerClientTTYs: reads.multiplexerClientTTYs)
                // The rollout last, as of this instant: a manual answer Codex already recorded, or an ended
                // turn, sends nothing.
                let evidence = ReminderReader.currentEvidence(for: current.session, in: rolloutRoot)
                if let veto = TerminalQuestionKeys.preSendCheck(question: current, evidence: evidence,
                                                                route: TerminalReplyRoute.from(binding), spent: start.pane) {
                    return .vetoed(veto)
                }
                let delivery = WezTermInput.delivery(WezTermNavigation.send(start.key, into: start.pane))
                return .delivered(TerminalQuestionKeys.delivery(delivery))
            }.value
            answering = false
            updateRowNote(RowNote.codexKeyAnswer(outcome, final: current.isFinalQuestion(index)), for: Self.rowNoteID(current))
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

    var wezTermSettingsRow: WezTermSettingsRow {
        WezTermPresentation.settingsRow(on: hostSwitches.isOn(.wezTerm), installed: wezTerm.installed,
                                        scan: wezTerm.scan, inUse: wezTerm.inUse)
    }
}

/// The latest reads a WezTerm Open's revalidation took, for the fallback's candidate walks.
@MainActor
private final class LatestWezTermReads {
    var reads: WezTermTabReads?
}
