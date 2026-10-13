import AppKit
import SteerCore

/// iTerm2 state (#238), main-actor only. The Settings card observes it directly.
@MainActor
final class ITerm2State: ObservableObject {
    /// The latest Automation consent check for iTerm2; nil until one has run since the switch went on.
    @Published var access: GhosttyAutomationAccess?
    @Published var scan: ITerm2ScanStatus = .notRead
    /// A live session was seen bound to an iTerm2 tab since the switch went on.
    @Published var inUse = false
    @Published var installed = false
    /// Each session's latest Open in iTerm2, for Show diagnostics: verified, fallback or unavailable, with the reason.
    @Published var lastOpen: [String: String] = [:]
    /// Queued Codex sessions whose typed input iTerm2 withholds, from the latest scan (ADR 0017).
    @Published var codexInputBlocks: [UUID: ITerm2TypedInputBlock] = [:]
    /// ADR 0016's visit interval and dwell run over iTerm2 sessions, by session GUID.
    var visits = TerminalVisitTracker<String>()
    /// Every session title in the latest readable inventory, for herdr's Codex gate (ADR 0014).
    var latestTitles: Set<String>?
    var probing = false
    /// A consent check started before the user last switched iTerm2 applies to nothing.
    var generation = 0
    var startupRetries = 0
    var checking = false
    var nextScan: Double = 0
    var launchObserver: NSObjectProtocol?
}

/// Reads behind one Codex binding across the enabled tab hosts (ADR 0013): two inventories with the
/// `ps -t` reads between them, in `TerminalTabReadAssembly`'s order. The iTerm2 Open, iTerm2's visit scan
/// and the Open availability scan (#267) all read through here, so a scan never reads less than a click.
struct CodexTabReads: Sendable {
    /// What the first read held besides inventories.
    struct FirstRead: Sendable {
        var iTerm2: ITerm2Snapshot?
        var ghostty: GhosttySnapshot?
        var tmux: TmuxRead = .notRunning
        var zellij: ZellijRead = .notRunning
    }

    let inventories: [TerminalHost: TerminalHostInventory]
    let processes: [String: [TerminalProcess]]
    let secondRead: [TerminalHost: TerminalHostInventory]
    let iTerm2: ITerm2Snapshot?
    /// tmux's attached clients and Zellij's client processes in the first read (ADR 0014's title-count exclusion).
    var multiplexerClientTTYs: Set<String> = []
    /// The first read's Ghostty, tmux and Zellij reads, for Ghostty's title route and the multiplexer plans.
    var ghostty: GhosttySnapshot?
    var tmux: TmuxRead = .notRunning
    var zellij: ZellijRead = .notRunning

    /// Blocking: call off the main actor. Ghostty is read only while it is on and running, iTerm2 only
    /// while running; `ps` only for tabs and panes showing one of `titles` or on one of `claudeTTYs`.
    ///   - iTerm2Running: nil while iTerm2 may not be contacted (never read); otherwise whether it runs.
    ///   - terminalAppRunning: nil while Terminal.app is off (never read); otherwise whether it runs (#239).
    ///   - wezTermRunning: likewise for WezTerm (#240), whose panes count toward title uniqueness.
    ///   - tmuxOn: tmux may be contacted, so its panes are read too (#241).
    ///   - zellijOn: Zellij may be contacted, so its panes count toward title uniqueness too (#242).
    static func read(titles: Set<String>, claudeTTYs: Set<String>, ghosttyOn: Bool, ghosttyRunning: Bool,
                     iTerm2Running: Bool?, terminalAppRunning: Bool? = nil, wezTermRunning: Bool? = nil,
                     tmuxOn: Bool = false, zellijOn: Bool = false) -> CodexTabReads {
        func hosts() -> ([TerminalHost: TerminalHostInventory], FirstRead) {
            var result: [TerminalHost: TerminalHostInventory] = [:]
            var first = FirstRead()
            if let iTerm2Running {
                let reading = iTerm2Running ? ITerm2Navigation.snapshot() : .notRunning
                result[.iTerm2] = ITerm2Navigation.inventory(reading)
                if case .snapshot(let value)? = reading { first.iTerm2 = value }
            }
            if let terminalAppRunning {
                result[.terminalApp] = terminalAppRunning ? TerminalAppNavigation.snapshot().inventory : .notRunning
            }
            if let wezTermRunning { result[.wezTerm] = WezTermNavigation.read(running: wezTermRunning).0.inventory }
            if ghosttyOn {
                first.ghostty = ghosttyRunning ? GhosttyNavigation.snapshot() : nil
                result[.ghostty] = .ghosttyTitles(first.ghostty, running: ghosttyRunning)
            }
            if tmuxOn {
                first.tmux = TmuxRunner.read()
                result[.tmux] = first.tmux.inventory
            }
            if zellijOn {
                first.zellij = ZellijRunner.read()
                result[.zellij] = first.zellij.inventory
            }
            return (result, first)
        }
        let reads = TerminalTabReadAssembly.take(codexTitles: titles, claudeTTYs: claudeTTYs, readHosts: hosts,
                                                 readProcesses: TerminalTTYReads.processes(on:))
        let first = reads.extra
        let clients = (first.tmux.snapshot?.clientTTYs ?? []).union(first.zellij.snapshot?.clientTTYs ?? [])
        return CodexTabReads(inventories: reads.inventories, processes: reads.processes, secondRead: reads.secondRead,
                             iTerm2: first.iTerm2, multiplexerClientTTYs: clients, ghostty: first.ghostty,
                             tmux: first.tmux, zellij: first.zellij)
    }
}

/// What an iTerm2 Open's revalidation saw, kept for the fallback decision after the sequence.
@MainActor
private final class ITerm2OpenRecord {
    var reads: CodexTabReads?
    var binding: TerminalTabBinding?
}

extension Companion {
    /// Whether a terminal host that can hold a Codex CLI tab is on: Ghostty, iTerm2 (#238),
    /// Terminal.app (#239) or WezTerm (#240).
    var cliTerminalHostOn: Bool {
        ghosttyEnabled || hostSwitches.mayContact(.iTerm2) || terminalAppSwitchedOn || wezTermSwitchedOn
    }

    // MARK: - Switch and Automation permission (Ghostty's flow, product.md "Settings")

    /// At launch, after the switches are restored: watches iTerm2 launches and, with the switch on,
    /// asks macOS for consent as Ghostty does. With it off, a silent check keeps a remembered denial's
    /// guidance on the card.
    func startITerm2() {
        iTerm2.installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ITerm2Navigation.bundleIdentifier) != nil
        if iTerm2.launchObserver == nil {
            iTerm2.launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let launched = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard launched == ITerm2Navigation.bundleIdentifier else { return }
                Task { @MainActor in
                    guard let self, self.hostSwitches.isOn(.iTerm2), self.iTerm2.access != .granted else { return }
                    self.probeITerm2Access()
                }
            }
        }
        if hostSwitches.isOn(.iTerm2) {
            probeITerm2Access()
        } else {
            Task { @MainActor in
                let access = await Task.detached {
                    GhosttyAutomationPermission.check(askIfNeeded: false, target: ITerm2Navigation.bundleIdentifier)
                }.value
                if access == .denied, !hostSwitches.isOn(.iTerm2) { iTerm2.access = access }
            }
        }
    }

    /// The iTerm2 switch moved (`setHostSwitch`). On asks macOS; off forgets every visit.
    func iTerm2SwitchChanged(_ on: Bool) {
        iTerm2.generation += 1
        iTerm2.startupRetries = 0
        iTerm2.scan = .notRead
        iTerm2.inUse = false
        iTerm2.codexInputBlocks = [:]
        iTerm2.latestTitles = nil
        iTerm2.visits.reset(at: Date().timeIntervalSince1970)
        if on {
            iTerm2.access = nil
            probeITerm2Access()
        }
    }

    /// Asks macOS for Automation consent to iTerm2, showing its prompt when no decision exists. Only a
    /// denial switches iTerm2 off; iTerm2 not running keeps it on until iTerm2 launches.
    private func probeITerm2Access() {
        guard hostSwitches.isOn(.iTerm2), !iTerm2.probing else { return }
        iTerm2.probing = true
        let generation = iTerm2.generation
        Task { @MainActor in
            let access = await Task.detached {
                GhosttyAutomationPermission.check(askIfNeeded: true, target: ITerm2Navigation.bundleIdentifier)
            }.value
            iTerm2.probing = false
            if generation != iTerm2.generation {
                probeITerm2Access()
                return
            }
            if access == .ghosttyNotRunning, TerminalApps.isRunning(.iTerm2), iTerm2.startupRetries < 10 {
                // Listed before it accepts Apple Events: retry once a second, ten times at most.
                iTerm2.startupRetries += 1
                iTerm2.probing = true
                try? await Task.sleep(for: .seconds(1))
                iTerm2.probing = false
                probeITerm2Access()
                return
            }
            iTerm2.startupRetries = 0
            applyITerm2Access(access)
            refresh()
        }
    }

    private func applyITerm2Access(_ access: GhosttyAutomationAccess) {
        guard hostSwitches.isOn(.iTerm2) else { return }
        iTerm2.access = access
        switch GhosttyControlsPolicy.outcome(for: access) {
        case .disable:
            setHostSwitch(.iTerm2, on: false)
            iTerm2.access = access
            navigationMessage = ITerm2SettingsProblem.automationDenied.message
        case .awaitGhostty:
            navigationMessage = "macOS will ask for access to iTerm2 when iTerm2 is open."
        case .verified, .unverified:
            break
        }
    }

    // MARK: - Open (ADR 0016's sequence, ADR 0015's fallback)

    /// Open for a Codex CLI session while iTerm2 is on: ADR 0013's binding across the enabled hosts,
    /// then the exact iTerm2 session, Ghostty's title route, or a fallback or unavailable line.
    func openCLIAcrossHosts(_ session: UUID) {
        guard !openingTask, let title = HerdrCodexBindingRules.title(forSession: session.uuidString.lowercased()) else { return }
        openingTask = true
        navigationMessage = "Finding the matching terminal tab…"
        let live = liveCLI
        let liveIDs = Set(live.map(\.uuidString))
        let switches = hostSwitches
        let ghosttyOn = ghosttyEnabled
        let ghosttyRunning = ghosttyOn && TerminalApps.isRunning(.ghostty)
        let iTerm2Running = TerminalApps.isRunning(.iTerm2)
        let terminalAppRunning: Bool? = terminalAppSwitchedOn ? TerminalApps.isRunning(.terminalApp) : nil
        let wezTermRunning: Bool? = wezTermSwitchedOn ? TerminalApps.isRunning(.wezTerm) : nil
        let tmuxOn = tmuxContactAllowed
        let zellijOn = zellijContactAllowed
        let liveness: HerdrSessionLiveness = live.contains(session) ? .live : .ended
        let record = ITerm2OpenRecord()
        Task { @MainActor in
            let run = await ITerm2Open.run(
                now: { Date().timeIntervalSince1970 },
                revalidate: { _ in
                    let reads = await Task.detached {
                        CodexTabReads.read(titles: [title], claudeTTYs: [], ghosttyOn: ghosttyOn,
                                           ghosttyRunning: ghosttyRunning, iTerm2Running: iTerm2Running,
                                           terminalAppRunning: terminalAppRunning, wezTermRunning: wezTermRunning,
                                           tmuxOn: tmuxOn, zellijOn: zellijOn)
                    }.value
                    let binding = TerminalTabBindingRules.codex(sessionID: session.uuidString, liveness: liveness,
                                                                liveSessions: liveIDs, switches: switches,
                                                                inventories: reads.inventories, processes: reads.processes,
                                                                secondRead: reads.secondRead,
                                                                multiplexerClientTTYs: reads.multiplexerClientTTYs)
                    record.reads = reads
                    record.binding = binding
                    return ITerm2Open.plan(TerminalTabOpen.route(binding), codexTitle: title)
                },
                select: { plan in await Task.detached { ITerm2Navigation.select(plan) }.value },
                verifyRead: { await self.iTerm2VerifyRead() })
            let result: TerminalOpenResult
            var opened = "Opened the matching iTerm2 tab."
            switch run {
            case .opened(_, let preOpenAt):
                result = .opened
                acknowledgeCodexOpen(session, preOpenAt: preOpenAt)
            case .failed(_, .revalidate) where record.binding.map(TerminalTabOpen.route) == .ghosttyTitle:
                // ADR 0013: a Ghostty without `tty` holds the only tab with the title; its title route decides.
                opened = "Opened the matching Ghostty tab."
                let preOpenAt = Date().timeIntervalSince1970
                let outcome = await Task.detached {
                    await GhosttyNavigation.open(session: session, live: live, running: ghosttyRunning)
                }.value
                result = await openResult(outcome) { count in
                    OpenFallback.codexApp(candidates: GhosttyTitleOpen.codexCandidates(count: count), switches: switches)
                }
                if result == .opened { acknowledgeCodexOpen(session, preOpenAt: preOpenAt) }
            case .failed(let miss, _):
                let carriers = record.reads.map {
                    TerminalTabOpen.codexCarriers(title: title, switches: switches, inventories: $0.inventories,
                                                  processes: $0.processes)
                } ?? []
                // ADR 0015 amendment: walk from each titled tab's own `codex`; never a guess past a failed walk.
                result = await openResult(.miss(miss)) { _ in
                    let candidates = await Task.detached {
                        TerminalTabOpen.codexCandidates(carriers, walk: TerminalApps.walk(from:),
                                                        ttyWrittenAt: TerminalTTYReads.writtenAt)
                    }.value
                    return OpenFallback.codexApp(candidates: candidates, switches: switches)
                }
            }
            iTerm2.lastOpen[session.uuidString] = Self.iTerm2Diagnostic(run, result: result)
            navigationMessage = message(for: result, opened: opened)
            recordOpen(result, codex: session)
            endVisitIntervalsAfterOpen()
            openingTask = false
            refresh()
        }
    }

    /// ADR 0016: a verified Open acknowledges the session's completions that arrived before the pre-Open read.
    private func acknowledgeCodexOpen(_ session: UUID, preOpenAt: Double) {
        let queued = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
        let acknowledged = TerminalVisitAcknowledgment.afterOpen(queued, result: .opened, preOpenAt: preOpenAt)
        guard !acknowledged.isEmpty else { return }
        acknowledgeCodexCompletions(Array(acknowledged))
        saveCompletions()
    }

    /// Open for a live Claude session's registered process while iTerm2 is on. Nil when the process's
    /// tty is on no iTerm2 tab, so Ghostty's title route or the process walk decides as before; otherwise
    /// the iTerm2 Open's result, a fallback included.
    func openClaudeInITerm2(sessionID: String, process: ClaudeSessionRegistry.Process?) async -> TerminalOpenResult? {
        guard hostSwitches.mayContact(.iTerm2), let process else { return nil }
        let pid = process.pid
        // Only tty-bound hosts take part: a Ghostty tab without `tty` never holds a tty binding (ADR 0013).
        let switches = TerminalHostSwitches(enabled: [.iTerm2])
        let running = TerminalApps.isRunning(.iTerm2)
        let record = ITerm2OpenRecord()
        let run = await ITerm2Open.run(
            now: { Date().timeIntervalSince1970 },
            revalidate: { _ in
                let reads = await Task.detached { () -> (ITerm2Reading?, TerminalProcessObservation?, [String: [TerminalProcess]]) in
                    let reading = running ? ITerm2Navigation.snapshot() : .notRunning
                    let observed = TerminalTTYReads.observation(of: pid)
                    var ttys: Set<String> = []
                    if case .snapshot(let value)? = reading {
                        ttys = value.ttysToRead(codexTitles: [], claudeTTYs: Set(observed?.tty.map { [$0] } ?? []))
                    }
                    return (reading, observed, TerminalTTYReads.processes(on: ttys))
                }.value
                let binding = TerminalTabBindingRules.claude(sessionID: sessionID, liveness: .live,
                                                             process: .registered(process),
                                                             observed: reads.1, switches: switches,
                                                             inventories: [.iTerm2: ITerm2Navigation.inventory(reads.0)],
                                                             processes: reads.2)
                record.binding = binding
                return ITerm2Open.plan(TerminalTabOpen.route(binding), codexTitle: nil)
            },
            select: { plan in await Task.detached { ITerm2Navigation.select(plan) }.value },
            verifyRead: { await self.iTerm2VerifyRead() })
        let result: TerminalOpenResult
        switch run {
        case .opened:
            result = .opened
        case .failed(_, .revalidate) where record.binding == .unavailable(.ttyNotInEnabledHost):
            return nil
        case .failed(let miss, _):
            let hostSwitches = hostSwitches
            result = await openResult(.miss(miss)) { _ in
                let walk = await Task.detached { TerminalApps.walk(from: pid) }.value
                return OpenFallback.processApp(walks: [walk], agent: .claude, switches: hostSwitches)
            }
        }
        iTerm2.lastOpen[sessionID] = Self.iTerm2Diagnostic(run, result: result)
        return result
    }

    /// Step 4's reads: a fresh inventory, then the app macOS reports frontmost.
    private func iTerm2VerifyRead() async -> (ITerm2Snapshot?, TerminalHost?) {
        let reading = await Task.detached { ITerm2Navigation.snapshot() }.value
        guard case .snapshot(let value)? = reading else { return (nil, TerminalApps.frontmostHost()) }
        return (value, TerminalApps.frontmostHost())
    }

    private static func iTerm2Diagnostic(_ run: TerminalOpenRun<ITerm2OpenPlan, OpenMiss>, result: TerminalOpenResult) -> String {
        switch run {
        case .opened: return "Open: verified"
        case .failed(let miss, let step): return "Open: \(result) after \(miss) at \(step)"
        }
    }

    // MARK: - Typed input (ADR 0017; ADR 0013 "Freshness")

    // iTerm2's latest-scan blocks feed the shared routes: `terminalReplyRoutes`, `terminalHost(forQuestionSession:)`
    // and `unreadQuestionHost(for:)` (Companion+TerminalApp.swift). The fresh read before a Ghostty key is
    // the shared `TerminalKeyRelayCheck` over every enabled host (Companion+Questions.swift).

    // MARK: - Visits (ADR 0016) and typed-input blocks

    /// Every two seconds while iTerm2 is on. Visibility needs macOS to report iTerm2 frontmost; when it
    /// is not, nothing there is visible, and iTerm2 is read only while a queued CLI question or
    /// completion could show input controls (to keep their iTerm2 line current), or while a daemon
    /// session's end check waits on a fresh inventory (`codexSessionsAwaitingInventory`, #265). One check at a time;
    /// none during an Open.
    func checkITerm2Visits() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard previewMode == nil, hostSwitches.mayContact(.iTerm2), !iTerm2.probing, !iTerm2.checking, !openingTask,
              uptime >= iTerm2.nextScan else { return }
        let claudeOutcomes = agentQueue.snapshot.outcomes.filter { $0.session.source == .claude && $0.session.surface == .cli }
        let cliQuestions = queue.items.compactMap(\.question).filter { $0.source == .cli }
        guard !cliItems.isEmpty || !cliQuestions.isEmpty || !liveCLI.isEmpty || !liveClaudeSessions.isEmpty
                || !claudeOutcomes.isEmpty else { return }
        iTerm2.nextScan = uptime + 2
        let takenAt = Date().timeIntervalSince1970
        let frontmost = TerminalApps.frontmostHost()
        let inputSessions = Set(cliItems.map(\.session)).union(cliQuestions.map(\.session))
        guard frontmost == .iTerm2 || !inputSessions.isEmpty || !codexSessionsAwaitingInventory.isEmpty else {
            iTerm2.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: .nothing))
            return
        }
        iTerm2.checking = true
        let live = liveCLI
        let liveIDs = Set(live.map(\.uuidString))
        let codexSessions = live.union(inputSessions)
        let titles = Set(codexSessions.compactMap { HerdrCodexBindingRules.title(forSession: $0.uuidString.lowercased()) })
        // Each queued Claude session's one registered process, from the latest inventories.
        var claudeProcesses: [AgentSessionIdentity: ClaudeSessionRegistry.Process] = [:]
        for identity in Set(claudeOutcomes.map(\.session)) {
            let own = claudeInventories[identity.sourceScope]?.sessions
                .filter { $0.kind == .interactive && $0.sessionID == identity.session } ?? []
            if own.count == 1, let pid = own[0].pid { claudeProcesses[identity] = .init(pid: pid, procStart: own[0].procStart) }
        }
        let processes = claudeProcesses
        let switches = hostSwitches
        let ghosttyOn = ghosttyEnabled
        let ghosttyRunning = ghosttyOn && TerminalApps.isRunning(.ghostty)
        let iTerm2Running = TerminalApps.isRunning(.iTerm2)
        // An enabled host left unread would make every binding here unavailable (ADR 0013), so Terminal.app
        // (#239), WezTerm (#240), tmux (#241) and Zellij (#242) are read beside iTerm2 while each is on.
        let terminalAppRunning: Bool? = terminalAppSwitchedOn ? TerminalApps.isRunning(.terminalApp) : nil
        let wezTermRunning: Bool? = wezTermSwitchedOn ? TerminalApps.isRunning(.wezTerm) : nil
        let tmuxOn = tmuxContactAllowed
        let zellijOn = zellijContactAllowed
        let generation = iTerm2.generation
        Task { @MainActor in
            let observed = await Task.detached { () -> (CodexTabReads, [Int32: TerminalProcessObservation]) in
                let observations = Dictionary(uniqueKeysWithValues: processes.values.compactMap { process in
                    TerminalTTYReads.observation(of: process.pid).map { (process.pid, $0) }
                })
                let reads = CodexTabReads.read(titles: titles, claudeTTYs: Set(observations.values.compactMap(\.tty)),
                                               ghosttyOn: ghosttyOn, ghosttyRunning: ghosttyRunning,
                                               iTerm2Running: iTerm2Running, terminalAppRunning: terminalAppRunning,
                                               wezTermRunning: wezTermRunning, tmuxOn: tmuxOn, zellijOn: zellijOn)
                return (reads, observations)
            }.value
            iTerm2.checking = false
            guard generation == iTerm2.generation, hostSwitches.mayContact(.iTerm2) else { return }
            let reads = observed.0
            recordHostTitles(reads.inventories, takenAt: takenAt)
            let iTerm2Inventory = reads.inventories[.iTerm2] ?? .unreadable
            switch iTerm2Inventory {
            case .tabs(let tabs): iTerm2.scan = .read; iTerm2.access = .granted; iTerm2.latestTitles = Set(tabs.compactMap(\.title))
            case .notRunning: iTerm2.scan = .notRunning
            case .unreadable: iTerm2.scan = .unreadable
            }
            iTerm2.codexInputBlocks = Dictionary(uniqueKeysWithValues: inputSessions.compactMap { session in
                HerdrCodexBindingRules.title(forSession: session.uuidString.lowercased())
                    .flatMap { ITerm2TypedInput.codexBlock(title: $0, processes: reads.processes, iTerm2: iTerm2Inventory) }
                    .map { (session, $0) }
            })
            // Frontmost as macOS reported it when the scan started: anything else shows nothing visible.
            iTerm2.visits.record(TerminalVisibilityScan(takenAt: takenAt,
                                                        reading: TerminalVisibility.iTerm2(reads.iTerm2, frontmost: frontmost)))
            var inUse = false
            for session in codexSessions.sorted(by: { $0.uuidString < $1.uuidString }) {
                let binding = TerminalTabBindingRules.codex(sessionID: session.uuidString,
                                                            liveness: live.contains(session) ? .live : .ended,
                                                            liveSessions: liveIDs, switches: switches,
                                                            inventories: reads.inventories, processes: reads.processes,
                                                            secondRead: reads.secondRead,
                                                            multiplexerClientTTYs: reads.multiplexerClientTTYs)
                guard case .bound(let target) = binding, target.host == .iTerm2 else { continue }
                inUse = true
                let completions = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
                acknowledgeCodexCompletions(Array(iTerm2.visits.acknowledged(completions, target: target.tabID)))
            }
            let claudeSwitches = TerminalHostSwitches(enabled: [.iTerm2])
            for (identity, process) in processes {
                let binding = TerminalTabBindingRules.claude(sessionID: identity.session, liveness: .live,
                                                             process: .registered(process),
                                                             observed: observed.1[process.pid], switches: claudeSwitches,
                                                             inventories: [.iTerm2: iTerm2Inventory],
                                                             processes: reads.processes)
                guard case .bound(let target) = binding, target.host == .iTerm2 else { continue }
                inUse = true
                let completions = agentQueue.snapshot.outcomes.filter { $0.session == identity }.map(TerminalCompletionCandidate.init)
                for id in iTerm2.visits.acknowledged(completions, target: target.tabID) { agentQueue.dismiss(.outcome(id)) }
            }
            if inUse { iTerm2.inUse = true }
            saveCompletions()
            refresh()
        }
    }
}
