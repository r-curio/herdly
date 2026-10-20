import Foundation
import Testing
@testable import HerdlyCore

// product.md, Notch, "Open unavailable" (#267): the scan-time cause that replaces a terminal card's Open
// with one reason line, derived from the same binding, plan and ADR 0015 rules a click rechecks. Every
// inventory, `ps` read and process walk here is a fixture; no host is contacted.

private let session = UUID(uuidString: "019A7C1E-5B2D-7F30-9C11-2F4E8A6B0001")!
private let title = "019a7c1e-5b2d-7f30-9c11-2f4e8..."
private let codexTTY = "/dev/ttys012"
private let codexPID: Int32 = 902
private let codexPS = """
  901 Ss     login
  902 S+     codex
"""

private func tab(_ id: String, tty: String? = codexTTY, title: String? = title, panes: Int = 1) -> TerminalTab {
    TerminalTab(tabID: id, tty: tty, title: title, paneCount: panes)
}

private func reads(_ hosts: Set<TerminalHost>, _ inventories: [TerminalHost: TerminalHostInventory],
                   processes: [String: [TerminalProcess]] = [codexTTY: TerminalForegroundProcesses.parse(codexPS)!],
                   ghosttyOn: Bool = false, ghostty: GhosttySnapshot? = nil, ghosttyRunning: Bool = false,
                   tmux: TmuxRead = .notRunning, zellij: ZellijRead = .notRunning) -> TerminalOpenScanReads {
    TerminalOpenScanReads(switches: TerminalHostSwitches(enabled: hosts), ghosttyOn: ghosttyOn,
                          inventories: inventories, processes: processes, secondRead: inventories,
                          tmux: tmux, zellij: zellij, ghostty: ghostty, ghosttyRunning: ghosttyRunning)
}

/// The scan's availability for the Codex session, with each walked process reaching `walks[pid]`.
private func codex(_ reads: TerminalOpenScanReads, live: Set<UUID> = [session],
                   walks: [Int32: TerminalAppWalk] = [codexPID: .reached(.iTerm2)],
                   ttyWrittenAt: [String: Double] = [:],
                   running: Set<TerminalHost> = Set(TerminalHost.terminals)) -> TerminalOpenAvailability {
    TerminalOpenScan.codex(session: session, liveSessions: live, reads: reads)
        .availability(agent: .codex, switches: reads.switches, walks: walks, ttyWrittenAt: ttyWrittenAt,
                      isRunning: { running.contains($0) })
}

// MARK: - iTerm2

@Test func iTerm2BoundTabOffersOpenWithNoLine() {
    let availability = codex(reads([.iTerm2], [.iTerm2: .tabs([tab("A1")])]))
    #expect(availability == .offered)
    #expect(availability.cardLine == nil)
}

@Test func iTerm2UnreadableReplacesOpenWithItsSettingsLine() {
    // Automation denied, a scripting error: the host cannot be ruled out, so Open is unavailable.
    let availability = codex(reads([.iTerm2], [.iTerm2: .unreadable]))
    #expect(availability == .unavailable(.hostUnreadable(.iTerm2)))
    #expect(availability.cardLine == "Herdly can't read iTerm2. Check Settings › Terminals.")
}

@Test func iTerm2SessionThatEndedSaysSo() {
    // Codex no longer lists the session as live: its tab may still show the title.
    let availability = codex(reads([.iTerm2], [.iTerm2: .tabs([tab("A1")])]), live: [])
    #expect(availability.cardLine == "This session has ended.")
}

private let decoyTTY = "/dev/ttys013"
private let decoyPS = TerminalForegroundProcesses.parse("  903 S+     sleep\n")!
private let realAndDecoyPS = [codexTTY: TerminalForegroundProcesses.parse(codexPS)!, decoyTTY: decoyPS]

@Test func iTerm2DecoyCarryingTheTitleLeavesTheRealTabReachable() {
    // The live #243 run: a decoy tab printed the Codex title. It runs no `codex`, so it is no candidate
    // (ADR 0013's 2026-10-13 amendment, #268) and the real tab is the exact target.
    let scanReads = reads([.iTerm2], [.iTerm2: .tabs([tab("A3", tty: decoyTTY), tab("A1")])], processes: realAndDecoyPS)
    #expect(TerminalOpenScan.codex(session: session, liveSessions: [session], reads: scanReads) == .reachable)
    #expect(codex(scanReads) == .offered)
    // Two tabs that both run `codex` still bind neither; both walks name iTerm2, so the fallback is offered.
    let twoReal = reads([.iTerm2], [.iTerm2: .tabs([tab("A1"), tab("A2", tty: decoyTTY)])],
                        processes: [codexTTY: TerminalForegroundProcesses.parse(codexPS)!,
                                    decoyTTY: TerminalForegroundProcesses.parse("  904 S+     codex\n")!])
    #expect(codex(twoReal, walks: [codexPID: .reached(.iTerm2), 904: .reached(.iTerm2)]) == .offered)
    guard case .miss(.fallBack(.noUniqueTarget, candidates: 2), _) =
            TerminalOpenScan.codex(session: session, liveSessions: [session], reads: twoReal) else {
        Issue.record("two real tabs must stay unbound")
        return
    }
}

@Test func aDecoyAloneOrAnUnreadableDecoyNeverOffersAnExactOpen() {
    // The real tab is gone: the decoy is no candidate, and nothing names the app.
    let alone = reads([.iTerm2], [.iTerm2: .tabs([tab("A3", tty: decoyTTY)])], processes: [decoyTTY: decoyPS])
    #expect(codex(alone).cardLine == "Herdly can't tell which terminal this session is in.")
    // `ps` failed for the second titled tab: it is never taken for a decoy, so Open fails closed.
    let unreadable = reads([.iTerm2], [.iTerm2: .tabs([tab("A3", tty: decoyTTY), tab("A1")])])
    #expect(codex(unreadable).cardLine == "Herdly can't tell which terminal this session is in.")
}

@Test func aDecoyInAnotherHostLeavesTheSessionToTheHostThatHoldsIt() {
    // Terminal.app carries a decoy while iTerm2 holds the real tab: Terminal.app's route does not keep it.
    let inventories: [TerminalHost: TerminalHostInventory] = [
        .terminalApp: .tabs([tab("9882", tty: decoyTTY)]), .iTerm2: .tabs([tab("A1")]),
    ]
    let scanReads = reads([.iTerm2, .terminalApp], inventories, processes: realAndDecoyPS)
    #expect(TerminalOpenScan.codex(session: session, liveSessions: [session], reads: scanReads) == .reachable)
    let binding = TerminalTabBindingRules.codex(sessionID: session.uuidString, liveness: .live,
                                                liveSessions: [session.uuidString], switches: scanReads.switches,
                                                inventories: inventories, processes: realAndDecoyPS, secondRead: inventories)
    #expect(!TerminalTabOpen.codexStays(in: .terminalApp, carriesTitle: true, binding: binding))
    #expect(TerminalTabOpen.codexStays(in: .iTerm2, carriesTitle: true, binding: binding))
    // A host keeps a session it carries that is bound nowhere: its own Open reports the miss.
    #expect(TerminalTabOpen.codexStays(in: .wezTerm, carriesTitle: true, binding: .unavailable(.duplicateTitles(2))))
    #expect(!TerminalTabOpen.codexStays(in: .wezTerm, carriesTitle: false, binding: .unavailable(.titleNotFound)))
}

@Test func iTerm2SplitTabIsASilentFallback() {
    // ADR 0015: a split falls back to raising iTerm2, which looks like any other Open.
    let availability = codex(reads([.iTerm2], [.iTerm2: .tabs([tab("A1", panes: 2)])]))
    #expect(availability == .offered)
    #expect(availability.cardLine == nil)
}

@Test func iTerm2FallbackWhoseAppIsNotRunningSaysSo() {
    // The walk names iTerm2 but macOS no longer lists it: Herdly never launches an app.
    let availability = codex(reads([.iTerm2], [.iTerm2: .tabs([tab("A1", panes: 2)])]), running: [])
    #expect(availability.cardLine == "iTerm2 isn't running.")
}

@Test func aSessionWhoseLastAppQuitSaysThatAppIsNotRunning() {
    // H7: iTerm2 quit while Codex's daemon keeps the session live. No tab carries the title any more,
    // but iTerm2's inventory showed it last.
    func availability(_ hosts: Set<TerminalHost>, lastSeen: TerminalHost?, running: Set<TerminalHost>) -> TerminalOpenAvailability {
        let scanReads = reads(hosts, [.iTerm2: .notRunning, .terminalApp: .tabs([])])
        return TerminalOpenScan.codex(session: session, liveSessions: [session], reads: scanReads, lastSeenHost: lastSeen)
            .availability(agent: .codex, switches: scanReads.switches, walks: [:], ttyWrittenAt: [:],
                          isRunning: { running.contains($0) })
    }
    #expect(availability([.iTerm2], lastSeen: .iTerm2, running: []).cardLine == "iTerm2 isn't running.")
    // Running again with no tab carrying the title: nothing names the app.
    #expect(availability([.iTerm2], lastSeen: .iTerm2, running: [.iTerm2]).cardLine
            == "Herdly can't tell which terminal this session is in.")
    // H8: a switched-off app is never named for a Codex session.
    #expect(availability([.terminalApp], lastSeen: .iTerm2, running: []).cardLine
            == "Herdly can't tell which terminal this session is in.")
    #expect(availability([.iTerm2], lastSeen: nil, running: []).cardLine
            == "Herdly can't tell which terminal this session is in.")
}

@Test func theSharedReadAssemblyReadsPsForAnITerm2TabSoItsCodexIsOffered() {
    // Review round 1 (B1): the scan's reads must `ps` the iTerm2 tab carrying the title, as the click's do,
    // or a bound tab reads `processesUnreadable` and loses Open.
    var hostReads = 0
    var asked: Set<String> = []
    let assembled = TerminalTabReadAssembly<Void>.take(
        codexTitles: [title], claudeTTYs: [],
        readHosts: {
            hostReads += 1
            return ([.iTerm2: .tabs([tab("A1"), tab("A2", tty: "/dev/ttys040", title: "zsh")])], ())
        },
        readProcesses: { ttys in
            asked = ttys
            return Dictionary(uniqueKeysWithValues: ttys.map { ($0, TerminalForegroundProcesses.parse(codexPS)!) })
        })
    #expect(hostReads == 2)
    #expect(asked == [codexTTY])
    let scanReads = TerminalOpenScanReads(switches: TerminalHostSwitches(enabled: [.iTerm2]), ghosttyOn: false,
                                          inventories: assembled.inventories, processes: assembled.processes,
                                          secondRead: assembled.secondRead)
    #expect(codex(scanReads) == .offered)
    // Without the `ps` read the same tab could not be bound or identified.
    var unread = scanReads
    unread.processes = [:]
    #expect(codex(unread).cardLine == "Herdly can't tell which terminal this session is in.")
}

@Test func theSharedReadAssemblyReadsEveryTTYListingHostAndClaudeTTYs() {
    let inventories: [TerminalHost: TerminalHostInventory] = [
        .terminalApp: .tabs([tab("9882", tty: "/dev/ttys001")]),
        .wezTerm: .tabs([tab("8", tty: "/dev/ttys002"), tab("9", tty: "/dev/ttys003", title: "claude")]),
        .tmux: .tabs([tab("%0", tty: "/dev/ttys004")]),
        .ghostty: .tabs([tab("g", tty: nil)]),
        .zellij: .tabs([tab("lab/terminal_1", tty: nil)]),
    ]
    #expect(TerminalTabReadAssembly<Void>.ttysToRead(inventories, codexTitles: [title], claudeTTYs: ["ttys003"])
            == ["/dev/ttys001", "/dev/ttys002", "/dev/ttys003", "/dev/ttys004"])
    // Without the live titles (Terminal.app's and the multiplexers' reads), every tab of every tty-listing
    // host showing any shortened Codex identifier is read, the iTerm2 decoy's too (#268).
    var withITerm2 = inventories
    withITerm2[.iTerm2] = .tabs([tab("A3", tty: "/dev/ttys005", title: "9f3c2b10-1111-4222-8333-44445..."),
                                 tab("A4", tty: "/dev/ttys006", title: "zsh")])
    #expect(TerminalTabReadAssembly<Void>.ttysToRead(withITerm2, claudeTTYs: ["ttys003"])
            == ["/dev/ttys001", "/dev/ttys002", "/dev/ttys003", "/dev/ttys004", "/dev/ttys005"])
}

// MARK: - Terminal.app

@Test func terminalAppCausesEachReplaceOpenWithTheirLine() {
    let bound = reads([.terminalApp], [.terminalApp: .tabs([tab("9882")])])
    #expect(codex(bound) == .offered)
    #expect(codex(reads([.terminalApp], [.terminalApp: .unreadable])).cardLine
            == "Herdly can't read Terminal.app. Check Settings › Terminals.")
    #expect(codex(bound, live: []).cardLine == "This session has ended.")
    let split = reads([.terminalApp], [.terminalApp: .tabs([tab("9882", panes: 2)])])
    #expect(codex(split, walks: [codexPID: .reached(.terminalApp)]) == .offered)
    #expect(codex(split, walks: [codexPID: .reached(.terminalApp)], running: []).cardLine == "Terminal.app isn't running.")
    // No tab carries the title: no app to raise.
    #expect(codex(reads([.terminalApp], [.terminalApp: .tabs([])])).cardLine
            == "Herdly can't tell which terminal this session is in.")
}

// MARK: - WezTerm

@Test func wezTermCausesEachReplaceOpenWithTheirLine() {
    let bound = reads([.wezTerm], [.wezTerm: .tabs([tab("8")])])
    #expect(codex(bound) == .offered)
    #expect(codex(reads([.wezTerm], [.wezTerm: .unreadable])).cardLine
            == "Herdly can't read WezTerm. Check Settings › Terminals.")
    #expect(codex(bound, live: []).cardLine == "This session has ended.")
    let split = reads([.wezTerm], [.wezTerm: .tabs([tab("8", panes: 2)])])
    #expect(codex(split, walks: [codexPID: .reached(.wezTerm)]) == .offered)
    #expect(codex(split, walks: [codexPID: .reached(.wezTerm)], running: [.iTerm2]).cardLine == "WezTerm isn't running.")
    // The walk ends in an app Herdly does not support.
    #expect(codex(split, walks: [codexPID: .unsupportedApp]).cardLine
            == "Herdly can't tell which terminal this session is in.")
}

@Test func anUnreadableHostBesideTheBoundOneStillBlocksOpen() {
    // ADR 0013: an enabled host that cannot be read could hold the real tab.
    let availability = codex(reads([.iTerm2, .wezTerm], [.iTerm2: .unreadable, .wezTerm: .tabs([tab("8")])]))
    #expect(availability.cardLine == "Herdly can't read iTerm2. Check Settings › Terminals.")
}

// MARK: - Ghostty (title route, ADR 0005)

private func ghosttySnapshot(_ titles: [[String]], status: String = "ok") throws -> GhosttySnapshot {
    let object: [String: Any] = [
        "status": status, "front_window_id": "w1",
        "windows": [["id": "w1", "tabs": titles.enumerated().map { t, names in
            ["id": "t\(t)", "terminals": names.enumerated().map { n, name in ["id": "t\(t)n\(n)", "name": name] }]
        }]],
    ]
    return try JSONDecoder().decode(GhosttySnapshot.self, from: JSONSerialization.data(withJSONObject: object))
}

private func ghosttyOnly(_ snapshot: GhosttySnapshot?, running: Bool = true) -> TerminalOpenScanReads {
    reads([.ghostty], [:], ghosttyOn: true, ghostty: snapshot, ghosttyRunning: running)
}

@Test func ghosttyTitleRouteKeepsItsAgreedBehaviour() throws {
    #expect(codex(ghosttyOnly(try ghosttySnapshot([["zsh"], [title]]))) == .offered)
    // Two tabs carrying the title, or a split: a fallback raising Ghostty, with no line.
    #expect(codex(ghosttyOnly(try ghosttySnapshot([[title], [title]]))) == .offered)
    #expect(codex(ghosttyOnly(try ghosttySnapshot([[title, "zsh"]]))) == .offered)
    #expect(codex(ghosttyOnly(try ghosttySnapshot([[title]])), live: []).cardLine == "This session has ended.")
    #expect(codex(ghosttyOnly(try ghosttySnapshot([], status: "error"))).cardLine
            == "Herdly can't read Ghostty. Check Settings › Terminals.")
    #expect(codex(ghosttyOnly(try ghosttySnapshot([["zsh"]]))).cardLine == "Herdly can't tell which terminal this session is in.")
    #expect(codex(ghosttyOnly(nil, running: false)).cardLine == "Herdly can't tell which terminal this session is in.")
    #expect(codex(ghosttyOnly(try ghosttySnapshot([[title], [title]])), running: []).cardLine == "Ghostty isn't running.")
}

// MARK: - tmux (ADR 0014)

private let paneTTY = "/dev/ttys017"
private let clientTTY = "/dev/ttys022"
private let clientPID: Int32 = 45245

private func tmuxSnapshot(clients: String = "\(clientTTY)|\(clientPID)|$0|%0|0\n") throws -> TmuxSnapshot {
    let parsed = try #require(TmuxSnapshot.parse(panes: "%0|\(paneTTY)|@0|1|$0|1|0|0|0|0|\(title)\n", clients: clients))
    return parsed.withClientAncestries(Dictionary(uniqueKeysWithValues: parsed.clients.map {
        ($0.pid, ["tmux", "zsh", "login", "iTerm2"])
    }))
}

/// tmux on beside iTerm2, whose one tab runs tmux's client.
private func tmuxReads(_ tmux: TmuxRead, iTerm2: TerminalHostInventory? = nil) -> TerminalOpenScanReads {
    var inventories: [TerminalHost: TerminalHostInventory] = [.iTerm2: iTerm2 ?? .tabs([tab("A1", tty: clientTTY, title: "tmux")])]
    inventories[.tmux] = tmux.inventory
    var result = reads([.iTerm2, .tmux], inventories, processes: [paneTTY: TerminalForegroundProcesses.parse(codexPS)!], tmux: tmux)
    result.multiplexerClientTTYs = tmux.snapshot?.clientTTYs ?? []
    return result
}

@Test func tmuxCausesEachReplaceOpenWithTheirLine() throws {
    let snapshot = try tmuxSnapshot()
    #expect(codex(tmuxReads(.snapshot(snapshot))) == .offered)
    for unreadable: TmuxRead in [.unreadable, .untrustedSocket, .binaryNotFound] {
        #expect(codex(tmuxReads(unreadable)).cardLine == "Herdly can't read tmux. Check Settings › Terminals.")
    }
    #expect(codex(tmuxReads(.snapshot(snapshot)), live: []).cardLine == "This session has ended.")
    // A detached session has no client to name its app.
    #expect(codex(tmuxReads(.snapshot(try tmuxSnapshot(clients: "")))).cardLine
            == "Herdly can't tell which terminal this session is in.")
    // The client's tab is in no enabled host: the fallback walks the client to iTerm2, which must run.
    let elsewhere = tmuxReads(.snapshot(snapshot), iTerm2: .tabs([]))
    #expect(codex(elsewhere, walks: [clientPID: .reached(.iTerm2)]) == .offered)
    #expect(codex(elsewhere, walks: [clientPID: .reached(.iTerm2)], running: []).cardLine == "iTerm2 isn't running.")
    // The client's host app cannot be read: no host tab can be trusted.
    #expect(codex(tmuxReads(.snapshot(snapshot), iTerm2: .unreadable)).cardLine
            == "Herdly can't read iTerm2. Check Settings › Terminals.")
}

@Test func tmuxNotHoldingTheTitleLeavesTheSessionToTheOtherRoutes() throws {
    let empty = try #require(TmuxSnapshot.parse(panes: "", clients: ""))
    var inventories: [TerminalHost: TerminalHostInventory] = [.iTerm2: .tabs([tab("A1")]), .tmux: empty.inventory]
    #expect(codex(reads([.iTerm2, .tmux], inventories, tmux: .snapshot(empty))) == .offered)
    inventories[.tmux] = .notRunning
    #expect(codex(reads([.iTerm2, .tmux], inventories, tmux: .notRunning)) == .offered)
}

@Test func aTmuxDecoyPaneLeavesTheSessionToTheTabThatRunsCodex() throws {
    // A tmux pane prints the title but runs no `codex`; the real tab is in iTerm2 (#268).
    let snapshot = try tmuxSnapshot()
    let inventories: [TerminalHost: TerminalHostInventory] = [
        .iTerm2: .tabs([tab("A1"), tab("A2", tty: clientTTY, title: "tmux")]), .tmux: snapshot.inventory,
    ]
    var scanReads = reads([.iTerm2, .tmux], inventories,
                          processes: [codexTTY: TerminalForegroundProcesses.parse(codexPS)!, paneTTY: decoyPS],
                          tmux: .snapshot(snapshot))
    scanReads.multiplexerClientTTYs = snapshot.clientTTYs
    #expect(TerminalOpenScan.codex(session: session, liveSessions: [session], reads: scanReads) == .reachable)
}

@Test func aDecoyBesideATTYLessGhosttyTabLeavesTheSessionToGhosttysTitleRoute() throws {
    // Review of #268: the real Codex is in a Ghostty tab without `tty`, so the binding reads
    // `ttyUnknown(.ghostty)`. A tmux decoy pane must not keep the session and fall back through its clients.
    let snapshot = try tmuxSnapshot()
    let ghostty = try ghosttySnapshot([[title]])
    let inventories: [TerminalHost: TerminalHostInventory] = [
        .ghostty: .ghosttyTitles(ghostty, running: true), .tmux: snapshot.inventory,
        .terminalApp: .tabs([tab("9882", tty: clientTTY, title: "tmux")]),
    ]
    var scanReads = reads([.ghostty, .tmux, .terminalApp], inventories, processes: [paneTTY: decoyPS], ghosttyOn: true,
                          ghostty: ghostty, ghosttyRunning: true, tmux: .snapshot(snapshot))
    scanReads.multiplexerClientTTYs = snapshot.clientTTYs
    #expect(TerminalOpenScan.codex(session: session, liveSessions: [session], reads: scanReads) == .reachable)
    // Each host's click asks the same question: only Ghostty keeps a session its tty-less tab holds.
    let binding = TerminalTabBinding.unavailable(.ttyUnknown(.ghostty))
    for host in [TerminalHost.tmux, .terminalApp, .wezTerm, .iTerm2] {
        #expect(!TerminalTabOpen.codexStays(in: host, carriesTitle: true, binding: binding), "\(host)")
    }
    #expect(TerminalTabOpen.codexStays(in: .ghostty, carriesTitle: true, binding: binding))
    // A Zellij pane holding the only candidate is Zellij's, whatever another host's decoy shows.
    #expect(!TerminalTabOpen.codexStays(in: .tmux, carriesTitle: true, binding: .unavailable(.ttyUnknown(.zellij))))
}

// MARK: - Zellij (ADR 0014)

private func zellijSnapshot() throws -> ZellijSnapshot {
    let pane = """
    [{"id": 1, "is_plugin": false, "is_focused": false, "is_fullscreen": false, "is_floating": false,
      "is_suppressed": false, "title": "\(title)", "exited": false, "exit_status": null, "is_held": false,
      "terminal_command": null, "plugin_url": null, "is_selectable": true, "tab_id": 1, "tab_position": 1,
      "tab_name": "Tab #1", "pane_command": "codex", "pane_cwd": "/Users/me"}]
    """
    let tabs = """
    [{"position": 1, "name": "Tab #1", "active": false, "panes_to_hide": 0, "is_fullscreen_active": false,
      "is_sync_panes_active": false, "are_floating_panes_visible": false, "other_focused_clients": [],
      "selectable_tiled_panes_count": 1, "selectable_floating_panes_count": 0, "tab_id": 1,
      "has_bell_notification": false, "is_flashing_bell": false}]
    """
    let session = try #require(ZellijSession.parse(name: "lab", panes: pane, tabs: tabs,
                                                   clients: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1 terminal_1 N/A\n"))
    // One client in a terminal tab; no server is found, so the pane cannot be bound and Open falls back.
    let table = try #require(ZellijProcessTable.parse("49075 901 501 ttys017 /opt/homebrew/bin/zellij\n", owner: 501,
                                                       arguments: [49075: ["zellij", "--session", "lab"]], startTimes: [:]))
    return ZellijSnapshot(socketDirectory: "/tmp/zellij-501/contract_version_1", sessions: [session], processes: table)
}

private func zellijReads(_ zellij: ZellijRead) -> TerminalOpenScanReads {
    reads([.wezTerm, .zellij], [.wezTerm: .tabs([]), .zellij: zellij.inventory], processes: [:], zellij: zellij)
}

@Test func zellijCausesEachReplaceOpenWithTheirLine() throws {
    for unreadable: ZellijRead in [.untrustedSocket, .binaryNotFound] {
        #expect(codex(zellijReads(unreadable)).cardLine == "Herdly can't read Zellij. Check Settings › Terminals.")
    }
    let snapshot = try zellijSnapshot()
    #expect(codex(zellijReads(.snapshot(snapshot)), walks: [49075: .reached(.wezTerm)]) == .offered)
    #expect(codex(zellijReads(.snapshot(snapshot)), walks: [49075: .reached(.wezTerm)], running: []).cardLine
            == "WezTerm isn't running.")
    #expect(codex(zellijReads(.snapshot(snapshot)), walks: [49075: .failed]).cardLine
            == "Herdly can't tell which terminal this session is in.")
    #expect(codex(zellijReads(.snapshot(snapshot)), live: []).cardLine == "This session has ended.")
}

// MARK: - Claude Code

private let claudeID = "f119a3c3-7fdf-4bf9-ac69-60acf9ad8321"
private let claudePID: Int32 = 70412
private let claudeTTY = "/dev/ttys005"
private let claudePS = """
70410 Ss     login
70412 S+     claude
"""
private let registered = TerminalSessionProcess.registered(.init(pid: claudePID, procStart: "Mon Oct 12 09:00:00 2026"))
private let observedClaude = TerminalProcessObservation(pid: claudePID, procStart: "Mon Oct 12 09:00:00 2026", tty: "ttys005")

private func claude(_ reads: TerminalOpenScanReads, process: TerminalSessionProcess = registered,
                    observed: TerminalProcessObservation? = observedClaude,
                    walk: TerminalAppWalk = .reached(.terminalApp),
                    running: Set<TerminalHost> = Set(TerminalHost.terminals)) -> TerminalOpenAvailability {
    TerminalOpenScan.claude(sessionID: claudeID, process: process, observed: observed, newestRecords: [],
                            liveSessionIDs: [claudeID], reads: reads)
        .availability(agent: .claude, switches: reads.switches, walks: [claudePID: walk], ttyWrittenAt: [:],
                      isRunning: { running.contains($0) })
}

private func claudeReads(_ hosts: Set<TerminalHost>, _ inventories: [TerminalHost: TerminalHostInventory],
                         ghosttyOn: Bool = false, ghostty: GhosttySnapshot? = nil) -> TerminalOpenScanReads {
    reads(hosts, inventories, processes: [claudeTTY: TerminalForegroundProcesses.parse(claudePS)!],
          ghosttyOn: ghosttyOn, ghostty: ghostty, ghosttyRunning: ghostty != nil)
}

@Test func claudeCausesFollowItsOwnProcess() {
    let tabOnTTY = TerminalTab(tabID: "9882", tty: claudeTTY, title: nil, paneCount: 1)
    #expect(claude(claudeReads([.terminalApp], [.terminalApp: .tabs([tabOnTTY])])) == .offered)
    #expect(claude(claudeReads([.terminalApp], [.terminalApp: .unreadable])).cardLine
            == "Herdly can't read Terminal.app. Check Settings › Terminals.")
    #expect(claude(claudeReads([.iTerm2], [.iTerm2: .unreadable])).cardLine
            == "Herdly can't read iTerm2. Check Settings › Terminals.")
    // The registered process is gone: the session has ended.
    #expect(claude(claudeReads([.terminalApp], [.terminalApp: .tabs([tabOnTTY])]), observed: nil).cardLine
            == "This session has ended.")
    // Several registries hold the session: no one process names its app.
    #expect(claude(claudeReads([.terminalApp], [.terminalApp: .tabs([tabOnTTY])]), process: .ambiguous).cardLine
            == "Herdly can't tell which terminal this session is in.")
}

@Test func claudeInASwitchedOffOrUnsupportedAppFollowsItsWalk() throws {
    // Only Ghostty is on and its title route misses: the session's own process names its app, which
    // still falls back while it runs, switched on or not (ADR 0015).
    let ghostty = try ghosttySnapshot([["zsh"]])
    #expect(claude(claudeReads([.ghostty], [:], ghosttyOn: true, ghostty: ghostty), walk: .reached(.iTerm2)) == .offered)
    #expect(claude(claudeReads([.ghostty], [:], ghosttyOn: true, ghostty: ghostty), walk: .reached(.iTerm2), running: [])
            .cardLine == "iTerm2 isn't running.")
    #expect(claude(claudeReads([.ghostty], [:], ghosttyOn: true, ghostty: ghostty), walk: .unsupportedApp).cardLine
            == "Herdly can't tell which terminal this session is in.")
    // Its own Ghostty tab, by the full Claude title in the front window.
    let own = try ghosttySnapshot([["Herdly Claude \(claudeID)"]])
    #expect(claude(claudeReads([.ghostty], [:], ghosttyOn: true, ghostty: own), walk: .failed) == .offered)
}

// MARK: - herdr (its own presentation, unchanged)

@Test func herdrKeepsItsIntegrationLineAndFallbacks() {
    // A herdr session never takes this scan's route; its card keeps HerdrPresentation's line, including
    // the table's integration row, and its fallbacks stay silent (ADR 0015).
    let stale = HerdrUnavailableCause.session(.herdr(.integrationNotCurrent(.claude)))
    #expect(HerdrPresentation.cardLine(for: stale, agent: .claude)
            == "Run herdr integration install claude to return to herdr panes.")
    #expect(HerdrPresentation.openAvailability(binding: .unavailable(.binding(.split)), ttySupport: .supported) == .available)
    #expect(HerdrPresentation.unrelayedQuestionLine(openCause: stale).hasPrefix("Answer this in Codex. "))
}

// MARK: - Card lines (product.md, "Open unavailable" and "Typed input unavailable")

@Test func aCodexQuestionThatCannotBeTypedSharesOneLineWithOpensReason() {
    let reason = OpenUnavailableReason.hostUnreadable(.iTerm2)
    #expect(OpenUnavailableLines<String>.cardLine(reason, questionCannotBeTyped: false)
            == "Herdly can't read iTerm2. Check Settings › Terminals.")
    #expect(OpenUnavailableLines<String>.cardLine(reason, questionCannotBeTyped: true)
            == "Answer this in Codex. Herdly can't read iTerm2. Check Settings › Terminals.")
}

@Test func aScanLineReplacesOpenAndAFallbackShowsNone() {
    var lines = OpenUnavailableLines<String>()
    lines.applyScan(["a": .unavailable(.appNotRunning(.wezTerm)), "b": .offered], startedAt: 10)
    #expect(!lines.offersOpen("a"))
    #expect(lines.line(for: "a") == .appNotRunning(.wezTerm))
    #expect(lines.offersOpen("b"))
    #expect(lines.line(for: "b") == nil)
    // A later scan that offers Open drops the line.
    lines.applyScan(["a": .offered], startedAt: 20)
    #expect(lines.offersOpen("a"))
    #expect(lines.line(for: "a") == nil)
}

@Test func aClickTimeFailureShowsTheLineBesideOpenUntilTheNextScanSwapsIt() {
    var lines = OpenUnavailableLines<String>()
    lines.applyScan(["a": .offered], startedAt: 10)
    // The scan offered Open; the click's recheck found iTerm2 unreadable.
    lines.recordOpen(.unavailable(.hostUnreadable(.iTerm2)), for: "a", at: 12)
    #expect(lines.offersOpen("a"))
    #expect(lines.line(for: "a") == .hostUnreadable(.iTerm2))
    // A scan that started before the click says nothing about it.
    lines.applyScan(["a": .offered], startedAt: 11)
    #expect(lines.line(for: "a") == .hostUnreadable(.iTerm2))
    // The next scan agrees: Open is swapped for the line.
    lines.applyScan(["a": .unavailable(.hostUnreadable(.iTerm2))], startedAt: 13)
    #expect(!lines.offersOpen("a"))
    #expect(lines.line(for: "a") == .hostUnreadable(.iTerm2))
}

@Test func aClickTimeLineClearsOnAFreshScanThatOffersOpenOrAnOpenThatWorks() {
    var lines = OpenUnavailableLines<String>()
    lines.recordOpen(.unavailable(.activationFailed(.iTerm2)), for: "a", at: 5)
    lines.applyScan(["a": .offered], startedAt: 6)
    #expect(lines.line(for: "a") == nil)
    lines.recordOpen(.unavailable(.appNotRunning(.iTerm2)), for: "a", at: 7)
    lines.recordOpen(.fellBack(.iTerm2, .unsupportedLayout), for: "a", at: 8)
    #expect(lines.line(for: "a") == nil)
    lines.recordOpen(.unavailable(.appNotRunning(.iTerm2)), for: "a", at: 9)
    lines.recordOpen(.opened, for: "a", at: 10)
    #expect(lines.line(for: "a") == nil)
}

@Test func aScanStartedBeforeAnOpenThatWorkedIsIgnoredForThatSession() {
    // Review round 1 (S1): the Open reached the session after the scan began, so its stale cause is dropped.
    var lines = OpenUnavailableLines<String>()
    lines.recordOpen(.opened, for: "a", at: 10)
    lines.applyScan(["a": .unavailable(.hostUnreadable(.iTerm2)), "b": .unavailable(.sessionEnded)], startedAt: 9)
    #expect(lines.offersOpen("a"))
    #expect(lines.line(for: "a") == nil)
    #expect(lines.line(for: "b") == .sessionEnded)
    lines.recordOpen(.fellBack(.iTerm2, .unsupportedLayout), for: "a", at: 20)
    lines.applyScan(["a": .unavailable(.appNotRunning(.iTerm2))], startedAt: 19)
    #expect(lines.offersOpen("a"))
    // A scan that started after the Open decides again.
    lines.applyScan(["a": .unavailable(.appNotRunning(.iTerm2))], startedAt: 21)
    #expect(!lines.offersOpen("a"))
}

@Test func aCardTheScanNoLongerCoversDropsItsScanLineButKeepsItsClickLine() {
    // Review round 3: a Codex card later bound by herdr, or every terminal host switched off, leaves the
    // scan's targets while the card stays queued; its old scan line must not hide Open.
    var lines = OpenUnavailableLines<String>()
    lines.applyScan(["a": .unavailable(.hostUnreadable(.iTerm2)), "b": .unavailable(.sessionEnded)], startedAt: 1)
    lines.recordOpen(.unavailable(.appNotIdentified), for: "c", at: 2)
    lines.retainScanned(["b"])
    #expect(lines.offersOpen("a"))
    #expect(lines.line(for: "a") == nil)
    #expect(lines.line(for: "b") == .sessionEnded)
    #expect(lines.line(for: "c") == .appNotIdentified)
}

@Test func linesForCardsThatLeftTheQueueAreForgotten() {
    var lines = OpenUnavailableLines<String>()
    lines.applyScan(["a": .unavailable(.sessionEnded)], startedAt: 1)
    lines.recordOpen(.unavailable(.appNotIdentified), for: "b", at: 2)
    lines.retain(["c"])
    #expect(lines.line(for: "a") == nil)
    #expect(lines.line(for: "b") == nil)
    #expect(lines.offersOpen("a"))
}

@Test func aSessionTheScanNoLongerClassifiesKeepsNoStaleScanLine() {
    // A card the scan cannot classify (no fresh inventory) offers Open; the click rechecks.
    var lines = OpenUnavailableLines<String>()
    lines.applyScan(["a": .unavailable(.sessionEnded)], startedAt: 1)
    lines.applyScan([:], startedAt: 2)
    #expect(lines.offersOpen("a"))
}
