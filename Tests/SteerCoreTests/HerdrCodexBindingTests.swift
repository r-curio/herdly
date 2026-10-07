import Foundation
import Testing
@testable import SteerCore

// ADR 0012: a Codex CLI session binds to a herdr pane by its title and the pane's foreground
// process, never by hook records, `agent_session` or herdr's Codex integration.

private let session = "01a1151d-4e9d-7e53-a0b0-10d6e0000001"
private let sibling = "01a1151d-4e9d-7e53-a0b0-10d6e0000002"   // same 29-character prefix
private let otherSession = "9f3c2b10-1111-4222-8333-444455556666"
private let socket = "/Users/test/.config/herdr/herdr.sock"
private let title = "01a1151d-4e9d-7e53-a0b0-10d6e..."
private let otherTitle = "9f3c2b10-1111-4222-8333-44445..."
private let codexKey = HerdrSessionKey(agent: .codex, sessionID: session)
private let target = HerdrPaneTarget(sessionID: session, agent: .codex, paneID: "w1:p1")

private func pane(_ paneID: String = "w1:p1", tab: String = "w1:t1", agent: String? = "codex",
                  title paneTitle: String? = title, status: HerdrAgentStatus = .working) -> HerdrPane {
    // herdr's own report for a daemon-run Codex is empty or wrong; the rule must not need it.
    HerdrPane(paneID: paneID, tabID: tab, workspaceID: "w1", focused: true, agent: agent, agentStatus: status,
              agentSession: nil, terminalTitle: paneTitle)
}

private func process(_ name: String = "codex", pid: Int32 = 60859, argv: [String]? = nil) -> HerdrForegroundProcess {
    HerdrForegroundProcess(pid: pid, name: name, argv: argv ?? [name], cwd: "/lab")
}

private func info(_ paneID: String = "w1:p1", _ processes: [HerdrForegroundProcess] = [process()])
    -> Result<HerdrProcessInfo, HerdrUnavailableReason> {
    .success(HerdrProcessInfo(paneID: paneID, shellPID: 100, foregroundProcessGroupID: processes.first?.pid,
                              foregroundProcesses: processes))
}

private func scan(panes: [HerdrPane] = [pane()],
                  tabs: [HerdrTab] = [HerdrTab(tabID: "w1:t1", workspaceID: "w1", focused: true, paneCount: 1),
                                      HerdrTab(tabID: "w1:t2", workspaceID: "w1", focused: false, paneCount: 1)],
                  layouts: [HerdrLayout] = [],
                  protocolVersion: Int = 22,
                  integration: [HerdrAgentKind: HerdrIntegrationState] = [:],
                  client: Result<HerdrAttachedClient, HerdrUnavailableReason>
                      = .success(HerdrAttachedClient(pid: 93954, tty: "ttys015", serverPID: 900)),
                  serverStartedAt: Double? = nil,
                  processInfo: [String: Result<HerdrProcessInfo, HerdrUnavailableReason>] = ["w1:p1": info()]) -> HerdrScan {
    HerdrScan(snapshot: HerdrSnapshot(version: "0.9.3", protocolVersion: protocolVersion, focusedWorkspaceID: "w1",
                                      focusedTabID: "w1:t1", focusedPaneID: "w1:p1", tabs: tabs, panes: panes,
                                      layouts: layouts),
              integration: HerdrIntegrationReport(states: integration), client: client,
              serverStartedAt: serverStartedAt, processInfo: processInfo)
}

private func evaluate(_ sessionID: String = session, liveness: HerdrSessionLiveness = .live,
                      live: Set<String> = [session, otherSession], scan: HerdrScan = scan()) -> HerdrBinding {
    HerdrCodexBindingRules.evaluate(sessionID: sessionID, liveness: liveness, liveSessions: live, scan: scan)
}

private func binding(_ key: HerdrSessionKey = codexKey, liveness: HerdrSessionLiveness = .live,
                     records: [HerdrHookPaneRecord] = [], ghosttyControls: Bool = true,
                     ghostty: Set<String>? = [otherTitle], live: Set<String> = [session, otherSession],
                     outcome: HerdrScanOutcome? = .available(scan())) -> HerdrSessionBinding {
    HerdrBindingInputs.binding(for: key, liveness: liveness, hookRecords: records, ghosttyControlsEnabled: ghosttyControls,
                               outcome: outcome, defaultSocketPath: socket,
                               codex: HerdrCodexTitles(liveSessions: live, ghostty: ghostty))
}

// MARK: - Binding

@Test func herdrCodexBindsByTitleAndOneForegroundCodexProcess() {
    #expect(evaluate() == .bound(target))
    #expect(binding() == .bound(target))
    // No integration, server identity or agent_session is needed.
    #expect(scan().integration.states.isEmpty)
    #expect(scan().serverStartedAt == nil)
}

@Test func herdrCodexNormalizesUppercaseSessionIDs() {
    let upper = HerdrSessionKey(agent: .codex, sessionID: session.uppercased())
    #expect(binding(upper, live: [session.uppercased(), otherSession]) == .bound(target))
    #expect(HerdrCodexBindingRules.title(forSession: session.uppercased()) == title)
    #expect(HerdrCodexBindingRules.title(forSession: "not-a-uuid") == nil)
}

@Test func herdrCodexTitleMustMatchExactlyOnePane() {
    #expect(evaluate(scan: scan(panes: [pane(title: nil)])) == .unavailable(.titleNotInHerdr))
    #expect(evaluate(scan: scan(panes: [pane(title: otherTitle)])) == .unavailable(.titleNotInHerdr))
    // Neither a longer, a shorter nor an uppercase title is the shortened identifier.
    for near in [title + " ", String(title.dropLast()), title.uppercased(), session] {
        #expect(evaluate(scan: scan(panes: [pane(title: near)])) == .unavailable(.titleNotInHerdr))
    }
    let duplicate = scan(panes: [pane(), pane("w1:p2", tab: "w1:t2")],
                         processInfo: ["w1:p1": info(), "w1:p2": info("w1:p2")])
    #expect(evaluate(scan: duplicate) == .unavailable(.duplicateTitles(["w1:p1", "w1:p2"])))
    let reversed = scan(panes: [pane("w1:p2", tab: "w1:t2"), pane()],
                        processInfo: ["w1:p1": info(), "w1:p2": info("w1:p2")])
    #expect(evaluate(scan: reversed) == .unavailable(.duplicateTitles(["w1:p1", "w1:p2"])))
}

@Test func herdrCodexPrefixMustBeUniqueAmongLiveSessions() {
    #expect(evaluate(live: [session, sibling]) == .unavailable(.sessionPrefixNotUnique(2)))
    #expect(evaluate(sibling, live: [session, sibling]) == .unavailable(.sessionPrefixNotUnique(2)))
    // A session Steer does not track as live cannot claim the title.
    #expect(evaluate(live: [otherSession]) == .unavailable(.sessionPrefixNotUnique(0)))
    #expect(evaluate(liveness: .ended) == .unavailable(.sessionEnded))
}

@Test func herdrCodexRequiresExactlyOneForegroundProcessNamedCodex() {
    #expect(evaluate(scan: scan(processInfo: ["w1:p1": info("w1:p1", [])]))
        == .unavailable(.foregroundProcesses(.codex, count: 0)))
    #expect(evaluate(scan: scan(processInfo: ["w1:p1": info("w1:p1", [process(pid: 1), process(pid: 2)])]))
        == .unavailable(.foregroundProcesses(.codex, count: 2)))
    // Only argv mentions codex: a shell, editor or script is not Codex.
    for impostor in [process("zsh", argv: ["zsh", "-c", "codex"]), process("node", argv: ["node", "/usr/local/bin/codex"]),
                     process("vim", argv: ["vim", "codex.md"]), process("Codex"), process("codex-helper")] {
        #expect(evaluate(scan: scan(processInfo: ["w1:p1": info("w1:p1", [impostor])]))
            == .unavailable(.foregroundProcesses(.codex, count: 0)))
    }
    // Codex's own children in the foreground group do not matter.
    #expect(evaluate(scan: scan(processInfo: ["w1:p1": info("w1:p1", [process(), process("rg", pid: 2)])])) == .bound(target))
}

@Test func herdrCodexProcessInfoMustBeReadForThatPane() {
    #expect(evaluate(scan: scan(processInfo: [:])) == .unavailable(.processInfoUnavailable(nil)))
    for reason in [HerdrUnavailableReason.timeout, .malformedReply, .requestRefused(code: "pane_not_found"), .notRunning] {
        #expect(evaluate(scan: scan(processInfo: ["w1:p1": .failure(reason)])) == .unavailable(.processInfoUnavailable(reason)))
    }
    #expect(evaluate(scan: scan(processInfo: ["w1:p1": info("w1:p9")])) == .unavailable(.processInfoUnavailable(.malformedReply)))
}

@Test func herdrCodexDetectedAgentOnlyVetoes() {
    #expect(evaluate(scan: scan(panes: [pane(agent: nil)])) == .bound(target))
    #expect(evaluate(scan: scan(panes: [pane(agent: "claude")])) == .unavailable(.detectedAgent("claude")))
    #expect(evaluate(scan: scan(panes: [pane(agent: "opencode")])) == .unavailable(.detectedAgent("opencode")))
    #expect(evaluate(scan: scan(panes: [pane(agent: String(repeating: "x", count: 100))]))
        == .unavailable(.detectedAgent(String(repeating: "x", count: 64))))
}

@Test func herdrCodexKeepsADR0008TargetChecks() {
    #expect(evaluate(scan: scan(tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", focused: true, paneCount: 2)]))
        == .unavailable(.split))
    #expect(evaluate(scan: scan(layouts: [HerdrLayout(tabID: "w1:t1", zoomed: true, paneIDs: ["w1:p1", "w1:p9"])]))
        == .unavailable(.split))
    #expect(evaluate(scan: scan(client: .failure(.wrongClientCount(0)))) == .unavailable(.noClient))
    #expect(evaluate(scan: scan(client: .failure(.wrongClientCount(2)))) == .unavailable(.multipleClients(2)))
    #expect(evaluate(scan: scan(client: .failure(.nonGhosttyClient))) == .unavailable(.nonGhosttyClient))
    #expect(evaluate(scan: scan(protocolVersion: 23)) == .unavailable(.unsupportedProtocol(23)))
    #expect(evaluate(scan: scan(panes: [pane(), pane(agent: nil)])) == .unavailable(.conflictingPaneObservations))
}

@Test func herdrCodexIgnoresHookRecordsAgentSessionAndIntegration() {
    // A daemon-run hook records the pane of whichever CLI started the daemon.
    let tainted = HerdrHookPaneRecord(sessionID: session, agent: .codex, paneID: "w1:p2", socketPath: socket, recordedAt: 1)
    #expect(binding(records: [tainted]) == .bound(target))
    let outdated = scan(integration: [.codex: .outdated, .claude: .notInstalled])
    #expect(binding(outcome: .available(outdated)) == .bound(target))
    #expect(HerdrScanOutcome.available(outdated).targetReason(for: .codex) == nil)
    #expect(HerdrScanOutcome.available(outdated).targetReason(for: .claude) == .integrationNotCurrent(.claude))
}

@Test func herdrCodexRestartThatResumedTheSessionStillBinds() {
    // Codex restarted in the pane with a new PID and resumed the same session: the title still names it.
    let before = scan(processInfo: ["w1:p1": info("w1:p1", [process(pid: 60859)])])
    let after = scan(serverStartedAt: 5_000, processInfo: ["w1:p1": info("w1:p1", [process(pid: 73257)])])
    #expect(evaluate(scan: before) == .bound(target))
    #expect(evaluate(scan: after) == .bound(target))
    // herdr's server restarting does not void it either: no hook event is needed.
    #expect(binding(records: [HerdrHookPaneRecord(sessionID: session, agent: .codex, paneID: "w1:p1", socketPath: socket,
                                                  recordedAt: 1)],
                    outcome: .available(after)) == .bound(target))
}

// MARK: - Route

@Test func herdrCodexRouteFollowsTheTitle() {
    // herdr only.
    #expect(binding(ghostty: [otherTitle]) == .bound(target))
    #expect(binding(ghostty: []) == .bound(target))
    // Ghostty only: herdr has nothing to say, and the Ghostty tab rules apply.
    #expect(binding(ghostty: [title], outcome: .available(scan(panes: [pane(title: otherTitle)]))) == .notInHerdr)
    // Both: the route is unknown.
    #expect(binding(ghostty: [title]) == .unavailable(.binding(.titleInHerdrAndGhostty)))
    // Neither: not in herdr, and the Ghostty rules find no tab, so the session stays unavailable.
    let neither = scan(panes: [pane(title: otherTitle)])
    #expect(binding(ghostty: [], outcome: .available(neither)) == .notInHerdr)
    #expect(GhosttyMatch.target(title: title, live: [title], snapshot: ghosttySnapshot(titles: [])) == nil)
}

@Test func herdrCodexIsNotInHerdrWithoutAScanOrGhosttyInventory() {
    #expect(binding(outcome: nil) == .notInHerdr)
    #expect(binding(outcome: .unavailable(.notRunning)) == .notInHerdr)
    #expect(binding(ghosttyControls: false) == .notInHerdr)
    #expect(binding(ghostty: nil) == .notInHerdr)
}

@Test func herdrCodexBindingFailuresAreUnavailableNotNotInHerdr() {
    #expect(binding(liveness: .ended) == .unavailable(.binding(.sessionEnded)))
    #expect(binding(outcome: .available(scan(processInfo: [:]))) == .unavailable(.binding(.processInfoUnavailable(nil))))
    for reason in [HerdrBindingUnavailable.titleInHerdrAndGhostty, .duplicateTitles(["a", "b"]), .sessionPrefixNotUnique(2),
                   .detectedAgent("claude"), .processInfoUnavailable(nil), .foregroundProcesses(.codex, count: 0),
                   .titleNotInHerdr] {
        #expect(HerdrPresentation.group(reason) == .generic)
    }
}

// MARK: - Gate and scan request

@Test func herdrCodexGateOpensForATitleOutsideGhosttyWithATrustedSocket() {
    let codex = HerdrCodexTitles(liveSessions: [session.uppercased(), otherSession], ghostty: [otherTitle])
    #expect(codex.outsideGhostty == [title])
    #expect(HerdrBindingInputs.codexGateOpens(codex, defaultSocketTrusted: true))
    #expect(!HerdrBindingInputs.codexGateOpens(codex, defaultSocketTrusted: false))
    let allInGhostty = HerdrCodexTitles(liveSessions: [session], ghostty: [title, otherTitle])
    #expect(!HerdrBindingInputs.codexGateOpens(allInGhostty, defaultSocketTrusted: true))
    // Without a known Ghostty inventory nothing is known to be outside it.
    #expect(!HerdrBindingInputs.codexGateOpens(HerdrCodexTitles(liveSessions: [session], ghostty: nil), defaultSocketTrusted: true))
    #expect(!HerdrBindingInputs.codexGateOpens(.none, defaultSocketTrusted: true))
}

@Test func herdrScanRequestReadsIntegrationForClaudeAndProcessInfoForCodexTitles() {
    let codex = HerdrCodexTitles(liveSessions: [session, otherSession], ghostty: [otherTitle])
    let codexOnly = HerdrBindingInputs.scanRequest(paneIDs: [], codex: codex)
    #expect(codexOnly == HerdrScanRequest(includeIntegration: false, processInfoTitles: [title]))
    #expect(HerdrBindingInputs.scanRequest(paneIDs: ["w3:p1"], codex: .none)
        == HerdrScanRequest(includeIntegration: true, processInfoTitles: [], processInfoPaneIDs: ["w3:p1"]))
    let snapshot = scan(panes: [pane("w1:p3", tab: "w1:t2"), pane(), pane("w1:p2", title: otherTitle), pane("w1:p4", title: nil)]).snapshot
    #expect(codexOnly.processInfoPanes(in: snapshot) == ["w1:p1", "w1:p3"])
    #expect(HerdrScanRequest().processInfoPanes(in: snapshot).isEmpty)
    let crowded = HerdrSnapshot(version: "0.9.3", protocolVersion: 22, focusedWorkspaceID: nil, focusedTabID: nil,
                                focusedPaneID: nil, tabs: [],
                                panes: (0..<40).map { pane(String(format: "w1:p%02d", $0)) }, layouts: [])
    let bounded = codexOnly.processInfoPanes(in: crowded)
    #expect(bounded.count == HerdrScanRequest.maximumProcessInfoRequests)
    #expect(bounded == bounded.sorted())
}

@Test func herdrSettingsListNoCodexIntegrationProblem() {
    let outdated = HerdrScanOutcome.available(scan(integration: [.codex: .outdated, .claude: .current(version: 10)]))
    let row = HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: outdated,
                                            agentsSeen: [.codex, .claude], ttySupport: .supported)
    #expect(row.problems.isEmpty)
    #expect(row.badge == .ready)
    let claudeOutdated = HerdrScanOutcome.available(scan(integration: [.claude: .outdated]))
    #expect(HerdrPresentation.settingsRow(inUse: true, ghosttyControlsEnabled: true, outcome: claudeOutdated,
                                          agentsSeen: [.claude], ttySupport: .supported).problems == [.integration(.claude)])
}

private func ghosttySnapshot(titles: [String]) -> GhosttySnapshot {
    let terminals = titles.enumerated().map { #"{"id":"t\#($0.offset)","name":"\#($0.element)"}"# }.joined(separator: ",")
    let json = #"{"status":"ok","windows":[{"id":"w","tabs":[{"id":"tab","terminals":[\#(terminals)]}]}],"front_window_id":"w"}"#
    return try! JSONDecoder().decode(GhosttySnapshot.self, from: Data(json.utf8))
}
