import Foundation
import Testing
@testable import HerdlyCore

// Rex. Fixtures follow the shape of the inventory script's reply on Rex 0.1.0-preview.21
// (docs/rex-cli-investigation.md): session S1 holds window W1 (a Codex block B1 and, split beside it, a
// Claude block B2) and window W2 (a decoy B3 carrying Codex's title over `sleep`); session S2 holds W3 with a
// shell block B4, a non-terminal block and a block on another host.

private let codexSession = "01a129bd-a3ec-7dc0-875a-4fac39ec9eaa"
private let codexTitle = "01a129bd-a3ec-7dc0-875a-4fac3..."
private let claudeSessionID = "729984f1-4a2d-4649-b5f3-92212557f4ee"
private let claudeTitle = "Herdly Claude 729984f1-4a2d-4649-b5f3-92212557f4ee"

private let s1 = "session:01a2073b-9505-72f5-b3bb-fa6d0fb53942"
private let s2 = "session:01a20742-07c2-760e-9286-827d99e588dc"
private let w1 = "window:01a2073b-b9cf-7b71-a553-19d3fc407207"
private let w2 = "window:01a20742-4b7f-734b-a831-4c584fe34a35"
private let w3 = "window:01a20742-07dd-74e5-95c3-be99bf4a1887"
private let b1 = "block:01a2073b-b9c1-7509-8d6e-18a5ad6bfef2"
private let b2 = "block:01a20742-07c2-76f5-b3af-cbc61754b1f1"
private let b3 = "block:01a20742-4b6f-7338-b94b-1d8c5eab35a3"
private let b4 = "block:01a20742-5567-7e2c-a566-38b84675c168"
private let b5 = "block:01a20744-bdac-7a5c-b82f-4cc745e30ad1"
private let b6 = "block:01a20744-4ae3-70de-9357-c6afd9ce1bf4"

/// Each block's foreground pid → tty, as HerdlyApp reads it from the kernel.
private let ttys: [Int32: String] = [501: "/dev/ttys017", 601: "/dev/ttys018", 502: "/dev/ttys019", 701: "ttys020"]

private func blockJSON(_ id: String, pid: Int32?, title: String?, terminal: Bool = true, local: Bool = true) -> String {
    var fields = [#""block_id":"\#(id)""#, #""terminal":\#(terminal)"#, #""local":\#(local)"#]
    if let pid { fields.append(#""foreground_pid":\#(pid)"#) }
    if let title { fields.append(#""title":"\#(title)""#) }
    return "{" + fields.joined(separator: ",") + "}"
}

private func firstSession(focused w1Focus: String = b1, active s1Active: String = w1) -> String {
    #"{"session_id":"\#(s1)","active_window_id":"\#(s1Active)","windows":["#
        + #"{"window_id":"\#(w1)","focused_block_id":"\#(w1Focus)","blocks":["#
        + blockJSON(b1, pid: 501, title: codexTitle) + "," + blockJSON(b2, pid: 601, title: claudeTitle) + "]},"
        + #"{"window_id":"\#(w2)","focused_block_id":"\#(b3)","blocks":["# + blockJSON(b3, pid: 502, title: codexTitle) + "]}]}"
}

private let secondSession = #"{"session_id":"\#(s2)","active_window_id":"\#(w3)","windows":[{"window_id":"\#(w3)","focused_block_id":"\#(b4)","blocks":["#
    + blockJSON(b4, pid: 701, title: "") + "," + blockJSON(b5, pid: nil, title: nil, terminal: false) + ","
    + blockJSON(b6, pid: 9, title: "remote", local: false) + "]}]}"

private func replyJSON(sessions: [String]? = nil, focused w1Focus: String = b1, active s1Active: String = w1) -> String {
    let rows = sessions ?? [firstSession(focused: w1Focus, active: s1Active), secondSession]
    return #"{"server_pid":64207,"sessions":["# + rows.joined(separator: ",") + "]}"
}

private func snapshot(_ json: String = replyJSON()) -> RexSnapshot? {
    RexSnapshot.parse(Data(json.utf8)) { ttys[$0] }
}

private let rexOn = TerminalHostSwitches(enabled: [.rex])

private let processes: [String: [TerminalProcess]] = [
    "/dev/ttys017": [TerminalProcess(pid: 501, name: "codex", foreground: true)],
    "/dev/ttys019": [TerminalProcess(pid: 502, name: "sleep", foreground: true)],
    "/dev/ttys018": [TerminalProcess(pid: 601, name: "claude", foreground: true)],
]

// MARK: - Inventory

@Test func rexInventoryListsEveryLocalTerminalBlockAsItsOwnOnePaneTab() throws {
    let parsed = try #require(snapshot())
    // Every block has its own pty and is focused exactly, so B1 and B2 sharing W1 are two one-pane targets.
    // The non-terminal block and the other host's block are left out.
    #expect(parsed.inventory == .tabs([
        TerminalTab(tabID: b1, tty: "/dev/ttys017", title: codexTitle, paneCount: 1),
        TerminalTab(tabID: b2, tty: "/dev/ttys018", title: claudeTitle, paneCount: 1),
        TerminalTab(tabID: b3, tty: "/dev/ttys019", title: codexTitle, paneCount: 1),
        TerminalTab(tabID: b4, tty: "/dev/ttys020", title: nil, paneCount: 1),
    ]))
    #expect(parsed.sessionIDs == [s1, s2])
    #expect(parsed.block(b2)?.windowID == w1)
    #expect(parsed.block(b4)?.sessionID == s2)
    #expect(parsed.serverPID == 64207)
}

@Test func rexInventoryAcceptsLuasEmptyObjectsAsEmptyLists() throws {
    // Lua serializes an empty table as `{}`.
    #expect(try #require(snapshot(#"{"sessions":{}}"#)).inventory == .tabs([]))
    let empty = #"{"sessions":[{"session_id":"\#(s1)","windows":{}}]}"#
    #expect(try #require(snapshot(empty)).sessionIDs == [s1])
}

@Test func rexInventoryRefusesMalformedReplies() {
    #expect(snapshot("not json") == nil)
    #expect(snapshot(#"{"sessions":[1]}"#) == nil)
    #expect(snapshot(#"{"sessions":{"a":1}}"#) == nil)
    // A duplicate block, a bad id, a pid of the wrong type, a title of the wrong type, missing flags.
    #expect(snapshot(replyJSON().replacingOccurrences(of: b3, with: b1)) == nil)
    #expect(snapshot(replyJSON().replacingOccurrences(of: b1, with: "pane:1")) == nil)
    #expect(snapshot(replyJSON().replacingOccurrences(of: #""foreground_pid":501"#, with: #""foreground_pid":"501""#)) == nil)
    #expect(snapshot(replyJSON().replacingOccurrences(of: #""title":"\#(claudeTitle)""#, with: #""title":7"#)) == nil)
    #expect(snapshot(replyJSON().replacingOccurrences(of: #""terminal":true,"#, with: "")) == nil)
    #expect(snapshot(String(repeating: " ", count: RexSnapshot.maximumReplySize + 1)) == nil)
}

@Test func rexReadsPSOnlyForTitledCodexBlocksAndClaudeTTYs() throws {
    let parsed = try #require(snapshot())
    #expect(parsed.ttysToRead(codexTitles: [codexTitle], claudeTTYs: []) == ["/dev/ttys017", "/dev/ttys019"])
    #expect(parsed.ttysToRead(codexTitles: [], claudeTTYs: ["ttys018"]) == ["/dev/ttys018"])
}

// MARK: - Binding (ADR 0013)

@Test func aCodexRexBlockBindsByTitleAndForegroundCodexWhileTheDecoyAndTheSplitDoNotStopIt() throws {
    let inventory = try #require(snapshot()).inventory
    let binding = TerminalTabBindingRules.codex(sessionID: codexSession, liveness: .live, liveSessions: [codexSession],
                                                switches: rexOn, inventories: [.rex: inventory], processes: processes,
                                                secondRead: [.rex: inventory])
    #expect(binding == .bound(TerminalTabTarget(host: .rex, tabID: b1, tty: "/dev/ttys017")))
}

@Test func aClaudeRexBlockBindsByItsRegisteredProcessTTY() throws {
    let inventory = try #require(snapshot()).inventory
    let registered = ClaudeSessionRegistry.Process(pid: 601, procStart: "start")
    let observed = TerminalProcessObservation(pid: 601, procStart: "start", tty: "ttys018")
    let binding = TerminalTabBindingRules.claude(sessionID: claudeSessionID, liveness: .live, process: .registered(registered),
                                                 observed: observed, switches: rexOn, inventories: [.rex: inventory],
                                                 processes: processes)
    #expect(binding == .bound(TerminalTabTarget(host: .rex, tabID: b2, tty: "/dev/ttys018")))
}

@Test func anUnreadableRexLeavesEverySessionItCouldHoldUnavailable() {
    let binding = TerminalTabBindingRules.codex(sessionID: codexSession, liveness: .live, liveSessions: [codexSession],
                                                switches: rexOn, inventories: [.rex: .unreadable], processes: [:],
                                                secondRead: [.rex: .unreadable])
    #expect(binding == .unavailable(.hostUnreadable(.rex)))
}

// MARK: - Visible and Open

@Test func aRexBlockIsVisibleOnlyWithRexFrontmostAndOneSessionShowingIt() throws {
    let one = try #require(snapshot(replyJSON(sessions: [firstSession()])))
    #expect(TerminalVisibility.rex(one, frontmost: .rex) == .visible(b1))
    #expect(TerminalVisibility.rex(one, frontmost: .wezTerm) == .nothing)
    #expect(TerminalVisibility.rex(nil, frontmost: .rex) == .unknown)
    // Rex does not say which session the app shows, so with two nothing is known to be visible.
    #expect(TerminalVisibility.rex(try #require(snapshot()), frontmost: .rex) == .unknown)
}

@Test func rexOpenPlansOnlyItsOwnBlockAndAsksForTheSessionWhenThereAreSeveral() throws {
    let parsed = try #require(snapshot())
    let target = TerminalTabTarget(host: .rex, tabID: b2, tty: "/dev/ttys018")
    let plan = try RexOpen.plan(.exact(target), codexTitle: nil, snapshot: parsed).get()
    #expect(plan.block.sessionID == s1)
    #expect(plan.needsSelect)
    let other = TerminalTabTarget(host: .wezTerm, tabID: "2", tty: "/dev/ttys018")
    #expect(RexOpen.plan(.exact(other), codexTitle: nil, snapshot: parsed) == .failure(.fallBack(.noUniqueTarget, candidates: 1)))
    let gone = TerminalTabTarget(host: .rex, tabID: "block:00000000-0000-0000-0000-000000000000", tty: "/dev/ttys018")
    #expect(RexOpen.plan(.exact(gone), codexTitle: nil, snapshot: parsed) == .failure(.unavailable(.sessionEnded)))
}

@Test func rexOpenVerifiesTheFocusedBlockAndTheAppsSession() throws {
    let target = TerminalTabTarget(host: .rex, tabID: b2, tty: "/dev/ttys018")
    let plan = try RexOpen.plan(.exact(target), codexTitle: nil, snapshot: try #require(snapshot())).get()
    let focused = try #require(snapshot(replyJSON(focused: b2)))
    // Several sessions: verified only when the app performed the select.
    #expect(RexOpen.verify(plan, after: focused, selected: true, frontmost: .rex) == nil)
    #expect(RexOpen.verify(plan, after: focused, selected: false, frontmost: .rex) == .fallBack(.notVerified, candidates: 1))
    // Focus did not land, another app is in front, or the block's window is not the active one.
    #expect(RexOpen.verify(plan, after: try #require(snapshot()), selected: true, frontmost: .rex) != nil)
    #expect(RexOpen.verify(plan, after: focused, selected: true, frontmost: .wezTerm) != nil)
    #expect(RexOpen.verify(plan, after: try #require(snapshot(replyJSON(focused: b2, active: w2))), selected: true,
                           frontmost: .rex) != nil)
    // A Codex plan needs its title to still show.
    let codex = try RexOpen.plan(.exact(TerminalTabTarget(host: .rex, tabID: b1, tty: "/dev/ttys017")),
                                 codexTitle: "renamed", snapshot: try #require(snapshot())).get()
    #expect(RexOpen.verify(codex, after: try #require(snapshot()), selected: true, frontmost: .rex) != nil)
}

@Test func rexFocusAndWriteResultsMapToOpenMissesAndDeliveries() {
    let notFound = RexCommandResult.exited(status: 3, stdout: Data(),
                                           stderr: "Error: block not found: block:x (status=404 code=not_found)")
    #expect(RexOpen.focused(.exited(status: 0, stdout: Data(), stderr: "")) == nil)
    #expect(RexOpen.focused(notFound) == .unavailable(.sessionEnded))
    #expect(RexOpen.focused(.notRun(.binaryNotFound)) == .unavailable(.hostUnreadable(.rex)))
    #expect(RexOpen.focused(.timedOut) == .fallBack(.notVerified, candidates: 1))
    #expect(RexInput.delivery(.exited(status: 0, stdout: Data(), stderr: "")) == .written)
    #expect(RexInput.delivery(notFound) == .notWritten)
    #expect(RexInput.delivery(.notRun(.socketUntrusted)) == .notWritten)
    #expect(RexInput.delivery(.timedOut) == .possiblyWritten)
    #expect(RexOpen.selected(.exited(status: 0, stdout: Data(), stderr: "")))
    #expect(!RexOpen.selected(.exited(status: 1, stdout: Data(), stderr: "code=refused")))
}

// MARK: - Commands, identity and presentation

@Test func rexRunsFromFixedPathsPinnedToItsSocketWithoutStartingAServer() {
    #expect(RexCLI.binaryCandidates(home: "/Users/u").allSatisfy { $0.hasSuffix("/rex") && $0.hasPrefix("/") })
    let environment = RexCLI.environment(home: "/Users/u", socket: "/Users/u/Library/Application Support/rex/server.sock")
    #expect(environment["REX_SERVER"] == "unix:///Users/u/Library/Application%20Support/rex/server.sock")
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(RexCLI.inventory.contains("--autostart=false"))
    let block = RexBlock(blockID: b1, windowID: w1, sessionID: s1, tty: "/dev/ttys017", title: nil)
    let write = RexCLI.write("1\r", block: block)
    #expect(write.contains("--autostart=false"))
    #expect(write.last == #"{"args":{"data":"1\r"},"block_id":"\#(b1)","method":"write","session_id":"\#(s1)"}"#)
}

@Test func aProcessWalkReachingTheRexServerIsRex() {
    #expect(TerminalHost(bundleIdentifier: "com.superlogical.rex.server") == .rex)
    #expect(TerminalHost(bundleIdentifier: "com.superlogical.rex") == .rex)
    #expect(TerminalHost.rex.kind == .terminal)
    #expect(TerminalHost.rex.typesReplies)
    #expect(!TerminalHost.rex.typesQuestionDigits)
}

@Test func rexVersionAndAppClientsParseWithinBounds() {
    #expect(RexCLI.version(Data(#"{"rex_version":"0.1.0-preview.21","api_revision":18}"#.utf8)) == "0.1.0-preview.21")
    #expect(RexCLI.version(Data(#"{"rex_version":"bad version"}"#.utf8)) == nil)
    let clients = #"{"clients":[{"client_id":"client:01a20738-b2bc","connection_state":"connected"},"#
        + #"{"client_id":"client:01a20738-b2ca","info":{"kind":"app"},"connection_state":"connected"},"#
        + #"{"client_id":"client:01a20744-f966","info":{"kind":"cli"},"connection_state":"connected"}]}"#
    #expect(RexClients.appClients(Data(clients.utf8)) == ["client:01a20738-b2ca"])
}

@Test func rexSettingsRowShowsEachProblemOnce() {
    #expect(RexPresentation.settingsRow(on: false, installed: false, scan: .notRead, inUse: false).badge == .off)
    #expect(RexPresentation.settingsRow(on: true, installed: true, scan: .read, inUse: true).badge == .ready)
    #expect(RexPresentation.settingsRow(on: true, installed: true, scan: .read, inUse: false).badge == .notInUse)
    let missing = RexPresentation.settingsRow(on: true, installed: false, scan: .unreadable(.binaryNotFound), inUse: false)
    #expect(missing.problems == [.notFound])
    #expect(RexPresentation.settingsRow(on: true, installed: true, scan: .unreadable(.socketUntrusted), inUse: false).problems
        == [.untrustedSocket])
}
