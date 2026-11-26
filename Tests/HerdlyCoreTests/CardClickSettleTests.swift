import Testing
@testable import HerdlyCore

private func card(_ call: String) -> AgentAttentionID {
    let session = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s", surface: .cli)
    return .running(AgentTurnIdentity(session: session, turn: call))
}

@Test func aDecisionClickInTheFirstHalfSecondIsIgnoredAndCountsExactlyAtTheSettle() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100)
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 100))
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 100 + CardClickSettle.settle - 0.001))
    #expect(settle.acceptsDecisionClick(on: card("a"), now: 100 + CardClickSettle.settle))
}

@Test func redrawingTheSameCardKeepsItsClock() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100)
    settle.show(card("a"), now: 103)
    #expect(settle.acceptsDecisionClick(on: card("a"), now: 103))
}

@Test func aCardSwappedInUnderThePointerStartsOver() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100)
    settle.show(card("b"), now: 105)
    #expect(!settle.acceptsDecisionClick(on: card("b"), now: 105.2))
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 106))
    #expect(settle.acceptsDecisionClick(on: card("b"), now: 105.5))
}

@Test func foldingAndReopeningTheSameCardStartsOver() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100)
    settle.show(nil, now: 101)
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 102))
    settle.show(card("a"), now: 102)
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 102.4))
    #expect(settle.acceptsDecisionClick(on: card("a"), now: 102.5))
}
