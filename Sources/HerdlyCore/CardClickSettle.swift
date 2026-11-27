import CoreGraphics
import Foundation

/// Approve and Deny ignore a click in the first half second a card is on screen, but only when the
/// pointer was already over the card at the moment it appeared. The panel takes the first click even
/// before it is key, so a card that pops into the spotlight under a pointer already on its way down
/// could otherwise be decided by a click meant for whatever sat there before. A pointer that was
/// elsewhere had to travel to the card after it appeared, so its click is deliberate and counts at
/// once. A new card in the same panel (another request swapped in) starts over.
/// Keyboard decisions (⌘⏎, ⌘⌫) need deliberate focus first and are not settled here.
public struct CardClickSettle: Equatable, Sendable {
    /// How long a newly shown card ignores clicks on its decision buttons when it appeared under the pointer.
    public static let settle: Double = 0.5

    public private(set) var card: AgentAttentionID?
    public private(set) var shownAt: Double?
    /// Where the pointer was, in screen coordinates, when `card` appeared; nil when unknown.
    public private(set) var pointerAtShow: CGPoint?

    public init() {}

    /// Records the card now on screen and where the pointer is; both are kept only when the card changes.
    public mutating func show(_ card: AgentAttentionID?, now: Double, pointer: CGPoint?) {
        guard card != self.card else { return }
        self.card = card
        shownAt = card == nil ? nil : now
        pointerAtShow = card == nil ? nil : pointer
    }

    /// Whether a click on `card`'s Approve or Deny at `now` counts, given the card's frame on screen
    /// now (the same coordinates as the pointer). A click on a card other than the one recorded (or
    /// none recorded) is refused: what the user aimed at is uncertain. Inside the settle, a click
    /// counts only when the pointer is known to have started outside the card.
    public func acceptsDecisionClick(on card: AgentAttentionID, now: Double, cardFrame: CGRect) -> Bool {
        guard card == self.card, let shownAt else { return false }
        if now - shownAt >= Self.settle { return true }
        guard let pointerAtShow else { return false }
        return !cardFrame.contains(pointerAtShow)
    }
}
