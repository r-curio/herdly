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
    /// The display's UUID, stable across reboots and reconnects where `id` is not; nil when the
    /// system cannot report one, in which case the display cannot be pinned.
    public let persistentID: String?
    /// The name macOS gives the display, for the display picker; nil when it reports none.
    public let name: String?

    public init(id: UInt32, frame: CGRect, topInset: CGFloat, housingWidth: CGFloat = 0, menuBarHeight: CGFloat = 0,
                isBuiltIn: Bool = false, persistentID: String? = nil, name: String? = nil) {
        self.id = id
        self.frame = frame
        self.topInset = topInset
        self.housingWidth = housingWidth
        self.menuBarHeight = menuBarHeight
        self.isBuiltIn = isBuiltIn
        self.persistentID = persistentID
        self.name = name
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

/// A display the user pinned the notch to. `name` is kept so the choice can still be labeled while
/// that display is not connected.
public struct NotchDisplayPin: Equatable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Where the user wants the notch: following the pointer (the default), or pinned to one display.
public enum NotchDisplayPreference: Equatable, Hashable, Sendable {
    case followPointer
    case pinned(NotchDisplayPin)

    /// The preference from stored values. A missing or empty identifier means no pin; a missing
    /// name is labeled generically rather than invented.
    public static func restored(id: String?, name: String?) -> NotchDisplayPreference {
        guard let id, !id.isEmpty else { return .followPointer }
        let name = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Pinned display"
        return .pinned(NotchDisplayPin(id: id, name: name))
    }

    public var pin: NotchDisplayPin? {
        if case let .pinned(pin) = self { return pin }
        return nil
    }

    /// The attached display a pin names, matched by identifier; nil without a pin or while that
    /// display is not attached.
    public func pinnedDisplay(in displays: [NotchDisplay]) -> NotchDisplay? {
        guard let pin else { return nil }
        return displays.first { $0.persistentID == pin.id }
    }
}

/// Active-display rule for the single shared panel.
///
/// 1. While the user is interacting with the panel (pointer over it or keyboard focus in it), keep
///    the display it is already on, so controls never move away mid-action.
/// 2. With a pin, the pinned display wherever the pointer is; while it is not attached, the
///    built-in display, returning to the pinned one when it reconnects. With neither attached the
///    rules below apply.
/// 3. Otherwise use the display under the pointer.
/// 4. If the pointer is on no display, keep the current display.
/// 5. Otherwise the first attached display.
/// A display that has disconnected is never chosen, even while interacting.
public enum NotchDisplaySelection {
    public static func choose(displays: [NotchDisplay], pointer: CGPoint, current: UInt32?, interacting: Bool,
                              preference: NotchDisplayPreference = .followPointer) -> NotchDisplay? {
        let currentDisplay = displays.first { $0.id == current }
        if interacting, let currentDisplay { return currentDisplay }
        if preference.pin != nil {
            if let pinned = preference.pinnedDisplay(in: displays) { return pinned }
            if let builtIn = displays.first(where: \.isBuiltIn) { return builtIn }
        }
        return displays.first { $0.frame.contains(pointer) } ?? currentDisplay ?? displays.first
    }
}

/// One entry in the notch display picker.
public struct NotchDisplayOption: Equatable, Hashable, Sendable, Identifiable {
    public let preference: NotchDisplayPreference
    public let label: String

    public var id: NotchDisplayPreference { preference }

    public init(preference: NotchDisplayPreference, label: String) {
        self.preference = preference
        self.label = label
    }
}

/// Everything the controls window and the menu bar item show for the notch display setting,
/// computed together so the checked entry and the detail line always name the same display.
public struct NotchDisplayChoices: Equatable, Sendable {
    /// "Follow pointer" first, then each attached display that can be pinned, left to right. Two
    /// displays with the same name (two monitors of one model) are numbered in that order. A saved
    /// pin whose display is not attached stays listed, marked not connected, so the current choice
    /// is always visible.
    public let options: [NotchDisplayOption]
    /// The entry for the saved preference. A pin matches its display by identifier, so a stored
    /// name that has gone out of date still checks the right display.
    public let selected: NotchDisplayOption
    /// One sentence describing where the notch is shown.
    public let detail: String

    public init(displays: [NotchDisplay], preference: NotchDisplayPreference) {
        let followPointer = NotchDisplayOption(preference: .followPointer, label: "Follow pointer")
        let pinnable = displays.filter { $0.persistentID != nil }
            .sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        var nameCounts: [String: Int] = [:]
        for display in pinnable { nameCounts[Self.displayName(display), default: 0] += 1 }
        var seen: [String: Int] = [:]
        var options = [followPointer]
        var selected = followPointer
        for display in pinnable {
            guard let id = display.persistentID else { continue }
            let name = Self.displayName(display)
            var label = name
            if nameCounts[name, default: 0] > 1 {
                seen[name, default: 0] += 1
                label = "\(name) (\(seen[name, default: 0]))"
            }
            // The pin stores the shown label so a disconnected twin is still told apart.
            let option = NotchDisplayOption(preference: .pinned(NotchDisplayPin(id: id, name: label)), label: label)
            options.append(option)
            if id == preference.pin?.id { selected = option }
        }
        let detail: String
        if let pin = preference.pin {
            if preference.pinnedDisplay(in: pinnable) != nil {
                detail = "Stays on \(selected.label)."
            } else {
                selected = NotchDisplayOption(preference: preference, label: "\(pin.name) (not connected)")
                options.append(selected)
                detail = displays.contains(where: \.isBuiltIn)
                    ? "\(pin.name) isn't connected. Showing on the built-in display."
                    : "\(pin.name) isn't connected. Following the pointer."
            }
        } else {
            detail = "Follows the pointer to the display you're using."
        }
        self.options = options
        self.selected = selected
        self.detail = detail
    }

    private static func displayName(_ display: NotchDisplay) -> String {
        if let name = display.name, !name.isEmpty { return name }
        return display.isBuiltIn ? "Built-in display" : "Display"
    }
}

/// Panel geometry for the chosen display. On a display with a camera housing the collapsed panel is
/// the housing row itself: exactly as tall as the housing, anchored to the top edge of the screen,
/// with a wing on each side of the housing where the sprites and count (left) and the usage readouts (right) live. On any other display it is a compact strip inline with the menu bar row, anchored to the
/// top edge of the screen. The open queue grows downward from the strip. The frame includes the concave ears at the top corners.
/// Geometry depends only on these inputs, so a display change or an interaction never changes what
/// the queue holds or when items expire.
public enum NotchPlacement {
    /// Visible body left of the camera housing, where up to three session sprites, the overflow
    /// mark, and the to-check count live.
    public static let leadingWing: CGFloat = 112
    /// Visible body right of the camera housing while it holds only Codex's weekly readout.
    public static let trailingWing: CGFloat = 60
    /// Width Codex's five-hour readout adds ahead of the weekly one. Claude readouts are sized by
    /// `UsageStripReadouts.wingWidth`.
    public static let readoutWidth: CGFloat = 52
    /// Concave fillet joining the body to the menu bar at each top corner; part of the frame.
    public static let earRadius: CGFloat = 8
    /// Radius of the two bottom corners.
    public static let cornerRadius: CGFloat = 18
    /// Narrowest body a display without a housing gets.
    public static let minimumBodyWidth: CGFloat = 200
    /// Narrowest body the open panel gets.
    public static let expandedBodyWidth: CGFloat = 380
    /// Width opening always adds to the collapsed body, so hovering visibly widens the strip even
    /// when its usage readouts already make it wider than `expandedBodyWidth`.
    public static let expandedGrowth: CGFloat = 60
    /// Strip height on a display showing neither a housing nor a menu bar; otherwise the strip is
    /// the housing or menu bar height.
    public static let collapsedHeight: CGFloat = 40
    public static let maximumExpandedHeight: CGFloat = 480

    public static func bodyWidth(on display: NotchDisplay, expanded: Bool, wing: CGFloat = trailingWing) -> CGFloat {
        let collapsed = max(display.housingWidth + leadingWing + max(trailingWing, wing), minimumBodyWidth)
        return expanded ? max(collapsed + expandedGrowth, expandedBodyWidth) : collapsed
    }

    /// Height of the collapsed strip: the housing row on a display with a camera housing, the menu
    /// bar row on any other display showing one, and `collapsedHeight` where no bar is showing.
    public static func stripHeight(on display: NotchDisplay) -> CGFloat {
        if display.hasPhysicalNotch { return display.topInset }
        return display.menuBarHeight > 0 ? display.menuBarHeight : collapsedHeight
    }

    /// How the strip's content is split around the housing. Extra width when the panel is open is
    /// shared equally by both wings so the housing stays centered in the gap. `wing` is the trailing
    /// wing's width for the usage readouts shown (`UsageStripReadouts.wingWidth`); the leading wing never moves for it.
    public static func strip(on display: NotchDisplay, expanded: Bool, wing: CGFloat = trailingWing) -> StripLayout {
        let body = bodyWidth(on: display, expanded: expanded, wing: wing)
        let trailing = max(trailingWing, wing)
        guard display.hasPhysicalNotch else {
            return StripLayout(leading: body - trailing, gap: 0, trailing: trailing, height: stripHeight(on: display))
        }
        let extra = (body - display.housingWidth - leadingWing - trailing) / 2
        return StripLayout(leading: leadingWing + extra, gap: display.housingWidth, trailing: trailing + extra,
                           height: stripHeight(on: display))
    }

    /// Estimated frame from a row count, used before the content has been measured.
    public static func frame(on display: NotchDisplay, expanded: Bool, rows: Int, extraRows: Bool, wing: CGFloat = trailingWing) -> CGRect {
        let estimate = stripHeight(on: display) + 28 + CGFloat(rows) * 64 + (extraRows ? 56 : 0)
        return frame(on: display, expanded: expanded, contentHeight: estimate, wing: wing)
    }

    /// Frame for a measured content height (strip included): the open panel is exactly as tall as
    /// what it shows, growing downward and capped for long queues.
    public static func frame(on display: NotchDisplay, expanded: Bool, contentHeight: CGFloat, wing: CGFloat = trailingWing) -> CGRect {
        let layout = strip(on: display, expanded: expanded, wing: wing)
        let width = bodyWidth(on: display, expanded: expanded, wing: wing) + 2 * earRadius
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
    public static let grace: Double = 0.18
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

public struct AgentStripSession: Equatable, Sendable {
    public let session: AgentSessionIdentity
    public let working: Bool
    public let color: Int

    public init(session: AgentSessionIdentity, working: Bool, color: Int) {
        self.session = session
        self.working = working
        self.color = color
    }
}

public struct AgentStripSummary: Equatable, Sendable {
    public static let maximumSprites = StripSummary.maximumSprites
    public static let colorCount = StripSummary.colorCount

    public let subject: String
    public let working: Bool
    public let toCheck: Int
    public let sessions: [AgentStripSession]
    public let overflow: Int

    public init(subject: String, working: Bool, toCheck: Int, sessions: [AgentStripSession] = [], overflow: Int = 0) {
        self.subject = subject
        self.working = working
        self.toCheck = toCheck
        self.sessions = sessions
        self.overflow = overflow
    }

    public static func preferredColor(for session: AgentSessionIdentity) -> Int {
        (session.source.rawValue.utf8.reduce(0) { $0 &+ Int($1) }
            &+ session.sourceScope.utf8.reduce(0) { $0 &+ Int($1) }
            &+ session.session.utf8.reduce(0) { $0 &+ Int($1) }) % colorCount
    }

    public static func sessionLabel(_ session: AgentSessionIdentity, names: [AgentSessionIdentity: String] = [:]) -> String {
        let source = session.source == .claude ? "Claude" : "Codex"
        if let name = names[session], !name.isEmpty { return "\(source) · \(name)" }
        return "\(source) session " + String(session.session.prefix(8)).lowercased()
    }

    public static func make(items: [AgentAttentionItem], testPending: Bool = false,
                            names: [AgentSessionIdentity: String] = [:]) -> Self {
        let toCheck = items.filter { $0.kind != .running }.count + (testPending ? 1 : 0)
        let working = items.contains { $0.running?.status == .working }
        let subject: String
        if let first = items.first {
            if let name = names[first.session], !name.isEmpty {
                subject = sessionLabel(first.session, names: names)
            } else if let task = first.approval?.details?.taskName, !task.isEmpty {
                let source = first.session.source == .claude ? "Claude" : "Codex"
                subject = "\(source) · \(task)"
            } else {
                subject = sessionLabel(first.session, names: names)
            }
        } else {
            subject = testPending ? "test notification" : "idle"
        }
        var sessions: [AgentStripSession] = []
        var seen = Set<AgentSessionIdentity>()
        var colors = Set<Int>()
        for item in items where seen.insert(item.session).inserted {
            guard sessions.count < maximumSprites else { continue }
            var color = preferredColor(for: item.session)
            while colors.contains(color) { color = (color + 1) % colorCount }
            colors.insert(color)
            sessions.append(AgentStripSession(session: item.session, working: item.running?.status == .working, color: color))
        }
        return Self(subject: subject, working: working, toCheck: toCheck, sessions: sessions,
                    overflow: max(0, seen.count - maximumSprites))
    }
}
