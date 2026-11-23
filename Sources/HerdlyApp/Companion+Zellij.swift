import AppKit
import HerdlyCore

// Zellij (#242): the two-second binding and visit scan, ADR 0014's two-layer Open with ADR 0015's
// fallback, replies typed into the bound pane (ADR 0017), and the question-digit relay, on since its
// live proof (`ZellijInput.questionDigitsProvenLive`, #247). Everything runs only while Zellij may
// be contacted (its switch and a terminal on); the card is shown since Zellij's acceptance (#247).
// Rules are HerdlyCore's (`Zellij.swift`, `ZellijTargeting.swift`, `ZellijInput.swift`,
// `MultiplexerHostTab.swift`); this file reads, sends and schedules. Commands go through `ZellijRunner`.

/// Zellij state held by the companion. Main-actor only; memory only.
@MainActor
final class ZellijState: ObservableObject {
    /// The latest read of the default socket directory; nil before one, and whenever Zellij may not be contacted.
    @Published var read: ZellijRead?
    /// A scan has bound a session to a Zellij pane since the switch went on (the card's In use).
    @Published var sessionsSeen = false
    /// Each queued Codex session's typed route, from the latest scan, for sessions Zellij holds or could
    /// hold (an unreadable Zellij).
    var codexRoutes: [UUID: TerminalReplyRoute] = [:]
    var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
    /// Codex sessions whose title a Zellij pane carried in the latest scan.
    var codexSeen: Set<UUID> = []
    /// ADR 0016's visit interval and dwell run over Zellij panes, by pane handle (`<session>/terminal_<n>`).
    var visits = TerminalVisitTracker<String>()
    var scanning = false
    var nextScan: Double = 0
    /// Bumped on every switch change, so a scan started before it applies to nothing.
    var generation = 0
    /// The exact internal reasons, for the card's diagnostics only.
    var diagnostics: [String] = []
}

extension Companion {
    /// Zellij may be read and contacted: its switch and a terminal are on (ADR 0014, "Gate").
    var zellijContactAllowed: Bool { previewMode == nil && hostSwitches.mayContact(.zellij) }

    /// The switch moved (`setHostSwitch`), or a terminal's switch did: forget every scan result.
    func zellijSwitchChanged(_ on: Bool) {
        zellij.generation += 1
        zellij.read = nil
        zellij.codexRoutes = [:]
        zellij.claudeRoutes = [:]
        zellij.codexSeen = []
        zellij.nextScan = 0
        if !on { zellij.sessionsSeen = false }
        zellij.visits.reset(at: Date().timeIntervalSince1970)
    }

    // MARK: - Bindings and typed routes

    /// ADR 0014's Codex rule over fresh reads of every enabled host, Zellij's included.
    func zellijCodexBinding(_ session: UUID, reads: TerminalTabReads) -> ZellijBinding {
        guard zellijContactAllowed else { return .notInZellij }
        return ZellijBindingRules.codex(sessionID: session.uuidString,
                                        liveness: endedSessions.contains(session) ? .ended : .live,
                                        liveSessions: Set(liveCLI.map(\.uuidString)), switches: contactSwitches,
                                        inventories: reads.inventories, processes: reads.processes,
                                        secondRead: reads.secondRead, multiplexerClientTTYs: reads.multiplexerClientTTYs,
                                        zellij: reads.zellij.snapshot)
    }

    /// ADR 0014's Claude rule: the session's newest hook records and its registered process over `read`.
    func zellijClaudeBinding(_ identity: AgentSessionIdentity, process: ClaudeTabProcess, read: ZellijRead?) -> ZellijBinding {
        guard zellijContactAllowed else { return .notInZellij }
        return ZellijBindingRules.claude(sessionID: identity.session, liveness: .live,
                                         newestRecords: newestHookRecords(forClaudeSession: identity.session),
                                         process: process.process, observed: process.observed, zellij: read)
    }

    /// The typed route for a Codex session from fresh reads: its Zellij pane when Zellij binds it (or
    /// unreachable when Zellij could hold it but cannot bind it), otherwise tmux's or another host's.
    func codexTypedRoute(_ session: UUID, reads: TerminalTabReads) -> TerminalReplyRoute? {
        if let route = ZellijInput.route(zellijCodexBinding(session, reads: reads), snapshot: reads.zellij.snapshot) {
            return route
        }
        return TmuxInput.route(codexBinding(session, reads: reads), snapshot: reads.tmux.snapshot)
    }

    /// The typed route for a Claude session, as `codexTypedRoute`.
    func claudeTypedRoute(_ identity: AgentSessionIdentity, process: ClaudeTabProcess, reads: TerminalTabReads) -> TerminalReplyRoute? {
        if let route = ZellijInput.route(zellijClaudeBinding(identity, process: process, read: reads.zellij),
                                         snapshot: reads.zellij.snapshot) {
            return route
        }
        return TmuxInput.route(claudeBinding(identity, process: process, reads: reads), snapshot: reads.tmux.snapshot)
    }

    /// The server of the Zellij session `pane` is in, as `reads` saw it: a Zellij write goes only to it.
    nonisolated static func zellijServer(for pane: TypedInputPane, in reads: TerminalTabReads) -> ZellijServerIdentity? {
        guard pane.host == .zellij, let target = ZellijPaneTarget(handle: pane.paneID) else { return nil }
        return reads.zellij.snapshot?.server(target.session)
    }

    // MARK: - Scan (bindings, routes, visits, card)

    /// Zellij's part of the shared scheduled read (`checkScheduledTabHosts`): while Zellij may be
    /// contacted, is not scanning, and a session could be bound there.
    func zellijScanPlan() -> ZellijScanPlan? {
        guard zellijContactAllowed else {
            if zellij.read != nil { zellijSwitchChanged(hostSwitches.isOn(.zellij)) }
            return nil
        }
        guard !zellij.scanning, !openingTask else { return nil }
        let codexSessions = Set(cliItems.map(\.session)).union(queue.items.compactMap { item in
            item.question.flatMap { $0.source == .cli ? $0.session : nil }
        })
        let identities = Set(agentQueue.snapshot.outcomes.map(\.session).filter { $0.source == .claude && $0.surface == .cli })
        let claudeRows = Dictionary(uniqueKeysWithValues: identities.map { identity in
            (identity, (claudeInventories[identity.sourceScope]?.sessions ?? [])
                .filter { $0.kind == .interactive && $0.sessionID == identity.session })
        })
        guard !codexSessions.isEmpty || !claudeRows.isEmpty || !liveCLI.isEmpty else { return nil }
        return ZellijScanPlan(codexSessions: codexSessions, claudeRows: claudeRows, generation: zellij.generation)
    }

    /// Applies the shared read to Zellij, unless its switch or generation moved meanwhile.
    func finishZellijScan(_ plan: ZellijScanPlan, reads: TerminalTabReads, claude: [AgentSessionIdentity: ClaudeTabProcess],
                          hostFront: TerminalVisibilityReading<String>, takenAt: Double) {
        zellij.scanning = false
        guard plan.generation == zellij.generation, zellijContactAllowed else { return }
        applyZellijScan(reads, claude: claude.filter { plan.claudeRows[$0.key] != nil }, codexSessions: plan.codexSessions,
                        hostFront: hostFront, takenAt: takenAt)
    }

    private func applyZellijScan(_ reads: TerminalTabReads, claude: [AgentSessionIdentity: ClaudeTabProcess],
                                 codexSessions: Set<UUID>, hostFront: TerminalVisibilityReading<String>, takenAt: Double) {
        zellij.read = reads.zellij
        recordHostTitles(reads.inventories, takenAt: takenAt)
        let snapshot = reads.zellij.snapshot
        let unreadable = reads.zellij.inventory == .unreadable
        var diagnostics = ["Zellij: \(Self.zellijDiagnostic(reads.zellij))"]
        var codexRoutes: [UUID: TerminalReplyRoute] = [:]
        var codexSeen: Set<UUID> = []
        var codexTargets: [UUID: String] = [:]
        for session in codexSessions {
            let binding = zellijCodexBinding(session, reads: reads)
            let carried = snapshot.map { !$0.panes(titled: GhosttyMatch.title(session)).isEmpty } ?? false
            if carried { codexSeen.insert(session) }
            if case .bound(let target) = binding { codexTargets[session] = target.handle }
            if binding != .notInZellij || carried || unreadable {
                codexRoutes[session] = codexTypedRoute(session, reads: reads) ?? .unreachable
            }
            diagnostics.append("Codex \(session.uuidString.lowercased()): \(binding)")
        }
        var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
        var claudeTargets: [AgentSessionIdentity: String] = [:]
        for (identity, process) in claude {
            let binding = zellijClaudeBinding(identity, process: process, read: reads.zellij)
            if case .bound(let target) = binding { claudeTargets[identity] = target.handle }
            if binding != .notInZellij {
                claudeRoutes[identity] = claudeTypedRoute(identity, process: process, reads: reads) ?? .unreachable
            }
            diagnostics.append("Claude \(identity.session): \(binding)")
        }
        zellij.codexRoutes = codexRoutes
        zellij.claudeRoutes = claudeRoutes
        zellij.codexSeen = codexSeen
        if !codexTargets.isEmpty || !claudeTargets.isEmpty { zellij.sessionsSeen = true }
        zellij.diagnostics = diagnostics

        // ADR 0016: one visit and dwell rule; only completions, only for the session's own bound pane.
        zellij.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: ZellijVisibility.reading(snapshot, hostFront: hostFront)))
        for (session, pane) in codexTargets {
            let completions = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
            acknowledgeCodexCompletions(Array(zellij.visits.acknowledged(completions, target: pane)))
        }
        for (identity, pane) in claudeTargets {
            let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
            for id in zellij.visits.acknowledged(outcomes, target: pane) { agentQueue.dismiss(.outcome(id)) }
        }
        saveCompletions()
    }

    private static func zellijDiagnostic(_ read: ZellijRead) -> String {
        switch read {
        case .notRunning: "no session in the default socket directory"
        case .binaryNotFound: "zellij not found"
        case .unsupportedVersion(let version, let running):
            "version \(version) older than \(ZellijVersion.minimum)\(running ? ", running" : "")"
        case .untrustedSocket: "default socket directory untrusted"
        case .unreadable(let reason): "unreadable: \(reason.diagnostic)"
        case .snapshot(let snapshot):
            "\(snapshot.sessions.count) sessions, \(snapshot.processes.clientProcesses.count) client processes"
        }
    }

    // MARK: - Open (ADR 0014 "Open sequence", ADR 0015, ADR 0016)

    /// Open for a Codex CLI session while Zellij may be contacted. A session whose title no Zellij pane
    /// carries is left to the other routes, as is everything while no Zellij session runs. An unreadable
    /// Zellij keeps the session here, where it is unavailable (ADR 0013).
    func openCodexWithZellij(_ session: UUID, otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask else { return }
        openingTask = true
        let title = GhosttyMatch.title(session)
        Task { @MainActor in
            let first = await Task.detached { ZellijRunner.read() }.value
            if first.inventory == .notRunning || first.snapshot.map({ $0.panes(titled: title).isEmpty }) == true {
                openingTask = false
                otherwise()
                return
            }
            let others = otherTabHosts
            let record = MultiplexerOpenRecord()
            let result = await runZellijOpen(agent: .codex, record: record, revalidate: { [weak self] in
                let reads = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: true) }.value
                return (reads, self?.zellijCodexBinding(session, reads: reads) ?? .unavailable(.terminal(.sessionEnded)))
            }, rebind: { [weak self] reads in self?.zellijCodexBinding(session, reads: reads) ?? .unavailable(.terminal(.sessionEnded)) })
            if case .opened(let preOpenAt) = result {
                let queued = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
                let acknowledged = TerminalVisitAcknowledgment.afterOpen(queued, result: .opened, preOpenAt: preOpenAt)
                if !acknowledged.isEmpty { acknowledgeCodexCompletions(Array(acknowledged)); saveCompletions() }
            }
            recordOpen(result.open, codex: session)
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// Open for a Claude CLI session while Zellij may be contacted. A session Zellij has nothing to say
    /// about (no Zellij pane in its newest hook records, or no Zellij server above its process) is left
    /// to the other routes.
    func openClaudeWithZellij(_ identity: AgentSessionIdentity, request: ClaudeOpenRequest?,
                              otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask else { return }
        openingTask = true
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
            let first = await Task.detached { (ClaudeTabProcess.read(rows), ZellijRunner.read()) }.value
            if zellijClaudeBinding(identity, process: first.0, read: first.1) == .notInZellij {
                openingTask = false
                otherwise()
                return
            }
            let others = otherTabHosts
            let record = MultiplexerOpenRecord()
            final class Latest { var process: ClaudeTabProcess? }
            let latest = Latest()
            let result = await runZellijOpen(agent: .claude, record: record, revalidate: { [weak self] in
                let fresh = await Task.detached { () -> (ClaudeTabProcess, TerminalTabReads) in
                    let process = ClaudeTabProcess.read(rows)
                    return (process, TerminalTabReads.take(others: others, claudeTTYs: Set([process.tty].compactMap { $0 }),
                                                           second: false))
                }.value
                latest.process = fresh.0
                guard let self, !rows.isEmpty else { return (fresh.1, .unavailable(.terminal(.sessionEnded))) }
                return (fresh.1, self.zellijClaudeBinding(identity, process: fresh.0, read: fresh.1.zellij))
            }, rebind: { [weak self] reads in
                guard let self, let process = latest.process else { return .unavailable(.terminal(.sessionEnded)) }
                return self.zellijClaudeBinding(identity, process: process, read: reads.zellij)
            })
            recordOpen(result.open, claude: identity)
            // ADR 0015: an Open on an actionable request hands it back with no decision, fallback included;
            // an unavailable one hands nothing back.
            handBackClaudeRequest(request, after: result.open)
            if case .unavailable = result.open {} else {
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

    /// ADR 0014's sequence: revalidate both layers, `focus-pane-id` once, verify the pane on a fresh read,
    /// then raise and verify the host tab with that host's Open. A failure falls back by walking the
    /// `zellij` client processes to their app (ADR 0015) or stays unavailable; nothing is rolled back.
    private func runZellijOpen(agent: AgentSource, record: MultiplexerOpenRecord,
                               revalidate: @escaping @MainActor () async -> (TerminalTabReads, ZellijBinding),
                               rebind: @escaping @MainActor (TerminalTabReads) -> ZellijBinding) async -> TmuxOpenEnd {
        let switches = contactSwitches
        let run = await ZellijOpen.run(
            now: { Date().timeIntervalSince1970 },
            revalidate: {
                let (reads, binding) = await revalidate()
                record.reads = reads
                guard let snapshot = reads.zellij.snapshot else {
                    if case .unavailable(let reason) = binding { return .failure(ZellijOpen.miss(reason)) }
                    return .failure(.unavailable(.hostUnreadable(.zellij)))
                }
                return ZellijOpen.plan(binding, snapshot: snapshot, join: {
                    reads.hostJoin(clientTTY: $0, switches: switches)
                }, hostTitle: { tab in
                    guard case .tabs(let tabs)? = reads.inventories[tab.host] else { return nil }
                    return tabs.first { $0.tabID == tab.tabID }?.title
                })
            },
            focus: { plan in
                ZellijOpen.focused(await Task.detached {
                    ZellijRunner.send(ZellijOpen.focusArguments(plan), to: plan.pane, expecting: plan.server)
                }.value)
            },
            verifyPane: { plan in
                let fresh = await Task.detached { ZellijRunner.read() }.value
                guard let reads = record.reads else { return .fallBack(.notVerified, candidates: 1) }
                var inventories = reads.inventories
                inventories[.zellij] = fresh.inventory
                let rebound = TerminalTabReads(terminalApp: reads.terminalApp, inventories: inventories,
                                               processes: reads.processes, secondRead: inventories, tmux: reads.tmux,
                                               zellij: fresh, ghostty: reads.ghostty, iTerm2: reads.iTerm2,
                                               wezTerm: reads.wezTerm, wezTermClients: reads.wezTermClients,
                                               rex: reads.rex)
                return ZellijOpen.verifyPane(plan, read: fresh, binding: rebind(rebound))
            },
            // nil is a step that passed; see `runTmuxOpen`.
            raise: { [weak self] plan in
                guard let self else { return .unavailable(.sessionEnded) }
                return await self.raiseHostTab(plan.host, clientTTY: plan.client.tty, record: record,
                                               requiredTitlePrefix: ZellijOpen.titlePrefix(plan.pane.session))
            },
            verifyHost: { [weak self] plan in
                guard let self else { return .unavailable(.sessionEnded) }
                return await self.verifyHostTab(plan.host, clientTTY: plan.client.tty, record: record)
            })
        switch run {
        case .opened(_, let preOpenAt):
            return .opened(preOpenAt: preOpenAt)
        case .failed(let miss, _):
            let pids = ZellijOpen.fallbackClientPIDs(in: record.reads?.zellij.snapshot)
            let result = await openResult(.miss(miss)) { _ in
                let walks = await Task.detached { pids.map(TerminalApps.walk(from:)) }.value
                return OpenFallback.processApp(walks: walks, agent: agent, switches: switches)
            }
            return .other(result)
        }
    }

    // MARK: - Question digits (ADR 0017)

    /// The bound Zellij pane a Codex question's digit may be typed into, from the latest scan; nil if
    /// Zellij's digit is not proven live (`ZellijInput.questionDigitsProvenLive`), so the shared route offers
    /// no key and the card says "Answer this in Codex."
    func zellijQuestionKeyPane(for session: UUID) -> TypedInputPane? {
        guard zellijContactAllowed, case .pane(let pane)? = zellij.codexRoutes[session], pane.host == .zellij,
              pane.host.typesQuestionDigits else { return nil }
        return pane
    }

    /// The Zellij send behind the shared pane-key route (`answerThroughTerminalKeys`, ADR 0017), after
    /// `TerminalQuestionKeys.start` spent the key: immediately before it, the binding is re-run on fresh
    /// reads of every enabled host and the rollout is re-read last; the send itself re-reads the pane
    /// first (`ZellijRunner.send`). One digit with `write-chars`, never a carriage return; a key that may
    /// have been written counts as sent and is never resent.
    func sendZellijQuestionKey(_ current: AttentionQuestion, start: TerminalQuestionKeys.Start,
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
            let route = codexTypedRoute(current.session, reads: reads)
            let server = Companion.zellijServer(for: start.pane, in: reads)
            let outcome = await Task.detached { () -> HerdrQuestionRelay.Outcome in
                // The rollout last, as of this instant: a manual answer Codex already recorded, or an ended
                // turn, sends nothing.
                let evidence = ReminderReader.currentEvidence(for: current.session, in: rolloutRoot)
                if let veto = TerminalQuestionKeys.preSendCheck(question: current, evidence: evidence, route: route,
                                                                spent: start.pane) {
                    return .vetoed(veto)
                }
                guard let target = ZellijPaneTarget(handle: start.pane.paneID),
                      let arguments = ZellijInput.digitArguments(start.key, into: start.pane) else {
                    return .delivered(TerminalQuestionKeys.delivery(.notWritten))
                }
                let delivery = ZellijInput.delivery(ZellijRunner.send(arguments, to: target, expecting: server))
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

    var zellijSettingsRow: ZellijSettingsRow {
        ZellijPresentation.settingsRow(on: hostSwitches.isOn(.zellij), anyTerminalOn: hostSwitches.anyTerminalOn,
                                       read: zellij.read, sessionsSeen: zellij.sessionsSeen)
    }
}
