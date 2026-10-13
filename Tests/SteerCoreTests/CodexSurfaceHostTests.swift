import Foundation
import Testing
@testable import SteerCore

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
        root = FileManager.default.temporaryDirectory.appendingPathComponent("steer-surface-\(UUID().uuidString)")
        events = root.appendingPathComponent("events")
        rollouts = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollouts, withIntermediateDirectories: true)
        let startedAt = "2026-10-13T09:00:00Z"
        started = RolloutTimestamp.parse(startedAt)!
        let hook = "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"\(session)\",\"received_at\":\"\(startedAt)\"}"
        try hook.write(to: events.appendingPathComponent("\(UUID().uuidString).json"), atomically: true, encoding: .utf8)
        let rollout = rollouts.appendingPathComponent("rollout-2026-10-13T09-00-00-\(session.uuidString.lowercased()).jsonl")
        let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"vscode\",\"originator\":\"steer\"}}\n"
        try header.write(to: rollout, atomically: true, encoding: .utf8)
    }

    var title: String { GhosttyMatch.title(session) }
    /// Well past the grace.
    var later: Double { started + 100 }

    /// A Ghostty inventory without the session's title, as when it runs in another host.
    func scan(otherHosts: [TerminalHost: TerminalHostTitles], ghosttyAt: Double? = nil,
              knownCLISessions: Set<UUID> = []) -> ReminderScan {
        ReminderReader.scan(events: events, rollouts: rollouts,
                            ghostty: GhosttyInventory(titles: ["zsh"], takenAt: ghosttyAt ?? later),
                            knownCLISessions: knownCLISessions, daemonThreads: [session], otherHosts: otherHosts)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test(arguments: [TerminalHost.iTerm2, .terminalApp, .wezTerm, .tmux, .zellij])
func aDaemonSessionShownInASwitchedOnHostIsNotEnded(host: TerminalHost) throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    let scan = fixture.scan(otherHosts: [host: .known(["zsh", fixture.title], takenAt: fixture.later)])
    #expect(scan.cliSessions == [fixture.session])
    #expect(scan.cliState.liveSessions == [fixture.session])
    #expect(scan.endedSessions.isEmpty && scan.sessionEnds.isEmpty)
    // Its tab is that host's, not Ghostty's.
    #expect(scan.titledCLISessions.isEmpty)
}

@Test(arguments: [TerminalHost.iTerm2, .terminalApp, .wezTerm, .tmux, .zellij])
func aDaemonSessionWhoseTabClosedInASwitchedOnHostEnds(host: TerminalHost) throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    let scan = fixture.scan(otherHosts: [host: .known(["zsh"], takenAt: fixture.later)])
    #expect(scan.endedSessions == [fixture.session])
    #expect(scan.sessionEnds[fixture.session] == fixture.later)
    // Another session's title does not stand in for this one.
    let other = fixture.scan(otherHosts: [host: .known([GhosttyMatch.title(UUID())], takenAt: fixture.later)])
    #expect(other.endedSessions == [fixture.session])
}

@Test func noDaemonSessionEndsWhileASwitchedOnHostsTitlesAreUnknown() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    let known = TerminalHostTitles.known(["zsh"], takenAt: fixture.later)
    // Not yet scanned or unreadable: a tab there may show the title.
    let unknown = fixture.scan(otherHosts: [.iTerm2: .unknown, .wezTerm: known])
    #expect(unknown.cliState.liveSessions == [fixture.session])
    #expect(unknown.endedSessions.isEmpty && unknown.sessionEnds.isEmpty)
    // An inventory taken before the grace ran out may predate the tab: not evidence of absence.
    let stale = fixture.scan(otherHosts: [.iTerm2: .known(["zsh"], takenAt: fixture.started + ReminderReader.surfaceGrace - 1)])
    #expect(stale.cliState.liveSessions == [fixture.session] && stale.endedSessions.isEmpty)
    let fresh = fixture.scan(otherHosts: [.iTerm2: .known(["zsh"], takenAt: fixture.started + ReminderReader.surfaceGrace)])
    #expect(fresh.endedSessions == [fixture.session])
    // A session Ghostty proved earlier is not ended for a missing tab while another host is unknown.
    let proved = fixture.scan(otherHosts: [.tmux: .unknown], knownCLISessions: [fixture.session])
    #expect(proved.cliState.liveSessions == [fixture.session] && proved.endedSessions.isEmpty)
}

@Test func aDaemonSessionIsNotEndedWhileASwitchedOffHostMayHoldIt() throws {
    let fixture = try DaemonSessionFixture()
    defer { fixture.remove() }
    // product.md: a Codex session in a switched-off app "cannot have its app identified"; Open says
    // "Steer can't tell which terminal this session is in.", never "This session has ended." (H8).
    for host in TerminalHostTitles.hosts {
        let unseen = fixture.scan(otherHosts: [host: .unseen])
        #expect(unseen.cliState.liveSessions == [fixture.session], Comment(rawValue: host.rawValue))
        #expect(unseen.endedSessions.isEmpty && unseen.sessionEnds.isEmpty)
    }
    // A Ghostty tab that showed the title and then closed still ends it: that session was in Ghostty.
    let closed = fixture.scan(otherHosts: [.iTerm2: .unseen, .tmux: .unseen], knownCLISessions: [fixture.session])
    #expect(closed.endedSessions == [fixture.session] && closed.sessionEnds[fixture.session] == fixture.later)
    // No other host in play: the existing Ghostty rule ends it.
    #expect(fixture.scan(otherHosts: [:]).endedSessions == [fixture.session])
}

@Test func theScanReadsEachContactableHostsLatestTitlesAndMarksOffHostsInUseUnseen() {
    let iTerm2 = TerminalHostTitles.known(["a"], takenAt: 5)
    var switches = TerminalHostSwitches(enabled: [.ghostty, .iTerm2, .tmux, .wezTerm])
    // iTerm2 running and read; tmux running but never read: unknown. WezTerm on but not running:
    // it holds no tab as of now. Terminal.app off but running: unseen. Zellij off and not running:
    // absent, so it holds nothing, whatever an old reading said.
    let titles = TerminalHostTitles.forScan(switches: switches, latest: [.iTerm2: iTerm2, .zellij: .known(["z"], takenAt: 1)],
                                            running: [.iTerm2, .tmux, .terminalApp], now: 50)
    #expect(titles == [.iTerm2: iTerm2, .tmux: .unknown, .wezTerm: .known([], takenAt: 50), .terminalApp: .unseen])
    // A multiplexer on with no terminal on cannot be contacted: treated as off.
    switches = TerminalHostSwitches(enabled: [.tmux])
    #expect(TerminalHostTitles.forScan(switches: switches, latest: [.tmux: .known([], takenAt: 1)], running: [.tmux], now: 50)
            == [.tmux: .unseen])
    #expect(TerminalHostTitles.forScan(switches: switches, latest: [:], running: [], now: 50) == [:])
}

@Test func anInventoryBecomesTitlesStampedWithItsReadTime() {
    let tab = TerminalTab(tabID: "1", tty: "/dev/ttys001", title: "codex title", paneCount: 1)
    let untitled = TerminalTab(tabID: "2", tty: "/dev/ttys002", title: nil, paneCount: 1)
    #expect(TerminalHostTitles(inventory: .tabs([tab, untitled]), takenAt: 7) == .known(["codex title"], takenAt: 7))
    #expect(TerminalHostTitles(inventory: .notRunning, takenAt: 7) == .known([], takenAt: 7))
    #expect(TerminalHostTitles(inventory: .unreadable, takenAt: 7) == .unknown)
}

@Test func aMultiplexerIsInUseWhenItsProcessRunsOrTheListIsUnreadable() {
    let list = """
    /bin/zsh -l
    tmux new-session -s work
    /opt/homebrew/bin/codex
    """
    #expect(TerminalHostTitles.multiplexersRunning(processList: list) == [.tmux])
    #expect(TerminalHostTitles.multiplexersRunning(processList: "/opt/homebrew/bin/zellij attach main\n") == [.zellij])
    // A path or argument that merely mentions one is not that process.
    #expect(TerminalHostTitles.multiplexersRunning(processList: "vim tmux.conf\n/usr/bin/less /tmp/zellij.log\n").isEmpty)
    // ps failed: either may be running.
    #expect(TerminalHostTitles.multiplexersRunning(processList: nil) == [.tmux, .zellij])
}
