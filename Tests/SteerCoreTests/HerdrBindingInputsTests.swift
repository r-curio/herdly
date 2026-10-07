import Foundation
import Testing
@testable import SteerCore

private let session = "01a1142d-7a21-7383-a6aa-40030c90d7cf"
private let otherSession = "9f3c2b10-1111-4222-8333-444455556666"
private let socket = "/Users/test/.config/herdr/herdr.sock"
private let codexKey = HerdrSessionKey(agent: .codex, sessionID: session)

// Explicit clock, in seconds since 1970: herdr's server started at 1_000, hooks arrive later.
private let serverStart = 1_000.0

private func record(_ sessionID: String = session, agent: HerdrAgentKind = .codex, pane: String? = "w1:p1",
                    socket socketPath: String? = socket, at recordedAt: Double = 1_100) -> HerdrHookPaneRecord {
    HerdrHookPaneRecord(sessionID: sessionID, agent: agent, paneID: pane,
                        socketPath: pane == nil ? nil : socketPath, recordedAt: recordedAt)
}

private func herdrPane(_ paneID: String = "w1:p1", tab: String = "w1:t1", agent: String? = "codex",
                       session agentSession: HerdrAgentSession? = HerdrAgentSession(source: "herdr:codex", agent: "codex",
                                                                                     kind: "id", value: session),
                       title: String? = nil) -> HerdrPane {
    HerdrPane(paneID: paneID, tabID: tab, workspaceID: "w1", focused: true, agent: agent, agentStatus: .idle,
              agentSession: agentSession, terminalTitle: title)
}

private func scan(panes: [HerdrPane] = [herdrPane()],
                  tabs: [HerdrTab] = [HerdrTab(tabID: "w1:t1", workspaceID: "w1", focused: true, paneCount: 1)],
                  layouts: [HerdrLayout] = [HerdrLayout(tabID: "w1:t1", zoomed: false, paneIDs: ["w1:p1"])],
                  protocolVersion: Int = 22,
                  integration: [HerdrAgentKind: HerdrIntegrationState] = [.codex: .current(version: 8),
                                                                         .claude: .current(version: 10)],
                  client: Result<HerdrAttachedClient, HerdrUnavailableReason>
                      = .success(HerdrAttachedClient(pid: 93954, tty: "ttys015", serverPID: 900)),
                  serverStartedAt: Double? = serverStart) -> HerdrScanOutcome {
    .available(HerdrScan(snapshot: HerdrSnapshot(version: "0.9.3", protocolVersion: protocolVersion,
                                                 focusedWorkspaceID: "w1", focusedTabID: "w1:t1",
                                                 focusedPaneID: "w1:p1", tabs: tabs, panes: panes, layouts: layouts),
                         integration: HerdrIntegrationReport(states: integration), client: client,
                         serverStartedAt: serverStartedAt))
}

private func binding(_ key: HerdrSessionKey = codexKey, liveness: HerdrSessionLiveness = .live,
                     records: [HerdrHookPaneRecord] = [record()], ghostty: Bool = true,
                     outcome: HerdrScanOutcome? = scan()) -> HerdrSessionBinding {
    HerdrBindingInputs.binding(for: key, liveness: liveness, hookRecords: records, ghosttyControlsEnabled: ghostty,
                               outcome: outcome, defaultSocketPath: socket)
}

private let target = HerdrPaneTarget(sessionID: session, agent: .codex, paneID: "w1:p1")

// MARK: - Agreement

@Test func herdrInputsBindWhenTheHookRecordAndTheScanAgree() {
    #expect(binding() == .bound(target))
    #expect(binding().target == target)
}

@Test func herdrInputsLowercaseCodexSessionsOnBothSides() {
    let upper = session.uppercased()
    let pane = herdrPane(session: HerdrAgentSession(source: "herdr:codex", agent: "codex", kind: "id", value: upper))
    let key = HerdrSessionKey(agent: .codex, sessionID: upper)
    #expect(key == codexKey)
    #expect(binding(key, records: [record(upper)], outcome: scan(panes: [pane])) == .bound(target))
}

@Test func herdrInputsKeepClaudeSessionsAsWritten() {
    let claude = "Claude-Session-A"
    let key = HerdrSessionKey(agent: .claude, sessionID: claude)
    #expect(key.sessionID == claude)
    let pane = herdrPane(agent: "claude",
                         session: HerdrAgentSession(source: "herdr:claude", agent: "claude", kind: "id", value: claude))
    #expect(binding(key, records: [record(claude, agent: .claude)], outcome: scan(panes: [pane]))
        == .bound(HerdrPaneTarget(sessionID: claude, agent: .claude, paneID: "w1:p1")))
    #expect(binding(HerdrSessionKey(agent: .claude, sessionID: claude.lowercased()),
                    records: [record(claude, agent: .claude)], outcome: scan(panes: [pane])) == .notInHerdr)
}

@Test func herdrInputsDisagreementIsUnavailableNotNotInHerdr() {
    let other = herdrPane(session: HerdrAgentSession(source: "herdr:codex", agent: "codex", kind: "id", value: otherSession))
    #expect(binding(outcome: scan(panes: [other])) == .unavailable(.binding(.agentSessionMismatch)))
    #expect(binding(outcome: scan(panes: [herdrPane(session: nil)])) == .unavailable(.binding(.agentSessionNull)))
    let path = herdrPane(session: HerdrAgentSession(source: "herdr:codex", agent: "codex", kind: "path", value: session))
    #expect(binding(outcome: scan(panes: [path])) == .unavailable(.binding(.agentSessionMismatch)))
    let wrongAgent = herdrPane(session: HerdrAgentSession(source: "herdr:claude", agent: "claude", kind: "id", value: session))
    #expect(binding(outcome: scan(panes: [wrongAgent])) == .unavailable(.binding(.agentSessionMismatch)))
    #expect(binding(liveness: .ended) == .unavailable(.binding(.sessionEnded)))
}

@Test func herdrInputsCountZoomedAndSplitPanesInTheTab() {
    let zoomed = scan(panes: [herdrPane(), herdrPane("w1:p2", agent: nil, session: nil)],
                      tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", focused: true, paneCount: 1)],
                      layouts: [HerdrLayout(tabID: "w1:t1", zoomed: true, paneIDs: ["w1:p1", "w1:p2"])])
    #expect(binding(outcome: zoomed) == .unavailable(.binding(.split)))
    let counted = scan(tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", focused: true, paneCount: 2)])
    #expect(binding(outcome: counted) == .unavailable(.binding(.split)))
    #expect(binding(outcome: scan(tabs: [])) == .unavailable(.binding(.split)))
}

@Test func herdrInputsMapTheClientVerdict() {
    #expect(binding(outcome: scan(client: .failure(.wrongClientCount(0)))) == .unavailable(.binding(.noClient)))
    #expect(binding(outcome: scan(client: .failure(.wrongClientCount(3)))) == .unavailable(.binding(.multipleClients(3))))
    #expect(binding(outcome: scan(client: .failure(.nonGhosttyClient))) == .unavailable(.binding(.nonGhosttyClient)))
}

// MARK: - Restart

@Test func herdrInputsVoidTheBindingWhenTheServerStartedAfterTheNewestHookRecord() {
    // herdr restarted at 1_200, after the hook event at 1_100: the restored agent_session is stale.
    #expect(binding(outcome: scan(serverStartedAt: 1_200)) == .unavailable(.binding(.herdrRestarted)))
    // Starting at the same instant is not proof of the old server either.
    #expect(binding(outcome: scan(serverStartedAt: 1_100)) == .unavailable(.binding(.herdrRestarted)))
    // A new hook event from the pane after the restart restores it.
    #expect(binding(records: [record(at: 1_100), record(at: 1_300)], outcome: scan(serverStartedAt: 1_200))
        == .bound(target))
}

@Test func herdrInputsRequireAServerIdentity() {
    #expect(binding(outcome: scan(serverStartedAt: nil)) == .unavailable(.serverIdentityUnknown))
    let observation = HerdrBindingInputs.observation(from: scan().scan!)
    #expect(observation?.server == HerdrServerInstance(startedAt: serverStart))
    #expect(observation?.session == .defaultSession)
    #expect(observation?.protocolVersion == 22)
    #expect(HerdrBindingInputs.observation(from: scan(serverStartedAt: nil).scan!) == nil)
}

// MARK: - Integration status

@Test func herdrInputsPassEveryIntegrationStateToTheRules() {
    #expect(binding(outcome: scan(integration: [.codex: .current(version: 8)])) == .bound(target))
    for state in [HerdrIntegrationState.outdated, .notInstalled, .unparseable] {
        #expect(binding(outcome: scan(integration: [.codex: state, .claude: .current(version: 10)]))
            == .unavailable(.binding(.integrationNotCurrent(.codex, state))))
    }
    #expect(binding(outcome: scan(integration: [.claude: .current(version: 10)]))
        == .unavailable(.binding(.integrationNotCurrent(.codex, nil))))
    // Parsed output reaches the rules unchanged.
    let parsed = HerdrIntegrationReport(parsing: "codex: outdated (v7 < v8) (/x)\nclaude: current (v10) (/y)\n")
    #expect(binding(outcome: scan(integration: parsed.states))
        == .unavailable(.binding(.integrationNotCurrent(.codex, .outdated))))
}

// MARK: - Scan-level states

@Test func herdrInputsReportGateAndScanStatesForSessionsInHerdr() {
    #expect(binding(ghostty: false) == .unavailable(.ghosttyControlsOff))
    #expect(binding(outcome: nil) == .unavailable(.notScanned))
    for reason in [HerdrUnavailableReason.notRunning, .herdrNotFound, .untrustedSocket, .timeout, .malformedReply,
                   .unsupportedProtocol(23)] {
        #expect(binding(outcome: .unavailable(reason)) == .unavailable(.herdr(reason)))
    }
    #expect(binding(records: [record(socket: "/tmp/named.sock")]) == .unavailable(.binding(.namedSession)))
    #expect(binding(records: [record(socket: nil)]) == .unavailable(.binding(.socketUnknown)))
}

// MARK: - Sessions not in herdr

@Test func herdrInputsKeepSessionsNotInHerdrApartFromUnavailable() {
    #expect(binding(records: []) == .notInHerdr)
    #expect(binding(records: [record(otherSession)]) == .notInHerdr)
    #expect(binding(records: [record(pane: nil)]) == .notInHerdr)
    // Only the newest event counts: the session left herdr after an older event in a pane.
    #expect(binding(records: [record(at: 1_100), record(pane: nil, at: 1_150)]) == .notInHerdr)
    // Not in herdr regardless of Ghostty controls or scan state.
    #expect(binding(records: [record(pane: nil)], ghostty: false, outcome: nil) == .notInHerdr)
    #expect(binding(records: [record(pane: nil)], outcome: .unavailable(.notRunning)) == .notInHerdr)
    // A disagreeing tie at the newest time is uncertain, not "not in herdr".
    #expect(binding(records: [record(at: 1_150), record(pane: nil, at: 1_150)])
        == .unavailable(.binding(.conflictingHookRecords)))
}

// MARK: - Gate

@Test func herdrGateRequiresGhosttyControlsAndARecordedPane() {
    #expect(HerdrBindingInputs.allowsContact(ghosttyControlsEnabled: true, paneIDs: ["w1:p1"]))
    #expect(!HerdrBindingInputs.allowsContact(ghosttyControlsEnabled: false, paneIDs: ["w1:p1"]))
    #expect(!HerdrBindingInputs.allowsContact(ghosttyControlsEnabled: true, paneIDs: []))
}

@Test func herdrGatePaneIDsComeFromLiveSessionsNewestEvents() {
    let claudeKey = HerdrSessionKey(agent: .claude, sessionID: "claude-a")
    let records = [
        record(at: 1_100),
        record(otherSession, pane: "w2:p1", at: 1_100),
        record(otherSession, pane: nil, at: 1_200),   // newest event left herdr
        record("claude-a", agent: .claude, pane: "w3:p1"),
        record("ended-claude", agent: .claude, pane: "w4:p1"),
    ]
    let live: Set = [codexKey, HerdrSessionKey(agent: .codex, sessionID: otherSession), claudeKey]
    #expect(HerdrBindingInputs.gatePaneIDs(records: records, liveSessions: live) == ["w1:p1", "w3:p1"])
    #expect(HerdrBindingInputs.gatePaneIDs(records: records, liveSessions: []).isEmpty)
    #expect(HerdrBindingInputs.gatePaneIDs(records: [record(session.uppercased())], liveSessions: [codexKey]) == ["w1:p1"])
}

// MARK: - Hook records

@Test func herdrHookRecordsDecodeSteerEventsOnly() {
    let codex: [String: Any] = ["hook_event_name": "Stop", "session_id": session.uppercased(), "source": "steer-hook-v1",
                                "captured_at": 1_100.5, HerdrPaneID.recordKey: "w1:p1",
                                HerdrSocketPath.recordKey: socket]
    #expect(HerdrBindingInputs.hookRecord(from: codex) == record(at: 1_100.5))
    let claude: [String: Any] = ["hook_event_name": "Stop", "session_id": "Claude-A", "source": "steer-claude-hook-v1",
                                 "received_at": "2026-10-07T12:00:00Z"]
    let decoded = HerdrBindingInputs.hookRecord(from: claude)
    #expect(decoded?.agent == .claude)
    #expect(decoded?.sessionID == "Claude-A")
    #expect(decoded?.paneID == nil)
    #expect(decoded?.recordedAt == RolloutTimestamp.parse("2026-10-07T12:00:00Z"))
    var foreign = codex; foreign["source"] = "other"
    var noTime = codex; noTime["captured_at"] = nil
    var badSession = codex; badSession["session_id"] = "not-a-uuid"
    var noEvent = codex; noEvent["hook_event_name"] = nil
    for object in [foreign, noTime, badSession, noEvent] { #expect(HerdrBindingInputs.hookRecord(from: object) == nil) }
    var badPane = codex; badPane[HerdrPaneID.recordKey] = "w1:p1\u{7}"
    #expect(HerdrBindingInputs.hookRecord(from: badPane)?.paneID == nil)
    #expect(HerdrBindingInputs.hookRecord(from: badPane)?.socketPath == nil)
}

@Test func herdrHookRecordReaderKeepsEachSessionsNewestAndCachesByPath() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-inputs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
    }
    let base: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": session, "source": "steer-hook-v1"]
    try write(base.merging(["captured_at": 1_100.0, HerdrPaneID.recordKey: "w1:p1", HerdrSocketPath.recordKey: socket]) { $1 })
    try write(base.merging(["captured_at": 1_200.0, HerdrPaneID.recordKey: "w1:p2", HerdrSocketPath.recordKey: socket]) { $1 })
    try write(["request_id": UUID().uuidString])
    try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

    let first = HerdrHookRecordReader.read(directories: [directory])
    #expect(first.records == [record(pane: "w1:p2", at: 1_200)])
    #expect(first.cache.count == 4)
    #expect(first.cache.values.compactMap { $0 }.count == 2)

    // A cached path is not decoded again: a stand-in cache entry wins over the file.
    var stale = first.cache
    let newestPath = try #require(first.cache.first { $0.value?.paneID == "w1:p2" }?.key)
    stale[newestPath] = .some(record(pane: "w9:p9", at: 1_200))
    #expect(HerdrHookRecordReader.read(directories: [directory], cache: stale).records == [record(pane: "w9:p9", at: 1_200)])
    // Paths no longer listed drop out of the cache.
    let gone = HerdrHookRecordReader.read(directories: [directory], cache: ["/nowhere.json": record()])
    #expect(gone.cache["/nowhere.json"] == nil)
    #expect(HerdrHookRecordReader.read(directories: [directory.appendingPathComponent("missing")]).records.isEmpty)
}
