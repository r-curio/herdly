import Foundation
import Testing
@testable import HerdlyCore

// tmux (#241). Fixtures are saved `list-panes -a` and `list-clients` output in Herdly's format
// strings (`TmuxListing.paneFormat`, `TmuxListing.clientFormat`), shaped after the live proof
// (docs/evidence/tmux-live.md, tmux-live.json: Codex in %0, Claude in %1, a decoy carrying Codex's
// title in %2 and a split %3/%4, one client on /dev/ttys022) and an isolated tmux 3.8 run on a
// private socket (a grouped session lists each pane once per session).

private let codexSession = UUID(uuidString: "01A129C8-A7DB-7782-94AD-741ABB49661F")!
private let codexTitle = "01a129c8-a7db-7782-94ad-741ab..."
private let claudeSessionID = "f119a3c3-7fdf-4bf9-ac69-60acf9ad8321"

/// Codex alone in window @0, Claude alone in @1, the split @3; one session `$0` with one client.
private let panesOutput = """
%0|/dev/ttys017|@0|1|$0|1|0|0|0|0|\(codexTitle)
%1|/dev/ttys018|@1|1|$0|1|0|0|0|0|Mac
%3|/dev/ttys020|@3|2|$0|1|0|0|0|0|Mac
%4|/dev/ttys021|@3|2|$0|1|0|0|0|0|Mac

"""
private let clientsOutput = "/dev/ttys022|45245|$0|%0|0\n"

/// A client run from a shell in a terminal tab: no multiplexer above it.
private let hostedAncestry = ["tmux", "zsh", "login", "Terminal"]

/// The listings, with every client's ancestry read as hosted directly by a terminal unless `ancestry`
/// says otherwise (a missing entry is an ancestry that could not be read).
private func snapshot(panes: String = panesOutput, clients: String = clientsOutput,
                      ancestry: ((Int32) -> [String]?)? = nil) -> TmuxSnapshot? {
    guard let parsed = TmuxSnapshot.parse(panes: panes, clients: clients) else { return nil }
    var ancestries: [Int32: [String]] = [:]
    for client in parsed.clients { ancestries[client.pid] = ancestry.map { $0(client.pid) } ?? hostedAncestry }
    return parsed.withClientAncestries(ancestries.compactMapValues { $0 })
}

// MARK: - Listing

@Test func tmuxListingReadsEachPaneAndClientFromSavedOutput() throws {
    let parsed = try #require(snapshot())
    #expect(parsed.panes.count == 4)
    #expect(parsed.panes[0] == TmuxPane(paneID: "%0", tty: "/dev/ttys017", windowID: "@0", windowPanes: 1,
                                        sessionID: "$0", sessionAttached: 1, sessionGrouped: false,
                                        inMode: false, dead: false, inputOff: false, title: codexTitle))
    #expect(parsed.clients == [TmuxClient(tty: "/dev/ttys022", pid: 45245, sessionID: "$0", paneID: "%0",
                                          controlMode: false)])
    // ADR 0013's inventory: each pane as a tab, its window's pane count visible as a split.
    #expect(parsed.inventory == .tabs([
        TerminalTab(tabID: "%0", tty: "/dev/ttys017", title: codexTitle, paneCount: 1),
        TerminalTab(tabID: "%1", tty: "/dev/ttys018", title: "Mac", paneCount: 1),
        TerminalTab(tabID: "%3", tty: "/dev/ttys020", title: "Mac", paneCount: 2),
        TerminalTab(tabID: "%4", tty: "/dev/ttys021", title: "Mac", paneCount: 2),
    ]))
    #expect(parsed.clientTTYs == ["/dev/ttys022"])
}

@Test func tmuxListingKeepsATitleContainingTheSeparator() throws {
    let parsed = try #require(snapshot(panes: "%7|/dev/ttys030|@2|1|$1|0|0|0|0|0|a|b title\n", clients: ""))
    #expect(parsed.panes[0].title == "a|b title")
    #expect(parsed.clients.isEmpty)
}

@Test func tmuxListingWithNoServerContentHoldsNoPane() throws {
    let parsed = try #require(snapshot(panes: "", clients: ""))
    #expect(parsed.inventory == .tabs([]))
}

@Test func tmuxListingRefusesMalformedOrOversizedOutput() {
    // A bad pane id, tty, window or session id, a missing field, a non-numeric count: unreadable.
    #expect(snapshot(panes: "0|/dev/ttys017|@0|1|$0|1|0|0|0|0|x\n") == nil)
    #expect(snapshot(panes: "%0|/dev/console|@0|1|$0|1|0|0|0|0|x\n") == nil)
    #expect(snapshot(panes: "%0|/dev/ttys017|0|1|$0|1|0|0|0|0|x\n") == nil)
    #expect(snapshot(panes: "%0|/dev/ttys017|@0|1|0|1|0|0|0|0|x\n") == nil)
    #expect(snapshot(panes: "%0|/dev/ttys017|@0|1|$0|1|0|0|0\n") == nil)
    #expect(snapshot(panes: "%0|/dev/ttys017|@0|one|$0|1|0|0|0|0|x\n") == nil)
    #expect(snapshot(clients: "/dev/ttys022|x|$0|%0|0\n") == nil)
    #expect(snapshot(clients: "/dev/ttys022|45245|$0|%0\n") == nil)
    let many = String(repeating: "%0|/dev/ttys017|@0|1|$0|1|0|0|0|0|x\n", count: TmuxSnapshot.maximumPanes + 1)
    #expect(snapshot(panes: many) == nil)
    #expect(snapshot(panes: "%0|/dev/ttys017|@0|1|$0|1|0|0|0|0|" + String(repeating: "t", count: TmuxSnapshot.maximumTitleLength + 1)) == nil)
}

@Test func tmuxListingOfAGroupedSessionListsEachPaneOncePerSessionButOneTab() throws {
    // Isolated tmux 3.8: `new-session -t lab -s grp` lists every pane twice, grouped.
    let grouped = """
    %0|/dev/ttys021|@0|1|$1|0|1|0|0|0|\(codexTitle)
    %0|/dev/ttys021|@0|1|$0|0|1|0|0|0|\(codexTitle)
    """
    let parsed = try #require(snapshot(panes: grouped, clients: ""))
    #expect(parsed.inventory == .tabs([TerminalTab(tabID: "%0", tty: "/dev/ttys021", title: codexTitle, paneCount: 1)]))
}

// MARK: - Pane binding across enabled hosts (ADR 0013 with the pane in place of the tab, ADR 0014)

private let hostTTY = "/dev/ttys022"
private let switches = TerminalHostSwitches(enabled: [.terminalApp, .tmux])
private let codexInPane = ["/dev/ttys017": [TerminalProcess(pid: 45160, name: "codex", foreground: true)]]

/// Terminal.app holding the client's tab (title `tmux`) and an unrelated shell tab.
private func terminalTabs(clientTitle: String = "tmux") -> TerminalHostInventory {
    .tabs([TerminalTab(tabID: "9882", tty: hostTTY, title: clientTitle, paneCount: 1),
           TerminalTab(tabID: "9921", tty: "/dev/ttys030", title: "Terminal", paneCount: 1)])
}

private func codexBinding(tmux: TerminalHostInventory?, terminal: TerminalHostInventory? = nil,
                          processes: [String: [TerminalProcess]] = codexInPane,
                          switches: TerminalHostSwitches = switches,
                          clientTTYs: Set<String> = [hostTTY]) -> TerminalTabBinding {
    var inventories: [TerminalHost: TerminalHostInventory] = [.terminalApp: terminal ?? terminalTabs()]
    if let tmux { inventories[.tmux] = tmux }
    return TerminalTabBindingRules.codex(sessionID: codexSession.uuidString, liveness: .live,
                                         liveSessions: [codexSession.uuidString], switches: switches,
                                         inventories: inventories, processes: processes, secondRead: inventories,
                                         multiplexerClientTTYs: clientTTYs)
}

@Test func tmuxCodexPaneBindsByTitleAndOneForegroundCodex() throws {
    let tmux = try #require(snapshot()).inventory
    #expect(codexBinding(tmux: tmux) == .bound(TerminalTabTarget(host: .tmux, tabID: "%0", tty: "/dev/ttys017")))
    // No foreground `codex` on the pane's tty: a title decoy, so nothing carries the title (#268).
    #expect(codexBinding(tmux: tmux, processes: ["/dev/ttys017": [TerminalProcess(pid: 9, name: "zsh", foreground: true)]])
            == .unavailable(.titleNotFound))
}

@Test func tmuxDecoyPaneCarryingTheTitleLeavesTheRealPaneBound() throws {
    let decoy = "%2|/dev/ttys019|@2|1|$0|1|0|0|0|0|\(codexTitle)\n"
    let tmux = try #require(snapshot(panes: panesOutput + decoy)).inventory
    // The decoy's `ps` was not read: it may run `codex`, so it still counts.
    #expect(codexBinding(tmux: tmux) == .unavailable(.duplicateTitles(2)))
    // Its `ps` shows no foreground `codex`: it is no candidate, and the real pane binds (#268).
    var withDecoyPS = codexInPane
    withDecoyPS["/dev/ttys019"] = [TerminalProcess(pid: 9, name: "zsh", foreground: true)]
    #expect(codexBinding(tmux: tmux, processes: withDecoyPS)
            == .bound(TerminalTabTarget(host: .tmux, tabID: "%0", tty: "/dev/ttys017")))
    // A second pane that runs `codex` too still leaves the session unbound.
    withDecoyPS["/dev/ttys019"] = [TerminalProcess(pid: 10, name: "codex", foreground: true)]
    #expect(codexBinding(tmux: tmux, processes: withDecoyPS) == .unavailable(.duplicateTitles(2)))
}

@Test func tmuxClientsHostTabMirroringThePaneTitleIsLeftOutOfTheCodexTitleCount() throws {
    // `set-titles on` with "#T": the host tab shows the focused pane's title. Its tty is the client's,
    // so it never counts (ADR 0014, "Codex title count").
    let tmux = try #require(snapshot()).inventory
    let mirrored = terminalTabs(clientTitle: codexTitle)
    #expect(codexBinding(tmux: tmux, terminal: mirrored)
            == .bound(TerminalTabTarget(host: .tmux, tabID: "%0", tty: "/dev/ttys017")))
    // A tab on any other tty carrying the title is a second candidate.
    #expect(codexBinding(tmux: tmux, terminal: mirrored, clientTTYs: []) == .unavailable(.duplicateTitles(2)))
}

@Test func tmuxEnabledButUnreadOrUnreadableLeavesEverySessionUnavailable() throws {
    #expect(codexBinding(tmux: nil) == .unavailable(.hostUnreadable(.tmux)))
    #expect(codexBinding(tmux: .unreadable) == .unavailable(.hostUnreadable(.tmux)))
    // Not running holds nothing; the Terminal.app tab rules decide alone.
    #expect(codexBinding(tmux: .notRunning) == .unavailable(.titleNotFound))
    // tmux with no terminal on is never contacted, so its read is ignored.
    let tmux = try #require(snapshot()).inventory
    #expect(codexBinding(tmux: tmux, switches: TerminalHostSwitches(enabled: [.tmux])) == .unavailable(.titleNotFound))
}

@Test func tmuxSplitPaneIsUnavailable() throws {
    let split = panesOutput.replacingOccurrences(of: "%0|/dev/ttys017|@0|1|", with: "%0|/dev/ttys017|@0|2|")
    #expect(codexBinding(tmux: try #require(snapshot(panes: split)).inventory) == .unavailable(.split))
}

@Test func tmuxClaudePaneBindsByItsRegisteredProcessTTY() throws {
    let tmux = try #require(snapshot()).inventory
    let process = ClaudeSessionRegistry.Process(pid: 45170, procStart: "Mon Oct 12 10:00:00 2026")
    let binding = TerminalTabBindingRules.claude(
        sessionID: claudeSessionID, liveness: .live, process: .registered(process),
        observed: TerminalProcessObservation(pid: 45170, procStart: "Mon Oct 12 10:00:00 2026", tty: "ttys018"),
        switches: switches, inventories: [.terminalApp: terminalTabs(), .tmux: tmux],
        processes: ["/dev/ttys018": [TerminalProcess(pid: 45170, name: "2.1.296", foreground: true)]])
    #expect(binding == .bound(TerminalTabTarget(host: .tmux, tabID: "%1", tty: "/dev/ttys018")))
    let unread = TerminalTabBindingRules.claude(
        sessionID: claudeSessionID, liveness: .live, process: .registered(process),
        observed: TerminalProcessObservation(pid: 45170, procStart: "Mon Oct 12 10:00:00 2026", tty: "ttys018"),
        switches: switches, inventories: [.terminalApp: terminalTabs()], processes: [:])
    #expect(unread == .unavailable(.hostUnreadable(.tmux)))
}

// MARK: - Layout and clients (ADR 0014 "Layout and clients")

@Test func tmuxPaneLayerNeedsOneListingOneWindowPaneAndNoNesting() throws {
    let parsed = try #require(snapshot())
    #expect(TmuxLayout.paneLayer("%0", in: parsed) == nil)
    #expect(TmuxLayout.paneLayer("%3", in: parsed) == .split)
    #expect(TmuxLayout.paneLayer("%9", in: parsed) == .paneGone)
    let grouped = try #require(snapshot(panes: """
    %0|/dev/ttys021|@0|1|$1|0|1|0|0|0|\(codexTitle)
    %0|/dev/ttys021|@0|1|$0|1|1|0|0|0|\(codexTitle)
    """, clients: ""))
    #expect(TmuxLayout.paneLayer("%0", in: grouped) == .groupedSession)
    // The session's client runs inside a tmux pane (tmux in tmux): nested.
    let nested = try #require(snapshot(clients: "/dev/ttys018|45300|$0|%0|0\n"))
    #expect(TmuxLayout.paneLayer("%0", in: nested) == .nested)
}

@Test func tmuxClientInsideHerdrOrZellijIsNestedAndAnUnreadAncestryCannotBeRuledOut() throws {
    // herdr and Zellij list no pane tty, so only the client process's ancestry shows them (ADR 0014).
    for multiplexer in ["herdr", "zellij", "tmux"] {
        let inside = try #require(snapshot(ancestry: { _ in ["tmux", "zsh", multiplexer, "login", "Terminal"] }))
        #expect(TmuxLayout.paneLayer("%0", in: inside) == .nested)
        #expect(TmuxLayout.inputLayer("%0", in: inside) == .nested)
        #expect(TmuxOpen.plan(.bound(paneTarget), snapshot: inside, join: { _ in .tab(hostTab) })
                == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
    }
    let unread = try #require(snapshot(ancestry: { _ in nil }))
    #expect(TmuxLayout.paneLayer("%0", in: unread) == .nested)
    // A parsed listing whose ancestries were never read cannot rule nesting out either.
    #expect(TmuxLayout.inputLayer("%0", in: try #require(TmuxSnapshot.parse(panes: panesOutput, clients: clientsOutput))) == .nested)
    // A session with no client has no client to nest.
    #expect(TmuxLayout.inputLayer("%0", in: try #require(snapshot(clients: ""))) == nil)
}

@Test func tmuxInputIsRefusedWhileTheSessionHasAControlModeClient() throws {
    // Conservative, pending a product decision: as Open falls back, typed input and digits go nowhere.
    let control = try #require(snapshot(clients: "/dev/ttys022|45245|$0|%0|1\n"))
    #expect(TmuxLayout.inputLayer("%0", in: control) == .controlModeClient)
    #expect(TmuxInput.route(.bound(paneTarget), snapshot: control) == .unreachable)
}

@Test func tmuxInputNeedsThePaneOutOfCopyModeAndAcceptingKeys() throws {
    let parsed = try #require(snapshot())
    #expect(TmuxLayout.inputLayer("%0", in: parsed) == nil)
    let copy = try #require(snapshot(panes: panesOutput.replacingOccurrences(
        of: "%0|/dev/ttys017|@0|1|$0|1|0|0|0|0|", with: "%0|/dev/ttys017|@0|1|$0|1|0|1|0|0|")))
    #expect(TmuxLayout.inputLayer("%0", in: copy) == .inMode)
    let off = try #require(snapshot(panes: panesOutput.replacingOccurrences(
        of: "%0|/dev/ttys017|@0|1|$0|1|0|0|0|0|", with: "%0|/dev/ttys017|@0|1|$0|1|0|0|0|1|")))
    #expect(TmuxLayout.inputLayer("%0", in: off) == .inputOff)
    // The host tab plays no part in where the bytes land: no client needed (ADR 0017).
    #expect(TmuxLayout.inputLayer("%0", in: try #require(snapshot(clients: ""))) == nil)
}

@Test func tmuxOpenNeedsExactlyOneAttachedClientOnThePanesSession() throws {
    let parsed = try #require(snapshot())
    #expect(TmuxLayout.client(for: "%0", in: parsed)
            == .success(TmuxClient(tty: hostTTY, pid: 45245, sessionID: "$0", paneID: "%0", controlMode: false)))
    #expect(TmuxLayout.client(for: "%0", in: try #require(snapshot(clients: ""))) == .failure(.noClient))
    let two = try #require(snapshot(clients: clientsOutput + "/dev/ttys023|45400|$0|%0|0\n"))
    #expect(TmuxLayout.client(for: "%0", in: two) == .failure(.clients(2)))
    // A client on another session is not this pane's: Herdly never moves a client between sessions.
    #expect(TmuxLayout.client(for: "%0", in: try #require(snapshot(clients: "/dev/ttys022|45245|$5|%8|0\n")))
            == .failure(.noClient))
    // iTerm2's `-CC` control client counts, but is no host tab.
    #expect(TmuxLayout.client(for: "%0", in: try #require(snapshot(clients: "/dev/ttys022|45245|$0|%0|1\n")))
            == .failure(.controlModeClient))
}

// MARK: - Host-tab join (ADR 0014 "Host-tab join")

private let joinSwitches = TerminalHostSwitches(enabled: [.iTerm2, .terminalApp, .tmux])

@Test func multiplexerClientJoinsTheOneUnsplitTabOnItsTTYAcrossEnabledHosts() {
    let iTerm2: TerminalHostInventory = .tabs([TerminalTab(tabID: "GUID-1", tty: "/dev/ttys040", title: "zsh", paneCount: 1)])
    let inventories: [TerminalHost: TerminalHostInventory] = [.iTerm2: iTerm2, .terminalApp: terminalTabs()]
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: joinSwitches, inventories: inventories)
            == .tab(TerminalTabTarget(host: .terminalApp, tabID: "9882", tty: hostTTY)))
    #expect(MultiplexerHostTab.join(clientTTY: "/dev/ttys040", switches: joinSwitches, inventories: inventories)
            == .tab(TerminalTabTarget(host: .iTerm2, tabID: "GUID-1", tty: "/dev/ttys040")))
}

@Test func multiplexerClientJoinFallsBackOrStaysUnavailableByADR0015() {
    let split: TerminalHostInventory = .tabs([TerminalTab(tabID: "GUID-1", tty: hostTTY, title: "tmux", paneCount: 2)])
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: joinSwitches,
                                    inventories: [.iTerm2: split, .terminalApp: .notRunning])
            == .miss(.fallBack(.unsupportedLayout, candidates: 1)))
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: joinSwitches,
                                    inventories: [.iTerm2: .notRunning, .terminalApp: .notRunning])
            == .miss(.fallBack(.noUniqueTarget, candidates: 0)))
    // An enabled host that cannot be read cannot be ruled out.
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: joinSwitches,
                                    inventories: [.iTerm2: .unreadable, .terminalApp: terminalTabs()])
            == .miss(.unavailable(.hostUnreadable(.iTerm2))))
    // A switched-off host is never read, whatever it would hold.
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: TerminalHostSwitches(enabled: [.iTerm2, .tmux]),
                                    inventories: [.iTerm2: .notRunning, .terminalApp: terminalTabs()])
            == .miss(.fallBack(.noUniqueTarget, candidates: 0)))
}

@Test func multiplexerClientJoinLeavesAGhosttyWithoutTTYToGhosttysOwnJoin() {
    let ghostty: TerminalHostInventory = .tabs([TerminalTab(tabID: "w1/t1/s1", tty: nil, title: "tmux", paneCount: 1)])
    let switches = TerminalHostSwitches(enabled: [.ghostty, .terminalApp, .tmux])
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: switches,
                                    inventories: [.ghostty: ghostty, .terminalApp: .notRunning]) == .ghostty)
    // A tty-bearing tab that matches wins: a tty is one device.
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: switches,
                                    inventories: [.ghostty: ghostty, .terminalApp: terminalTabs()])
            == .tab(TerminalTabTarget(host: .terminalApp, tabID: "9882", tty: hostTTY)))
}

// MARK: - Two-layer Open (ADR 0014 "Open sequence", ADR 0015, ADR 0016)

private let paneTarget = TerminalTabTarget(host: .tmux, tabID: "%0", tty: "/dev/ttys017")
private let hostTab = TerminalTabTarget(host: .terminalApp, tabID: "9882", tty: hostTTY)
private let client = TmuxClient(tty: hostTTY, pid: 45245, sessionID: "$0", paneID: "%0", controlMode: false)

@Test func tmuxOpenPlanNeedsTheBoundPaneItsOneClientAndTheHostTab() throws {
    let parsed = try #require(snapshot())
    #expect(TmuxOpen.plan(.bound(paneTarget), snapshot: parsed, join: { _ in .tab(hostTab) })
            == .success(TmuxOpenPlan(pane: paneTarget, client: client, host: .tab(hostTab))))
    #expect(TmuxOpen.plan(.bound(paneTarget), snapshot: parsed, join: { _ in .ghostty })
            == .success(TmuxOpenPlan(pane: paneTarget, client: client, host: .ghostty)))
    // A join that misses keeps its own outcome; the pane is never focused.
    #expect(TmuxOpen.plan(.bound(paneTarget), snapshot: parsed,
                          join: { _ in .miss(.unavailable(.hostUnreadable(.iTerm2))) })
            == .failure(.unavailable(.hostUnreadable(.iTerm2))))
}

@Test func tmuxOpenPlanMapsBindingAndLayoutFailuresByADR0015() throws {
    let parsed = try #require(snapshot())
    let join: (String) -> MultiplexerHostJoin = { _ in .tab(hostTab) }
    #expect(TmuxOpen.plan(.unavailable(.hostUnreadable(.tmux)), snapshot: parsed, join: join)
            == .failure(.unavailable(.hostUnreadable(.tmux))))
    #expect(TmuxOpen.plan(.unavailable(.split), snapshot: parsed, join: join)
            == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
    #expect(TmuxOpen.plan(.unavailable(.duplicateTitles(2)), snapshot: parsed, join: join)
            == .failure(.fallBack(.noUniqueTarget, candidates: 2)))
    // Several clients, none, or a grouped session: an unsupported layout; the fallback walks the clients.
    let two = try #require(snapshot(clients: clientsOutput + "/dev/ttys023|45400|$0|%0|0\n"))
    #expect(TmuxOpen.plan(.bound(paneTarget), snapshot: two, join: join) == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
    #expect(TmuxOpen.plan(.bound(paneTarget), snapshot: try #require(snapshot(clients: "")), join: join)
            == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
    #expect(TmuxOpen.fallbackClientPIDs(for: "%0", in: two) == [45245, 45400])
    #expect(TmuxOpen.fallbackClientPIDs(for: "%0", in: try #require(snapshot(clients: ""))) == [])
}

@Test func tmuxOpenFocusesThePaneOnceWithSwitchClientAndVerifiesItThroughListClients() throws {
    let plan = TmuxOpenPlan(pane: paneTarget, client: client, host: .tab(hostTab))
    #expect(TmuxOpen.focusArguments(plan) == ["switch-client", "-c", hostTTY, "-t", "%0"])
    #expect(TmuxOpen.focused(.succeeded("")) == nil)
    // A failed focus falls back without touching the host tab; a missing binary is unreadable.
    #expect(TmuxOpen.focused(.failed) == .fallBack(.notVerified, candidates: 1))
    #expect(TmuxOpen.focused(.timedOut) == .fallBack(.notVerified, candidates: 1))
    #expect(TmuxOpen.focused(.notLaunched) == .unavailable(.hostUnreadable(.tmux)))

    let parsed = try #require(snapshot())
    #expect(TmuxOpen.verifyPane(plan, read: .snapshot(parsed), binding: .bound(paneTarget)) == nil)
    let elsewhere = try #require(snapshot(clients: "/dev/ttys022|45245|$0|%1|0\n"))
    #expect(TmuxOpen.verifyPane(plan, read: .snapshot(elsewhere), binding: .bound(paneTarget))
            == .fallBack(.notVerified, candidates: 1))
    let otherClient = try #require(snapshot(clients: "/dev/ttys022|50000|$0|%0|0\n"))
    #expect(TmuxOpen.verifyPane(plan, read: .snapshot(otherClient), binding: .bound(paneTarget))
            == .fallBack(.notVerified, candidates: 1))
    #expect(TmuxOpen.verifyPane(plan, read: .unreadable, binding: .bound(paneTarget)) == .fallBack(.notVerified, candidates: 1))
    #expect(TmuxOpen.verifyPane(plan, read: .snapshot(parsed), binding: .unavailable(.titleChanged))
            == .fallBack(.notVerified, candidates: 1))
}

@Test func tmuxOpenHostTabFailureAfterAVerifiedPaneIsAPartialReach() {
    #expect(TmuxOpen.hostRaised(nil) == nil)
    #expect(TmuxOpen.hostRaised(.fallBack(.notVerified, candidates: 1)) == .fallBack(.partialReach, candidates: 1))
    // Automation denied or the tab gone stays unavailable (ADR 0016, "Select or raise").
    #expect(TmuxOpen.hostRaised(.unavailable(.hostUnreadable(.terminalApp))) == .unavailable(.hostUnreadable(.terminalApp)))
}

@Test func tmuxOpenSequenceStopsAtTheFirstFailureAndNeverRollsBack() async {
    final class Calls: @unchecked Sendable { var steps: [String] = [] }
    let calls = Calls()
    let plan = TmuxOpenPlan(pane: paneTarget, client: client, host: .tab(hostTab))
    let failed = await TmuxOpen.run(now: { 100 },
                                    revalidate: { calls.steps.append("revalidate"); return .success(plan) },
                                    focus: { _ in calls.steps.append("focus"); return nil },
                                    verifyPane: { _ in calls.steps.append("verifyPane"); return .fallBack(.notVerified, candidates: 1) },
                                    raise: { _ in calls.steps.append("raise"); return nil },
                                    verifyHost: { _ in calls.steps.append("verifyHost"); return nil })
    #expect(failed == .failed(.fallBack(.notVerified, candidates: 1), at: .verifyPane))
    #expect(calls.steps == ["revalidate", "focus", "verifyPane"])
    calls.steps = []
    let opened = await TmuxOpen.run(now: { 100 }, revalidate: { .success(plan) }, focus: { _ in nil },
                                    verifyPane: { _ in nil }, raise: { _ in calls.steps.append("raise"); return nil },
                                    verifyHost: { _ in calls.steps.append("verifyHost"); return nil })
    #expect(opened == .opened(plan, preOpenAt: 100))
    #expect(calls.steps == ["raise", "verifyHost"])
}

// MARK: - Typed input (ADR 0017)

private let inputPane = TypedInputPane(host: .tmux, paneID: "%0", tty: "/dev/ttys017")

@Test func tmuxTypesLiteralTextThenASeparateEnter() {
    #expect(TmuxInput.arguments(.text("-run the tests"), into: inputPane)
            == ["send-keys", "-t", "%0", "-l", "--", "-run the tests"])
    // Claude submits text plus CR from one send-keys (tmux-live.md, "send-keys to a TUI").
    #expect(TmuxInput.arguments(.textAndSubmit("hi"), into: inputPane) == ["send-keys", "-t", "%0", "-l", "--", "hi\r"])
    #expect(TmuxInput.arguments(.submit, into: inputPane) == ["send-keys", "-t", "%0", "Enter"])
}

@Test func tmuxEscapesATrailingSemicolonSoItIsTypedNotTakenAsACommandSeparator() {
    // tmux 3.8 (isolated server): an argument ending in `;` ends the command and loses the `;`, even
    // after `-l --`; a trailing `\;` types `;`. Only the last `;` is special.
    #expect(TmuxInput.arguments(.text("fix the parser;"), into: inputPane).last == "fix the parser\\;")
    #expect(TmuxInput.arguments(.text(";"), into: inputPane).last == "\\;")
    #expect(TmuxInput.arguments(.text("a\\;"), into: inputPane).last == "a\\\\;")
    #expect(TmuxInput.arguments(.text("a;b"), into: inputPane).last == "a;b")
    #expect(TmuxInput.arguments(.text("x\\"), into: inputPane).last == "x\\")
    #expect(TmuxInput.arguments(.textAndSubmit("go;"), into: inputPane).last == "go;\r")
    #expect(TmuxInput.literal("stop;") == "stop\\;")
    #expect(TmuxInput.digitArguments("2", into: inputPane).last == "2")
    // Codex gets its text, then the separate Enter.
    #expect(TypedReplyWrites.plan(agent: .codex, text: "go").map { TmuxInput.arguments($0, into: inputPane) }
            == [["send-keys", "-t", "%0", "-l", "--", "go"], ["send-keys", "-t", "%0", "Enter"]])
}

@Test func tmuxSendThatDoesNotReturnInTimeCountsAsSent() {
    #expect(TmuxInput.delivery(.succeeded("")) == .written)
    // An unknown pane exits 1 before writing ("can't find pane"); nothing was sent.
    #expect(TmuxInput.delivery(.failed) == .notWritten)
    #expect(TmuxInput.delivery(.notLaunched) == .notWritten)
    #expect(TmuxInput.delivery(.timedOut) == .possiblyWritten)
}

@Test func tmuxReplyRouteNeedsThePaneLayerAndNoCopyMode() throws {
    #expect(TerminalHost.tmux.typesReplies)
    let parsed = try #require(snapshot())
    #expect(TmuxInput.route(.bound(paneTarget), snapshot: parsed) == .pane(inputPane))
    let copy = try #require(snapshot(panes: panesOutput.replacingOccurrences(
        of: "%0|/dev/ttys017|@0|1|$0|1|0|0|0|0|", with: "%0|/dev/ttys017|@0|1|$0|1|0|1|0|0|")))
    #expect(TmuxInput.route(.bound(paneTarget), snapshot: copy) == .unreachable)
    #expect(TmuxInput.route(.bound(paneTarget), snapshot: nil) == .unreachable)
    #expect(TmuxInput.route(.unavailable(.duplicateTitles(2)), snapshot: parsed) == .unreachable)
    // The copy-mode check is part of the fresh check before every write.
    let state = TypedReplyFreshState(completionQueued: true, latestTurn: true, sessionIdle: true, pendingInteraction: false,
                                     daemonHoldsThread: false, route: TmuxInput.route(.bound(paneTarget), snapshot: copy))
    #expect(TypedReplyCheck.veto(state, spent: inputPane) == .unreachable)
    // A tab bound in another host keeps that host's route.
    #expect(TmuxInput.route(.bound(hostTab), snapshot: parsed)
            == .pane(TypedInputPane(host: .terminalApp, paneID: "9882", tty: hostTTY)))
}

// MARK: - Question digits (ADR 0017 "Codex questions"): on since the live proof (#246)

@Test func tmuxQuestionDigitsFollowTheirLiveProofGate() {
    // Proven live in tmux's acceptance run (#246): the digit alone commits Codex's answer.
    #expect(TmuxInput.questionDigitsProvenLive)
    #expect(TerminalHost.tmux.typesQuestionDigits == TmuxInput.questionDigitsProvenLive)
    // With the gate off, a session tmux holds is answered in Codex.
    let question = cliQuestion()
    #expect(QuestionRelayRouting.route(for: question, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .tmux, typesDigits: { _ in false }) == .relayUnavailable(.noQuestionKeys(.tmux)))
    #expect(HerdrQuestionRelayUnavailable.noQuestionKeys(.tmux).message == "Answer this in Codex.")
    // With it on, the shared pane-key route carries it.
    #expect(QuestionRelayRouting.route(for: question, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .tmux, typesDigits: { $0 == .tmux }) == .terminalRelay)
}

private func cliQuestion() -> AttentionQuestion {
    AttentionQuestion(source: .cli, session: codexSession, turn: UUID(uuidString: "01A129C9-0000-7000-8000-000000000001")!,
                      callID: "call_1", arrivedAt: 10)
}

@Test func tmuxQuestionKeyFreshCheckNeedsThePendingCallTheSamePaneAndNoCopyMode() throws {
    let question = cliQuestion()
    var pending = ReminderReader.RolloutEvidence()
    pending.pendingQuestions = [question]
    let parsed = try #require(snapshot())
    func check(_ evidence: ReminderReader.RolloutEvidence, _ binding: TerminalTabBinding, _ tmux: TmuxSnapshot) -> HerdrQuestionRelayUnavailable? {
        TerminalQuestionKeys.preSendCheck(question: question, evidence: evidence,
                                          route: TmuxInput.route(binding, snapshot: tmux), spent: inputPane)
    }
    #expect(check(pending, .bound(paneTarget), parsed) == nil)
    #expect(TmuxInput.digitArguments("2", into: inputPane) == ["send-keys", "-t", "%0", "-l", "--", "2"])
    var ended = pending
    ended.completed = [TurnIdentity(session: question.session, turn: question.turn)]
    #expect(check(ended, .bound(paneTarget), parsed) == .turnEnded)
    let copy = try #require(snapshot(panes: panesOutput.replacingOccurrences(
        of: "%0|/dev/ttys017|@0|1|$0|1|0|0|0|0|", with: "%0|/dev/ttys017|@0|1|$0|1|0|1|0|0|")))
    #expect(check(pending, .bound(paneTarget), copy) == .leftHerdr)
    #expect(check(pending, .bound(TerminalTabTarget(host: .tmux, tabID: "%1", tty: "/dev/ttys018")), parsed) == .paneChanged)
}

// MARK: - Visits (ADR 0016 "Visible": the client's current pane, and its host tab visible)

@Test func tmuxPaneIsVisibleWhenItsClientShowsItInTheFrontHostTab() throws {
    let parsed = try #require(snapshot())
    #expect(TmuxVisibility.reading(parsed, hostFront: .visible(hostTTY)) == .visible("%0"))
    let elsewhere = try #require(snapshot(clients: "/dev/ttys022|45245|$0|%1|0\n"))
    #expect(TmuxVisibility.reading(elsewhere, hostFront: .visible(hostTTY)) == .visible("%1"))
    // Another tab in front, no host in front, or an unread host or tmux.
    #expect(TmuxVisibility.reading(parsed, hostFront: .visible("/dev/ttys030")) == .nothing)
    #expect(TmuxVisibility.reading(parsed, hostFront: .nothing) == .nothing)
    #expect(TmuxVisibility.reading(parsed, hostFront: .unknown) == .unknown)
    #expect(TmuxVisibility.reading(nil, hostFront: .visible(hostTTY)) == .unknown)
    // A split pane or a second client is not a visit target.
    let split = try #require(snapshot(clients: "/dev/ttys022|45245|$0|%3|0\n"))
    #expect(TmuxVisibility.reading(split, hostFront: .visible(hostTTY)) == .nothing)
}

@Test func hostFrontTabIsReadByEachHostsOwnVisibleTestAsATTY() throws {
    // iTerm2: its current session, only while macOS reports iTerm2 frontmost.
    let iTerm2JSON = #"{"status":"ok","current":{"window":7,"session":"DB978EE1-01BB-4FE6-9F82-88B775105CDC"},"windows":[{"id":7,"tabs":[{"sessions":[{"id":"DB978EE1-01BB-4FE6-9F82-88B775105CDC","tty":"/dev/ttys022","window_name":"tmux","icon_name":null}]}]}]}"#
    guard case .snapshot(let iTerm2)? = ITerm2Reading.parse(Data(iTerm2JSON.utf8)) else { Issue.record("iTerm2"); return }
    #expect(MultiplexerHostFront.iTerm2(iTerm2, frontmost: .iTerm2) == .visible(hostTTY))
    #expect(MultiplexerHostFront.iTerm2(iTerm2, frontmost: .terminalApp) == .nothing)
    #expect(MultiplexerHostFront.iTerm2(nil, frontmost: .iTerm2) == .unknown)
    // Terminal.app: its front tab-window, on screen.
    let terminal = try #require(TerminalAppSnapshot.parse(Data(#"{"status":"ok","windows":[{"id":9882,"tabs":[{"tty":"/dev/ttys022","title":"tmux"}]}]}"#.utf8)))
    #expect(MultiplexerHostFront.terminalApp(terminal, frontmost: .terminalApp, onScreenWindowIDs: [9882]) == .visible(hostTTY))
    #expect(MultiplexerHostFront.terminalApp(terminal, frontmost: .terminalApp, onScreenWindowIDs: []) == .nothing)
    // Ghostty: its selected terminal's tty; a Ghostty without `tty` cannot say.
    func ghostty(_ tty: String?) throws -> GhosttySnapshot {
        let field = tty.map { #","tty":"\#($0)""# } ?? ""
        let json = #"{"status":"ok","windows":[{"id":"w1","tabs":[{"id":"t1","terminals":[{"id":"s1","name":"tmux"\#(field)}]}]}],"front_window_id":"w1","selected":{"window_id":"w1","tab_id":"t1","terminal_id":"s1"}}"#
        return try JSONDecoder().decode(GhosttySnapshot.self, from: Data(json.utf8))
    }
    #expect(MultiplexerHostFront.ghostty(try ghostty(hostTTY), frontmost: .ghostty) == .visible(hostTTY))
    #expect(MultiplexerHostFront.ghostty(try ghostty(nil), frontmost: .ghostty) == .unknown)
    #expect(MultiplexerHostFront.ghostty(try ghostty(hostTTY), frontmost: nil) == .nothing)
    // WezTerm: the one GUI client's focused pane, only while macOS reports WezTerm frontmost.
    let list = #"[{"window_id":1,"tab_id":1,"pane_id":7,"workspace":"default","size":{"rows":24,"cols":80,"pixel_width":1120,"pixel_height":768,"dpi":144},"title":"tmux","cwd":"file:///tmp","cursor_x":0,"cursor_y":0,"cursor_shape":"Default","cursor_visibility":"Visible","left_col":0,"top_row":0,"tab_title":"","window_title":"tmux","is_active":true,"is_zoomed":false,"tty_name":"/dev/ttys022"}]"#
    let clientsJSON = #"[{"pid":38165,"connection_elapsed":{"secs":3,"nanos":0},"idle_time":{"secs":3,"nanos":0},"workspace":"default","focused_pane_id":7}]"#
    let wezTerm = try #require(WezTermSnapshot.parse(Data(list.utf8)))
    let clients = try #require(WezTermClients.parse(Data(clientsJSON.utf8)))
    #expect(MultiplexerHostFront.wezTerm(wezTerm, clients: clients, frontmost: .wezTerm) == .visible(hostTTY))
    #expect(MultiplexerHostFront.wezTerm(wezTerm, clients: clients, frontmost: .iTerm2) == .nothing)
    #expect(MultiplexerHostFront.wezTerm(wezTerm, clients: nil, frontmost: .wezTerm) == .unknown)
}

@Test func multiplexerClientJoinsAWezTermPaneLikeAnyEnabledHostsTab() {
    let wezTerm: TerminalHostInventory = .tabs([TerminalTab(tabID: "7", tty: hostTTY, title: "tmux", paneCount: 1)])
    #expect(MultiplexerHostTab.join(clientTTY: hostTTY, switches: TerminalHostSwitches(enabled: [.wezTerm, .tmux]),
                                    inventories: [.wezTerm: wezTerm]) == .tab(TerminalTabTarget(host: .wezTerm, tabID: "7", tty: hostTTY)))
}

// MARK: - Settings card (product.md, "Agreed terminal host presentation")

@Test func tmuxCardSaysWhenNoTerminalIsOn() {
    let row = TmuxPresentation.settingsRow(on: true, anyTerminalOn: false, read: nil, sessionsSeen: false,
                                           otherSocketSeen: false)
    #expect(row.badge == .needsAttention)
    #expect(row.problems == ["Turn on the terminal you run tmux in."])
    // product.md's lines, and the shared unavailable line where product.md names none.
    #expect(TmuxPresentation.otherSocketLine == "Sessions seen on a socket other than the default can't be reached.")
    #expect(TmuxPresentation.unreadableLine == OpenUnavailableReason.hostUnreadable(.tmux).cardLine)
    #expect(!TmuxPresentation.howOpenWorks.contains("Codex questions"))
    #expect(TmuxPresentation.settingsRow(on: false, anyTerminalOn: false, read: nil, sessionsSeen: false,
                                         otherSocketSeen: true).badge == .off)
}

@Test func tmuxCardListsEveryProblemIncludingANonDefaultSocket() throws {
    let row = TmuxPresentation.settingsRow(on: true, anyTerminalOn: true, read: .snapshot(try #require(snapshot())),
                                           sessionsSeen: true, otherSocketSeen: true)
    #expect(row.badge == .needsAttention)
    #expect(row.problems == [TmuxPresentation.otherSocketLine])
    #expect(TmuxPresentation.settingsRow(on: true, anyTerminalOn: true, read: .binaryNotFound, sessionsSeen: false,
                                         otherSocketSeen: false).problems == [TmuxPresentation.notFoundLine])
    #expect(TmuxPresentation.settingsRow(on: true, anyTerminalOn: true, read: .untrustedSocket, sessionsSeen: false,
                                         otherSocketSeen: false).problems == [TmuxPresentation.untrustedSocketLine])
    #expect(TmuxPresentation.untrustedSocketLine.contains("Check that it runs as you"))
    #expect(TmuxPresentation.settingsRow(on: true, anyTerminalOn: true, read: .unreadable, sessionsSeen: false,
                                         otherSocketSeen: false).problems == [TmuxPresentation.unreadableLine])
    #expect(!TmuxPresentation.unreadableLine.contains("runs as you"))
    let ready = TmuxPresentation.settingsRow(on: true, anyTerminalOn: true, read: .notRunning, sessionsSeen: true,
                                             otherSocketSeen: false)
    #expect(ready.badge == .ready && ready.problems.isEmpty)
    #expect(TmuxPresentation.settingsRow(on: true, anyTerminalOn: true, read: .notRunning, sessionsSeen: false,
                                         otherSocketSeen: false).badge == .notInUse)
}

@Test func tmuxSessionOnAnotherSocketIsSeenFromAClaudeProcessUnderATmuxServer() {
    let underTmux = TmuxSessionProcess(tty: "/dev/ttys050", ancestorCommands: ["2.1.296", "zsh", "tmux"])
    // Its tty is no pane of the default server: it runs on another socket.
    #expect(TmuxPresentation.otherSocketSeen([underTmux], defaultPaneTTYs: ["/dev/ttys017"]))
    #expect(!TmuxPresentation.otherSocketSeen([underTmux], defaultPaneTTYs: ["/dev/ttys050"]))
    // An unread default server says nothing; a session not under tmux says nothing.
    #expect(!TmuxPresentation.otherSocketSeen([underTmux], defaultPaneTTYs: nil))
    #expect(!TmuxPresentation.otherSocketSeen([TmuxSessionProcess(tty: "/dev/ttys050", ancestorCommands: ["claude", "zsh", "login"])],
                                              defaultPaneTTYs: []))
}

// MARK: - Server identity before a send

@Test func tmuxSendGoesOnlyToTheServerItsFreshCheckRead() {
    // `display-message -p '#{pid}|#{start_time}'` from an isolated tmux 3.8 server.
    let identity = TmuxServerIdentity.parse("48163|1791809248\n")
    #expect(identity == TmuxServerIdentity(pid: 48163, startTime: 1791809248))
    #expect(TmuxServerIdentity.parse("48163") == nil)
    #expect(TmuxServerIdentity.parse("x|1") == nil)
    // A restarted server reuses pane ids; a send to it is refused before anything is typed.
    #expect(TmuxServerIdentity.allowsSend(expected: identity, current: identity))
    #expect(!TmuxServerIdentity.allowsSend(expected: identity, current: TmuxServerIdentity(pid: 50000, startTime: 1791809999)))
    #expect(!TmuxServerIdentity.allowsSend(expected: identity, current: nil))
    #expect(!TmuxServerIdentity.allowsSend(expected: nil, current: identity))
}

// MARK: - Default socket and binary (ADR 0014 "Sockets, sessions and gates")

@Test func tmuxDefaultSocketIsTheResolvedTmpdirsUserDirectory() {
    let resolve: (String) -> String? = { ["/tmp": "/private/tmp", "/Users/me/tt": "/Users/me/tt"][$0] }
    #expect(TmuxDefaultSocket.path(uid: 503, environment: [:], resolve: resolve) == "/private/tmp/tmux-503/default")
    #expect(TmuxDefaultSocket.path(uid: 503, environment: ["TMUX_TMPDIR": "/Users/me/tt"], resolve: resolve)
            == "/Users/me/tt/tmux-503/default")
    // A TMUX_TMPDIR that does not resolve falls back to /tmp, as tmux does; TMPDIR is never read.
    #expect(TmuxDefaultSocket.path(uid: 503, environment: ["TMUX_TMPDIR": "/nope", "TMPDIR": "/Users/me/tt"],
                                   resolve: resolve) == "/private/tmp/tmux-503/default")
    #expect(TmuxDefaultSocket.path(uid: 503, environment: [:], resolve: { _ in nil }) == nil)
}

@Test func tmuxDefaultSocketIsTrustedOnlyWhenTheUserOwnsItAndItsDirectory() {
    let directory = TmuxFileFacts(kind: .directory, owner: 503, mode: 0o700)
    let socket = TmuxFileFacts(kind: .socket, owner: 503, mode: 0o660)
    #expect(TmuxSocketTrust.problem(directory: directory, socket: socket, me: 503) == nil)
    // No socket: no server, so tmux holds nothing.
    #expect(TmuxSocketTrust.problem(directory: directory, socket: nil, me: 503) == .notRunning)
    #expect(TmuxSocketTrust.problem(directory: nil, socket: nil, me: 503) == .notRunning)
    // Anything another user could have placed or reach is untrusted, never scanned.
    #expect(TmuxSocketTrust.problem(directory: TmuxFileFacts(kind: .directory, owner: 0, mode: 0o700),
                                    socket: socket, me: 503) == .untrusted)
    #expect(TmuxSocketTrust.problem(directory: TmuxFileFacts(kind: .directory, owner: 503, mode: 0o701),
                                    socket: socket, me: 503) == .untrusted)
    #expect(TmuxSocketTrust.problem(directory: TmuxFileFacts(kind: .other, owner: 503, mode: 0o700),
                                    socket: socket, me: 503) == .untrusted)
    #expect(TmuxSocketTrust.problem(directory: directory, socket: TmuxFileFacts(kind: .other, owner: 503, mode: 0o600),
                                    me: 503) == .untrusted)
    #expect(TmuxSocketTrust.problem(directory: directory, socket: TmuxFileFacts(kind: .socket, owner: 501, mode: 0o600),
                                    me: 503) == .untrusted)
    #expect(TmuxSocketTrust.problem(directory: directory, socket: TmuxFileFacts(kind: .socket, owner: 503, mode: 0o666),
                                    me: 503) == .untrusted)
}

@Test func tmuxBinaryComesOnlyFromFixedLocations() {
    #expect(TmuxBinary.resolve(isExecutable: { $0 == "/usr/local/bin/tmux" || $0 == "/usr/bin/tmux" })
            == "/usr/local/bin/tmux")
    #expect(TmuxBinary.resolve(isExecutable: { $0 == "/opt/homebrew/bin/tmux" }) == "/opt/homebrew/bin/tmux")
    // `PATH` is never consulted: nothing at the fixed locations is not found.
    #expect(TmuxBinary.resolve(isExecutable: { $0 == "/Users/me/bin/tmux" }) == nil)
}

@Test func tmuxReadMapsToADR0013Inventory() throws {
    let parsed = try #require(snapshot())
    #expect(TmuxRead.snapshot(parsed).inventory == parsed.inventory)
    #expect(TmuxRead.notRunning.inventory == .notRunning)
    // Running but unreadable, untrusted, or a server whose binary is missing: it cannot be ruled out.
    #expect(TmuxRead.unreadable.inventory == .unreadable)
    #expect(TmuxRead.untrustedSocket.inventory == .unreadable)
    #expect(TmuxRead.binaryNotFound.inventory == .unreadable)
}
