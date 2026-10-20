import Foundation
import Testing
@testable import HerdlyCore

// Issue #265: a daemon-held Codex session (rollout `source: vscode`, originator not the desktop's)
// is ended when no tab shows its title after the surface grace. Every switched-on host's tabs and
// panes count as its surface, not only Ghostty's and herdr's.

private struct DaemonSessionFixture {
    let session = UUID()
    let root: URL
    let events: URL
    let rollouts: URL
    let started: Double

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("herdly-surface-\(UUID().uuidString)")
        events = root.appendingPathComponent("events")
        rollouts = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
        let startedAt = "2026-10-13T09:00:00Z"
        started = RolloutTimestamp.parse(startedAt)!
        let hook = "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"\(session)\",\"received_at\":\"\(startedAt)\"}"
        try hook.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
        let rollout = rollouts.appendingPathComponent("rollout-2026-10-13T09-00-00-\(session.uuidString.lowercased()).jsonl")
        let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"vscode\",\"originator\":\"herdly\"}}\n"
        try header.write(to: rollout, atomically: true, encoding: .utf8)
    }

    var title: String { GhosttyMatch.title(session) }
    /// Well past the grace.
    var later: Double { started + 100 }

    /// By default with a Ghostty inventory that does not show the session, as when it runs in another host.
    func scan(otherHosts: [TerminalHost: TerminalHostTitles], ghostty: GhosttyInventory?? = nil,
              ghosttyOn: Bool = true, knownCLISessions: Set<UUID> = [],
              lastSeenHosts: [UUID: TerminalHost] = [:]) -> ReminderScan {
        ReminderReader.scan(events: events, rollouts: rollouts,
                            ghostty: ghostty ?? GhosttyInventory(titles: ["zsh"], takenAt: later),
                            knownCLISessions: knownCLISessions, daemonThreads: [session], otherHosts: otherHosts,
                            ghosttyOn: ghosttyOn, lastSeenHosts: lastSeenHosts)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test(arguments: TerminalHostTitles.hosts)
func aDaemonSessionShownInASwitchedOnHostIsNotEnded(host: TerminalHost) throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    let scan = fixture.scan(otherHosts: [host: .known(["zsh", fixture.title], takenAt: fixture.later)])
    #expect(scan.cliSessions == [fixture.session])
    #expect(scan.cliState.liveSessions == [fixture.session])
    #expect(scan.endedSessions.isEmpty && scan.sessionEnds.isEmpty)
    // Its tab is that host's, not Ghostty's, and the app remembers the host.
    #expect(scan.titledCLISessions.isEmpty)
    #expect(scan.surfaceHosts == [fixture.session: host])
}

@Test(arguments: TerminalHostTitles.hosts)
func aDaemonSessionWhoseTabClosedInASwitchedOnHostEnds(host: TerminalHost) throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    // Dated at the newest inventory consulted, the one that proved the tab gone.
    let scan = fixture.scan(otherHosts: [host: .known(["zsh"], takenAt: fixture.later + 3)])
    #expect(scan.endedSessions == [fixture.session])
    #expect(scan.sessionEnds[fixture.session] == fixture.later + 3)
    #expect(scan.awaitingHostInventories.isEmpty)
    // Another session's title does not stand in for this one.
    let other = fixture.scan(otherHosts: [host: .known([GhosttyMatch.title(UUID())], takenAt: fixture.later)])
    #expect(other.endedSessions == [fixture.session])
}

@Test func aDaemonOnlySessionWaitsForEverySwitchedOnHostsFreshInventory() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    let known = TerminalHostTitles.known(["zsh"], takenAt: fixture.later)
    // Not yet read, or unreadable: a tab there may show the title. The app is asked to read it.
    let unknown = fixture.scan(otherHosts: [.iTerm2: .unknown(takenAt: fixture.later), .wezTerm: known])
    #expect(unknown.cliState.liveSessions == [fixture.session])
    #expect(unknown.endedSessions.isEmpty && unknown.sessionEnds.isEmpty)
    #expect(unknown.awaitingHostInventories == [fixture.session])
    // An inventory taken before the grace ran out may predate the tab: not evidence of absence.
    let stale = fixture.scan(otherHosts: [.iTerm2: .known(["zsh"], takenAt: fixture.started + ReminderReader.surfaceGrace - 1)])
    #expect(stale.cliState.liveSessions == [fixture.session] && stale.endedSessions.isEmpty)
    #expect(stale.awaitingHostInventories == [fixture.session])
    let fresh = fixture.scan(otherHosts: [.iTerm2: .known(["zsh"], takenAt: fixture.started + ReminderReader.surfaceGrace)])
    #expect(fresh.endedSessions == [fixture.session] && fresh.awaitingHostInventories.isEmpty)
    // Inside its own grace a new session is not awaiting anything yet.
    let young = fixture.scan(otherHosts: [.iTerm2: .unknown(takenAt: 0)],
                             ghostty: GhosttyInventory(titles: ["zsh"], takenAt: fixture.started + 1))
    #expect(young.awaitingHostInventories.isEmpty && young.endedSessions.isEmpty)
}

@Test func aGhosttyProvedSessionEndsWhenItsTabClosesWhateverOtherHostsSay() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    // A tab cannot move between apps: an unread host or an unseen one changes nothing for it.
    for others: [TerminalHost: TerminalHostTitles] in [[.iTerm2: .unknown(takenAt: 0)], [.tmux: .unseen], [:]] {
        let closed = fixture.scan(otherHosts: others, knownCLISessions: [fixture.session])
        #expect(closed.endedSessions == [fixture.session], Comment(rawValue: "\(others)"))
        #expect(closed.sessionEnds[fixture.session] == fixture.later)
        #expect(closed.awaitingHostInventories.isEmpty)
    }
}

@Test func aSwitchedOffHostBlocksTheEndOnlyWhileACodexTUIRunsUnderIt() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    let ghosttyOnly = TerminalHostSwitches(enabled: [.ghostty])
    // Terminal.app and iTerm2 running with their switches off, and no Codex TUI under either: they
    // are irrelevant, and a daemon session whose tab closed while Herdly was down ends as before.
    let idle = TerminalHostTitles.forScan(switches: ghosttyOnly, latest: [:], appsRunning: [.terminalApp, .iTerm2],
                                          codexReach: [.ghostty: 1], now: fixture.later)
    #expect(idle.isEmpty)
    #expect(fixture.scan(otherHosts: idle).endedSessions == [fixture.session])
    // A Codex TUI whose ancestry reaches switched-off Terminal.app, or a tmux server: its session may
    // be the one no tab shows. Open says "Herdly can't tell which terminal this session is in." (H8).
    for reach: TerminalHost in [.terminalApp, .iTerm2, .wezTerm, .tmux, .zellij] {
        let held = TerminalHostTitles.forScan(switches: ghosttyOnly, latest: [:], appsRunning: [.terminalApp],
                                              codexReach: [reach: 1], now: fixture.later)
        #expect(held == [reach: .unseen])
        let scan = fixture.scan(otherHosts: held)
        #expect(scan.cliState.liveSessions == [fixture.session] && scan.endedSessions.isEmpty, Comment(rawValue: reach.rawValue))
        #expect(scan.awaitingHostInventories.isEmpty)
    }
    // Ghostty itself switched off with a Codex TUI under it, and iTerm2 on and read.
    let iTerm2Only = TerminalHostSwitches(enabled: [.iTerm2])
    let ghosttyOff = TerminalHostTitles.forScan(switches: iTerm2Only, latest: [.iTerm2: .known(["zsh"], takenAt: fixture.later)],
                                                appsRunning: [.iTerm2], codexReach: [.ghostty: 1], now: fixture.later)
    #expect(ghosttyOff == [.iTerm2: .known(["zsh"], takenAt: fixture.later), .ghostty: .unseen])
    #expect(fixture.scan(otherHosts: ghosttyOff, ghostty: .some(nil), ghosttyOn: false).endedSessions.isEmpty)
}

@Test func withGhosttyOffTheSwitchedOnHostsAloneEndASession() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    // H7: Ghostty off, the session's iTerm2 tab shown, then closed.
    let shown = fixture.scan(otherHosts: [.iTerm2: .known([fixture.title], takenAt: fixture.later)], ghostty: .some(nil), ghosttyOn: false)
    #expect(shown.cliState.liveSessions == [fixture.session] && shown.surfaceHosts == [fixture.session: .iTerm2])
    let closed = fixture.scan(otherHosts: [.iTerm2: .known(["zsh"], takenAt: fixture.later + 2)], ghostty: .some(nil), ghosttyOn: false)
    #expect(closed.endedSessions == [fixture.session] && closed.sessionEnds[fixture.session] == fixture.later + 2)
    // Ghostty off and no other host consulted: nothing to check against.
    #expect(fixture.scan(otherHosts: [:], ghostty: .some(nil), ghosttyOn: false).endedSessions.isEmpty)
    // Ghostty on but unreadable or not running: no end, as before.
    #expect(fixture.scan(otherHosts: [.iTerm2: .known(["zsh"], takenAt: fixture.later)], ghostty: .some(nil)).endedSessions.isEmpty)
}

@Test func aSessionWhoseLastHostIsNotRunningIsNotEnded() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    // H7: quit iTerm2 with the session's tab open. Open says "iTerm2 isn't running.", not ended.
    let quit = fixture.scan(otherHosts: [.iTerm2: .notRunning(takenAt: fixture.later)],
                            lastSeenHosts: [fixture.session: .iTerm2])
    #expect(quit.cliState.liveSessions == [fixture.session] && quit.endedSessions.isEmpty)
    // A Ghostty-proved session last seen in iTerm2 is not ended while iTerm2 is down either.
    #expect(fixture.scan(otherHosts: [.iTerm2: .notRunning(takenAt: fixture.later)], knownCLISessions: [fixture.session],
                         lastSeenHosts: [fixture.session: .iTerm2]).endedSessions.isEmpty)
    // Relaunched and the tab closed: it ends.
    let relaunched = fixture.scan(otherHosts: [.iTerm2: .known(["zsh"], takenAt: fixture.later + 5)],
                                  lastSeenHosts: [fixture.session: .iTerm2])
    #expect(relaunched.endedSessions == [fixture.session])
    // A host not running holds nothing for a session last seen elsewhere, or never seen.
    for lastSeen: [UUID: TerminalHost] in [[:], [fixture.session: .wezTerm]] {
        let elsewhere = fixture.scan(otherHosts: [.iTerm2: .notRunning(takenAt: fixture.later)], lastSeenHosts: lastSeen)
        #expect(elsewhere.endedSessions == [fixture.session])
    }
}

@Test func aMultiplexerWithNoDefaultServerIsUnseenOnlyWhileACodexTUIRunsUnderIt() {
    let switches = TerminalHostSwitches(enabled: [.ghostty, .tmux, .zellij])
    let latest: [TerminalHost: TerminalHostTitles] = [.tmux: .notRunning(takenAt: 7), .zellij: .notRunning(takenAt: 7)]
    // A Codex TUI under a tmux server on another socket: its session may be there.
    #expect(TerminalHostTitles.forScan(switches: switches, latest: latest, appsRunning: [], codexReach: [.tmux: 1], now: 9)
            == [.tmux: .unseen, .zellij: .notRunning(takenAt: 7)])
    #expect(TerminalHostTitles.forScan(switches: switches, latest: latest, appsRunning: [], codexReach: [.zellij: 1], now: 9)
            == [.tmux: .notRunning(takenAt: 7), .zellij: .unseen])
    // No Codex TUI under either: no server holds a session.
    #expect(TerminalHostTitles.forScan(switches: switches, latest: latest, appsRunning: [], codexReach: [:], now: 9)
            == latest)
}

@Test func theScanTakesEachContactableHostsReadingOrItsAppState() {
    let switches = TerminalHostSwitches(enabled: [.ghostty, .iTerm2, .terminalApp, .wezTerm, .tmux])
    let latest: [TerminalHost: TerminalHostTitles] = [.iTerm2: .known(["a"], takenAt: 5), .terminalApp: .notRunning(takenAt: 4),
                                                       .zellij: .known(["z"], takenAt: 1)]
    let titles = TerminalHostTitles.forScan(switches: switches, latest: latest, appsRunning: [.iTerm2, .terminalApp],
                                            codexReach: [:], now: 50)
    // iTerm2 read; Terminal.app relaunched since its "not running" reading: unknown; WezTerm not
    // running: no tab as of now; tmux never read: unknown; Zellij off: absent whatever it said.
    #expect(titles == [.iTerm2: .known(["a"], takenAt: 5), .terminalApp: .unknown(takenAt: 4),
                       .wezTerm: .notRunning(takenAt: 50), .tmux: .unknown(takenAt: 50)])
    // A multiplexer on with no terminal on cannot be contacted: treated as off.
    let tmuxAlone = TerminalHostSwitches(enabled: [.tmux])
    #expect(TerminalHostTitles.forScan(switches: tmuxAlone, latest: [.tmux: .known([], takenAt: 1)], appsRunning: [],
                                       codexReach: [.tmux: 1], now: 50) == [.tmux: .unseen])
    #expect(TerminalHostTitles.forScan(switches: tmuxAlone, latest: [:], appsRunning: [], codexReach: [:], now: 50).isEmpty)
}

@Test func theNewestReadingWinsWhateverOrderScansFinishIn() {
    let tab = TerminalTab(tabID: "1", tty: "/dev/ttys001", title: "codex title", paneCount: 1)
    let untitled = TerminalTab(tabID: "2", tty: "/dev/ttys002", title: nil, paneCount: 1)
    #expect(TerminalHostTitles(inventory: .tabs([tab, untitled]), takenAt: 7) == .known(["codex title"], takenAt: 7))
    #expect(TerminalHostTitles(inventory: .notRunning, takenAt: 7) == .notRunning(takenAt: 7))
    #expect(TerminalHostTitles(inventory: .unreadable, takenAt: 7) == .unknown(takenAt: 7))
    let all = Set(TerminalHostTitles.hosts)
    let newer = TerminalHostTitles.merged([:], inventories: [.iTerm2: .unreadable], takenAt: 20, contactable: all)
    #expect(newer == [.iTerm2: .unknown(takenAt: 20)])
    // An older scan finishing late, readable or not, leaves the newer reading.
    #expect(TerminalHostTitles.merged(newer, inventories: [.iTerm2: .tabs([tab])], takenAt: 10, contactable: all) == newer)
    let known = TerminalHostTitles.merged([.iTerm2: .known(["x"], takenAt: 20)], inventories: [.iTerm2: .unreadable],
                                          takenAt: 10, contactable: all)
    #expect(known == [.iTerm2: .known(["x"], takenAt: 20)])
    // A newer one replaces it; a host Herdly may not contact, or Ghostty, is not recorded.
    let replaced = TerminalHostTitles.merged(newer, inventories: [.iTerm2: .tabs([tab]), .ghostty: .tabs([tab]), .tmux: .notRunning],
                                             takenAt: 30, contactable: [.iTerm2, .ghostty])
    #expect(replaced == [.iTerm2: .known(["codex title"], takenAt: 30)])
}

@Test func aCodexTUIsAncestryNamesTheHostItRunsIn() {
    func chain(_ entries: (String, String?)...) -> [ProcessAncestor] {
        entries.map { ProcessAncestor(command: $0.0, bundleIdentifier: $0.1) }
    }
    let iTerm2 = "com.googlecode.iterm2", terminal = "com.apple.Terminal"
    #expect(CodexCLIProcesses.hostReached(by: chain(("codex", nil), ("zsh", nil), ("login", nil), ("iTerm2", iTerm2))) == .iTerm2)
    #expect(CodexCLIProcesses.hostReached(by: chain(("codex-aarch64-apple-darwin", nil), ("node", nil), ("zsh", nil),
                                                    ("Terminal", terminal))) == .terminalApp)
    // The nearest multiplexer server decides, even with a terminal app above it.
    #expect(CodexCLIProcesses.hostReached(by: chain(("codex", nil), ("zsh", nil), ("tmux", nil))) == .tmux)
    #expect(CodexCLIProcesses.hostReached(by: chain(("codex", nil), ("bash", nil), ("zellij", nil), ("Terminal", terminal))) == .zellij)
    // Not a Codex executable, an unsupported app, or nothing reached.
    #expect(CodexCLIProcesses.hostReached(by: chain(("node", nil), ("zsh", nil), ("iTerm2", iTerm2))) == nil)
    #expect(CodexCLIProcesses.hostReached(by: chain(("codex", nil), ("Code Helper", "com.microsoft.VSCode"), ("iTerm2", iTerm2))) == nil)
    #expect(CodexCLIProcesses.hostReached(by: chain(("codex", nil), ("zsh", nil))) == nil)
    #expect(CodexCLIProcesses.hostsReached(by: [chain(("codex", nil), ("tmux", nil)), chain(("codex", nil), ("iTerm2", iTerm2)),
                                                chain(("codex", nil), ("bash", nil), ("tmux", nil)),
                                                chain(("vim", nil), ("Terminal", terminal))]) == [.tmux: 2, .iTerm2: 1])
}

@Test(arguments: [TerminalHost.tmux, .zellij])
func aSessionLastSeenInAMultiplexerWhoseServerStoppedEnds(host: TerminalHost) throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    // The user exits Codex in a lone tmux session and the server exits with it: no Codex TUI runs
    // under it, so its "not running" reading holds nothing, and the session ends.
    let switches = TerminalHostSwitches(enabled: [.ghostty, host])
    let others = TerminalHostTitles.forScan(switches: switches, latest: [host: .notRunning(takenAt: fixture.later)],
                                            appsRunning: [], codexReach: [:], now: fixture.later)
    #expect(others == [host: .notRunning(takenAt: fixture.later)])
    let scan = fixture.scan(otherHosts: others, lastSeenHosts: [fixture.session: host])
    #expect(scan.endedSessions == [fixture.session])
}

@Test(arguments: [TerminalHost.tmux, .zellij])
func aCodexTUIOnAnotherMultiplexerServerMakesItUnseen(host: TerminalHost) throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    let switches = TerminalHostSwitches(enabled: [.ghostty, host])
    let other = GhosttyMatch.title(UUID())
    // The default server shows one Codex pane, but two Codex TUIs run under that multiplexer's
    // servers: one is on a server Herdly does not read, and its session may be the one no tab shows.
    let busy = TerminalHostTitles.forScan(switches: switches, latest: [host: .known(["zsh", other], takenAt: fixture.later)],
                                          appsRunning: [], codexReach: [host: 2], now: fixture.later)
    #expect(busy == [host: .unseen])
    #expect(fixture.scan(otherHosts: busy).endedSessions.isEmpty)
    // Every Codex TUI accounted for by a Codex title on the default server: its reading stands, and
    // a pane that closed (killing its TUI) still ends its session.
    let accounted = TerminalHostTitles.forScan(switches: switches, latest: [host: .known(["zsh", other], takenAt: fixture.later)],
                                               appsRunning: [], codexReach: [host: 1], now: fixture.later)
    #expect(accounted == [host: .known(["zsh", other], takenAt: fixture.later)])
    #expect(fixture.scan(otherHosts: accounted).endedSessions == [fixture.session])
}

@Test func aDaemonSessionShownOnlyInAStaleReadingAsksForARead() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    // iTerm2 last read a grace before Ghostty: the tab may have closed since. Still live, but iTerm2 is re-read.
    let stale = fixture.scan(otherHosts: [.iTerm2: .known([fixture.title], takenAt: fixture.later - ReminderReader.surfaceGrace)])
    #expect(stale.cliState.liveSessions == [fixture.session] && stale.endedSessions.isEmpty)
    #expect(stale.awaitingHostInventories == [fixture.session])
    // A recent reading, or a Ghostty-proved session, asks for nothing.
    let recent = fixture.scan(otherHosts: [.iTerm2: .known([fixture.title], takenAt: fixture.later - ReminderReader.surfaceGrace + 1)])
    #expect(recent.awaitingHostInventories.isEmpty)
    let proved = fixture.scan(otherHosts: [.iTerm2: .known([fixture.title], takenAt: fixture.later - ReminderReader.surfaceGrace)],
                              knownCLISessions: [fixture.session])
    #expect(proved.awaitingHostInventories.isEmpty)
}

@Test func codexCandidatesComeFromThePIDListing() {
    let list = """
      101 /bin/zsh -l
      202 /opt/homebrew/bin/codex --model gpt-5
      303 /Applications/ChatGPT.app/Contents/Resources/codex app-server
      404 /Users/me/My Tools/codex
    505 node /usr/local/lib/node_modules/@openai/codex/bin/codex.js
    """
    // Loose by command line, so a path with spaces is not missed; the ancestry walk confirms each.
    #expect(CodexCLIProcesses.candidatePIDs(processList: list) == [202, 404, 505])
    let arguments = CodexCLIProcesses.arguments(processList: list)
    #expect(arguments.split(separator: "\n").first == "/bin/zsh -l")
    #expect(CodexCLIProcesses.isRunning(processList: arguments))
    #expect(!CodexCLIProcesses.isRunning(processList: CodexCLIProcesses.arguments(processList: "  1 /sbin/launchd\n")))
}

// Issue #285: a direct (`source: cli`, `--no-daemon`) session killed with its tab writes no
// SessionEnd. It ends once the host that last showed its title reads without it, or once Ghostty,
// which proved it, no longer shows it. Otherwise it still ends only by its own hook.

private func directSession(_ fixture: DaemonSessionFixture) throws {
    let rollout = try FileManager.default.contentsOfDirectory(at: fixture.rollouts, includingPropertiesForKeys: nil)[0]
    let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(fixture.session)\",\"source\":\"cli\",\"originator\":\"codex-tui\"}}\n"
    try header.write(to: rollout, atomically: true, encoding: .utf8)
}

@Test(arguments: TerminalHostTitles.hosts)
func aDirectSessionWhoseLastHostNoLongerShowsItEnds(host: TerminalHost) throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    try directSession(fixture)
    let closed = fixture.scan(otherHosts: [host: .known(["zsh"], takenAt: fixture.later + 3)], lastSeenHosts: [fixture.session: host])
    #expect(closed.endedSessions == [fixture.session])
    #expect(closed.sessionEnds[fixture.session] == fixture.later + 3)
    // A tab cannot move between apps: another host unread or unseen changes nothing.
    let others = TerminalHostTitles.hosts.filter { $0 != host }
    var readings: [TerminalHost: TerminalHostTitles] = [host: .known(["zsh"], takenAt: fixture.later)]
    readings[others[0]] = .unknown(takenAt: 0)
    readings[others[1]] = .unseen
    let unread = fixture.scan(otherHosts: readings, lastSeenHosts: [fixture.session: host])
    #expect(unread.endedSessions == [fixture.session])
}

@Test func aDirectSessionIsNotEndedWithoutEvidenceItsTabClosed() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    try directSession(fixture)
    let empty = TerminalHostTitles.known(["zsh"], takenAt: fixture.later)
    // Never seen in a host: its app is unknown, so it ends only by its own hook.
    #expect(fixture.scan(otherHosts: [.wezTerm: empty]).endedSessions.isEmpty)
    // Still shown.
    let shown = fixture.scan(otherHosts: [.wezTerm: .known([fixture.title], takenAt: fixture.later)],
                             lastSeenHosts: [fixture.session: .wezTerm])
    #expect(shown.endedSessions.isEmpty && shown.cliState.liveSessions == [fixture.session])
    // Its last host unread, switched off (no reading) or not running.
    for reading: TerminalHostTitles? in [.unknown(takenAt: fixture.later), nil, .notRunning(takenAt: fixture.later)] {
        let others: [TerminalHost: TerminalHostTitles] = reading.map { [.wezTerm: $0] } ?? [:]
        #expect(fixture.scan(otherHosts: others, lastSeenHosts: [fixture.session: .wezTerm]).endedSessions.isEmpty,
                Comment(rawValue: "\(String(describing: reading))"))
    }
    // herdr's titles unknown: a pane may still show it.
    let herdrUnknown = ReminderReader.scan(events: fixture.events, rollouts: fixture.rollouts,
                                           ghostty: GhosttyInventory(titles: ["zsh"], takenAt: fixture.later),
                                           herdrTitles: .unknown, otherHosts: [.wezTerm: empty],
                                           lastSeenHosts: [fixture.session: .wezTerm])
    #expect(herdrUnknown.endedSessions.isEmpty)
}

@Test func aDirectSessionProvedByGhosttyEndsWhenItsTabCloses() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    try directSession(fixture)
    let closed = fixture.scan(otherHosts: [:], knownCLISessions: [fixture.session])
    #expect(closed.endedSessions == [fixture.session])
    // Ghostty unreadable or not running: no inventory, no end.
    let unread = ReminderReader.scan(events: fixture.events, rollouts: fixture.rollouts, ghostty: nil,
                                     knownCLISessions: [fixture.session], otherHosts: [:])
    #expect(unread.endedSessions.isEmpty)
}
