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
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Companion: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var attention = Attention(restored: UserDefaults.standard.bool(forKey: "testCompletion"))
    @Published var muted = UserDefaults.standard.bool(forKey: "muted")
    @Published var taskID = ""
    @Published var navigationMessage = ""
    @Published var openingTask = false
    @Published var queue: AttentionQueue = {
        let decoder = JSONDecoder()
        let cli = UserDefaults.standard.data(forKey: "cliAcknowledgments")
            .flatMap { try? decoder.decode(Set<TurnIdentity>.self, from: $0) } ?? []
        let desktop = UserDefaults.standard.data(forKey: "desktopAcknowledgments")
            .flatMap { try? decoder.decode(Set<TurnIdentity>.self, from: $0) } ?? []
        return AttentionQueue(acknowledged: Set((cli.map { CompletionIdentity(source: .cli, session: $0.session, turn: $0.turn) }
            + desktop.map { CompletionIdentity(source: .desktop, session: $0.session, turn: $0.turn) })))
    }()
    @Published var reminderPresentation = Attention()
    @Published var eventsPath = UserDefaults.standard.string(forKey: "approvalEventsPath") ?? ""
    @Published var cliPresentation = Attention()
    @Published var desktopPresentation = Attention()
    @Published var ghosttyEnabled = false
    @Published var ghosttyPermissionVerified = false
    @Published var setupStatus: CodexConnectionStatus = .notConfigured
    @Published var setupCapabilities = CodexCapabilities(cli: false, desktop: false, ghostty: false, supported: false)
    @Published var setupPlan: CodexSetupPlan?
    @Published var setupMessage = ""
    @Published var desktopForeground = false
    private let desktopAdapter = DesktopAdapter()
    private var firstDesktopScan = true
    private var cliSessions: Set<UUID> = []
    private var liveCLI: Set<UUID> = []
    private var firstCLIScan = true
    private var checkingGhostty = false
    private var nextGhosttyScan: Double = 0
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
    var expanded: Bool { attention.expanded || reminderPresentation.expanded || cliPresentation.expanded || desktopPresentation.expanded }
    var hovering = false
    private var status: NSStatusItem!
    private var panel: NSPanel!
    private var controls: NSWindow?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var setupRoots: CodexSetupRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let helper = home.appendingPathComponent("Library/Application Support/Steer", isDirectory: true)
        return CodexSetupRoots(configDirectory: home.appendingPathComponent(".codex", isDirectory: true),
                               helperDirectory: helper, eventsDirectory: helper.appendingPathComponent("events", isDirectory: true))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for flag in ["--reminder-events", "--desktop-events"] {
            if let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) {
                eventsPath = CommandLine.arguments[index + 1]
            }
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
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
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
        queue = AttentionQueue(acknowledged: queue.acknowledgedCompletions)
        firstCLIScan = true
        firstDesktopScan = true
        cliPresentation.dismiss()
        reminderPresentation.dismiss()
        desktopPresentation.dismiss()
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
        var rollouts = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        if let index = CommandLine.arguments.firstIndex(of: "--reminder-rollouts"), CommandLine.arguments.indices.contains(index + 1) {
            rollouts = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        let rolloutRoot = rollouts
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
            queue.apply(scan: scan, desktopEvents: desktopEvents, now: Date().timeIntervalSince1970)
            let current = queue.items
            let newItems = current.filter { !previous.contains($0.id) }
            if newItems.contains(where: { $0.kind == .completion }) {
                if firstCLIScan { cliPresentation = Attention(restored: true) }
                else { cliPresentation.enqueue() }
            }
            firstCLIScan = false
            if !current.contains(where: { $0.kind == .handedBackRequest || $0.kind == .actionableRequest }) { reminderPresentation.dismiss() }
            else if newItems.contains(where: { $0.kind == .handedBackRequest || $0.kind == .actionableRequest }) { reminderPresentation.enqueue() }
            if !current.contains(where: { $0.kind == .completion && $0.completion?.source == .desktop }) { desktopPresentation.dismiss() }
            else if firstDesktopScan { desktopPresentation = Attention(restored: true) }
            else if newItems.contains(where: { $0.kind == .completion && $0.completion?.source == .desktop }) { desktopPresentation.enqueue() }
            firstDesktopScan = false
            scanning = false
            refresh()
        }
    }

    func refresh() {
        scanReminders()
        checkGhosttyFocus()
        // App identity only: no window contents, task titles, or accessibility queries.
        let codexForeground = desktopAdapter.codexForeground()
        desktopForeground = codexForeground == true
        var next = attention
        let firstPresentation = next.update(codexForeground: codexForeground, hovering: hovering || panel.isKeyWindow,
                                            now: ProcessInfo.processInfo.systemUptime)
        if next.pending != attention.pending || next.presented != attention.presented || next.expanded != attention.expanded {
            attention = next
        }
        if firstPresentation && !muted { NSSound(named: "Glass")?.play() }
        // Use the same visibility as the count and rows, including CLI reminders.
        _ = reminderPresentation.update(codexForeground: visibleReminders.isEmpty, hovering: hovering || panel.isKeyWindow,
                                        now: ProcessInfo.processInfo.systemUptime)
        var nextDesktopPresentation = desktopPresentation
        let firstDesktopPresentation = nextDesktopPresentation.update(
            codexForeground: codexForeground, hovering: hovering || panel.isKeyWindow,
            now: ProcessInfo.processInfo.systemUptime
        )
        desktopPresentation = nextDesktopPresentation
        if firstDesktopPresentation && !muted { NSSound(named: "Glass")?.play() }
        if cliPresentation.update(codexForeground: false, hovering: hovering || panel.isKeyWindow,
                                  now: ProcessInfo.processInfo.systemUptime) && !muted { NSSound(named: "Glass")?.play() }
        guard DesktopVisibility.isVisible(hasActivity: count > 0, codexForeground: codexForeground) else {
            panel.orderOut(nil)
            hovering = false
            return
        }
        let screen = (hovering && panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else { panel.orderOut(nil); return }
        let width: CGFloat = expanded ? 380 : 210
        let rows = orderedAttentionItems.count
        let height: CGFloat = expanded ? min(380, 150 + CGFloat(rows) * 65 + (attention.pending ? 80 : 0)) : 34
        // Keep controls below physical camera housing; top-center on other displays.
        let top = screen.frame.maxY - max(screen.safeAreaInsets.top, 6) - 6
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: top - height,
                              width: width, height: height), display: true)
        panel.orderFrontRegardless()
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
    func saveCompletions() {
        let acknowledgments = queue.acknowledgedCompletions
        let cli = Set(acknowledgments.filter { $0.source == .cli }.map { TurnIdentity(session: $0.session, turn: $0.turn) })
        let desktop = Set(acknowledgments.filter { $0.source == .desktop }.map { TurnIdentity(session: $0.session, turn: $0.turn) })
        if let bytes = try? JSONEncoder().encode(cli) { UserDefaults.standard.set(bytes, forKey: "cliAcknowledgments") }
        if let bytes = try? JSONEncoder().encode(desktop) { UserDefaults.standard.set(bytes, forKey: "desktopAcknowledgments") }
        if !queue.items.contains(where: { $0.completion?.source == .cli }) { cliPresentation.dismiss() }
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
    func openAttentionSession(_ session: UUID) {
        if cliSessions.contains(session) { openCLI(session) }
        else { taskID = session.uuidString; openTestTask() }
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
        nextGhosttyScan = now + 2
        let queued = cliItems
        Task { @MainActor in
            let snapshot = await Task.detached { GhosttyNavigation.snapshot() }.value
            if ghosttyEnabled, let snapshot {
                ghosttyPermissionVerified = true
                for session in Set(queued.map(\.session)) {
                    if let target = GhosttyMatch.target(session: session, live: liveCLI, snapshot: snapshot), snapshot.selected == target {
                        for item in queued where item.session == session {
                            queue.dismiss(.completion(CompletionIdentity(source: .cli, session: item.session, turn: item.turn)))
                        }
                    }
                }
                saveCompletions()
            } else if ghosttyEnabled {
                ghosttyEnabled = false
                ghosttyPermissionVerified = false
                navigationMessage = "Ghostty controls unavailable. Check Automation permission before enabling them again."
            }
            checkingGhostty = false
            refresh()
        }
    }
    func expand() {
        cliPresentation.expand(now: ProcessInfo.processInfo.systemUptime)
        reminderPresentation.expand(now: ProcessInfo.processInfo.systemUptime)
        desktopPresentation.expand(now: ProcessInfo.processInfo.systemUptime)
        attention.expand(now: ProcessInfo.processInfo.systemUptime)
        refresh()
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
                    if !enabled { model.ghosttyPermissionVerified = false }
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

    @ViewBuilder
    private func attentionRow(_ item: AttentionItem) -> some View {
        HStack {
            VStack(alignment: .leading) {
                switch item.kind {
                case .actionableRequest:
                    Text("Permission needed").font(.headline)
                case .handedBackRequest:
                    Text("Continue in Codex").font(.headline)
                case .completion:
                    Text(item.completion?.source == .cli ? "Codex CLI finished" : "Codex desktop finished").font(.headline)
                case .running:
                    Text(item.running?.source == .cli ? "Codex CLI working" : "Codex desktop working").font(.headline)
                }
                Text("Session \(item.session.uuidString.prefix(13))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch item.kind {
            case .actionableRequest, .handedBackRequest:
                Button("Open in Codex") { model.openAttentionSession(item.session) }
                    .disabled(model.openingTask)
            case .completion:
                Button("Open in Codex") {
                    if item.completion?.source == .cli { model.openCLI(item.session) }
                    else { model.openDesktop(item.session) }
                }.disabled(model.openingTask)
                Button("Dismiss") {
                    if let completion = item.completion { model.dismissAttention(completion) }
                }
            case .running:
                Button("Open in Codex") {
                    if item.running?.source == .cli { model.openCLI(item.session) }
                    else { model.openDesktop(item.session) }
                }.disabled(model.openingTask)
            }
        }
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
            .accessibilityLabel("\(model.count) notifications. Expand details")
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
                            Button("Dismiss", action: model.dismissTest)
                        }
                    }
                }
            }
        }
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
