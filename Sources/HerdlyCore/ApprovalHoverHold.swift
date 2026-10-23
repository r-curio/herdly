import Foundation

/// Pauses live approvals' handoff countdown while the user's pointer is on the notch (ADR 0020,
/// agreed with the user on 2026-10-23). Each approval keeps the time it had left when the hover
/// began; once the pointer leaves, its countdown resumes from there. No hold runs past
/// `ApprovalTiming.maximumHold` after receipt, and a request with less than `holdMargin` left is
/// not held, so the helper always reads a hold before its own deadline. Holding decides nothing:
/// only the user's explicit choice does, and expiry still hands back with no decision.
public struct ApprovalHoverHold<Key: Hashable & Sendable>: Equatable, Sendable {
    /// One live approval as the queue holds it: `expiresAt` is its receipt deadline.
    public struct Live: Equatable, Sendable {
        public let key: Key
        public let expiresAt: Double

        public init(key: Key, expiresAt: Double) {
            self.key = key
            self.expiresAt = expiresAt
        }
    }

    /// Held deadlines, later than the receipt deadline, for live approvals only.
    public private(set) var deadlines: [Key: Double] = [:]
    private var remaining: [Key: Double] = [:]

    public init() {}

    public mutating func update(hovering: Bool, live: [Live], now: Double) {
        let keys = Set(live.map(\.key))
        deadlines = deadlines.filter { keys.contains($0.key) }
        remaining = remaining.filter { keys.contains($0.key) }
        guard hovering else {
            remaining = [:]
            return
        }
        for approval in live {
            let current = max(approval.expiresAt, deadlines[approval.key] ?? approval.expiresAt)
            if let left = remaining[approval.key] {
                let held = ApprovalTiming.heldDeadline(expiresAt: approval.expiresAt, held: now + left)
                if held > current { deadlines[approval.key] = held }
            } else if current - now >= ApprovalTiming.holdMargin {
                remaining[approval.key] = current - now
            }
        }
    }

    /// The deadline the queue and the helper keep for `key`: the hold when there is one.
    public func deadline(for key: Key, expiresAt: Double) -> Double {
        max(expiresAt, deadlines[key] ?? expiresAt)
    }
}
