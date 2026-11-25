import Foundation
import Testing
@testable import HerdlyCore

// WezTerm (#240). Fixtures follow the saved output of the live proof (docs/evidence/wezterm-live.md,
// wezterm-live.json): window 1 holds A1 (Codex, pane 1), A2 (Claude, pane 2), A3 (a decoy with Codex's
// title over `sleep`, pane 3) and A4 split into panes 4 and 5; window 2 holds B1 (pane 6), which the one
// GUI client had focused.

private let codexSession = "01a129bd-a3ec-7dc0-875a-4fac39ec9eaa"
private let codexTitle = "01a129bd-a3ec-7dc0-875a-4fac3..."
private let claudeSessionID = "729984f1-4a2d-4649-b5f3-92212557f4ee"
private let claudeTitle = "Herdly Claude 729984f1-4a2d-4649-b5f3-92212557f4ee"

private func paneJSON(window: Int, tab: Int, pane: Int, title: String, tty: String, active: Bool = true) -> String {
    #"{"window_id":\#(window),"tab_id":\#(tab),"pane_id":\#(pane),"workspace":"default","size":{"rows":24,"cols":80,"pixel_width":1120,"pixel_height":768,"dpi":144},"title":"\#(title)","cwd":"file://<lab-root>/project","cursor_x":2,"cursor_y":20,"cursor_shape":"Default","cursor_visibility":"Visible","left_col":0,"top_row":0,"tab_title":"","window_title":"\#(codexTitle)","is_active":\#(active),"is_zoomed":false,"tty_name":"\#(tty)"}"#
}

/// `wezterm cli list --format json` as the proof's inventory step saw it (without the decoy, unless asked).
private func listJSON(decoy: Bool = true) -> String {
    var panes = [
        paneJSON(window: 1, tab: 1, pane: 1, title: codexTitle, tty: "/dev/ttys017"),
        paneJSON(window: 1, tab: 2, pane: 2, title: claudeTitle, tty: "/dev/ttys018"),
        paneJSON(window: 1, tab: 4, pane: 4, title: "zsh", tty: "/dev/ttys020", active: false),
        paneJSON(window: 1, tab: 4, pane: 5, title: "zsh", tty: "/dev/ttys021"),
        paneJSON(window: 2, tab: 5, pane: 6, title: "zsh", tty: "/dev/ttys022"),
    ]
    if decoy { panes.insert(paneJSON(window: 1, tab: 3, pane: 3, title: codexTitle, tty: "/dev/ttys019"), at: 2) }
    return "[" + panes.joined(separator: ",") + "]"
}

/// `wezterm cli list-clients --format json` with the one GUI client focused on `pane`.
private func clientsJSON(focused pane: Int) -> String {
    #"[{"pid":38165,"connection_elapsed":{"secs":3,"nanos":765604000},"idle_time":{"secs":3,"nanos":765604000},"workspace":"default","focused_pane_id":\#(pane)}]"#
}

/// The parsed `list-clients` fixture for one client focused on `pane` (parsing is checked on its own).
private func focusedOn(_ pane: Int) -> WezTermClients {
    WezTermClients.parse(Data(clientsJSON(focused: pane).utf8))!
}

private func snapshot(_ json: String = listJSON()) -> WezTermSnapshot? {
    WezTermSnapshot.parse(Data(json.utf8))
}

private func clients(_ json: String) -> WezTermClients? {
    WezTermClients.parse(Data(json.utf8))
}

private func tab(_ pane: Int, _ tty: String, _ title: String?, panes: Int = 1) -> TerminalTab {
    TerminalTab(tabID: String(pane), tty: tty, title: title, paneCount: panes)
}

// MARK: - Inventory

@Test func wezTermInventoryListsEachPaneWithItsTTYTitleAndItsTabsPaneCount() throws {
    let parsed = try #require(snapshot())
    // A split shows as two panes sharing a tab_id, so each counts two panes and never binds.
    #expect(parsed.inventory == .tabs([
        tab(1, "/dev/ttys017", codexTitle),
        tab(2, "/dev/ttys018", claudeTitle),
        tab(3, "/dev/ttys019", codexTitle),
        tab(4, "/dev/ttys020", "zsh", panes: 2),
        tab(5, "/dev/ttys021", "zsh", panes: 2),
        tab(6, "/dev/ttys022", "zsh"),
    ]))
    #expect(parsed.pane(6)?.windowID == 2)
    #expect(parsed.pane(1)?.tabID == 1)
}

@Test func wezTermInventoryWithNoPanesHoldsNoTab() throws {
    #expect(try #require(snapshot("[]")).inventory == .tabs([]))
}

@Test func wezTermInventoryRefusesMalformedOrOversizedReplies() {
    // Not an array, ids of the wrong type, a negative or fractional id, a duplicate pane, a bad tty, a
    // title of the wrong type, missing ids: unreadable, never repaired.
    #expect(snapshot(#"{"panes":[]}"#) == nil)
    #expect(snapshot("not json") == nil)
    #expect(snapshot(#"[{"window_id":"1","tab_id":1,"pane_id":1,"title":"x","tty_name":"/dev/ttys001"}]"#) == nil)
    #expect(snapshot(#"[{"window_id":1,"tab_id":1,"pane_id":-1,"title":"x","tty_name":"/dev/ttys001"}]"#) == nil)
    #expect(snapshot(#"[{"window_id":1,"tab_id":1.5,"pane_id":1,"title":"x","tty_name":"/dev/ttys001"}]"#) == nil)
    #expect(snapshot(#"[{"window_id":1,"tab_id":true,"pane_id":1,"title":"x","tty_name":"/dev/ttys001"}]"#) == nil)
    #expect(snapshot(#"[{"window_id":1,"tab_id":1,"pane_id":1,"title":"x","tty_name":"/dev/ttys001"},{"window_id":1,"tab_id":2,"pane_id":1,"title":"y","tty_name":"/dev/ttys002"}]"#) == nil)
    #expect(snapshot(#"[{"window_id":1,"tab_id":1,"pane_id":1,"title":"x","tty_name":"/dev/console"}]"#) == nil)
    #expect(snapshot(#"[{"window_id":1,"tab_id":1,"pane_id":1,"title":7,"tty_name":"/dev/ttys001"}]"#) == nil)
    #expect(snapshot(#"[{"tab_id":1,"pane_id":1,"title":"x","tty_name":"/dev/ttys001"}]"#) == nil)
    #expect(snapshot(#"[3]"#) == nil)
    let many = (0...WezTermSnapshot.maximumPanes).map {
        #"{"window_id":1,"tab_id":\#($0),"pane_id":\#($0),"title":"x","tty_name":"/dev/ttys001"}"#
    }.joined(separator: ",")
    #expect(snapshot("[\(many)]") == nil)
    #expect(WezTermSnapshot.parse(Data(count: WezTermSnapshot.maximumReplySize + 1)) == nil)
}

@Test func wezTermPaneWithoutATTYStillCountsForTitlesButAnOverlongTitleIsNoTitle() throws {
    let long = String(repeating: "a", count: WezTermSnapshot.maximumTitleLength + 1)
    let parsed = try #require(snapshot(#"""
    [{"window_id":1,"tab_id":1,"pane_id":7,"title":"\#(codexTitle)","tty_name":null},
     {"window_id":1,"tab_id":2,"pane_id":8,"title":"\#(long)","tty_name":"ttys003"}]
    """#))
    #expect(parsed.inventory == .tabs([
        TerminalTab(tabID: "7", tty: nil, title: codexTitle, paneCount: 1),
        tab(8, "/dev/ttys003", nil),
    ]))
}

@Test func wezTermReadsProcessesOnlyForTitledCodexPanesAndClaudeTTYs() throws {
    let parsed = try #require(snapshot())
    #expect(parsed.ttysToRead(codexTitles: [codexTitle], claudeTTYs: ["ttys018"])
        == ["/dev/ttys017", "/dev/ttys019", "/dev/ttys018"])
    #expect(parsed.ttysToRead(codexTitles: [], claudeTTYs: []).isEmpty)
    // Read beside another host, every pane titled with any shortened Codex identifier is read.
    #expect(parsed.ttysToRead(claudeTTYs: []) == ["/dev/ttys017", "/dev/ttys019"])
}

// MARK: - Binding (ADR 0013)

private let wezTermOn = TerminalHostSwitches(enabled: [.wezTerm])
private let codexPS: [String: [TerminalProcess]] = [
    "/dev/ttys017": [TerminalProcess(pid: 501, name: "codex", foreground: true)],
    "/dev/ttys019": [TerminalProcess(pid: 502, name: "sleep", foreground: true)],
    "/dev/ttys018": [TerminalProcess(pid: 601, name: "claude", foreground: true),
                     TerminalProcess(pid: 602, name: "caffeinate", foreground: true)],
]

private func codexBinding(_ inventory: TerminalHostInventory, second: TerminalHostInventory? = nil,
                          switches: TerminalHostSwitches = wezTermOn,
                          others: [TerminalHost: TerminalHostInventory] = [:]) -> TerminalTabBinding {
    var first = others
    first[.wezTerm] = inventory
    var again = others
    again[.wezTerm] = second ?? inventory
    return TerminalTabBindingRules.codex(sessionID: codexSession, liveness: .live, liveSessions: [codexSession],
                                         switches: switches, inventories: first, processes: codexPS, secondRead: again)
}

@Test func aCodexPaneBindsByTitleAndItsOneForegroundCodexWhileTheDecoyBindsNothing() throws {
    let withDecoy = try #require(snapshot()).inventory
    // The proof's decoy carries the same title over `sleep`: it is no candidate, so the real pane binds (#268).
    let bound = TerminalTabBinding.bound(TerminalTabTarget(host: .wezTerm, tabID: "1", tty: "/dev/ttys017"))
    #expect(codexBinding(withDecoy) == bound)
    let real = try #require(snapshot(listJSON(decoy: false))).inventory
    #expect(codexBinding(real) == bound)
}

@Test func aCodexTitleOverAnotherProgramNeverBinds() throws {
    // Only the decoy is left: its tty runs `sleep`, not `codex`, so nothing carries the title.
    let decoyOnly = try #require(snapshot("[" + paneJSON(window: 1, tab: 3, pane: 3, title: codexTitle, tty: "/dev/ttys019") + "]"))
    #expect(codexBinding(decoyOnly.inventory) == .unavailable(.titleNotFound))
}

@Test func aSplitWezTermTabNeverBindsAndASecondReadMustAgree() throws {
    let split = try #require(snapshot("[" + paneJSON(window: 1, tab: 1, pane: 1, title: codexTitle, tty: "/dev/ttys017") + ","
                                      + paneJSON(window: 1, tab: 1, pane: 9, title: "zsh", tty: "/dev/ttys030") + "]"))
    #expect(codexBinding(split.inventory) == .unavailable(.split))
    let real = try #require(snapshot(listJSON(decoy: false))).inventory
    let renamed = try #require(snapshot(listJSON(decoy: false).replacingOccurrences(of: codexTitle, with: "renamed"))).inventory
    #expect(codexBinding(real, second: renamed) == .unavailable(.titleChanged))
}

@Test func anUnreadableOrSwitchedOffWezTermDecidesNothingAndAnotherHostsTitleCounts() throws {
    let real = try #require(snapshot(listJSON(decoy: false))).inventory
    #expect(codexBinding(.unreadable) == .unavailable(.hostUnreadable(.wezTerm)))
    // Switched off: never read, whatever was passed.
    #expect(codexBinding(real, switches: TerminalHostSwitches()) == .unavailable(.titleNotFound))
    // Terminal.app on beside it with the same title: two candidates across hosts.
    let both = TerminalHostSwitches(enabled: [.wezTerm, .terminalApp])
    let terminal = TerminalHostInventory.tabs([TerminalTab(tabID: "9882", tty: "/dev/ttys005", title: codexTitle, paneCount: 1)])
    #expect(codexBinding(real, switches: both, others: [.terminalApp: terminal]) == .unavailable(.duplicateTitles(2)))
}

@Test func aClaudePaneBindsByItsRegisteredProcessTTYEvenWhenAnIconTitleHidesHerdlysTitle() throws {
    // The live proof: an OSC 1 icon title wins over Herdly's OSC 2 Claude title.
    let masked = try #require(snapshot(listJSON().replacingOccurrences(of: claudeTitle, with: "ICON-title"))).inventory
    let registered = ClaudeSessionRegistry.Process(pid: 601, procStart: "start")
    let observed = TerminalProcessObservation(pid: 601, procStart: "start", tty: "ttys018")
    let binding = TerminalTabBindingRules.claude(sessionID: claudeSessionID, liveness: .live, process: .registered(registered),
                                                 observed: observed, switches: wezTermOn, inventories: [.wezTerm: masked],
                                                 processes: codexPS)
    #expect(binding == .bound(TerminalTabTarget(host: .wezTerm, tabID: "2", tty: "/dev/ttys018")))
}

@Test func listClientsGivesTheOneClientsFocusedPaneOnly() throws {
    #expect(focusedOn(6).focusedPane == 6)
    let two = #"[{"pid":1,"focused_pane_id":1},{"pid":2,"focused_pane_id":6}]"#
    #expect(try #require(clients(two)).focusedPane == nil)
    #expect(try #require(clients("[]")).focusedPane == nil)
    #expect(try #require(clients(#"[{"pid":1,"focused_pane_id":null}]"#)).focusedPane == nil)
    #expect(clients(#"[{"pid":1,"focused_pane_id":"6"}]"#) == nil)
    #expect(clients(#"{"clients":[]}"#) == nil)
    #expect(clients(#"[7]"#) == nil)
}

// MARK: - Binary and socket

@Test func wezTermRunsOnlyFromFixedPathsAgainstOneSocketPinnedInItsEnvironment() {
    #expect(WezTermCLI.binaryCandidates(home: "/Users/u") == [
        "/Applications/WezTerm.app/Contents/MacOS/wezterm",
        "/Users/u/Applications/WezTerm.app/Contents/MacOS/wezterm",
    ])
    #expect(WezTermCLI.socketDirectory(home: "/Users/u") == "/Users/u/.local/share/wezterm")
    // No PATH lookup and no inherited WEZTERM_UNIX_SOCKET: the trusted socket is the only one it can use.
    #expect(WezTermCLI.environment(home: "/Users/u", socket: "/Users/u/.local/share/wezterm/gui-sock-38165") == [
        "HOME": "/Users/u", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "WEZTERM_UNIX_SOCKET": "/Users/u/.local/share/wezterm/gui-sock-38165",
    ])
    #expect(WezTermCLI.list == ["cli", "--no-auto-start", "list", "--format", "json"])
    #expect(WezTermCLI.listClients == ["cli", "--no-auto-start", "list-clients", "--format", "json"])
    #expect(WezTermCLI.activate(pane: "6") == ["cli", "--no-auto-start", "activate-pane", "--pane-id", "6"])
    #expect(WezTermCLI.activate(pane: "6; rm") == nil)
}

@Test func theGUISocketIsTheOneWhoseProcessIsARunningWezTerm() {
    let live = WezTermSocketCandidate(name: "gui-sock-38165", runsWezTerm: true)
    let stale = WezTermSocketCandidate(name: "gui-sock-111", runsWezTerm: false)
    #expect(WezTermSocketCandidate.pid(fromName: "gui-sock-38165") == 38165)
    #expect(WezTermSocketCandidate.pid(fromName: "sock") == nil)
    #expect(WezTermSocketCandidate.pid(fromName: "gui-sock-") == nil)
    #expect(WezTermSocketCandidate.pid(fromName: "gui-sock-12a") == nil)
    #expect(WezTermSocket.choose([live, stale, WezTermSocketCandidate(name: "sock", runsWezTerm: true)]) == .success("gui-sock-38165"))
    #expect(WezTermSocket.choose([stale]) == .failure(.socketMissing))
    #expect(WezTermSocket.choose([live, WezTermSocketCandidate(name: "gui-sock-2", runsWezTerm: true)]) == .failure(.severalInstances))
}

@Test func theSocketIsTrustedOnlyWhenItIsOwnerOnly() {
    #expect(WezTermSocket.trust(exists: true, isSocket: true, owner: 501, mode: 0o700, me: 501) == nil)
    #expect(WezTermSocket.trust(exists: true, isSocket: true, owner: 501, mode: 0o600, me: 501) == nil)
    // Readable or writable by the group or others, another owner, not a socket, missing: untrusted.
    #expect(WezTermSocket.trust(exists: true, isSocket: true, owner: 501, mode: 0o755, me: 501) == .socketUntrusted)
    #expect(WezTermSocket.trust(exists: true, isSocket: true, owner: 501, mode: 0o704, me: 501) == .socketUntrusted)
    #expect(WezTermSocket.trust(exists: true, isSocket: true, owner: 0, mode: 0o700, me: 501) == .socketUntrusted)
    #expect(WezTermSocket.trust(exists: true, isSocket: false, owner: 501, mode: 0o700, me: 501) == .socketUntrusted)
    #expect(WezTermSocket.trust(exists: false, isSocket: false, owner: 501, mode: 0, me: 501) == .socketMissing)
}

@Test func anUntrustedSocketOrAFailedRunIsAnUnreadableHostNeverAnEmptyOne() {
    let ok = WezTermCommandResult.exited(status: 0, stdout: Data(listJSON().utf8), stderr: "")
    guard case .snapshot = WezTermRead.list(ok) else { Issue.record("expected a snapshot"); return }
    #expect(WezTermRead.list(.notRun(.socketUntrusted)) == .unreadable(.socketUntrusted))
    #expect(WezTermRead.list(.notRun(.binaryNotFound)) == .unreadable(.binaryNotFound))
    #expect(WezTermRead.list(.timedOut) == .unreadable(.timedOut))
    #expect(WezTermRead.list(.exited(status: 1, stdout: Data(), stderr: "failed to connect")) == .unreadable(.commandFailed))
    #expect(WezTermRead.list(.exited(status: 0, stdout: Data("nope".utf8), stderr: "")) == .unreadable(.malformedReply))
    #expect(WezTermRead.notRunning.inventory == .notRunning)
    #expect(WezTermRead.unreadable(.socketUntrusted).inventory == .unreadable)
}

// MARK: - Visible (ADR 0016)

@Test func aPaneIsVisibleOnlyWhileWezTermIsFrontmostAndTheOneClientFocusesIt() throws {
    let parsed = try #require(snapshot())
    let focused6 = focusedOn(6)
    #expect(TerminalVisibility.wezTerm(parsed, clients: focused6, frontmost: .wezTerm) == .visible("6"))
    // `focused_pane_id` keeps its last value while another app is in front (live proof): nothing visible.
    #expect(TerminalVisibility.wezTerm(parsed, clients: focused6, frontmost: .terminalApp) == .nothing)
    #expect(TerminalVisibility.wezTerm(parsed, clients: focused6, frontmost: nil) == .nothing)
    // A focused pane missing from the list shows nothing Herdly knows.
    #expect(TerminalVisibility.wezTerm(parsed, clients: focusedOn(40), frontmost: .wezTerm) == .nothing)
    // Several clients, or a read that failed: unknown, so no visit and no dwell counts.
    let two = try #require(clients(#"[{"pid":1,"focused_pane_id":1},{"pid":2,"focused_pane_id":6}]"#))
    #expect(TerminalVisibility.wezTerm(parsed, clients: two, frontmost: .wezTerm) == .unknown)
    #expect(TerminalVisibility.wezTerm(nil, clients: focused6, frontmost: .wezTerm) == .unknown)
    #expect(TerminalVisibility.wezTerm(parsed, clients: nil, frontmost: .wezTerm) == .unknown)
}

// MARK: - Open (ADR 0015, ADR 0016)

private let codexTarget = TerminalTabTarget(host: .wezTerm, tabID: "1", tty: "/dev/ttys017")

@Test func openPlansAnActivateOnlyForATargetInTheFocusedWindow() throws {
    let parsed = try #require(snapshot(listJSON(decoy: false)))
    // The proof: pane 1 is in window 1; the client focused pane 2 there, so the target's window is in front.
    let plan = WezTermOpen.plan(.exact(codexTarget), codexTitle: codexTitle, snapshot: parsed,
                                clients: focusedOn(2))
    #expect(plan == .success(WezTermOpenPlan(target: codexTarget, title: codexTitle)))
    // A tab in a window that isn't in front (the client focused pane 6, in window 2) falls back:
    // activate-pane would change that window's tab where Herdly cannot verify it.
    #expect(WezTermOpen.plan(.exact(codexTarget), codexTitle: codexTitle, snapshot: parsed,
                             clients: focusedOn(6))
        == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
    // Extra clients, or none: no front window can be named, so it falls back too.
    #expect(WezTermOpen.plan(.exact(codexTarget), codexTitle: codexTitle, snapshot: parsed,
                             clients: WezTermClients(focusedPaneIDs: [1, 1]))
        == .failure(.fallBack(.unsupportedLayout, candidates: 1)))
    // list-clients could not be read: the host is unreadable.
    #expect(WezTermOpen.plan(.exact(codexTarget), codexTitle: codexTitle, snapshot: parsed, clients: nil)
        == .failure(.unavailable(.hostUnreadable(.wezTerm))))
}

@Test func openLeavesOtherHostsTargetsAndMissesToTheirResolution() throws {
    let parsed = try #require(snapshot(listJSON(decoy: false)))
    let focus = focusedOn(1)
    let elsewhere = TerminalTabTarget(host: .iTerm2, tabID: "GUID", tty: "/dev/ttys005")
    #expect(WezTermOpen.plan(.exact(elsewhere), codexTitle: codexTitle, snapshot: parsed, clients: focus)
        == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
    #expect(WezTermOpen.plan(.miss(.fallBack(.noUniqueTarget, candidates: 2)), codexTitle: codexTitle, snapshot: parsed, clients: focus)
        == .failure(.fallBack(.noUniqueTarget, candidates: 2)))
    #expect(WezTermOpen.plan(.exact(TerminalTabTarget(host: .wezTerm, tabID: "77", tty: "/dev/ttys017")),
                             codexTitle: codexTitle, snapshot: parsed, clients: focus) == .failure(.unavailable(.sessionEnded)))
}

@Test func activatePaneOutcomesMapToADR0016Failures() {
    #expect(WezTermOpen.activated(.exited(status: 0, stdout: Data(), stderr: "")) == nil)
    // The proof's unknown pane: "no such pane", nothing activated: the session's pane is gone.
    let gone = WezTermCommandResult.exited(status: 1, stdout: Data(),
                                           stderr: #"ERROR wezterm > unexpected response Ok(ErrorResponse(ErrorResponse { reason: "Error: no such pane 1006" })); terminating"#)
    #expect(WezTermOpen.activated(gone) == .unavailable(.sessionEnded))
    #expect(WezTermOpen.activated(.notRun(.socketUntrusted)) == .unavailable(.hostUnreadable(.wezTerm)))
    #expect(WezTermOpen.activated(.exited(status: 1, stdout: Data(), stderr: "other")) == .fallBack(.notVerified, candidates: 1))
    #expect(WezTermOpen.activated(.timedOut) == .fallBack(.notVerified, candidates: 1))
}

@Test func openVerifiesTheTargetVisibleUnsplitOnItsTTYAndStillTitled() throws {
    let plan = WezTermOpenPlan(target: codexTarget, title: codexTitle)
    let after = try #require(snapshot(listJSON(decoy: false)))
    let focused1 = focusedOn(1)
    #expect(WezTermOpen.verify(plan, after: after, clients: focused1, frontmost: .wezTerm) == nil)
    // Another app in front, another pane focused, a renamed or newly split tab: falls back, adding nothing.
    #expect(WezTermOpen.verify(plan, after: after, clients: focused1, frontmost: .terminalApp) == .fallBack(.notVerified, candidates: 1))
    #expect(WezTermOpen.verify(plan, after: after, clients: focusedOn(2), frontmost: .wezTerm)
        == .fallBack(.notVerified, candidates: 1))
    let renamed = try #require(snapshot(listJSON(decoy: false).replacingOccurrences(of: codexTitle, with: "x")))
    #expect(WezTermOpen.verify(plan, after: renamed, clients: focused1, frontmost: .wezTerm) == .fallBack(.notVerified, candidates: 1))
    let split = try #require(snapshot("[" + paneJSON(window: 1, tab: 1, pane: 1, title: codexTitle, tty: "/dev/ttys017") + ","
                                      + paneJSON(window: 1, tab: 1, pane: 9, title: "zsh", tty: "/dev/ttys030") + "]"))
    #expect(WezTermOpen.verify(plan, after: split, clients: focused1, frontmost: .wezTerm) == .fallBack(.notVerified, candidates: 1))
    #expect(WezTermOpen.verify(plan, after: nil, clients: focused1, frontmost: .wezTerm) == .fallBack(.notVerified, candidates: 1))
    // Claude's plan carries no title: a rename voids nothing.
    let claude = WezTermOpenPlan(target: codexTarget, title: nil)
    #expect(WezTermOpen.verify(claude, after: renamed, clients: focused1, frontmost: .wezTerm) == nil)
}

@MainActor
@Test func openRunsEachStepOnceAndSkipsActivateForATargetOutsideTheFrontWindow() async throws {
    let parsed = try #require(snapshot(listJSON(decoy: false)))
    var activations: [String] = []
    let opened = await WezTermOpen.run(
        now: { 100 },
        revalidate: { _ in WezTermOpen.plan(.exact(codexTarget), codexTitle: codexTitle, snapshot: parsed,
                                            clients: WezTermClients(focusedPaneIDs: [2])) },
        activate: { plan in activations.append(plan.target.tabID); return .exited(status: 0, stdout: Data(), stderr: "") },
        verifyRead: { (parsed, WezTermClients(focusedPaneIDs: [1]), .wezTerm) })
    #expect(opened == .opened(WezTermOpenPlan(target: codexTarget, title: codexTitle), preOpenAt: 100))
    #expect(activations == ["1"])

    activations = []
    let fellBack = await WezTermOpen.run(
        now: { 100 },
        revalidate: { _ in WezTermOpen.plan(.exact(codexTarget), codexTitle: codexTitle, snapshot: parsed,
                                            clients: WezTermClients(focusedPaneIDs: [6])) },
        activate: { plan in activations.append(plan.target.tabID); return .exited(status: 0, stdout: Data(), stderr: "") },
        verifyRead: { (parsed, WezTermClients(focusedPaneIDs: [1]), .wezTerm) })
    #expect(fellBack == .failed(.fallBack(.unsupportedLayout, candidates: 1), at: .revalidate))
    #expect(activations.isEmpty)
}

// MARK: - Typed input (ADR 0017)

private let pane1 = TypedInputPane(host: .wezTerm, paneID: "1", tty: "/dev/ttys017")

@Test func wezTermTypesRepliesAndQuestionDigitsIntoTheBoundPane() {
    #expect(TerminalHost.wezTerm.typesReplies)
    // Proven live in WezTerm's acceptance run (#245): the digit alone commits Codex's answer.
    #expect(WezTermInput.questionDigitsProvenLive)
    #expect(TerminalHost.wezTerm.typesQuestionDigits)
    #expect(TerminalReplyRoute.from(.bound(codexTarget)) == .pane(pane1))
    #expect(TerminalReplyRoute.from(.unavailable(.split)) == .unreachable)
}

@Test func repliesGoAsNoPasteSendTextToThePaneIdWithCodexsCRSeparate() {
    // Codex: text, then a CR alone a second later; Claude: text and CR in one send (live proof).
    #expect(TypedReplyWrites.plan(agent: .codex, text: "go on").map(WezTermInput.payload) == ["go on", "\r"])
    #expect(TypedReplyWrites.plan(agent: .claude, text: "go on").map(WezTermInput.payload) == ["go on\r"])
    #expect(WezTermInput.send("-h", pane: "1")
        == ["cli", "--no-auto-start", "send-text", "--no-paste", "--pane-id", "1", "--", "-h"])
    #expect(WezTermInput.send("2", pane: "%1") == nil)
}

@Test func aSendThatMayHaveTypedCountsAsSentAndANoSuchPaneDoesNot() {
    #expect(WezTermInput.delivery(.exited(status: 0, stdout: Data(), stderr: "")) == .written)
    #expect(WezTermInput.delivery(.exited(status: 1, stdout: Data(), stderr: "Error: no such pane 1006")) == .notWritten)
    #expect(WezTermInput.delivery(.notRun(.socketUntrusted)) == .notWritten)
    #expect(WezTermInput.delivery(.exited(status: 1, stdout: Data(), stderr: "connection reset")) == .possiblyWritten)
    #expect(WezTermInput.delivery(.timedOut) == .possiblyWritten)
}

@MainActor
@Test func aCodexReplyIsCheckedFreshBeforeEachSendAndNeverPressesEnterLater() async {
    var sent: [[String]] = []
    let run = await TypedReplySequence.run(
        writes: TypedReplyWrites.plan(agent: .codex, text: "go on"),
        check: { nil },
        write: { write in
            sent.append(WezTermInput.send(WezTermInput.payload(write), pane: pane1.paneID) ?? [])
            return sent.count == 1 ? .written : WezTermInput.delivery(.exited(status: 1, stdout: Data(), stderr: "no such pane 1"))
        },
        pause: { _ in })
    #expect(sent.map(\.last) == ["go on", "\r"])
    // The text went in but its CR did not: the card says the text may be waiting; nothing is retried.
    #expect(run == .sentTextOnly)
}

// MARK: - Codex question digits (ADR 0017, gated)

private let question = AttentionQuestion(
    source: .cli, session: UUID(uuidString: codexSession)!, turn: UUID(uuidString: "01A129BD-0C51-7F33-9EBC-4E44F91DF22C")!,
    callID: "call_1", arrivedAt: 100,
    prompts: [QuestionPrompt(id: "q1", header: "Shape", question: "Which?", options: ["Flexible", "Same"])])

private var pendingEvidence: ReminderReader.RolloutEvidence {
    var evidence = ReminderReader.RolloutEvidence()
    evidence.pendingQuestions = [question]
    return evidence
}

@Test func aWezTermQuestionUsesItsPaneByDefaultAndIsAnsweredInCodexWithTheGateOff() {
    #expect(QuestionRelayRouting.route(for: question, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .wezTerm) == .terminalRelay)
    let route = QuestionRelayRouting.route(for: question, book: AppServerQuestionBook(), daemonConnected: false,
                                           ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                           terminalHost: .wezTerm, typesDigits: { _ in false })
    #expect(route == .relayUnavailable(.noQuestionKeys(.wezTerm)))
    #expect(HerdrQuestionRelayUnavailable.noQuestionKeys(.wezTerm).message == "Answer this in Codex.")
}

@Test func withTheGateOnAWezTermQuestionUsesTheBoundPanesKeyUnlessAnotherHostIsUnread() {
    let on: (TerminalHost) -> Bool = { $0 == .wezTerm }
    #expect(QuestionRelayRouting.route(for: question, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .wezTerm, typesDigits: on) == .terminalRelay)
    #expect(QuestionRelayRouting.route(for: question, book: AppServerQuestionBook(), daemonConnected: false,
                                       ledger: QuestionRelayLedger(), progress: nil, herdr: .notInHerdr,
                                       terminalHost: .wezTerm, unreadHost: .iTerm2, typesDigits: on)
        == .relayUnavailable(.otherHostUnreadable(.iTerm2)))
    // Once a key left by the pane route, the call stays there.
    var ledger = QuestionRelayLedger()
    let spent = ledger.spend(question.id, question: 0, route: .terminal(pane1))
    #expect(spent)
    #expect(QuestionRelayRouting.route(for: question, book: AppServerQuestionBook(), daemonConnected: true,
                                       ledger: ledger, progress: nil, herdr: .notInHerdr) == .terminalRelay)
}

@Test func aDigitIsSpentOnTheClickedPaneBeforeAnythingIsSentAndOnlyOnce() throws {
    let start = try TerminalQuestionKeys.start(current: question, progress: QuestionAnswerProgress(call: question.id),
                                               ledger: QuestionRelayLedger(), pane: pane1, question: 0, option: 1).get()
    #expect(start.key == "2")
    #expect(start.pane == pane1)
    #expect(start.ledger.keyRoute(for: question.id) == .terminal(pane1))
    #expect(TerminalQuestionKeys.start(current: question, progress: start.progress, ledger: start.ledger, pane: pane1,
                                       question: 0, option: 1) != .success(start))
    #expect(TerminalQuestionKeys.start(current: question, progress: QuestionAnswerProgress(call: question.id),
                                       ledger: QuestionRelayLedger(), pane: nil, question: 0, option: 0) == .failure(.noPane))
    #expect(TerminalQuestionKeys.start(current: nil, progress: QuestionAnswerProgress(call: question.id),
                                       ledger: QuestionRelayLedger(), pane: pane1, question: 0, option: 0)
        == .failure(.policy(.notInQueue)))
}

@Test func theDigitGoesOnlyAfterAFreshBindingOnTheSamePaneAndAPendingRollout() {
    let pending = pendingEvidence
    #expect(TerminalQuestionKeys.preSendCheck(question: question, evidence: pending, route: .pane(pane1), spent: pane1) == nil)
    #expect(TerminalQuestionKeys.preSendCheck(question: question, evidence: pending, route: .unreachable, spent: pane1) == .leftHerdr)
    #expect(TerminalQuestionKeys.preSendCheck(question: question, evidence: pending, route: nil, spent: pane1) == .leftHerdr)
    let other = TypedInputPane(host: .wezTerm, paneID: "3", tty: "/dev/ttys019")
    #expect(TerminalQuestionKeys.preSendCheck(question: question, evidence: pending, route: .pane(other), spent: pane1) == .paneChanged)
    #expect(TerminalQuestionKeys.preSendCheck(question: question, evidence: ReminderReader.RolloutEvidence(), route: .pane(pane1),
                                              spent: pane1) == .rolloutUnreadable)
}

// MARK: - Card and lines (product.md, "Agreed terminal host presentation")

@Test func theWezTermCardIsShownSinceAcceptanceAndHasNoPermissionRow() {
    #expect(TerminalHost.wezTerm.showsCard)
    #expect(TerminalHost.wezTerm.bundleIdentifier == "com.github.wez.wezterm")
    let off = WezTermPresentation.settingsRow(on: false, installed: true, scan: .notRead, inUse: false)
    #expect(off.badge == .off)
    #expect(off.problems.isEmpty)
    #expect(WezTermPresentation.settingsRow(on: true, installed: true, scan: .read, inUse: false).badge == .notInUse)
    #expect(WezTermPresentation.settingsRow(on: true, installed: true, scan: .read, inUse: true)
        == WezTermSettingsRow(badge: .ready, problems: []))
    #expect(WezTermPresentation.settingsRow(on: true, installed: true, scan: .notRunning, inUse: true).badge == .ready)
    // How Open Works… states targeting and replies only, so it cannot go stale when the digit gate opens (#245).
    #expect(WezTermPresentation.howOpenWorks
        == "Herdly returns to unsplit tabs in WezTerm's front window; otherwise Open raises WezTerm. Replies are typed into the exact pane.")
}

@Test func everyWezTermProblemIsItsOwnLine() {
    let missing = WezTermPresentation.settingsRow(on: true, installed: false, scan: .unreadable(.binaryNotFound), inUse: false)
    #expect(missing.badge == .needsAttention)
    #expect(missing.problems == [.notFound])
    #expect(WezTermSettingsProblem.notFound.message == "Herdly can't find WezTerm in /Applications or ~/Applications.")
    let untrusted = WezTermPresentation.settingsRow(on: true, installed: true, scan: .unreadable(.socketUntrusted), inUse: true)
    #expect(untrusted.problems == [.untrustedSocket])
    #expect(WezTermSettingsProblem.untrustedSocket.message
        == "Herdly can't read WezTerm: its socket in ~/.local/share/wezterm isn't private to you.")
    // Several running copies, a timeout or any other failed read is the generic agreed line; the exact
    // reason stays in diagnostics.
    #expect(WezTermPresentation.settingsRow(on: true, installed: true, scan: .unreadable(.severalInstances), inUse: true).problems
        == [.unreadable])
    #expect(WezTermPresentation.settingsRow(on: true, installed: true, scan: .unreadable(.timedOut), inUse: true).problems
        == [.unreadable])
    #expect(WezTermSettingsProblem.unreadable.message == OpenUnavailableReason.hostUnreadable(.wezTerm).cardLine)
    // A switched-off WezTerm says nothing about problems it was never asked about.
    #expect(WezTermPresentation.settingsRow(on: false, installed: false, scan: .notRead, inUse: false).problems.isEmpty)
}

@Test func wezTermNotchLinesComeFromTheSharedReasons() {
    #expect(OpenUnavailableReason.hostUnreadable(.wezTerm).cardLine == "Herdly can't read WezTerm. Check Settings › Terminals.")
    #expect(OpenUnavailableReason.appNotRunning(.wezTerm).cardLine == "WezTerm isn't running.")
    #expect(SessionReplyPolicy.message(for: .terminalUnreachable) == "Herdly can't reach this session's tab. Reply in the session.")
    #expect(HerdrPresentation.keyDestination(for: .terminalRelay).place == "the session's pane")
    // Every other key route names its own place; only the Ghostty relay reads "the Ghostty tab".
    #expect(HerdrPresentation.keyDestination(for: .herdrRelay).place == "the herdr pane")
    #expect(HerdrPresentation.keyDestination(for: .ghosttyRelay).place == "the Ghostty tab")
}

@Test func anUnreadEnabledTerminalAppDoesNotStopAnITerm2TabFromBinding() {
    // ADR 0013, 2026-11-25: an enabled Terminal.app left out of the reads no longer makes every binding
    // "host unreadable" when iTerm2's titled tab runs the one foreground `codex`.
    let switches = TerminalHostSwitches(enabled: [.iTerm2, .terminalApp])
    let iTerm2 = TerminalHostInventory.tabs([TerminalTab(tabID: "GUID", tty: "/dev/ttys017", title: codexTitle, paneCount: 1)])
    func bind(_ inventories: [TerminalHost: TerminalHostInventory]) -> TerminalTabBinding {
        TerminalTabBindingRules.codex(sessionID: codexSession, liveness: .live, liveSessions: [codexSession],
                                      switches: switches, inventories: inventories, processes: codexPS,
                                      secondRead: inventories)
    }
    let bound = TerminalTabBinding.bound(TerminalTabTarget(host: .iTerm2, tabID: "GUID", tty: "/dev/ttys017"))
    #expect(bind([.iTerm2: iTerm2]) == bound)
    #expect(bind([.iTerm2: iTerm2, .terminalApp: .tabs([])]) == bound)
    #expect(bind([.iTerm2: .tabs([])]) == .unavailable(.hostUnreadable(.terminalApp)))
}

// MARK: - Cross-host routes and freshness

@Test func routesFromTwoHostsScansMergeWithAnyNonPaneWinning() {
    let other = TypedInputPane(host: .terminalApp, paneID: "9882", tty: "/dev/ttys005")
    #expect(TerminalReplyRoute.merging(nil, .pane(pane1)) == .pane(pane1))
    #expect(TerminalReplyRoute.merging(.pane(pane1), .pane(pane1)) == .pane(pane1))
    #expect(TerminalReplyRoute.merging(.pane(pane1), .pane(other)) == .unreachable)
    #expect(TerminalReplyRoute.merging(.pane(pane1), .unreachable) == .unreachable)
    #expect(TerminalReplyRoute.merging(.hostCannotType(.iTerm2), .pane(pane1)) == .hostCannotType(.iTerm2))
    #expect(TerminalReplyRoute.merging(nil, nil) == nil)
}

@Test func aGhosttyKeyNeedsAFreshWezTermReadWithoutTheTitle() throws {
    let switches = TerminalHostSwitches(enabled: [.ghostty, .wezTerm])
    #expect(TerminalKeyRelayCheck.hostsToRead(switches: switches) == [.wezTerm])
    let real = try #require(snapshot(listJSON(decoy: false))).inventory
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: codexTitle, processes: [:], switches: switches, fresh: [.wezTerm: real]) == .noQuestionKeys(.wezTerm))
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: "other", processes: [:], switches: switches, fresh: [.wezTerm: real]) == nil)
    #expect(TerminalKeyRelayCheck.ghosttyVeto(title: "other", processes: [:], switches: switches, fresh: [.wezTerm: .unreadable]) == .otherHostUnreadable(.wezTerm))
}

@Test func theCardsVersionComesFromTheBinarysVersionLineOnly() {
    #expect(WezTermCLI.version(Data("wezterm 20240203-110809-5046fc22\n".utf8)) == "20240203-110809-5046fc22")
    #expect(WezTermCLI.version(Data("wezterm\n".utf8)) == nil)
    #expect(WezTermCLI.version(Data("error: no socket\n".utf8)) == nil)
    #expect(WezTermCLI.version(Data("wezterm 1 2\n".utf8)) == nil)
    #expect(WezTermCLI.version(Data(("wezterm " + String(repeating: "1", count: 300)).utf8)) == nil)
    #expect(WezTermCLI.versionEnvironment(home: "/Users/a")["WEZTERM_UNIX_SOCKET"] == nil)
}
