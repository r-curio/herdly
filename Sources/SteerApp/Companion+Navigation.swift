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
