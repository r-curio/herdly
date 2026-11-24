import AppKit
import HerdlyCore

// Open for a Claude Desktop Code session (#471; HerdlyCore's ClaudeDesktop.swift). The registry is
// re-read at click time: only a session the complete inventories list exactly once, as running in
// Claude Desktop, is opened. Claude Desktop's own link selects the exact session, and the jump counts
// as reached only once Claude Desktop records that session's focus after the click. Anything else
// raises Claude Desktop with the card's note, or shows why Open is unavailable. No Open here
// acknowledges a result: for a desktop session only Dismiss does (agreed 2026-11-24).

extension Companion {
    /// Whether the latest inventories list this Claude session as running in Claude Desktop.
    func isClaudeDesktopSession(_ identity: AgentSessionIdentity) -> Bool {
        identity.source == .claude && claudeDesktopSessions.contains(identity)
    }

    func openClaudeInDesktop(_ identity: AgentSessionIdentity, request: ClaudeOpenRequest?) {
        openingTask = true
        let roots = configuredClaudeNavigationRoots()
        let support = ClaudeDesktopSessionIndex.defaultApplicationSupport
        let clickedAt = Date().timeIntervalSince1970
        // As the click lands: the notch panel does not take frontmost from the app under it.
        let claudeFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeDesktopSessionIndex.bundleIdentifier
        Task { @MainActor in
            let (inventories, index) = await Task.detached {
                (roots.map { ClaudeSetupDetection.activeSessionInventory(root: $0.root, capabilities: $0.capabilities) },
                 ClaudeDesktopSessionIndex.read(applicationSupport: support))
            }.value
            let currentScopes = Set(configuredClaudeNavigationRoots().map { $0.root.path })
            let complete = !inventories.isEmpty && Set(inventories.map(\.sourceScope)) == currentScopes
                && inventories.allSatisfy(\.available)
            let holders = inventories.flatMap(\.sessions).filter { $0.kind == .interactive && $0.sessionID == identity.session }
            let desktopHolder = inventories.first { $0.sourceScope == identity.sourceScope }?.sessions.contains {
                $0.kind == .interactive && $0.sessionID == identity.session && $0.host == .claudeDesktop
            } ?? false
            let plan = ClaudeDesktopOpen.plan(complete: complete, holders: holders.count, desktopHolder: desktopHolder,
                                              listedAnywhere: inventories.contains { $0.listedSessionIDs.contains(identity.session) },
                                              localID: index?.localID(for: identity.session),
                                              claudeRunning: Self.claudeDesktopRunning)
            let result: ClaudeDesktopOpen.Result
            switch plan {
            case .unavailable(let reason):
                result = .unavailable(reason)
            case .raise:
                result = Self.raiseClaudeDesktop()
            case .exact(let url):
                let localID = index?.localID(for: identity.session) ?? ""
                let showing = ClaudeDesktopOpen.alreadyShowing(localID: localID, claudeFrontmost: claudeFrontmost, index: index)
                let reached = NSWorkspace.shared.open(url)
                if reached, showing {
                    result = .opened
                } else if reached,
                   await Self.claudeDesktopFocused(localID: localID, clickedAt: clickedAt, applicationSupport: support) {
                    result = .opened
                } else {
                    result = Self.raiseClaudeDesktop()
                }
            }
            switch result.cardLine {
            case .some(let line): recordOpen(.unavailable(line), claude: identity)
            case nil: recordOpen(.opened, claude: identity)
            }
            // ADR 0015, #411: reaching the session or raising its app hands the request back with no
            // decision or answer, so Claude Desktop shows its own prompt.
            if result.handsBackRequest { handBackClaudeRequest(request) }
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    static var claudeDesktopRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopSessionIndex.bundleIdentifier).isEmpty
    }

    /// Brings Claude Desktop forward as a whole. Herdly never launches it.
    static func raiseClaudeDesktop() -> ClaudeDesktopOpen.Result {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeDesktopSessionIndex.bundleIdentifier)
        guard let app = apps.first else { return .unavailable(.claudeDesktopNotRunning) }
        return app.activate() ? .raised : .unavailable(.claudeDesktopNotRaised)
    }

    /// Polls the session's file until Claude Desktop records its focus after the click, for at most
    /// `ClaudeDesktopOpen.verificationTimeout`.
    static func claudeDesktopFocused(localID: String, clickedAt: Double, applicationSupport: URL) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + ClaudeDesktopOpen.verificationTimeout
        repeat {
            let focused = await Task.detached {
                ClaudeDesktopSessionIndex.lastFocusedAt(localID: localID, applicationSupport: applicationSupport)
            }.value
            if ClaudeDesktopOpen.verified(lastFocusedAt: focused, clickedAt: clickedAt) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
}
