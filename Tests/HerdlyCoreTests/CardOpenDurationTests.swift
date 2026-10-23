import Testing
@testable import HerdlyCore

private func session(_ name: String) -> AgentSessionIdentity {
    AgentSessionIdentity(source: .codex, sourceScope: "codex", session: name, surface: .cli)
}

private let done = AgentAttentionID.running(AgentTurnIdentity(session: session("busy"), turn: "t1"))

@Test(arguments: [(CardOpenDuration.threeSeconds, 3.0), (.fiveSeconds, 5.0), (.tenSeconds, 10.0)])
func aTimedCardStaysOpenUntilItsTimeAndClosesExactlyThen(duration: CardOpenDuration, seconds: Double) {
    var presentation = NotchPresentationController()
    presentation.present(done, now: 100, duration: duration)

    #expect(presentation.update(interacting: false, now: 100 + seconds - 0.001) == .agentSpotlight(done))
    #expect(presentation.update(interacting: false, now: 100 + seconds) == .collapsed)
}

@Test func theOldKeepCardsOpenSwitchMigratesToTheMatchingDuration() {
    #expect(CardOpenDuration.resolve(saved: nil, legacyKeepCardsOpen: true) == .untilIAct)
    #expect(CardOpenDuration.resolve(saved: nil, legacyKeepCardsOpen: false) == .threeSeconds)
    #expect(CardOpenDuration.resolve(saved: nil, legacyKeepCardsOpen: nil) == .threeSeconds)
}

@Test func aSavedDurationWinsOverTheOldSwitch() {
    #expect(CardOpenDuration.resolve(saved: "10s", legacyKeepCardsOpen: true) == .tenSeconds)
    #expect(CardOpenDuration.resolve(saved: "untilIAct", legacyKeepCardsOpen: false) == .untilIAct)
    #expect(CardOpenDuration.resolve(saved: "5s", legacyKeepCardsOpen: nil) == .fiveSeconds)
}

@Test func anUnknownSavedDurationFallsBackLikeNoneWasSaved() {
    #expect(CardOpenDuration.resolve(saved: "forever", legacyKeepCardsOpen: true) == .untilIAct)
    #expect(CardOpenDuration.resolve(saved: "", legacyKeepCardsOpen: false) == .threeSeconds)
}

@Test func untilIActHoldsTheCardUntilInteractionEnds() {
    var presentation = NotchPresentationController()
    presentation.present(done, now: 0, duration: .untilIAct)

    #expect(presentation.update(interacting: false, now: 3_600) == .agentSpotlight(done))
    #expect(presentation.update(interacting: true, now: 3_601) == .agentSpotlight(done))
    #expect(presentation.update(interacting: true, now: 3_700) == .agentSpotlight(done))
    #expect(presentation.update(interacting: false, now: 3_700.1) == .collapsed)
}

@Test func aTimedCardCountsDownOnlyAfterTheUserLeavesIt() {
    var presentation = NotchPresentationController()
    presentation.present(done, now: 0, duration: .fiveSeconds)

    // Held past its time while the user is on it; its full time starts once they leave.
    #expect(presentation.update(interacting: true, now: 7) == .agentSpotlight(done))
    #expect(presentation.update(interacting: false, now: 11.999) == .agentSpotlight(done))
    #expect(presentation.update(interacting: false, now: 12) == .collapsed)

    // Interaction that ends before the time restarts it from the last interaction.
    presentation.present(done, now: 20, duration: .fiveSeconds)
    #expect(presentation.update(interacting: true, now: 24) == .agentSpotlight(done))
    #expect(presentation.update(interacting: false, now: 28.999) == .agentSpotlight(done))
    #expect(presentation.update(interacting: false, now: 29) == .collapsed)

    // A new card may not take the spotlight while the restarted time runs.
    presentation.present(done, now: 40, duration: .threeSeconds)
    #expect(presentation.update(interacting: true, now: 42) == .agentSpotlight(done))
    #expect(!presentation.acceptsAgentSpotlight(interacting: false, draftInProgress: false, now: 44.999))
    #expect(presentation.acceptsAgentSpotlight(interacting: false, draftInProgress: false, now: 45))
}

@Test func anApprovalHeldOpenUntilIActStillHandsBackAtExactlyThirtySeconds() {
    var queue = AgentAttentionQueue()
    let approval = AgentApproval(session: session("asks"), turn: "t1", call: "a1", arrivedAt: 0)
    queue.apply(.approval(approval))
    let id = AgentAttentionID.approval(approval.id)
    var presentation = NotchPresentationController()
    presentation.present(id, now: 0, duration: .untilIAct)

    // The user hovers the card the whole time; the card stays, the deadline does not move.
    for now in stride(from: 1.0, through: 29.0, by: 1) {
        #expect(presentation.update(interacting: true, now: now) == .agentSpotlight(id))
        queue.expire(at: now)
        #expect(queue.items(at: now).first?.kind == .actionableApproval)
    }
    queue.expire(at: 29.999)
    #expect(queue.items(at: 29.999).first?.kind == .actionableApproval)
    #expect(presentation.update(interacting: true, now: 30) == .agentSpotlight(id))
    queue.expire(at: 30)
    #expect(queue.items(at: 30).first?.kind == .handedBackApproval)
    #expect(queue.items(at: 30).first?.approval?.state == .handedBack)
}

@Test func theConnectionNoticeNamesOnlyAgentsKnownNotToBeConnected() {
    #expect(AgentConnectionNotice.message(codexConnected: true, claudeConnected: true) == nil)
    #expect(AgentConnectionNotice.message(codexConnected: false, claudeConnected: true) == "Codex isn't connected")
    #expect(AgentConnectionNotice.message(codexConnected: true, claudeConnected: false) == "Claude Code isn't connected")
    #expect(AgentConnectionNotice.message(codexConnected: false, claudeConnected: false)
            == "Codex and Claude Code aren't connected")
}

@Test func theConnectionNoticeNeverGuessesWhileAStateIsStillBeingChecked() {
    #expect(AgentConnectionNotice.message(codexConnected: nil, claudeConnected: nil) == nil)
    #expect(AgentConnectionNotice.message(codexConnected: nil, claudeConnected: true) == nil)
    #expect(AgentConnectionNotice.message(codexConnected: true, claudeConnected: nil) == nil)
    // A known gap is still named while the other agent is being checked.
    #expect(AgentConnectionNotice.message(codexConnected: false, claudeConnected: nil) == "Codex isn't connected")
    #expect(AgentConnectionNotice.message(codexConnected: nil, claudeConnected: false) == "Claude Code isn't connected")
}
