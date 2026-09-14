import CoreGraphics
import Foundation

/// One attached display as the placement rules see it. `topInset` is the height of the physical
/// camera housing (zero on a display without one); `housingWidth` is its width, and `menuBarHeight`
/// the height of the menu bar strip the panel fuses to. Coordinates follow AppKit's global space.
public struct NotchDisplay: Equatable, Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let topInset: CGFloat
    public let housingWidth: CGFloat
    public let menuBarHeight: CGFloat
    /// True for the Mac's own display; false for an external monitor.
    public let isBuiltIn: Bool

    public init(id: UInt32, frame: CGRect, topInset: CGFloat, housingWidth: CGFloat = 0, menuBarHeight: CGFloat = 0,
                isBuiltIn: Bool = false) {
        self.id = id
        self.frame = frame
        self.topInset = topInset
        self.housingWidth = housingWidth
        self.menuBarHeight = menuBarHeight
        self.isBuiltIn = isBuiltIn
    }

    public var hasPhysicalNotch: Bool { topInset > 0 }

    /// Height of the menu bar currently shown along the top edge of `frame`, given the menu bar
    /// windows the window server has on screen (AppKit global coordinates). A display whose menu
    /// bar is hidden, for example under a full-screen app, gets zero, so the strip meets the top
    /// edge of the screen instead of floating where the menu bar would be. `visibleFrame` cannot
    /// tell these apart: it reserves the menu bar strip whether or not the bar is showing.
    public static func shownMenuBarHeight(on frame: CGRect, menuBars: [CGRect]) -> CGFloat {
        menuBars.first { bar in
            abs(bar.maxY - frame.maxY) <= 1 && frame.contains(CGPoint(x: bar.midX, y: bar.midY))
        }.map { min($0.height, frame.height) } ?? 0
    }
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

/// Panel geometry for the chosen display. On a display with a camera housing the collapsed panel is
/// the housing row itself: exactly as tall as the housing, anchored to the top edge of the screen,
/// with a narrow wing on each side of the housing where the sprite (left) and the count (right) live. On any other display it is a compact strip inline with the menu bar row, anchored to the
/// top edge of the screen. The open queue grows downward from the strip. The frame includes the concave ears at the top corners.
/// Geometry depends only on these inputs, so a display change or an interaction never changes what
/// the queue holds or when items expire.
public enum NotchPlacement {
    /// Visible body left of the camera housing, where up to three session sprites live.
    public static let leadingWing: CGFloat = 64
    /// Visible body right of the camera housing, where the overflow mark and the count live.
    public static let trailingWing: CGFloat = 60
    /// Concave fillet joining the body to the menu bar at each top corner; part of the frame.
    public static let earRadius: CGFloat = 8
    /// Radius of the two bottom corners.
    public static let cornerRadius: CGFloat = 18
    /// Narrowest body a display without a housing gets.
    public static let minimumBodyWidth: CGFloat = 200
    public static let expandedBodyWidth: CGFloat = 380
    /// Strip height on a display showing neither a housing nor a menu bar; otherwise the strip is
    /// the housing or menu bar height.
    public static let collapsedHeight: CGFloat = 40
    public static let maximumExpandedHeight: CGFloat = 480

    public static func bodyWidth(on display: NotchDisplay, expanded: Bool) -> CGFloat {
        let collapsed = max(display.housingWidth + leadingWing + trailingWing, minimumBodyWidth)
        return expanded ? max(collapsed, expandedBodyWidth) : collapsed
    }

    /// Height of the collapsed strip: the housing row on a display with a camera housing, the menu
    /// bar row on any other display showing one, and `collapsedHeight` where no bar is showing.
    public static func stripHeight(on display: NotchDisplay) -> CGFloat {
        if display.hasPhysicalNotch { return display.topInset }
        return display.menuBarHeight > 0 ? display.menuBarHeight : collapsedHeight
    }

    /// How the strip's content is split around the housing. Extra width when the panel is open is
    /// shared equally by both wings so the housing stays centered in the gap.
    public static func strip(on display: NotchDisplay, expanded: Bool) -> StripLayout {
        let body = bodyWidth(on: display, expanded: expanded)
        guard display.hasPhysicalNotch else {
            return StripLayout(leading: body - trailingWing, gap: 0, trailing: trailingWing, height: stripHeight(on: display))
        }
        let extra = (body - display.housingWidth - leadingWing - trailingWing) / 2
        return StripLayout(leading: leadingWing + extra, gap: display.housingWidth, trailing: trailingWing + extra,
                           height: stripHeight(on: display))
    }

    /// Estimated frame from a row count, used before the content has been measured.
    public static func frame(on display: NotchDisplay, expanded: Bool, rows: Int, extraRows: Bool) -> CGRect {
        let estimate = stripHeight(on: display) + 28 + CGFloat(rows) * 64 + (extraRows ? 56 : 0)
        return frame(on: display, expanded: expanded, contentHeight: estimate)
    }

    /// Frame for a measured content height (strip included): the open panel is exactly as tall as
    /// what it shows, growing downward and capped for long queues.
    public static func frame(on display: NotchDisplay, expanded: Bool, contentHeight: CGFloat) -> CGRect {
        let layout = strip(on: display, expanded: expanded)
        let width = bodyWidth(on: display, expanded: expanded) + 2 * earRadius
        let height = expanded ? min(maximumExpandedHeight, max(layout.height + 24, contentHeight.rounded(.up))) : layout.height
        // The panel starts at the very top of the screen on every display: its gap over the housing
        // where there is one, otherwise centered in the menu bar row.
        let top = display.frame.maxY
        let x = display.hasPhysicalNotch
            ? display.frame.midX - layout.gap / 2 - layout.leading - earRadius
            : display.frame.midX - width / 2
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}

/// On an external monitor that shows no menu bar (a full-screen app), the strip would sit over
/// the top of whatever is full screen. There it tucks away above the screen edge, like the hidden
/// menu bar, and slides in while the pointer touches the top edge or is over the panel, while the
/// panel has keyboard focus, or while the panel is open (a new completion, request, or question
/// opens it for its spotlight, so it still announces itself briefly). An external monitor with a
/// menu bar never tucks: the strip fuses to the bar. The built-in display never tucks either:
/// with a housing the strip is the housing row, and without one it stays under the menu bar.
public enum NotchTuck {
    /// Height of the band along the top edge that reveals the tucked strip, in points.
    public static let revealBand: CGFloat = 3

    public static func isTucked(display: NotchDisplay, pointer: CGPoint, interacting: Bool, open: Bool) -> Bool {
        guard !display.isBuiltIn, display.menuBarHeight == 0, !interacting, !open else { return false }
        return !pointerTouchesTopEdge(of: display, pointer: pointer)
    }

    /// The pointer pinned to the top edge reports exactly `maxY`, which `CGRect.contains` excludes.
    public static func pointerTouchesTopEdge(of display: NotchDisplay, pointer: CGPoint) -> Bool {
        pointer.x >= display.frame.minX && pointer.x < display.frame.maxX
            && pointer.y >= display.frame.maxY - revealBand && pointer.y <= display.frame.maxY
    }

    /// Where the tucked strip rests: the same frame moved up so it is entirely above the screen.
    public static func tuckedFrame(_ frame: CGRect) -> CGRect {
        frame.offsetBy(dx: 0, dy: frame.height)
    }
}

/// The strip's content regions, inside the ears: `leading` left of the housing, `gap` over it
/// (zero without a housing), `trailing` right of it, all `height` tall.
public struct StripLayout: Equatable, Sendable {
    public let leading: CGFloat
    public let gap: CGFloat
    public let trailing: CGFloat
    public let height: CGFloat

    public init(leading: CGFloat, gap: CGFloat, trailing: CGFloat, height: CGFloat) {
        self.leading = leading
        self.gap = gap
        self.trailing = trailing
        self.height = height
    }
}

/// Interaction freezes placement and keeps a spotlight open; it never touches approval deadlines.
public enum NotchInteraction {
    public static func isActive(pointerInside: Bool, keyboardFocus: Bool) -> Bool {
        pointerInside || keyboardFocus
    }
}

/// Hover with a short grace after the pointer leaves, so a slip off the edge does not snap the
/// panel shut. Entering counts at once; leaving counts only after `grace` seconds.
public struct HoverHold: Equatable, Sendable {
    public static let grace: Double = 0.3
    private var leftAt: Double?
    private var inside = false

    public init() {}

    /// Returns whether the panel should be treated as hovered at `now`.
    public mutating func update(pointerInside: Bool, now: Double) -> Bool {
        if pointerInside {
            inside = true
            leftAt = nil
            return true
        }
        if inside {
            inside = false
            leftAt = now
        }
        guard let leftAt else { return false }
        if now - leftAt < HoverHold.grace { return true }
        self.leftAt = nil
        return false
    }
}

/// The one item a new completion or approval request opens the panel to show, for three seconds
/// from presentation. Interaction holds it open; once interaction ends the original deadline
/// applies, not a new one. It never extends an approval deadline and never acknowledges anything.
public struct Spotlight: Equatable, Sendable {
    public static let duration: Double = 3
    public private(set) var item: AttentionItemID?
    private var until: Double = 0

    public init() {}

    public mutating func present(_ item: AttentionItemID, now: Double) {
        self.item = item
        until = now + Spotlight.duration
    }

    /// Returns the spotlit item while it should stay open, clearing it once its time has passed
    /// without interaction.
    public mutating func update(interacting: Bool, now: Double) -> AttentionItemID? {
        guard item != nil else { return nil }
        if interacting || now < until { return item }
        clear()
        return nil
    }

    public mutating func clear() {
        item = nil
        until = 0
    }
}

/// One session on the strip: its sprite steps while the session is working, in a color that stays
/// with the session.
public struct StripSession: Equatable, Sendable {
    public let session: Foundation.UUID
    public let working: Bool
    public let color: Int

    public init(session: Foundation.UUID, working: Bool, color: Int) {
        self.session = session
        self.working = working
        self.color = color
    }
}

/// What the collapsed strip shows: one sprite per session (at most `maximumSprites`, in priority
/// order), how many further sessions are not shown, the subject of the top-priority item, and how
/// many items need the user.
public struct StripSummary: Equatable, Sendable {
    public static let maximumSprites = 3
    /// Number of distinct sprite colors; a session keeps its color from its identifier.
    public static let colorCount = 6

    public let subject: String
    public let working: Bool
    public let toCheck: Int
    public let sessions: [StripSession]
    public let overflow: Int

    public init(subject: String, working: Bool, toCheck: Int, sessions: [StripSession] = [], overflow: Int = 0) {
        self.subject = subject
        self.working = working
        self.toCheck = toCheck
        self.sessions = sessions
        self.overflow = overflow
    }

    /// A session's preferred color, derived from its identifier so it survives queue changes.
    public static func preferredColor(for session: Foundation.UUID) -> Int {
        let bytes = session.uuid
        let sum = Int(bytes.0) &+ Int(bytes.1) &+ Int(bytes.2) &+ Int(bytes.3) &+ Int(bytes.15)
        return sum % colorCount
    }

    /// Sessions in first-appearance order of the priority-ordered items. Each takes its preferred
    /// color unless a session shown before it already has that color, in which case the next free
    /// color is used, so the sprites on the strip are never two of the same color.
    public static func sessions(in items: [AttentionItem]) -> (shown: [StripSession], overflow: Int) {
        var order: [Foundation.UUID] = []
        var working: Set<Foundation.UUID> = []
        for item in items {
            if !order.contains(item.session) { order.append(item.session) }
            if item.kind == .running { working.insert(item.session) }
        }
        var taken: Set<Int> = []
        var shown: [StripSession] = []
        for session in order.prefix(maximumSprites) {
            var color = preferredColor(for: session)
            while taken.contains(color) { color = (color + 1) % colorCount }
            taken.insert(color)
            shown.append(StripSession(session: session, working: working.contains(session), color: color))
        }
        return (shown, max(0, order.count - maximumSprites))
    }

    /// Items arrive already ordered by priority; the first one names the strip. Codex's own thread
    /// name is preferred, then a request's task name from Codex, otherwise the shortened session
    /// identifier, never an invented name.
    public static func make(items: [AttentionItem], testPending: Bool, names: [Foundation.UUID: String] = [:]) -> StripSummary {
        let toCheck = items.filter { $0.kind != .running }.count + (testPending ? 1 : 0)
        let working = items.contains { $0.kind == .running }
        let subject: String
        if let first = items.first {
            if let name = names[first.session] { subject = name }
            else if let task = first.request?.details?.taskName, !task.isEmpty { subject = task }
            else { subject = StripSummary.sessionLabel(first.session) }
        } else if testPending {
            subject = "test notification"
        } else {
            subject = "idle"
        }
        let (sessions, overflow) = StripSummary.sessions(in: items)
        return StripSummary(subject: subject, working: working, toCheck: toCheck, sessions: sessions, overflow: overflow)
    }

    /// The thread name Codex gave the session when known; otherwise the shortened identifier.
    public static func sessionLabel(_ session: Foundation.UUID, names: [Foundation.UUID: String] = [:]) -> String {
        names[session] ?? "session " + session.uuidString.lowercased().prefix(8)
    }
}
