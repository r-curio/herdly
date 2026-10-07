import AppKit
import SteerCore

struct ClaudeNavigationRoot: Sendable {
    let root: URL
    let capabilities: ClaudeCapabilities
}

extension Companion {
    func openAgent(_ identity: AgentSessionIdentity) {
        if identity.source == .claude {
            openClaude(identity)
        } else if let session = codexSession(identity) {
            if identity.surface == .cli { openCLI(session) } else { openDesktop(session) }
        } else {
            navigationMessage = "Open in Codex is unavailable until Steer can verify the exact session."
            refresh()
        }
    }

    func canOpenClaude(_ identity: AgentSessionIdentity) -> Bool {
        guard identity.source == .claude, identity.surface == .cli, ghosttyEnabled,
              ghosttyPermissionVerified, !liveClaudeSessions.isEmpty,
              let configuredScopes = configuredClaudeNavigationScopes(),
              Set(liveClaudeSessions.keys) == configuredScopes,
              Set(claudeInventoryAvailable.keys) == configuredScopes,
              claudeInventoryAvailable.values.allSatisfy({ $0 }),
              liveClaudeSessions[identity.sourceScope]?.filter({ $0 == identity.session }).count == 1,
              let snapshot = knownGhosttySnapshot else { return false }
        let live = liveClaudeSessions.values.flatMap { $0 }
        guard let target = GhosttyMatch.target(claudeSessionID: identity.session, live: live, snapshot: snapshot) else { return false }
        return GhosttyMatch.isInCurrentWindow(target, snapshot: snapshot)
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
        if !ghosttyEnabled { return "Enable Ghostty controls to open the exact Claude tab." }
        if !ghosttyPermissionVerified { return "Ghostty controls are awaiting Automation permission." }
        return "The exact Claude tab is unavailable until Steer can verify one live, unsplit target."
    }

    private func openClaude(_ identity: AgentSessionIdentity, approval: AgentApproval? = nil) {
        guard !openingTask else { return }
        guard ghosttyEnabled else { showControls(); return }
        guard identity.surface == .cli else {
            navigationMessage = "The exact Claude tab is unavailable for this session surface."
            refresh()
            return
        }
        let herdrKey = HerdrSessionKey(agent: .claude, sessionID: identity.session)
        if herdrBinding(for: herdrKey) != .notInHerdr {
            // ADR 0011: an actionable approval is handed back before the herdr pane is opened.
            if let approval,
               let current = orderedAgentAttentionItems.compactMap(\.approval).first(where: { $0.id == approval.id }) {
                handBackClaudeApproval(current)
            }
            openHerdr(herdrKey, subject: .claude(identity))
            return
        }
        openingTask = true
        navigationMessage = "Finding the matching Claude tab…"
        let configuredRoots = configuredClaudeNavigationRoots()
        let queued = orderedAgentAttentionItems.filter { $0.session == identity && $0.outcome != nil }.map(\.id)
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
            let ownLive = inventories.first { $0.sourceScope == identity.sourceScope }
            let result: (opened: Bool, message: String)
            if !complete || ownLive?.sessions.filter({ $0.kind == .interactive && $0.sessionID == identity.session }).count != 1
                || live.filter({ $0 == identity.session }).count != 1 {
                result = (false, claudeReturnUnavailableMessage)
            } else {
                result = await Task.detached {
                    GhosttyNavigation.openClaude(sessionID: identity.session, live: live)
                }.value
            }
            navigationMessage = result.message
            if result.opened {
                if let approval,
                   let current = orderedAgentAttentionItems.compactMap(\.approval).first(where: { $0.id == approval.id }) {
                    handBackClaudeApproval(current)
                }
                for id in queued { agentQueue.dismiss(id) }
                saveCompletions()
            }
            openingTask = false
            refresh()
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
            navigationMessage = "Open in Claude is unavailable until Steer can verify the exact Claude tab."
            refresh()
            return
        }
        openApprovalInCodex(request)
        _ = session
    }

    func openCLI(_ session: UUID) {
        guard !openingTask else { return }
        guard ghosttyEnabled else { showControls(); return }
        // A session in herdr never falls back to the title route. An approval reaching here through
        // `openApprovalInCodex` was already handed back (ADR 0011).
        let herdrKey = HerdrSessionKey(agent: .codex, sessionID: session.uuidString)
        if herdrBinding(for: herdrKey) != .notInHerdr {
            openHerdr(herdrKey, subject: .codex(session))
            return
        }
        openingTask = true
        navigationMessage = "Finding the matching Ghostty tab…"
        let live = liveCLI
        let queued = cliItems.filter { $0.session == session }.map(\.id)
        Task { @MainActor in
            let result = await Task.detached { GhosttyNavigation.open(session: session, live: live) }.value
            navigationMessage = result.message
            // A verified visit acknowledges only completions already queued for this session.
            if result.opened {
                for id in queued { queue.dismiss(.completion(id)) }
                saveCompletions()
            }
            openingTask = false
            refresh()
        }
    }
    func reminderActionTitle(_ item: Reminder) -> String {
        cliSessions.contains(item.session_id) && !ghosttyEnabled ? "Set up Ghostty" : "Open in Codex"
    }
    var needsGhosttySetup: Bool {
        !ghosttyEnabled && (!cliItems.isEmpty || visibleReminders.contains { cliSessions.contains($0.session_id) }
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
    /// The previous scheduled scan, for ADR 0009's visit interval.
    fileprivate var previousFocus: HerdrFocusObservation?
    fileprivate var checkingVisit = false
}

extension Companion {
    /// The typed reason the latest herdr Open for `session` was unavailable, or nil when none failed
    /// since the last Opened.
    func herdrOpenFailure(for session: HerdrSessionKey) -> HerdrOpenFailure? {
        herdr.open.failures[session]
    }

    /// Runs ADR 0011's sequence for a session in herdr. The completion or reminder is retained on
    /// every failure; only completions that arrived before the pre-Open scan are acknowledged on success.
    fileprivate func openHerdr(_ key: HerdrSessionKey, subject: HerdrOpenSubject) {
        openingTask = true
        navigationMessage = "Finding the matching herdr pane…"
        let client = herdr.client
        let effects = HerdrOpenEffects(
            now: { Date().timeIntervalSince1970 },
            ttySupport: { await Task.detached { GhosttyScriptingSupport.ttySupport() }.value },
            revalidate: { [weak self] in
                guard let self else { return (.unavailable(.notScanned), nil) }
                return await self.revalidateHerdrBinding(for: key)
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
                herdr.open.failures[key] = failure
                // The grouped reason only; the exact failure stays in diagnostics.
                navigationMessage = HerdrPresentation.cardLine(for: .open(failure), agent: key.agent)
            }
            openingTask = false
            refresh()
        }
    }

    /// Called after each scheduled herdr scan. When focus moved to a pane bound to a session with
    /// queued completions, takes one fresh Ghostty inventory and applies ADR 0011's manual-visit rule.
    func observeHerdrVisit(_ outcome: HerdrScanOutcome) {
        guard let startedAt = herdr.monitor.latestStartedAt else { return }
        // The scan's start on the completions' clock: conservative, as the snapshot was read after it.
        let takenAt = Date().timeIntervalSince1970 - max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        let previous = herdr.open.previousFocus
        let current = HerdrFocusObservation.from(outcome, takenAt: takenAt)
        herdr.open.previousFocus = current
        guard let previous, let current, let pane = current.focusedPaneID, previous.focusedPaneID != pane,
              !herdr.open.checkingVisit, !openingTask else { return }
        let subjects = herdrVisitSubjects(boundTo: pane)
        guard !subjects.isEmpty else { return }
        herdr.open.checkingVisit = true
        Task { @MainActor in
            let ghosttyTakenAt = Date().timeIntervalSince1970
            let observed = await Task.detached { () -> (GhosttyTTYSupport, GhosttySnapshot?) in
                // Without `tty` the inventory still says whether Ghostty is frontmost (interim, issue #155).
                (GhosttyScriptingSupport.ttySupport(), GhosttyNavigation.snapshot())
            }.value
            herdr.open.checkingVisit = false
            guard ghosttyEnabled else { return }
            for subject in subjects {
                acknowledgeHerdrCompletions(HerdrOpenAcknowledgment.manualVisit(
                    herdrCompletions(subject), boundPaneID: pane, previous: previous, current: current,
                    support: observed.0, ghostty: observed.1, ghosttyTakenAt: ghosttyTakenAt), subject: subject)
            }
            refresh()
        }
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

    private func herdrCompletions(_ subject: HerdrOpenSubject) -> [HerdrCompletionCandidate<String>] {
        switch subject {
        case .codex(let session):
            return cliItems.filter { $0.session == session }
                .map { HerdrCompletionCandidate(id: $0.turn.uuidString, arrivedAt: $0.arrivedAt) }
        case .claude(let identity):
            return agentQueue.snapshot.outcomes.filter { $0.session == identity }
                .map { HerdrCompletionCandidate(id: $0.turn, arrivedAt: $0.arrivedAt) }
        }
    }

    private func acknowledgeHerdrCompletions(_ turns: Set<String>, subject: HerdrOpenSubject) {
        guard !turns.isEmpty else { return }
        switch subject {
        case .codex(let session):
            for item in cliItems where item.session == session && turns.contains(item.turn.uuidString) {
                queue.dismiss(.completion(item.id))
            }
        case .claude(let identity):
            for outcome in agentQueue.snapshot.outcomes where outcome.session == identity && turns.contains(outcome.turn) {
                agentQueue.dismiss(.outcome(outcome.id))
            }
        }
        saveCompletions()
    }
}
