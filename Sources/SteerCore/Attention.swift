/// One test completion. App visibility never clears queue state.
public struct Attention {
    public private(set) var pending: Bool
    public private(set) var presented: Bool
    public private(set) var expanded = false
    private var collapseAt: Double = 0

    public init(restored: Bool = false) {
        pending = restored
        presented = restored // Restored items do not replay their sound or popup.
    }

    public mutating func enqueue() {
        pending = true
        presented = false
        expanded = false
    }

    /// Returns true exactly once when a new item becomes visible.
    public mutating func update(codexForeground: Bool, hovering: Bool, now: Double) -> Bool {
        guard pending else { return false }
        if codexForeground {
            expanded = false
            return false
        }
        if !presented {
            presented = true
            expanded = true
            collapseAt = now + 3
            return true
        }
        if !hovering && now >= collapseAt { expanded = false }
        return false
    }

    public mutating func expand(now: Double) {
        guard pending else { return }
        expanded = true
        collapseAt = now + 3
    }

    public mutating func dismiss() {
        pending = false
        expanded = false
    }
}
