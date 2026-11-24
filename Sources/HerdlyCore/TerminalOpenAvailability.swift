import Foundation

// product.md, Notch, "Open unavailable" (#267): at scan time a Codex or Claude CLI card whose Open is
// unavailable replaces Open with one reason line (`OpenUnavailableReason.cardLine`); an Open fallback
// (ADR 0015) looks like any other Open. The scan picks a route in the order a click tries them past herdr
// (`Companion.openCLI`, `Companion.openClaude`): tmux, then Zellij, WezTerm, Terminal.app, iTerm2, then
// Ghostty's title route or the session's own process. What it shares with a click is the binding rules
// (`TerminalTabBindingRules`, `ZellijBindingRules`), the multiplexer plans (`TmuxOpen.plan`,
// `ZellijOpen.plan`), Ghostty's revalidation, ADR 0015's fallback resolution, and the read assembly
// (`TerminalTabReadAssembly`, which the iTerm2 Open's reads use; the other hosts' click reads differ in
// detail). It does not share a host's own plan for a bound tab (Terminal.app's tab alone in its window,
// WezTerm's focused window), its select, verify or activation, so a bound target offers Open; nor the
// click's fallback for the H7 last-seen app, which a click reports as an app it cannot identify. It is
// presentation only: a click still re-runs everything on fresh reads. Pure: HerdlyApp takes the reads and
// walks the processes this asks for.

/// Whether a terminal card offers Open, as the latest scan saw it.
public enum TerminalOpenAvailability: Equatable, Sendable {
    /// The exact target, a route the click decides, or an Open fallback: the card shows Open.
    case offered
    /// The card shows the reason's line in place of Open.
    case unavailable(OpenUnavailableReason)

    public var reason: OpenUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// The agreed line that replaces Open; nil while Open is offered.
    public var cardLine: String? { reason?.cardLine }
}

/// How a missed Open finds the app its fallback would raise (ADR 0015, "Which app and window").
public enum OpenFallbackApp: Equatable, Sendable {
    /// A Codex session: each enabled tab carrying its title, walked from its own `codex` (the amendment).
    case codexCarriers([TerminalCodexCarrier])
    /// A Codex session on Ghostty's title route: the Ghostty terminals carrying its title are in Ghostty.
    case ghosttyTitle
    /// A Claude session's registered process, or a multiplexer session's clients.
    case processes([Int32])
    /// A Codex session no enabled tab carries, whose title this switched-on terminal app showed last
    /// (`ReminderScan.surfaceHosts`). Not running, it is "<app> isn't running." (H7); running, the
    /// session's app still cannot be identified, because nothing in it carries the title.
    case lastSeen(TerminalHost)
}

/// What a scan found on a session's Open route before ADR 0015 resolves it.
public enum OpenScanRoute: Equatable, Sendable {
    /// The exact target is bound, or a later route (Ghostty's title route behind an iTerm2 binding)
    /// decides at click time.
    case reachable
    /// The exact target cannot be reached; `app` says how a fallback would identify its app.
    case miss(OpenMiss, app: OpenFallbackApp)

    /// The processes to walk to their app, only for a miss that may fall back.
    public var pidsToWalk: [Int32] {
        guard case .miss(.fallBack, let app) = self else { return [] }
        switch app {
        case .codexCarriers(let carriers): return carriers.compactMap(\.codexPID)
        case .ghosttyTitle, .lastSeen: return []
        case .processes(let pids): return pids
        }
    }

    /// The ttys whose modification times order candidates in different apps (the amendment).
    public var ttysToTime: [String] {
        guard case .miss(.fallBack, .codexCarriers(let carriers)) = self else { return [] }
        return carriers.compactMap(\.tty)
    }

    /// ADR 0015 over the scan's observations: unavailable stays so; a fallback is offered only when its
    /// app is identified and running, exactly as `OpenFallback.resolve` decides a click.
    ///
    /// - Parameters:
    ///   - walks: where each of `pidsToWalk` led; a missing walk failed.
    ///   - ttyWrittenAt: each of `ttysToTime`'s modification time; a missing one could not be read.
    ///   - isRunning: whether macOS reports the app running.
    public func availability(agent: AgentSource, switches: TerminalHostSwitches,
                             walks: [Int32: TerminalAppWalk], ttyWrittenAt: [String: Double],
                             isRunning: (TerminalHost) -> Bool) -> TerminalOpenAvailability {
        guard case .miss(let miss, let app) = self else { return .offered }
        if case .fallBack = miss, case .lastSeen(let host) = app {
            return .unavailable(isRunning(host) ? .appNotIdentified : .appNotRunning(host))
        }
        let result = OpenFallback.resolve(miss, app: { count in
            switch app {
            case .lastSeen:
                return .failure(.appNotIdentified)
            case .codexCarriers(let carriers):
                let candidates = TerminalTabOpen.codexCandidates(carriers, walk: { walks[$0] ?? .failed },
                                                                 ttyWrittenAt: { ttyWrittenAt[$0] })
                return OpenFallback.codexApp(candidates: candidates, switches: switches)
            case .ghosttyTitle:
                return OpenFallback.codexApp(candidates: GhosttyTitleOpen.codexCandidates(count: count), switches: switches)
            case .processes(let pids):
                return OpenFallback.processApp(walks: pids.map { walks[$0] ?? .failed }, agent: agent, switches: switches)
            }
        }, isRunning: isRunning)
        if case .unavailable(let reason) = result { return .unavailable(reason) }
        return .offered
    }
}

/// One scan's reads across the enabled hosts (ADR 0013): the first inventories, `ps` for the ttys that
/// could bind, a second read, and the multiplexer and Ghostty reads behind them. A host switched off is
/// never read and has no entry.
public struct TerminalOpenScanReads: Sendable {
    public var switches: TerminalHostSwitches
    /// Ghostty controls are on, as the Open routes read them: Ghostty's title route is then the last
    /// Codex route, and the other hosts leave a session they do not hold to it.
    public var ghosttyOn: Bool
    public var inventories: [TerminalHost: TerminalHostInventory]
    public var processes: [String: [TerminalProcess]]
    public var secondRead: [TerminalHost: TerminalHostInventory]
    /// tmux's attached clients and Zellij's client processes: host tabs left out of the title count.
    public var multiplexerClientTTYs: Set<String>
    /// `.notRunning` while tmux may not be contacted.
    public var tmux: TmuxRead
    /// `.notRunning` while Zellij may not be contacted.
    public var zellij: ZellijRead
    /// Ghostty's inventory for its title route, nil when not read or unreadable.
    public var ghostty: GhosttySnapshot?
    public var ghosttyRunning: Bool

    public init(switches: TerminalHostSwitches, ghosttyOn: Bool, inventories: [TerminalHost: TerminalHostInventory],
                processes: [String: [TerminalProcess]], secondRead: [TerminalHost: TerminalHostInventory],
                multiplexerClientTTYs: Set<String> = [], tmux: TmuxRead = .notRunning, zellij: ZellijRead = .notRunning,
                ghostty: GhosttySnapshot? = nil, ghosttyRunning: Bool = false) {
        self.switches = switches
        self.ghosttyOn = ghosttyOn
        self.inventories = inventories
        self.processes = processes
        self.secondRead = secondRead
        self.multiplexerClientTTYs = multiplexerClientTTYs
        self.tmux = tmux
        self.zellij = zellij
        self.ghostty = ghostty
        self.ghosttyRunning = ghosttyRunning
    }

    /// Whether `host`'s inventory has a tab for which `matches` holds.
    func holds(_ host: TerminalHost, _ matches: (TerminalTab) -> Bool) -> Bool {
        guard case .tabs(let tabs)? = inventories[host] else { return false }
        return tabs.contains(where: matches)
    }

    /// `TerminalAppOpen.leavesToOtherRoute` for `host`, whose missing inventory is an unread host.
    func leaves(_ host: TerminalHost, otherRouteOn: Bool, holds: Bool) -> Bool {
        TerminalAppOpen.leavesToOtherRoute(otherRouteOn: otherRouteOn, inventory: inventories[host] ?? .unreadable,
                                           holdsSession: holds)
    }
}

/// ADR 0013's reads in order, shared by the iTerm2 Open's revalidation, iTerm2's visit scan and the
/// availability scan (`CodexTabReads.read`): a first read of every enabled host, `ps -t` for each tab or
/// pane of a tty-listing host that shows one of the Codex titles asked about or runs on a Claude tty, then
/// a second read of every enabled host. HerdlyApp supplies the host and `ps` readers; this only orders
/// them and chooses the ttys, so the scan and the click cannot read differently.
public struct TerminalTabReadAssembly<Extra> {
    public let inventories: [TerminalHost: TerminalHostInventory]
    /// What the first read returned besides inventories (snapshots a plan needs).
    public let extra: Extra
    public let processes: [String: [TerminalProcess]]
    public let secondRead: [TerminalHost: TerminalHostInventory]

    /// The ttys `ps` reads after `inventories`: every tab of a `TerminalHost.ttyBound` host titled with
    /// one of `codexTitles` or on one of `claudeTTYs`, normalized.
    public static func ttysToRead(_ inventories: [TerminalHost: TerminalHostInventory], codexTitles: Set<String>,
                                  claudeTTYs: Set<String>) -> Set<String> {
        let claude = Set(claudeTTYs.compactMap(GhosttyTTYMatch.normalizedTTY))
        var ttys: Set<String> = []
        for host in TerminalHost.ttyBound {
            guard case .tabs(let tabs)? = inventories[host] else { continue }
            for tab in tabs {
                guard let tty = tab.tty.flatMap(GhosttyTTYMatch.normalizedTTY) else { continue }
                if claude.contains(tty) || tab.title.map(codexTitles.contains) == true { ttys.insert(tty) }
            }
        }
        return ttys
    }

    /// As above for every tab titled with any shortened Codex identifier, for reads taken without knowing
    /// which sessions are live (Terminal.app's and the multiplexers'). Every titled tab of every tty-listing
    /// host needs its `ps`, or it could not be told from a title decoy (#268) and the binding fails closed.
    public static func ttysToRead(_ inventories: [TerminalHost: TerminalHostInventory], claudeTTYs: Set<String>) -> Set<String> {
        let titles = TerminalHost.ttyBound.reduce(into: Set<String>()) { titles, host in
            guard case .tabs(let tabs)? = inventories[host] else { return }
            titles.formUnion(tabs.compactMap(\.title).filter(HerdrBindingRules.isShortenedCodexSessionTitle))
        }
        return ttysToRead(inventories, codexTitles: titles, claudeTTYs: claudeTTYs)
    }

    /// Blocking when the readers are: call off the main actor. `readHosts` runs twice, `readProcesses` once
    /// between them.
    public static func take(codexTitles: Set<String>, claudeTTYs: Set<String>,
                            readHosts: () -> ([TerminalHost: TerminalHostInventory], Extra),
                            readProcesses: (Set<String>) -> [String: [TerminalProcess]]) -> TerminalTabReadAssembly {
        let (first, extra) = readHosts()
        let processes = readProcesses(ttysToRead(first, codexTitles: codexTitles, claudeTTYs: claudeTTYs))
        let (second, _) = readHosts()
        return TerminalTabReadAssembly(inventories: first, extra: extra, processes: processes, secondRead: second)
    }
}

extension TerminalTabReadAssembly: Sendable where Extra: Sendable {}

public enum TerminalOpenScan {
    /// A Codex CLI session's route past herdr, in the click's order.
    ///
    /// - Parameters:
    ///   - liveSessions: every live tracked Codex CLI session; one not among them has ended.
    ///   - lastSeenHost: the host whose inventory last showed the session's title, nil when none did. A
    ///     session no enabled tab carries is then "<app> isn't running." while that switched-on terminal
    ///     app is not running (H7), rather than an app that cannot be identified.
    public static func codex(session: UUID, liveSessions: Set<UUID>, reads: TerminalOpenScanReads,
                             lastSeenHost: TerminalHost? = nil) -> OpenScanRoute {
        let route = codexRoute(session: session, liveSessions: liveSessions, reads: reads)
        guard case .miss(let miss, _) = route, case .fallBack(_, candidates: 0) = miss,
              let host = lastSeenHost, host.kind == .terminal, reads.switches.isOn(host) else { return route }
        return .miss(miss, app: .lastSeen(host))
    }

    private static func codexRoute(session: UUID, liveSessions: Set<UUID>, reads: TerminalOpenScanReads) -> OpenScanRoute {
        let title = GhosttyMatch.title(session)
        let switches = reads.switches
        let binding = TerminalTabBindingRules.codex(
            sessionID: session.uuidString, liveness: liveSessions.contains(session) ? .live : .ended,
            liveSessions: Set(liveSessions.map(\.uuidString)), switches: switches,
            inventories: reads.inventories, processes: reads.processes, secondRead: reads.secondRead,
            multiplexerClientTTYs: reads.multiplexerClientTTYs)
        // tmux (#241): a pane of the default server carries the title, or the server cannot be read. A decoy
        // pane leaves a session bound to another host's tab to that host (#268).
        if switches.mayContact(.tmux), reads.tmux != .notRunning,
           reads.tmux.snapshot.map({ snapshot in
               TerminalTabOpen.codexStays(in: .tmux, carriesTitle: snapshot.panes.contains { $0.title == title },
                                          binding: binding)
           }) != false {
            var panes = Set(reads.tmux.snapshot?.panes.filter { $0.title == title }.map(\.paneID) ?? [])
            if case .bound(let target) = binding, target.host == .tmux { panes = [target.tabID] }
            return tmux(binding, panes: panes, reads: reads)
        }
        // Zellij (#242): a pane carries the title, or Zellij cannot be read.
        if switches.mayContact(.zellij), reads.zellij.inventory != .notRunning,
           reads.zellij.snapshot.map({ !$0.panes(titled: title).isEmpty }) != false {
            let zellijBinding = ZellijBindingRules.codex(
                sessionID: session.uuidString, liveness: liveSessions.contains(session) ? .live : .ended,
                liveSessions: Set(liveSessions.map(\.uuidString)), switches: switches,
                inventories: reads.inventories, processes: reads.processes, secondRead: reads.secondRead,
                multiplexerClientTTYs: reads.multiplexerClientTTYs, zellij: reads.zellij.snapshot)
            return zellij(zellijBinding, reads: reads)
        }
        // A host keeps the session only when the binding names none of another host's tabs (#268).
        let holds: (TerminalHost) -> Bool = { host in
            TerminalTabOpen.codexStays(in: host, carriesTitle: reads.holds(host) { $0.title == title }, binding: binding)
        }
        let bindingRoute = codexBindingRoute(binding, title: title, reads: reads)
        // The Herdr app: a terminal there carries the title, or Herdr cannot be read.
        if switches.isOn(.herdrApp),
           !reads.leaves(.herdrApp, otherRouteOn: reads.ghosttyOn || switches.isOn(.rex) || switches.isOn(.wezTerm)
                            || switches.isOn(.terminalApp) || switches.mayContact(.iTerm2),
                         holds: holds(.herdrApp)) {
            return bindingRoute
        }
        // Rex: a block there carries the title, or Rex cannot be read.
        if switches.isOn(.rex),
           !reads.leaves(.rex, otherRouteOn: reads.ghosttyOn || switches.isOn(.wezTerm) || switches.isOn(.terminalApp)
                            || switches.mayContact(.iTerm2),
                         holds: holds(.rex)) {
            return bindingRoute
        }
        if switches.isOn(.wezTerm),
           !reads.leaves(.wezTerm, otherRouteOn: reads.ghosttyOn || switches.isOn(.terminalApp) || switches.mayContact(.iTerm2),
                         holds: holds(.wezTerm)) {
            return bindingRoute
        }
        if switches.isOn(.terminalApp),
           !reads.leaves(.terminalApp, otherRouteOn: reads.ghosttyOn || switches.mayContact(.iTerm2),
                         holds: holds(.terminalApp)) {
            return bindingRoute
        }
        if switches.mayContact(.iTerm2) { return bindingRoute }
        switch GhosttyTitleOpen.revalidate(title: title, live: liveSessions.map(GhosttyMatch.title), ghostty: reads.ghostty,
                                           running: reads.ghosttyRunning, sameWindowOnly: false) {
        case .exact: return .reachable
        case .miss(let miss): return .miss(miss, app: .ghosttyTitle)
        }
    }

    /// A live Claude CLI session's route past herdr, in the click's order.
    ///
    /// - Parameters:
    ///   - process, observed: the registry entry holding the session and a fresh kernel read of it
    ///     (`TerminalTabBindingRules.claude`).
    ///   - newestRecords: the session's newest hook pane records, for Zellij's rule.
    ///   - liveSessionIDs: every live interactive Claude session, for Ghostty's title route.
    public static func claude(sessionID: String, process: TerminalSessionProcess, observed: TerminalProcessObservation?,
                              newestRecords: [HerdrHookPaneRecord], liveSessionIDs: [String],
                              reads: TerminalOpenScanReads) -> OpenScanRoute {
        let switches = reads.switches
        var walked: [Int32] = []
        if case .registered(let registered) = process {
            // ADR 0013: the registered process is gone, whichever route would have read its tty.
            guard observed?.pid == registered.pid else { return .miss(.unavailable(.sessionEnded), app: .processes([])) }
            walked = [registered.pid]
        }
        let tty = observed?.tty.flatMap(GhosttyTTYMatch.normalizedTTY)
        let binding = TerminalTabBindingRules.claude(sessionID: sessionID, liveness: .live, process: process,
                                                     observed: observed, switches: switches,
                                                     inventories: reads.inventories, processes: reads.processes)
        // tmux (#241): the process's tty is a pane of the default server, or the server cannot be read.
        if switches.mayContact(.tmux), reads.tmux != .notRunning,
           reads.tmux.snapshot.map({ $0.panes.contains { $0.tty == tty } }) != false {
            var panes = Set(reads.tmux.snapshot?.panes.filter { $0.tty == tty }.map(\.paneID) ?? [])
            if case .bound(let target) = binding, target.host == .tmux { panes = [target.tabID] }
            return tmux(binding, panes: panes, reads: reads)
        }
        // Zellij (#242): its newest hook records and process put the session in a Zellij pane.
        if switches.mayContact(.zellij) {
            let zellijBinding = ZellijBindingRules.claude(sessionID: sessionID, liveness: .live, newestRecords: newestRecords,
                                                          process: process, observed: observed, zellij: reads.zellij)
            if zellijBinding != .notInZellij { return zellij(zellijBinding, reads: reads) }
        }
        let onTTY: (TerminalTab) -> Bool = { tab in tty != nil && tab.tty.flatMap(GhosttyTTYMatch.normalizedTTY) == tty }
        let bindingRoute = processRoute(binding, walked: walked)
        if switches.isOn(.herdrApp), !reads.leaves(.herdrApp, otherRouteOn: true, holds: reads.holds(.herdrApp, onTTY)) {
            return bindingRoute
        }
        if switches.isOn(.rex), !reads.leaves(.rex, otherRouteOn: true, holds: reads.holds(.rex, onTTY)) {
            return bindingRoute
        }
        if switches.isOn(.wezTerm), !reads.leaves(.wezTerm, otherRouteOn: true, holds: reads.holds(.wezTerm, onTTY)) {
            return bindingRoute
        }
        if switches.isOn(.terminalApp), !reads.leaves(.terminalApp, otherRouteOn: true, holds: reads.holds(.terminalApp, onTTY)) {
            return bindingRoute
        }
        // iTerm2 decides whenever the process's tty is on one of its tabs (#238).
        if switches.mayContact(.iTerm2), !walked.isEmpty {
            let iTerm2 = TerminalTabBindingRules.claude(sessionID: sessionID, liveness: .live, process: process,
                                                        observed: observed, switches: TerminalHostSwitches(enabled: [.iTerm2]),
                                                        inventories: [.iTerm2: reads.inventories[.iTerm2] ?? .unreadable],
                                                        processes: reads.processes)
            if iTerm2 != .unavailable(.ttyNotInEnabledHost) { return processRoute(iTerm2, walked: walked) }
        }
        guard reads.ghosttyOn else { return .miss(.fallBack(.noUniqueTarget, candidates: 0), app: .processes(walked)) }
        guard let title = GhosttyMatch.claudeTitle(sessionID) else {
            return .miss(.fallBack(.noUniqueTarget, candidates: 0), app: .processes(walked))
        }
        switch GhosttyTitleOpen.revalidate(title: title, live: liveSessionIDs.compactMap(GhosttyMatch.claudeTitle),
                                           ghostty: reads.ghostty, running: reads.ghosttyRunning, sameWindowOnly: true) {
        case .exact: return .reachable
        case .miss(let miss): return .miss(miss, app: .processes(walked))
        }
    }

    /// ADR 0013's cross-host binding for a Codex tab: a miss walks every enabled tab carrying the title.
    static func codexBindingRoute(_ binding: TerminalTabBinding, title: String, reads: TerminalOpenScanReads) -> OpenScanRoute {
        switch TerminalTabOpen.route(binding) {
        case .exact, .ghosttyTitle: return .reachable
        case .miss(let miss):
            return .miss(miss, app: .codexCarriers(TerminalTabOpen.codexCarriers(
                title: title, switches: reads.switches, inventories: reads.inventories, processes: reads.processes)))
        }
    }

    /// A binding whose miss walks the session's own process (Claude, ADR 0015).
    static func processRoute(_ binding: TerminalTabBinding, walked: [Int32]) -> OpenScanRoute {
        switch TerminalTabOpen.route(binding) {
        case .exact, .ghosttyTitle: return .reachable
        case .miss(let miss): return .miss(miss, app: .processes(walked))
        }
    }

    /// ADR 0014's two layers on tmux: a miss walks the clients of the session's panes.
    static func tmux(_ binding: TerminalTabBinding, panes: Set<String>, reads: TerminalOpenScanReads) -> OpenScanRoute {
        guard let snapshot = reads.tmux.snapshot else {
            return .miss(TerminalTabOpen.miss(binding.unavailableReason ?? .hostUnreadable(.tmux)), app: .processes([]))
        }
        let plan = TmuxOpen.plan(binding, snapshot: snapshot, join: {
            MultiplexerHostTab.join(clientTTY: $0, switches: reads.switches, inventories: reads.inventories)
        })
        switch plan {
        case .success: return .reachable
        case .failure(let miss):
            let pids = Array(Set(panes.flatMap { TmuxOpen.fallbackClientPIDs(for: $0, in: snapshot) })).sorted()
            return .miss(miss, app: .processes(pids))
        }
    }

    /// ADR 0014's two layers on Zellij: a miss walks every `zellij` client process.
    static func zellij(_ binding: ZellijBinding, reads: TerminalOpenScanReads) -> OpenScanRoute {
        guard let snapshot = reads.zellij.snapshot else {
            if case .unavailable(let reason) = binding { return .miss(ZellijOpen.miss(reason), app: .processes([])) }
            return .miss(.unavailable(.hostUnreadable(.zellij)), app: .processes([]))
        }
        let plan = ZellijOpen.plan(binding, snapshot: snapshot, join: {
            MultiplexerHostTab.join(clientTTY: $0, switches: reads.switches, inventories: reads.inventories)
        }, hostTitle: { tab in
            guard case .tabs(let tabs)? = reads.inventories[tab.host] else { return nil }
            return tabs.first { $0.tabID == tab.tabID }?.title
        })
        switch plan {
        case .success: return .reachable
        case .failure(let miss): return .miss(miss, app: .processes(ZellijOpen.fallbackClientPIDs(in: snapshot)))
        }
    }
}

/// The Open line each terminal card shows (product.md, "Open unavailable"), keyed by session.
///
/// A scan's cause replaces Open with its line. When an Open the scan offered fails its click-time
/// recheck with an unavailable cause, the same line shows on that card beside Open; the item stays.
/// That click line lasts until the session's next scan that started after the click (which swaps Open
/// for its own line, or finds Open offered and drops it), a later Open of the session that opened or
/// fell back, or the card leaving the queue.
public struct OpenUnavailableLines<Key: Hashable & Sendable>: Equatable, Sendable {
    struct Clicked: Equatable, Sendable {
        let reason: OpenUnavailableReason
        let at: Double
    }

    private var scanned: [Key: OpenUnavailableReason] = [:]
    private var clicked: [Key: Clicked] = [:]
    /// When an Open of the session last opened or fell back: a scan started before it is stale for it.
    private var reached: [Key: Double] = [:]

    public init() {}

    /// Whether the card offers Open: no scan found it unavailable.
    public func offersOpen(_ key: Key) -> Bool { scanned[key] == nil }

    /// The reason whose line the card shows, nil for none: the scan's, else a click's.
    public func line(for key: Key) -> OpenUnavailableReason? { scanned[key] ?? clicked[key]?.reason }

    /// When the click line `line(for:)` may show was recorded, nil for none. A result row's fold
    /// reads it to tell this click's line from an older one (#322).
    public func clickedAt(_ key: Key) -> Double? { clicked[key]?.at }

    /// A scan that started at `startedAt` classified exactly the sessions in `results`. A session it did
    /// not classify keeps no scan line (the click rechecks); a click line from before it gives way. A
    /// session whose Open opened or fell back after the scan started keeps no line from it.
    public mutating func applyScan(_ results: [Key: TerminalOpenAvailability], startedAt: Double) {
        scanned = results.filter { (reached[$0.key] ?? -.infinity) <= startedAt }.compactMapValues(\.reason)
        for key in results.keys where (clicked[key]?.at ?? .infinity) <= startedAt { clicked[key] = nil }
        reached = reached.filter { $0.value > startedAt }
    }

    /// An Open of `key`'s session ended at `at`. Unavailable shows its line; an Open that reached the
    /// session or raised its app (ADR 0015) drops every line until the next scan.
    public mutating func recordOpen(_ result: TerminalOpenResult, for key: Key, at: Double) {
        switch result {
        case .unavailable(let reason): clicked[key] = Clicked(reason: reason, at: at)
        case .opened, .fellBack:
            clicked[key] = nil
            scanned[key] = nil
            reached[key] = at
        }
    }

    /// Forgets the scan line of every session the scan no longer covers (its card left the terminal
    /// route, such as one now bound by herdr, or every host was switched off), whether or not a scan
    /// runs. Click lines keep their own rules.
    public mutating func retainScanned(_ keys: Set<Key>) {
        scanned = scanned.filter { keys.contains($0.key) }
    }

    /// Forgets every line of a card no longer queued.
    public mutating func retain(_ keys: Set<Key>) {
        scanned = scanned.filter { keys.contains($0.key) }
        clicked = clicked.filter { keys.contains($0.key) }
        reached = reached.filter { keys.contains($0.key) }
    }

    /// The card's one line. A Codex question whose option cannot be typed while Open is also unavailable
    /// shows "Answer this in Codex." followed by Open's line, never two lines.
    public static func cardLine(_ reason: OpenUnavailableReason, questionCannotBeTyped: Bool) -> String {
        questionCannotBeTyped ? "Answer this in Codex. " + reason.cardLine : reason.cardLine
    }
}

extension TerminalTabBinding {
    /// The reason a binding is unavailable, nil when bound.
    public var unavailableReason: TerminalTabUnavailable? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// Whether complete Claude inventories list a session as live (`Companion.canOpenClaude`'s gate).
public enum ClaudeInventoryPresence: Equatable, Sendable {
    /// Listed exactly once.
    case live
    /// Every configured root's inventory is complete and none lists the session.
    case absent
    /// Inventories are incomplete, or the session is listed more than once.
    case unknown

    /// The session's presence across every configured root's latest inventory.
    ///
    /// - Parameters:
    ///   - listedByScope: each root's `ClaudeInventoryScan.listedSessionIDs`, so a session a running
    ///     background job holds (#393) is live, not ended.
    ///   - inventoryAvailable: whether each root's latest scan was complete.
    ///   - configuredScopes: the roots navigation includes, nil when there are none.
    /// - Returns: `.unknown` unless both maps cover exactly the configured roots and every scan is complete.
    public static func of(session: String, scope: String, listedByScope: [String: Set<String>],
                          inventoryAvailable: [String: Bool], configuredScopes: Set<String>?) -> Self {
        guard let configuredScopes, Set(listedByScope.keys) == configuredScopes,
              Set(inventoryAvailable.keys) == configuredScopes,
              inventoryAvailable.values.allSatisfy({ $0 }) else { return .unknown }
        let everywhere = listedByScope.values.filter { $0.contains(session) }.count
        if everywhere == 0 { return .absent }
        return everywhere == 1 && listedByScope[scope]?.contains(session) == true ? .live : .unknown
    }
}

/// H7 for a Claude CLI card that is no longer live (#280). A Claude process ends with the terminal app it
/// runs in, so once that app quits the card cannot reach Open and the scan no longer follows it. The app
/// the session's own process last walked to (ADR 0015) names the line instead, as `lastSeenHosts` does for
/// a Codex card: "<app> isn't running." while that app is not running, then "This session has ended." once
/// it runs again without the session. Pure: HerdlyApp walks the process and asks macOS what is running.
public enum ClaudeLastSeenHost {
    /// The registered process a scan walks to record the session's app: only one whose fresh kernel read
    /// is the registered process (same PID and, when Claude recorded one, the same start), so a reused
    /// PID never names an app.
    public static func pidToWalk(process: TerminalSessionProcess, observed: TerminalProcessObservation?) -> Int32? {
        guard case .registered(let registered) = process, let observed, observed.pid == registered.pid else { return nil }
        if let recorded = registered.procStart, observed.procStart != recorded { return nil }
        return registered.pid
    }

    /// The terminal app a walk names, nil for anything else: a multiplexer's process walks to no app, and
    /// a stopped multiplexer server is never "isn't running".
    public static func host(from walk: TerminalAppWalk) -> TerminalHost? {
        guard case .reached(let host) = walk, host.kind == .terminal else { return nil }
        return host
    }

    /// The line a Claude card that is not offered Open shows in place of
    /// `claudeReturnUnavailableMessage`; nil keeps that message. A live session keeps its own route.
    public static func openLine(lastSeen: TerminalHost?, presence: ClaudeInventoryPresence,
                                isRunning: (TerminalHost) -> Bool) -> OpenUnavailableReason? {
        guard presence != .live, let host = lastSeen, host.kind == .terminal else { return nil }
        if !isRunning(host) { return .appNotRunning(host) }
        return presence == .absent ? .sessionEnded : nil
    }
}
