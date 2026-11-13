import Foundation

/// The walk through what needs the user, one card at a time (#440, Paper K "D · Walk the to-check
/// list"). From the hotkey's queue → opens the first to-check item as its card; ← → step through the
/// rest in the queue's own order. Memory only, and presentation only: stepping past an item, opening
/// its card, or reaching either end acknowledges, decides and answers nothing, and keyboard focus
/// pauses no deadline (ADR 0020).
public struct ToCheckWalk: Equatable, Sendable {
    /// What the walk shows.
    public enum Screen: Equatable, Sendable {
        /// One to-check item as its card.
        case card(AgentAttentionID)
        /// The last item was done (decided, answered, dismissed, or otherwise left to-check): the panel
        /// says "All checked", then folds and hands the keyboard back.
        case allChecked
    }

    /// "3 of 4 to check": the current card's one-based place among `count` items.
    public struct Position: Equatable, Sendable {
        public let index: Int
        public let count: Int

        public init(index: Int, count: Int) {
            self.index = index
            self.count = count
        }

        /// What VoiceOver reads for the header.
        public var spoken: String { "Item \(index) of \(count) to check" }
    }

    /// The items the walk visits, in the queue's own order ("By need" or "Newest first", whichever
    /// list `items` is), so live approvals still come first. Running work is not in the walk, and
    /// Earlier results are not counted as to check, as the strip's badge leaves them out.
    public static func order(of items: [AgentAttentionItem]) -> [AgentAttentionID] {
        items.filter { $0.kind != .running && $0.kind != .earlierOutcome }.map(\.id)
    }

    public private(set) var screen: Screen
    /// The walk's items as last observed, so a card that leaves can hand over to its neighbour.
    public private(set) var order: [AgentAttentionID]
    private var foldAt: Double?

    /// → from the hotkey's queue: the first to-check item. Nil when nothing needs the user.
    public init?(items: [AgentAttentionItem]) {
        let order = Self.order(of: items)
        guard let first = order.first else { return nil }
        self.order = order
        screen = .card(first)
    }

    /// The current card's place in the walk; nil on "All checked".
    public var position: Position? {
        guard case let .card(id) = screen, let index = order.firstIndex(of: id) else { return nil }
        return Position(index: index + 1, count: order.count)
    }

    /// One refresh with the queue as it is now. An item that arrives takes its queue position and the
    /// count follows; one that leaves drops out. When the card on screen leaves (it was decided,
    /// answered or dismissed, or resolved elsewhere) the walk moves to the item that followed it, or
    /// failing that the one before it. When nothing is left to check the walk shows "All checked"
    /// and its fold falls due `allCheckedHold` later. Once "All checked", it stays so.
    public mutating func observe(items: [AgentAttentionItem], now: Double) {
        guard case let .card(current) = screen else { return }
        let next = Self.order(of: items)
        defer { order = next }
        guard !next.contains(current) else { return }
        if let index = order.firstIndex(of: current) {
            let after = order[(index + 1)...].first(where: next.contains)
            let before = order[..<index].last(where: next.contains)
            if let neighbour = after ?? before {
                screen = .card(neighbour)
                return
            }
        }
        if let first = next.first {
            screen = .card(first)
        } else {
            screen = .allChecked
            foldAt = now + Self.allCheckedHold
        }
    }

    /// ← or →, from a key or the header's ‹ › wells, with the queue re-read first so an arrival or a
    /// departure since the last refresh is already in place. `question` is the card's viewed question
    /// and how many it has, when it is a question card stepped by a key: a card with several questions
    /// steps through its own first (the owner's option A, 2026-11-13), and only past its last (or
    /// before its first) moves to the next (or previous) card. The ends stop; nothing wraps.
    @discardableResult
    public mutating func step(_ direction: Direction, items: [AgentAttentionItem], question: QuestionPosition? = nil,
                              now: Double) -> Step {
        observe(items: items, now: now)
        guard case let .card(current) = screen, let index = order.firstIndex(of: current) else { return .stop }
        let by = direction == .next ? 1 : -1
        if let question, question.count > 1 {
            let viewed = question.viewed + by
            if (0..<question.count).contains(viewed) { return .question(viewed) }
        }
        let target = index + by
        guard order.indices.contains(target) else { return .stop }
        screen = .card(order[target])
        return .card(order[target])
    }

    /// "All checked" has shown for its hold: the panel folds and the keyboard goes back. A timer only
    /// asks again; it decides nothing.
    public func foldDue(now: Double) -> Bool {
        foldAt.map { now >= $0 } ?? false
    }
}

extension ToCheckWalk {
    /// How long "All checked" shows before the panel folds, as a keyboard card's sent line does.
    public static let allCheckedHold: Double = SpotlightKeyboardCard.sentHold

    public enum Direction: Equatable, Sendable {
        case previous
        case next
    }

    /// A question card's viewed question (zero-based) and how many questions it has.
    public struct QuestionPosition: Equatable, Sendable {
        public let viewed: Int
        public let count: Int

        public init(viewed: Int, count: Int) {
            self.viewed = viewed
            self.count = count
        }
    }

    /// What one step did.
    public enum Step: Equatable, Sendable {
        /// The card shows its question at this zero-based index; the walk stays on the card.
        case question(Int)
        /// The walk moved to this item's card.
        case card(AgentAttentionID)
        /// At an end (or on "All checked"): nothing moved.
        case stop
    }
}
