import AppKit
import HerdlyCore

private enum SetupInstallResult: Sendable {
    case success(CodexConnectionStatus)
    case failure(String)
}

private enum SetupUndoResult: Sendable {
    case success(CodexConnectionStatus)
    case failure(String)
}

extension Companion {
    var setupRoots: CodexSetupRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let helper = home.appendingPathComponent("Library/Application Support/Herdly", isDirectory: true)
        return CodexSetupRoots(configDirectory: home.appendingPathComponent(".codex", isDirectory: true),
                               helperDirectory: helper, eventsDirectory: helper.appendingPathComponent("events", isDirectory: true))
    }

    func refreshLaunchAtLogin() {
        launchAtLoginCoordinator.refresh()
        launchAtLogin = launchAtLoginCoordinator.state
    }

    func launchAtLoginChanged(_ enabled: Bool) {
        launchAtLoginCoordinator.setEnabled(enabled)
        launchAtLogin = launchAtLoginCoordinator.state
    }

    func openLoginItemsSettings() {
        launchAtLoginCoordinator.openSystemSettings()
    }

    @objc func connectReminders() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.message = "Choose the Codex hook lab’s events folder. Herdly reads it without changing hooks."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        // Requests and running work belong to the old folder; undismissed completions are kept, now uncertain.
        queue = AttentionQueue(snapshot: queue.snapshot, observingSince: Date().timeIntervalSince1970)
        reminderPresentation.dismiss()
        questionPresentation.dismiss()
        completionPresentation = Attention(restored: queue.items.contains { $0.kind == .completion })
        eventsPath = url.path
        UserDefaults.standard.set(eventsPath, forKey: "approvalEventsPath")
        nextScan = 0
        refresh()
    }

    func refreshSetup() { refreshingSetup() }

    /// Starts a Codex setup detection; awaiting the task waits until its result has landed.
    @discardableResult
    func refreshingSetup() -> Task<Void, Never> {
        let roots = setupRoots
        return Task { @MainActor [weak self] in
            let (snapshot, helperUpdated) = await Task.detached {
                // Only Herdly's own unchanged helper is replaced; Codex's files are never touched here.
                let refresh = BundledHelper.validated.flatMap { try? CodexSetupInstaller().refreshHelper(roots: roots, helper: $0) }
                let capabilities = CodexSetupDetection.capabilities()
                return (CodexSetupDetection.setupSnapshot(roots: roots, capabilities: capabilities), refresh == .updated)
            }.value
            guard let self else { return }
            if helperUpdated { self.setupMessage = "Updated Herdly's Codex helper to match this version of Herdly." }
            self.setupCapabilities = snapshot.capabilities
            self.setupPlan = snapshot.plan
            self.setupStatus = snapshot.status
            self.setupChecked = true
            self.codexDetected()
            self.adoptInstalledEventsFolder(roots)
            // Until Codex is delivering events, the controls window is the only way to finish setup,
            // so a launch that finds setup incomplete shows it without waiting for a reopen.
            if !self.shownControlsForSetup, self.previewMode == nil {
                self.shownControlsForSetup = true
                if case .connected = snapshot.status {} else if self.launchAtLogin.shouldOpenUnconfiguredControls {
                    self.showControls()
                }
            }
        }
    }

    /// A connected install delivers to Herdly's own events folder; watch it even if an earlier lab
    /// folder was chosen or a previous Configure attempt ended before recording the path.
    private func adoptInstalledEventsFolder(_ roots: CodexSetupRoots) {
        guard previewMode == nil, Companion.argumentValue(for: "--reminder-events") == nil,
              Companion.argumentValue(for: "--desktop-events") == nil else { return }
        switch setupStatus {
        case .connected, .configuredAwaitingRestart, .permissionRequired: break
        default: return
        }
        let installed = roots.eventsDirectory.path
        guard eventsPath != installed else { return }
        queue = AttentionQueue(snapshot: queue.snapshot, observingSince: Date().timeIntervalSince1970)
        reminderPresentation.dismiss()
        questionPresentation.dismiss()
        completionPresentation = Attention(restored: queue.items.contains { $0.kind == .completion })
        eventsPath = installed
        UserDefaults.standard.set(installed, forKey: "approvalEventsPath")
        nextScan = 0
        refresh()
    }

    func configureCodex() {
        let roots = setupRoots
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await Task.detached {
                let capabilities = CodexSetupDetection.capabilities()
                return CodexSetupDetection.setupSnapshot(roots: roots, capabilities: capabilities)
            }.value
            self.setupCapabilities = snapshot.capabilities
            self.setupPlan = snapshot.plan
            self.setupStatus = snapshot.status
            guard let plan = self.setupPlan, case .ready = plan.status else {
                self.setupMessage = "Herdly cannot configure Codex until the setup preview is ready."
                return
            }
            let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HerdlyHook")
            guard let helper = CodexSetupDetection.boundedRegularData(at: helperURL, maximum: CodexSetupLimits.maximumFileSize) else {
                self.setupMessage = "The bundled Herdly helper is unavailable. Reinstall Herdly and try again."
                return
            }
            let helperIsValid = await Task.detached { CodexSetupDetection.validateHelper(helperURL) }.value
            guard helperIsValid else {
                self.setupMessage = "The bundled Herdly helper failed its self-test. Reinstall Herdly and try again."
                return
            }
            let result = await Task.detached {
                do {
                    return SetupInstallResult.success(
                        try CodexSetupInstaller().install(plan, roots: roots, helper: helper,
                                                          capabilities: snapshot.capabilities))
                } catch {
                    return SetupInstallResult.failure(error.localizedDescription)
                }
            }.value
            guard case .success(let status) = result else {
                if case .failure(let message) = result { self.setupMessage = message }
                self.refreshSetup()
                return
            }
            self.setupStatus = status
            switch status {
            case .connected, .configuredAwaitingRestart, .permissionRequired:
                self.eventsPath = roots.eventsDirectory.path
                UserDefaults.standard.set(self.eventsPath, forKey: "approvalEventsPath")
            default: break
            }
            self.setupMessage = self.setupStatusText + " Restart new Codex sessions to load settings; Herdly did not restart existing sessions. Review Codex's hook-trust prompt. Ghostty Automation permission is not verified; enable Ghostty controls to let macOS prompt."
        }
    }

    func undoCodexSetup() {
        let roots = setupRoots
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached {
                do { return SetupUndoResult.success(try CodexSetupInstaller().undo(roots: roots)) }
                catch { return SetupUndoResult.failure(error.localizedDescription) }
            }.value
            switch result {
            case .success(let status):
                self.setupStatus = status
                if self.eventsPath == roots.eventsDirectory.path {
                    self.eventsPath = ""
                    UserDefaults.standard.removeObject(forKey: "approvalEventsPath")
                }
                self.setupMessage = "Disconnected. Existing Codex approval and sandbox settings were left unchanged."
            case .failure(let message):
                self.setupMessage = message
                self.refreshSetup()
            }
        }
    }

    /// What the open queue says while it is empty, from both setups' connection status. Preview
    /// launches fix the reading so screenshots do not depend on this machine's setup.
    var emptyQueueReading: EmptyQueueReading {
        switch previewMode {
        case "empty-not-connected": return .notConnected
        case "empty-collapsed", "empty-expanded": return .nothingRunning(listening: [.codex, .claude])
        default:
            return .make(codexConnected: setupChecked ? setupStatus == .connected : nil,
                         claudeConnected: claude.checked ? claude.roots.contains { $0.status == .connected } : nil)
        }
    }

    var setupStatusText: String {
        switch setupStatus {
        case .connected: return "Codex event delivery connected"
        case .notConfigured: return "Codex detected; Herdly is not configured."
        case .configuredAwaitingRestart(let value), .unavailable(let value), .unsupported(let value), .permissionRequired(let value), .malformed(let value), .conflict(let value), .repairRequired(let value): return value
        }
    }

    var setupSurfaceStatusText: [String] {
        func text(_ name: String, installed: Bool, supported: Bool, version: String?, minimum: String) -> String {
            guard installed else { return "\(name): unavailable" }
            guard supported else { return "\(name) \(version ?? "version unknown"): unsupported; requires ≥ \(minimum)" }
            return "\(name) \(version ?? "version unknown"): available"
        }
        return [
            text("Codex CLI", installed: setupCapabilities.cliInstalled, supported: setupCapabilities.cli,
                 version: setupCapabilities.cliVersion, minimum: CodexSetupRequirements.minimumCLIVersion),
            text("Codex desktop", installed: setupCapabilities.desktopInstalled, supported: setupCapabilities.desktop,
                 version: setupCapabilities.desktopVersion, minimum: CodexSetupRequirements.minimumDesktopVersion),
            text("Ghostty", installed: setupCapabilities.ghosttyInstalled, supported: setupCapabilities.ghostty,
                 version: setupCapabilities.ghosttyVersion, minimum: CodexSetupRequirements.minimumGhosttyVersion)
        ]
    }

    var canUndoSetup: Bool {
        switch setupStatus {
        case .connected, .configuredAwaitingRestart, .permissionRequired: return true
        default: return false
        }
    }

    var canConfigureSetup: Bool {
        guard let plan = setupPlan, case .ready = plan.status else { return false }
        switch setupStatus {
        case .notConfigured, .repairRequired: return true
        default: return false
        }
    }
}
