import Foundation
import Testing
@testable import HerdlyCore

private let session = "01a1142d-7a21-7383-a6aa-40030c90d7cf"
private let otherSession = "9f3c2b10-1111-4222-8333-444455556666"
private let socket = "/Users/test/.config/herdr/herdr.sock"
private let claudeKey = HerdrSessionKey(agent: .claude, sessionID: session)

// Explicit clock, in seconds since 1970: herdr's server started at 1_000, hooks arrive later.
private let serverStart = 1_000.0

private func record(_ sessionID: String = session, agent: HerdrAgentKind = .claude, pane: String? = "w1:p1",
                    socket socketPath: String? = socket, at recordedAt: Double = 1_100) -> HerdrHookPaneRecord {
    HerdrHookPaneRecord(sessionID: sessionID, agent: agent, paneID: pane,
                        socketPath: pane == nil ? nil : socketPath, recordedAt: recordedAt)
}

private func herdrPane(_ paneID: String = "w1:p1", tab: String = "w1:t1", agent: String? = "claude",
                       session agentSession: HerdrAgentSession? = HerdrAgentSession(source: "herdr:claude", agent: "claude",
                                                                                     kind: "id", value: session),
                       title: String? = nil) -> HerdrPane {
    HerdrPane(paneID: paneID, tabID: tab, workspaceID: "w1", focused: true, agent: agent, agentStatus: .idle,
              agentSession: agentSession, terminalTitle: title)
}

private func scan(panes: [HerdrPane] = [herdrPane()],
                  tabs: [HerdrTab] = [HerdrTab(tabID: "w1:t1", workspaceID: "w1", focused: true, paneCount: 1)],
                  layouts: [HerdrLayout] = [HerdrLayout(tabID: "w1:t1", zoomed: false, paneIDs: ["w1:p1"])],
                  protocolVersion: Int = 22,
                  integration: [HerdrAgentKind: HerdrIntegrationState] = [.claude: .current(version: 8),
                                                                         .codex: .current(version: 10)],
                  client: Result<HerdrAttachedClient, HerdrUnavailableReason>
                      = .success(HerdrAttachedClient(pid: 93954, tty: "ttys015", serverPID: 900)),
                  serverStartedAt: Double? = serverStart,
                  processInfo: [String: Result<HerdrProcessInfo, HerdrUnavailableReason>] = ["w1:p1": foreground()])
    -> HerdrScanOutcome {
    .available(HerdrScan(snapshot: HerdrSnapshot(version: "0.9.3", protocolVersion: protocolVersion,
                                                 focusedWorkspaceID: "w1", focusedTabID: "w1:t1",
                                                 focusedPaneID: "w1:p1", tabs: tabs, panes: panes, layouts: layouts),
                         integration: HerdrIntegrationReport(states: integration), client: client,
                         serverStartedAt: serverStartedAt, processInfo: processInfo))
}

/// `pane.process_info` for `paneID` listing processes with these names.
private func foreground(_ paneID: String = "w1:p1", _ names: [String] = ["claude"])
    -> Result<HerdrProcessInfo, HerdrUnavailableReason> {
    .success(HerdrProcessInfo(paneID: paneID, shellPID: 100, foregroundProcessGroupID: 83378,
                              foregroundProcesses: names.enumerated().map {
                                  HerdrForegroundProcess(pid: Int32(83378 + $0.offset), name: $0.element, argv: nil, cwd: nil)
                              }))
}

private func binding(_ key: HerdrSessionKey = claudeKey, liveness: HerdrSessionLiveness = .live,
                     records: [HerdrHookPaneRecord] = [record()], herdr: Bool = true, ghostty: Bool = true,
                     outcome: HerdrScanOutcome? = scan()) -> HerdrSessionBinding {
    HerdrBindingInputs.binding(for: key, liveness: liveness, hookRecords: records, herdrEnabled: herdr,
                               ghosttyControlsEnabled: ghostty,
                               gateOpen: herdr && ghostty, outcome: outcome, defaultSocketPath: socket, codex: .none)
}

private let target = HerdrPaneTarget(sessionID: session, agent: .claude, paneID: "w1:p1")

// MARK: - Agreement

@Test func herdrInputsBindWhenTheHookRecordAndTheScanAgree() {
    #expect(binding() == .bound(target))
    #expect(binding().target == target)
}

@Test func herdrInputsKeepClaudeSessionsAsWritten() {
    let claude = "Claude-Session-A"
    let key = HerdrSessionKey(agent: .claude, sessionID: claude)
    #expect(key.sessionID == claude)
    let pane = herdrPane(session: HerdrAgentSession(source: "herdr:claude", agent: "claude", kind: "id", value: claude))
    #expect(binding(key, records: [record(claude)], outcome: scan(panes: [pane]))
        == .bound(HerdrPaneTarget(sessionID: claude, agent: .claude, paneID: "w1:p1")))
    #expect(binding(HerdrSessionKey(agent: .claude, sessionID: claude.lowercased()),
                    records: [record(claude)], outcome: scan(panes: [pane])) == .notInHerdr)
}

@Test func herdrInputsIgnoreCodexHookRecordsForClaude() {
    // ADR 0012: a Codex record naming this Claude pane later must not void the Claude binding.
    #expect(binding(records: [record(), record(otherSession, agent: .codex, at: 1_200)]) == .bound(target))
    // Nor does a Codex record put a Codex session in herdr: Codex binds only by title.
    let codexKey = HerdrSessionKey(agent: .codex, sessionID: otherSession)
    #expect(binding(codexKey, records: [record(otherSession, agent: .codex, at: 1_200)]) == .notInHerdr)
}

@Test func herdrInputsDisagreementIsUnavailableNotNotInHerdr() {
    let other = herdrPane(session: HerdrAgentSession(source: "herdr:claude", agent: "claude", kind: "id", value: otherSession))
    #expect(binding(outcome: scan(panes: [other])) == .unavailable(.binding(.agentSessionMismatch)))
    #expect(binding(outcome: scan(panes: [herdrPane(session: nil)])) == .unavailable(.binding(.agentSessionNull)))
    let path = herdrPane(session: HerdrAgentSession(source: "herdr:claude", agent: "claude", kind: "path", value: session))
    #expect(binding(outcome: scan(panes: [path])) == .unavailable(.binding(.agentSessionMismatch)))
    let wrongAgent = herdrPane(session: HerdrAgentSession(source: "herdr:codex", agent: "codex", kind: "id", value: session))
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
    #expect(binding(outcome: scan(integration: [.claude: .current(version: 8)])) == .bound(target))
    for state in [HerdrIntegrationState.outdated, .notInstalled, .unparseable] {
        #expect(binding(outcome: scan(integration: [.claude: state, .codex: .current(version: 10)]))
            == .unavailable(.binding(.integrationNotCurrent(.claude, state))))
    }
    #expect(binding(outcome: scan(integration: [.codex: .current(version: 10)]))
        == .unavailable(.binding(.integrationNotCurrent(.claude, nil))))
    // Parsed output reaches the rules unchanged.
    let parsed = HerdrIntegrationReport(parsing: "claude: outdated (v7 < v8) (/x)\ncodex: current (v10) (/y)\n")
    #expect(binding(outcome: scan(integration: parsed.states))
        == .unavailable(.binding(.integrationNotCurrent(.claude, .outdated))))
}

// MARK: - Scan-level states

@Test func herdrInputsReportGateAndScanStatesForSessionsInHerdr() {
    #expect(binding(ghostty: false) == .unavailable(.ghosttyControlsOff))
    // herdr's own switch closes the gate before Ghostty controls are consulted.
    #expect(binding(herdr: false) == .unavailable(.herdrSwitchedOff))
    #expect(binding(herdr: false, ghostty: false) == .unavailable(.herdrSwitchedOff))
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
    #expect(binding(records: [record(pane: nil)], herdr: false, outcome: nil) == .notInHerdr)
    #expect(binding(records: [record(pane: nil)], outcome: .unavailable(.notRunning)) == .notInHerdr)
    // A disagreeing tie at the newest time is uncertain, not "not in herdr".
    #expect(binding(records: [record(at: 1_150), record(pane: nil, at: 1_150)])
        == .unavailable(.binding(.conflictingHookRecords)))
}

// MARK: - Gate

@Test func herdrGateRequiresHerdrsSwitchAndARecordedPaneOrTheCodexGate() {
    #expect(HerdrBindingInputs.allowsContact(herdrEnabled: true, paneIDs: ["w1:p1"]))
    #expect(!HerdrBindingInputs.allowsContact(herdrEnabled: false, paneIDs: ["w1:p1"]))
    #expect(!HerdrBindingInputs.allowsContact(herdrEnabled: true, paneIDs: []))
    #expect(HerdrBindingInputs.allowsContact(herdrEnabled: true, paneIDs: [], codexGate: true))
    #expect(!HerdrBindingInputs.allowsContact(herdrEnabled: false, paneIDs: [], codexGate: true))
}

@Test func herdrGatePaneIDsComeFromLiveClaudeSessionsNewestEvents() {
    let codexKey = HerdrSessionKey(agent: .codex, sessionID: "9f3c2b10-0000-4222-8333-444455556666")
    let records = [
        record(at: 1_100),
        record(otherSession, pane: "w2:p1", at: 1_100),
        record(otherSession, pane: nil, at: 1_200),   // newest event left herdr
        record(codexKey.sessionID, agent: .codex, pane: "w3:p1"),   // Codex records never open the gate
        record("ended-claude", pane: "w4:p1"),
    ]
    let live: Set = [claudeKey, HerdrSessionKey(agent: .claude, sessionID: otherSession), codexKey]
    #expect(HerdrBindingInputs.gatePaneIDs(records: records, liveSessions: live) == ["w1:p1"])
    #expect(HerdrBindingInputs.gatePaneIDs(records: records, liveSessions: []).isEmpty)
}

// MARK: - Hook records

@Test func herdrHookRecordsDecodeHerdlyEventsOnly() {
    let codex: [String: Any] = ["hook_event_name": "Stop", "session_id": session.uppercased(), "source": "herdly-hook-v1",
                                "captured_at": 1_100.5, HerdrPaneID.recordKey: "w1:p1",
                                HerdrSocketPath.recordKey: socket]
    #expect(HerdrBindingInputs.hookRecord(from: codex) == record(agent: .codex, at: 1_100.5))
    let claude: [String: Any] = ["hook_event_name": "Stop", "session_id": "Claude-A", "source": "herdly-claude-hook-v1",
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
    let base: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": session, "source": "herdly-hook-v1"]
    try write(base.merging(["captured_at": 1_100.0, HerdrPaneID.recordKey: "w1:p1", HerdrSocketPath.recordKey: socket]) { $1 })
    try write(base.merging(["captured_at": 1_200.0, HerdrPaneID.recordKey: "w1:p2", HerdrSocketPath.recordKey: socket]) { $1 })
    try write(["request_id": UUID().uuidString])
    try Data("not json".utf8).write(to: directory.appendingPathComponent("broken.json"))

    let first = HerdrHookRecordReader.read(directories: [directory])
    #expect(first.records == [record(agent: .codex, pane: "w1:p2", at: 1_200)])
    #expect(first.cache.count == 4)
    #expect(first.cache.values.compactMap { $0 }.count == 2)

    // A cached path is not decoded again: a stand-in cache entry wins over the file.
    var stale = first.cache
    let newestPath = try #require(first.cache.first { $0.value?.paneID == "w1:p2" }?.key)
    stale[newestPath] = .some(record(agent: .codex, pane: "w9:p9", at: 1_200))
    #expect(HerdrHookRecordReader.read(directories: [directory], cache: stale).records == [record(agent: .codex, pane: "w9:p9", at: 1_200)])
    // Paths no longer listed drop out of the cache.
    let gone = HerdrHookRecordReader.read(directories: [directory], cache: ["/nowhere.json": record()])
    #expect(gone.cache["/nowhere.json"] == nil)
    #expect(HerdrHookRecordReader.read(directories: [directory.appendingPathComponent("missing")]).records.isEmpty)
}

// MARK: - Foreground process (ADR 0008, #148)

@Test func herdrInputsBindClaudeOnlyWhileClaudeIsInThePanesForeground() {
    #expect(binding(outcome: scan(processInfo: ["w1:p1": foreground()])) == .bound(target))
    // agent_session still names the session, but Claude has exited to the shell.
    #expect(binding(outcome: scan(processInfo: ["w1:p1": foreground("w1:p1", ["zsh"])]))
        == .unavailable(.binding(.foregroundProcesses(.claude, count: 0))))
    #expect(binding(outcome: scan(processInfo: ["w1:p1": .failure(.malformedReply)]))
        == .unavailable(.binding(.processInfoUnavailable(.malformedReply))))
    #expect(binding(outcome: scan(processInfo: ["w1:p1": .failure(.timeout)]))
        == .unavailable(.binding(.processInfoUnavailable(.timeout))))
    #expect(binding(outcome: scan(processInfo: [:])) == .unavailable(.binding(.processInfoUnavailable(nil))))
    // Every reason lands in the generic group and keeps its exact text for diagnostics.
    let cause = HerdrUnavailableCause.session(.binding(.foregroundProcesses(.claude, count: 0)))
    #expect(cause.group == .generic)
    #expect(cause.diagnostic.contains("foregroundProcesses"))
}

@Test func herdrScanRequestAsksAboutTheClaudePanesThatOpenedTheGate() {
    let request = HerdrBindingInputs.scanRequest(paneIDs: ["w1:p1", "w9:p9"], codex: .none)
    #expect(request.includeIntegration)
    #expect(request.processInfoPaneIDs == ["w1:p1", "w9:p9"])
    // A recorded pane missing from the snapshot is not asked about.
    let snapshot = scan(panes: [herdrPane(), herdrPane("w1:p2", tab: "w1:t2")]).scan!.snapshot
    #expect(request.processInfoPanes(in: snapshot) == ["w1:p1"])
}

@MainActor @Test func herdrClaudeOpenFailsWhenTheRecheckFindsClaudeGoneAfterTheScanPassed() async {
    let key = claudeKey
    func fresh(_ outcome: HerdrScanOutcome) -> HerdrSessionBinding {
        binding(key, outcome: outcome)
    }
    // The scheduled scan bound the session, so the card offered Open.
    #expect(fresh(scan()) == .bound(target))
    // By the click, Claude has exited in the pane: Open's revalidation re-reads process info and fails
    // before any herdr focus or Ghostty request.
    let gone = scan(processInfo: ["w1:p1": foreground("w1:p1", ["zsh"])])
    var calls: [String] = []
    let effects = HerdrOpenEffects(
        now: { 5_000 },
        ttySupport: { calls.append("ttySupport"); return .supported },
        revalidate: { calls.append("revalidate"); return (fresh(gone), gone) },
        ghosttySnapshot: { calls.append("ghostty"); return nil },
        focus: { pane in calls.append("focus \(pane)"); return .success(.accepted(type: "agent_focused")) },
        select: { _, _ in calls.append("select"); return true })
    let result = await HerdrOpenSequence.run(effects)
    #expect(result == .unavailable(.binding(.binding(.foregroundProcesses(.claude, count: 0)))))
    #expect(calls == ["ttySupport", "revalidate"])
    #expect(HerdrPresentation.group(result.failure!) == .generic)
}

@Test func herdrScanRequestAsksAboutRecordedClaudePanesBeforeCodexTitlesUnderTheCap() {
    let codexTitle = "01a1151d-4e9d-7e53-a0b0-10d6e..."
    let titled = (0..<20).map { herdrPane(String(format: "w1:p%02d", $0), title: codexTitle) }
    let snapshot = scan(panes: titled + [herdrPane("w9:p1")]).scan!.snapshot
    let request = HerdrScanRequest(includeIntegration: true, processInfoTitles: [codexTitle], processInfoPaneIDs: ["w9:p1"])
    let panes = request.processInfoPanes(in: snapshot)
    #expect(panes.count == HerdrScanRequest.maximumProcessInfoRequests)
    #expect(panes.first == "w9:p1")
    #expect(Array(panes.dropFirst()) == Array(titled.map(\.paneID).sorted().prefix(HerdrScanRequest.maximumProcessInfoRequests - 1)))
}

@Test func herdrInputsPassTheRegistryPIDToTheForegroundRule() {
    // A native-installer Claude: pid 83378 is named for its version.
    let outcome = scan(processInfo: ["w1:p1": foreground("w1:p1", ["2.1.293", "node"])])
    func bind(_ process: ClaudeSessionProcess) -> HerdrSessionBinding {
        HerdrBindingInputs.binding(for: claudeKey, liveness: .live, hookRecords: [record()], herdrEnabled: true,
                                   ghosttyControlsEnabled: true,
                                   gateOpen: true, outcome: outcome, defaultSocketPath: socket, codex: .none,
                                   claudeProcess: process)
    }
    #expect(bind(.identified(pid: 83378)) == .bound(target))
    #expect(bind(.identified(pid: 99999)) == .unavailable(.binding(.agentProcessNotInForeground(.claude))))
    #expect(bind(.unidentified) == .unavailable(.binding(.foregroundProcesses(.claude, count: 0))))
    #expect(bind(.ambiguous) == .unavailable(.binding(.agentProcessAmbiguous(.claude))))
    // Both new reasons land in the generic group and keep their exact text for diagnostics.
    for reason in [HerdrBindingUnavailable.agentProcessNotInForeground(.claude), .agentProcessAmbiguous(.claude)] {
        let cause = HerdrUnavailableCause.session(.binding(reason))
        #expect(cause.group == .generic)
        #expect(cause.diagnostic.contains("\(reason)"))
    }
}

// MARK: - The session's process from every root's inventory

private func inventory(_ root: String, _ sessions: [(id: String, pid: Int32?)],
                       kind: ClaudeInventoryKind = .interactive) -> ClaudeInventoryScan {
    ClaudeInventoryScan(sourceScope: root, observedAt: 10, sessions: sessions.map {
        ClaudeInventorySession(sessionID: $0.id, kind: kind, startedAt: 1,
                               lifecycle: kind == .interactive ? .interactive(status: "busy") : .background(state: "working"),
                               pid: $0.pid)
    })
}

@Test func claudeSessionProcessIsIdentifiedByTheOneRegistryThatListsIt() {
    let identified = ClaudeSessionProcess(sessionID: session, inventories: [
        inventory("/tmp/one", [(session, 83378), (otherSession, 83400)]),
        inventory("/tmp/two", [("5b2e9c40-2222-4333-8444-555566667777", 83500)]),
        // A root that cannot be read lists nothing.
        .unavailable(sourceScope: "/tmp/three", observedAt: 10, reason: ClaudeInventoryDecoder.invalidMessage),
    ])
    #expect(identified == .identified(pid: 83378))
    // A background holder of the session elsewhere is not a second interactive one.
    #expect(ClaudeSessionProcess(sessionID: session, inventories: [
        inventory("/tmp/one", [(session, 83378)]), inventory("/tmp/two", [(session, 83600)], kind: .background),
    ]) == .identified(pid: 83378))
}

@Test func claudeSessionProcessIsUnidentifiedWithoutARegistryPID() {
    // No inventory lists the session, or the one that does is `claude agents --json`'s, with no PID.
    #expect(ClaudeSessionProcess(sessionID: session, inventories: []) == .unidentified)
    #expect(ClaudeSessionProcess(sessionID: session, inventories: [inventory("/tmp/one", [(otherSession, 83400)])])
        == .unidentified)
    #expect(ClaudeSessionProcess(sessionID: session, inventories: [inventory("/tmp/one", [(session, nil)])])
        == .unidentified)
    // Claude session IDs are compared exactly, as `HerdrSessionKey` keeps them.
    #expect(ClaudeSessionProcess(sessionID: session.uppercased(), inventories: [inventory("/tmp/one", [(session, 83378)])])
        == .unidentified)
}

@Test func claudeSessionProcessIsAmbiguousWhenSeveralRootsListTheSession() {
    // Whatever each root's source, and even when both name the same PID.
    let pids: [(Int32?, Int32?)] = [(83378, 83600), (83378, 83378), (83378, nil), (nil, nil)]
    for (first, second) in pids {
        #expect(ClaudeSessionProcess(sessionID: session, inventories: [
            inventory("/tmp/one", [(session, first)]), inventory("/tmp/two", [(session, second)]),
        ]) == .ambiguous, "\(String(describing: first)), \(String(describing: second))")
    }
    // A root whose inventory found two interactive holders of the session is unavailable, and ambiguous.
    #expect(ClaudeSessionProcess(sessionID: session, inventories: [
        inventory("/tmp/one", [(session, 83378)]),
        .unavailable(sourceScope: "/tmp/two", observedAt: 10, reason: ClaudeInventoryDecoder.incompleteMessage,
                     ambiguousSessionIDs: [session]),
    ]) == .ambiguous)
}

private func parkedInventory(_ root: String, _ links: [String: ClaudeSessionProcess]) -> ClaudeInventoryScan {
    ClaudeInventoryScan(sourceScope: root, observedAt: 10, backgroundSessionIDs: Set(links.keys), parkedJobProcesses: links)
}

@Test func claudeSessionProcessFollowsTheParkedJobLinkOnlyWhenItIsTheOneHolder() {
    // A background job continued from a parked session is held by the process that parked it.
    #expect(ClaudeSessionProcess(sessionID: session, inventories: [
        parkedInventory("/tmp/one", [session: .identified(pid: 83378)]), inventory("/tmp/two", [(otherSession, 83400)]),
    ]) == .identified(pid: 83378))
    #expect(ClaudeSessionProcess(sessionID: session, inventories: [parkedInventory("/tmp/one", [session: .ambiguous])])
        == .ambiguous)
    // A link and an interactive holder, or links from two roots, name no one process.
    #expect(ClaudeSessionProcess(sessionID: session, inventories: [
        parkedInventory("/tmp/one", [session: .identified(pid: 83378)]), inventory("/tmp/two", [(session, 83600)]),
    ]) == .ambiguous)
    #expect(ClaudeSessionProcess(sessionID: session, inventories: [
        parkedInventory("/tmp/one", [session: .identified(pid: 83378)]),
        parkedInventory("/tmp/two", [session: .identified(pid: 83378)]),
    ]) == .ambiguous)
    // An unavailable root's link does not count.
    #expect(ClaudeSessionProcess(sessionID: session, inventories: [
        .unavailable(sourceScope: "/tmp/one", observedAt: 10, reason: ClaudeInventoryDecoder.invalidMessage),
    ]) == .unidentified)
}

@Test func herdrClaudeBindingAcceptsTheParkingProcessForABackgroundJob() {
    // The pane's foreground process, 83378, parked the session's job and displays it.
    let outcome = scan(processInfo: ["w1:p1": foreground("w1:p1", ["2.1.296", "node"])])
    func bind(_ link: ClaudeSessionProcess) -> HerdrSessionBinding {
        HerdrBindingInputs.binding(for: claudeKey, liveness: .live, hookRecords: [record()], herdrEnabled: true,
                                   ghosttyControlsEnabled: true,
                                   gateOpen: true, outcome: outcome, defaultSocketPath: socket, codex: .none,
                                   claudeProcess: ClaudeSessionProcess(sessionID: session,
                                                                       inventories: [parkedInventory("/tmp/one", [session: link])]))
    }
    #expect(bind(.identified(pid: 83378)) == .bound(target))
    // A job parked from another pane's process does not bind this pane.
    #expect(bind(.identified(pid: 99999)) == .unavailable(.binding(.agentProcessNotInForeground(.claude))))
    #expect(bind(.ambiguous) == .unavailable(.binding(.agentProcessAmbiguous(.claude))))
}

@Test func herdrClaudeBindingFollowsTheSessionProcessSelectedFromInventories() {
    // The pane runs the session's native-installer process, 83378, named for its version.
    let outcome = scan(processInfo: ["w1:p1": foreground("w1:p1", ["2.1.293", "node"])])
    func bind(_ inventories: [ClaudeInventoryScan], records: [HerdrHookPaneRecord] = [record()]) -> HerdrSessionBinding {
        HerdrBindingInputs.binding(for: claudeKey, liveness: .live, hookRecords: records, herdrEnabled: true,
                                   ghosttyControlsEnabled: true,
                                   gateOpen: true, outcome: outcome, defaultSocketPath: socket, codex: .none,
                                   claudeProcess: ClaudeSessionProcess(sessionID: session, inventories: inventories))
    }
    // One root's registry names it: bound by PID.
    #expect(bind([inventory("/tmp/one", [(session, 83378)])]) == .bound(target))
    // No registry PID: the name rule applies, and `2.1.293` is not `claude`.
    #expect(bind([inventory("/tmp/one", [(session, nil)])]) == .unavailable(.binding(.foregroundProcesses(.claude, count: 0))))
    // Two roots list the session: unavailable, even though one of them names the pane's process.
    let twoRoots = [inventory("/tmp/one", [(session, 83378)]), inventory("/tmp/two", [(session, 83600)])]
    #expect(bind(twoRoots) == .unavailable(.binding(.agentProcessAmbiguous(.claude))))
    // A session whose newest hook event carried no pane is still not in herdr, so the Ghostty rules apply.
    #expect(bind(twoRoots, records: [record(pane: nil)]) == .notInHerdr)
}
