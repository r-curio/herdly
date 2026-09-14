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
    /// True once the user has clicked in the panel; launch or app activation can also make the
    /// panel key, and that must not count as the user interacting with it.
    private(set) var clickedForKey = false

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { clickedForKey = true }
        super.sendEvent(event)
    }

    override func resignKey() {
        clickedForKey = false
        super.resignKey()
    }

    /// Keyboard focus the user asked for by clicking, as opposed to key status handed over at launch.
    var hasDeliberateKeyboardFocus: Bool { isKeyWindow && clickedForKey }

    /// Escape collapses the panel and returns keyboard input to the app the user was using.
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// AppKit pulls a frame back on screen; the tucked strip rests entirely above the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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
    @Published var questionPresentation = Attention()
    /// Steer's own bookkeeping of what it relayed for each waiting question. Memory only: a restart
    /// returns every question as plain pending and nothing is ever re-sent.
    @Published var answerProgress: [QuestionIdentity: QuestionAnswerProgress] = [:]
    private var answering = false
    /// Steer's own bookkeeping of the one reply each completion card sent. Memory only, and a card
    /// that has sent one never sends another.
    @Published var replyProgress: [CompletionIdentity: SessionReplyProgress] = [:]
    private var replying = false
    /// Sessions Codex recorded as ended; a completion for one has nothing left to reply to.
    @Published var endedSessions: Set<UUID> = []
    /// The second client on Codex's app-server daemon socket, when one exists. Inert otherwise.
    private let daemonClient = AppServerDaemonClient(socketPath: Companion.daemonSocketPath)
    /// The daemon's pending question requests on the current connection, and the ones Steer answered.
    @Published var daemonBook = AppServerQuestionBook()
    @Published var daemonStatus = "Codex daemon: not checked yet."
    /// The daemon path is available; the preview renders it with a seeded request.
    var daemonConnected: Bool { daemonClient.isConnected || previewMode != nil }
    private var savedSnapshot = Companion.launchSnapshot
    @Published var ghosttyEnabled = false
    @Published var ghosttyPermissionVerified = false
    /// Read the Codex desktop app's own unread flags to acknowledge desktop completions it has
    /// cleared. Private format; on by default, off with one switch when a desktop update breaks it.
    @Published var desktopReadStateEnabled = UserDefaults.standard.object(forKey: "desktopReadStateEnabled") as? Bool ?? true
    @Published var desktopReadStateMessage = "Desktop read state: not checked yet."
    /// Codex's own thread names by session, refreshed every scan; unknown sessions keep their identifier.
    @Published var threadNames: [UUID: String] = [:]
    /// Codex's weekly usage limit from the newest rollout, refreshed every scan; nil until one is read.
    @Published var weeklyLimit: CodexWeeklyLimit?
    /// The strip's weekly reading: only a window that has not yet reset is shown.
    var currentWeeklyLimit: CodexWeeklyLimit? {
        weeklyLimit.flatMap { $0.isCurrent(now: Date().timeIntervalSince1970) ? $0 : nil }
    }
    /// `--reminder-rollouts <path>` points lab runs at a copy of Codex's sessions tree.
    nonisolated static var rolloutRoot: URL {
        argumentValue(for: "--reminder-rollouts").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }
    /// `--daemon-socket <path>` points lab runs at another app-server socket.
    nonisolated static var daemonSocketPath: String {
        argumentValue(for: "--daemon-socket") ?? AppServerDaemonClient.defaultSocketPath
    }
    /// `--thread-names <path>` points lab runs at a copy instead of the live Codex index.
    nonisolated static var threadNamesURL: URL {
        if let path = argumentValue(for: "--thread-names") { return URL(fileURLWithPath: path) }
        return ThreadNameReader.defaultURL(codexHome: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true))
    }
    /// `--desktop-read-state <path>` points lab runs at a copy instead of the live Codex file.
    nonisolated static var desktopReadStateURL: URL {
        if let path = argumentValue(for: "--desktop-read-state") { return URL(fileURLWithPath: path) }
        return DesktopReadStateReader.defaultURL(codexHome: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true))
    }
    @Published var setupStatus: CodexConnectionStatus = .notConfigured
    @Published var setupCapabilities = CodexCapabilities(cli: false, desktop: false, ghostty: false, supported: false)
    @Published var setupPlan: CodexSetupPlan?
    @Published var setupMessage = ""
    @Published var desktopForeground = false
    private let desktopAdapter = DesktopAdapter()
    private var cliSessions: Set<UUID> = []
    private var liveCLI: Set<UUID> = []
    /// Sessions a Ghostty inventory proved CLI by their session-id title, this launch. They stay CLI
    /// after the tab closes, and that closing ends them (`ReminderReader.scan`). Memory only.
    private var knownCLISessions: Set<UUID> = []
    /// Unix time of the inventory in `ghosttyFocusState`, for dating a session end at the tab's absence.
    private var ghosttyInventoryAt: Double = 0
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
    /// Presentation state the notch view renders. `showAll` is hover or keyboard focus: the whole
    /// queue. `spotlightItem` is the one new item a completion or request opened the panel for.
    @Published var expanded = false
    @Published var showAll = false
    @Published var spotlightItem: AttentionItemID?
    @Published var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// Natural height of the open panel's content, reported by the view after layout.
    var contentHeight: CGFloat = 0
    /// How the strip splits around the housing on the current display; the view lays out by it.
    @Published var stripLayout = StripLayout(leading: 140, gap: 0, trailing: 60, height: NotchPlacement.collapsedHeight)
    var hovering = false
    private var hoverHold = HoverHold()
    private var hoverHeld = false
    /// After Escape, hover does not reopen the panel until the pointer has left it.
    private var hoverSuppressed = false
    private var spotlight = Spotlight()
    private var manualOpen = false
    private var latestNewRequest: AttentionItemID?
    private var latestNewCompletion: AttentionItemID?
    private var latestNewQuestion: AttentionItemID?
    private var targetFrame: CGRect = .zero
    /// `--preview-queue <collapsed|spotlight|expanded>` seeds in-memory sample items for screenshots.
    /// It never scans Codex events, never saves, and never releases approvals.
    let previewMode = Companion.argumentValue(for: "--preview-queue")
    private var status: NSStatusItem!
    private var panel: NotchPanel!
    private var controls: NSWindow?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// The display the panel was last placed on; placement freezes here while the user interacts.
    private var currentDisplayID: UInt32?
    /// SwiftUI's hover flag can go stale when the panel is re-placed out from under the pointer
    /// (a display disconnect, for example), so it is confirmed against the actual pointer location.
    private var pointerInsidePanel: Bool {
        hovering && panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
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
        // No window shadow: its rim would outline the panel and break the fusion with the menu bar.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Notch(model: self))
        panel.onEscape = { [weak self] in self?.collapse() }
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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
        daemonClient.onMessage = { [weak self] message in
            guard let self else { return }
            _ = self.daemonBook.apply(message: message, now: Date().timeIntervalSince1970)
        }
        daemonClient.onDisconnect = { [weak self] in self?.daemonBook.disconnect() }
        if let mode = previewMode { seedPreview(mode) }
        refresh()
        refreshSetup()
        // A first/unconfigured launch should explain setup immediately. Once state
        // exists, refresh can keep the normal quiet launch behavior.
        if previewMode == nil, !FileManager.default.fileExists(atPath: setupRoots.stateURL.path) { showControls() }
        if CommandLine.arguments.contains("--smoke-test") {
            showControls()
            precondition(controls?.isVisible == true && controls?.contentView != nil)
            precondition(status.button?.title == "S" && status.menu?.items.count == 6)
            print("Steer controls-window smoke check passed.")
            app.terminate(nil)
        }
        writePlacementProbeAndQuitIfRequested()
        printSetupProbeAndQuitIfRequested()
    }

    /// `--setup-probe`: print the Codex setup status and plan this build computes, then quit.
    /// It reads the same files the controls window reads and changes nothing.
    private func printSetupProbeAndQuitIfRequested() {
        guard CommandLine.arguments.contains("--setup-probe") else { return }
        let roots = setupRoots
        let capabilities = CodexSetupDetection.capabilities()
        let snapshot = CodexSetupDetection.setupSnapshot(roots: roots, capabilities: capabilities)
        print("status: \(snapshot.status)")
        print("capabilities: cli=\(capabilities.cli) desktop=\(capabilities.desktop) ghostty=\(capabilities.ghostty) supported=\(capabilities.supported)")
        if let plan = snapshot.plan {
            print("plan: \(plan.status) requiresConfigure=\(plan.requiresConfigure)")
            print("config change adds hooks flag: \(CodexSetupValidator.hasHooksEnabled(in: plan.configChange))")
        } else {
            print("plan: nil (config or hooks unreadable)")
        }
        app.terminate(nil)
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
            "chosen_display": chosen.map { Int($0.id) } ?? NSNull(),
            "collapsed_frame": chosen.map { rect(NotchPlacement.frame(on: $0, expanded: false, rows: 0, extraRows: false)) } ?? NSNull(),
            "expanded_frame_three_rows": chosen.map { rect(NotchPlacement.frame(on: $0, expanded: true, rows: 3, extraRows: false)) } ?? NSNull(),
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

    /// AppKit screens as the placement rules see them. The top safe-area inset is the camera housing;
    /// the menu bar height is that of the bar actually showing on the screen, zero under a
    /// full-screen app or an auto-hidden bar (`visibleFrame` reserves the strip either way).
    nonisolated static func attachedDisplays() -> [NotchDisplay] {
        let menuBars = shownMenuBars()
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            var housing: CGFloat = 0
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                housing = max(0, screen.frame.width - left.width - right.width)
            }
            let menuBar = NotchDisplay.shownMenuBarHeight(on: screen.frame, menuBars: menuBars)
            return NotchDisplay(id: number.uint32Value, frame: screen.frame, topInset: screen.safeAreaInsets.top,
                                housingWidth: housing, menuBarHeight: menuBar,
                                isBuiltIn: CGDisplayIsBuiltin(number.uint32Value) != 0)
        }
    }

    /// The menu bar windows the window server has on screen, in AppKit global coordinates. The
    /// window server draws one per display that is showing a menu bar, at the main-menu window
    /// level; a display under a full-screen app has none. Owner and level are readable without
    /// Screen Recording permission; window names are not, so they are not used.
    nonisolated static func shownMenuBars() -> [CGRect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        return windows.compactMap { window in
            guard window[kCGWindowOwnerName as String] as? String == "Window Server",
                  window[kCGWindowLayer as String] as? Int == menuLevel,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            // Core Graphics measures from the top-left of the primary display; AppKit from its bottom-left.
            return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
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
        questionPresentation.dismiss()
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
            self.adoptInstalledEventsFolder(roots)
            // Until Codex is delivering events, the controls window is the only way to finish setup,
            // so a launch that finds setup incomplete shows it without waiting for a reopen.
            if !self.shownControlsForSetup, self.previewMode == nil {
                self.shownControlsForSetup = true
                if case .connected = snapshot.status {} else { self.showControls() }
            }
        }
    }
    private var shownControlsForSetup = false

    /// A connected install delivers to Steer's own events folder; watch it even if an earlier lab
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
                self.setupMessage = "Steer cannot configure Codex until the setup preview is ready."
                return
            }
            let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SteerHook")
            guard let helper = CodexSetupDetection.boundedRegularData(at: helperURL, maximum: CodexSetupLimits.maximumFileSize) else {
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
        guard previewMode == nil, !eventsPath.isEmpty, !scanning, now >= nextScan else { return }
        scanning = true
        nextScan = now + 2
        let events = URL(fileURLWithPath: eventsPath)
        let rolloutRoot = Companion.rolloutRoot
        let readStateURL = desktopReadStateEnabled ? Companion.desktopReadStateURL : nil
        let namesURL = Companion.threadNamesURL
        // Ghostty's current tab titles prove which sessions are CLI sessions when the rollout header
        // cannot (a TUI on the app-server daemon is recorded as `vscode`). Empty with controls off.
        let inventory: GhosttyInventory? = {
            if case .known(let snapshot) = ghosttyFocusState, snapshot.status == "ok" {
                return GhosttyInventory(titles: snapshot.terminalNames, takenAt: ghosttyInventoryAt)
            }
            return nil
        }()
        let known = knownCLISessions
        let daemonThreads = daemonClient.loadedThreads
        Task { @MainActor in
            let result = await Task.detached {
                (ReminderReader.scan(events: events, rollouts: rolloutRoot, ghostty: inventory, knownCLISessions: known,
                                     daemonThreads: daemonThreads), DesktopEventReader.read(from: events),
                 readStateURL.flatMap(DesktopReadStateReader.read), ThreadNameReader.read(namesURL) ?? [:],
                 CodexUsageReader.latest(root: rolloutRoot),
                 SessionDiscovery.candidates(root: rolloutRoot, now: Date().timeIntervalSince1970),
                 ProcessList.arguments().map(CodexCLIProcesses.isRunning(processList:)) ?? false)
            }.value
            let scan = result.0
            let desktopEvents = result.1
            let readState = result.2
            guard eventsPath == events.path else { scanning = false; refresh(); return }
            if threadNames != result.3 { threadNames = result.3 }
            if weeklyLimit != result.4 { weeklyLimit = result.4 }
            // Sessions already working before their first hook event: shown only with liveness
            // evidence, and only as working (see docs/session-discovery.md).
            let candidates = result.5
            let cliCandidates = Set(candidates.filter { $0.source == .cli }.map(\.session))
            var inGhostty: Set<UUID> = []
            if case .known(let snapshot) = ghosttyFocusState { inGhostty = GhosttyMatch.sessions(in: snapshot, among: cliCandidates) }
            let liveness = SessionLiveness(desktopRunning: !desktopAdapter.runningInstallations().isEmpty,
                                           cliProcessRunning: result.6, cliSessionsInGhostty: inGhostty,
                                           sessionEnds: scan.sessionEnds)
            let discovered = SessionDiscovery.running(candidates, liveness: liveness)
            let discoveredCLI = Set(discovered.filter { $0.source == .cli }.map(\.session))
            endedSessions = Set(scan.sessionEnds.keys)
            cliSessions = scan.cliSessions.union(discoveredCLI)
            liveCLI = scan.cliState.liveSessions.union(discoveredCLI)
            knownCLISessions.formUnion(scan.titledCLISessions)
            let previous = Set(queue.items.map(\.id))
            // A receipt found on disk is not a verified live interaction: such a request enters handed
            // back and, when a real helper receipt exists, a no-decision record releases it to Codex at once.
            let unverified = queue.apply(scan: scan, desktopEvents: desktopEvents, now: Date().timeIntervalSince1970)
            queue.apply(discovered: discovered)
            applyDesktopReadState(readState, enabled: readStateURL != nil)
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
            if let newest = newItems.filter({ $0.completion?.uncertain == false }).max(by: { $0.arrivedAt < $1.arrivedAt }) {
                latestNewCompletion = newest.id
            }
            if let newest = newItems.filter({ $0.kind == .actionableRequest || $0.kind == .handedBackRequest })
                .max(by: { $0.arrivedAt < $1.arrivedAt }) {
                latestNewRequest = newest.id
            }
            let newQuestions = newItems.filter { $0.kind == .question }
            if let newest = newQuestions.max(by: { $0.arrivedAt < $1.arrivedAt }) { latestNewQuestion = newest.id }
            if newCompletions.contains(where: { !$0.uncertain }) { completionPresentation.enqueue() }
            else if !newCompletions.isEmpty, !completionPresentation.pending { completionPresentation = Attention(restored: true) }
            if ghosttyEnabled && newCompletions.contains(where: { $0.source == .cli }) { nextGhosttyScan = 0 }
            if !current.contains(where: { $0.kind == .handedBackRequest || $0.kind == .actionableRequest }) { reminderPresentation.dismiss() }
            else if newItems.contains(where: { $0.kind == .handedBackRequest || $0.kind == .actionableRequest }) { reminderPresentation.enqueue() }
            if !current.contains(where: { $0.kind == .completion }) { completionPresentation.dismiss() }
            // A question posed before this launch is shown but does not pop or chime: the user may
            // already be looking at it, and Steer was not observing when it arrived.
            if !current.contains(where: { $0.kind == .question }) { questionPresentation.dismiss() }
            else if newQuestions.contains(where: { $0.arrivedAt >= Companion.launchedAt }) { questionPresentation.enqueue() }
            else if !newQuestions.isEmpty, !questionPresentation.pending { questionPresentation = Attention(restored: true) }
            saveCompletions()
            scanning = false
            completedAScan = true
            refresh()
            writeRestartReportAndQuitIfRequested(unverified: unverified)
        }
    }

    /// `--daemon-report <path>`: a few seconds after launch, record what the daemon client saw on
    /// `--daemon-socket`, then quit. Used by the daemon lab against a fake daemon; nothing is answered.
    private var daemonReportDue: Double?
    /// True once a scan has published its result; the lab reports wait for it.
    private var completedAScan = false
    private func writeDaemonReportAndQuitIfRequested() {
        guard let path = Companion.argumentValue(for: "--daemon-report") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let due = daemonReportDue else { daemonReportDue = now + 4; return }
        // A scan must have finished, or the report would describe an empty queue rather than what
        // the seeded session produced; the deadline still ends the run if no scan ever completes.
        guard now >= due, completedAScan || now >= due + 6 else { return }
        let report: [String: Any] = [
            "socket": daemonClient.socketPath,
            "status": daemonClient.statusText,
            "connected": daemonClient.isConnected,
            "subscribed": daemonClient.subscribed.sorted(),
            "question_routes": queue.items.compactMap(\.question).map { "\($0.callID): \(route(for: $0))" },
            // Where each completion card's reply field would send, without sending anything.
            "completion_reply_targets": queue.items.compactMap(\.completion)
                .map { "\($0.session.uuidString.lowercased()): \(replyTarget(for: $0))" },
            "pending_requests": daemonBook.pendingRequests.map { request -> [String: Any] in
                ["thread": request.thread.uuidString.lowercased(), "turn": request.turn?.uuidString.lowercased() ?? "",
                 "item_id": request.itemID, "request_id": "\(request.requestID)",
                 "questions": request.questions.map { ["id": $0.id, "options": $0.options ?? [], "takes_text": $0.takesText, "is_secret": $0.isSecret] },
                 "route": queue.items.compactMap(\.question).first { $0.session == request.thread && $0.callID == request.itemID }
                    .map { "\(route(for: $0))" } ?? "no rollout question in the queue"]
            }
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
        app.terminate(nil)
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
                if let question = item.question { row["call_id"] = question.callID; row["turn"] = question.turn.uuidString
                                                  row["source"] = question.source.rawValue
                                                  if let progress = answerProgress[question.id] { row["answer_phase"] = "\(progress.phase)" }
                                                  row["answer_path"] = "\(route(for: question))" }
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
        pruneAnswerProgress()
        pruneReplyProgress()
        if previewMode == nil {
            // A waiting question on a thread Steer has not subscribed to yet: ask for the list now.
            if daemonClient.isConnected,
               queue.items.contains(where: { item in
                   item.question.map { !daemonClient.subscribed.contains($0.session.uuidString.lowercased()) } ?? false
               }) {
                daemonClient.pollThreadsSoon()
            }
            daemonClient.tick(now: ProcessInfo.processInfo.systemUptime)
            if daemonStatus != daemonClient.statusText { daemonStatus = daemonClient.statusText }
            writeDaemonReportAndQuitIfRequested()
        }
        checkApprovalFocus()
        checkGhosttyFocus()
        // App identity only: no window contents, task titles, or accessibility queries.
        // Preview screenshots ignore app activation; every real run keeps the foreground rule.
        let codexForeground = previewMode == nil ? desktopAdapter.codexForeground() : false
        desktopForeground = codexForeground == true
        // Desktop decision transport is unproven: release every desktop request at once.
        if previewMode == nil {
            queue.items.compactMap(\.request)
                .filter { $0.state == .actionable && ApprovalHandoff.releasesOnReceipt(source: $0.source) }
                .forEach(handBackApproval)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let pointerInside = pointerInsidePanel
        if !pointerInside { hoverSuppressed = false }
        hoverHeld = hoverHold.update(pointerInside: pointerInside && !hoverSuppressed, now: now)
        let interacting = NotchInteraction.isActive(pointerInside: hoverHeld, keyboardFocus: panel.hasDeliberateKeyboardFocus)
        if !interacting { manualOpen = false }
        var next = attention
        let firstPresentation = next.update(codexForeground: codexForeground, hovering: interacting,
                                            now: ProcessInfo.processInfo.systemUptime)
        if next.pending != attention.pending || next.presented != attention.presented || next.expanded != attention.expanded {
            attention = next
        }
        if firstPresentation && !muted { NSSound(named: "Glass")?.play() }
        // Use the same visibility as the count and rows, including CLI reminders.
        let firstReminderPresentation = reminderPresentation.update(codexForeground: visibleReminders.isEmpty, hovering: interacting,
                                                                    now: ProcessInfo.processInfo.systemUptime)
        if firstReminderPresentation {
            let requests = queue.items.filter { $0.kind == .actionableRequest || $0.kind == .handedBackRequest }
            if let id = latestNewRequest, requests.contains(where: { $0.id == id }) { spotlight.present(id, now: now) }
            else if let newest = requests.max(by: { $0.arrivedAt < $1.arrivedAt }) { spotlight.present(newest.id, now: now) }
            latestNewRequest = nil
        }
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
        if firstCompletionPresentation {
            let completions = queue.items.filter { $0.completion?.uncertain == false }
            if let id = latestNewCompletion, completions.contains(where: { $0.id == id }) { spotlight.present(id, now: now) }
            else if let newest = completions.max(by: { $0.arrivedAt < $1.arrivedAt }) { spotlight.present(newest.id, now: now) }
            latestNewCompletion = nil
        }
        // A question pops under the same away-from-Codex rule as a completion; Ghostty focus is
        // not consulted because the question stays pending until Codex records the answer.
        let canPresentQuestion = queue.items.contains { item in
            guard let question = item.question else { return false }
            return CompletionVisibility.allows(source: question.source, codexForeground: codexForeground, ghosttyFocus: .disabled)
        }
        let firstQuestionPresentation = questionPresentation.update(codexForeground: canPresentQuestion ? codexForeground : true,
                                                                    hovering: interacting, now: ProcessInfo.processInfo.systemUptime)
        if firstQuestionPresentation {
            let questions = queue.items.filter { $0.kind == .question }
            if let id = latestNewQuestion, questions.contains(where: { $0.id == id }) { spotlight.present(id, now: now) }
            else if let newest = questions.max(by: { $0.arrivedAt < $1.arrivedAt }) { spotlight.present(newest.id, now: now) }
            latestNewQuestion = nil
        }
        if let mode = previewMode, mode == "spotlight", let id = previewSpotlight { spotlight.present(id, now: now) }
        spotlightItem = spotlight.update(interacting: interacting, now: now)
        switch previewMode {
        case "expanded": showAll = true
        case "collapsed", "spotlight": showAll = false
        default: showAll = interacting || manualOpen
        }
        expanded = showAll || spotlightItem != nil || attention.expanded
        // Sound follows the card opening: the frame below is set in the same pass, so the chime
        // lands as the card lands. Muted, restored, and foreground cases never reach here.
        if CompletionSound.shouldPlay(firstPresentation: firstCompletionPresentation || firstQuestionPresentation, muted: muted) {
            NSSound(named: "Glass")?.play()
        }
        guard DesktopVisibility.isVisible(hasActivity: count > 0, codexForeground: codexForeground) else {
            panel.orderOut(nil)
            hovering = false
            targetFrame = .zero
            contentHeight = 0
            currentDisplayID = nil
            return
        }
        // One panel, one queue: the display is chosen by the documented rule and frozen while the
        // user is interacting, so controls never move away mid-action. Only geometry changes here.
        guard let display = NotchDisplaySelection.choose(displays: Companion.attachedDisplays(), pointer: NSEvent.mouseLocation,
                                                         current: currentDisplayID, interacting: interacting && panel.isVisible)
        else { panel.orderOut(nil); currentDisplayID = nil; return }
        currentDisplayID = display.id
        let layout = NotchPlacement.strip(on: display, expanded: expanded)
        if stripLayout != layout { stripLayout = layout }
        let rows = showAll ? orderedAttentionItems.count : (spotlightItem == nil ? 0 : 1)
        var frame = contentHeight > 0
            ? NotchPlacement.frame(on: display, expanded: expanded, contentHeight: contentHeight)
            : NotchPlacement.frame(on: display, expanded: expanded, rows: rows,
                                   extraRows: attention.pending && (showAll || spotlightItem == nil))
        // With no menu bar and no housing the strip rests above the screen edge and slides in for
        // the pointer at the top edge or an open panel, so it does not cover a full-screen app.
        if NotchTuck.isTucked(display: display, pointer: NSEvent.mouseLocation, interacting: interacting, open: expanded) {
            frame = NotchTuck.tuckedFrame(frame)
        }
        if targetFrame != frame {
            targetFrame = frame
            if reduceMotion || !panel.isVisible {
                panel.setFrame(frame, display: true)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().setFrame(frame, display: true)
                }
            }
        }
        // Never makes the panel key: an automatic notification does not take input from the user's app.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Collapses the panel and hands keyboard input back to the app the user was using.
    func collapse() {
        attention.collapse()
        reminderPresentation.collapse()
        completionPresentation.collapse()
        questionPresentation.collapse()
        spotlight.clear()
        manualOpen = false
        hoverSuppressed = true
        hoverHold = HoverHold()
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
    /// Acknowledges desktop completions the Codex desktop app itself no longer flags as unread.
    /// Only ever removes items; a missing or unparsable file changes nothing and says so.
    private func applyDesktopReadState(_ snapshot: DesktopReadStateSnapshot?, enabled: Bool) {
        guard enabled else { desktopReadStateMessage = "Desktop read state: off. Desktop completions clear only by dismissal."; return }
        guard let snapshot else {
            desktopReadStateMessage = "Desktop read state: unavailable (\(Companion.desktopReadStateURL.lastPathComponent) missing or in an unexpected format). Desktop completions clear only by dismissal."
            return
        }
        let queued = queue.items.compactMap(\.completion)
        let acknowledged = DesktopReadAcknowledgment.acknowledged(queued, snapshot: snapshot)
        for id in acknowledged { queue.dismiss(.completion(id)) }
        let written = Date(timeIntervalSince1970: snapshot.modifiedAt).formatted(date: .omitted, time: .standard)
        let tested = CodexSetupRequirements.minimumDesktopVersion
        let version = setupCapabilities.desktopVersion ?? "unknown"
        desktopReadStateMessage = "Desktop read state: file written \(written), \(snapshot.unread.count) unread threads"
            + (acknowledged.isEmpty ? "." : ", cleared \(acknowledged.count) completion\(acknowledged.count == 1 ? "" : "s") this scan.")
            + (version == tested ? "" : " Format tested with desktop \(tested); installed \(version).")
    }

    /// Persists unacknowledged completions and acknowledgments atomically whenever they change.
    func saveCompletions() {
        guard previewMode == nil else { return }
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
    /// Dismissal is in memory only: a question still pending in the rollout returns after a restart.
    func dismissQuestion(_ question: AttentionQuestion) {
        queue.dismiss(.question(question.id)); refresh()
    }

    /// Progress for a question the queue holds; a fresh, ready record when Steer has relayed nothing.
    func progress(for question: AttentionQuestion) -> QuestionAnswerProgress {
        let progress = answerProgress[question.id] ?? QuestionAnswerProgress(call: question.id)
        // A desktop pick made before the daemon delivered the request opened Codex and nothing more;
        // the daemon card starts from its first question.
        if case .daemon = route(for: question) { return progress.reopeningForDaemon() }
        return progress
    }

    /// Which path this question's card uses right now: the daemon when it holds the request,
    /// otherwise the Ghostty relay (CLI) or the desktop pick, exactly as before the daemon.
    func route(for question: AttentionQuestion) -> QuestionAnswerRoute {
        QuestionAnswerRouting.route(for: question, book: daemonBook, daemonConnected: daemonConnected)
    }

    /// Whether the card may show the options as controls: the daemon path, a CLI question with
    /// Ghostty controls on, or a desktop question (whose pick only opens Codex). Preview renders the
    /// controls as well.
    func showsOptionControls(for question: AttentionQuestion) -> Bool {
        switch route(for: question) {
        case .daemon: return true
        case .daemonAnswered: return false
        case .desktopPick: return true
        case .ghosttyRelay: return ghosttyEnabled || previewMode != nil
        }
    }

    /// One click on an option. Daemon: the exact answer by call id. Desktop: remember the pick and
    /// open the thread. CLI: relay the digit through Ghostty after re-checking the queue, the policy,
    /// and the rollout as it is right now.
    func chooseOption(_ question: AttentionQuestion, question index: Int, option: Int) {
        switch route(for: question) {
        case .daemon:
            answerThroughDaemon(question, question: index, answer: .option(option))
            return
        case .daemonAnswered:
            navigationMessage = AppServerAnswerPolicy.message(for: .alreadyAnswered); refresh()
            return
        case .desktopPick, .ghosttyRelay:
            break
        }
        if question.source == .desktop {
            guard case .options = QuestionAnswerProgress.offer(question, at: index) else { return }
            answerProgress[question.id] = progress(for: question).pickingInCodex(question: index, option: option)
            openAttentionSession(source: .desktop, session: question.session)
            return
        }
        guard !answering else { return }
        // Re-read the queue's current copy: a question answered since the row rendered must not be relayed.
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        let progress = progress(for: question)
        if let rejection = QuestionAnswerPolicy.rejection(for: current, ghosttyEnabled: ghosttyEnabled, progress: progress,
                                                          question: index, option: option) {
            navigationMessage = QuestionAnswerPolicy.message(for: rejection); refresh(); return
        }
        guard let current, previewMode == nil else { return }
        answering = true
        answerProgress[question.id] = progress.startingSend(question: index, option: option)
        let key = QuestionAnswerPolicy.key(forOption: option)
        let live = liveCLI
        let rolloutRoot = Companion.rolloutRoot
        navigationMessage = "Sending \(key)…"
        refresh()
        Task { @MainActor in
            let result = await Task.detached { () -> (sent: Bool, message: String) in
                // The rollout as of this instant: an answer Codex already recorded, or an ended turn,
                // means the pane is gone and the key would land in the composer instead.
                let evidence = ReminderReader.currentEvidence(for: current.session, in: rolloutRoot)
                guard QuestionAnswerGuard.stillPending(current, in: evidence) else {
                    return (false, "Codex already has an answer or the turn ended; nothing was sent.")
                }
                return GhosttyNavigation.answer(session: current.session, live: live, keys: [key])
            }.value
            answering = false
            navigationMessage = result.message
            guard queue.items.contains(where: { $0.id == .question(question.id) }) else {
                // Answered or ended while the key was in flight: the card is gone and so is the progress.
                answerProgress[question.id] = nil
                refresh()
                return
            }
            if let progress = answerProgress[question.id] {
                answerProgress[question.id] = result.sent
                    ? progress.recordingSent(question: index, option: option, of: current, at: Date().timeIntervalSince1970)
                    : progress.recordingFailure(result.message)
            }
            refresh()
        }
    }

    /// A typed answer; only the daemon path takes one.
    func answerText(_ question: AttentionQuestion, question index: Int, text: String) {
        guard case .daemon = route(for: question) else {
            navigationMessage = "Typed answers need Codex's daemon; answer this one in Codex."; refresh()
            return
        }
        answerThroughDaemon(question, question: index, answer: .text(text))
    }

    /// One answer through the daemon. A non-last question's answer is only drafted; the last one
    /// sends the whole call as one JSON-RPC response, after re-reading the rollout, and marks the
    /// request answered before the write so nothing is ever sent twice. Never on a timer or error.
    private func answerThroughDaemon(_ question: AttentionQuestion, question index: Int, answer: ChosenAnswer) {
        guard !answering else { return }
        let current = queue.items.compactMap(\.question).first { $0.id == question.id }
        if let rejection = AppServerAnswerPolicy.rejection(for: current, book: daemonBook, progress: progress(for: question),
                                                           question: index, answer: answer) {
            navigationMessage = AppServerAnswerPolicy.message(for: rejection); refresh(); return
        }
        guard let current, previewMode == nil, let request = daemonBook.request(for: current) else { return }
        let isLast = index + 1 >= request.questions.count
        answering = true
        navigationMessage = ""
        let rolloutRoot = Companion.rolloutRoot
        Task { @MainActor in
            // The rollout as of this instant, only when the answer would leave Steer: an answer Codex
            // already recorded, or an ended turn, means the daemon request is stale.
            let pending = isLast ? await Task.detached {
                QuestionAnswerGuard.stillPending(current, in: ReminderReader.currentEvidence(for: current.session, in: rolloutRoot))
            }.value : true
            let now = Date().timeIntervalSince1970
            let latest = queue.items.compactMap(\.question).first { $0.id == question.id }
            let plan = AppServerAnswering.prepare(current: latest, book: daemonBook, progress: progress(for: question),
                                                  question: index, answer: answer, stillPending: { pending }, now: now)
            daemonBook = plan.book
            switch plan.outcome {
            case let .refused(rejection):
                navigationMessage = AppServerAnswerPolicy.message(for: rejection)
            case let .drafted(next):
                answerProgress[question.id] = next
            case let .sending(next):
                answerProgress[question.id] = next
                let written = plan.message.map { daemonClient.send($0) } ?? false
                if let latest {
                    answerProgress[question.id] = written
                        ? next.recordingSent(question: index, answer: answer, of: latest, at: now)
                        : next.recordingFailure("Could not write to Codex's daemon; Steer will not retry. Answer in Codex.")
                }
                navigationMessage = written ? "Answer sent to Codex's daemon." : "Could not write to Codex's daemon."
            }
            answering = false
            refresh()
        }
    }

    /// What Steer can see right now about reaching a finished session: the daemon's own loaded
    /// threads, the sessions Codex recorded as ended, and the sessions already working again.
    var replyAvailability: SessionReplyAvailability {
        // Sessions in a turn, not sessions shown as working: one blocked on a question is mid-turn
        // too, and its running row is only withheld from the display.
        let working = queue.sessionsInTurn
        guard previewMode == nil else {
            // The preview has no daemon; it renders the field as a reachable session would.
            return SessionReplyAvailability(daemonConnected: true,
                                            daemonThreads: Set(queue.items.compactMap { $0.completion?.session }),
                                            endedSessions: endedSessions, workingSessions: working)
        }
        return SessionReplyAvailability(daemonConnected: daemonClient.isConnected, daemonThreads: daemonClient.loadedThreads,
                                        endedSessions: endedSessions, workingSessions: working)
    }

    /// Where this completion's reply would go, or why the field is disabled.
    func replyTarget(for completion: AttentionCompletion) -> SessionReplyTarget {
        SessionReplyRouting.target(for: completion, availability: replyAvailability)
    }

    /// This card's reply so far; a fresh, ready record when the user has sent nothing.
    func reply(for completion: AttentionCompletion) -> SessionReplyProgress {
        replyProgress[completion.id] ?? SessionReplyProgress(completion: completion.id)
    }

    /// One Send on a completion card. The reply starts a new turn on that exact thread through the
    /// daemon, after re-reading the queue and the target as they are right now. Sending does not
    /// acknowledge the completion, and a card that has sent one reply never sends another.
    func sendReply(to completion: AttentionCompletion, text: String) {
        guard !replying else { return }
        let current = queue.items.compactMap(\.completion).first { $0.id == completion.id }
        let plan = SessionReplySending.prepare(completion: current, availability: replyAvailability,
                                               progress: reply(for: completion), text: text)
        switch plan.outcome {
        case let .refused(rejection):
            navigationMessage = SessionReplyPolicy.message(for: rejection)
            refresh()
        case let .sending(next):
            guard previewMode == nil else {
                navigationMessage = "Preview only; nothing was sent."
                refresh()
                return
            }
            guard let params = plan.params else { return }
            replying = true
            replyProgress[completion.id] = next
            navigationMessage = "Sending your reply to Codex's daemon…"
            refresh()
            daemonClient.call(SessionReplyRequest.method, params: params) { [weak self] accepted, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.replying = false
                    let progress = self.reply(for: completion)
                    self.replyProgress[completion.id] = accepted
                        ? progress.recordingSent(at: Date().timeIntervalSince1970)
                        : progress.recordingFailure(SessionReplyPolicy.daemonRefused(error))
                    self.navigationMessage = accepted ? "Reply sent to Codex's daemon." : "Could not send the reply to Codex's daemon."
                    self.refresh()
                }
            }
        }
    }

    /// Keeps a card's reply only while its completion is queued, and lets a sent one reach its final
    /// state: confirmed by the session working again, or unconfirmed once the window passes.
    private func pruneReplyProgress() {
        guard !replyProgress.isEmpty else { return }
        let queued = Set(queue.items.compactMap { $0.completion?.id })
        let working = queue.sessionsInTurn
        let now = Date().timeIntervalSince1970
        let next = replyProgress.filter { queued.contains($0.key) }
            .mapValues { $0.observing(sessionWorking: working.contains($0.completion.session), at: now) }
        if next != replyProgress { replyProgress = next }
    }

    /// Drops progress for questions no longer waiting and turns an unconfirmed send into its final state.
    private func pruneAnswerProgress() {
        guard !answerProgress.isEmpty else { return }
        let waiting = Set(queue.items.compactMap { $0.question?.id })
        let now = Date().timeIntervalSince1970
        let next = answerProgress.filter { waiting.contains($0.key) }.mapValues { $0.expiring(at: now) }
        if next != answerProgress { answerProgress = next }
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
        guard previewMode == nil, !requests.isEmpty else { return }
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
              !cliItems.isEmpty || !queue.items.isEmpty || !liveCLI.isEmpty || !knownCLISessions.isEmpty else { return }
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
                ghosttyInventoryAt = Date().timeIntervalSince1970
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
    /// Opens the whole queue from the strip (a click or VoiceOver activation); it stays open while
    /// the panel has the pointer or keyboard focus.
    func expand() {
        manualOpen = true
        attention.expand(now: ProcessInfo.processInfo.systemUptime)
        refresh()
    }

    private var previewSpotlight: AttentionItemID?

    private func seedPreview(_ mode: String) {
        eventsPath = ""
        let now = Date().timeIntervalSince1970
        weeklyLimit = CodexWeeklyLimit(usedPercent: 37, resetsAt: now + 3 * 86400)
        let working = UUID(uuidString: "01A0916C-337B-4E2A-9D11-0000000000A1")!
        let finished = UUID(uuidString: "7C2F5D10-88AA-4B7E-8E0B-0000000000B2")!
        let asking = UUID(uuidString: "3E9D1B44-51C3-4F0A-9A77-0000000000C3")!
        let details = ApprovalDetails(taskName: "fix auth bug", project: "steer", action: "Run command",
                                      command: "swift test --filter AuthTests", reason: "Verify the token refresh fix before committing.")
        let request = AttentionRequest(id: UUID(), source: .cli, session: asking, turn: UUID(), arrivedAt: now - 5, details: details)
        let completion = AttentionCompletion(source: .desktop, session: finished, turn: UUID(), arrivedAt: now - 2)
        let running = AttentionRunning(source: .cli, session: working, turn: UUID(), arrivedAt: now - 60)
        let question = AttentionQuestion(source: .cli, session: working, turn: UUID(), callID: "call_preview", arrivedAt: now - 3,
                                         prompts: [QuestionPrompt(header: "Nested choices",
                                                                  question: "Should different variant paths support different levels of choices?",
                                                                  options: ["Flexible paths (Recommended)", "Same levels throughout"]),
                                                   QuestionPrompt(header: "First release",
                                                                  question: "Should the first release also support checkout?",
                                                                  options: ["Stock lookup only (Recommended)", "Include checkout"])])
        let desktopQuestion = AttentionQuestion(source: .desktop, session: finished, turn: UUID(), callID: "call_preview_desktop",
                                                arrivedAt: now - 4,
                                                prompts: [QuestionPrompt(header: "Storage",
                                                                         question: "Where should the cache live?",
                                                                         options: ["Application Support (Recommended)", "Caches", "Next to the app"])])
        queue.recordReceipts([request], now: now)
        queue.apply(completions: [completion], running: [running], now: now)
        queue.apply(questions: [question, desktopQuestion])
        // The CLI sample is reachable through the daemon in the preview: a seeded request whose
        // second question takes a typed answer, so the card shows both controls.
        _ = daemonBook.apply(message: ["jsonrpc": "2.0", "id": 1, "method": "item/tool/requestUserInput",
                                       "params": ["threadId": working.uuidString, "turnId": question.turn.uuidString,
                                                  "itemId": "call_preview",
                                                  "questions": [["id": "shape", "header": "Nested choices",
                                                                 "question": "Should different variant paths support different levels of choices?",
                                                                 "options": [["label": "Flexible paths (Recommended)", "description": ""],
                                                                             ["label": "Same levels throughout", "description": ""]]],
                                                                ["id": "name", "header": "Name",
                                                                 "question": "What should the first release be called?", "isOther": true,
                                                                 "options": [["label": "Stock lookup only (Recommended)", "description": ""],
                                                                             ["label": "Include checkout", "description": ""]]]]]],
                             now: now)
        completionPresentation = Attention(restored: true)
        reminderPresentation = Attention(restored: true)
        questionPresentation = Attention(restored: true)
        previewSpotlight = .completion(completion.id)
        _ = mode
    }

    func desktopReadStateChanged(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "desktopReadStateEnabled")
        if !enabled { desktopReadStateMessage = "Desktop read state: off. Desktop completions clear only by dismissal." }
        nextScan = 0
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
            Text(model.daemonStatus)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("With a Codex app-server daemon running (`codex app-server daemon start`), questions are answered exactly through it, including typed answers. Steer only reads its socket; it never starts the daemon.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Clear desktop completions Codex marks read", isOn: $model.desktopReadStateEnabled)
                .onChange(of: model.desktopReadStateEnabled) { _, enabled in
                    model.desktopReadStateChanged(enabled)
                }
            Text("Reads the desktop app's own unread flags from its private state file. A thread counts as read only after it was open in a focused Codex window. Turn off if a Codex update changes the format.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.desktopReadStateMessage)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 460, height: 800)
    }
}

let app = NSApplication.shared
let companion = Companion()
app.setActivationPolicy(.accessory)
app.delegate = companion
app.run()
