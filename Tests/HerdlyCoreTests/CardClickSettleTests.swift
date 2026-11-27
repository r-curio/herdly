import CoreGraphics
import Testing
@testable import HerdlyCore

private func card(_ call: String) -> AgentAttentionID {
    let session = AgentSessionIdentity(source: .codex, sourceScope: "codex", session: "s", surface: .cli)
    return .running(AgentTurnIdentity(session: session, turn: call))
}

/// The card's frame on screen; `inside` is over it, `outside` is not.
private let frame = CGRect(x: 600, y: 800, width: 360, height: 200)
private let inside = CGPoint(x: 700, y: 900)
private let outside = CGPoint(x: 300, y: 400)

@Test func aCardThatAppearedUnderThePointerIgnoresAClickInTheFirstHalfSecondAndCountsExactlyAtTheSettle() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100, pointer: inside)
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 100, cardFrame: frame))
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 100 + CardClickSettle.settle - 0.001, cardFrame: frame))
    #expect(settle.acceptsDecisionClick(on: card("a"), now: 100 + CardClickSettle.settle, cardFrame: frame))
}

@Test func aPointerThatMovedToTheCardAfterItAppearedClicksAtOnce() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100, pointer: outside)
    #expect(settle.acceptsDecisionClick(on: card("a"), now: 100.1, cardFrame: frame))
}

@Test func anUnknownPointerAtAppearanceKeepsTheSettle() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100, pointer: nil)
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 100.1, cardFrame: frame))
    #expect(settle.acceptsDecisionClick(on: card("a"), now: 100.5, cardFrame: frame))
}

@Test func theCardsFrameAtClickTimeDecidesWhetherThePointerWasOverIt() {
    // The pointer sat on the collapsed strip, which lies inside the card once it has opened.
    var settle = CardClickSettle()
    let onStrip = CGPoint(x: 780, y: 998)
    settle.show(card("a"), now: 100, pointer: onStrip)
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 100.2, cardFrame: frame))
}

@Test func redrawingTheSameCardKeepsItsClockAndItsPointer() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100, pointer: inside)
    settle.show(card("a"), now: 103, pointer: outside)
    #expect(settle.pointerAtShow == inside)
    #expect(settle.acceptsDecisionClick(on: card("a"), now: 103, cardFrame: frame))
}

@Test func aCardSwappedInUnderThePointerStartsOver() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100, pointer: outside)
    settle.show(card("b"), now: 105, pointer: inside)
    #expect(!settle.acceptsDecisionClick(on: card("b"), now: 105.2, cardFrame: frame))
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 106, cardFrame: frame))
    #expect(settle.acceptsDecisionClick(on: card("b"), now: 105.5, cardFrame: frame))
}

@Test func foldingAndReopeningTheSameCardStartsOver() {
    var settle = CardClickSettle()
    settle.show(card("a"), now: 100, pointer: inside)
    settle.show(nil, now: 101, pointer: inside)
    #expect(settle.pointerAtShow == nil)
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 102, cardFrame: frame))
    settle.show(card("a"), now: 102, pointer: inside)
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 102.4, cardFrame: frame))
    #expect(settle.acceptsDecisionClick(on: card("a"), now: 102.5, cardFrame: frame))
}

@Test func aClickOnACardNotOnScreenNeverCounts() {
    var settle = CardClickSettle()
    #expect(!settle.acceptsDecisionClick(on: card("a"), now: 100, cardFrame: frame))
    settle.show(card("a"), now: 100, pointer: outside)
    #expect(!settle.acceptsDecisionClick(on: card("b"), now: 100.1, cardFrame: frame))
}
