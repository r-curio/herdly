import AppKit
import SwiftUI
import SteerCore

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
    @Published var reminders = ReminderQueue()
    @Published var reminderPresentation = Attention()
    @Published var eventsPath = UserDefaults.standard.string(forKey: "approvalEventsPath") ?? ""
    @Published var cli = CLIQueue(acknowledged: UserDefaults.standard.data(forKey: "cliAcknowledgments")
        .flatMap { try? JSONDecoder().decode(Set<TurnIdentity>.self, from: $0) } ?? [])
    @Published var cliPresentation = Attention()
    @Published var ghosttyEnabled = false
    @Published var desktopForeground = false
    private var cliSessions: Set<UUID> = []
    private var liveCLI: Set<UUID> = []
    private var firstCLIScan = true
    private var checkingGhostty = false
    private var nextGhosttyScan: Double = 0
    var visibleReminders: [Reminder] { reminders.items.filter { !desktopForeground || cliSessions.contains($0.session_id) } }
    private var scanning = false
    private var nextScan: Double = 0
    var count: Int { visibleReminders.count + cli.items.count + (attention.pending && !desktopForeground ? 1 : 0) }
    var expanded: Bool { attention.expanded || reminderPresentation.expanded || cliPresentation.expanded }
    var hovering = false
    private var status: NSStatusItem!
    private var panel: NSPanel!
    private var controls: NSWindow?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--reminder-events"), CommandLine.arguments.indices.contains(index + 1) {
            eventsPath = CommandLine.arguments[index + 1]
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
        showControls()
        if CommandLine.arguments.contains("--smoke-test") {
            precondition(controls?.isVisible == true && controls?.contentView != nil)
            precondition(status.button?.title == "S" && status.menu?.items.count == 6)
            print("Steer controls-window smoke check passed.")
            app.terminate(nil)
        }
    }

    @objc func showControls() {
        if controls == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 570),
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
        reminders = ReminderQueue()
        cli = CLIQueue(acknowledged: cli.acknowledged)
        firstCLIScan = true
        cliPresentation.dismiss()
        reminderPresentation.dismiss()
        eventsPath = url.path
        UserDefaults.standard.set(eventsPath, forKey: "approvalEventsPath")
        nextScan = 0
        refresh()
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
            let scan = await Task.detached { ReminderReader.scan(events: events, rollouts: rolloutRoot) }.value
            guard eventsPath == events.path else { scanning = false; refresh(); return }
            let previous = Set(reminders.items.map(\.id))
            reminders.apply(scan)
            cliSessions = scan.cliSessions
            liveCLI = scan.liveCLISessions
            let beforeCLI = Set(cli.items.map(\.id))
            cli.apply(scan.cliCompletions)
            if !cli.items.isEmpty {
                if firstCLIScan { cliPresentation = Attention(restored: true) }
                else if cli.items.contains(where: { !beforeCLI.contains($0.id) }) { cliPresentation.enqueue() }
            }
            firstCLIScan = false
            if reminders.items.isEmpty { reminderPresentation.dismiss() }
            else if reminders.items.contains(where: { !previous.contains($0.id) }) { reminderPresentation.enqueue() }
            scanning = false
            refresh()
        }
    }

    func refresh() {
        scanReminders()
        checkGhosttyFocus()
        // App identity only: no window contents, task titles, or accessibility queries.
        let codexForeground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map { $0 == "com.openai.codex" }
        desktopForeground = codexForeground == true
        var next = attention
        let firstPresentation = next.update(codexForeground: codexForeground, hovering: hovering || panel.isKeyWindow,
                                            now: ProcessInfo.processInfo.systemUptime)
        if next.pending != attention.pending || next.presented != attention.presented || next.expanded != attention.expanded {
            attention = next
        }
        if firstPresentation && !muted { NSSound(named: "Glass")?.play() }
        _ = reminderPresentation.update(codexForeground: codexForeground, hovering: hovering || panel.isKeyWindow,
                                        now: ProcessInfo.processInfo.systemUptime)
        if cliPresentation.update(codexForeground: false, hovering: hovering || panel.isKeyWindow,
                                  now: ProcessInfo.processInfo.systemUptime) && !muted { NSSound(named: "Glass")?.play() }
        guard count > 0 else {
            panel.orderOut(nil)
            hovering = false
            return
        }
        let screen = (hovering && panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        guard let screen else { panel.orderOut(nil); return }
        let width: CGFloat = expanded ? 380 : 210
        let height: CGFloat = expanded ? min(380, 100 + CGFloat(visibleReminders.count + cli.items.count) * 65 + (attention.pending ? 80 : 0)) : 34
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
        let installations = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.openai.codex" }
            .map(\.bundleURL)
        Task { @MainActor in
            let result = await DesktopNavigation.open(taskID: id, runningAppURLs: installations) { task, installation in
                _ = try await NSWorkspace.shared.open([task], withApplicationAt: installation,
                                                     configuration: NSWorkspace.OpenConfiguration())
            }
            navigationMessage = result.rawValue
            openingTask = false
            // Navigation never calls dismissTest or writes the saved completion flag.
        }
    }
    func saveCLI() {
        if let bytes = try? JSONEncoder().encode(cli.acknowledged) { UserDefaults.standard.set(bytes, forKey: "cliAcknowledgments") }
        if cli.items.isEmpty { cliPresentation.dismiss() }
    }
    func dismissCLI(_ id: TurnIdentity) { cli.dismiss(id); saveCLI(); refresh() }
    func openCLI(_ session: UUID) {
        guard ghosttyEnabled, !openingTask else { return }
        openingTask = true
        navigationMessage = "Finding the matching Ghostty tab…"
        let live = liveCLI
        let queued = cli.items.filter { $0.session == session }.map(\.id)
        Task { @MainActor in
            let opened = await Task.detached { GhosttyNavigation.open(session: session, live: live) }.value
            navigationMessage = opened ? "Opened the matching Ghostty tab." : "Could not verify the matching tab. Check its session-ID title and Automation permission."
            // A verified visit acknowledges only completions already queued for this session.
            if opened { for id in queued { cli.dismiss(id) }; saveCLI() }
            openingTask = false
            refresh()
        }
    }
    func canOpenReminder(_ item: Reminder) -> Bool { !openingTask && (!cliSessions.contains(item.session_id) || ghosttyEnabled) }
    func openReminder(_ item: Reminder) {
        if cliSessions.contains(item.session_id) { openCLI(item.session_id) }
        else { taskID = item.session_id.uuidString; openTestTask() }
    }
    func checkGhosttyFocus() {
        let now = ProcessInfo.processInfo.systemUptime
        guard ghosttyEnabled, !checkingGhostty, !openingTask, now >= nextGhosttyScan,
              !cli.items.isEmpty else { return }
        checkingGhostty = true
        nextGhosttyScan = now + 2
        let queued = cli.items
        Task { @MainActor in
            let snapshot = await Task.detached { GhosttyNavigation.snapshot() }.value
            if ghosttyEnabled, let snapshot {
                for session in Set(queued.map(\.session)) {
                    if let target = GhosttyMatch.target(session: session, live: liveCLI, snapshot: snapshot), snapshot.selected == target {
                        for item in queued where item.session == session { cli.dismiss(item.id) }
                    }
                }
                saveCLI()
            } else if ghosttyEnabled {
                ghosttyEnabled = false
                navigationMessage = "Ghostty controls unavailable. Check Automation permission before enabling them again."
            }
            checkingGhostty = false
            refresh()
        }
    }
    func expand() {
        cliPresentation.expand(now: ProcessInfo.processInfo.systemUptime)
        reminderPresentation.expand(now: ProcessInfo.processInfo.systemUptime)
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
            Button("Connect Codex events…", action: model.connectReminders)
            Text(model.eventsPath.isEmpty ? "Codex events are not connected." : "\(model.reminders.items.count) reminders · \(model.cli.items.count) CLI completions")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Enable Ghostty controls", isOn: $model.ghosttyEnabled)
            Text("Requires session-ID terminal titles and one session per unsplit tab. Enabling may request macOS Automation access.")
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
        .frame(width: 460, height: 570)
    }
}

struct Notch: View {
    @ObservedObject var model: Companion
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: model.expand) {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.mint)
                    Text("\(model.count) to check").font(.system(size: 13, weight: .semibold))
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
                        ForEach(model.visibleReminders) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Continue in Codex").font(.headline)
                                    Text("Task \(item.session_id.uuidString.prefix(8))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open in Codex") {
                                    model.openReminder(item)
                                }.disabled(!model.canOpenReminder(item))
                            }
                        }
                        ForEach(model.cli.items) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Codex CLI finished").font(.headline)
                                    Text("Session \(item.session.uuidString.prefix(13))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open in Codex") { model.openCLI(item.session) }
                                    .disabled(model.openingTask || !model.ghosttyEnabled)
                                Button("Dismiss") { model.dismissCLI(item.id) }
                            }
                        }
                        if !model.cli.items.isEmpty && !model.ghosttyEnabled {
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
