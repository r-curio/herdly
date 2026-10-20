import AppKit
import HerdlyCore

// tmux (#241): the two-second binding and visit scan, ADR 0014's two-layer Open with ADR 0015's
// fallback, replies typed into the bound pane (ADR 0017), and the question-digit relay, built but off
// until its live proof (`TmuxInput.questionDigitsProvenLive`). Everything runs only while tmux may
// be contacted (its switch and a terminal on); the switch and card stay hidden until acceptance (#246).
// Rules are HerdlyCore's (`Tmux.swift`, `TmuxTargeting.swift`, `TmuxInput.swift`,
// `MultiplexerHostTab.swift`); this file reads, sends and schedules. Commands go through `TmuxRunner`.

/// tmux state held by the companion. Main-actor only; memory only.
@MainActor
final class TmuxState: ObservableObject {
    /// The latest read of the default server; nil before one, and whenever tmux may not be contacted.
    @Published var read: TmuxRead?
    /// A scan has bound a session to a tmux pane since the switch went on (the card's In use).
    @Published var sessionsSeen = false
    /// A live Claude session runs under a tmux server on another socket (the card's line).
    @Published var otherSocketSeen = false
    /// Each queued Codex session's typed route, from the latest scan, for sessions tmux holds or could
    /// hold (an unreadable server).
    var codexRoutes: [UUID: TerminalReplyRoute] = [:]
    var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
    /// Codex sessions whose title a tmux pane carried in the latest scan.
    var codexSeen: Set<UUID> = []
    /// ADR 0016's visit interval and dwell run over tmux panes, by `%pane`.
    var visits = TerminalVisitTracker<String>()
    var scanning = false
    var nextScan: Double = 0
    /// Bumped on every switch change, so a scan started before it applies to nothing.
    var generation = 0
    /// The exact internal reasons, for the card's diagnostics only.
    var diagnostics: [String] = []
}

/// What a multiplexer Open's steps saw (tmux's, or herdr's in a host other than Ghostty), kept for
/// later steps and the fallback decision.
@MainActor
final class MultiplexerOpenRecord {
    var reads: TerminalTabReads?
    /// The panes whose sessions' clients a fallback walks: the bound pane, or every pane carrying the
    /// session's title (Codex) or its process's tty (Claude).
    var panes: Set<String> = []
    /// Ghostty's matched tab and `tty` support, when the client's host is a Ghostty (ADR 0011).
    var ghostty: (target: GhosttyTarget, support: GhosttyTTYSupport)?
    /// WezTerm's plan, when the client's host is a WezTerm pane (#240's Open).
    var wezTerm: WezTermOpenPlan?
}

extension Companion {
    /// tmux may be read and contacted: its switch and a terminal are on (ADR 0014, "Gate").
    var tmuxContactAllowed: Bool { previewMode == nil && hostSwitches.mayContact(.tmux) }

    /// The switch moved (`setHostSwitch`), or a terminal's switch did: forget every scan result.
    func tmuxSwitchChanged(_ on: Bool) {
        tmux.generation += 1
        tmux.read = nil
        tmux.codexRoutes = [:]
        tmux.claudeRoutes = [:]
        tmux.codexSeen = []
        tmux.nextScan = 0
        tmux.otherSocketSeen = false
        if !on { tmux.sessionsSeen = false }
        tmux.visits.reset(at: Date().timeIntervalSince1970)
    }

    /// Writes one typed-input write into `pane` by its host's own send. Blocking: call off the main
    /// actor. A host without a send in this build writes nothing. `tmuxServer` and `zellijServer` are the
    /// servers the fresh check read; a tmux or Zellij send goes only to it, and a Zellij send only after
    /// the pane is re-read (`ZellijRunner.send`).
    nonisolated static func typeInto(_ pane: TypedInputPane, _ write: TypedWrite, tmuxServer: TmuxServerIdentity? = nil,
                                     zellijServer: ZellijServerIdentity? = nil) -> TypedInputDelivery {
        switch pane.host {
        case .terminalApp:
            return TerminalAppInput.delivery(TerminalAppNavigation.type(TerminalAppInput.script(write), into: pane))
        case .tmux:
            return TmuxInput.delivery(TmuxRunner.send(TmuxInput.arguments(write, into: pane), expecting: tmuxServer))
        case .zellij:
            guard let target = ZellijPaneTarget(handle: pane.paneID),
                  let arguments = ZellijInput.arguments(write, into: pane) else { return .notWritten }
            return ZellijInput.delivery(ZellijRunner.send(arguments, to: target, expecting: zellijServer))
        case .ghostty, .iTerm2, .wezTerm, .herdr:
            return .notWritten
        }
    }

    // MARK: - Scan (bindings, routes, visits, card)

    /// Claude CLI sessions with queued outcomes and their inventory rows.
    private var tmuxClaudeRows: [AgentSessionIdentity: [ClaudeInventorySession]] {
        let identities = Set(agentQueue.snapshot.outcomes.map(\.session).filter { $0.source == .claude && $0.surface == .cli })
        var result: [AgentSessionIdentity: [ClaudeInventorySession]] = [:]
        for identity in identities {
            result[identity] = (claudeInventories[identity.sourceScope]?.sessions ?? [])
                .filter { $0.kind == .interactive && $0.sessionID == identity.session }
        }
        return result
    }

    /// tmux's part of the shared scheduled read (`checkScheduledTabHosts`): while tmux may be
    /// contacted, is not scanning, and a session could be bound there.
    func tmuxScanPlan() -> TmuxScanPlan? {
        guard tmuxContactAllowed else {
            if tmux.read != nil { tmuxSwitchChanged(hostSwitches.isOn(.tmux)) }
            return nil
        }
        guard !tmux.scanning, !openingTask else { return nil }
        let codexSessions = Set(cliItems.map(\.session)).union(queue.items.compactMap { item in
            item.question.flatMap { $0.source == .cli ? $0.session : nil }
        })
        let claudeRows = tmuxClaudeRows
        // Live Claude processes, for the card's other-socket line only.
        let livePIDs = liveClaudeSessions.flatMap { scope, sessions in
            (claudeInventories[scope]?.sessions ?? []).filter { $0.kind == .interactive && sessions.contains($0.sessionID) }
                .compactMap(\.pid)
        }
        guard !codexSessions.isEmpty || !claudeRows.isEmpty || !livePIDs.isEmpty || !liveCLI.isEmpty else { return nil }
        return TmuxScanPlan(codexSessions: codexSessions, claudeRows: claudeRows, livePIDs: livePIDs,
                            generation: tmux.generation)
    }

    /// Applies the shared read to tmux, unless its switch or generation moved meanwhile.
    func finishTmuxScan(_ plan: TmuxScanPlan, reads: TerminalTabReads, claude: [AgentSessionIdentity: ClaudeTabProcess],
                        processes: [TmuxSessionProcess], hostFront: TerminalVisibilityReading<String>, takenAt: Double) {
        tmux.scanning = false
        guard plan.generation == tmux.generation, tmuxContactAllowed else { return }
        applyTmuxScan(reads, claude: claude.filter { plan.claudeRows[$0.key] != nil }, codexSessions: plan.codexSessions,
                      processes: processes, hostFront: hostFront, takenAt: takenAt)
    }

    /// The tty of the frontmost enabled host's visible tab (ADR 0016), from reads already taken. A host
    /// that is off, or another app in front, shows nothing.
    nonisolated static func hostFront(_ reads: TerminalTabReads, frontmost: TerminalHost?,
                                      onScreen: Set<Int>?) -> TerminalVisibilityReading<String> {
        guard let frontmost, reads.inventories[frontmost] != nil else { return .nothing }
        switch frontmost {
        case .iTerm2: return MultiplexerHostFront.iTerm2(reads.iTerm2, frontmost: frontmost)
        case .terminalApp:
            return MultiplexerHostFront.terminalApp(reads.terminalApp.snapshot, frontmost: frontmost, onScreenWindowIDs: onScreen)
        case .ghostty: return MultiplexerHostFront.ghostty(reads.ghostty, frontmost: frontmost)
        case .wezTerm: return MultiplexerHostFront.wezTerm(reads.wezTerm, clients: reads.wezTermClients, frontmost: frontmost)
        case .tmux, .zellij, .herdr: return .unknown
        }
    }

    private func applyTmuxScan(_ reads: TerminalTabReads, claude: [AgentSessionIdentity: ClaudeTabProcess],
                               codexSessions: Set<UUID>, processes: [TmuxSessionProcess],
                               hostFront: TerminalVisibilityReading<String>, takenAt: Double) {
        tmux.read = reads.tmux
        recordHostTitles(reads.inventories, takenAt: takenAt)
        let snapshot = reads.tmux.snapshot
        let unreadable = reads.tmux.inventory == .unreadable
        var diagnostics = ["tmux: \(Self.tmuxDiagnostic(reads.tmux))"]
        var codexRoutes: [UUID: TerminalReplyRoute] = [:]
        var codexSeen: Set<UUID> = []
        var codexTargets: [UUID: String] = [:]
        for session in codexSessions {
            let binding = codexBinding(session, reads: reads)
            let title = GhosttyMatch.title(session)
            // A title decoy pane, or one beside a session another host holds, is not tmux's (#268).
            let carried: Bool
            if case .tabs(let panes) = reads.tmux.inventory {
                carried = TerminalTabOpen.codexStays(in: .tmux, carriesTitle: TerminalTabBindingRules.carriesCodexTitle(
                    panes, title: title, processes: reads.processes), binding: binding)
            } else {
                carried = false
            }
            if carried { codexSeen.insert(session) }
            let boundHere: Bool
            if case .bound(let target) = binding, target.host == .tmux { boundHere = true; codexTargets[session] = target.tabID }
            else { boundHere = false }
            if boundHere || carried || unreadable || binding == .unavailable(.hostUnreadable(.tmux)) {
                codexRoutes[session] = TmuxInput.route(binding, snapshot: snapshot) ?? .unreachable
            }
            diagnostics.append("Codex \(session.uuidString.lowercased()): \(binding)")
        }
        var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
        var claudeTargets: [AgentSessionIdentity: String] = [:]
        for (identity, process) in claude {
            let binding = claudeBinding(identity, process: process, reads: reads)
            let inPane = process.tty.map { tty in snapshot?.panes.contains { $0.tty == tty } == true } ?? false
            var boundHere = false
            if case .bound(let target) = binding, target.host == .tmux { boundHere = true; claudeTargets[identity] = target.tabID }
            if boundHere || inPane || unreadable || binding == .unavailable(.hostUnreadable(.tmux)) {
                claudeRoutes[identity] = TmuxInput.route(binding, snapshot: snapshot) ?? .unreachable
            }
            diagnostics.append("Claude \(identity.session): \(binding)")
        }
        tmux.codexRoutes = codexRoutes
        tmux.claudeRoutes = claudeRoutes
        tmux.codexSeen = codexSeen
        if !codexTargets.isEmpty || !claudeTargets.isEmpty { tmux.sessionsSeen = true }
        let defaultPaneTTYs: Set<String>? = reads.tmux == .notRunning ? [] : snapshot.map { Set($0.panes.map(\.tty)) }
        let otherSocket = TmuxPresentation.otherSocketSeen(processes, defaultPaneTTYs: defaultPaneTTYs)
        if tmux.otherSocketSeen != otherSocket { tmux.otherSocketSeen = otherSocket }
        tmux.diagnostics = diagnostics

        // ADR 0016: one visit and dwell rule; only completions, only for the session's own bound pane.
        tmux.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: TmuxVisibility.reading(snapshot, hostFront: hostFront)))
        for (session, pane) in codexTargets {
            let completions = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
            acknowledgeCodexCompletions(Array(tmux.visits.acknowledged(completions, target: pane)))
        }
        for (identity, pane) in claudeTargets {
            let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
            for id in tmux.visits.acknowledged(outcomes, target: pane) { agentQueue.dismiss(.outcome(id)) }
        }
        saveCompletions()
    }

    private static func tmuxDiagnostic(_ read: TmuxRead) -> String {
        switch read {
        case .notRunning: "default server not running"
        case .binaryNotFound: "tmux not found"
        case .untrustedSocket: "default socket untrusted"
        case .unreadable: "unreadable"
        case .snapshot(let snapshot): "\(snapshot.panes.count) panes, \(snapshot.clients.count) clients"
        }
    }

    // MARK: - Open (ADR 0014 "Open sequence", ADR 0015, ADR 0016)

    /// Open for a Codex CLI session while tmux may be contacted. A session whose title no pane of the
    /// default server carries is left to the other routes, as is everything while that server is not
    /// running. An unreadable server keeps the session here, where it is unavailable (ADR 0013).
    func openCodexWithTmux(_ session: UUID, otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask else { return }
        openingTask = true
        navigationMessage = "Finding the matching tmux pane…"
        let title = GhosttyMatch.title(session)
        Task { @MainActor in
            let first = await Task.detached { TmuxRunner.read() }.value
            if first == .notRunning || first.snapshot.map({ !$0.panes.contains { $0.title == title } }) == true {
                openingTask = false
                otherwise()
                return
            }
            let others = otherTabHosts
            // A decoy pane here leaves a session whose tab is in another host to the other routes (#268).
            let across = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: false) }.value
            if !TerminalTabOpen.codexStays(in: .tmux, carriesTitle: true, binding: codexBinding(session, reads: across)) {
                openingTask = false
                otherwise()
                return
            }
            let record = MultiplexerOpenRecord()
            let result = await runTmuxOpen(agent: .codex, record: record, revalidate: { [weak self] in
                let reads = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: true) }.value
                record.panes = Set(reads.tmux.snapshot?.panes.filter { $0.title == title }.map(\.paneID) ?? [])
                return (reads, self?.codexBinding(session, reads: reads) ?? .unavailable(.sessionEnded))
            }, rebind: { [weak self] reads in self?.codexBinding(session, reads: reads) ?? .unavailable(.sessionEnded) })
            if case .opened(let preOpenAt) = result {
                let queued = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
                let acknowledged = TerminalVisitAcknowledgment.afterOpen(queued, result: .opened, preOpenAt: preOpenAt)
                if !acknowledged.isEmpty { acknowledgeCodexCompletions(Array(acknowledged)); saveCompletions() }
            }
            navigationMessage = message(for: result.open, opened: "Opened the matching tmux pane.")
            recordOpen(result.open, codex: session)
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// Open for a Claude CLI session while tmux may be contacted. A session whose process's tty is no
    /// pane of the default server is left to the other routes.
    func openClaudeWithTmux(_ identity: AgentSessionIdentity, approval: AgentApproval?,
                            otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask else { return }
        openingTask = true
        navigationMessage = "Finding the matching tmux pane…"
        let roots = configuredClaudeNavigationRoots()
        Task { @MainActor in
            let rows = await Task.detached { () -> [ClaudeInventorySession]? in
                let scans = roots.map { ClaudeSetupDetection.activeSessionInventory(root: $0.root, capabilities: $0.capabilities) }
                guard !scans.isEmpty, scans.allSatisfy(\.available) else { return nil }
                return scans.flatMap { $0.sessions.filter { $0.kind == .interactive && $0.sessionID == identity.session } }
            }.value
            guard let rows else {
                openingTask = false
                navigationMessage = claudeReturnUnavailableMessage
                refresh()
                return
            }
            let first = await Task.detached { (ClaudeTabProcess.read(rows), TmuxRunner.read()) }.value
            if first.1 == .notRunning
                || first.1.snapshot.map({ snapshot in !snapshot.panes.contains { $0.tty == first.0.tty } }) == true {
                openingTask = false
                otherwise()
                return
            }
            let others = otherTabHosts
            let record = MultiplexerOpenRecord()
            final class Latest { var process: ClaudeTabProcess? }
            let latest = Latest()
            let result = await runTmuxOpen(agent: .claude, record: record, revalidate: { [weak self] in
                let fresh = await Task.detached { () -> (ClaudeTabProcess, TerminalTabReads) in
                    let process = ClaudeTabProcess.read(rows)
                    return (process, TerminalTabReads.take(others: others, claudeTTYs: Set([process.tty].compactMap { $0 }),
                                                           second: false))
                }.value
                latest.process = fresh.0
                record.panes = Set(fresh.1.tmux.snapshot?.panes.filter { $0.tty == fresh.0.tty }.map(\.paneID) ?? [])
                guard let self, !rows.isEmpty else { return (fresh.1, .unavailable(.sessionEnded)) }
                return (fresh.1, self.claudeBinding(identity, process: fresh.0, reads: fresh.1))
            }, rebind: { [weak self] reads in
                guard let self, let process = latest.process else { return .unavailable(.sessionEnded) }
                return self.claudeBinding(identity, process: process, reads: reads)
            })
            navigationMessage = message(for: result.open, opened: "Opened the matching tmux pane.")
            recordOpen(result.open, claude: identity)
            if case .unavailable = result.open {} else {
                // ADR 0015: an Open on an actionable request hands it back with no decision, fallback included.
                if let approval,
                   let current = orderedAgentAttentionItems.compactMap(\.approval).first(where: { $0.id == approval.id }) {
                    handBackClaudeApproval(current)
                }
                if case .opened(let preOpenAt) = result {
                    let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
                    for id in TerminalVisitAcknowledgment.afterOpen(outcomes, result: .opened, preOpenAt: preOpenAt) {
                        agentQueue.dismiss(.outcome(id))
                    }
                    saveCompletions()
                }
            }
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// How a tmux Open ended: verified (with its pre-Open time) or resolved by ADR 0015.
    enum TmuxOpenEnd {
        case opened(preOpenAt: Double)
        case other(TerminalOpenResult)

        var open: TerminalOpenResult {
            if case .other(let result) = self { return result }
            return .opened
        }
    }

    /// ADR 0014's sequence: revalidate both layers, `switch-client` once, verify the pane on a fresh
    /// read, then raise and verify the host tab with that host's Open. A failure falls back by walking
    /// the session's clients to their app (ADR 0015) or stays unavailable; nothing is rolled back.
    private func runTmuxOpen(agent: AgentSource, record: MultiplexerOpenRecord,
                             revalidate: @escaping @MainActor () async -> (TerminalTabReads, TerminalTabBinding),
                             rebind: @escaping @MainActor (TerminalTabReads) -> TerminalTabBinding) async -> TmuxOpenEnd {
        let switches = hostSwitches
        let run = await TmuxOpen.run(
            now: { Date().timeIntervalSince1970 },
            revalidate: {
                let (reads, binding) = await revalidate()
                record.reads = reads
                if case .bound(let target) = binding, target.host == .tmux { record.panes = [target.tabID] }
                guard let snapshot = reads.tmux.snapshot else {
                    return .failure(TerminalTabOpen.miss(binding.unavailableReason ?? .hostUnreadable(.tmux)))
                }
                return TmuxOpen.plan(binding, snapshot: snapshot, join: {
                    MultiplexerHostTab.join(clientTTY: $0, switches: switches, inventories: reads.inventories)
                })
            },
            focus: { plan in
                let server = record.reads?.tmux.snapshot?.server
                return TmuxOpen.focused(await Task.detached {
                    TmuxRunner.send(TmuxOpen.focusArguments(plan), expecting: server)
                }.value)
            },
            verifyPane: { plan in
                let fresh = await Task.detached { TmuxRunner.read() }.value
                guard let reads = record.reads else { return .fallBack(.notVerified, candidates: 1) }
                var inventories = reads.inventories
                inventories[.tmux] = fresh.inventory
                let rebound = TerminalTabReads(terminalApp: reads.terminalApp, inventories: inventories,
                                               processes: reads.processes, secondRead: inventories, tmux: fresh,
                                               zellij: reads.zellij, ghostty: reads.ghostty, iTerm2: reads.iTerm2)
                return TmuxOpen.verifyPane(plan, read: fresh, binding: rebind(rebound))
            },
            raise: { [weak self] plan in
                await self?.raiseHostTab(plan.host, clientTTY: plan.client.tty, record: record) ?? .unavailable(.sessionEnded)
            },
            verifyHost: { [weak self] plan in
                await self?.verifyHostTab(plan.host, clientTTY: plan.client.tty, record: record) ?? .unavailable(.sessionEnded)
            })
        switch run {
        case .opened(_, let preOpenAt):
            return .opened(preOpenAt: preOpenAt)
        case .failed(let miss, _):
            let snapshot = record.reads?.tmux.snapshot
            let pids = Array(Set(record.panes.flatMap { TmuxOpen.fallbackClientPIDs(for: $0, in: snapshot) })).sorted()
            let result = await openResult(.miss(miss)) { _ in
                let walks = await Task.detached { pids.map(TerminalApps.walk(from:)) }.value
                return OpenFallback.processApp(walks: walks, agent: agent, switches: switches)
            }
            return .other(result)
        }
    }

    /// ADR 0014 step 4 for any multiplexer: the host tab's own select and raise, once. Terminal.app's tab
    /// must be alone in its window; a WezTerm pane must be in the focused window, as WezTerm's Open requires.
    /// `requiredTitlePrefix` is Zellij's host-title veto for the tab Ghostty's own join chooses here (the
    /// other hosts' tabs were checked when the plan was made).
    func raiseHostTab(_ host: MultiplexerHostTarget, clientTTY: String, record: MultiplexerOpenRecord,
                      requiredTitlePrefix: String? = nil) async -> OpenMiss? {
        switch host {
        case .tab(let target):
            switch target.host {
            case .iTerm2:
                return ITerm2Open.selection(await Task.detached {
                    ITerm2Navigation.select(ITerm2OpenPlan(target: target, title: nil))
                }.value)
            case .terminalApp:
                guard let snapshot = record.reads?.terminalApp.snapshot, let window = Int(target.tabID),
                      snapshot.tabsInWindow(window) == 1 else { return .fallBack(.unsupportedLayout, candidates: 1) }
                return TerminalAppOpen.raised(await Task.detached { TerminalAppNavigation.raise(target) }.value)
            case .wezTerm:
                let read = await Task.detached { WezTermNavigation.read(running: true, clients: true) }.value
                guard let snapshot = read.0.snapshot else { return .unavailable(.hostUnreadable(.wezTerm)) }
                let plan: WezTermOpenPlan
                switch WezTermOpen.plan(.exact(target), codexTitle: nil, snapshot: snapshot, clients: read.1) {
                case .failure(let miss): return miss
                case .success(let value): plan = value
                }
                record.wezTerm = plan
                let result = await Task.detached { WezTermNavigation.activate(target) }.value
                if let miss = WezTermOpen.activated(result) { return miss }
                _ = TerminalApps.activate(.wezTerm)
                return nil
            case .ghostty, .tmux, .zellij, .herdr:
                return .fallBack(.unsupportedLayout, candidates: 1)
            }
        case .ghostty:
            let tty = clientTTY
            let observed = await Task.detached { (GhosttyScriptingSupport.ttySupport(), GhosttyNavigation.snapshot()) }.value
            guard let snapshot = observed.1 else { return .unavailable(.hostUnreadable(.ghostty)) }
            let join = GhosttyTTYMatch.join(clientTTY: tty, support: observed.0, snapshot: snapshot)
            guard case .matched(let target) = join else {
                return HerdrOpenFallback.reason(for: join).map { .fallBack($0, candidates: 1) }
                    ?? .unavailable(.hostUnreadable(.ghostty))
            }
            if let requiredTitlePrefix, snapshot.terminalName(target)?.hasPrefix(requiredTitlePrefix) != true {
                return .fallBack(.noUniqueTarget, candidates: 1)
            }
            record.ghostty = (target, observed.0)
            let selected = await Task.detached { GhosttyNavigation.selectHerdrTab(target: target, tty: tty) }.value
            return selected ? nil : .fallBack(.notVerified, candidates: 1)
        }
    }

    /// ADR 0014 step 5 for any multiplexer: the host tab visible by that host's own test, with the tty
    /// join unchanged.
    func verifyHostTab(_ host: MultiplexerHostTarget, clientTTY: String, record: MultiplexerOpenRecord) async -> OpenMiss? {
        switch host {
        case .tab(let target):
            switch target.host {
            case .iTerm2:
                let reading = await Task.detached { ITerm2Navigation.snapshot() }.value
                var after: ITerm2Snapshot?
                if case .snapshot(let value)? = reading { after = value }
                return ITerm2Open.verify(ITerm2OpenPlan(target: target, title: nil), after: after,
                                         frontmost: TerminalApps.frontmostHost())
            case .terminalApp:
                let frontmost = TerminalApps.frontmostHost()
                let pid = TerminalAppNavigation.pid()
                let observed = await Task.detached {
                    (TerminalAppNavigation.snapshot().snapshot, TerminalAppNavigation.onScreenWindowIDs(pid: pid))
                }.value
                return TerminalAppOpen.verified(target, snapshot: observed.0, frontmost: frontmost, onScreenWindowIDs: observed.1)
            case .wezTerm:
                guard let plan = record.wezTerm else { return .fallBack(.notVerified, candidates: 1) }
                let read = await Task.detached { WezTermNavigation.read(running: true, clients: true) }.value
                return WezTermOpen.verify(plan, after: read.0.snapshot, clients: read.1, frontmost: TerminalApps.frontmostHost())
            case .ghostty, .tmux, .zellij, .herdr:
                return .fallBack(.notVerified, candidates: 1)
            }
        case .ghostty:
            guard let matched = record.ghostty else { return .fallBack(.notVerified, candidates: 1) }
            let snapshot = await Task.detached { GhosttyNavigation.snapshot() }.value
            guard let snapshot,
                  GhosttyTTYMatch.join(clientTTY: clientTTY, support: matched.support, snapshot: snapshot)
                    == .matched(matched.target),
                  snapshot.selected == matched.target, snapshot.front_window_id == matched.target.window_id else {
                return .fallBack(.notVerified, candidates: 1)
            }
            return nil
        }
    }

    // MARK: - Question digits (ADR 0017; off until the live proof)

    /// The bound tmux pane a Codex question's digit may be typed into, from the latest scan; nil while
    /// tmux's digit is not proven live (`TmuxInput.questionDigitsProvenLive`), so the shared route offers
    /// no key and the card says "Answer this in Codex."
    func tmuxQuestionKeyPane(for session: UUID) -> TypedInputPane? {
        guard tmuxContactAllowed, case .pane(let pane)? = tmux.codexRoutes[session], pane.host == .tmux,
              pane.host.typesQuestionDigits else { return nil }
        return pane
    }

    /// The tmux send behind the shared pane-key route (`answerThroughTerminalKeys`, ADR 0017), after
    /// `TerminalQuestionKeys.start` spent the key: immediately before it, the binding is re-run on fresh
    /// reads of every enabled host, the pane must be out of copy mode (`TmuxInput.route`), and the rollout
    /// is re-read last. One digit with `send-keys -l`, never Enter; a key that may have been written counts
    /// as sent and is never resent.
    func sendTmuxQuestionKey(_ current: AttentionQuestion, start: TerminalQuestionKeys.Start,
                             question: AttentionQuestion, index: Int, option: Int) {
        answering = true
        relayLedger = start.ledger
        answerProgress[question.id] = start.progress
        navigationMessage = "Sending \(start.key)…"
        refresh()
        let others = otherTabHosts
        let rolloutRoot = Companion.rolloutRoot
        Task { @MainActor in
            let reads = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: true) }.value
            let route = TmuxInput.route(codexBinding(current.session, reads: reads), snapshot: reads.tmux.snapshot)
            let outcome = await Task.detached { () -> HerdrQuestionRelay.Outcome in
                // The rollout last, as of this instant: a manual answer Codex already recorded, or an ended
                // turn, sends nothing.
                let evidence = ReminderReader.currentEvidence(for: current.session, in: rolloutRoot)
                if let veto = TerminalQuestionKeys.preSendCheck(question: current, evidence: evidence, route: route,
                                                                spent: start.pane) {
                    return .vetoed(veto)
                }
                let delivery = TmuxInput.delivery(TmuxRunner.send(TmuxInput.digitArguments(start.key, into: start.pane),
                                                                  expecting: reads.tmux.snapshot?.server))
                return .delivered(TerminalQuestionKeys.delivery(delivery))
            }.value
            answering = false
            switch outcome {
            case let .delivered(delivery) where delivery.countsAsSent: navigationMessage = "Sent \(start.key) as a key."
            case let .vetoed(reason): navigationMessage = reason.message
            case .delivered: navigationMessage = "Could not send the key; nothing was sent. Answer in Codex."
            }
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

    var tmuxSettingsRow: TmuxSettingsRow {
        TmuxPresentation.settingsRow(on: hostSwitches.isOn(.tmux), anyTerminalOn: hostSwitches.anyTerminalOn,
                                     read: tmux.read, sessionsSeen: tmux.sessionsSeen, otherSocketSeen: tmux.otherSocketSeen)
    }
}
