import AppKit
import SwiftUI
import SteerCore

private enum SetupInstallResult: Sendable {
    case success(CodexConnectionStatus)
    case failure(String)
}

private enum SetupUndoResult: Sendable {
    case success(CodexConnectionStatus)
    case failure(String)
}

@MainActor
final class NotchPanel: NSPanel {
    /// Key status is only ever taken by a deliberate click or Tab into the panel; automatic
    /// presentation uses orderFrontRegardless, which never makes the panel key.
    override var canBecomeKey: Bool { true }
    var onEscape: (() -> Void)?

    /// Escape collapses the panel and returns keyboard input to the app the user was using.
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class Companion: NSObject, NSApplicationDelegate, ObservableObject {
    private enum GhosttyFocusState {
        case disabled
        case checking
        case known(GhosttySnapshot)
        case unknown
    }
    @Published var attention = Attention(restored: UserDefaults.standard.bool(forKey: "testCompletion"))
    @Published var muted = UserDefaults.standard.bool(forKey: "muted")
    @Published var taskID = ""
    @Published var navigationMessage = ""
    @Published var openingTask = false
    private static let launchedAt = Date().timeIntervalSince1970
    @Published var queue = AttentionQueue(snapshot: Companion.launchSnapshot, observingSince: Companion.launchedAt)
    @Published var reminderPresentation = Attention()
    @Published var eventsPath = UserDefaults.standard.string(forKey: "approvalEventsPath") ?? ""
    @Published var completionPresentation = Attention()
    private var savedSnapshot = Companion.launchSnapshot
    @Published var ghosttyEnabled = false
    @Published var ghosttyPermissionVerified = false
    @Published var setupStatus: CodexConnectionStatus = .notConfigured
    @Published var setupCapabilities = CodexCapabilities(cli: false, desktop: false, ghostty: false, supported: false)
    @Published var setupPlan: CodexSetupPlan?
    @Published var setupMessage = ""
    @Published var desktopForeground = false
    private let desktopAdapter = DesktopAdapter()
    private var cliSessions: Set<UUID> = []
    private var liveCLI: Set<UUID> = []
    private var checkingGhostty = false
    private var nextGhosttyScan: Double = 0
    private var checkingApprovalFocus = false
    private var nextApprovalFocusScan: Double = 0
    private var ghosttyFocusState: GhosttyFocusState = .disabled
    private var ghosttyUnavailable = false
    var visibleReminders: [Reminder] {
        queue.items.compactMap { $0.request }.map {
            Reminder(request_id: $0.id, session_id: $0.session, turn_id: $0.turn, outcome: "no_decision")
        }
    }
    var cliItems: [AttentionCompletion] {
        queue.items.compactMap(\.completion).filter { $0.source == .cli }
    }
    private var scanning = false
    private var nextScan: Double = 0
    var orderedAttentionItems: [AttentionItem] { queue.items }
    var count: Int { orderedAttentionItems.count + (attention.pending && !desktopForeground ? 1 : 0) }
    var workingCount: Int { orderedAttentionItems.filter { $0.kind == .running }.count }
    var toCheckCount: Int {
        orderedAttentionItems.filter { $0.kind != .running }.count + (attention.pending && !desktopForeground ? 1 : 0)
    }
    var expanded: Bool { attention.expanded || reminderPresentation.expanded || completionPresentation.expanded }
    var hovering = false
    private var status: NSStatusItem!
    private var panel: NSPanel!
    private var controls: NSWindow?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// The display the panel was last placed on; placement freezes here while the user interacts.
    private var currentDisplayID: UInt32?
    private var panelInteraction: Bool {
        NotchInteraction.isActive(pointerInside: hovering, keyboardFocus: panel.isKeyWindow)
    }
    private var setupRoots: CodexSetupRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let helper = home.appendingPathComponent("Library/Application Support/Steer", isDirectory: true)
        return CodexSetupRoots(configDirectory: home.appendingPathComponent(".codex", isDirectory: true),
                               helperDirectory: helper, eventsDirectory: helper.appendingPathComponent("events", isDirectory: true))
    }

    nonisolated static func argumentValue(for flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    /// Steer's own support directory, never Codex's. `--attention-snapshot` isolates lab runs.
    nonisolated static var snapshotURL: URL {
        if let path = argumentValue(for: "--attention-snapshot") { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steer/attention-snapshot.json")
    }

    nonisolated static let launchSnapshot = restoredSnapshot()

    /// The saved snapshot, or the pre-snapshot acknowledgment lists from UserDefaults when none exists yet.
    /// An unreadable or invalid snapshot loads as empty; startup never depends on it.
    nonisolated private static func restoredSnapshot() -> AttentionSnapshot {
        let snapshot = AttentionSnapshotStore.load(from: snapshotURL)
        guard snapshot == AttentionSnapshot(), !FileManager.default.fileExists(atPath: snapshotURL.path) else { return snapshot }
        let decoder = JSONDecoder()
        let cli = UserDefaults.standard.data(forKey: "cliAcknowledgments")
            .flatMap { try? decoder.decode(Set<TurnIdentity>.self, from: $0) } ?? []
        let desktop = UserDefaults.standard.data(forKey: "desktopAcknowledgments")
            .flatMap { try? decoder.decode(Set<TurnIdentity>.self, from: $0) } ?? []
        return AttentionSnapshot(legacyCLI: cli, legacyDesktop: desktop)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for flag in ["--reminder-events", "--desktop-events"] {
            if let path = Companion.argumentValue(for: flag) { eventsPath = path }
        }
        // Restored completions never replay their sound or popup.
        if queue.items.contains(where: { $0.kind == .completion }) { completionPresentation = Attention(restored: true) }
        // Checkpoint what was restored: the store keeps the current valid file as the fallback for the next
        // save, and rewrites a corrupt file from that fallback. A missing snapshot is not created here.
        if FileManager.default.fileExists(atPath: Companion.snapshotURL.path) {
            AttentionSnapshotStore.save(Companion.launchSnapshot, to: Companion.snapshotURL)
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.title = "S"
        status.button?.toolTip = "Steer"
        status.button?.setAccessibilityLabel("Steer prototype menu")
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Steer · Prototype", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        for (title, action) in [("Show Steer controls", #selector(showControls)),
                                ("Send test notification", #selector(sendTest)),
                                ("Dismiss test notification", #selector(dismissTest)),
                                ("Mute sound", #selector(toggleMute)),
                                ("Quit Steer", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            if action == #selector(toggleMute) { item.state = muted ? .on : .off }
            menu.addItem(item)
        }
        status.menu = menu
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Notch(model: self))
        (panel as? NotchPanel)?.onEscape = { [weak self] in self?.collapse() }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        // Display connect, disconnect, and rearrangement re-place the one panel; queue state is untouched.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        refreshSetup()
        // A first/unconfigured launch should explain setup immediately. Once state
        // exists, refresh can keep the normal quiet launch behavior.
        if !FileManager.default.fileExists(atPath: setupRoots.stateURL.path) { showControls() }
        if CommandLine.arguments.contains("--smoke-test") {
            showControls()
            precondition(controls?.isVisible == true && controls?.contentView != nil)
            precondition(status.button?.title == "S" && status.menu?.items.count == 6)
            print("Steer controls-window smoke check passed.")
            app.terminate(nil)
        }
        writePlacementProbeAndQuitIfRequested()
    }

    /// `--placement-probe <path>`: record the attached displays, the active-display choice, and the
    /// panel frames this build would use, then quit. It reads screen geometry only.
    private func writePlacementProbeAndQuitIfRequested() {
        guard let path = Companion.argumentValue(for: "--placement-probe") else { return }
        // An in-memory test item makes the panel present; nothing is written to UserDefaults.
        attention.enqueue()
        refresh()
        let displays = Companion.attachedDisplays()
        let pointer = NSEvent.mouseLocation
        let chosen = NotchDisplaySelection.choose(displays: displays, pointer: pointer, current: currentDisplayID, interacting: false)
        func rect(_ r: CGRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        let report: [String: Any] = [
            "displays": displays.map { ["id": Int($0.id), "frame": rect($0.frame), "top_inset": Double($0.topInset), "physical_notch": $0.hasPhysicalNotch] },
            "pointer": ["x": pointer.x, "y": pointer.y],
            "chosen_display": chosen.map { Int($0.id) } as Any,
            "collapsed_frame": chosen.map { rect(NotchPlacement.frame(on: $0, expanded: false, rows: 0, extraRows: false)) } as Any,
            "expanded_frame_three_rows": chosen.map { rect(NotchPlacement.frame(on: $0, expanded: true, rows: 3, extraRows: false)) } as Any,
            "panel_frame": rect(panel.frame),
            "codex_foreground": desktopForeground,
            "panel": ["level": panel.level.rawValue, "nonactivating": panel.styleMask.contains(.nonactivatingPanel),
                      "can_join_all_spaces": panel.collectionBehavior.contains(.canJoinAllSpaces),
                      "full_screen_auxiliary": panel.collectionBehavior.contains(.fullScreenAuxiliary),
                      "is_key_after_presentation": panel.isKeyWindow, "visible": panel.isVisible]
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
        app.terminate(nil)
    }

    /// AppKit screens as the placement rules see them. The top safe-area inset is the camera housing.
    nonisolated static func attachedDisplays() -> [NotchDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return NotchDisplay(id: number.uint32Value, frame: screen.frame, topInset: screen.safeAreaInsets.top)
        }
    }

    @objc func showControls() {
        if controls == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Steer — Prototype"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Controls(model: self))
            window.center()
            controls = window
        }
        controls?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return true
    }

    @objc func connectReminders() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.message = "Choose the Codex hook lab’s events folder. Steer reads it without changing hooks."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        // Requests and running work belong to the old folder; undismissed completions are kept, now uncertain.
        queue = AttentionQueue(snapshot: queue.snapshot, observingSince: Date().timeIntervalSince1970)
        reminderPresentation.dismiss()
        completionPresentation = Attention(restored: queue.items.contains { $0.kind == .completion })
        eventsPath = url.path
        UserDefaults.standard.set(eventsPath, forKey: "approvalEventsPath")
        nextScan = 0
        refresh()
    }

    func refreshSetup() {
        let roots = setupRoots
        Task { @MainActor [weak self] in
            let snapshot = await Task.detached {
                let capabilities = CodexSetupDetection.capabilities()
                return CodexSetupDetection.setupSnapshot(roots: roots, capabilities: capabilities)
            }.value
            guard let self else { return }
            self.setupCapabilities = snapshot.capabilities
            self.setupPlan = snapshot.plan
            self.setupStatus = snapshot.status
        }
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
                self.setupMessage = "Steer cannot configure Codex until the setup preview is ready."
                return
            }
            let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SteerHook")
            guard let helper = CodexSetupDetection.boundedRegularData(at: helperURL, maximum: 1_048_576) else {
                self.setupMessage = "The bundled Steer helper is unavailable. Reinstall Steer and try again."
                return
            }
            let helperIsValid = await Task.detached { CodexSetupDetection.validateHelper(helperURL) }.value
            guard helperIsValid else {
                self.setupMessage = "The bundled Steer helper failed its self-test. Reinstall Steer and try again."
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
            self.setupMessage = self.setupStatusText + " Restart new Codex sessions to load settings; Steer did not restart existing sessions. Review Codex's hook-trust prompt. Ghostty Automation permission is not verified; enable Ghostty controls to let macOS prompt."
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

    var setupStatusText: String {
        switch setupStatus {
        case .connected: return "Codex event delivery connected"
        case .notConfigured: return "Codex detected; Steer is not configured."
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

    func scanReminders() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !eventsPath.isEmpty, !scanning, now >= nextScan else { return }
        scanning = true
        nextScan = now + 2
        let events = URL(fileURLWithPath: eventsPath)
        let rolloutRoot = Companion.argumentValue(for: "--reminder-rollouts").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        Task { @MainActor in
            let result = await Task.detached {
                (ReminderReader.scan(events: events, rollouts: rolloutRoot), DesktopEventReader.read(from: events))
            }.value
            let scan = result.0
            let desktopEvents = result.1
            guard eventsPath == events.path else { scanning = false; refresh(); return }
            cliSessions = scan.cliSessions
            liveCLI = scan.cliState.liveSessions
            let previous = Set(queue.items.map(\.id))
            // A receipt found on disk is not a verified live interaction: such a request enters handed
            // back and, when a real helper receipt exists, a no-decision record releases it to Codex at once.
            let unverified = queue.apply(scan: scan, desktopEvents: desktopEvents, now: Date().timeIntervalSince1970)
            for request in unverified where ApprovalReceipts.existing(for: request.id, in: events) != nil {
                _ = ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .noDecision,
                                                                 decidedAt: Date().timeIntervalSince1970), in: events)
            }
            // Companion receipt: the deadline starts here, including for requests queued behind others.
            let receipted = ApprovalReceipts.issue(scan.awaitingReceipt, in: events, cliSessions: scan.cliSessions,
                                                   now: Date().timeIntervalSince1970)
            if !receipted.isEmpty { queue.recordReceipts(receipted, now: Date().timeIntervalSince1970) }
            let current = queue.items
            let newItems = current.filter { !previous.contains($0.id) }
            let newCompletions = newItems.compactMap(\.completion)
            if newCompletions.contains(where: { !$0.uncertain }) { completionPresentation.enqueue() }
            else if !newCompletions.isEmpty, !completionPresentation.pending { completionPresentation = Attention(restored: true) }
            if ghosttyEnabled && newCompletions.contains(where: { $0.source == .cli }) { nextGhosttyScan = 0 }
            if !current.contains(where: { $0.kind == .handedBackRequest || $0.kind == .actionableRequest }) { reminderPresentation.dismiss() }
            else if newItems.contains(where: { $0.kind == .handedBackRequest || $0.kind == .actionableRequest }) { reminderPresentation.enqueue() }
            if !current.contains(where: { $0.kind == .completion }) { completionPresentation.dismiss() }
            saveCompletions()
            scanning = false
            refresh()
            writeRestartReportAndQuitIfRequested(unverified: unverified)
        }
    }

    /// `--restart-report <path>`: after the first scan, record what a restart produced, then quit.
    /// Used by the restart lab; it reads nothing beyond the queue this process already holds.
    private func writeRestartReportAndQuitIfRequested(unverified: [AttentionRequest]) {
        guard let path = Companion.argumentValue(for: "--restart-report") else { return }
        let report: [String: Any] = [
            "snapshot": Companion.snapshotURL.path,
            "working_count": workingCount,
            "to_check_count": toCheckCount,
            "items": queue.items.map { item -> [String: Any] in
                var row: [String: Any] = ["kind": "\(item.kind)", "session": item.session.uuidString]
                if let completion = item.completion { row["turn"] = completion.turn.uuidString; row["uncertain"] = completion.uncertain
                                                     row["source"] = completion.source.rawValue }
                if let request = item.request { row["request"] = request.id.uuidString; row["state"] = "\(request.state)" }
                return row
            },
            "released_unverified_requests": unverified.map { $0.id.uuidString },
            "completion_presentation": ["pending": completionPresentation.pending, "presented": completionPresentation.presented,
                                        "expanded": completionPresentation.expanded],
            "acknowledged_count": queue.acknowledgedCompletions.count
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
        app.terminate(nil)
    }

    func refresh() {
        scanReminders()
        queue.expire(at: Date().timeIntervalSince1970)
        checkApprovalFocus()
        checkGhosttyFocus()
        // App identity only: no window contents, task titles, or accessibility queries.
        let codexForeground = desktopAdapter.codexForeground()
        desktopForeground = codexForeground == true
        // Desktop decision transport is unproven: release every desktop request at once.
        queue.items.compactMap(\.request)
            .filter { $0.state == .actionable && ApprovalHandoff.releasesOnReceipt(source: $0.source) }
            .forEach(handBackApproval)
        let interacting = panelInteraction
        var next = attention
        let firstPresentation = next.update(codexForeground: codexForeground, hovering: interacting,
                                            now: ProcessInfo.processInfo.systemUptime)
        if next.pending != attention.pending || next.presented != attention.presented || next.expanded != attention.expanded {
            attention = next
        }
        if firstPresentation && !muted { NSSound(named: "Glass")?.play() }
        // Use the same visibility as the count and rows, including CLI reminders.
        _ = reminderPresentation.update(codexForeground: visibleReminders.isEmpty, hovering: interacting,
                                        now: ProcessInfo.processInfo.systemUptime)
        var nextCompletionPresentation = completionPresentation
        let ghosttyFocus: CompletionFocus
        switch ghosttyFocusState {
        case .disabled: ghosttyFocus = .disabled
        case .checking: ghosttyFocus = .checking
        case .known(let snapshot): ghosttyFocus = snapshot.selected == nil ? .unknown : .away
        case .unknown: ghosttyFocus = .unknown
        }
        let canPresentCompletion = queue.items.contains { item in
            guard let completion = item.completion else { return false }
            guard CompletionVisibility.allows(source: completion.source, codexForeground: codexForeground,
                                             ghosttyFocus: ghosttyFocus) else { return false }
            guard completion.source == .cli, ghosttyEnabled else { return true }
            guard case .known(let snapshot) = ghosttyFocusState,
                  let target = GhosttyMatch.target(session: completion.session, live: liveCLI, snapshot: snapshot)
            else { return false }
            return snapshot.selected != target
        }
        let firstCompletionPresentation = nextCompletionPresentation.update(
            codexForeground: canPresentCompletion ? codexForeground : true,
            hovering: interacting,
            now: ProcessInfo.processInfo.systemUptime
        )
        completionPresentation = nextCompletionPresentation
        if CompletionSound.shouldPlay(firstPresentation: firstCompletionPresentation, muted: muted) {
            NSSound(named: "Glass")?.play()
        }
        guard DesktopVisibility.isVisible(hasActivity: count > 0, codexForeground: codexForeground) else {
            panel.orderOut(nil)
            hovering = false
            currentDisplayID = nil
            return
        }
        // One panel, one queue: the display is chosen by the documented rule and frozen while the
        // user is interacting, so controls never move away mid-action. Only geometry changes here.
        guard let display = NotchDisplaySelection.choose(displays: Companion.attachedDisplays(), pointer: NSEvent.mouseLocation,
                                                         current: currentDisplayID, interacting: interacting && panel.isVisible)
        else { panel.orderOut(nil); currentDisplayID = nil; return }
        currentDisplayID = display.id
        let frame = NotchPlacement.frame(on: display, expanded: expanded, rows: orderedAttentionItems.count,
                                         extraRows: attention.pending)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        // Never makes the panel key: an automatic notification does not take input from the user's app.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Collapses the panel and hands keyboard input back to the app the user was using.
    func collapse() {
        attention.collapse()
        reminderPresentation.collapse()
        completionPresentation.collapse()
        if panel.isKeyWindow {
            panel.orderOut(nil)
            NSWorkspace.shared.frontmostApplication?.activate()
        }
        refresh()
    }

    @objc func sendTest() {
        attention.enqueue()
        UserDefaults.standard.set(true, forKey: "testCompletion")
        refresh()
    }
    @objc func dismissTest() {
        attention.dismiss()
        UserDefaults.standard.set(false, forKey: "testCompletion")
        refresh()
    }
    @objc func toggleMute(_ sender: NSMenuItem) {
        muted.toggle()
        UserDefaults.standard.set(muted, forKey: "muted")
        sender.state = muted ? .on : .off
    }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func openTestTask() {
        guard !openingTask else { return }
        openingTask = true
        navigationMessage = "Opening link…"
        let id = taskID
        Task { @MainActor in
            let result = await desktopAdapter.open(taskID: id)
            navigationMessage = result.rawValue
            openingTask = false
            // Navigation never calls dismissTest or writes the saved completion flag.
        }
    }
    /// Persists unacknowledged completions and acknowledgments atomically whenever they change.
    func saveCompletions() {
        let snapshot = queue.snapshot
        guard snapshot != savedSnapshot else { return }
        if AttentionSnapshotStore.save(snapshot, to: Companion.snapshotURL) { savedSnapshot = snapshot }
    }
    func dismissAttention(_ item: AttentionCompletion) {
        switch item.source {
        case .desktop:
            queue.dismiss(.completion(item.id)); saveCompletions(); refresh()
        case .cli:
            queue.dismiss(.completion(item.id)); saveCompletions(); refresh()
        }
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
        !ghosttyEnabled && (!cliItems.isEmpty || visibleReminders.contains { cliSessions.contains($0.session_id) })
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

    func decide(_ request: AttentionRequest, as decision: ApprovalDecision) {
        // Re-read the queue's current copy: a request handed back since the row rendered must not be answered.
        guard !eventsPath.isEmpty else { navigationMessage = "Codex events are not connected."; refresh(); return }
        guard let current = queue.items.compactMap(\.request).first(where: { $0.identity == request.identity }) else {
            navigationMessage = "This request is no longer in the queue."; refresh(); return
        }
        guard ApprovalDecisionPolicy.accepts(current, decision: decision, now: Date().timeIntervalSince1970) else {
            navigationMessage = "This request was handed back to Codex; answer it there."; refresh(); return
        }
        let record = ApprovalDecisionRecord(requestID: request.id, decision: decision,
                                            decidedAt: Date().timeIntervalSince1970)
        guard ApprovalStore.publish(record, in: URL(fileURLWithPath: eventsPath)) else {
            navigationMessage = "This approval was already answered or is no longer available."
            refresh()
            return
        }
        queue.dismiss(.request(request.identity))
        navigationMessage = decision == .allowOnce ? "Approved once." : "Denied."
        refresh()
    }

    private func handBackApproval(_ request: AttentionRequest) {
        guard request.state == .actionable else { return }
        let now = Date().timeIntervalSince1970
        if !eventsPath.isEmpty {
            let events = URL(fileURLWithPath: eventsPath)
            let released = ApprovalStore.publish(ApprovalDecisionRecord(requestID: request.id, decision: .noDecision, decidedAt: now), in: events)
            if !released && ApprovalDecisions.existing(for: request.id, in: events) == nil {
                // The helper still waits for its own deadline; the row loses its controls regardless.
                navigationMessage = "Steer could not write the handoff record; Codex will show its own prompt within 30 seconds."
            }
        }
        let handedBack = AttentionRequest(id: request.id, source: request.source, session: request.session,
                                          turn: request.turn, arrivedAt: request.arrivedAt, expiresAt: request.expiresAt,
                                          state: .handedBack, details: request.details)
        queue.apply(requests: [handedBack], now: now)
    }

    private func checkApprovalFocus() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !checkingApprovalFocus, now >= nextApprovalFocusScan else { return }
        let requests = queue.items.compactMap(\.request).filter { $0.source == .cli && $0.state == .actionable }
        guard !requests.isEmpty else { return }
        nextApprovalFocusScan = now + 2
        guard ghosttyEnabled else {
            requests.filter { ApprovalHandoff.mustHandBack(source: $0.source, paneFocus: .disabled) }.forEach(handBackApproval)
            return
        }
        checkingApprovalFocus = true
        let live = liveCLI
        Task { @MainActor in
            let snapshot = await Task.detached { GhosttyNavigation.snapshot() }.value
            for request in requests {
                let focus: CompletionFocus
                if let snapshot, let target = GhosttyMatch.target(session: request.session, live: live, snapshot: snapshot) {
                    focus = snapshot.selected == target ? .focused : .away
                } else {
                    focus = .unknown
                }
                if ApprovalHandoff.mustHandBack(source: request.source, paneFocus: focus) { handBackApproval(request) }
            }
            checkingApprovalFocus = false
            refresh()
        }
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
    func checkGhosttyFocus() {
        let now = ProcessInfo.processInfo.systemUptime
        guard ghosttyEnabled, !checkingGhostty, !openingTask, now >= nextGhosttyScan,
              !cliItems.isEmpty else { return }
        checkingGhostty = true
        // Keep the last verified snapshot while a re-check is in flight. Resetting to
        // `.checking` every poll collapsed an already presented CLI popup early.
        if case .known = ghosttyFocusState {} else { ghosttyFocusState = .checking }
        nextGhosttyScan = now + 2
        let queued = cliItems
        Task { @MainActor in
            let snapshot = await Task.detached { GhosttyNavigation.snapshot() }.value
            if ghosttyEnabled, let snapshot {
                ghosttyPermissionVerified = true
                ghosttyFocusState = .known(snapshot)
                for session in Set(queued.map(\.session)) {
                    if let target = GhosttyMatch.target(session: session, live: liveCLI, snapshot: snapshot), snapshot.selected == target {
                        for item in queued where item.session == session {
                            queue.dismiss(.completion(CompletionIdentity(source: .cli, session: item.session, turn: item.turn)))
                        }
                    }
                }
                saveCompletions()
            } else if ghosttyEnabled {
                ghosttyFocusState = .unknown
                ghosttyUnavailable = true
                ghosttyEnabled = false
                ghosttyPermissionVerified = false
                navigationMessage = "Ghostty controls unavailable. Check Automation permission before enabling them again."
            }
            checkingGhostty = false
            refresh()
        }
    }
    func expand() {
        reminderPresentation.expand(now: ProcessInfo.processInfo.systemUptime)
        completionPresentation.expand(now: ProcessInfo.processInfo.systemUptime)
        attention.expand(now: ProcessInfo.processInfo.systemUptime)
        refresh()
    }

    func ghosttyChanged(_ enabled: Bool) {
        if !enabled && ghosttyUnavailable { return }
        ghosttyUnavailable = false
        ghosttyPermissionVerified = false
        ghosttyFocusState = enabled ? .checking : .disabled
        if enabled { nextGhosttyScan = 0 }
    }
}

struct Controls: View {
    @ObservedObject var model: Companion
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try your notch companion").font(.title3.bold())
            Text("Send a test, then switch between Codex and Notes. Returning to Codex hides the panel without clearing it.")
                .font(.callout).foregroundStyle(.secondary)
            Text("\(model.count) notifications queued")
                .font(.callout.weight(.medium))
            HStack {
                Button("Send test", action: model.sendTest).keyboardShortcut(.defaultAction)
                Button("Dismiss", action: model.dismissTest).disabled(!model.attention.pending)
                Spacer()
                Button("Quit", action: model.quit)
            }
            Divider()
            Text("Codex setup").font(.callout.weight(.medium))
            Text(model.setupStatusText).font(.caption).foregroundStyle(.secondary)
            ForEach(model.setupSurfaceStatusText, id: \.self) { status in
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let plan = model.setupPlan, case .ready = plan.status {
                Text(plan.requiresConfigure ? "Preview: add session-ID terminal titles and Steer-owned lifecycle hooks. Existing hooks and approval settings remain unchanged." : "The required Steer entries are already configured.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if plan.requiresConfigure {
                    DisclosureGroup("Show exact configuration preview") {
                        let hooks = String(data: plan.hooksChange, encoding: .utf8) ?? "(unreadable)"
                        Text("config.toml\n\(plan.configChange)\n\nhooks.json\n\(hooks)\n\nhelper command\n\(plan.helperCommand)")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button("Review again", action: model.refreshSetup)
                    Button("Configure Codex", action: model.configureCodex).disabled(!model.canConfigureSetup)
                    if model.canUndoSetup { Button("Undo setup", action: model.undoCodexSetup) }
                }
            } else {
                Button("Check Codex setup", action: model.refreshSetup)
            }
            if !model.setupMessage.isEmpty { Text(model.setupMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Divider()
            Button("Connect Codex events…", action: model.connectReminders)
            Text(model.eventsPath.isEmpty ? "Codex events are not connected." : "\(model.toCheckCount) to check · \(model.workingCount) working")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Enable Ghostty controls", isOn: $model.ghosttyEnabled)
                .onChange(of: model.ghosttyEnabled) { _, enabled in
                    model.ghosttyChanged(enabled)
                }
            Text("Requires session-ID terminal titles and one session per unsplit tab. Enabling may request macOS Automation access.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.ghosttyPermissionVerified ? "Ghostty Automation permission: verified by navigation probe." : "Ghostty Automation permission: not verified; enable controls to let macOS prompt.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Optional task-link check").font(.callout.weight(.medium))
            HStack {
                TextField("Local Codex task ID", text: $model.taskID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Local Codex task ID")
                Button("Open task", action: model.openTestTask).disabled(model.openingTask)
            }
            Text(model.navigationMessage.isEmpty ? "Opening a task will not dismiss your notification." : model.navigationMessage)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Menu-bar shortcut: S · Closing this window keeps Steer running.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 460, height: 700)
    }
}

struct Notch: View {
    @ObservedObject var model: Companion
    @FocusState private var headerFocused: Bool

    private func rowTitle(_ item: AttentionItem) -> String {
        switch item.kind {
        case .actionableRequest: return "Permission needed"
        case .handedBackRequest: return "Continue in Codex"
        case .completion: return item.completion?.source == .cli ? "Codex CLI finished" : "Codex desktop finished"
        case .running: return item.running?.source == .cli ? "Codex CLI working" : "Codex desktop working"
        }
    }

    private func rowSubject(_ item: AttentionItem) -> String {
        let session = "session \(item.session.uuidString.prefix(13))"
        guard let task = item.request?.details?.taskName, !task.isEmpty else { return session }
        return "\(task), \(session)"
    }

    @ViewBuilder
    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(rowTitle(item)).font(.headline).accessibilityAddTraits(.isHeader)
                switch item.kind {
                case .handedBackRequest:
                    Text("Handed back with no decision. Steer has not seen an answer yet; this clears when Codex records one, the turn ends, or the session ends.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .completion:
                    if item.completion?.uncertain == true {
                        Text("Queued before Steer last started. You may already have seen this result; Steer cannot verify it.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                case .actionableRequest, .running:
                    EmptyView()
                }
                Text("Session \(item.session.uuidString.prefix(13))").font(.caption).foregroundStyle(.secondary)
                if let details = item.request?.details {
                    // Long commands and reasons wrap in full; nothing is truncated with an ellipsis.
                    Group {
                        Text("Task: \(details.taskName ?? "Not provided by Codex")")
                        Text("Project: \(details.project ?? "Not provided by Codex")")
                        Text("Action: \(details.action ?? "Not provided by Codex")")
                        Text("Command: \(details.command ?? "Not provided by Codex")").textSelection(.enabled)
                        Text("Reason: \(details.reason ?? "Not provided by Codex")").textSelection(.enabled)
                    }
                    .font(.caption).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    if let longText = details.longText {
                        DisclosureGroup("Show full request") {
                            Text(longText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }.font(.caption).accessibilityLabel("Show full request for \(rowSubject(item))")
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                switch item.kind {
                case .actionableRequest:
                    if item.request?.source == .cli {
                        Button("Approve once") { if let request = item.request { model.decide(request, as: .allowOnce) } }
                            .accessibilityLabel("Approve once: \(rowSubject(item))")
                        Button("Deny") { if let request = item.request { model.decide(request, as: .deny) } }
                            .accessibilityLabel("Deny: \(rowSubject(item))")
                    }
                    Button("Open in Codex") {
                        if let request = item.request { model.openApprovalInCodex(request) }
                    }.disabled(model.openingTask)
                        .accessibilityLabel("Open in Codex: \(rowSubject(item))")
                        .accessibilityHint("Hands this request back to Codex's own prompt.")
                case .handedBackRequest:
                    Button("Open in Codex") {
                        if let request = item.request { model.openAttentionSession(source: request.source, session: request.session) }
                    }.disabled(model.openingTask)
                        .accessibilityLabel("Open in Codex: \(rowSubject(item))")
                case .completion:
                    Button("Open in Codex") {
                        if item.completion?.source == .cli { model.openCLI(item.session) }
                        else { model.openDesktop(item.session) }
                    }.disabled(model.openingTask)
                        .accessibilityLabel("Open in Codex: \(rowSubject(item))")
                    Button("Dismiss") {
                        if let completion = item.completion { model.dismissAttention(completion) }
                    }
                    .accessibilityLabel("Dismiss completion: \(rowSubject(item))")
                case .running:
                    Button("Open in Codex") {
                        if item.running?.source == .cli { model.openCLI(item.session) }
                        else { model.openDesktop(item.session) }
                    }.disabled(model.openingTask)
                        .accessibilityLabel("Open in Codex: \(rowSubject(item))")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rowTitle(item)), \(rowSubject(item))")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: model.expand) {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                    Text(model.workingCount == 0 ? "\(model.toCheckCount) to check" : "\(model.workingCount) working · \(model.toCheckCount) to check")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("STEER").font(.system(size: 9, weight: .medium)).foregroundStyle(.gray)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($headerFocused)
            // The plain style draws no focus ring of its own; keyboard focus stays visible here.
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(headerFocused ? 0.9 : 0), lineWidth: 2).padding(-4))
            .accessibilityLabel(model.workingCount == 0 ? "\(model.toCheckCount) to check" : "\(model.workingCount) working, \(model.toCheckCount) to check")
            .accessibilityHint(model.expanded ? "Steer attention queue is expanded." : "Expands the Steer attention queue.")
            if model.expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.orderedAttentionItems) { item in
                            attentionRow(item)
                        }
                        if model.needsGhosttySetup {
                            Text("Enable Ghostty controls in Steer’s controls window to open these sessions.").font(.caption)
                        }
                        if !model.navigationMessage.isEmpty { Text(model.navigationMessage).font(.caption) }
                        if model.attention.pending && !model.desktopForeground {
                            Text("Test notification").font(.headline)
                            Button("Dismiss", action: model.dismissTest).accessibilityLabel("Dismiss test notification")
                        }
                        Text("Tab moves between controls; Escape returns to your app.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .focusSection()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steer notch")
        .padding(.horizontal, 14)
        .padding(.vertical, model.expanded ? 16 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.12)))
        .preferredColorScheme(.dark)
        .onHover { model.hovering = $0 }
    }
}

let app = NSApplication.shared
let companion = Companion()
app.setActivationPolicy(.accessory)
app.delegate = companion
app.run()
