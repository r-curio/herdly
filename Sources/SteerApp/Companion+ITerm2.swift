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
    /// ADR 0016's visit interval and dwell run over iTerm2 sessions, by session GUID.
    var visits = TerminalVisitTracker<String>()
    var probing = false
    /// A consent check started before the user last switched iTerm2 applies to nothing.
    var generation = 0
    var startupRetries = 0
    var checking = false
    var nextScan: Double = 0
    var launchObserver: NSObjectProtocol?
}

/// Reads behind one Codex binding across the enabled tab hosts (ADR 0013): two inventories with the
/// `ps -t` reads between them.
private struct CodexTabReads: Sendable {
    let inventories: [TerminalHost: TerminalHostInventory]
    let processes: [String: [TerminalProcess]]
    let secondRead: [TerminalHost: TerminalHostInventory]
    let iTerm2: ITerm2Snapshot?

    /// Blocking: call off the main actor. Ghostty is read only while it is on and running, iTerm2 only
    /// while running; `ps` only for tabs showing one of `titles` or on one of `claudeTTYs`.
    static func read(titles: Set<String>, claudeTTYs: Set<String>, ghosttyOn: Bool, ghosttyRunning: Bool,
                     iTerm2Running: Bool) -> CodexTabReads {
        func hosts() -> ([TerminalHost: TerminalHostInventory], ITerm2Snapshot?) {
            var result: [TerminalHost: TerminalHostInventory] = [:]
            let reading = iTerm2Running ? ITerm2Navigation.snapshot() : .notRunning
            result[.iTerm2] = ITerm2Navigation.inventory(reading)
            if ghosttyOn {
                result[.ghostty] = .ghosttyTitles(ghosttyRunning ? GhosttyNavigation.snapshot() : nil, running: ghosttyRunning)
            }
            if case .snapshot(let value)? = reading { return (result, value) }
            return (result, nil)
        }
        let (first, snapshot) = hosts()
        let ttys = snapshot?.ttysToRead(codexTitles: titles, claudeTTYs: claudeTTYs) ?? []
        let processes = TerminalTTYReads.processes(on: ttys)
        let (second, _) = hosts()
        return CodexTabReads(inventories: first, processes: processes, secondRead: second, iTerm2: snapshot)
    }
}

/// What an iTerm2 Open's revalidation saw, kept for the fallback decision after the sequence.
@MainActor
private final class ITerm2OpenRecord {
    var reads: CodexTabReads?
    var binding: TerminalTabBinding?
}

extension Companion {
    /// Whether a terminal host that can hold a Codex CLI tab is on: Ghostty, or iTerm2 (#238).
    var cliTerminalHostOn: Bool { ghosttyEnabled || hostSwitches.mayContact(.iTerm2) }

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
        let liveness: HerdrSessionLiveness = live.contains(session) ? .live : .ended
        let record = ITerm2OpenRecord()
        Task { @MainActor in
            let run = await ITerm2Open.run(
                now: { Date().timeIntervalSince1970 },
                revalidate: { _ in
                    let reads = await Task.detached {
                        CodexTabReads.read(titles: [title], claudeTTYs: [], ghosttyOn: ghosttyOn,
                                           ghosttyRunning: ghosttyRunning, iTerm2Running: iTerm2Running)
                    }.value
                    let binding = TerminalTabBindingRules.codex(sessionID: session.uuidString, liveness: liveness,
                                                                liveSessions: liveIDs, switches: switches,
                                                                inventories: reads.inventories, processes: reads.processes,
                                                                secondRead: reads.secondRead)
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
    func openClaudeInITerm2(sessionID: String, pid: Int32?) async -> TerminalOpenResult? {
        guard hostSwitches.mayContact(.iTerm2), let pid else { return nil }
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
                                                             process: .registered(.init(pid: pid, procStart: nil)),
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

    // MARK: - Visits (ADR 0016)

    /// Every two seconds while iTerm2 is on and a CLI session could be in it. iTerm2 is asked only while
    /// macOS reports it frontmost; otherwise nothing there is visible. One check at a time; none during
    /// an Open.
    func checkITerm2Visits() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard previewMode == nil, hostSwitches.mayContact(.iTerm2), !iTerm2.probing, !iTerm2.checking, !openingTask,
              uptime >= iTerm2.nextScan else { return }
        let claudeOutcomes = agentQueue.snapshot.outcomes.filter { $0.session.source == .claude && $0.session.surface == .cli }
        guard !cliItems.isEmpty || !liveCLI.isEmpty || !liveClaudeSessions.isEmpty || !claudeOutcomes.isEmpty else { return }
        iTerm2.nextScan = uptime + 2
        let takenAt = Date().timeIntervalSince1970
        guard TerminalApps.frontmostHost() == .iTerm2 else {
            iTerm2.visits.record(TerminalVisibilityScan(takenAt: takenAt, reading: .nothing))
            return
        }
        iTerm2.checking = true
        let live = liveCLI
        let liveIDs = Set(live.map(\.uuidString))
        let codexSessions = live.union(cliItems.map(\.session))
        let titles = Set(codexSessions.compactMap { HerdrCodexBindingRules.title(forSession: $0.uuidString.lowercased()) })
        // Each queued Claude session's one registered process, from the latest inventories.
        var claudePIDs: [AgentSessionIdentity: Int32] = [:]
        for identity in Set(claudeOutcomes.map(\.session)) {
            let own = claudeInventories[identity.sourceScope]?.sessions
                .filter { $0.kind == .interactive && $0.sessionID == identity.session } ?? []
            if own.count == 1, let pid = own[0].pid { claudePIDs[identity] = pid }
        }
        let pids = claudePIDs
        let switches = hostSwitches
        let ghosttyOn = ghosttyEnabled
        let ghosttyRunning = ghosttyOn && TerminalApps.isRunning(.ghostty)
        let generation = iTerm2.generation
        Task { @MainActor in
            let observed = await Task.detached { () -> (CodexTabReads, [Int32: TerminalProcessObservation]) in
                let observations = Dictionary(uniqueKeysWithValues: pids.values.compactMap { pid in
                    TerminalTTYReads.observation(of: pid).map { (pid, $0) }
                })
                let reads = CodexTabReads.read(titles: titles, claudeTTYs: Set(observations.values.compactMap(\.tty)),
                                               ghosttyOn: ghosttyOn, ghosttyRunning: ghosttyRunning, iTerm2Running: true)
                return (reads, observations)
            }.value
            iTerm2.checking = false
            guard generation == iTerm2.generation, hostSwitches.mayContact(.iTerm2) else { return }
            let reads = observed.0
            switch reads.inventories[.iTerm2] {
            case .tabs?: iTerm2.scan = .read; iTerm2.access = .granted
            case .notRunning?: iTerm2.scan = .notRunning
            case .unreadable?, nil: iTerm2.scan = .unreadable
            }
            iTerm2.visits.record(TerminalVisibilityScan(takenAt: takenAt,
                                                        reading: TerminalVisibility.iTerm2(reads.iTerm2, frontmost: .iTerm2)))
            var inUse = false
            for session in codexSessions.sorted(by: { $0.uuidString < $1.uuidString }) {
                let binding = TerminalTabBindingRules.codex(sessionID: session.uuidString,
                                                            liveness: live.contains(session) ? .live : .ended,
                                                            liveSessions: liveIDs, switches: switches,
                                                            inventories: reads.inventories, processes: reads.processes,
                                                            secondRead: reads.secondRead)
                guard case .bound(let target) = binding, target.host == .iTerm2 else { continue }
                inUse = true
                let completions = cliItems.filter { $0.session == session }.map(TerminalCompletionCandidate.init)
                acknowledgeCodexCompletions(Array(iTerm2.visits.acknowledged(completions, target: target.tabID)))
            }
            let claudeSwitches = TerminalHostSwitches(enabled: [.iTerm2])
            for (identity, pid) in pids {
                let binding = TerminalTabBindingRules.claude(sessionID: identity.session, liveness: .live,
                                                             process: .registered(.init(pid: pid, procStart: nil)),
                                                             observed: observed.1[pid], switches: claudeSwitches,
                                                             inventories: [.iTerm2: reads.inventories[.iTerm2] ?? .unreadable],
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
