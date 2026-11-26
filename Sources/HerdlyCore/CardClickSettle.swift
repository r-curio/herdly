import Foundation

/// Approve and Deny ignore a click that lands in the first half second a card is on screen. The
/// panel takes the first click even before it is key, so without this a card that pops into the
/// spotlight under a pointer that was already on its way down could be decided by a click meant for
/// whatever sat there before. A new card in the same panel (another request swapped in) starts over.
/// Keyboard decisions (⌘⏎, ⌘⌫) need deliberate focus first and are not settled here.
public struct CardClickSettle: Equatable, Sendable {
    /// How long a newly shown card ignores clicks on its decision buttons.
    public static let settle: Double = 0.5

    public private(set) var card: AgentAttentionID?
    public private(set) var shownAt: Double?

    public init() {}

    /// Records the card now on screen; the clock starts only when the card changes.
    public mutating func show(_ card: AgentAttentionID?, now: Double) {
        guard card != self.card else { return }
        self.card = card
        shownAt = card == nil ? nil : now
    }

    /// Whether a click on `card`'s Approve or Deny at `now` counts. A click on a card other than
    /// the one recorded (or none recorded) is refused: what the user aimed at is uncertain.
    public func acceptsDecisionClick(on card: AgentAttentionID, now: Double) -> Bool {
        guard card == self.card, let shownAt else { return false }
        return now - shownAt >= Self.settle
    }
}
