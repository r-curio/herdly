import Foundation
import Testing
@testable import SteerCore

// Fixtures follow the herdr 0.9.3 (protocol 22) shapes recorded in the #102 live proof
// (docs/evidence/herdr-ghostty-live.md): disposable session `steer-probe`, workspace `w1` "Steer"
// with a Codex tab `w1:t1` and a shell tab `w1:t2`, and workspace `w2`. Paths and host names are
// replaced; the session UUID is the disposable one already published in that evidence.

let herdrCodexSession = "01a1142d-7a21-7383-a6aa-40030c90d7cf"

func herdrSnapshotReply(id: String, protocolVersion: Int = 22, focusedPane: String = "w1:p1",
                        codexStatus: String = "done") -> String {
    """
    {"id":"\(id)","result":{"type":"session_snapshot","snapshot":{"version":"0.9.3","protocol":\(protocolVersion),\
    "focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"\(focusedPane)",\
    "workspaces":[{"workspace_id":"w1","label":"Steer","number":1,"focused":true},\
    {"workspace_id":"w2","label":"probe-ws-b","number":2,"focused":false}],\
    "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"codex","focused":true,"pane_count":1,"agent_status":"\(codexStatus)"},\
    {"tab_id":"w1:t2","workspace_id":"w1","number":2,"label":"shell","focused":false,"pane_count":1,"agent_status":"unknown"},\
    {"tab_id":"w2:t1","workspace_id":"w2","number":1,"label":"shell","focused":true,"pane_count":2,"agent_status":"unknown"}],\
    "panes":[{"pane_id":"w1:p1","terminal_id":"term_a","workspace_id":"w1","tab_id":"w1:t1","focused":\(focusedPane == "w1:p1"),\
    "cwd":"/lab/herdr-lab","agent":"codex","agent_status":"\(codexStatus)","revision":7,\
    "agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"\(herdrCodexSession)"},\
    "terminal_title":"\(herdrCodexSession.prefix(29))...","terminal_title_stripped":"\(herdrCodexSession.prefix(29))...","future_field":{"x":1}},\
    {"pane_id":"w1:p2","terminal_id":"term_b","workspace_id":"w1","tab_id":"w1:t2","focused":false,"agent_status":"unknown","revision":2},\
    {"pane_id":"w2:p1","terminal_id":"term_c","workspace_id":"w2","tab_id":"w2:t1","focused":true,"agent_status":"unknown","revision":1},\
    {"pane_id":"w2:p2","terminal_id":"term_d","workspace_id":"w2","tab_id":"w2:t1","focused":false,"agent_status":"unknown","revision":1}],\
    "layouts":[{"workspace_id":"w1","tab_id":"w1:t1","zoomed":false,"area":{"x":0,"y":0,"width":120,"height":40},"focused_pane_id":"w1:p1",\
    "panes":[{"pane_id":"w1:p1","focused":true,"rect":{"x":0,"y":0,"width":120,"height":40}}],"splits":[]},\
    {"workspace_id":"w2","tab_id":"w2:t1","zoomed":true,"area":{"x":0,"y":0,"width":120,"height":40},"focused_pane_id":"w2:p1",\
    "panes":[{"pane_id":"w2:p1","focused":true,"rect":{"x":0,"y":0,"width":60,"height":40}},\
    {"pane_id":"w2:p2","focused":false,"rect":{"x":60,"y":0,"width":60,"height":40}}],"splits":[]}],\
    "agents":[{"terminal_id":"term_a","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1","focused":true,"agent_status":"\(codexStatus)","revision":7,"name":"probe","agent":"codex"}]}}}
    """
}

func herdrPongReply(id: String, protocolVersion: Int = 22) -> String {
    #"{"id":"\#(id)","result":{"type":"pong","version":"0.9.3","protocol":\#(protocolVersion),"capabilities":{"live_handoff":true}}}"#
}

private func decode(_ text: String, id: String = "r1") -> Result<HerdrReply, HerdrUnavailableReason> {
    HerdrWire.decodeReply(Data(text.utf8), expectedID: id)
}

@Test func herdrSnapshotDecodesTheLiveProofShape() throws {
    let reply = try decode(herdrSnapshotReply(id: "r1")).get()
    guard case .snapshot(let snapshot) = reply else { Issue.record("expected a snapshot"); return }
    #expect(snapshot.version == "0.9.3")
    #expect(snapshot.protocolVersion == 22)
    #expect(snapshot.focusedPaneID == "w1:p1")
    let codex = try #require(snapshot.pane("w1:p1"))
    #expect(codex.agent == "codex")
    #expect(codex.agentStatus == .done)
    #expect(codex.agentSession == HerdrAgentSession(source: "herdr:codex", agent: "codex", kind: "id", value: herdrCodexSession))
    #expect(codex.focused)
    let shell = try #require(snapshot.pane("w1:p2"))
    #expect(shell.agent == nil && shell.agentSession == nil && shell.terminalTitle == nil)
    #expect(snapshot.tab("w1:t1")?.paneCount == 1)
    #expect(snapshot.tab("w2:t1")?.paneCount == 2)
    #expect(snapshot.layouts.first { $0.tabID == "w2:t1" } == HerdrLayout(tabID: "w2:t1", zoomed: true, paneIDs: ["w2:p1", "w2:p2"]))
}

@Test func herdrAgentStatusPreservesUnknownValues() throws {
    guard case .snapshot(let snapshot) = try decode(herdrSnapshotReply(id: "r1", codexStatus: "thinking")).get() else {
        Issue.record("expected a snapshot"); return
    }
    #expect(snapshot.pane("w1:p1")?.agentStatus == .other("thinking"))
}

@Test func herdrPongAppliesTheProtocolAllowlist() {
    #expect(HerdrProtocol.supported == [22])
    #expect(decode(herdrPongReply(id: "r1")) == .success(.pong(version: "0.9.3", protocolVersion: 22)))
    #expect(decode(herdrPongReply(id: "r1", protocolVersion: 23)) == .failure(.unsupportedProtocol(23)))
    #expect(decode(herdrPongReply(id: "r1", protocolVersion: 21)) == .failure(.unsupportedProtocol(21)))
}

@Test func herdrSnapshotWithAnUnlistedProtocolIsUnsupportedEvenWhenItsShapeChanged() {
    #expect(decode(herdrSnapshotReply(id: "r1", protocolVersion: 23)) == .failure(.unsupportedProtocol(23)))
    let reshaped = #"{"id":"r1","result":{"type":"session_snapshot","snapshot":{"protocol":30,"surfaces":[]}}}"#
    #expect(decode(reshaped) == .failure(.unsupportedProtocol(30)))
}

@Test func herdrRepliesThatDoNotAnswerTheRequestAreMalformed() {
    #expect(decode(herdrPongReply(id: "other")) == .failure(.malformedReply))
    #expect(decode(#"{"id":"","error":{"code":"invalid_request","message":"bad json"}}"#) == .failure(.malformedReply))
    #expect(decode("not json") == .failure(.malformedReply))
    #expect(decode(#"{"id":"r1"}"#) == .failure(.malformedReply))
    #expect(decode(#"{"id":"r1","result":{"version":"0.9.3","protocol":22}}"#) == .failure(.malformedReply))
    // A relied-on field missing from one pane voids the whole snapshot.
    let missingStatus = herdrSnapshotReply(id: "r1").replacingOccurrences(
        of: #""focused":false,"agent_status":"unknown","revision":2"#, with: #""focused":false,"revision":2"#)
    #expect(missingStatus != herdrSnapshotReply(id: "r1"))
    #expect(decode(missingStatus) == .failure(.malformedReply))
}

@Test func herdrRepliesOverTheBoundAreMalformed() {
    let padding = String(repeating: " ", count: HerdrWire.maximumReply)
    #expect(decode(herdrPongReply(id: "r1") + padding) == .failure(.malformedReply))
}

@Test func herdrErrorRepliesAreRefusedWithHerdrsCode() {
    #expect(decode(#"{"id":"r1","error":{"code":"agent_not_found","message":"no agent"}}"#)
            == .failure(.requestRefused(code: "agent_not_found")))
    #expect(decode(#"{"id":"r1","result":{"type":"agent_info"},"error":{"code":"x","message":"y"}}"#)
            == .failure(.malformedReply))
}

@Test func herdrOtherSuccessResultsAreAcceptedWithoutDecoding() {
    #expect(decode(#"{"id":"r1","result":{"type":"ok"}}"#) == .success(.accepted(type: "ok")))
}

@Test func herdrRequestLineIsOneNewlineTerminatedObject() throws {
    let line = try #require(HerdrWire.requestLine(id: "r1", method: "agent.send_keys", params: ["target": "w1:p1", "keys": ["2"]]))
    #expect(line.last == 0x0A)
    #expect(line.dropLast().contains(0x0A) == false)
    let object = try #require(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
    #expect(object["id"] as? String == "r1")
    #expect(object["method"] as? String == "agent.send_keys")
    #expect((object["params"] as? [String: Any])?["keys"] as? [String] == ["2"])
}

// MARK: - Integration status

@Test func herdrIntegrationStatusReadsCurrentVersions() {
    // The live proof's integrations: codex v8, claude v10, plus herdr's other targets.
    let report = HerdrIntegrationReport(parsing: """
    pi: not installed (/home/.pi/agent/extensions/herdr-agent-state.ts)
    claude: current (v10) (/home/.claude/hooks/herdr-agent-state.sh)
    codex: current (v8) (/home/.codex/herdr-agent-state.sh)
    letta (experimental): not installed (/home/.letta/hooks/herdr-agent-session.sh)
    """)
    #expect(report.states == [.claude: .current(version: 10), .codex: .current(version: 8)])
    #expect(report.reason(for: .claude) == nil)
    #expect(report.reason(for: .codex) == nil)
}

@Test func herdrIntegrationStatusThatIsNotCurrentIsUnavailableForThatAgent() {
    let report = HerdrIntegrationReport(parsing: """
    claude: needs repair (v10) (/home/.claude/hooks/herdr-agent-state.sh)
    codex: outdated (v7 < v8) (/home/.codex/herdr-agent-state.sh)
    """)
    #expect(report.states == [.claude: .outdated, .codex: .outdated])
    #expect(report.reason(for: .codex) == .integrationNotCurrent(.codex))
    #expect(report.reason(for: .claude) == .integrationNotCurrent(.claude))

    let missing = HerdrIntegrationReport(parsing: "codex: not installed (/x)\n")
    #expect(missing.states == [.claude: .notInstalled, .codex: .notInstalled])
    #expect(missing.reason(for: .claude) == .integrationNotCurrent(.claude))
}

@Test func herdrIntegrationStatusThatCannotBeReadIsNotCurrent() {
    #expect(HerdrIntegrationReport(parsing: "codex: current (vX) (/x)").states[.codex] == .unparseable)
    #expect(HerdrIntegrationReport(parsing: "codex: current (legacy) (/x)").states[.codex] == .unparseable)
    #expect(HerdrIntegrationReport(parsing: "codex: installed").states[.codex] == .unparseable)
    let duplicated = HerdrIntegrationReport(parsing: "codex: current (v8) (/a)\ncodex: current (v8) (/b)")
    #expect(duplicated.reason(for: .codex) == .integrationNotCurrent(.codex))
    let oversized = HerdrIntegrationReport(parsing: "codex: current (v8) (/a)\n"
                                           + String(repeating: "x", count: HerdrIntegrationReport.maximumOutput))
    #expect(oversized.reason(for: .codex) == .integrationNotCurrent(.codex))
}

// MARK: - Attached clients

let herdrClientSocket = "/home/.config/herdr/herdr-client.sock"

/// `lsof -nP -U -F pfdn` shaped like the live proof: server 900 owns the listener and one
/// accepted connection per client; clients 20 and 30 point at those connections; 40 points at an
/// unrelated socket.
func herdrLsofOutput(clients: [Int32]) -> String {
    var lines = ["p900", "f3", "d0xL", "n\(herdrClientSocket)", "f9", "d0xS", "n/home/.config/herdr/herdr.sock"]
    for (index, _) in clients.enumerated() {
        lines += ["f\(10 + index)", "d0xA\(index)", "n\(herdrClientSocket)"]
    }
    for (index, pid) in clients.enumerated() {
        lines += ["p\(pid)", "f4", "d0xC\(index)", "n->0xA\(index)"]
    }
    lines += ["p40", "f4", "d0xE", "n->0xZ"]
    return lines.joined(separator: "\n") + "\n"
}

@Test func herdrLsofListingFindsTheServerAndEachAttachedClient() throws {
    let three = try #require(HerdrClientListing.parse(lsof: herdrLsofOutput(clients: [93954, 93001, 93002]),
                                                      clientSocketPath: herdrClientSocket))
    #expect(three == HerdrClientListing(serverPIDs: [900], clientPIDs: [93001, 93002, 93954]))
    let one = try #require(HerdrClientListing.parse(lsof: herdrLsofOutput(clients: [93954]), clientSocketPath: herdrClientSocket))
    #expect(one.clientPIDs == [93954])
    let other = try #require(HerdrClientListing.parse(lsof: herdrLsofOutput(clients: [93954]),
                                                      clientSocketPath: "/home/.config/herdr/sessions/x/herdr-client.sock"))
    #expect(other == HerdrClientListing(serverPIDs: [], clientPIDs: []))
}

@Test func herdrLsofListingThatCannotBeReadIsRejected() {
    #expect(HerdrClientListing.parse(lsof: "pabc\nn/x\n", clientSocketPath: "/x") == nil)
    #expect(HerdrClientListing.parse(lsof: "n/x\n", clientSocketPath: "/x") == nil)
}

private func ancestry(_ chains: [Int32: [HerdrProcessAncestor]]) -> (Int32) -> [HerdrProcessAncestor] {
    { chains[$0] ?? [] }
}

private let ghosttyChain: [HerdrProcessAncestor] = [
    HerdrProcessAncestor(pid: 93954, command: "herdr", tty: "ttys015"),
    HerdrProcessAncestor(pid: 93950, command: "zsh", tty: "ttys015"),
    HerdrProcessAncestor(pid: 93949, command: "login", tty: "ttys015"),
    HerdrProcessAncestor(pid: 828, command: "ghostty", tty: nil),
]

@Test func herdrClientVerdictRequiresExactlyOneGhosttyHostedClient() {
    let one = HerdrClientListing(serverPIDs: [900], clientPIDs: [93954])
    #expect(HerdrAttachedClient.verdict(listing: one, ancestry: ancestry([93954: ghosttyChain]))
            == .success(HerdrAttachedClient(pid: 93954, tty: "ttys015", serverPID: 900)))
    #expect(HerdrAttachedClient.verdict(listing: HerdrClientListing(serverPIDs: [900], clientPIDs: []), ancestry: ancestry([:]))
            == .failure(.wrongClientCount(0)))
    #expect(HerdrAttachedClient.verdict(listing: HerdrClientListing(serverPIDs: [900], clientPIDs: [1, 2, 3]),
                                        ancestry: ancestry([:])) == .failure(.wrongClientCount(3)))
    let terminal = [HerdrProcessAncestor(pid: 93954, command: "herdr", tty: "ttys015"),
                    HerdrProcessAncestor(pid: 500, command: "Terminal", tty: nil)]
    #expect(HerdrAttachedClient.verdict(listing: one, ancestry: ancestry([93954: terminal])) == .failure(.nonGhosttyClient))
    // An exited client, or a chain that is only Ghostty itself, is not a Ghostty-hosted client.
    #expect(HerdrAttachedClient.verdict(listing: one, ancestry: ancestry([:])) == .failure(.nonGhosttyClient))
    #expect(HerdrAttachedClient.verdict(listing: one, ancestry: ancestry([93954: [HerdrProcessAncestor(pid: 93954, command: "ghostty", tty: nil)]]))
            == .failure(.nonGhosttyClient))
}

// MARK: - Socket trust and scans

@Test func herdrSocketTrustMapsEachProblem() {
    #expect(HerdrSocketTrust.reason(for: nil) == nil)
    #expect(HerdrSocketTrust.reason(for: .missing) == .notRunning)
    #expect(HerdrSocketTrust.reason(for: .notASocket) == .untrustedSocket)
    #expect(HerdrSocketTrust.reason(for: .notOwnedByUser) == .untrustedSocket)
    #expect(HerdrSocketTrust.reason(for: .sharedPermissions) == .untrustedSocket)
    // herdr's own modes: a 0600 socket is trusted whatever its 0755 directory allows.
    #expect(AppServerSocketCheck.problem(exists: true, isSocket: true, owner: 501, mode: 0o600, me: 501) == nil)
    #expect(AppServerSocketCheck.problem(exists: true, isSocket: true, owner: 501, mode: 0o660, me: 501) == .sharedPermissions)
}

@Test func herdrScanReportsIntegrationBeforeClientsPerAgent() throws {
    guard case .snapshot(let snapshot) = try decode(herdrSnapshotReply(id: "r1")).get() else {
        Issue.record("expected a snapshot"); return
    }
    let integration = HerdrIntegrationReport(states: [.claude: .notInstalled, .codex: .current(version: 8)])
    let ready = HerdrScanOutcome.available(HerdrScan(snapshot: snapshot, integration: integration,
                                                     client: .success(HerdrAttachedClient(pid: 1, tty: "ttys001", serverPID: 2))))
    #expect(ready.targetReason(for: .codex) == nil)
    #expect(ready.targetReason(for: .claude) == .integrationNotCurrent(.claude))
    let twoClients = HerdrScanOutcome.available(HerdrScan(snapshot: snapshot, integration: integration,
                                                          client: .failure(.wrongClientCount(2))))
    #expect(twoClients.targetReason(for: .codex) == .wrongClientCount(2))
    #expect(twoClients.targetReason(for: .claude) == .integrationNotCurrent(.claude))
    #expect(HerdrScanOutcome.unavailable(.notRunning).targetReason(for: .codex) == .notRunning)
    #expect(HerdrScanOutcome.unavailable(.notRunning).scan == nil)
}

// MARK: - pane.process_info

/// A `pane.process_info` reply in herdr 0.9.3's protocol 22 shape (`PaneProcessInfo`).
func herdrProcessInfoReply(id: String, pane: String = "w1:p8", processes: String? = nil) -> String {
    let list = processes ?? #"[{"pid":60859,"name":"codex","argv0":"codex","argv":["codex","resume"],"cmdline":"codex resume","cwd":"/lab"}]"#
    return #"{"id":"\#(id)","result":{"type":"pane_process_info","process_info":{"pane_id":"\#(pane)","tty":"/dev/ttys004","shell_pid":60700,"foreground_process_group_id":60859,"foreground_processes":\#(list)}}}"#
}

@Test func herdrProcessInfoDecodesTheForegroundProcesses() throws {
    guard case .processInfo(let info) = try decode(herdrProcessInfoReply(id: "r1")).get() else {
        Issue.record("not process info"); return
    }
    #expect(info == HerdrProcessInfo(paneID: "w1:p8", shellPID: 60700, foregroundProcessGroupID: 60859,
                                     foregroundProcesses: [HerdrForegroundProcess(pid: 60859, name: "codex",
                                                                                  argv: ["codex", "resume"], cwd: "/lab")]))
    // Optional fields may be null or absent; a missing list is zero processes.
    let sparse = #"{"id":"r1","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p8","shell_pid":null,"foreground_processes":[{"pid":7,"name":"zsh","argv":null}]}}}"#
    #expect(try decode(sparse).get() == .processInfo(HerdrProcessInfo(
        paneID: "w1:p8", shellPID: nil, foregroundProcessGroupID: nil,
        foregroundProcesses: [HerdrForegroundProcess(pid: 7, name: "zsh", argv: nil, cwd: nil)])))
    let empty = #"{"id":"r1","result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p8"}}}"#
    #expect(try decode(empty).get() == .processInfo(HerdrProcessInfo(paneID: "w1:p8", shellPID: nil,
                                                                     foregroundProcessGroupID: nil, foregroundProcesses: [])))
}

@Test func herdrMalformedProcessInfoIsUnavailable() {
    let malformed = [
        // Required fields missing or mistyped.
        #"{"id":"r1","result":{"type":"pane_process_info"}}"#,
        #"{"id":"r1","result":{"type":"pane_process_info","process_info":{"foreground_processes":[]}}}"#,
        herdrProcessInfoReply(id: "r1", processes: #"[{"pid":1}]"#),
        herdrProcessInfoReply(id: "r1", processes: #"[{"name":"codex"}]"#),
        herdrProcessInfoReply(id: "r1", processes: #"[{"pid":"1","name":"codex"}]"#),
        herdrProcessInfoReply(id: "r1", processes: #"{"pid":1,"name":"codex"}"#),
        // PIDs outside a positive Int32.
        herdrProcessInfoReply(id: "r1", processes: #"[{"pid":0,"name":"codex"}]"#),
        herdrProcessInfoReply(id: "r1", processes: #"[{"pid":4294967295,"name":"codex"}]"#),
        herdrProcessInfoReply(id: "r1").replacingOccurrences(of: #""shell_pid":60700"#, with: #""shell_pid":-1"#),
        // Another request's reply.
        herdrProcessInfoReply(id: "other"),
    ]
    for text in malformed { #expect(decode(text) == .failure(.malformedReply), "\(text)") }
}

@Test func herdrOversizedProcessInfoIsMalformedRatherThanTruncated() {
    let many = "[" + (1...(HerdrWire.maximumProcesses + 1)).map { #"{"pid":\#($0),"name":"codex"}"# }.joined(separator: ",") + "]"
    #expect(decode(herdrProcessInfoReply(id: "r1", processes: many)) == .failure(.malformedReply))
    let atBound = "[" + (1...HerdrWire.maximumProcesses).map { #"{"pid":\#($0),"name":"sh"}"# }.joined(separator: ",") + "]"
    #expect((try? decode(herdrProcessInfoReply(id: "r1", processes: atBound)).get()) != nil)
    let arguments = "[" + Array(repeating: #""x""#, count: HerdrWire.maximumArguments + 1).joined(separator: ",") + "]"
    #expect(decode(herdrProcessInfoReply(id: "r1", processes: #"[{"pid":1,"name":"codex","argv":\#(arguments)}]"#))
        == .failure(.malformedReply))
    let padding = String(repeating: " ", count: HerdrWire.maximumReply)
    #expect(decode(herdrProcessInfoReply(id: "r1") + padding) == .failure(.malformedReply))
}
