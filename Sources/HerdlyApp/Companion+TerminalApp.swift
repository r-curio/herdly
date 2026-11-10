import AppKit
import HerdlyCore

// Terminal.app (#239): its Automation permission, the two-second binding and visit scan, Open through
// ADR 0016's sequence with ADR 0015's fallback, and replies typed into the bound tab (ADR 0017).
// Everything runs only while Terminal.app's switch is on; the switch and card are shown since its
// acceptance (#244). Rules are HerdlyCore's (`TerminalAppHost.swift`, `TerminalTabBinding.swift`,
// `TerminalTypedInput.swift`); this file reads, sends and schedules.

/// Terminal.app state held by the companion. Main-actor only; memory only.
@MainActor
final class TerminalAppState {
    /// macOS's Automation answer, nil before the first check.
    var access: GhosttyAutomationAccess?
    /// What the latest scan that could tell showed about Automation (#279); nil before one.
    var scanPermission: TerminalAppScanPermission?
    /// The answer the Permission row shows: a scan's denial overrides `access` without stopping scans.
    var shownAccess: GhosttyAutomationAccess? {
        TerminalAppScanPermission.shown(checked: access, scan: scanPermission)
    }
    var probing = false
    /// Bumped on every switch change, so a check started before it applies to nothing.
    var generation = 0
    var scanning = false
    var nextScan: Double = 0
    /// Whether the latest inventory could be read; nil before one.
    var readable: Bool?
    /// Each queued Codex session's typed route, from the latest scan.
    var codexRoutes: [UUID: TerminalReplyRoute] = [:]
    /// Each queued Claude session's typed route, from the latest scan.
    var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
    /// Codex sessions whose title a Terminal.app tab carried in the latest scan: their questions are
    /// answered in Codex (ADR 0017).
    var codexSeen: Set<UUID> = []
    /// Whether any scan has seen a session's tab in Terminal.app (the card's In use).
    var sessionsSeen = false
    /// Every tab title in the latest readable inventory, for herdr's Codex gate (ADR 0014); nil before one.
    var latestTitles: Set<String>?
    /// ADR 0016's visit interval and dwell run over Terminal.app tab-windows.
    var visits = TerminalVisitTracker<TerminalTabTarget>()
    /// Claude completion cards' replies; Codex cards keep theirs in `Companion.replyProgress`.
    var claudeReplies: [AgentTurnIdentity: ReplyProgress<AgentTurnIdentity>] = [:]
    var replying = false
    /// The exact internal reasons, for the card's diagnostics only.
    var diagnostics: [String] = []
    var launchObserver: NSObjectProtocol?
    /// Terminal.app's bundle version, shown on the card for information only (product.md, "Settings").
    var version: String?
}

/// The enabled hosts a read is taken across, for ADR 0013's cross-host uniqueness: Terminal.app's
/// tabs, Ghostty's titles, iTerm2's, WezTerm's, tmux's and Zellij's inventories (#240–#242) while each is on.
/// Read on the main actor.
struct OtherTabHosts: Sendable {
    let ghosttyOn: Bool
    let ghosttyRunning: Bool
    /// nil while iTerm2 is off (never read).
    let iTerm2Running: Bool?
    /// nil while WezTerm is off (never read) (#240).
    var wezTermRunning: Bool? = nil
    /// nil while Terminal.app is off, or when Terminal.app is the host being read (#240); read by
    /// `WezTermTabReads`.
    var terminalAppRunning: Bool? = nil
    /// Terminal.app's switch is on, for `TerminalTabReads`; it is never read otherwise.
    var terminalAppOn = true
    /// tmux may be contacted (its switch and a terminal on); it is never read otherwise (#241).
    var tmuxOn = false
    /// Zellij may be contacted (its switch and a terminal on); it is never read otherwise (#242).
    var zellijOn = false

    /// A multiplexer is read, so WezTerm's clients are read too, for a client's host tab.
    var multiplexerOn: Bool { tmuxOn || zellijOn }
}

/// One set of fresh reads across the enabled hosts (ADR 0013): the first inventories, `ps` for the
/// ttys that could bind, and a second read after `ps`.
struct TerminalTabReads: Sendable {
    let terminalApp: TerminalAppNavigation.Read
    let inventories: [TerminalHost: TerminalHostInventory]
    let processes: [String: [TerminalProcess]]
    let secondRead: [TerminalHost: TerminalHostInventory]
    /// The first read's tmux server; `.notRunning` while tmux is off.
    var tmux: TmuxRead = .notRunning
    /// The first read's Zellij sessions; `.notRunning` while Zellij is off (#242).
    var zellij: ZellijRead = .notRunning
    /// The first read's Ghostty, iTerm2 and WezTerm snapshots, for a multiplexer's host tab (#241).
    var ghostty: GhosttySnapshot?
    var iTerm2: ITerm2Snapshot?
    var wezTerm: WezTermSnapshot?
    var wezTermClients: WezTermClients?
    /// Whether the Ghostty read above could list `tty`, read beside it; nil when Ghostty was not read
    /// or for the shared scheduled read, which never joins a multiplexer client.
    var ghosttyTTYSupport: GhosttyTTYSupport?

    /// Reads Terminal.app (while on) and the other enabled hosts, then `ps` for every tab or pane of a
    /// tty-listing host (Terminal.app, iTerm2, WezTerm, tmux) whose title is a shortened Codex identifier
    /// or whose tty is in `claudeTTYs`, so a title decoy is told apart from an unread tab (#268), then,
    /// when `second`, Terminal.app, tmux and Zellij again. Off the main actor.
    /// `scheduledSince` is set only by the shared scheduled read, as when it read the frontmost app: it
    /// may then reuse a Ghostty snapshot another scheduled scan read since (`GhosttyNavigation.scheduledSnapshot`).
    static func take(others: OtherTabHosts, claudeTTYs: Set<String>, second: Bool,
                     scheduledSince: Double? = nil) -> TerminalTabReads {
        let terminal: TerminalAppNavigation.Read = others.terminalAppOn ? TerminalAppNavigation.snapshot() : .notRunning
        var inventories: [TerminalHost: TerminalHostInventory] = [:]
        if others.terminalAppOn { inventories[.terminalApp] = terminal.inventory }
        var ghostty: GhosttySnapshot?
        if others.ghosttyOn {
            ghostty = others.ghosttyRunning
                ? (scheduledSince.map { GhosttyNavigation.scheduledSnapshot(notBefore: $0).snapshot } ?? GhosttyNavigation.snapshot())
                : nil
            inventories[.ghostty] = .ghosttyTitles(ghostty, running: others.ghosttyRunning)
        }
        var iTerm2: ITerm2Snapshot?
        if let running = others.iTerm2Running {
            let reading = running ? ITerm2Navigation.snapshot() : .notRunning
            if case .snapshot(let value)? = reading { iTerm2 = value }
            inventories[.iTerm2] = ITerm2Navigation.inventory(reading)
        }
        // WezTerm beside it (#240): its panes count toward uniqueness, and `ps` is read for its titled
        // Codex panes and Claude ttys too, so a session bound there routes to its pane. Its clients are
        // read too, for a multiplexer client's host tab (#241).
        var wezTermTTYs: Set<String> = []
        var wezTerm: WezTermSnapshot?
        var wezTermClients: WezTermClients?
        if let running = others.wezTermRunning {
            let (read, clients) = WezTermNavigation.read(running: running, clients: others.multiplexerOn)
            inventories[.wezTerm] = read.inventory
            wezTerm = read.snapshot
            wezTermClients = clients
            wezTermTTYs = read.snapshot?.ttysToRead(claudeTTYs: claudeTTYs) ?? []
        }
        let tmux: TmuxRead = others.tmuxOn ? TmuxRunner.read() : .notRunning
        if others.tmuxOn { inventories[.tmux] = tmux.inventory }
        // Zellij beside them (#242): its panes count toward Codex title uniqueness; it lists no tty to read.
        let zellij: ZellijRead = others.zellijOn ? ZellijRunner.read() : .notRunning
        if others.zellijOn { inventories[.zellij] = zellij.inventory }
        // Every titled tab of every tty-listing host (iTerm2's too), so a title decoy is told apart from a
        // tab whose `ps` was not read, which fails closed (#268).
        let ttys = (terminal.snapshot?.ttysToRead(claudeTTYs: claudeTTYs) ?? [])
            .union(wezTermTTYs).union(tmux.snapshot?.ttysToRead(claudeTTYs: claudeTTYs) ?? [])
            .union(TerminalTabReadAssembly<Void>.ttysToRead(inventories, claudeTTYs: claudeTTYs))
        let processes = TerminalTTYReads.processes(on: ttys)
        var secondRead = inventories
        if second {
            if others.terminalAppOn { secondRead[.terminalApp] = TerminalAppNavigation.snapshot().inventory }
            if others.tmuxOn { secondRead[.tmux] = TmuxRunner.read().inventory }
            if others.zellijOn { secondRead[.zellij] = ZellijRunner.read().inventory }
        }
        return TerminalTabReads(terminalApp: terminal, inventories: inventories, processes: processes,
                                secondRead: secondRead, tmux: tmux, zellij: zellij, ghostty: ghostty, iTerm2: iTerm2,
                                wezTerm: wezTerm, wezTermClients: wezTermClients,
                                ghosttyTTYSupport: ghostty == nil || scheduledSince != nil ? nil : GhosttyScriptingSupport.ttySupport())
    }

    /// ADR 0014's host-tab join for a multiplexer Open over these reads, with Ghostty's own join settled
    /// before the multiplexer moves rather than at the raise (#370).
    func hostJoin(clientTTY: String, switches: TerminalHostSwitches) -> MultiplexerHostJoin {
        let ghosttyJoin = ghostty.flatMap { snapshot in
            ghosttyTTYSupport.map { GhosttyTTYMatch.join(clientTTY: clientTTY, support: $0, snapshot: snapshot) }
        }
        return MultiplexerHostTab.join(clientTTY: clientTTY, switches: switches, inventories: inventories,
                                       ghostty: ghosttyJoin)
    }

    /// The ttys of tmux's attached clients and of Zellij's client processes in the first read: host tabs
    /// left out of the Codex title count (ADR 0014).
    var multiplexerClientTTYs: Set<String> {
        (tmux.snapshot?.clientTTYs ?? []).union(zellij.snapshot?.clientTTYs ?? [])
    }

    /// Whether Terminal.app's tabs carry `title`.
    func terminalAppCarries(title: String) -> Bool {
        guard case .tabs(let tabs) = terminalApp.inventory else { return false }
        return tabs.contains { $0.title == title }
    }

    func terminalAppHas(tty: String) -> Bool {
        guard case .tabs(let tabs) = terminalApp.inventory else { return false }
        return tabs.contains { $0.tty == tty }
    }
}

/// The process ADR 0013 follows for a Claude session, read fresh.
struct ClaudeTabProcess: Sendable {
    let process: TerminalSessionProcess
    let observed: TerminalProcessObservation?

    /// From the interactive inventory rows holding the session.
    static func read(_ rows: [ClaudeInventorySession]) -> ClaudeTabProcess {
        guard !rows.isEmpty else { return ClaudeTabProcess(process: .unidentified, observed: nil) }
        guard rows.count == 1 else { return ClaudeTabProcess(process: .ambiguous, observed: nil) }
        guard let pid = rows[0].pid else { return ClaudeTabProcess(process: .unidentified, observed: nil) }
        // ADR 0013: the start time Claude registered is compared with a fresh kernel read, so a reused
        // PID never binds. A process that is gone has no observation.
        return ClaudeTabProcess(process: .registered(ClaudeSessionRegistry.Process(pid: pid, procStart: rows[0].procStart)),
                                observed: TerminalTTYReads.observation(of: pid))
    }

    var tty: String? { observed?.tty.flatMap(GhosttyTTYMatch.normalizedTTY) }
    var pid: Int32? { if case .registered(let value) = process { return value.pid }; return nil }
}

extension Companion {
    /// Terminal.app may be scanned and contacted: its switch is on and macOS allowed Automation.
    var terminalAppActive: Bool {
        terminalAppSwitchedOn && terminalApp.access == .granted
    }

    /// The enabled hosts a read is taken across (ADR 0013), tmux included while it may be contacted.
    var otherTabHosts: OtherTabHosts {
        let ghosttyOn = ghosttyEnabled && ghosttyPermissionVerified
        return OtherTabHosts(ghosttyOn: ghosttyOn, ghosttyRunning: ghosttyOn && TerminalApps.isRunning(.ghostty),
                             iTerm2Running: hostSwitches.mayContact(.iTerm2) ? TerminalApps.isRunning(.iTerm2) : nil,
                             wezTermRunning: wezTermSwitchedOn ? TerminalApps.isRunning(.wezTerm) : nil,
                             terminalAppOn: terminalAppSwitchedOn, tmuxOn: tmuxContactAllowed,
                             zellijOn: zellijContactAllowed)
    }

    /// Terminal.app's switch is on. Open and question keys then account for it even before or without a
    /// readable scan: an enabled host that cannot be read fails closed (ADR 0013).
    var terminalAppSwitchedOn: Bool {
        previewMode == nil && hostSwitches.isOn(.terminalApp)
    }

    // MARK: - Switch and permission

    /// Restores a remembered switch at launch: check consent again, asking only if no decision exists.
    func startTerminalApp() {
        terminalApp.version = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalAppNavigation.bundleIdentifier)
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        observeTerminalAppLaunches()
        if hostSwitches.isOn(.terminalApp) { probeTerminalAppAccess() }
    }

    /// The switch moved (Settings). On: ask macOS. Off: forget every scan result.
    func terminalAppSwitchChanged(_ on: Bool) {
        terminalApp.generation += 1
        resetTerminalAppScan()
        terminalApp.scanPermission = nil
        if on { terminalApp.access = nil; probeTerminalAppAccess() }
    }

    private func resetTerminalAppScan() {
        terminalApp.codexRoutes = [:]
        terminalApp.claudeRoutes = [:]
        terminalApp.codexSeen = []
        terminalApp.readable = nil
        terminalApp.latestTitles = nil
        terminalApp.nextScan = 0
        terminalApp.visits.reset(at: Date().timeIntervalSince1970)
    }

    private func observeTerminalAppLaunches() {
        guard terminalApp.launchObserver == nil else { return }
        terminalApp.launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let launched = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard launched == TerminalAppNavigation.bundleIdentifier else { return }
            Task { @MainActor in
                guard let self, self.hostSwitches.isOn(.terminalApp), self.terminalApp.access != .granted else { return }
                self.probeTerminalAppAccess()
            }
        }
    }

    /// Ghostty's flow (product.md, Settings card "Permission"): a denial turns the switch back off and
    /// is remembered; Terminal not running keeps it on and asks when Terminal launches.
    func probeTerminalAppAccess() {
        guard hostSwitches.isOn(.terminalApp), !terminalApp.probing, previewMode == nil else { return }
        terminalApp.probing = true
        let generation = terminalApp.generation
        Task { @MainActor in
            let access = await Task.detached {
                GhosttyAutomationPermission.check(askIfNeeded: true, target: TerminalAppNavigation.bundleIdentifier)
            }.value
            terminalApp.probing = false
            guard generation == terminalApp.generation, hostSwitches.isOn(.terminalApp) else {
                if hostSwitches.isOn(.terminalApp) { probeTerminalAppAccess() }
                return
            }
            terminalApp.access = access
            if GhosttyControlsPolicy.outcome(for: access) == .disable {
                setHostSwitch(.terminalApp, on: false)
                terminalApp.access = .denied
            }
            refresh()
        }
    }

    // MARK: - Scan (bindings, routes, visits)

    /// Codex sessions whose tab binding matters now: queued completions and CLI questions.
    private var terminalAppCodexSessions: Set<UUID> {
        Set(cliItems.map(\.session)).union(queue.items.compactMap { item in
            item.question.flatMap { $0.source == .cli ? $0.session : nil }
        })
    }

    /// Claude CLI sessions with queued outcomes and their inventory rows.
    private var terminalAppClaudeRows: [AgentSessionIdentity: [ClaudeInventorySession]] {
        let identities = Set(agentQueue.snapshot.outcomes.map(\.session).filter { $0.source == .claude && $0.surface == .cli })
        var result: [AgentSessionIdentity: [ClaudeInventorySession]] = [:]
        for identity in identities {
            result[identity] = (claudeInventories[identity.sourceScope]?.sessions ?? [])
                .filter { $0.kind == .interactive && $0.sessionID == identity.session }
        }
        return result
    }

    /// Terminal.app's part of the shared scheduled read (`checkScheduledTabHosts`): while it is on,
    /// allowed, not scanning, and something could be bound to it. Whether it runs is checked once the
    /// read is due.
    func terminalAppScanPlan() -> TerminalAppScanPlan? {
        guard terminalAppActive else { return nil }
        let codexSessions = terminalAppCodexSessions
        let claudeRows = terminalAppClaudeRows
        guard !terminalApp.scanning, !openingTask,
              !codexSessions.isEmpty || !claudeRows.isEmpty || !codexSessionsAwaitingInventory.isEmpty else { return nil }
        return TerminalAppScanPlan(codexSessions: codexSessions, claudeRows: claudeRows, generation: terminalApp.generation)
    }

    /// Terminal.app stopped since its last scan: forget the result instead of reading it.
    func terminalAppStillRunning() -> Bool {
        guard TerminalApps.isRunning(.terminalApp) else {
            if terminalApp.readable != nil { resetTerminalAppScan() }
            return false
        }
        return true
    }

    /// Applies the shared read to Terminal.app, unless its switch, access or generation moved meanwhile.
    func finishTerminalAppScan(_ plan: TerminalAppScanPlan, reads: TerminalTabReads,
                               claude: [AgentSessionIdentity: ClaudeTabProcess], frontmost: TerminalHost?,
                               onScreen: Set<Int>?, takenAt: Double) {
        terminalApp.scanning = false
        guard plan.generation == terminalApp.generation, terminalAppActive else { return }
        // ADR 0016: frontmost comes from macOS as the scan starts; Terminal's own answer must agree.
        applyTerminalAppScan(reads, claude: claude.filter { plan.claudeRows[$0.key] != nil },
                             codexSessions: plan.codexSessions, frontmost: frontmost,
                             onScreen: frontmost == .terminalApp ? onScreen : [], takenAt: takenAt)
    }

    private func applyTerminalAppScan(_ reads: TerminalTabReads, claude: [AgentSessionIdentity: ClaudeTabProcess],
                                      codexSessions: Set<UUID>, frontmost: TerminalHost?, onScreen: Set<Int>?,
                                      takenAt: Double) {
        if case .unreadable = reads.terminalApp {
            // A denial while scanning keeps the switch and access as they are: the host stays enabled
            // and unreadable, so its sessions are unavailable and Ghostty keys fail closed. The Permission
            // row shows the denial until a readable scan (#279).
            terminalApp.readable = false
        } else {
            terminalApp.readable = true
        }
        terminalApp.scanPermission = TerminalAppScanPermission.after(terminalApp.scanPermission,
                                                                     reads.terminalApp.permissionOutcome)
        if case .tabs(let tabs) = reads.terminalApp.inventory { terminalApp.latestTitles = Set(tabs.compactMap(\.title)) }
        recordHostTitles(reads.inventories, takenAt: takenAt)
        var diagnostics = ["Terminal.app inventory: \(reads.terminalApp.diagnostic)"]
        var codexRoutes: [UUID: TerminalReplyRoute] = [:]
        var codexSeen: Set<UUID> = []
        var codexTargets: [UUID: TerminalTabTarget] = [:]
        for session in codexSessions {
            // A scan's binding is for presentation and visits; Open and typed input re-run it on fresh
            // reads, a second inventory included, immediately before acting.
            let binding = codexBinding(session, reads: reads)
            // A title decoy here, or one beside a session another host holds, is not this host's (#268).
            if case .tabs(let tabs) = reads.terminalApp.inventory,
               TerminalTabOpen.codexStays(in: .terminalApp, carriesTitle: TerminalTabBindingRules.carriesCodexTitle(
                   tabs, title: GhosttyMatch.title(session), processes: reads.processes), binding: binding) {
                codexSeen.insert(session)
            }
            if let route = TerminalReplyRoute.from(binding) { codexRoutes[session] = route }
            if case .bound(let target) = binding, target.host == .terminalApp { codexTargets[session] = target }
            diagnostics.append("Codex \(session.uuidString.lowercased()): \(binding)")
        }
        var claudeRoutes: [AgentSessionIdentity: TerminalReplyRoute] = [:]
        var claudeTargets: [AgentSessionIdentity: TerminalTabTarget] = [:]
        for (identity, process) in claude {
            let binding = claudeBinding(identity, process: process, reads: reads)
            // A session Zellij holds or could hold keeps Zellij's route (#242): its pane has no tab here.
            if zellijClaudeBinding(identity, process: process, read: reads.zellij) == .notInZellij,
               let route = TerminalReplyRoute.from(binding) { claudeRoutes[identity] = route }
            if case .bound(let target) = binding, target.host == .terminalApp { claudeTargets[identity] = target }
            diagnostics.append("Claude \(identity.session): \(binding)")
        }
        terminalApp.codexRoutes = codexRoutes
        terminalApp.claudeRoutes = claudeRoutes
        terminalApp.codexSeen = codexSeen
        if !codexTargets.isEmpty || !claudeTargets.isEmpty || !codexSeen.isEmpty { terminalApp.sessionsSeen = true }
        terminalApp.diagnostics = diagnostics

        // ADR 0016: one visit and dwell rule; only completions, only for the session's own bound tab.
        let reading: TerminalVisibilityReading<TerminalTabTarget> = frontmost == .terminalApp
            ? TerminalVisibility.terminalApp(reads.terminalApp.snapshot, frontmost: frontmost, onScreenWindowIDs: onScreen)
            : (reads.terminalApp.snapshot == nil ? .unknown : .nothing)
        terminalApp.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: reading))
        for (session, target) in codexTargets {
            let completions = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
            acknowledgeCodexCompletions(Array(terminalApp.visits.acknowledged(completions, target: target)))
        }
        for (identity, target) in claudeTargets {
            let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
            for id in terminalApp.visits.acknowledged(outcomes, target: target) { agentQueue.dismiss(.outcome(id)) }
        }
        saveCompletions()
    }

    func codexBinding(_ session: UUID, reads: TerminalTabReads) -> TerminalTabBinding {
        TerminalTabBindingRules.codex(sessionID: session.uuidString, liveness: endedSessions.contains(session) ? .ended : .live,
                                      liveSessions: Set(liveCLI.map(\.uuidString)), switches: hostSwitches,
                                      inventories: reads.inventories, processes: reads.processes,
                                      secondRead: reads.secondRead, multiplexerClientTTYs: reads.multiplexerClientTTYs)
    }

    func claudeBinding(_ identity: AgentSessionIdentity, process: ClaudeTabProcess,
                               reads: TerminalTabReads) -> TerminalTabBinding {
        TerminalTabBindingRules.claude(sessionID: identity.session, liveness: .live, process: process.process,
                                       observed: process.observed, switches: hostSwitches,
                                       inventories: reads.inventories, processes: reads.processes)
    }

    // MARK: - Open (ADR 0015, ADR 0016)

    /// Open for a Codex CLI session while Terminal.app is on. A session whose title no Terminal.app tab
    /// carries is left to Ghostty's own title route when Ghostty is on.
    func openCodexWithTerminalApp(_ session: UUID, otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask else { return }
        openingTask = true
        let others = otherTabHosts
        let title = GhosttyMatch.title(session)
        Task { @MainActor in
            let first = await Task.detached {
                TerminalTabReads.take(others: others, claudeTTYs: [], second: false)
            }.value
            // Ghostty's title route or iTerm2's cross-host Open decides a title no Terminal.app tab carries, or
            // one only a decoy here carries while the session's tab is in another host (#268).
            let holds = TerminalTabOpen.codexStays(in: .terminalApp, carriesTitle: first.terminalAppCarries(title: title),
                                                   binding: codexBinding(session, reads: first))
            if TerminalAppOpen.leavesToOtherRoute(otherRouteOn: ghosttyEnabled || hostSwitches.mayContact(.iTerm2),
                                                  inventory: first.terminalApp.inventory, holdsSession: holds) {
                openingTask = false
                otherwise()
                return
            }
            let preOpenAt = Date().timeIntervalSince1970
            let latest = LatestReads()
            let run = await runTerminalAppOpen(revalidate: { [weak self] in
                let reads = await Task.detached {
                    TerminalTabReads.take(others: others, claudeTTYs: [], second: true)
                }.value
                latest.reads = reads
                guard let self else { return .failure(.unavailable(.sessionEnded)) }
                return self.terminalAppPlan(self.codexBinding(session, reads: reads), reads: reads)
            })
            let switches = hostSwitches
            let result = await openResult(run) { _ in
                let carriers = latest.reads.map {
                    TerminalTabOpen.codexCarriers(title: title, switches: switches, inventories: $0.inventories,
                                                  processes: $0.processes)
                } ?? []
                // ADR 0015 amendment: walk from each titled tab's own `codex`; never a guess past a failed walk.
                let candidates = await Task.detached {
                    TerminalTabOpen.codexCandidates(carriers, walk: TerminalApps.walk(from:), ttyWrittenAt: TerminalTTYReads.writtenAt)
                }.value
                return OpenFallback.codexApp(candidates: candidates, switches: switches)
            }
            recordOpen(result, codex: session)
            let queued = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
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

    /// Open for a Claude CLI session while Terminal.app is on. A session whose tty no Terminal.app tab
    /// holds is left to Ghostty's own route when Ghostty is on.
    func openClaudeWithTerminalApp(_ identity: AgentSessionIdentity, approval: AgentApproval?,
                                   otherwise: @escaping @MainActor () -> Void) {
        guard !openingTask else { return }
        openingTask = true
        let others = otherTabHosts
        let roots = configuredClaudeNavigationRoots()
        Task { @MainActor in
            let rows = await Task.detached { () -> [ClaudeInventorySession]? in
                let scans = roots.map { ClaudeSetupDetection.activeSessionInventory(root: $0.root, capabilities: $0.capabilities) }
                guard !scans.isEmpty, scans.allSatisfy(\.available) else { return nil }
                return scans.flatMap { $0.sessions.filter { $0.kind == .interactive && $0.sessionID == identity.session } }
            }.value
            guard let rows else {
                openingTask = false
                refresh()
                return
            }
            let process = await Task.detached { ClaudeTabProcess.read(rows) }.value
            let first = await Task.detached {
                TerminalTabReads.take(others: others,
                                      claudeTTYs: Set([process.tty].compactMap { $0 }), second: false)
            }.value
            // iTerm2, Ghostty's title route or the process walk decides a tty no Terminal.app tab holds.
            if TerminalAppOpen.leavesToOtherRoute(otherRouteOn: true, inventory: first.terminalApp.inventory,
                                                  holdsSession: process.tty.map(first.terminalAppHas) ?? false) {
                openingTask = false
                otherwise()
                return
            }
            let preOpenAt = Date().timeIntervalSince1970
            let run = await runTerminalAppOpen(revalidate: { [weak self] in
                if rows.isEmpty { return .failure(.unavailable(.sessionEnded)) }
                let fresh = await Task.detached { () -> (ClaudeTabProcess, TerminalTabReads) in
                    let again = ClaudeTabProcess.read(rows)
                    return (again, TerminalTabReads.take(others: others,
                                                         claudeTTYs: Set([again.tty].compactMap { $0 }), second: false))
                }.value
                guard let self else { return .failure(.unavailable(.sessionEnded)) }
                return self.terminalAppPlan(self.claudeBinding(identity, process: fresh.0, reads: fresh.1), reads: fresh.1)
            })
            let switches = hostSwitches
            let pid = process.pid
            let result = await openResult(run) { _ in
                let walk = await Task.detached { pid.map(TerminalApps.walk(from:)) ?? .failed }.value
                return OpenFallback.processApp(walks: [walk], agent: .claude, switches: switches)
            }
            recordOpen(result, claude: identity)
            if case .unavailable = result {} else {
                // ADR 0015: an Open on an actionable request hands it back with no decision, fallback included.
                if let approval,
                   let current = orderedAgentAttentionItems.compactMap(\.approval).first(where: { $0.id == approval.id }) {
                    handBackClaudeApproval(current)
                }
                let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
                for id in TerminalVisitAcknowledgment.afterOpen(outcomes, result: result, preOpenAt: preOpenAt) {
                    agentQueue.dismiss(.outcome(id))
                }
                saveCompletions()
            }
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// Revalidate's plan from a fresh binding: a Terminal.app tab alone in its window, or the miss.
    private func terminalAppPlan(_ binding: TerminalTabBinding, reads: TerminalTabReads) -> Result<TerminalTabTarget, OpenMiss> {
        if case .unreadable = reads.terminalApp { return .failure(.unavailable(.hostUnreadable(.terminalApp))) }
        guard let snapshot = reads.terminalApp.snapshot else {
            return .failure(TerminalTabOpen.miss(binding.unavailableReason ?? .titleNotFound))
        }
        return TerminalAppOpen.plan(binding, snapshot: snapshot)
    }

    /// ADR 0016's sequence with Terminal.app's raise and verify, each sent once.
    private func runTerminalAppOpen(revalidate: @escaping () async -> Result<TerminalTabTarget, OpenMiss>) async -> GhosttyTitleOutcome {
        let steps = TerminalOpenSteps<TerminalTabTarget, OpenMiss>(
            now: { Date().timeIntervalSince1970 },
            revalidate: { _ in await revalidate() },
            raise: { target in
                TerminalAppOpen.raised(await Task.detached { TerminalAppNavigation.raise(target) }.value)
            },
            verify: { target in
                let frontmost = TerminalApps.frontmostHost()
                let pid = TerminalAppNavigation.pid()
                let observed = await Task.detached {
                    (TerminalAppNavigation.snapshot().snapshot, TerminalAppNavigation.onScreenWindowIDs(pid: pid))
                }.value
                return TerminalAppOpen.verified(target, snapshot: observed.0, frontmost: frontmost, onScreenWindowIDs: observed.1)
            })
        switch await TerminalOpenSequence.run(steps) {
        case .opened: return .opened
        case .failed(let miss, _): return .miss(miss)
        }
    }

    // MARK: - Typed replies (ADR 0017)

    /// The typed routes `replyAvailability` passes to the routing rule, from every enabled host's latest
    /// scan: Terminal.app's binding, and iTerm2's blocks (a session iTerm2 may hold gets iTerm2's line, an
    /// unreadable iTerm2 the unreachable line). Any route that is not a pane wins over a pane.
    var terminalReplyRoutes: [UUID: TerminalReplyRoute] {
        var routes = terminalAppActive ? terminalApp.codexRoutes : [:]
        if wezTermSwitchedOn {
            for (session, route) in wezTerm.codexRoutes { routes[session] = TerminalReplyRoute.merging(routes[session], route) }
        }
        // tmux (#241): a session tmux holds, or one an unreadable tmux could hold, merges tmux's route.
        if tmuxContactAllowed {
            for (session, route) in tmux.codexRoutes { routes[session] = TerminalReplyRoute.merging(routes[session], route) }
        }
        // Zellij (#242): a session Zellij holds, or one an unreadable Zellij could hold, merges Zellij's route.
        if zellijContactAllowed {
            for (session, route) in zellij.codexRoutes { routes[session] = TerminalReplyRoute.merging(routes[session], route) }
        }
        if hostSwitches.mayContact(.iTerm2) {
            for (session, block) in iTerm2.codexInputBlocks {
                routes[session] = block == .inITerm2 ? .hostCannotType(.iTerm2) : .unreachable
            }
        }
        return routes
    }

    /// The question route's host other than Ghostty whose latest scan showed the session's tab:
    /// iTerm2 or Terminal.app, whose questions are answered in Codex (ADR 0017), or tmux (#241) and Zellij
    /// (#242), whose pane keys are offered only once each one's digit is proven live (`tmuxQuestionKeyPane`,
    /// `zellijQuestionKeyPane`).
    func terminalHost(forQuestionSession session: UUID) -> TerminalHost? {
        if tmuxContactAllowed, tmux.codexSeen.contains(session) { return .tmux }
        if zellijContactAllowed, zellij.codexSeen.contains(session) { return .zellij }
        if hostSwitches.mayContact(.iTerm2), iTerm2.codexInputBlocks[session] == .inITerm2 { return .iTerm2 }
        if wezTermSwitchedOn, wezTerm.codexSeen.contains(session) { return .wezTerm }
        return terminalAppSwitchedOn && terminalApp.codexSeen.contains(session) ? .terminalApp : nil
    }

    /// An enabled host that could hold the Codex session but whose latest read is missing, unreadable or
    /// denied, so no key may be offered (ADR 0013 "Inventory"). A host that is not running holds nothing.
    func unreadQuestionHost(for session: UUID) -> TerminalHost? {
        if tmuxContactAllowed, tmux.read?.snapshot == nil, tmux.read != .notRunning { return .tmux }
        if zellijContactAllowed, zellij.read?.snapshot == nil, zellij.read?.inventory != .notRunning { return .zellij }
        if hostSwitches.mayContact(.iTerm2), TerminalApps.isRunning(.iTerm2),
           iTerm2.codexInputBlocks[session] == .iTerm2Unreadable || iTerm2.scan == .notRead || iTerm2.scan == .unreadable {
            return .iTerm2
        }
        if wezTermSwitchedOn, TerminalApps.isRunning(.wezTerm), wezTerm.scan != .read { return .wezTerm }
        guard terminalAppSwitchedOn, TerminalApps.isRunning(.terminalApp) else { return nil }
        return terminalApp.access == .granted && terminalApp.readable == true ? nil : .terminalApp
    }

    /// Fresh inventories of `hosts` for `TerminalKeyRelayCheck`, off the main actor; `running` was read on
    /// the main actor, and a host not in it holds nothing and is not asked. A host without a reader in
    /// this build is unreadable, so the check fails closed for it.
    nonisolated static func freshInventories(_ hosts: [TerminalHost], running: Set<TerminalHost>) -> [TerminalHost: TerminalHostInventory] {
        var result: [TerminalHost: TerminalHostInventory] = [:]
        for host in hosts {
            // tmux and Zellij are no apps: their own reads say whether a server runs.
            if host == .tmux { result[host] = TmuxRunner.read().inventory; continue }
            if host == .zellij { result[host] = ZellijRunner.read().inventory; continue }
            guard running.contains(host) else { result[host] = .notRunning; continue }
            switch host {
            case .terminalApp: result[host] = TerminalAppNavigation.snapshot().inventory
            case .iTerm2: result[host] = ITerm2Navigation.inventory(ITerm2Navigation.snapshot())
            case .wezTerm: result[host] = WezTermNavigation.read(running: true).0.inventory
            case .ghostty, .tmux, .zellij, .herdr: result[host] = .unreadable
            }
        }
        return result
    }

    /// Types a Codex reply into the bound tab, after the click's policy passed: a fresh check before
    /// every write, Codex's text then a separate submit a second later, nothing ever resent.
    func sendTypedCodexReply(_ completion: AttentionCompletion, send: SessionReplySending.TerminalSend,
                             progress: SessionReplyProgress) {
        guard !terminalApp.replying else { return }
        terminalApp.replying = true
        replyProgress[completion.id] = progress
        refresh()
        let others = otherTabHosts
        let rolloutRoot = Companion.rolloutRoot
        // The tmux server each fresh check read; a tmux write goes only to it.
        let checked = TmuxCheckedServer()
        Task { @MainActor in
            let run = await TypedReplySequence.run(
                writes: send.writes,
                check: { [weak self] in
                    guard let self else { return .notInQueue }
                    let fresh = await Task.detached { () -> (TerminalTabReads, ReminderReader.RolloutEvidence) in
                        (TerminalTabReads.take(others: others, claudeTTYs: [], second: true),
                         ReminderReader.currentEvidence(for: completion.session, in: rolloutRoot))
                    }.value
                    checked.server = fresh.0.tmux.snapshot?.server
                    checked.zellij = Companion.zellijServer(for: send.pane, in: fresh.0)
                    return TypedReplyCheck.veto(self.codexReplyState(completion,
                                                                     route: self.codexTypedRoute(completion.session, reads: fresh.0),
                                                                     evidence: fresh.1),
                                                spent: send.pane)
                },
                write: { write in
                    let server = checked.server, zellij = checked.zellij
                    return await Task.detached { Companion.typeInto(send.pane, write, tmuxServer: server, zellijServer: zellij) }.value
                },
                pause: { seconds in try? await Task.sleep(for: .seconds(seconds)) })
            terminalApp.replying = false
            let current = reply(for: completion)
            replyProgress[completion.id] = current.settling(run, at: Date().timeIntervalSince1970)
            refresh()
        }
    }

    /// ADR 0017's fresh check for a Codex reply, from the queue as it is now, the rollout and the route of
    /// the binding re-run on fresh reads of every enabled host.
    func codexReplyState(_ completion: AttentionCompletion, route: TerminalReplyRoute?,
                         evidence: ReminderReader.RolloutEvidence) -> TypedReplyFreshState {
        let session = completion.session
        let turn = TurnIdentity(session: session, turn: completion.turn)
        let queued = queue.items.compactMap(\.completion)
        let pending = queue.items.contains { item in
            item.request?.session == session || item.question?.session == session
        } || evidence.pendingQuestions.contains { $0.session == session }
        return TypedReplyFreshState(
            completionQueued: queued.contains { $0.id == completion.id },
            latestTurn: !queued.contains { $0.session == session && $0.arrivedAt > completion.arrivedAt },
            sessionIdle: !queue.sessionsInTurn.contains(session)
                && (evidence.completed.contains(turn) || evidence.canceled.contains(turn)),
            pendingInteraction: pending,
            daemonHoldsThread: daemonClient.isConnected && daemonClient.loadedThreads.contains(session),
            route: route)
    }

    // MARK: Claude replies

    /// The Claude card's reply target, nil when no typed route exists (the card shows no field). Terminal.app's
    /// and WezTerm's latest scans each give a route; a route that is not one pane wins (#240).
    func claudeReplyTarget(for outcome: AgentOutcome) -> SessionReplyTarget? {
        guard terminalAppActive || wezTermSwitchedOn || tmuxContactAllowed || zellijContactAllowed, outcome.session.source == .claude,
              outcome.session.surface == .cli else { return nil }
        let items = orderedAgentAttentionItems.filter { $0.session == outcome.session }
        let ended = listedClaudeSessions[outcome.session.sourceScope].map { !$0.contains(outcome.session.session) } ?? false
        let inTurn = items.contains { $0.running != nil || $0.question != nil || ($0.approval != nil) }
        // No entry (bound in Ghostty, or not scanned yet) offers no field, as for Codex.
        let route = TerminalReplyRoute.merging(
            TerminalReplyRoute.merging(terminalAppActive ? terminalApp.claudeRoutes[outcome.session] : nil,
                                       wezTermSwitchedOn ? wezTerm.claudeRoutes[outcome.session] : nil),
            TerminalReplyRoute.merging(tmuxContactAllowed ? tmux.claudeRoutes[outcome.session] : nil,
                                       zellijContactAllowed ? zellij.claudeRoutes[outcome.session] : nil))
        return ClaudeReplyRouting.target(ended: ended, inTurn: inTurn, route: route)
    }

    /// A Claude result card's reply, by its outcome; a fresh, ready record when it has sent nothing.
    func claudeReply(for id: AgentTurnIdentity) -> ReplyProgress<AgentTurnIdentity> {
        terminalApp.claudeReplies[id] ?? ReplyProgress(completion: id)
    }

    /// One Send on a Claude completion card: text and its submit in one write (`do script`, tmux's
    /// `send-keys` or Zellij's `write-chars`), after a fresh check.
    func sendClaudeReply(_ outcome: AgentOutcome, text: String) {
        guard !terminalApp.replying else { return }
        let progress = claudeReply(for: outcome.id)
        let current = agentQueue.snapshot.outcomes.first { $0.id == outcome.id }
        guard let current, let target = claudeReplyTarget(for: current) else {
            refresh(); return
        }
        let send: SessionReplySending.TerminalSend
        switch ClaudeReplyRouting.prepare(target: target, progress: progress, text: text) {
        case .failure:
            refresh(); return
        case .success(let value): send = value
        }
        // A pane in WezTerm types through WezTerm's send (#240).
        if send.pane.host == .wezTerm {
            sendWezTermClaudeReply(outcome, send: send, progress: progress)
            return
        }
        terminalApp.replying = true
        terminalApp.claudeReplies[outcome.id] = progress.startingSend(text: text, route: .terminal(send.pane))
        refresh()
        let others = otherTabHosts
        let roots = configuredClaudeNavigationRoots().filter { $0.root.path == outcome.session.sourceScope }
        let checked = TmuxCheckedServer()
        Task { @MainActor in
            let run = await TypedReplySequence.run(
                writes: send.writes,
                check: { [weak self] in
                    guard let self else { return .notInQueue }
                    let fresh = await Task.detached { () -> (ClaudeInventorySession?, ClaudeTabProcess, TerminalTabReads)? in
                        let scans = roots.map { ClaudeSetupDetection.activeSessionInventory(root: $0.root, capabilities: $0.capabilities) }
                        guard scans.count == 1, scans[0].available else { return nil }
                        let rows = scans[0].sessions.filter { $0.kind == .interactive && $0.sessionID == outcome.session.session }
                        let process = ClaudeTabProcess.read(rows)
                        let reads = TerminalTabReads.take(others: others,
                                                          claudeTTYs: Set([process.tty].compactMap { $0 }), second: false)
                        return (rows.count == 1 ? rows[0] : nil, process, reads)
                    }.value
                    guard let fresh else { return .unreachable }
                    checked.server = fresh.2.tmux.snapshot?.server
                    checked.zellij = Companion.zellijServer(for: send.pane, in: fresh.2)
                    let route = self.claudeTypedRoute(outcome.session, process: fresh.1, reads: fresh.2)
                    return TypedReplyCheck.veto(self.claudeReplyState(outcome, row: fresh.0, route: route), spent: send.pane)
                },
                write: { write in
                    let server = checked.server, zellij = checked.zellij
                    return await Task.detached { Companion.typeInto(send.pane, write, tmuxServer: server, zellijServer: zellij) }.value
                },
                pause: { seconds in try? await Task.sleep(for: .seconds(seconds)) })
            terminalApp.replying = false
            terminalApp.claudeReplies[outcome.id] = claudeReply(for: outcome.id).settling(run, at: Date().timeIntervalSince1970)
            refresh()
        }
    }

    /// ADR 0017's fresh check for a Claude reply: a fresh interactive inventory reading must say idle, and
    /// `route` is the binding re-run on fresh reads of every enabled host.
    func claudeReplyState(_ outcome: AgentOutcome, row: ClaudeInventorySession?,
                          route: TerminalReplyRoute?) -> TypedReplyFreshState {
        let outcomes = agentQueue.snapshot.outcomes.filter { $0.session == outcome.session }
        let items = orderedAgentAttentionItems.filter { $0.session == outcome.session }
        return TypedReplyFreshState(
            completionQueued: outcomes.contains { $0.id == outcome.id },
            latestTurn: !outcomes.contains { $0.arrivedAt > outcome.arrivedAt },
            sessionIdle: row?.lifecycle.isIdleInteractive == true && !items.contains { $0.running != nil },
            pendingInteraction: items.contains { $0.question != nil || $0.approval != nil },
            daemonHoldsThread: false,
            route: route)
    }

    /// Keeps a Claude card's reply only while its outcome is queued, and lets a sent one reach its final
    /// state: the session working again (its prompt was submitted), or unconfirmed after the window.
    func pruneClaudeReplies() {
        guard !terminalApp.claudeReplies.isEmpty else { return }
        let queued = Set(agentQueue.snapshot.outcomes.map(\.id))
        let working = Set(orderedAgentAttentionItems.filter { $0.running != nil }.map(\.session))
        let now = Date().timeIntervalSince1970
        terminalApp.claudeReplies = terminalApp.claudeReplies.filter { queued.contains($0.key) }
            .mapValues { $0.observing(sessionWorking: working.contains($0.completion.session), at: now) }
    }

    // MARK: - Settings

    var terminalAppSettingsRow: TerminalAppSettingsRow {
        TerminalAppPresentation.settingsRow(on: hostSwitches.isOn(.terminalApp), access: terminalApp.shownAccess,
                                            readable: terminalApp.readable, sessionsSeen: terminalApp.sessionsSeen)
    }
}

/// The tmux and Zellij servers a typed reply's latest fresh check read, so its write goes only to them.
@MainActor
final class TmuxCheckedServer {
    var server: TmuxServerIdentity?
    var zellij: ZellijServerIdentity?
}

/// The latest reads an Open's revalidation took, for the fallback's candidate walks.
@MainActor
private final class LatestReads {
    var reads: TerminalTabReads?
}

extension TerminalAppNavigation.Read {
    var diagnostic: String {
        switch self {
        case .notRunning: "not running"
        case .snapshot(let snapshot): "\(snapshot.windows.count) windows"
        case .unreadable(let denied): denied ? "unreadable (Automation denied)" : "unreadable"
        }
    }
}
