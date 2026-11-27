import Foundation
import Testing
@testable import HerdlyCore

// The Herdr desktop app. Fixtures follow the shape of herdr-core 0.1.22's `terminal.list` reply and Herdr 0.1.16's
// `ls` and `status` (docs/herdr-app-investigation.md): t1 runs Claude, t2 runs Codex and, split beside it in the
// same tab, t4 is a decoy carrying Codex's title over `sleep`; t5 has finished, and `vps/t3` runs on another
// machine. Space S1 tab A shows t1; space S2 tab B shows t2 and t4.

private let codexSession = "01a129bd-a3ec-7dc0-875a-4fac39ec9eaa"
private let codexTitle = "01a129bd-a3ec-7dc0-875a-4fac3..."
private let claudeSessionID = "729984f1-4a2d-4649-b5f3-92212557f4ee"

private let s1 = "sp8c42213c760b7a36d2c86b38d0d646db", s2 = "sp27a7431f7b695f174555110a44ee18f4"
private let tabA = "tbc69b0b505199c69839b3693a0f229858", tabB = "tb7fbe947e4b058577802f632d1992b1bb"
private let p1 = "pcb509e3153fbdf69847435ef7653eba5", p2 = "p001c33e169beee8eeb7d319237b7fc61"
private let p4 = "p753d437b7269af76c84159defbd02bb8"

/// Each terminal's process → tty, as HerdlyApp reads it from the kernel.
private let ttys: [Int32: String] = [24856: "/dev/ttys002", 51902: "ttys004", 58067: "/dev/ttys005"]

private func terminalJSON(_ address: String, pid: Int32?, title: String, state: String = "live",
                          space: String? = nil, tab: String? = nil) -> String {
    var labels: [String] = []
    if let space { labels.append(#""herdr.space":"\#(space)""#) }
    if let tab { labels.append(#""herdr.tab":"\#(tab)""#) }
    let pidField = pid.map(String.init) ?? "null"
    return #"{"address":"\#(address)","argv":["/bin/zsh","-l"],"cols":146,"cwd":"/Users/u","identity":"ghostty","#
        + #""labels":{\#(labels.joined(separator: ","))},"pid":\#(pidField),"state":"\#(state)","title":"\#(title)","turn":0}"#
}

private let rows = [
    terminalJSON("t1", pid: 24856, title: "", space: s1, tab: tabA),
    terminalJSON("t2", pid: 51902, title: codexTitle, space: s2, tab: tabB),
    terminalJSON("t4", pid: 58067, title: codexTitle, space: s2, tab: tabB),
    terminalJSON("t5", pid: nil, title: "", state: "finished"),
    terminalJSON("vps/t3", pid: 99, title: "remote"),
]

private func listReply(_ terminals: [String] = rows, id: String = "r1") -> String {
    #"{"id":"\#(id)","jsonrpc":"2.0","result":{"hidden_finished":0,"machines":[],"terminals":["#
        + terminals.joined(separator: ",") + "]}}"
}

private func snapshot(_ json: String = listReply(), id: String = "r1") -> HerdrAppSnapshot? {
    HerdrAppSnapshot.parse(Data(json.utf8), id: id) { ttys[$0] }
}

private let lsJSON = """
{"spaces":[{"id":"\(s1)","name":"myproject","machine":null,"active":true,"tabs":[{"id":"\(tabA)","name":"1","active":true,
"terminals":[{"terminal":"t1","pane":"\(p1)","status":null,"sub_agents":[]}]}]},
{"id":"\(s2)","name":"herdly","machine":null,"active":false,"tabs":[{"id":"\(tabB)","name":"1","active":true,
"terminals":[{"terminal":"t2","pane":"\(p2)","sub_agents":[]},{"terminal":"t4","pane":"\(p4)","sub_agents":[]},
{"terminal":"t9","pane":null,"sub_agents":[]}]}]}],"recent":[]}
"""

private func statusJSON(space: String = s1, tab: String = tabA, pane: String = p1) -> String {
    #"{"zoom":1.0,"space":"\#(space)","tab":"\#(tab)","focused_pane":"\#(pane)","layout":"main","agent":null,"floats":{},"overlays":[],"errors":[]}"#
}

private func window(space: String = s1, tab: String = tabA, pane: String = p1) -> HerdrAppWindow? {
    HerdrAppWindow.parse(ls: Data(lsJSON.utf8), status: Data(statusJSON(space: space, tab: tab, pane: pane).utf8))
}

private let herdrAppOn = TerminalHostSwitches(enabled: [.herdrApp])

private let processes: [String: [TerminalProcess]] = [
    "/dev/ttys004": [TerminalProcess(pid: 51990, name: "codex", foreground: true)],
    "/dev/ttys005": [TerminalProcess(pid: 58143, name: "sleep", foreground: true)],
    "/dev/ttys002": [TerminalProcess(pid: 51973, name: "claude", foreground: true)],
]

// MARK: - Inventory

@Test func herdrAppInventoryListsEveryLiveLocalTerminalAsItsOwnOnePaneTab() throws {
    let parsed = try #require(snapshot())
    // t2 and t4 share a tab, yet each has its own pty and is focused exactly. The finished terminal and the other
    // machine's terminal are left out.
    #expect(parsed.inventory == .tabs([
        TerminalTab(tabID: "t1", tty: "/dev/ttys002", title: nil, paneCount: 1),
        TerminalTab(tabID: "t2", tty: "/dev/ttys004", title: codexTitle, paneCount: 1),
        TerminalTab(tabID: "t4", tty: "/dev/ttys005", title: codexTitle, paneCount: 1),
    ]))
    #expect(parsed.terminal("t2")?.spaceID == s2)
    #expect(parsed.terminal("t2")?.tabID == tabB)
    #expect(try #require(snapshot(listReply([])).map(\.inventory)) == .tabs([]))
}

@Test func herdrAppInventoryRefusesMalformedOrForeignReplies() {
    #expect(snapshot("not json") == nil)
    // Another request's reply, or the core's error.
    #expect(snapshot(listReply(id: "r2")) == nil)
    #expect(snapshot(#"{"id":"r1","jsonrpc":"2.0","error":{"code":-32000,"data":{"kind":"unavailable"},"message":"x"}}"#) == nil)
    // A duplicate address, a bad address, a pid of the wrong type, a title of the wrong type, no state.
    #expect(snapshot(listReply().replacingOccurrences(of: #""address":"t4""#, with: #""address":"t2""#)) == nil)
    #expect(snapshot(listReply().replacingOccurrences(of: #""address":"t4""#, with: #""address":"x-4""#)) == nil)
    #expect(snapshot(listReply().replacingOccurrences(of: #""pid":51902"#, with: #""pid":"51902""#)) == nil)
    #expect(snapshot(listReply().replacingOccurrences(of: #""title":"","#, with: #""title":7,"#)) == nil)
    #expect(snapshot(listReply().replacingOccurrences(of: #""state":"live","#, with: "")) == nil)
    #expect(snapshot(String(repeating: " ", count: HerdrAppSnapshot.maximumReplySize + 1)) == nil)
    #expect(HerdrAppRead.inventory(.reply(Data(#"{"id":"r1","error":{"data":{"kind":"x"}}}"#.utf8)), id: "r1") { _ in nil }
        == .unreadable(.commandFailed))
    #expect(HerdrAppRead.inventory(.reply(Data("{}".utf8)), id: "r1") { _ in nil } == .unreadable(.malformedReply))
    #expect(HerdrAppRead.inventory(.notRunning, id: "r1") { _ in nil } == .notRunning)
    #expect(HerdrAppRead.inventory(.failed(.timedOut), id: "r1") { _ in nil } == .unreadable(.timedOut))
}

@Test func herdrAppReadsPSOnlyForTitledCodexTerminalsAndClaudeTTYs() throws {
    let parsed = try #require(snapshot())
    #expect(parsed.ttysToRead(codexTitles: [codexTitle], claudeTTYs: []) == ["/dev/ttys004", "/dev/ttys005"])
    #expect(parsed.ttysToRead(codexTitles: [], claudeTTYs: ["ttys002"]) == ["/dev/ttys002"])
}

// MARK: - Binding (ADR 0013)

@Test func aCodexHerdrTerminalBindsByTitleAndForegroundCodexWhileTheSplitDecoyDoesNotStopIt() throws {
    let inventory = try #require(snapshot()).inventory
    let binding = TerminalTabBindingRules.codex(sessionID: codexSession, liveness: .live, liveSessions: [codexSession],
                                                switches: herdrAppOn, inventories: [.herdrApp: inventory],
                                                processes: processes, secondRead: [.herdrApp: inventory])
    #expect(binding == .bound(TerminalTabTarget(host: .herdrApp, tabID: "t2", tty: "/dev/ttys004")))
}

@Test func aClaudeHerdrTerminalBindsByItsRegisteredProcessTTY() throws {
    let inventory = try #require(snapshot()).inventory
    let registered = ClaudeSessionRegistry.Process(pid: 51973, procStart: "start")
    let observed = TerminalProcessObservation(pid: 51973, procStart: "start", tty: "ttys002")
    let binding = TerminalTabBindingRules.claude(sessionID: claudeSessionID, liveness: .live, process: .registered(registered),
                                                 observed: observed, switches: herdrAppOn,
                                                 inventories: [.herdrApp: inventory], processes: processes)
    #expect(binding == .bound(TerminalTabTarget(host: .herdrApp, tabID: "t1", tty: "/dev/ttys002")))
    // Bound in Herdr, a reply is typed there.
    #expect(TerminalReplyRoute.from(binding)
        == .pane(TypedInputPane(host: .herdrApp, paneID: "t1", tty: "/dev/ttys002")))
}

@Test func anUnreadableHerdrAppLeavesEverySessionItCouldHoldUnavailable() {
    let binding = TerminalTabBindingRules.codex(sessionID: codexSession, liveness: .live, liveSessions: [codexSession],
                                                switches: herdrAppOn, inventories: [.herdrApp: .unreadable], processes: [:],
                                                secondRead: [.herdrApp: .unreadable])
    #expect(binding == .unavailable(.hostUnreadable(.herdrApp)))
}

// MARK: - Window and visible

@Test func herdrAppWindowNamesTheFocusedPanesTerminalInTheShownTab() throws {
    #expect(try #require(window()).shownTerminal == "t1")
    #expect(try #require(window(space: s2, tab: tabB, pane: p4)).shownTerminal == "t4")
    // A focused pane outside the shown tab, or no focused pane, shows nothing.
    #expect(try #require(window(space: s1, tab: tabA, pane: p2)).shownTerminal == nil)
    let none = HerdrAppWindow.parse(ls: Data(lsJSON.utf8),
                                    status: Data(#"{"space":null,"tab":null,"focused_pane":null}"#.utf8))
    #expect(try #require(none).shownTerminal == nil)
    // A paneless terminal (t9) is skipped; a duplicate pane, a bad id or a non-JSON status is refused.
    #expect(try #require(window()).panes.count == 3)
    #expect(HerdrAppWindow.parse(ls: Data(lsJSON.replacingOccurrences(of: p4, with: p2).utf8),
                                 status: Data(statusJSON().utf8)) == nil)
    #expect(HerdrAppWindow.parse(ls: Data(lsJSON.replacingOccurrences(of: s1, with: "space-1").utf8),
                                 status: Data(statusJSON().utf8)) == nil)
    #expect(HerdrAppWindow.parse(ls: Data(lsJSON.utf8), status: Data("nope".utf8)) == nil)
    #expect(HerdrAppWindow.parse(ls: Data(lsJSON.utf8), status: Data(#"{"space":7}"#.utf8)) == nil)
}

@Test func herdrAppWindowReadsTellAClosedWindowFromAnUnreadableOne() {
    let ls = HerdrAppCommandResult.exited(status: 0, stdout: Data(lsJSON.utf8), stderr: "")
    let status = HerdrAppCommandResult.exited(status: 0, stdout: Data(statusJSON().utf8), stderr: "")
    #expect(HerdrAppWindowRead.from(ls: ls, status: status).window?.shownTerminal == "t1")
    #expect(HerdrAppWindowRead.from(ls: .notRun(.noWindow), status: .notRun(.noWindow)) == .closed)
    #expect(HerdrAppWindowRead.from(ls: ls, status: .timedOut) == .unreadable)
    #expect(HerdrAppWindowRead.from(ls: .notRun(.appNotFound), status: status) == .unreadable)
}

@Test func aHerdrTerminalIsVisibleOnlyWithHerdrFrontmostAndItsPaneFocusedInTheShownTab() throws {
    let parsed = try #require(snapshot())
    let shown = HerdrAppWindowRead.window(try #require(window()))
    #expect(TerminalVisibility.herdrApp(parsed, window: shown, frontmost: .herdrApp) == .visible("t1"))
    #expect(TerminalVisibility.herdrApp(parsed, window: shown, frontmost: .wezTerm) == .nothing)
    #expect(TerminalVisibility.herdrApp(parsed, window: .unreadable, frontmost: .herdrApp) == .unknown)
    #expect(TerminalVisibility.herdrApp(nil, window: shown, frontmost: .herdrApp) == .unknown)
    #expect(TerminalVisibility.herdrApp(parsed, window: .closed, frontmost: .herdrApp) == .nothing)
    // A multiplexer client in that terminal is visible by its tty.
    #expect(MultiplexerHostFront.herdrApp(parsed, window: shown, frontmost: .herdrApp) == .visible("/dev/ttys002"))
}

// MARK: - Open

@Test func herdrAppOpenPlansOnlyItsOwnTerminal() throws {
    let parsed = try #require(snapshot())
    let target = TerminalTabTarget(host: .herdrApp, tabID: "t2", tty: "/dev/ttys004")
    let plan = try HerdrAppOpen.plan(.exact(target), codexTitle: codexTitle, snapshot: parsed).get()
    #expect(plan.terminal.address == "t2")
    #expect(HerdrAppCLI.focus(plan.terminal) == ["do", "agent.focus", #"{"terminal":"t2"}"#])
    let other = TerminalTabTarget(host: .rex, tabID: "t2", tty: "/dev/ttys004")
    #expect(HerdrAppOpen.plan(.exact(other), codexTitle: nil, snapshot: parsed) == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
    let gone = TerminalTabTarget(host: .herdrApp, tabID: "t7", tty: "/dev/ttys004")
    #expect(HerdrAppOpen.plan(.exact(gone), codexTitle: nil, snapshot: parsed) == .failure(.unavailable(.sessionEnded)))
}

@Test func herdrAppOpenVerifiesTheShownTerminalOnTheSameTTY() throws {
    let parsed = try #require(snapshot())
    let plan = try HerdrAppOpen.plan(.exact(TerminalTabTarget(host: .herdrApp, tabID: "t2", tty: "/dev/ttys004")),
                                     codexTitle: codexTitle, snapshot: parsed).get()
    let shown = try #require(window(space: s2, tab: tabB, pane: p2))
    #expect(HerdrAppOpen.verify(plan, after: parsed, window: shown, frontmost: .herdrApp) == nil)
    let miss = OpenMiss.fallBack(.notVerified, candidates: 1)
    // Another app in front, the split neighbour focused, the window unread, or the core unread.
    #expect(HerdrAppOpen.verify(plan, after: parsed, window: shown, frontmost: .ghostty) == miss)
    #expect(HerdrAppOpen.verify(plan, after: parsed, window: try #require(window(space: s2, tab: tabB, pane: p4)),
                                frontmost: .herdrApp) == miss)
    #expect(HerdrAppOpen.verify(plan, after: parsed, window: nil, frontmost: .herdrApp) == miss)
    #expect(HerdrAppOpen.verify(plan, after: nil, window: shown, frontmost: .herdrApp) == miss)
    // The terminal moved to another tty, or Codex's title changed.
    let moved = try #require(snapshot(listReply([terminalJSON("t2", pid: 58067, title: codexTitle)])))
    #expect(HerdrAppOpen.verify(plan, after: moved, window: shown, frontmost: .herdrApp) == miss)
    let renamed = try #require(snapshot(listReply([terminalJSON("t2", pid: 51902, title: "renamed")])))
    #expect(HerdrAppOpen.verify(plan, after: renamed, window: shown, frontmost: .herdrApp) == miss)
}

@Test func herdrAppFocusResultsMapToOpenMisses() {
    #expect(HerdrAppOpen.focused(.exited(status: 0, stdout: Data(#"{"ok":true}"#.utf8), stderr: "")) == nil)
    let gone = HerdrAppCommandResult.exited(status: 1, stdout: Data(#"{"error":"no running terminal \"t9\""}"#.utf8), stderr: "")
    #expect(HerdrAppOpen.focused(gone) == .unavailable(.sessionEnded))
    #expect(HerdrAppOpen.focused(.notRun(.appNotFound)) == .unavailable(.hostUnreadable(.herdrApp)))
    #expect(HerdrAppOpen.focused(.notRun(.socketUntrusted)) == .unavailable(.hostUnreadable(.herdrApp)))
    #expect(HerdrAppOpen.focused(.notRun(.noWindow)) == .fallBack(.notVerified, candidates: 1))
    #expect(HerdrAppOpen.focused(.timedOut) == .fallBack(.notVerified, candidates: 1))
    #expect(HerdrAppOpen.focused(.exited(status: 1, stdout: Data(#"{"error":"no such pane"}"#.utf8), stderr: ""))
        == .fallBack(.notVerified, candidates: 1))
}

@MainActor
@Test func herdrAppOpenFocusesOnceThenVerifies() async throws {
    let parsed = try #require(snapshot())
    let plan = try HerdrAppOpen.plan(.exact(TerminalTabTarget(host: .herdrApp, tabID: "t1", tty: "/dev/ttys002")),
                                     codexTitle: nil, snapshot: parsed).get()
    var raised = 0
    let run = await HerdrAppOpen.run(now: { 100 }, revalidate: { _ in .success(plan) },
                                     raise: { _ in raised += 1; return .exited(status: 0, stdout: Data(), stderr: "") },
                                     verifyRead: { (parsed, window(), .herdrApp) })
    #expect(run == .opened(plan, preOpenAt: 100))
    #expect(raised == 1)
    let failed = await HerdrAppOpen.run(now: { 100 }, revalidate: { _ in .success(plan) },
                                        raise: { _ in .timedOut }, verifyRead: { (parsed, window(), .herdrApp) })
    #expect(failed == .failed(.fallBack(.notVerified, candidates: 1), at: .raise))
}

// MARK: - Typed input

@Test func herdrAppTypesEachReplyAsOneSendThatSubmitsItself() {
    #expect(TypedReplyWrites.plan(agent: .codex, text: "go on", host: .herdrApp) == [.textAndSubmit("go on")])
    #expect(TypedReplyWrites.plan(agent: .claude, text: "go on", host: .herdrApp) == [.textAndSubmit("go on")])
    // Every other host keeps Codex's separate submit.
    #expect(TypedReplyWrites.plan(agent: .codex, text: "go on", host: .rex) == [.text("go on"), .submit])
    let send = HerdrAppInput.send(.textAndSubmit("go on"), terminal: "t1")
    #expect(send?.method == "terminal.send")
    #expect(send?.params["text"] as? String == "go on")
    #expect(send?.params["terminal"] as? String == "t1")
    #expect(HerdrAppInput.send(.submit, terminal: "t1") == nil)
    #expect(HerdrAppInput.key("1", terminal: "t1").params["keys"] as? [String] == ["1"])
}

@Test func herdrAppDeliveriesNeverCountARefusalAsSentOrAnUnknownAsUnsent() {
    let ok = Data(#"{"id":"s","jsonrpc":"2.0","result":{"started":null,"status":null,"turn":0}}"#.utf8)
    func error(_ kind: String) -> HerdrAppExchange {
        .reply(Data(#"{"id":"s","jsonrpc":"2.0","error":{"code":-32000,"data":{"kind":"\#(kind)"},"message":"m"}}"#.utf8))
    }
    #expect(HerdrAppInput.delivery(.reply(ok), id: "s") == .written)
    #expect(HerdrAppInput.delivery(error("not_found"), id: "s") == .notWritten)
    // A blocked program (a permission dialog) is refused, never typed into.
    #expect(HerdrAppInput.delivery(error("blocked"), id: "s") == .notWritten)
    #expect(HerdrAppInput.delivery(error("internal"), id: "s") == .possiblyWritten)
    #expect(HerdrAppInput.delivery(.reply(Data("garbage".utf8)), id: "s") == .possiblyWritten)
    #expect(HerdrAppInput.delivery(.notRunning, id: "s") == .notWritten)
    #expect(HerdrAppInput.delivery(.notSent(.socketUntrusted), id: "s") == .notWritten)
    #expect(HerdrAppInput.delivery(.failed(.timedOut), id: "s") == .possiblyWritten)
}

// MARK: - Wire, sockets, identity and presentation

@Test func herdrAppRequestsAreOneJSONRPCLine() throws {
    let line = try #require(HerdrAppRPC.requestLine(id: "r1", method: "terminal.list", params: [:]))
    #expect(line.last == 0x0A)
    #expect(String(decoding: line, as: UTF8.self) == #"{"id":"r1","jsonrpc":"2.0","method":"terminal.list","params":{}}"# + "\n")
    #expect(HerdrAppCLI.version(Data(#"{"id":"v","jsonrpc":"2.0","result":{"version":"0.1.22","pid":1}}"#.utf8), id: "v") == "0.1.22")
    #expect(HerdrAppCLI.version(Data(#"{"id":"v","result":{"version":"bad version"}}"#.utf8), id: "v") == nil)
    #expect(HerdrAppCLI.coreSocketPath(home: "/Users/u") == "/Users/u/.local/state/herdr-core/default/default.sock")
    #expect(HerdrAppCLI.appBinaryCandidates(home: "/Users/u").allSatisfy { $0.hasPrefix("/") && $0.hasSuffix("/MacOS/Herdr") })
    #expect(HerdrAppCLI.environment(home: "/Users/u") == ["HOME": "/Users/u", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
}

@Test func herdrAppSocketsMustBeTheUsersAndUnwritableByOthers() {
    // herdr-core's socket is 0755 in a 0700 folder; the window's is 0755 in a 0755 folder.
    #expect(HerdrAppSocket.trust(exists: true, isSocket: true, owner: 501, mode: 0o755, folderOwner: 501, folderMode: 0o700, me: 501)
        == .trusted)
    #expect(HerdrAppSocket.trust(exists: true, isSocket: true, owner: 501, mode: 0o755, folderOwner: 501, folderMode: 0o755, me: 501)
        == .trusted)
    #expect(HerdrAppSocket.trust(exists: true, isSocket: true, owner: 501, mode: 0o775, folderOwner: 501, folderMode: 0o700, me: 501)
        == .untrusted)
    #expect(HerdrAppSocket.trust(exists: true, isSocket: true, owner: 501, mode: 0o755, folderOwner: 501, folderMode: 0o777, me: 501)
        == .untrusted)
    #expect(HerdrAppSocket.trust(exists: true, isSocket: true, owner: 502, mode: 0o700, folderOwner: 501, folderMode: 0o700, me: 501)
        == .untrusted)
    #expect(HerdrAppSocket.trust(exists: true, isSocket: false, owner: 501, mode: 0o600, folderOwner: 501, folderMode: 0o700, me: 501)
        == .untrusted)
    #expect(HerdrAppSocket.trust(exists: false, isSocket: false, owner: 0, mode: 0, folderOwner: 0, folderMode: 0, me: 501)
        == .missing)
}

@Test func aProcessWalkReachingHerdrCoreIsTheHerdrAppNotGhostty() {
    // Herdr terminals carry TERM_PROGRAM=ghostty; Herdly attributes them by process ancestry, which reaches
    // herdr-core's holder (Herdr Core.app), and by the frontmost app's bundle.
    #expect(TerminalHost(bundleIdentifier: "dev.herdr.core") == .herdrApp)
    #expect(TerminalHost(bundleIdentifier: "dev.herdr.app") == .herdrApp)
    #expect(TerminalHost.herdrApp.kind == .terminal)
    #expect(TerminalHost.herdrApp.displayName == "Herdr app")
    #expect(TerminalHost.herdrApp.executableName == "herdr-core")
    #expect(TerminalHost.herdrApp.typesReplies)
    #expect(!TerminalHost.herdrApp.typesQuestionDigits)
    #expect(TerminalHost.herdrApp.defaultsKey == "herdrAppHostEnabled")
    #expect(TerminalHostTitles.hosts.contains(.herdrApp))
}

@Test func herdrAppSettingsRowShowsEachProblemOnce() {
    #expect(HerdrAppPresentation.settingsRow(on: false, installed: false, scan: .notRead, inUse: false).badge == .off)
    #expect(HerdrAppPresentation.settingsRow(on: true, installed: true, scan: .read, inUse: true).badge == .ready)
    #expect(HerdrAppPresentation.settingsRow(on: true, installed: true, scan: .notRunning, inUse: false).badge == .notInUse)
    let missing = HerdrAppPresentation.settingsRow(on: true, installed: false, scan: .unreadable(.appNotFound), inUse: false)
    #expect(missing.problems == [.notFound])
    #expect(HerdrAppPresentation.settingsRow(on: true, installed: true, scan: .unreadable(.socketUntrusted), inUse: false).problems
        == [.untrustedSocket])
    #expect(HerdrAppSettingsProblem.unreadable.message == "Herdly can't read Herdr app. Check Settings › Terminals.")
}
