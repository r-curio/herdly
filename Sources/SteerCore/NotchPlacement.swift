import CoreGraphics

/// One attached display as the placement rules see it. `topInset` is the height of the physical
/// camera housing (zero on a display without one). Coordinates follow AppKit's global space.
public struct NotchDisplay: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let topInset: CGFloat

    public init(id: UInt32, frame: CGRect, topInset: CGFloat) {
        self.id = id
        self.frame = frame
        self.topInset = topInset
    }

    public var hasPhysicalNotch: Bool { topInset > 0 }
}

/// Active-display rule for the single shared panel.
///
/// 1. While the user is interacting with the panel (pointer over it or keyboard focus in it), keep
///    the display it is already on, so controls never move away mid-action.
/// 2. Otherwise use the display under the pointer.
/// 3. If the pointer is on no display, keep the current display.
/// 4. Otherwise the first attached display.
/// A display that has disconnected is never chosen, even while interacting.
public enum NotchDisplaySelection {
    public static func choose(displays: [NotchDisplay], pointer: CGPoint, current: UInt32?, interacting: Bool) -> NotchDisplay? {
        let currentDisplay = displays.first { $0.id == current }
        if interacting, let currentDisplay { return currentDisplay }
        return displays.first { $0.frame.contains(pointer) } ?? currentDisplay ?? displays.first
    }
}

/// Panel geometry for the chosen display. Controls stay below a physical camera housing; a display
/// without one gets a compact top-center panel. Geometry depends only on these inputs, so a
/// display change or an interaction never changes what the queue holds or when items expire.
public enum NotchPlacement {
    public static let collapsedWidth: CGFloat = 210
    public static let expandedWidth: CGFloat = 380
    public static let collapsedHeight: CGFloat = 34
    public static let maximumExpandedHeight: CGFloat = 380
    static let margin: CGFloat = 6

    public static func frame(on display: NotchDisplay, expanded: Bool, rows: Int, extraRows: Bool) -> CGRect {
        let width = expanded ? expandedWidth : collapsedWidth
        let height = expanded ? min(maximumExpandedHeight, 150 + CGFloat(rows) * 65 + (extraRows ? 80 : 0)) : collapsedHeight
        let top = display.frame.maxY - max(display.topInset, margin) - margin
        return CGRect(x: display.frame.midX - width / 2, y: top - height, width: width, height: height)
    }
}

/// Interaction freezes placement and keeps a completion popup open; it never touches approval deadlines.
public enum NotchInteraction {
    public static func isActive(pointerInside: Bool, keyboardFocus: Bool) -> Bool {
        pointerInside || keyboardFocus
    }
}
