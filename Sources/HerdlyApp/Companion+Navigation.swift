import AppKit
import HerdlyCore

struct ClaudeNavigationRoot: Sendable {
    let root: URL
    let capabilities: ClaudeCapabilities
}

extension Companion {
    func openAgent(_ identity: AgentSessionIdentity) {
        if identity.source == .claude {
            openClaude(identity)
        } else if let session = codexSession(identity) {
            if isCodexTerminalSession(identity) { openCLI(session) } else { openDesktop(session) }
        } else {
            navigationMessage = "Open Session is unavailable until Herdly can verify the exact session."
            refresh()
        }
    }

    /// Whether a Codex card belongs to a terminal session, against the sessions now known to be
    /// terminal ones (`CodexAttentionAdapter.isTerminalSession`).
    func isCodexTerminalSession(_ identity: AgentSessionIdentity) -> Bool {
        CodexAttentionAdapter.isTerminalSession(identity, cliSessions: cliSessions)
    }

    /// Whether a Claude card offers Open: the session is live exactly once in complete inventories,
    /// and Ghostty, when on, has its Automation permission. Whether the click reaches the exact tab or
    /// falls back to raising the session's app (ADR 0015) is decided at click time; the card looks
    /// the same either way.
    func canOpenClaude(_ identity: AgentSessionIdentity) -> Bool {
        guard identity.source == .claude, identity.surface == .cli,
              !ghosttyEnabled || ghosttyPermissionVerified, !liveClaudeSessions.isEmpty,
              let configuredScopes = configuredClaudeNavigationScopes(),
              Set(liveClaudeSessions.keys) == configuredScopes,
              Set(claudeInventoryAvailable.keys) == configuredScopes,
              claudeInventoryAvailable.values.allSatisfy({ $0 }) else { return false }
        return liveClaudeSessions[identity.sourceScope]?.filter({ $0 == identity.session }).count == 1
            && liveClaudeSessions.values.flatMap({ $0 }).filter({ $0 == identity.session }).count == 1
    }

    /// Whether complete inventories list a Claude CLI session as live, under `canOpenClaude`'s inventory gate.
    func claudeInventoryPresence(_ identity: AgentSessionIdentity) -> ClaudeInventoryPresence {
        guard let configuredScopes = configuredClaudeNavigationScopes(),
              Set(liveClaudeSessions.keys) == configuredScopes,
              Set(claudeInventoryAvailable.keys) == configuredScopes,
              claudeInventoryAvailable.values.allSatisfy({ $0 }) else { return .unknown }
        let everywhere = liveClaudeSessions.values.flatMap({ $0 }).filter({ $0 == identity.session }).count
        if everywhere == 0 { return .absent }
        let own = liveClaudeSessions[identity.sourceScope]?.filter({ $0 == identity.session }).count
        return own == 1 && everywhere == 1 ? .live : .unknown
    }

    /// H7 for a Claude CLI card not offered Open (#280): "<app> isn't running." for the terminal app its
    /// process last walked to, then "This session has ended."; nil keeps `claudeReturnUnavailableMessage`.
    /// Only reads whether the app runs; Herdly never launches it (#270).
    func claudeLastSeenLine(_ identity: AgentSessionIdentity) -> OpenUnavailableReason? {
        guard let key = openLineKey(identity) else { return nil }
        return ClaudeLastSeenHost.openLine(lastSeen: lastSeenClaudeHosts[key], presence: claudeInventoryPresence(identity),
                                           isRunning: TerminalApps.isRunning)
    }

    func isBackgroundClaudeSession(_ identity: AgentSessionIdentity) -> Bool {
        identity.source == .claude && claudeInventories[identity.sourceScope]?.isBackgroundSession(identity.session) == true
    }

    /// Navigation includes every supported root that has a configured or otherwise inspectable
    /// setup state. An awaiting-restart root is part of the global uniqueness gate even though it
    /// has not delivered a fresh hook event in this launch. A supported root with an unavailable
    /// setup status stays in the gate and makes navigation unavailable until its inventory is complete.
    func configuredClaudeNavigationRoots() -> [ClaudeNavigationRoot] {
        claude.roots.compactMap { root in
            guard root.capabilities.supported else { return nil }
            switch root.status {
            case .notConfigured:
                return nil
            default:
                return ClaudeNavigationRoot(root: root.url.standardizedFileURL, capabilities: root.capabilities)
            }
        }
    }

    private func configuredClaudeNavigationScopes() -> Set<String>? {
        let roots = configuredClaudeNavigationRoots()
        guard !roots.isEmpty else { return nil }
        return Set(roots.map { $0.root.path })
    }

    var claudeReturnUnavailableMessage: String {
        if ghosttyEnabled && !ghosttyPermissionVerified { return "Ghostty controls are awaiting Automation permission." }
        return "Open is unavailable until Herdly can verify this Claude session is live."
    }

    private func openClaude(_ identity: AgentSessionIdentity, approval: AgentApproval? = nil) {
        guard !openingTask else { return }
        guard identity.surface == .cli else {
            navigationMessage = "The exact Claude tab is unavailable for this session surface."
            refresh()
            return
        }
        let herdrKey = HerdrSessionKey(agent: .claude, sessionID: identity.session)
        let herdrRoute = herdrBinding(for: herdrKey)
        // With Ghostty off Herdly does not contact herdr (ADR 0014), so the session's own process is
        // walked as for any Claude session in a switched-off app (ADR 0015). Under herdr that process
        // descends from herdr's server, not a terminal app, so the walk fails and Open reports "Herdly
        // can't tell which terminal this session is in." That is accurate: without contacting herdr
        // Herdly cannot find the client, and so the app, the session is shown in.
        if herdrRoute != .notInHerdr, herdrRoute != .unavailable(.ghosttyControlsOff) {
            // ADR 0011: an actionable approval is handed back before the herdr pane is opened.
            if let approval,
               let current = orderedAgentAttentionItems.compactMap(\.approval).first(where: { $0.id == approval.id }) {
                handBackClaudeApproval(current)
            }
            openHerdr(herdrKey, subject: .claude(identity))
            return
        }
        // tmux (#241): a session whose process's tty is a pane of tmux's default server opens through
        // ADR 0014's two layers; anything else keeps the routes below.
        if tmuxContactAllowed {
            openClaudeWithTmux(identity, approval: approval) { [weak self] in
                self?.openClaudeOutsideTmux(identity, approval: approval)
            }
            return
        }
        openClaudeOutsideTmux(identity, approval: approval)
    }

    /// Zellij (#242): a session whose newest hook records and process put it in a Zellij pane opens through
    /// ADR 0014's two layers; anything else keeps the routes below.
    private func openClaudeOutsideTmux(_ identity: AgentSessionIdentity, approval: AgentApproval?) {
        if zellijContactAllowed {
            openClaudeWithZellij(identity, approval: approval) { [weak self] in
                self?.openClaudeOutsideMultiplexers(identity, approval: approval)
            }
            return
        }
        openClaudeOutsideMultiplexers(identity, approval: approval)
    }

    /// WezTerm's, then Terminal.app's sequence while each is on, otherwise Ghostty's title route or the walk.
    private func openClaudeOutsideMultiplexers(_ identity: AgentSessionIdentity, approval: AgentApproval?) {
        // WezTerm on (#240): a pane there opens through its own sequence; anything else keeps the routes below.
        if wezTermSwitchedOn {
            openClaudeWithWezTerm(identity, approval: approval) { [weak self] in
                self?.openClaudeOutsideWezTerm(identity, approval: approval)
            }
            return
        }
        openClaudeOutsideWezTerm(identity, approval: approval)
    }

    private func openClaudeOutsideWezTerm(_ identity: AgentSessionIdentity, approval: AgentApproval?) {
        // Terminal.app on (#239): a tab there opens through its own sequence; anything else keeps
        // Ghostty's title route below.
        if terminalAppSwitchedOn {
            openClaudeWithTerminalApp(identity, approval: approval) { [weak self] in
                self?.openClaudeByTitle(identity, approval: approval)
            }
            return
        }
        openClaudeByTitle(identity, approval: approval)
    }

    /// Ghostty's title route for a Claude tab, or the fallback from its registry process (ADR 0015).
    private func openClaudeByTitle(_ identity: AgentSessionIdentity, approval: AgentApproval?) {
        openingTask = true
        navigationMessage = "Finding the matching Claude tab…"
        let configuredRoots = configuredClaudeNavigationRoots()
        // ADR 0016: a verified Open acknowledges the session's completions that arrived before the pre-Open read.
        let preOpenAt = Date().timeIntervalSince1970
        let ghosttyOn = ghosttyEnabled
        let ghosttyRunning = ghosttyOn && TerminalApps.isRunning(.ghostty)
        Task { @MainActor in
            let inventories = await Task.detached {
                configuredRoots.map { root in
                    ClaudeSetupDetection.activeSessionInventory(root: root.root, capabilities: root.capabilities)
                }
            }.value
            let freshScopes = Set(inventories.map(\.sourceScope))
            let currentScopes = Set(configuredClaudeNavigationRoots().map { $0.root.path })
            let complete = !inventories.isEmpty && freshScopes == currentScopes && inventories.allSatisfy(\.available)
            let live = inventories.flatMap { scan in
                scan.sessions.filter { $0.kind == .interactive }.map(\.sessionID)
            }
            let own = inventories.first { $0.sourceScope == identity.sourceScope }?.sessions
                .filter { $0.kind == .interactive && $0.sessionID == identity.session } ?? []
            let result: TerminalOpenResult?
            if !complete {
                result = nil
            } else if own.isEmpty, !live.contains(identity.session) {
                result = .unavailable(.sessionEnded)
            } else if own.count != 1 || live.filter({ $0 == identity.session }).count != 1 {
                result = nil
            } else {
                // Ghostty off is never scanned: the session's own registry process names its app.
                let pid = own[0].pid
                let switches = hostSwitches
                // iTerm2 first (#238): its tty binding decides whenever the process's tty is on an iTerm2 tab.
                let registered = pid.map { ClaudeSessionRegistry.Process(pid: $0, procStart: own[0].procStart) }
                if let iTerm2Result = await openClaudeInITerm2(sessionID: identity.session, process: registered) {
                    result = iTerm2Result
                } else {
                    let outcome: GhosttyTitleOutcome = ghosttyOn
                        ? await Task.detached {
                            await GhosttyNavigation.openClaude(sessionID: identity.session, live: live, running: ghosttyRunning)
                        }.value
                        : .miss(.fallBack(.noUniqueTarget, candidates: 0))
                    result = await openResult(outcome) { _ in
                        let walk = await Task.detached { pid.map(TerminalApps.walk(from:)) ?? .failed }.value
                        return OpenFallback.processApp(walks: [walk], agent: .claude, switches: switches)
                    }
                }
            }
            navigationMessage = result.map { message(for: $0, opened: "Opened the matching Claude tab.") }
                ?? claudeReturnUnavailableMessage
            if let result { recordOpen(result, claude: identity) }
            switch result {
            case .opened?, .fellBack?:
                // ADR 0015: an Open on an actionable request hands it back with no decision, fallback
                // included. Only the verified Open acknowledges.
                if let approval,
                   let current = orderedAgentAttentionItems.compactMap(\.approval).first(where: { $0.id == approval.id }) {
                    handBackClaudeApproval(current)
                }
                if let result {
                    let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }
                        .map(TerminalCompletionCandidate.init)
                    for id in TerminalVisitAcknowledgment.afterOpen(outcomes, result: result, preOpenAt: preOpenAt) {
                        agentQueue.dismiss(.outcome(id))
                    }
                    saveCompletions()
                }
            case .unavailable?, nil:
                break
            }
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// Resolves a Ghostty title Open under ADR 0015 and performs the fallback: the identified app is
    /// raised as a whole, only while running, and nothing is acknowledged or made an input target.
    /// `app` identifies the session's app from the number of Ghostty terminals carrying its title.
    func openResult(_ outcome: GhosttyTitleOutcome,
                    app: (Int) async -> Result<TerminalHost, OpenUnavailableReason>) async -> TerminalOpenResult {
        switch outcome {
        case .opened:
            return .opened
        case .miss(let miss):
            // Identify the app off the decision (a walk may run off the main actor), only for a fallback.
            var identified: Result<TerminalHost, OpenUnavailableReason> = .failure(.appNotIdentified)
            if case .fallBack(_, let candidates) = miss { identified = await app(candidates) }
            return raise(OpenFallback.resolve(miss, app: { _ in identified }, isRunning: TerminalApps.isRunning))
        }
    }

    /// Activates the app of a fallback. A failed activation is "isn't running" only when a fresh
    /// check says so; the app is never launched.
    func raise(_ result: TerminalOpenResult) -> TerminalOpenResult {
        guard case .fellBack(let host, _) = result else { return result }
        let activated = TerminalApps.activate(host)
        return OpenFallback.afterActivation(result, activated: activated,
                                            stillRunning: activated || TerminalApps.isRunning(host))
    }

    /// The navigation message after an Open: the host's line for a verified Open, none for a silent
    /// fallback (ADR 0015; `navigationMessage` is empty when there is nothing to say), or the agreed
    /// unavailable line.
    func message(for result: TerminalOpenResult, opened: String) -> String {
        switch result {
        case .opened: opened
        case .fellBack: ""
        case .unavailable(let reason): reason.cardLine
        }
    }

    func openAgentApproval(_ approval: AgentApproval) {
        if approval.identity.session.source == .claude {
            openClaude(approval.identity.session, approval: approval)
            return
        }
        guard approval.identity.session.source == .codex,
              let session = codexSession(approval.identity.session),
              let requestID = UUID(uuidString: approval.identity.call),
              let request = queue.items.compactMap(\.request).first(where: { $0.id == requestID }) else {
            navigationMessage = "Open Session is unavailable until Herdly can verify the exact Claude tab."
            refresh()
            return
        }
        openApprovalInCodex(request)
        _ = session
    }

    func openCLI(_ session: UUID) {
        guard !openingTask else { return }
        guard cliTerminalHostOn else { showControls(); return }
        // A session in herdr never falls back to the title route. An approval reaching here through
        // `openApprovalInCodex` was already handed back (ADR 0011).
        let herdrKey = HerdrSessionKey(agent: .codex, sessionID: session.uuidString)
        let herdrRoute = herdrBinding(for: herdrKey)
        if herdrRoute != .notInHerdr, ghosttyEnabled || herdrRoute != .unavailable(.ghosttyControlsOff) {
            openHerdr(herdrKey, subject: .codex(session))
            return
        }
        // tmux (#241): a title a pane of tmux's default server carries opens through ADR 0014's two
        // layers; anything else keeps the routes below, which read tmux too for ADR 0013's uniqueness.
        if tmuxContactAllowed {
            openCodexWithTmux(session) { [weak self] in self?.openCLIOutsideTmux(session) }
            return
        }
        openCLIOutsideTmux(session)
    }

    /// Zellij (#242): a title a Zellij pane carries opens through ADR 0014's two layers; anything else keeps
    /// the routes below, which read Zellij too for ADR 0013's uniqueness.
    private func openCLIOutsideTmux(_ session: UUID) {
        if zellijContactAllowed {
            openCodexWithZellij(session) { [weak self] in self?.openCLIOutsideMultiplexers(session) }
            return
        }
        openCLIOutsideMultiplexers(session)
    }

    /// WezTerm's, then Terminal.app's sequence while each is on, otherwise iTerm2's or Ghostty's route.
    private func openCLIOutsideMultiplexers(_ session: UUID) {
        // WezTerm on (#240): a pane there opens through its own sequence; a title no WezTerm pane carries
        // keeps the routes below. Each reads every enabled host for ADR 0013's binding.
        if wezTermSwitchedOn {
            openCodexWithWezTerm(session) { [weak self] in self?.openCLIOutsideWezTerm(session) }
            return
        }
        openCLIOutsideWezTerm(session)
    }

    private func openCLIOutsideWezTerm(_ session: UUID) {
        // Terminal.app on (#239): a tab there opens through its own sequence; a title no Terminal.app
        // tab carries keeps the routes below. Both read every enabled host for ADR 0013's binding.
        if terminalAppSwitchedOn {
            openCodexWithTerminalApp(session) { [weak self] in self?.openCLIOutsideTerminalApp(session) }
            return
        }
        openCLIOutsideTerminalApp(session)
    }

    /// iTerm2's cross-host Open while it is on (#238), otherwise Ghostty's title route.
    private func openCLIOutsideTerminalApp(_ session: UUID) {
        if hostSwitches.mayContact(.iTerm2) {
            openCLIAcrossHosts(session)
            return
        }
        openCLIInGhostty(session)
    }

    /// Ghostty's title route for a Codex tab (ADR 0005, ADR 0016), with ADR 0015's fallback.
    private func openCLIInGhostty(_ session: UUID) {
        openingTask = true
        navigationMessage = "Finding the matching Ghostty tab…"
        let live = liveCLI
        // ADR 0016: a verified Open acknowledges the session's completions that arrived before the pre-Open read.
        let preOpenAt = Date().timeIntervalSince1970
        let running = TerminalApps.isRunning(.ghostty)
        Task { @MainActor in
            let outcome = await Task.detached { await GhosttyNavigation.open(session: session, live: live, running: running) }.value
            let switches = hostSwitches
            // ADR 0015 amendment: the tabs carrying the title name the app; none cannot be identified.
            let result = await openResult(outcome) { count in
                OpenFallback.codexApp(candidates: GhosttyTitleOpen.codexCandidates(count: count), switches: switches)
            }
            navigationMessage = message(for: result, opened: "Opened the matching Ghostty tab.")
            recordOpen(result, codex: session)
            let queued = cliItems.filter { $0.session == session }
                .map(TerminalCompletionCandidate.init)
            let acknowledged = TerminalVisitAcknowledgment.afterOpen(queued, result: result, preOpenAt: preOpenAt)
            if !acknowledged.isEmpty {
                acknowledgeCodexCompletions(Array(acknowledged))
                saveCompletions()
            }
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }
    func reminderActionTitle(_ item: Reminder) -> String {
        cliSessions.contains(item.session_id) && !cliTerminalHostOn ? "Set up Ghostty" : "Open Session"
    }
    var needsGhosttySetup: Bool {
        !cliTerminalHostOn && (!cliItems.isEmpty || visibleReminders.contains { cliSessions.contains($0.session_id) }
                            || queue.items.contains { $0.question?.source == .cli })
    }
    func openReminder(_ item: Reminder) {
        if cliSessions.contains(item.session_id) { openCLI(item.session_id) }
        else { taskID = item.session_id.uuidString; openTestTask() }
    }
    func openAttentionSession(source: AttentionSource, session: UUID) {
        if source == .cli { openCLI(session) }
        else { taskID = session.uuidString; openTestTask() }
    }

    /// Open in Codex releases the pending interaction at once: the user decides in Codex's own prompt.
    func openApprovalInCodex(_ request: AttentionRequest) {
        if let current = queue.items.compactMap(\.request).first(where: { $0.identity == request.identity }) {
            handBackApproval(current)
        }
        openAttentionSession(source: request.source, session: request.session)
    }

    func openDesktop(_ session: UUID) {
        guard !openingTask else { return }
        openingTask = true
        navigationMessage = "Opening link…"
        Task { @MainActor in
            let result = await desktopAdapter.open(taskID: session.uuidString)
            navigationMessage = result.rawValue
            openingTask = false
            refresh()
        }
    }
}

// MARK: - herdr Open (ADR 0011)

/// What an Open in a herdr pane acknowledges on success: Codex CLI completions in `queue`, or
/// Claude outcomes in `agentQueue`.
enum HerdrOpenSubject {
    case codex(UUID)
    case claude(AgentSessionIdentity)
}

/// herdr Open state held by `HerdrSessionBindings`. Main-actor only.
@MainActor
final class HerdrOpenState {
    /// The typed reason of each session's latest unavailable herdr Open, cleared by a later Opened.
    /// For diagnostics and for the card's grouped reason line (docs/product.md, "Agreed herdr presentation").
    fileprivate(set) var failures: [HerdrSessionKey: HerdrOpenFailure] = [:]
    /// The visit interval and dwell run over scheduled scans (ADR 0016), reset after every Open.
    fileprivate var visits = HerdrVisitTracker()
}

extension Companion {
    /// The typed reason the latest herdr Open for `session` was unavailable, or nil when none failed
    /// since the last Opened.
    func herdrOpenFailure(for session: HerdrSessionKey) -> HerdrOpenFailure? {
        herdr.open.failures[session]
    }

    /// Opens a session in herdr (ADR 0014): a client hosted by Ghostty, or by no other enabled host the
    /// latest scan's client walks to, keeps ADR 0011's sequence unchanged; a client in another enabled
    /// host's tab joins it by tty and is raised by that host's own Open.
    fileprivate func openHerdr(_ key: HerdrSessionKey, subject: HerdrOpenSubject) {
        let others = herdrClientHosts.subtracting([.ghostty])
        guard !others.isEmpty, let clientPID = HerdrOpen.attachedClient(herdr.scanOutcome)?.pid else {
            openHerdrInGhostty(key, subject: subject)
            return
        }
        openingTask = true
        navigationMessage = "Finding the matching herdr pane…"
        Task { @MainActor in
            let walk = await Task.detached { TerminalApps.walk(from: clientPID) }.value
            if case .reached(let host) = walk, others.contains(host) {
                openHerdrInHostTab(key, subject: subject)
            } else {
                openHerdrInGhostty(key, subject: subject)
            }
        }
    }

    /// ADR 0014's sequence for a herdr pane whose client runs in another enabled host's tab: revalidate
    /// herdr and the tty join, focus and verify the pane as ADR 0011 does, then raise and verify the tab
    /// with that host's Open. herdr failures keep their own lines and fallback; a host-tab failure after
    /// the pane verified is a partial reach (ADR 0015).
    private func openHerdrInHostTab(_ key: HerdrSessionKey, subject: HerdrOpenSubject) {
        openingTask = true
        navigationMessage = "Finding the matching herdr pane…"
        let client = herdr.client
        let others = otherTabHosts
        let switches = hostSwitches
        final class LatestScan { var outcome: HerdrScanOutcome? }
        let latest = LatestScan()
        let record = MultiplexerOpenRecord()
        Task { @MainActor in
            let run = await TerminalOpenSequence.run(TerminalOpenSteps<HerdrHostOpenPlan, HerdrHostOpenFailure>(
                now: { Date().timeIntervalSince1970 },
                revalidate: { [weak self] _ in
                    guard let self else { return .failure(.herdr(.binding(.notScanned))) }
                    let fresh = await self.revalidateHerdrBinding(for: key)
                    latest.outcome = fresh.outcome
                    let reads = await Task.detached { TerminalTabReads.take(others: others, claudeTTYs: [], second: false) }.value
                    record.reads = reads
                    return HerdrHostOpen.plan(binding: fresh.binding, outcome: fresh.outcome, join: {
                        MultiplexerHostTab.join(clientTTY: $0, switches: switches, inventories: reads.inventories)
                    })
                },
                focusPane: { plan in
                    HerdrOpen.focusOutcome(await Task.detached { client.focusAgent(target: plan.pane.paneID) }.value)
                        .map(HerdrHostOpenFailure.herdr)
                },
                verifyPane: { [weak self] plan in
                    guard let self else { return .herdr(.herdrVerifyUnavailable(.notScanned)) }
                    let verify = await self.revalidateHerdrBinding(for: key)
                    latest.outcome = verify.outcome ?? latest.outcome
                    return HerdrHostOpen.verifyPane(plan, binding: verify.binding, outcome: verify.outcome)
                },
                raise: { [weak self] plan in
                    TmuxOpen.hostRaised(await self?.raiseHostTab(plan.host, clientTTY: plan.clientTTY, record: record))
                        .map(HerdrHostOpenFailure.host)
                },
                verify: { [weak self] plan in
                    TmuxOpen.hostRaised(await self?.verifyHostTab(plan.host, clientTTY: plan.clientTTY, record: record))
                        .map(HerdrHostOpenFailure.host)
                }))
            let pids = HerdrOpenFallback.clientPIDs(latest.outcome)
            let agent: AgentSource = key.agent == .claude ? .claude : .codex
            switch run {
            case .opened(_, let preOpenAt):
                herdr.open.failures[key] = nil
                navigationMessage = "Opened the matching herdr pane."
                acknowledgeHerdrCompletions(TerminalVisitAcknowledgment.afterOpen(herdrCompletions(subject), result: .opened,
                                                                                  preOpenAt: preOpenAt), subject: subject)
            case .failed(.herdr(let failure), _):
                herdr.open.failures[key] = failure
                let walks = await Task.detached { pids.map(TerminalApps.walk(from:)) }.value
                if let fallback = HerdrOpenFallback.resolve(failure, agent: agent, clientWalks: walks, switches: switches,
                                                            isRunning: TerminalApps.isRunning) {
                    navigationMessage = message(for: raise(fallback), opened: "")
                } else {
                    navigationMessage = HerdrPresentation.cardLine(for: .open(failure), agent: key.agent)
                }
            case .failed(.host(let miss), _):
                let result = await openResult(.miss(miss)) { _ in
                    let walks = await Task.detached { pids.map(TerminalApps.walk(from:)) }.value
                    return OpenFallback.processApp(walks: walks, agent: agent, switches: switches)
                }
                navigationMessage = message(for: result, opened: "")
            }
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// Runs ADR 0011's sequence for a session in herdr. The completion or reminder is retained on
    /// every failure; only completions that arrived before the pre-Open scan are acknowledged on success.
    private func openHerdrInGhostty(_ key: HerdrSessionKey, subject: HerdrOpenSubject) {
        openingTask = true
        navigationMessage = "Finding the matching herdr pane…"
        let client = herdr.client
        // The latest scan the sequence read, whose attached clients a fallback walks (ADR 0015).
        final class LatestScan { var outcome: HerdrScanOutcome? }
        let latest = LatestScan()
        let effects = HerdrOpenEffects(
            now: { Date().timeIntervalSince1970 },
            ttySupport: { await Task.detached { GhosttyScriptingSupport.ttySupport() }.value },
            revalidate: { [weak self] in
                guard let self else { return (.unavailable(.notScanned), nil) }
                let fresh = await self.revalidateHerdrBinding(for: key)
                latest.outcome = fresh.outcome
                return fresh
            },
            ghosttySnapshot: { await Task.detached { GhosttyNavigation.snapshot() }.value },
            focus: { pane in await Task.detached { client.focusAgent(target: pane) }.value },
            select: { target, tty in await Task.detached { GhosttyNavigation.selectHerdrTab(target: target, tty: tty) }.value })
        Task { @MainActor in
            let result = await HerdrOpenSequence.run(effects)
            switch result {
            case .opened:
                herdr.open.failures[key] = nil
                navigationMessage = "Opened the matching herdr pane."
                acknowledgeHerdrCompletions(HerdrOpenAcknowledgment.afterOpen(herdrCompletions(subject), result: result),
                                            subject: subject)
            case .unavailable(let failure):
                // Kept for diagnostics whether or not the Open fell back.
                herdr.open.failures[key] = failure
                let pids = HerdrOpenFallback.clientPIDs(latest.outcome)
                let walks = await Task.detached { pids.map(TerminalApps.walk(from:)) }.value
                if let fallback = HerdrOpenFallback.resolve(failure, agent: key.agent == .claude ? .claude : .codex,
                                                            clientWalks: walks, switches: hostSwitches,
                                                            isRunning: TerminalApps.isRunning) {
                    // Silent; the herdr focus already verified is kept, and nothing is acknowledged.
                    navigationMessage = message(for: raise(fallback), opened: "")
                } else {
                    // The grouped reason only; the exact failure stays in diagnostics.
                    navigationMessage = HerdrPresentation.cardLine(for: .open(failure), agent: key.agent)
                }
            }
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// Called after each scheduled herdr scan. While the focused pane is bound to a live session or to one
    /// with queued completions, applies ADR 0016's manual-visit rule (the pane became visible) and dwell
    /// rule (it stayed visible after the completion arrived). The pane is visible when herdr focuses it and
    /// Ghostty shows its client's tab. Ghostty is asked for an inventory only while macOS reports it
    /// frontmost; otherwise nothing is visible and no Apple Event is sent. A live session's pane is sampled
    /// before any completion arrives, so the dwell run can predate one.
    func observeHerdrVisit(_ outcome: HerdrScanOutcome) {
        guard let startedAt = herdr.monitor.latestStartedAt else { return }
        // The scan's start on the completions' clock: conservative, as the snapshot was read after it.
        let takenAt = Date().timeIntervalSince1970 - max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        let current = HerdrFocusObservation.from(outcome, takenAt: takenAt)
        var subjects: [HerdrOpenSubject] = []
        guard let check = herdr.open.visits.scan(current, takenAt: takenAt, openInFlight: openingTask,
                                                 holdsLiveBoundTarget: { pane in
                                                     subjects = herdrVisitSubjects(boundTo: pane)
                                                     return !subjects.isEmpty || herdrPaneHostsLiveSession(pane)
                                                 },
                                                 frontmost: TerminalApps.frontmostHost()) else { return }
        let checkedSubjects = subjects
        Task { @MainActor in
            let ghosttyTakenAt = Date().timeIntervalSince1970
            let observed = await Task.detached { () -> (support: GhosttyTTYSupport, ghostty: GhosttySnapshot?) in
                // Without `tty` the inventory still says whether Ghostty is frontmost (interim, issue #155).
                (GhosttyScriptingSupport.ttySupport(), GhosttyNavigation.snapshot())
            }.value
            guard ghosttyEnabled else { herdr.open.visits.cancel(check); return }
            // Nil when an Open ended after this scan started: the check then counts for nothing.
            guard let result = herdr.open.visits.finish(check, support: observed.support, ghostty: observed.ghostty,
                                                        ghosttyTakenAt: ghosttyTakenAt) else { return }
            for subject in checkedSubjects {
                acknowledgeHerdrCompletions(herdr.open.visits.acknowledged(herdrCompletions(subject), after: result),
                                            subject: subject)
            }
            refresh()
        }
    }

    /// Ends every visit interval and dwell run as of now, after an Open of any outcome (ADR 0015, 0016):
    /// the interval spanning an Open is never a visit, so a fallback that happened to raise the target's
    /// tab acknowledges nothing, and a check started before the Open ended is ignored.
    func endVisitIntervalsAfterOpen() {
        let now = Date().timeIntervalSince1970
        herdr.open.visits.reset(at: now)
        resetGhosttyVisits(at: now)
        iTerm2.visits.reset(at: now)
        terminalApp.visits.reset(at: now)
        wezTerm.visits.reset(at: now)
        tmux.visits.reset(at: now)
        zellij.visits.reset(at: now)
    }

    /// Sessions with queued completions whose current binding is `pane`.
    private func herdrVisitSubjects(boundTo pane: String) -> [HerdrOpenSubject] {
        let codex = Set(cliItems.map(\.session)).sorted { $0.uuidString < $1.uuidString }.filter {
            herdrBinding(for: HerdrSessionKey(agent: .codex, sessionID: $0.uuidString)).target?.paneID == pane
        }.map(HerdrOpenSubject.codex)
        let claudeSessions = Set(agentQueue.snapshot.outcomes.map(\.session).filter {
            $0.source == .claude && $0.surface == .cli
        })
        let claude = claudeSessions.sorted { $0.session < $1.session }.filter {
            herdrBinding(for: HerdrSessionKey(agent: .claude, sessionID: $0.session)).target?.paneID == pane
        }.map(HerdrOpenSubject.claude)
        return codex + claude
    }

    private func herdrCompletions(_ subject: HerdrOpenSubject) -> [TerminalCompletionCandidate<String>] {
        switch subject {
        case .codex(let session):
            return cliItems.filter { $0.session == session }
                .map { TerminalCompletionCandidate(id: $0.turn.uuidString, arrivedAt: $0.arrivedAt) }
        case .claude(let identity):
            return agentQueue.snapshot.outcomes.filter { $0.session == identity }
                .map { TerminalCompletionCandidate(id: $0.turn, arrivedAt: $0.arrivedAt) }
        }
    }

    private func acknowledgeHerdrCompletions(_ turns: Set<String>, subject: HerdrOpenSubject) {
        guard !turns.isEmpty else { return }
        switch subject {
        case .codex(let session):
            acknowledgeCodexCompletions(cliItems.filter { $0.session == session && turns.contains($0.turn.uuidString) }
                .map(\.id))
        case .claude(let identity):
            for outcome in agentQueue.snapshot.outcomes where outcome.session == identity && turns.contains(outcome.turn) {
                agentQueue.dismiss(.outcome(outcome.id))
            }
        }
        saveCompletions()
    }
}
