import AppKit
import HerdlyCore

// Updating an outdated agent from its Settings problem row (#354, Paper "Update agents from
// Settings" U1–U7). The rules live in `AgentUpdates`; this file runs the command, opens Codex,
// reruns detection, and feeds SessionStart times in.
extension Companion {
    /// A problem row's button. A second press while that row is updating does nothing.
    func performAgentRowAction(_ target: AgentUpdateTarget, _ action: AgentRowAction) {
        switch action {
        case .none: return
        case .update(let command): runAgentUpdate(target, command: command)
        case .openApp(let path): openAppToUpdate(target, path: path)
        }
    }

    private func runAgentUpdate(_ target: AgentUpdateTarget, command: AgentUpdateCommand) {
        guard agentUpdates.begin(target) else { return }
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { AgentUpdateRunner.run(command) }.value
            guard let self else { return }
            // Success needs detection to see the new version, as Review Again would.
            let (version, meetsMinimum) = await self.redetect(target)
            let message = self.agentUpdates.finish(target, command: command, result: result, version: version,
                                                   meetsMinimum: meetsMinimum, now: Date().timeIntervalSince1970)
            if let message { self.showUpdateMessage(message, for: target.agent) }
        }
    }

    /// Herdly never updates the desktop app; it opens it so Codex can update itself (U4).
    private func openAppToUpdate(_ target: AgentUpdateTarget, path: String) {
        guard agentUpdates.state(target) != .updating else { return }
        observeCodexLaunches()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path),
                                           configuration: NSWorkspace.OpenConfiguration()) { _, error in
            let failure = error.map { _ in "Codex couldn't be opened" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failure { self.agentUpdates.openFailed(target, reason: failure) }
                else { self.agentUpdates.openedApp(target) }
            }
        }
    }

    private func redetect(_ target: AgentUpdateTarget) async -> (version: String?, meetsMinimum: Bool) {
        switch target {
        case .codexCLI:
            await refreshingSetup().value
            return (setupCapabilities.cliVersion, setupCapabilities.cli)
        case .codexDesktop:
            await refreshingSetup().value
            return (setupCapabilities.desktopVersion, setupCapabilities.desktop)
        case .claudeCode:
            await claude.refreshing().value
            // Every folder shares one `claude` executable, so the default folder's reading is the version.
            let capabilities = claude.roots.first?.capabilities
            return (capabilities?.version, capabilities?.supported ?? false)
        }
    }

    private func showUpdateMessage(_ message: String, for agent: AgentSource) {
        switch agent {
        case .codex: setupMessage = message
        case .claude: claude.message = message
        }
    }

    /// Called when a Codex setup detection lands: a desktop row waiting for Codex to update itself
    /// stops waiting once the version meets the minimum.
    func codexDetected() {
        guard agentUpdates.state(.codexDesktop) == .waitingForApp else { return }
        var next = agentUpdates
        let message = next.detected(.codexDesktop, version: setupCapabilities.desktopVersion,
                                    meetsMinimum: setupCapabilities.desktop, now: Date().timeIntervalSince1970)
        if next != agentUpdates { agentUpdates = next }
        if let message { showUpdateMessage(message, for: .codex) }
    }

    /// The newest SessionStart each agent has delivered; a later one than its update clears that
    /// agent's Restart required. Written back only when something changed, since the notch observes Companion.
    func noteSessionStarts(codex: Double?, claude: Double?) {
        var next = agentUpdates
        if let codex { next.sessionStarted(.codex, at: codex) }
        if let claude { next.sessionStarted(.claude, at: claude) }
        if next != agentUpdates { agentUpdates = next }
    }

    /// Codex desktop relaunches after updating itself; detect again then, while a row waits for it.
    private func observeCodexLaunches() {
        guard codexLaunchObserver == nil else { return }
        codexLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let launched = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard launched == "com.openai.codex" else { return }
            Task { @MainActor in
                guard let self, self.agentUpdates.state(.codexDesktop) == .waitingForApp else { return }
                self.refreshSetup()
            }
        }
    }
}
