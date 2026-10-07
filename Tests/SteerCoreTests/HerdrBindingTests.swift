import Testing
@testable import SteerCore

private let session = "01a1142d-7a21-7383-a6aa-40030c90d7cf"
private let otherSession = "9f3c2b10-1111-4222-8333-444455556666"
private let defaultSocket = "/Users/test/.config/herdr/herdr.sock"

private func record(
    _ sessionID: String = session,
    agent: HerdrAgentKind = .codex,
    pane: String? = "w1:p1",
    socket: String? = defaultSocket,
    at recordedAt: Double = 100
) -> HerdrHookPaneRecord {
    HerdrHookPaneRecord(sessionID: sessionID, agent: agent, paneID: pane, socketPath: socket, recordedAt: recordedAt)
}

private func pane(
    _ paneID: String = "w1:p1",
    agent: HerdrAgentKind? = .codex,
    session agentSession: String? = session,
    panesInTab: Int = 1,
    title: String? = nil
) -> HerdrPaneObservation {
    HerdrPaneObservation(paneID: paneID, agent: agent, agentSession: agentSession, panesInTab: panesInTab, terminalTitle: title)
}

private func observation(
    protocolVersion: Int? = 22,
    serverStartedAt: Double = 50,
    session herdrSession: HerdrSessionName = .defaultSession,
    clients: [HerdrClientObservation] = [HerdrClientObservation(processID: 93954, ancestryReachesGhostty: true)],
    integrations: [HerdrAgentKind: HerdrIntegrationState] = [.codex: .current(version: 8), .claude: .current(version: 10)],
    panes: [HerdrPaneObservation] = [pane(), pane("w1:p2", agent: nil, session: nil)]
) -> HerdrObservation {
    HerdrObservation(
        protocolVersion: protocolVersion,
        server: HerdrServerInstance(startedAt: serverStartedAt),
        session: herdrSession,
        clients: clients,
        integrations: integrations,
        panes: panes
    )
}

private func evaluate(
    _ sessionID: String = session,
    liveness: HerdrSessionLiveness = .live,
    records: [HerdrHookPaneRecord] = [record()],
    observation: HerdrObservation = observation()
) -> HerdrBinding {
    HerdrBindingRules.evaluate(
        sessionID: sessionID,
        liveness: liveness,
        hookRecords: records,
        observation: observation,
        defaultSocketPath: defaultSocket
    )
}

private let bound = HerdrBinding.bound(HerdrPaneTarget(sessionID: session, agent: .codex, paneID: "w1:p1"))

@Test func herdrPaneBindsWhenHookRecordAndAgentSessionAgreeOnOnePane() {
    #expect(evaluate() == bound)
    let claude = "c1a0de00-0000-4000-8000-000000000001"
    #expect(evaluate(
        claude,
        records: [record(claude, agent: .claude)],
        observation: observation(panes: [pane(agent: .claude, session: claude, title: "Claude Code")])
    ) == .bound(HerdrPaneTarget(sessionID: claude, agent: .claude, paneID: "w1:p1")))
}

@Test func herdrBindingIsVoidWhenTheSessionEnds() {
    #expect(evaluate(liveness: .ended) == .unavailable(.sessionEnded))
}

@Test func herdrBindingNeedsTheSessionsNewestHookEventToCarryThePane() {
    #expect(evaluate(records: []) == .unavailable(.noHookRecord))
    #expect(evaluate(records: [record(pane: nil)]) == .unavailable(.notInHerdr))
    // A newer event without HERDR_PANE_ID supersedes an older one with it.
    #expect(evaluate(records: [record(at: 100), record(pane: nil, at: 110)]) == .unavailable(.notInHerdr))
}

@Test func herdrBindingRequiresAnAllowlistedProtocol() {
    #expect(evaluate(observation: observation(protocolVersion: 23)) == .unavailable(.unsupportedProtocol(23)))
    #expect(evaluate(observation: observation(protocolVersion: nil)) == .unavailable(.unsupportedProtocol(nil)))
}

@Test func herdrBindingRequiresTheDefaultSocketAndSession() {
    #expect(evaluate(records: [record(socket: "/tmp/herdr-work.sock")]) == .unavailable(.namedSession))
    #expect(evaluate(observation: observation(session: .named("steer-probe"))) == .unavailable(.namedSession))
    #expect(evaluate(records: [record(socket: nil)]) == .unavailable(.socketUnknown))
}

@Test func herdrRestartVoidsTheBindingUntilANewHookEventFromThePane() {
    // herdr restarted after the hook event and restored the same agent_session: stale on both
    // sides, so it must not rebind.
    let restarted = observation(serverStartedAt: 200)
    #expect(evaluate(observation: restarted) == .unavailable(.herdrRestarted))
    // A start at the same instant as the record is uncertain and also void.
    #expect(evaluate(records: [record(at: 200)], observation: restarted) == .unavailable(.herdrRestarted))
    // Re-observing the same old record (or a duplicate of it) still does not rebind.
    #expect(evaluate(records: [record(), record()], observation: restarted) == .unavailable(.herdrRestarted))
    // A fresh hook event from the pane after the restart restores the binding.
    #expect(evaluate(records: [record(at: 100), record(at: 210)], observation: restarted) == bound)
}

@Test func herdrBindingIsVoidWhenHerdrReportsNullOrAnotherSession() {
    #expect(evaluate(observation: observation(panes: [pane(session: nil)])) == .unavailable(.agentSessionNull))
    // Before a Codex session's first turn herdr sees the agent but no session.
    #expect(evaluate(observation: observation(panes: [pane(agent: .codex, session: nil)])) == .unavailable(.agentSessionNull))
    #expect(evaluate(observation: observation(panes: [pane(session: otherSession)])) == .unavailable(.agentSessionMismatch))
    #expect(evaluate(observation: observation(panes: [pane(agent: .claude)])) == .unavailable(.agentSessionMismatch))
    #expect(evaluate(observation: observation(panes: [pane("w1:p2")])) == .unavailable(.paneMissing))
    // herdr reports the session in another pane while the recorded pane reports nothing.
    #expect(evaluate(observation: observation(panes: [pane(session: nil), pane("w1:p2")])) == .unavailable(.agentSessionNull))
    #expect(evaluate(observation: observation(panes: [pane(session: otherSession), pane("w1:p2")])) == .unavailable(.agentSessionMismatch))
}

@Test func herdrBindingIsVoidWhenSeveralPanesReportTheSession() {
    let panes = [pane(), pane("w2:p1")]
    #expect(evaluate(observation: observation(panes: panes)) == .unavailable(.duplicateMatches(["w1:p1", "w2:p1"])))
    #expect(evaluate(observation: observation(panes: panes.reversed())) == .unavailable(.duplicateMatches(["w1:p1", "w2:p1"])))
}

@Test func herdrBindingIsVoidWhenThePanesNewestHookEventBelongsToAnotherSession() {
    let records = [record(at: 100), record(otherSession, at: 120)]
    #expect(evaluate(records: records) == .unavailable(.paneReusedBySession(otherSession)))
    #expect(evaluate(records: records.reversed()) == .unavailable(.paneReusedBySession(otherSession)))
    // The other session's newest event elsewhere does not affect this pane.
    #expect(evaluate(records: [record(at: 100), record(otherSession, pane: "w2:p1", at: 120)]) == bound)
    // An older event by another session in the same pane is superseded by this one.
    #expect(evaluate(records: [record(at: 100), record(otherSession, at: 90)]) == bound)
}

@Test func herdrTitlesVetoButNeverBind() {
    let ownTitle = "01a1142d-7a21-7383-a6aa-40030..."
    let otherTitle = "9f3c2b10-1111-4222-8333-44445..."
    #expect(evaluate(observation: observation(panes: [pane(title: otherTitle)])) == .unavailable(.conflictingTitle))
    #expect(evaluate(observation: observation(panes: [pane(title: ownTitle)])) == bound)
    #expect(evaluate(observation: observation(panes: [pane(title: nil)])) == bound)
    #expect(evaluate(observation: observation(panes: [pane(title: "zsh — ~/src")])) == bound)
    #expect(evaluate(observation: observation(panes: [pane(title: "✳ Claude Code")])) == bound)
    // An uppercase or unshortened identifier is not Steer's title shape.
    #expect(evaluate(observation: observation(panes: [pane(title: otherTitle.uppercased())])) == bound)
    // A matching title alone never binds.
    #expect(evaluate(observation: observation(panes: [pane(session: nil, title: ownTitle)])) == .unavailable(.agentSessionNull))
}

@Test func herdrBindingIsVoidForASplitTab() {
    #expect(evaluate(observation: observation(panes: [pane(panesInTab: 2)])) == .unavailable(.split))
}

@Test func herdrBindingRequiresTheSessionsOwnIntegrationToBeCurrent() {
    #expect(evaluate(observation: observation(integrations: [.codex: .outdated])) == .unavailable(.integrationNotCurrent(.codex, .outdated)))
    #expect(evaluate(observation: observation(integrations: [.codex: .notInstalled])) == .unavailable(.integrationNotCurrent(.codex, .notInstalled)))
    #expect(evaluate(observation: observation(integrations: [.codex: .unparseable])) == .unavailable(.integrationNotCurrent(.codex, .unparseable)))
    #expect(evaluate(observation: observation(integrations: [.claude: .current(version: 10)])) == .unavailable(.integrationNotCurrent(.codex, nil)))
    #expect(evaluate(observation: observation(integrations: [.codex: .current(version: 8), .claude: .outdated])) == bound)
}

@Test func herdrBindingRequiresExactlyOneGhosttyClient() {
    let ghostty = HerdrClientObservation(processID: 1, ancestryReachesGhostty: true)
    let second = HerdrClientObservation(processID: 2, ancestryReachesGhostty: true)
    let other = HerdrClientObservation(processID: 3, ancestryReachesGhostty: false)
    #expect(evaluate(observation: observation(clients: [])) == .unavailable(.noClient))
    #expect(evaluate(observation: observation(clients: [ghostty, second])) == .unavailable(.multipleClients(2)))
    #expect(evaluate(observation: observation(clients: [other])) == .unavailable(.nonGhosttyClient))
    // The same client reported twice is still one client.
    #expect(evaluate(observation: observation(clients: [ghostty, ghostty])) == bound)
}

@Test func herdrBindingIgnoresDuplicateAndReorderedObservations() {
    let panes = [pane("w1:p2", agent: nil, session: nil), pane(), pane()]
    #expect(evaluate(records: [record(at: 90), record(at: 100), record(at: 100)], observation: observation(panes: panes)) == bound)
    #expect(evaluate(records: [record(at: 100), record(at: 90)], observation: observation(panes: panes.reversed())) == bound)
    // A newer record moves the session to another pane regardless of input order.
    let moved = [record(at: 100), record(pane: "w2:p1", at: 130)]
    let movedPanes = observation(panes: [pane(session: nil), pane("w2:p1")])
    let target = HerdrBinding.bound(HerdrPaneTarget(sessionID: session, agent: .codex, paneID: "w2:p1"))
    #expect(evaluate(records: moved, observation: movedPanes) == target)
    #expect(evaluate(records: moved.reversed(), observation: movedPanes) == target)
}

@Test func herdrBindingIsVoidWhenObservationsConflict() {
    #expect(evaluate(records: [record(at: 100), record(pane: "w2:p1", at: 100)]) == .unavailable(.conflictingHookRecords))
    #expect(evaluate(records: [record(pane: "w2:p1", at: 100), record(at: 100)]) == .unavailable(.conflictingHookRecords))
    #expect(evaluate(observation: observation(panes: [pane(), pane(session: nil)])) == .unavailable(.conflictingPaneObservations))
}

@Test func herdrBindingRestoresWhenTheSessionEndsAndANewOneStartsInThePane() {
    // Codex exits: herdr clears the pane and Steer marks the session ended.
    let cleared = observation(panes: [pane(agent: nil, session: nil)])
    #expect(evaluate(liveness: .ended, observation: cleared) == .unavailable(.sessionEnded))
    // A new Codex in the same pane binds once both sides report the new session.
    let records = [record(at: 100), record(otherSession, at: 150)]
    #expect(evaluate(otherSession, records: records, observation: observation(panes: [pane(session: otherSession)]))
        == .bound(HerdrPaneTarget(sessionID: otherSession, agent: .codex, paneID: "w1:p1")))
    #expect(evaluate(records: records, observation: observation(panes: [pane(session: otherSession)]))
        == .unavailable(.paneReusedBySession(otherSession)))
}
