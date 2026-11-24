import AppKit
import SwiftUI
import HerdlyCore

struct ClaudeQuestionViewStateKey: Hashable, Sendable {
    let sourceScope: String
    let sessionID: String
    let promptID: String
    let toolUseID: String
    let requestID: String
    let index: Int

    init(question: AgentQuestion, index: Int, requestID: String? = nil) {
        sourceScope = question.identity.session.sourceScope
        sessionID = question.identity.session.session
        promptID = question.identity.turn
        toolUseID = question.identity.call
        self.requestID = requestID ?? question.helperRequestID ?? ""
        self.index = index
    }

    var storageKey: String {
        [sourceScope, sessionID, promptID, toolUseID, requestID, String(index)]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

/// How open-queue rows arrive, leave, and change places. Rows keep their identity across
/// refreshes, so a reorder slides each row to its new place instead of redrawing the list. The
/// curve has no bounce and runs close to the panel's own resize, so rows and frame settle together.
/// Under Reduce Motion the change is a 0.15 s crossfade with no offset or scaling.
enum QueueMotion {
    static func curve(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.28)
    }

    static func rowTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -6)).combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    /// Opens or closes a disclosure: at once under Reduce Motion, otherwise with a short ease. Shared by
    /// `NotchDisclosure` and the Earlier fold (D34) so the two folds move alike.
    @MainActor
    static func disclose(reduceMotion: Bool, _ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeOut(duration: 0.12), change) }
    }

    /// Every row and heading in display order: a change here is an arrival, departure, or reorder.
    static func layoutKey(_ groups: [QueueGroup]) -> [AnyHashable] {
        groups.flatMap { group in [AnyHashable(group.heading)] + group.items.map { AnyHashable($0.id) } }
    }
}

extension QueueGroup.Line {
    /// Stable identity for `ForEach`: a row by its ID; one Earlier heading (Earlier rows sit together
    /// in queue order) and one pill per group.
    var layoutID: AnyHashable {
        switch self {
        case .row(let item): AnyHashable(item.id)
        case .earlierHeading: AnyHashable("earlier-heading")
        case .moreRows: AnyHashable("more-rows")
        }
    }
}

/// Queue row sizes shared by the row and its selection ring.
enum QueueRowMetrics {
    /// A result row's line (D34).
    static let resultLine: CGFloat = 30
    /// The space between result rows (D34), split above and below each.
    static let resultGap: CGFloat = 4
    static let ringWidth: CGFloat = 1.5
    /// How far a result row's selection ring path sits outside its line: half the gap less half the
    /// stroke, so the stroke's outer edge meets the band's edge and never reaches the next row.
    static let resultRingOutset: CGFloat = resultGap / 2 - ringWidth / 2
}

/// The one visual vocabulary of the notch: pure black fused to the menu bar, one monospaced face,
/// one green sprite, one dark badge. Nothing here is decoration; every mark is a reading.
enum NotchStyle {
    static let ground = Color.black
    static let ink = Color(red: 0.90, green: 0.90, blue: 0.90)          // #e6e6e6 titles and digits
    static let text = Color(red: 0.56, green: 0.56, blue: 0.56)         // #8f8f8f names and captions
    static let dim = Color(red: 0.47, green: 0.47, blue: 0.47)          // #787878 tertiary, 4.7:1 on black
    static let well = Color(red: 0.165, green: 0.165, blue: 0.165)      // #2a2a2a badge and controls
    /// The opened running row's container (#319, F3): the one card-like surface in the queue.
    static let openRow = Color(red: 0.102, green: 0.102, blue: 0.102)   // #1a1a1a
    /// The hover ground behind a queue row that opens as a card (#320): a highlight only; hover never acts.
    static let hoverRow = Color(red: 0.110, green: 0.110, blue: 0.110)  // #1c1c1c
    /// The question card's typed-answer field (D23), under its faint `well` outline.
    static let typedField = Color(red: 0.078, green: 0.078, blue: 0.078) // #141414
    // Source values chosen so the captured tones match the reference's greens (109,201,125 and 135,222,154).
    static let sprite = Color(red: 0.133, green: 0.773, blue: 0.369)    // #22c55e body
    static let spriteLight = Color(red: 0.298, green: 0.863, blue: 0.502) // #4cdc80 highlight
    static let seam = Color.white.opacity(0.08)
    /// The well behind "Failed" and nothing else: the one red in the panel (D14).
    static let failure = Color(red: 0.227, green: 0.114, blue: 0.114)  // #3a1d1d
    /// Usage ring fills name their source: Codex blue, Claude orange. Nothing else uses these.
    static let codexUsage = Color(red: 0.231, green: 0.510, blue: 0.965)  // #3b82f6
    static let claudeUsage = Color(red: 0.851, green: 0.467, blue: 0.341) // #d97757
    /// A finished row's state words (#418) and nothing else: red for checks failing and conflict, amber
    /// for uncommitted and not pushed, gray for checks running, green for checks passed and merged.
    static let stateRed = stateColor(.red)        // #f87171
    static let stateAmber = stateColor(.amber)    // #fbbf24
    static let stateGray = stateColor(.gray)      // #8f8f8f
    static let stateGreen = stateColor(.green)    // #4ade80

    /// The one mapping from a tone to its colour: the exact sRGB value (`WorkStatusTone.hex`).
    static func stateColor(_ tone: WorkStatusTone) -> Color {
        let channels = tone.components
        return Color(.sRGB, red: channels.red, green: channels.green, blue: channels.blue)
    }

    /// Sprite colors by session, body and highlight; index 0 is the original green.
    static let spriteColors: [(body: Color, light: Color)] = [
        (sprite, spriteLight),
        (Color(red: 0.231, green: 0.510, blue: 0.965), Color(red: 0.376, green: 0.647, blue: 0.980)), // blue
        (Color(red: 0.961, green: 0.620, blue: 0.043), Color(red: 0.984, green: 0.749, blue: 0.141)), // amber
        (Color(red: 0.925, green: 0.282, blue: 0.600), Color(red: 0.957, green: 0.447, blue: 0.714)), // pink
        (Color(red: 0.655, green: 0.545, blue: 0.980), Color(red: 0.769, green: 0.710, blue: 0.992)), // violet
        (Color(red: 0.024, green: 0.714, blue: 0.831), Color(red: 0.133, green: 0.827, blue: 0.933))  // cyan
    ]

    static func spriteColor(_ index: Int) -> (body: Color, light: Color) {
        spriteColors[((index % spriteColors.count) + spriteColors.count) % spriteColors.count]
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A redraw schedule for the quiet rule (#419): the moment the view first draws, each moment in
/// `changes` (when a working row turns quiet) still ahead, and, with `every`, that interval once one of
/// them has passed. Without a change ahead and nothing quiet it never fires again, so a working row
/// costs no timer until it can turn quiet.
struct QuietSchedule: TimelineSchedule {
    let changes: [Date]
    let every: TimeInterval?

    init(changes: [Double], every: TimeInterval? = nil) {
        self.changes = changes.filter(\.isFinite).map { Date(timeIntervalSince1970: $0) }
        self.every = every
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var last: Date?
        return AnyIterator {
            guard let previous = last else {
                last = startDate
                return startDate
            }
            var candidates = changes.filter { $0 > previous }
            if let every, changes.contains(where: { $0 <= previous }) { candidates.append(previous.addingTimeInterval(every)) }
            guard let next = candidates.min() else { return nil }
            last = next
            return next
        }
    }

    /// The time to read quiet at: the entry's date, or the current time when the view redraws for
    /// another reason after its last entry, so a later redraw never reads an old moment.
    static func now(_ entry: Date) -> Double {
        max(entry, Date()).timeIntervalSince1970
    }
}

/// Replaces an element's spoken label when `text` is set; otherwise leaves it as it is.
private struct SpokenLabel: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.accessibilityLabel(text) } else { content }
    }
}

/// The panel outline: a flat top that meets the menu bar, concave ears at both top corners so the
/// body reads as one shape growing out of the housing, and deep rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat = NotchPlacement.earRadius
    var corner: CGFloat = NotchPlacement.cornerRadius

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let top = rect.minY, bottom = rect.maxY
        let left = rect.minX + ear, right = rect.maxX - ear
        let radius = min(corner, (right - left) / 2, (bottom - top - ear) / 2)
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        // Right ear: concave quarter circle whose center sits on the menu bar edge, outside the body.
        path.addArc(center: CGPoint(x: rect.maxX, y: top + ear), radius: ear,
                    startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addArc(center: CGPoint(x: right - radius, y: bottom - radius), radius: radius,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addArc(center: CGPoint(x: left + radius, y: bottom - radius), radius: radius,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: left, y: top + ear))
        path.addArc(center: CGPoint(x: rect.minX, y: top + ear), radius: ear,
                    startAngle: .degrees(0), endAngle: .degrees(-90), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The user's chosen animal (`SpriteKind`) at two points per cell, drawn at its own size, at most
/// 18 by 10 points. It steps between its two frames while a session is working and stands still
/// otherwise; with Reduce Motion it breathes on frame one instead of stepping. Unlit, it is the empty
/// notch's mark: frame one with every cell in well gray, still, and no session's color, so it never
/// reads as a session.
struct Sprite: View {
    var kind: SpriteKind
    var working: Bool
    var reduceMotion: Bool
    var color: Int = 0
    var unlit = false
    /// Points per cell: the notch's 2pt, larger for a Settings preview so edges stay crisp, or
    /// `subagentCell` in a subagent switcher well.
    var cellSize: CGFloat = Sprite.cell
    static let cell: CGFloat = 2
    /// Two-thirds of `cell`: the sprite before a subagent's name in the opened row's switcher (#397),
    /// 9x6pt for the 6x4-cell kinds.
    static let subagentCell: CGFloat = cell * 2 / 3
    /// The fixed leading slot of a queue row, 18x10pt: the widest and tallest kinds, so titles
    /// align whichever kind is chosen. The title follows 6pt after it.
    static let slotWidth = cell * CGFloat(SpriteKind.maximumColumns)
    static let slotHeight = cell * CGFloat(SpriteKind.maximumRows)
    static let slotGap: CGFloat = 6
    /// One shared anchor for every sprite's timeline. Anchored at `.now`, each sprite ticked on its
    /// own offset from when it appeared, so sprites added at different moments stepped out of step.
    static let beatEpoch = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        let frames = kind.frames
        Group {
            if unlit {
                bitmap(frames[0])
            } else if working && !reduceMotion {
                TimelineView(.periodic(from: Sprite.beatEpoch, by: 0.5)) { context in
                    // Ticks land on the half-second grid; rounding keeps a tick a hair early on its own step.
                    let frame = Int((context.date.timeIntervalSinceReferenceDate * 2).rounded()) & 1
                    bitmap(frames[frame])
                }
            } else if working {
                TimelineView(.periodic(from: Sprite.beatEpoch, by: 0.1)) { context in
                    let phase = sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.4)
                    bitmap(frames[0]).opacity(0.75 + 0.25 * phase)
                }
            } else {
                bitmap(frames[0])
            }
        }
        .frame(width: cellSize * CGFloat(kind.columns), height: cellSize * CGFloat(kind.rows))
        .accessibilityHidden(true)
    }

    /// Two filled paths rather than a `Canvas`: SwiftUI draws a Canvas through Metal, which keeps
    /// GPU buffer pools for the process even when still, and redrawn by the working TimelineView
    /// held about 170 MB resident (#343).
    private func bitmap(_ rows: [String]) -> some View {
        // One tone when unlit: the highlight cells fill like the body and close into it.
        let tone = unlit ? (body: NotchStyle.well, light: NotchStyle.well) : NotchStyle.spriteColor(color)
        return ZStack(alignment: .topLeading) {
            cells(in: rows) { $0 != "." && $0 != "+" }.fill(tone.body)
            cells(in: rows) { $0 == "+" }.fill(tone.light)
        }
    }

    private func cells(in rows: [String], where matches: (Character) -> Bool) -> Path {
        Path { path in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where matches(ch) {
                    path.addRect(CGRect(x: CGFloat(x) * cellSize, y: CGFloat(y) * cellSize, width: cellSize, height: cellSize))
                }
            }
        }
    }
}

/// The count of items that need the user: the bare number on the collapsed strip, "N to check"
/// while the queue is open (`StripWing`); hidden at zero by the caller.
struct Badge: View {
    var badge: StripWing.Badge

    init(count: Int) { badge = .count(count) }
    init(_ badge: StripWing.Badge) { self.badge = badge }

    private var named: Bool {
        if case .named = badge { true } else { false }
    }

    var body: some View {
        Text(badge.text)
            .font(NotchStyle.mono(11, .medium)).monospacedDigit()
            .foregroundStyle(NotchStyle.ink)
            .lineLimit(1).fixedSize()
            .frame(minWidth: 16, minHeight: 16)
            // A named badge keeps the well's shape with a little more room either side (`badge-named`).
            .padding(.horizontal, named ? 4 : 2)
            .background(NotchStyle.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// One source's usage limits as one ring (D35): the outer ring is the weekly (Claude: seven-day)
/// window, the inner ring the five-hour one, each a dark-well track filled clockwise from 12 o'clock
/// in the source's hue (Codex blue, Claude orange), with no warning colour near the cap. A window
/// that is not reported draws no ring at all; an unknown window draws an empty track, and the ring
/// carries a dim dash after it so it never reads as 0%. Open, the ring is followed by its numbers
/// ("61/18%"). Fill changes are not animated. Hidden from VoiceOver; the strip label speaks it.
struct UsageRing: View {
    let readout: UsageStripReadout
    var showsNumbers: Bool

    private var tint: Color { readout.source == .claude ? NotchStyle.claudeUsage : NotchStyle.codexUsage }

    var body: some View {
        HStack(spacing: UsageStripReadouts.textGap) {
            ZStack {
                arc(readout.weekly, diameter: UsageStripReadouts.outerRingDiameter)
                arc(readout.fiveHour, diameter: UsageStripReadouts.innerRingDiameter)
            }
            .frame(width: UsageStripReadouts.ringSize, height: UsageStripReadouts.ringSize)
            // A new reading redraws the fill in place; it never animates.
            .transaction { $0.animation = nil }
            if showsNumbers {
                numbers
            } else if readout.showsDash {
                Text(verbatim: "—").foregroundStyle(NotchStyle.dim)
            }
        }
        .font(NotchStyle.mono(11, .medium)).monospacedDigit()
        .lineLimit(1).fixedSize()
        .accessibilityHidden(true)
    }

    /// The track, and over it the used share; an unknown window keeps the track alone, so it never
    /// reads as a fill of 0%, and a window that is not reported draws nothing.
    @ViewBuilder
    private func arc(_ window: UsageWindowState, diameter: CGFloat) -> some View {
        if window.isShown {
            let stroke = StrokeStyle(lineWidth: UsageStripReadouts.ringLineWidth, lineCap: .butt)
            ZStack {
                Circle().stroke(NotchStyle.well, style: stroke)
                if let fraction = window.share?.fraction, fraction > 0 {
                    Circle().trim(from: 0, to: fraction).stroke(tint, style: stroke).rotationEffect(.degrees(-90))
                }
            }
            .frame(width: diameter, height: diameter)
        }
    }

    /// Five-hour, a dim regular-weight slash, week, one trailing percent, as one line of text.
    private var numbers: Text {
        readout.openText.reduce(Text(verbatim: "")) { line, run in
            let part = run.dim
                ? Text(verbatim: run.text).fontWeight(.regular).foregroundStyle(NotchStyle.dim)
                : Text(verbatim: run.text).foregroundStyle(NotchStyle.ink)
            return Text("\(line)\(part)")
        }
    }
}

/// A control in the panel's own vocabulary: a dark well that inverts to light when pressed and
/// shows a visible ring when it has keyboard focus.
struct NotchButtonStyle: ButtonStyle {
    var emphasized = false
    /// A choice the user made here: drawn in the pressed look until Codex records the answer.
    var selected = false
    /// 4pt for a button; 2pt for a subagent switcher well (#397). A question card keeps its own 5pt.
    var verticalPadding: CGFloat = 4
    @Environment(\.questionCard) private var questionCard
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let inverted = configuration.isPressed || selected
        configuration.label
            .font(questionCard ? QuestionCardStyle.font(11) : NotchStyle.mono(11, emphasized ? .semibold : .regular))
            .foregroundStyle(inverted ? Color.black : (enabled ? NotchStyle.ink : NotchStyle.dim))
            .padding(.horizontal, questionCard ? 9 : 8).padding(.vertical, questionCard ? 5 : verticalPadding)
            .background(inverted ? NotchStyle.ink : NotchStyle.well,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(enabled || questionCard ? 1 : 0.6)
    }
}

struct NotchButton: View {
    let title: String
    var emphasized = false
    var selected = false
    /// Focus owned by the caller, so it can move focus here (the opened row's Open, #397); by default
    /// the button keeps its own.
    var focus: FocusState<Bool>.Binding? = nil
    /// The key that does this button on a card that has the keyboard (#428, Paper L "2 · Keyboard
    /// in"): drawn 8pt after the title in 10pt dim, never part of the button's name. Callers say it
    /// in the hint instead (`NotchShortcut.hint`).
    var shortcut: NotchShortcut? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        let binding = focus ?? $focused
        Button(action: action) {
            if let shortcut {
                HStack(spacing: 8) {
                    Text(verbatim: title)
                    Text(verbatim: shortcut.symbol).font(QuestionCardStyle.font(10)).foregroundStyle(NotchStyle.dim)
                        .accessibilityHidden(true)
                }
            } else {
                Text(verbatim: title)
            }
        }
            .buttonStyle(NotchButtonStyle(emphasized: emphasized, selected: selected))
            .focused(binding)
            .modifier(NotchFocusRing(focused: binding.wrappedValue))
    }
}

/// One of the walk header's ‹ › wells (#440, Paper K "D · Walk the to-check list"): the notch's own
/// button style at the slim 2pt height the subagent switcher's wells use; dim and not pressable at
/// either end.
struct WalkStepWell: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) { Text(verbatim: symbol) }
            .buttonStyle(NotchButtonStyle(verticalPadding: 2))
            .disabled(!enabled)
            .focused($focused)
            .modifier(NotchFocusRing(focused: focused))
    }
}

/// A keyboard card's key labels (#428): what each key is called aloud, and the hint that says it, so a
/// key label is never part of a button's name ("Shortcut: O").
enum NotchShortcut: Equatable {
    case open
    case dismiss
    case returnKey
    /// An approval card's Approve (#439, Paper K "B · Approval keys").
    case commandReturn
    /// An approval card's Deny (#439).
    case commandDelete

    /// What the button shows after its title.
    var symbol: String {
        switch self {
        case .open: "O"
        case .dismiss: "X"
        case .returnKey: "⏎"
        case .commandReturn: "⌘⏎"
        case .commandDelete: "⌘⌫"
        }
    }

    /// What VoiceOver says for the key.
    var spoken: String {
        switch self {
        case .open: "O"
        case .dismiss: "X"
        case .returnKey: "Return"
        case .commandReturn: "Command Return"
        case .commandDelete: "Command Delete"
        }
    }

    static func hint(_ base: String?, shortcut: NotchShortcut?) -> String {
        [shortcut.map { "Shortcut: \($0.spoken)." }, base].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// The keyboard focus ring every notch control shares: 1.5pt ink at 90%, 6pt continuous corners,
/// 2pt outside the control.
struct NotchFocusRing: ViewModifier {
    let focused: Bool
    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
    }
}

/// The result card's reply field (#323, 9NU): one line the user types and sends to a finished
/// session. Return in the field and Send do the same thing, and an empty or all-space draft sends
/// nothing. Escape follows the panel's one Escape rule from the field (a clicked card steps back to
/// the queue, otherwise the panel collapses) without dismissing anything. The caller owns the text
/// and decides what sending means.
struct DraftField: View {
    let placeholder: String
    @Binding var text: String
    let sendTitle: String
    /// Names the subject session in both labels, for keyboard and VoiceOver use.
    let fieldLabel: String
    let sendLabel: String
    var hint: String?
    var committedText: String?
    let onEscape: () -> Void
    let send: () -> Void
    @Environment(\.isEnabled) private var enabled

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A 30pt `{colors.open-row}` ground with 6pt corners and no outline (D23 keeps the outline for the
    /// question field); Send sits inside it once there is text. Unsent text holds the card open.
    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.ink)
                .onSubmit { if enabled { send() } }
                .onExitCommand(perform: onEscape)
                .accessibilityLabel(fieldLabel)
                .accessibilityHint(hint ?? "")
            if hasText {
                NotchButton(title: sendTitle, action: send)
                    .accessibilityLabel(sendLabel)
            }
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 30)
        .background(NotchStyle.openRow, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .preference(key: DraftInProgressKey.self, value: text != committedText && hasText)
    }
}

/// True while any `DraftField` on screen holds unsent text. Only rendered fields report, so text
/// left in a card that has since gone away holds nothing open.
struct DraftInProgressKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// One answer option: its digit in the session's colour, the label in ink. The option the user
/// selected fills with that colour and reads in black, the way a pressed control inverts; the colour
/// says which session's question this is, the fill says what was chosen. Selecting sends nothing
/// (D16). A read-only option (the Codex app without the daemon, #321) sits on the darker open-row
/// ground with its digit dim and its label in text gray. A multi-select option shows a box (☑/☐) in
/// the digit slot. Each option spans the column, so the list reads as one stack and every label wraps.
struct OptionButton: View {
    let number: Int
    let label: String
    let tone: (body: Color, light: Color)
    var selected = false
    var readOnly = false
    /// Multi-select: ticked or not, drawn in place of the digit. Nil draws the digit.
    var checked: Bool? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let display = QuestionOptionLabel(label)
        let live = enabled && !readOnly
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(checked.map { $0 ? "☑" : "☐" } ?? "\(number)").monospacedDigit()
                    .font(QuestionCardStyle.font(11, .semibold))
                    .foregroundStyle(selected ? Color.black : (live ? tone.light : NotchStyle.dim))
                    .frame(width: 14, alignment: .leading)
                Text(display.text).foregroundStyle(selected ? Color.black : (live ? NotchStyle.ink : NotchStyle.text))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if display.recommended {
                    Text("Recommended").font(QuestionCardStyle.font(10))
                        .foregroundStyle(selected ? Color.black : NotchStyle.dim)
                        .fixedSize()
                }
            }
            .font(QuestionCardStyle.font(11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? tone.body : (readOnly ? NotchStyle.openRow : NotchStyle.well),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

        }
        .disabled(readOnly)
        .accessibilityValue(checked.map { $0 ? "Ticked" : "Not ticked" } ?? (selected ? "Selected" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .buttonStyle(QuestionOptionButtonStyle())
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
    }
}

/// A question card's "Or type an answer" field (D23), on the daemon path and on a Claude question: the
/// one surface that keeps a faint outline, so it reads as a place to type. A dim "›" leads the text.
/// Return does the card's Next or Send with the typed text in place of a selected option; the bottom
/// row's button does the same. Escape follows
/// the panel's one Escape rule. Unsent text holds the card open (`DraftInProgressKey`).
struct QuestionTypedField: View {
    var placeholder = "Or type an answer"
    @Binding var text: String
    let fieldLabel: String
    var committedText: String?
    let onEscape: () -> Void
    let submit: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("›").foregroundStyle(NotchStyle.dim).accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(NotchStyle.ink)
                .onSubmit { if enabled { submit() } }
                .onExitCommand(perform: onEscape)
                .accessibilityLabel(fieldLabel)
                .accessibilityHint("Takes the place of a selected option. Nothing is sent until Send.")
        }
        .font(QuestionCardStyle.font(11))
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(NotchStyle.typedField, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(NotchStyle.well, lineWidth: 1))
        .preference(key: DraftInProgressKey.self, value: text != committedText && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private struct QuestionOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // PlainButtonStyle dims disabled selections, obscuring the answer being reviewed.
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Viewed position and answer progress are independent; changing a step only navigates. Each step
/// is a 2pt bar with its header beneath (10pt; the viewed one semibold ink), and an answered step's
/// answer beneath that in text gray ("sent: 1 · JSON lines" for a typed key).
struct QuestionStepRail: View {
    let steps: [QuestionSteps.Step]
    let show: (Int) -> Void
    @FocusState private var focusedStep: Int?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(steps) { step in cell(step, inline: true).frame(maxWidth: .infinity, alignment: .leading) }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(steps) { step in cell(step) }
            }
        }
    }

    private func cell(_ step: QuestionSteps.Step, inline: Bool = false) -> some View {
        Button { show(step.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 1).fill(step.state == .current ? NotchStyle.ink :
                    (step.state == .answered ? NotchStyle.dim : NotchStyle.well)).frame(height: 2)
                Text(step.label)
                    .font(QuestionCardStyle.font(10, step.state == .current ? .semibold : .regular))
                    .foregroundStyle(step.state == .current ? NotchStyle.ink : NotchStyle.dim)
                    .fixedSize(horizontal: inline, vertical: !inline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let summary = step.summary {
                    Text(summary).font(QuestionCardStyle.font(10)).foregroundStyle(NotchStyle.text)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedStep, equals: step.id)
        .overlay(RoundedRectangle(cornerRadius: 3)
            .stroke(NotchStyle.ink.opacity(focusedStep == step.id ? 0.9 : 0), lineWidth: 1).padding(-2))
        .accessibilityLabel("View question \(step.id + 1): \(step.label)")
        .accessibilityValue([step.state == .current ? "Viewing" : nil, step.summary].compactMap { $0 }.joined(separator: ", "))
    }
}

/// An agent's message with its markdown read as formatting (`MessageMarkdown`). `.result` is the
/// result card's 11pt mono text gray at a 16pt line height; `.question` is the question card's 12pt ink:
/// bold and headings in ink, code on the `well`, tables as aligned columns. A message cut mid-table or
/// mid-fence still draws; only web links stay links, so a message cannot open another app.
struct ResultMarkdown: View {
    enum Style {
        case result, question

        func font(_ size: CGFloat? = nil, _ weight: Font.Weight = .regular) -> Font {
            switch self {
            case .result: NotchStyle.mono(size ?? 11, weight)
            case .question: QuestionCardStyle.font(size ?? 12, weight)
            }
        }
        var color: Color { self == .result ? NotchStyle.text : NotchStyle.ink }
        /// Each font sets a little under its line height; this makes up the rest.
        var lineSpacing: CGFloat { self == .result ? 3 : 2 }
    }

    let text: String
    var style: Style = .result

    /// A big message takes milliseconds to parse and the panel redraws often, so the last few stay
    /// parsed. Like the messages themselves, this lives only in process memory.
    @MainActor private static let parsed: NSCache<NSString, ParsedBlocks> = {
        let cache = NSCache<NSString, ParsedBlocks>()
        cache.countLimit = 16
        return cache
    }()
    private final class ParsedBlocks {
        let blocks: [MessageMarkdownBlock]
        init(_ blocks: [MessageMarkdownBlock]) { self.blocks = blocks }
    }

    private var blocks: [MessageMarkdownBlock] {
        if let hit = Self.parsed.object(forKey: text as NSString) { return hit.blocks }
        let blocks = MessageMarkdown.blocks(text)
        Self.parsed.setObject(ParsedBlocks(blocks), forKey: text as NSString)
        return blocks
    }

    var body: some View {
        MarkdownBlocks(blocks: blocks, style: style)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func line(_ text: AttributedString, style: Style = .result, size: CGFloat? = nil, weight: Font.Weight = .regular,
                     color: Color? = nil, alignment: TextAlignment = .leading) -> some View {
        Text(styled(text)).font(style.font(size, weight)).foregroundStyle(color ?? style.color)
            .lineSpacing(style.lineSpacing)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
    }

    /// Colors for the inline marks Foundation parsed. Only web links stay links.
    static func styled(_ text: AttributedString) -> AttributedString {
        var value = text
        for (intent, range) in value.runs[\.inlinePresentationIntent].reversed() {
            guard let intent else { continue }
            if intent.contains(.code) {
                value[range].foregroundColor = NotchStyle.ink
                value[range].backgroundColor = NotchStyle.well
            } else if intent.contains(.stronglyEmphasized) {
                value[range].foregroundColor = NotchStyle.ink
            }
            if intent.contains(.strikethrough) {
                value[range].strikethroughStyle = .single
            }
        }
        for (link, range) in value.runs[\.link].reversed() {
            guard let link else { continue }
            if ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                value[range].foregroundColor = NotchStyle.ink
                value[range].underlineStyle = .single
            } else {
                value[range].link = nil
            }
        }
        return value
    }
}

/// A run of blocks, recursive through lists and quotes. `listDepth` is how many lists enclose these;
/// a nested list steps in 14pt, up to three levels, so deep nesting cannot squeeze the text away.
private struct MarkdownBlocks: View {
    let blocks: [MessageMarkdownBlock]
    let style: ResultMarkdown.Style
    var listDepth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MessageMarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            ResultMarkdown.line(text, style: style)
        case let .heading(level, text):
            ResultMarkdown.line(text, style: style, size: style == .result && level <= 2 ? 12 : nil, weight: .semibold, color: NotchStyle.ink)
                .accessibilityAddTraits(.isHeader)
        case let .list(items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    MarkdownListItem(item: item, style: style, listDepth: listDepth)
                }
            }
            .padding(.leading, (1...3).contains(listDepth) ? 14 : 0)
        case let .quote(blocks):
            MarkdownBlocks(blocks: blocks, style: style, listDepth: listDepth)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(NotchStyle.well).frame(width: 2) }
        case let .code(text):
            Text(verbatim: text).font(style.font(11)).foregroundStyle(NotchStyle.ink)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(NotchStyle.typedField, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(NotchStyle.well, lineWidth: 1))
        case let .table(alignments, header, rows):
            ResultTable(alignments: alignments, header: header, rows: rows, style: style)
        case .rule:
            Rectangle().fill(NotchStyle.well).frame(height: 1)
        }
    }
}

/// The marker beside the item's text and whatever else belongs in that text column; a nested list
/// and anything after it sit below, stepped in from the marker.
private struct MarkdownListItem: View {
    let item: MessageMarkdownListItem
    let style: ResultMarkdown.Style
    let listDepth: Int

    private static func isList(_ block: MessageMarkdownBlock) -> Bool {
        if case .list = block { true } else { false }
    }

    var body: some View {
        let beside = item.blocks.prefix { !Self.isList($0) }
        let below = item.blocks.dropFirst(beside.count)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.marker).font(style.font(11)).foregroundStyle(NotchStyle.dim)
                MarkdownBlocks(blocks: Array(beside.isEmpty ? below : beside), style: style, listDepth: listDepth + 1)
            }
            .accessibilityElement(children: .combine)
            if !beside.isEmpty, !below.isEmpty {
                MarkdownBlocks(blocks: Array(below), style: style, listDepth: listDepth + 1)
            }
        }
    }
}

/// A markdown table in the card's width: each column's share follows its longest cell, within
/// bounds, so a short "Priority" column does not take a third of the row; cells wrap.
private struct ResultTable: View {
    let alignments: [PresentationIntent.TableColumn.Alignment]
    let header: [AttributedString]
    let rows: [[AttributedString]]
    let style: ResultMarkdown.Style

    private var weights: [CGFloat] {
        header.indices.map { column in
            let longest = ([header] + rows).map { $0[column].characters.count }.max() ?? 0
            return CGFloat(min(max(longest, 6), 40))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(header, header: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                Rectangle().fill(NotchStyle.well).frame(height: 1)
                row(cells, header: false)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(NotchStyle.well).frame(height: 1).offset(y: -1) }
    }

    private func alignment(_ column: Int) -> TextAlignment {
        guard alignments.indices.contains(column) else { return .leading }
        switch alignments[column] {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
    }

    private func row(_ cells: [AttributedString], header: Bool) -> some View {
        WeightedColumns(weights: weights, spacing: 10) {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                ResultMarkdown.line(cell, style: style, weight: header ? .semibold : .regular,
                                    color: header ? NotchStyle.ink : nil, alignment: alignment(column))
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// Lays subviews side by side, each given a width share in proportion to its weight, as tall as
/// the tallest. Every row of a table uses the same weights, so columns line up.
private struct WeightedColumns: Layout {
    let weights: [CGFloat]
    let spacing: CGFloat

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let used = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let sum = max(used.reduce(0, +), 1)
        let available = max(total - spacing * CGFloat(max(count - 1, 0)), 0)
        return used.map { available * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let heights = zip(subviews, widths(width, count: subviews.count)).map { subview, columnWidth in
            subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, columnWidth) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: columnWidth, height: nil))
            x += columnWidth + spacing
        }
    }
}

/// The whole last message (#323): its own scroll, as tall as the text up to `cap`, so a long
/// message never pushes Open and Dismiss off the panel. While text lies below the visible part, its
/// bottom edge fades into the ground so the cut reads as "more to scroll", not the message's end.
struct ResultMessageScroll: View {
    let text: String
    /// Twelve 16pt lines.
    private static let cap: CGFloat = 192
    private static let fadeHeight: CGFloat = 28
    private static let space = "result-message-scroll"
    @State private var naturalHeight: CGFloat = 0
    /// The text's bottom edge in the scroll's own coordinates; past the visible height means more below.
    @State private var contentBottom: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { min(max(naturalHeight, 16), Self.cap) }
    private var moreBelow: Bool { contentBottom > height + 1 }

    var body: some View {
        ScrollView(.vertical) {
            ResultMarkdown(text: text)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                naturalHeight = proxy.size.height
                                contentBottom = proxy.frame(in: .named(Self.space)).maxY
                            }
                            .onChange(of: proxy.size.height) { _, height in naturalHeight = height }
                            .onChange(of: proxy.frame(in: .named(Self.space)).maxY) { _, bottom in contentBottom = bottom }
                    }
                }
        }
        .coordinateSpace(name: Self.space)
        .frame(height: height)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [NotchStyle.ground.opacity(0), NotchStyle.ground],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeHeight)
                .opacity(moreBelow ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: moreBelow)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// A disclosure that keeps its content on the panel's left edge. SwiftUI's DisclosureGroup indents
/// and centers what it reveals; here the revealed rows align with everything above them.
/// The label names what pressing it does, so an open disclosure reads "Hide …" (or `expandedTitle`)
/// rather than still offering to show what is already shown. The result card's toggle (#323, 9NU:
/// "Show all ›") uses the trailing style: dim words, then "›" turning down when open.
struct NotchDisclosure<Content: View>: View {
    enum Chevron { case leading, trailing }
    let title: String
    var expandedTitle: String? = nil
    /// Names the item for VoiceOver, so the spoken label follows the visible one.
    var subject: String? = nil
    var chevron: Chevron = .leading
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content
    @FocusState private var focused: Bool
    /// The system setting, as the controls window reads it; the model's `reduceMotion` mirrors the same one.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var currentTitle: String {
        guard expanded else { return title }
        if let expandedTitle { return expandedTitle }
        return title.hasPrefix("Show ") ? "Hide " + title.dropFirst(5) : title
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                QueueMotion.disclose(reduceMotion: reduceMotion) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    switch chevron {
                    case .leading:
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 10)
                        Text(currentTitle)
                    case .trailing:
                        Text(currentTitle)
                        Text("›").rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .font(NotchStyle.mono(11)).foregroundStyle(chevron == .leading ? NotchStyle.text : NotchStyle.dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(.horizontal, -4).padding(.vertical, -2))
            .accessibilityLabel(subject.map { "\(currentTitle) for \($0)" } ?? currentTitle)
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded { content() }
        }
    }
}

/// The panel's small pill: 10pt mono on a fill, 6pt by 1pt padding, 4pt continuous corners, sized to
/// its text. Shared by "Failed", "Ns left", and "+N more". `bar` draws a 2pt ink bar along the bottom
/// edge, that share of the pill wide and clipped to it; nil draws none.
struct SmallPill: ViewModifier {
    let fill: Color
    let textColor: Color
    var weight: Font.Weight = .regular
    var bar: Double? = nil

    func body(content: Content) -> some View {
        content
            .font(NotchStyle.mono(10, weight)).foregroundStyle(textColor)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(fill)
            .overlay(alignment: .bottomLeading) {
                if let bar {
                    GeometryReader { proxy in
                        Rectangle().fill(NotchStyle.ink)
                            .frame(width: proxy.size.width * bar, height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }
}

extension View {
    func smallPill(fill: Color, textColor: Color, weight: Font.Weight = .regular, bar: Double? = nil) -> some View {
        modifier(SmallPill(fill: fill, textColor: textColor, weight: weight, bar: bar))
    }
}

/// A row's one off-path word (D17). "Failed" sits in the dark red well, the panel's only red (D14);
/// "Handed back", "Waiting", "Status unknown", and "Unreachable" (#322) are plain dim text with no
/// well. Spoken through the row heading, so it is hidden from VoiceOver here.
struct ExceptionWord: View {
    let exception: RowException
    var body: some View {
        if exception.isFailure {
            Text(exception.word)
                .smallPill(fill: NotchStyle.failure, textColor: NotchStyle.ink)
                .accessibilityHidden(true)
        } else {
            Text(exception.word)
                .font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.dim)
                .lineLimit(1).fixedSize()
                .accessibilityHidden(true)
        }
    }
}

/// The place after a row's name as one line (`RowPlaceLine`, #418): dim "· ", a finished row's state
/// words in their tone, then dim " · herdly#431" or the place; a quiet working row (#419) ends with
/// dim " · " and "quiet" in amber. The state never truncates; the part
/// after it takes what width is left and tail-truncates. A verdict change redraws the text in place
/// with no motion of its own. Spoken through the row heading.
struct RowPlaceLineText: View {
    let line: RowPlaceLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let label = line.label {
                Text("\(Text("· ").foregroundStyle(NotchStyle.dim))\(Text(label.words).foregroundStyle(NotchStyle.stateColor(label.tone)))")
                    .lineLimit(1).fixedSize()
                if let detail = line.detail {
                    Text(" · \(detail)").foregroundStyle(NotchStyle.dim)
                        .lineLimit(1).truncationMode(.tail)
                }
            } else if let detail = line.detail {
                Text("· \(detail)").foregroundStyle(NotchStyle.dim)
                    .lineLimit(1).truncationMode(.tail)
            }
            if line.quiet {
                // #419: after the place, in amber; the place gives way first, the word never does.
                Text("\(Text(line.quietLead).foregroundStyle(NotchStyle.dim))\(Text(RowPlaceLine.quietWord).foregroundStyle(NotchStyle.stateColor(RowPlaceLine.quietTone)))")
                    .lineLimit(1).fixedSize()
            }
        }
        .font(NotchStyle.mono(11))
        .accessibilityHidden(true)
    }
}

/// A row header's name and place (D17, #418): the name in 12pt semibold ink, then the row note or the
/// place line, which takes the free width. When the row runs out of room the place's repository or
/// branch truncates first, then the name; a finished row's state words never do, and the word slot and
/// age after this view are fixed. Spoken through the row heading.
struct RowHeaderNamePlace: View {
    let name: String
    let note: RowNote?
    let place: RowPlaceLine?
    /// The place's tooltip: the full working directory when known.
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
                .lineLimit(1).truncationMode(.tail).layoutPriority(2)
            if let note {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("·")
                    Text(note.text).lineLimit(1).truncationMode(.tail)
                }
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let place {
                RowPlaceLineText(line: place)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(help ?? place.detail ?? place.text)
            } else {
                Spacer(minLength: 0)
            }
        }
    }
}

/// "18s left" on a live approval (D7, D12): ink on a well, with a 2pt ink bar along its bottom edge
/// as long as the remaining share of the request's own window. It steps once a second with no
/// animation, so Reduce Motion needs nothing extra. Display only; the deadline never moves.
struct SecondsLeftPill: View {
    let countdown: ApprovalCountdown
    var body: some View {
        Text(countdown.label)
            .monospacedDigit()
            .smallPill(fill: NotchStyle.well, textColor: NotchStyle.ink, weight: .semibold, bar: countdown.fraction)
            .transaction { $0.animation = nil }
            .accessibilityHidden(true)
    }
}

/// The approval card's "Ns left" row (D7, #320): a full-width 2pt bar, ink over a well track as long
/// as the remaining share of the request's own window, then "18s left" in 10pt dim, bright 600-weight
/// ink for the last five seconds (`ApprovalCountdown.isUrgent`). It steps once a second without
/// animation, so Reduce Motion needs nothing extra, and it never moves the deadline.
struct ApprovalCountdownRow: View {
    let countdown: ApprovalCountdown
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(NotchStyle.well)
                    Rectangle().fill(NotchStyle.ink).frame(width: proxy.size.width * countdown.fraction)
                }
            }
            .frame(height: 2)
            Text(countdown.label)
                .font(NotchStyle.mono(10, countdown.isUrgent ? .semibold : .regular))
                .foregroundStyle(countdown.isUrgent ? NotchStyle.ink : NotchStyle.dim)
                .monospacedDigit()
                .frame(height: 12)
                .fixedSize()
        }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(countdown.spoken)
    }
}

/// The approval card's command (#320): the full command in 11pt ink at a 14pt line height, never
/// shortened. Past six lines (84pt) it sits in a box that scrolls, and "Show full command" lifts the
/// cap; a command that fits shows no disclosure.
struct ApprovalCommandBox: View {
    let command: String
    let subject: String
    @Binding var expanded: Bool
    /// The command's own height at the card's width, measured where it is drawn.
    @State private var naturalHeight: CGFloat = 0
    private static let cap: CGFloat = 84
    private var overflows: Bool { naturalHeight > Self.cap + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if overflows && !expanded {
                ScrollView(.vertical) { commandText }
                    .frame(height: Self.cap)
            } else {
                commandText
            }
            if overflows {
                NotchDisclosure(title: "Show full command", subject: subject, expanded: $expanded) { EmptyView() }
            }
        }
    }

    private var commandText: some View {
        Text(command)
            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.ink)
            // SF Mono 11pt sets about 13pt of line; one more makes the 14pt line height.
            .lineSpacing(1)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { naturalHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in naturalHeight = height }
                }
            }
    }
}

/// A single approval card's kind word (#320): "Approve" in a well pill while it can be decided here,
/// then the queue's own "Handed back". The row heading already speaks the state.
struct ApprovalKindWordView: View {
    let word: ApprovalCardKindWord
    var body: some View {
        switch word {
        case .approve:
            Text(word.word)
                .smallPill(fill: NotchStyle.well, textColor: NotchStyle.ink, weight: .semibold)
                .accessibilityHidden(true)
        case let .exception(exception):
            ExceptionWord(exception: exception)
        }
    }
}

/// The hover ground behind a queue row that opens as a card (#320) or a reachable result row that
/// opens its session (#322): #1c1c1c with 5pt continuous corners, 6pt outside the row horizontally
/// like the selection ring. Hover only highlights; it never opens, selects, or acts. Under Reduce
/// Motion the ground appears without animation.
struct CardRowHover: ViewModifier {
    let id: AgentAttentionID
    let active: Bool
    @Binding var hovered: AgentAttentionID?
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let highlighted = active && hovered == id
        content
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(NotchStyle.hoverRow)
                    .padding(.horizontal, -6)
                    .opacity(highlighted ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
            }
            .onHover { inside in
                if inside, active { hovered = id } else if hovered == id { hovered = nil }
            }
    }
}

/// A kind section's "+N more" (D13): a pressable well that opens the rest of that section in place.
/// It is a plain button, so Tab and VoiceOver reach it; the arrow-key row selection does not.
struct MoreRowsPill: View {
    let count: Int
    let section: String
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            Text("+\(count) more")
                .smallPill(fill: NotchStyle.well, textColor: NotchStyle.text)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
        .accessibilityLabel("Show \(count) more in \(section)")
    }
}

/// A result row's quiet Dismiss or Remove (D34, #347): a 22pt square with a 10pt × in a 1.4pt text-gray
/// stroke and no fill, in the fixed lane after the age. Hover or keyboard focus draws the gray well
/// under an ink ×. The caller gives the spoken label ("Dismiss completion: …", "Remove: …") and any hint.
struct RowDismissButton: View {
    static let lane: CGFloat = 22
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false
    var body: some View {
        let lit = hovered || focused
        Button(action: action) {
            Path { path in
                path.move(to: CGPoint(x: 2, y: 2)); path.addLine(to: CGPoint(x: 8, y: 8))
                path.move(to: CGPoint(x: 8, y: 2)); path.addLine(to: CGPoint(x: 2, y: 8))
            }
            .stroke(lit ? NotchStyle.ink : NotchStyle.text, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 10, height: 10)
            .frame(width: Self.lane, height: Self.lane)
            .background(lit ? NotchStyle.well : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
    }
}

/// The Earlier heading (D34, #347): a disclosure with the "N working" fold's chevron in the sprite
/// slot, then "Earlier" in 10pt dim and its count in 10pt semibold text gray, like a kind section's
/// heading (Paper A3). "Dismiss all" is 11pt text-gray text with no well at the trailing edge, over
/// the × lane, shown folded and open; it clears exactly the results the heading counts.
struct EarlierHeading: View {
    let count: Int
    let open: Bool
    /// The keyboard selection is on this heading (a folded Earlier is one arrow stop).
    let selected: Bool
    let toggle: () -> Void
    let dismissAll: () -> Void
    @FocusState private var focused: Bool
    @FocusState private var dismissFocused: Bool
    var body: some View {
        let results = count == 1 ? "result" : "results"
        HStack(alignment: .center, spacing: 8) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: Sprite.slotGap) {
                    // The same chevron, size, and frame as `NotchDisclosure`'s, in the sprite slot.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(NotchStyle.text)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                        .frame(width: Sprite.slotWidth, alignment: .leading)
                    Text("Earlier").font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.dim)
                    Text("\(count)").font(NotchStyle.mono(10, .semibold)).foregroundStyle(NotchStyle.text).monospacedDigit()
                    Spacer(minLength: 0)
                }
                .frame(height: RowDismissButton.lane)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(NotchStyle.ink.opacity(focused || selected ? 0.9 : 0), lineWidth: QueueRowMetrics.ringWidth).padding(.horizontal, -6))
            .accessibilityLabel("Earlier, \(count) \(results)")
            .accessibilityValue(open ? "expanded" : "collapsed")
            .accessibilityAddTraits(selected ? [.isHeader, .isSelected] : .isHeader)
            Button(action: dismissAll) {
                Text("Dismiss all").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text)
                    .frame(height: RowDismissButton.lane)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($dismissFocused)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(NotchStyle.ink.opacity(dismissFocused ? 0.9 : 0), lineWidth: QueueRowMetrics.ringWidth).padding(.horizontal, -4))
            .accessibilityLabel("Dismiss all \(count) earlier \(results)")
        }
    }
}

/// Reports the open panel's natural content height so the window can be exactly that tall.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Notch: View {
    @ObservedObject var model: Companion
    /// Observed so the empty queue's reading follows Claude setup changes; read through `model`.
    @ObservedObject var claudeSetup: ClaudeSetupModel
    /// Observed so a finished row's work status redraws in place when a reading lands (#418); read
    /// through `model`.
    @ObservedObject var workStatus: WorkStatusModel
    @FocusState private var headerFocused: Bool
    /// The opened running row's focused switcher well and Open (#397), owned here so focus can move
    /// between them after the switcher itself has left.
    @FocusState private var switcherFocus: OpenRunningRow.Shown?
    @FocusState private var runningOpenFocused: Bool
    /// The switcher well that last held focus, kept past SwiftUI clearing it as its well leaves.
    @State private var lastSwitcherFocus: OpenRunningRow.Shown?
    /// Disclosures the user opened, by the item they belong to; cleared when the item leaves.
    @State private var openDisclosures: Set<String> = []
    /// Typed answers being composed, by call id and question index; sent only on Return or Send.
    @State private var drafts: [String: String] = [:]
    /// Text typed in a Codex daemon card's field, per card (`QuestionTypedDrafts`).
    @State private var questionDrafts: [ClaudeQuestionViewStateKey: QuestionTypedDrafts] = [:]
    @State private var viewedQuestions: [ClaudeQuestionViewStateKey: Int] = [:]
    /// A Claude call's selections are kept in the view until the user presses Send (D16, #382).
    @State private var claudeSelections: [ClaudeQuestionViewStateKey: ClaudeQuestionCallSelection] = [:]
    /// The queue row under the pointer that would open as a card; a highlight only (#320).
    @State private var hoveredCardRow: AgentAttentionID?
    /// Ghostty's `tty` support for herdr Open availability; refreshed off the main actor.
    @ObservedObject private var ghosttyTTY = GhosttyTTYSupportMonitor.shared

    private func draft(_ key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
    }

    private func disclosure(_ key: String) -> Binding<Bool> {
        Binding(get: { openDisclosures.contains(key) },
                set: { open in if open { openDisclosures.insert(key) } else { openDisclosures.remove(key) } })
    }

    private func questionViewStateKey(_ question: AgentQuestion, _ index: Int) -> ClaudeQuestionViewStateKey {
        let requestID: String?
        if let legacy = model.codexQuestion(for: question), case let .daemon(request) = model.route(for: legacy) {
            requestID = "\(request.requestID):\(request.receivedAt)"
        } else {
            requestID = nil
        }
        return ClaudeQuestionViewStateKey(question: question, index: index, requestID: requestID)
    }

    /// The daemon field for the card's viewed question: what it shows is what Send or Return sends.
    private func questionDraft(_ card: CodexCard) -> Binding<String> {
        let key = questionViewStateKey(card.agent, 0)
        return Binding(get: {
            (questionDrafts[key] ?? QuestionTypedDrafts()).text(for: card.viewed, route: card.route, progress: card.progress)
        }, set: {
            questionDrafts[key] = (questionDrafts[key] ?? QuestionTypedDrafts()).editing(card.viewed, text: $0, route: card.route)
        })
    }

    private func questionPrompts(_ question: AgentQuestion) -> [QuestionPrompt] {
        if let legacy = model.codexQuestion(for: question), case let .daemon(request) = model.route(for: legacy) {
            return request.questions.map(\.displayPrompt)
        }
        if let legacy = model.codexQuestion(for: question), legacy.questionCount > question.prompts.count {
            let unread = QuestionPrompt(header: nil, question: nil, options: [])
            return question.prompts + Array(repeating: unread, count: legacy.questionCount - question.prompts.count)
        }
        return question.prompts
    }

    private func viewedQuestion(_ question: AgentQuestion, current: Int, count: Int) -> Int {
        min(max(viewedQuestions[questionViewStateKey(question, 0)] ?? model.previewViewedQuestion ?? current, 0), max(0, count - 1))
    }

    /// Steps the card to question `index`. An earlier step's unsubmitted text is discarded on the way
    /// out, so no step shows text that Send would not send (`QuestionTypedDrafts.leaving`).
    private func showQuestion(_ index: Int, of question: AgentQuestion) {
        let key = questionViewStateKey(question, 0)
        if let legacy = model.codexQuestion(for: question) {
            let card = codexCard(legacy)
            questionDrafts[key] = questionDrafts[key]?.leaving(card.viewed, current: card.current)
        }
        viewedQuestions[key] = index
    }

    /// What the user has chosen on a Claude call, by question; nothing until they select.
    private func claudeCall(_ question: AgentQuestion) -> ClaudeQuestionCallSelection {
        claudeSelections[questionViewStateKey(question, 0)] ?? ClaudeQuestionCallSelection(prompts: question.prompts)
    }

    /// The Claude card's viewed question: where Next last moved on to unless the user stepped elsewhere.
    private func claudeViewed(_ question: AgentQuestion) -> Int {
        viewedQuestion(question, current: claudeCall(question).current, count: question.prompts.count)
    }

    private func toggleClaudeSelection(_ question: AgentQuestion, question index: Int, option: Int) {
        claudeSelections[questionViewStateKey(question, 0)] = claudeCall(question).toggling(option, at: index)
    }

    /// The Claude field's text for question `index`; typing clears its selected options
    /// (`ClaudeQuestionSelection.typing`).
    private func claudeTypedText(_ question: AgentQuestion, question index: Int) -> Binding<String> {
        Binding(get: { claudeCall(question).selection(at: index).text },
                set: { claudeSelections[questionViewStateKey(question, 0)] = claudeCall(question).typing($0, at: index) })
    }

    /// The Claude card's answering button (#382, #388): Next shows the next question, keeping every
    /// selection; Send hands the whole set to the live helper's own checks (`answerClaudeQuestion`).
    /// Any question is answerable in any order, so Next never unlocks one. Nothing is sent before
    /// Send, and never a partial set.
    private func performClaude(_ primary: QuestionCardPrimary, _ question: AgentQuestion) {
        let key = questionViewStateKey(question, 0)
        let call = claudeCall(question)
        switch primary {
        case let .step(to): showQuestion(to, of: question)
        case .next:
            guard primary.enabled, !model.answering else { return }
            let next = call.advancing(from: claudeViewed(question))
            claudeSelections[key] = next
            viewedQuestions[key] = next.current
        case .send:
            guard primary.enabled, !model.answering, let answers = call.answers(prompts: question.prompts) else { return }
            let last = call.selection(at: question.prompts.count - 1)
            armKeyboardSend(.question(question.id), agent: question.identity.session.source, prompts: question.prompts,
                            lastPick: .init(typed: last.text, options: Array(last.options)))
            model.answerClaudeQuestion(question, answers: answers)
            claudeSelections[key] = nil
        }
    }

    private var sessionNames: [AgentSessionIdentity: String] {
        var names = model.claudeSessionNames
        for (session, name) in model.threadNames {
            names[CodexAttentionAdapter.session(session, surface: .desktop)] = name
            names[CodexAttentionAdapter.session(session, surface: .cli)] = name
        }
        return names
    }

    /// The strip's summary now. The subject, counts, colours and spoken label do not depend on quiet;
    /// the wing's sprites read `strip(at:)` on their own schedule.
    private var strip: AgentStripSummary { strip(at: Date().timeIntervalSince1970) }

    /// The strip's summary at `now`, which marks which working sessions are quiet (#419) and so which
    /// sprites stand still.
    private func strip(at now: Double) -> AgentStripSummary {
        AgentStripSummary.make(items: model.orderedAgentAttentionItems,
                               testPending: model.attention.pending && !model.desktopForeground,
                               names: sessionNames, now: now)
    }

    /// The strip's center label, when the profile shows one and the layout has room for it.
    private var centerLabel: String? {
        guard model.stripLayout.gap > 0 else { return nil }
        switch model.appearance.effectiveCenterLabel(on: model.activeProfile) {
        case .off: return nil
        case .taskName: return strip.sessions.isEmpty && strip.toCheck == 0 ? nil : strip.subject
        case .sessionName: return model.orderedAgentAttentionItems.first.map { sessionLabel($0.session) }
        }
    }

    private func sessionLabel(_ session: AgentSessionIdentity) -> String {
        AgentStripSummary.sessionLabel(session, names: sessionNames)
    }

    /// The color the strip gives this session, or its preferred color if it is not on the strip.
    private func spriteColor(for session: AgentSessionIdentity) -> Int {
        strip.sessions.first { $0.session == session }?.color ?? AgentStripSummary.preferredColor(for: session)
    }

    private func rowSubject(_ item: AgentAttentionItem) -> String {
        if let task = item.approval?.details?.taskName, !task.isEmpty { return "\(task), \(sessionLabel(item.session))" }
        return sessionLabel(item.session)
    }

    // MARK: Question card (#321)

    /// One Codex question card as it stands now, from the queue's current copy of the question.
    private struct CodexCard {
        let question: AttentionQuestion
        let agent: AgentQuestion
        let progress: QuestionAnswerProgress
        let route: QuestionAnswerRoute
        let prompts: [QuestionPrompt]
        let viewed: Int
        /// The route offers option controls at all (`Companion.showsOptionControls`).
        let controls: Bool
        var current: Int { progress.questionIndex }
        /// The daemon's request, when the card answers through it.
        var request: AppServerQuestionRequest? { route.daemonRequest }
        /// One typed digit per Send (ADR 0006, ADR 0017).
        var keyRoute: Bool { route.isKeyRoute }
    }

    private func codexCard(_ legacy: AttentionQuestion) -> CodexCard {
        let agent = CodexAttentionAdapter.question(from: legacy)
        let progress = model.progress(for: legacy)
        let prompts = questionPrompts(agent)
        return CodexCard(question: legacy, agent: agent, progress: progress, route: model.route(for: legacy),
                         prompts: prompts, viewed: viewedQuestion(agent, current: progress.questionIndex, count: prompts.count),
                         controls: model.showsOptionControls(for: legacy))
    }

    /// Whether the viewed question's options can be selected now (`QuestionCardOptions.selectable`).
    private func selectable(_ card: CodexCard) -> Bool {
        QuestionCardOptions.selectable(route: card.route, question: card.question, progress: card.progress,
                                       viewed: card.viewed, controls: card.controls)
    }

    private func optionCount(_ card: CodexCard) -> Int {
        QuestionCardOptions.options(route: card.route, question: card.question, at: card.viewed).count
    }

    /// The daemon field's text for the viewed question; empty when there is no field.
    private func typedText(_ card: CodexCard) -> String {
        guard card.request != nil else { return "" }
        return questionDraft(card).wrappedValue
    }

    /// A click on an option or its digit: selects it (D16). The typed field gives way to it.
    private func select(_ card: CodexCard, option: Int) {
        if card.request != nil { questionDraft(card).wrappedValue = "" }
        model.selectQuestionAnswer(card.question, question: card.viewed, answer: .option(option))
    }

    /// The card's Next or Send, or a step on while reviewing; nil where the route answers nothing here.
    private func primary(_ card: CodexCard) -> QuestionCardPrimary? {
        guard card.request != nil || (card.keyRoute && card.controls), !card.prompts.isEmpty else { return nil }
        let typed = !typedText(card).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return QuestionCardPrimary.make(daemon: card.request != nil, viewed: card.viewed, current: card.current,
                                        count: card.prompts.count,
                                        selected: typed || card.progress.selected[card.viewed] != nil,
                                        ready: card.progress.phase == .ready)
    }

    private func perform(_ primary: QuestionCardPrimary, _ card: CodexCard) {
        switch primary {
        case let .step(to): showQuestion(to, of: card.agent)
        case .next, .send:
            guard primary.enabled, !model.answering else { return }
            if case .send = primary {
                let option: [Int] = if case let .option(option) = card.progress.selection(for: card.viewed) { [option] } else { [] }
                armKeyboardSend(.question(card.agent.id), agent: .codex, prompts: card.prompts,
                                lastPick: .init(typed: typedText(card), options: option))
            }
            model.sendQuestionAnswer(card.question, question: card.viewed, typed: card.request != nil ? typedText(card) : nil)
        }
    }

    /// On the keyboard card only (#428): what its sent line will say if the route confirms the send.
    private func armKeyboardSend(_ id: AgentAttentionID, agent: AgentSource, prompts: [QuestionPrompt],
                                 lastPick: SpotlightSentAnswer.Pick) {
        guard model.keyboardCard?.id == id else { return }
        model.armKeyboardSend(SpotlightSentAnswer.make(agent: agent.displayName, prompts: prompts, lastPick: lastPick), for: id)
    }

    /// The card's Open as its button does it, or nil where the card shows no Open (#428: O, and
    /// Return once the card cannot be answered here). It reads the same decisions the buttons do
    /// (`claudeOpenOffered`, `codexFooterMode`, `codexOpenOffered`), so a key never opens what the
    /// card does not show.
    private func questionOpen(_ item: AgentAttentionItem) -> (() -> Void)? {
        guard !model.openingTask, questionOpenOffered(item), let question = item.question else { return nil }
        if item.session.source == .claude { return { model.openClaudeQuestion(question) } }
        return { model.openAgent(item.session) }
    }

    /// Whether the question card shows an Open: the decision its button, O, Return after hand-back,
    /// and the foot line's "⏎ open" all read.
    private func questionOpenOffered(_ item: AgentAttentionItem) -> Bool {
        guard let question = item.question else { return false }
        if item.session.source == .claude { return claudeOpenOffered(item.session) }
        let card = model.codexQuestion(for: question).map(codexCard)
        return codexOpenOffered(item) && codexFooterMode(card, item: item) != .setUpTerminal
    }

    /// The viewed question of a card and how many it has: where Next last moved on to unless the
    /// user stepped elsewhere.
    private func viewedQuestionIndex(_ question: AgentQuestion) -> (viewed: Int, count: Int) {
        let count = questionPrompts(question).count
        let current = model.codexQuestion(for: question).map { model.progress(for: $0).questionIndex }
            ?? (model.canAnswerAgentQuestion(question) ? claudeCall(question).current : 0)
        return (viewedQuestion(question, current: current, count: count), count)
    }

    /// A key the panel handed to the question card on screen (#321, #428), already mapped by
    /// `SpotlightCardKeys`. A select only selects; primary does what the card's answering button
    /// would, only while it is enabled; open, dismiss and step act exactly as Open, Dismiss and ‹ ›.
    private func handleQuestionCardKey(_ press: QuestionCardKeyPress?) {
        guard let press, press.card == model.presentationMode.singleCard,
              let item = model.orderedAgentAttentionItems.first(where: { $0.id == press.card }),
              let question = item.question else { return }
        let action = press.action
        switch action {
        case .none, .consume:
            return
        case .open:
            questionOpen(item)?()
            return
        case .dismiss:
            model.dismissAgent(item.id)
            return
        case let .step(by):
            let (viewed, count) = viewedQuestionIndex(question)
            guard count > 1 else { return }
            let next = min(max(viewed + by, 0), count - 1)
            if next != viewed { showQuestion(next, of: question) }
            return
        case .select, .primary:
            break
        }
        if question.identity.session.source == .claude {
            guard model.canAnswerAgentQuestion(question) else { return }
            let viewed = claudeViewed(question)
            if case let .select(number) = action { toggleClaudeSelection(question, question: viewed, option: number - 1) }
            else { performClaude(claudeCall(question).primary(viewed: viewed), question) }
            return
        }
        guard let legacy = model.codexQuestion(for: question) else { return }
        let card = codexCard(legacy)
        if case let .select(number) = action {
            guard selectable(card), number <= optionCount(card) else { return }
            select(card, option: number - 1)
        } else {
            guard let primary = primary(card), primary.enabled else { return }
            perform(primary, card)
        }
    }

    /// The question card's header line (6AD): sprite, name, dim "· repo @ branch", the "Answer" pill,
    /// the dim source ("CLI", "App", "Claude"), then the age, or, for a Claude question Herdly can
    /// answer, its "Ns left" pill in the age's place, as its queue row shows it (ADR 0020, #374;
    /// Paper "G · Claude: answer several questions", #382). Queue rows keep D17 and name neither.
    @ViewBuilder
    private func questionCardHeader(_ item: AgentAttentionItem) -> some View {
        if let question = item.question, question.identity.session.source == .claude,
           model.canAnswerAgentQuestion(question) {
            // Display only: the countdown reads the held deadline and never moves it.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                questionCardHeader(item, countdown: model.claudeQuestionCountdown(question,
                                                                                  now: context.date.timeIntervalSince1970))
            }
        } else {
            questionCardHeader(item, countdown: nil)
        }
    }

    private func questionCardHeader(_ item: AgentAttentionItem, countdown: ApprovalCountdown?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: Sprite.slotGap) {
                spriteSlot(working: false, color: spriteColor(for: item.session))
                Text(QueueRowPresentation.sessionName(item.session, names: sessionNames))
                    .font(QuestionCardStyle.font(12, .semibold)).foregroundStyle(NotchStyle.ink)
                    .lineLimit(1).truncationMode(.tail)
            }
            .layoutPriority(2)
            if let place = model.rowPlace(for: item) {
                Text("· \(place)").font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.rowDirectory(for: item) ?? place)
            } else {
                Spacer(minLength: 0)
            }
            Text("Answer").font(QuestionCardStyle.font(10, .semibold)).foregroundStyle(NotchStyle.ink)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(NotchStyle.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .fixedSize()
            Text(Self.questionSource(item.session)).font(QuestionCardStyle.font(10)).foregroundStyle(NotchStyle.dim)
                .lineLimit(1).fixedSize()
            if let countdown {
                SecondsLeftPill(countdown: countdown)
            } else {
                rowAge(item)
            }
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rowHeading(item, countdown: countdown, quiet: false)), \(item.session.sourceLabel)")
        .accessibilityAddTraits(.isHeader)
    }

    /// The question card header's source word (6AD): "CLI", "App" for the Codex app, or "Claude".
    static func questionSource(_ session: AgentSessionIdentity) -> String {
        session.source == .claude ? "Claude" : (session.surface == .cli ? "CLI" : "App")
    }

    /// One question card body for the spotlight and the clicked card, inset to the title: the steps,
    /// the viewed question, its options, the typed field on the daemon path, one status line, then
    /// Open on the left and Dismiss then Next or Send on the right (#382). A Codex question has no
    /// countdown; a Claude question Herdly can answer shows "Ns left" in its header
    /// (`questionCardHeader`; ADR 0020, #374, #382).
    @ViewBuilder
    private func questionCardBody(_ item: AgentAttentionItem, subject: String, herdr: HerdrOpenAvailability,
                                  codexOpen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let phase = model.keyboardCard?.id == item.id ? model.keyboardCard?.phase : nil
            if case let .sent(answer)? = phase {
                sentCardBody(answer, item: item, subject: subject)
            } else if case let .handedBack(askedAt)? = phase, let question = item.question {
                handedBackCardBody(question, item: item, subject: subject, askedAt: askedAt)
            } else if let question = item.question {
                if question.identity.session.source == .claude {
                    claudeQuestionCard(question, subject: subject)
                    claudeReturnMessage(item)
                    if herdr == .notInHerdr, !model.isBackgroundClaudeSession(item.session),
                       !model.canAnswerAgentQuestion(question) {
                        Text("The exact Claude tab cannot be opened until Herdly can verify it; continue in Claude.")
                            .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    claudeQuestionFooter(question, item: item, subject: subject)
                } else {
                    let card = model.codexQuestion(for: question).map(codexCard)
                    if let card {
                        codexQuestionCard(card, subject: subject)
                    } else if question.prompts.isEmpty {
                        Text("Codex asked a question Herdly could not read; answer it in Codex.")
                            .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
                    } else {
                        // Not in the queue Herdly answers from, so nothing here is pressable.
                        readOnlyQuestions(question.prompts, agent: "Codex", question: question, subject: subject,
                                          tone: spriteColor(for: question.identity.session))
                    }
                    if case let .unavailable(cause) = herdr {
                        herdrReasonLine(item, cause: cause)
                    } else if let reason = model.terminalOpenLine(item.session) {
                        terminalOpenLine(item, reason: reason)
                    }
                    codexQuestionFooter(card, item: item, subject: subject, codexOpen: codexOpen)
                }
            }
        }
        .padding(.leading, Sprite.slotWidth + Sprite.slotGap)
        .padding(.trailing, 6)
        .padding(.top, 2)
    }

    // MARK: Keyboard card (#428, Paper L "Spotlight question by keyboard")

    private func announceKeyboardCard(_ id: AgentAttentionID?) {
        guard let id, NSWorkspace.shared.isVoiceOverEnabled, let question = model.spotlightItem(id)?.question else { return }
        let prompts = questionPrompts(question)
        let viewed = viewedQuestionIndex(question).viewed
        guard prompts.indices.contains(viewed), let text = prompts[viewed].question else { return }
        announce(text)
    }

    /// Key labels show only on the card that has the keyboard (frame 2), never before it (frame 1),
    /// and not once its send is shown (frame 4). A clicked card with the keyboard shows them too
    /// (#438, Paper K "C · Answer keys").
    private func keyLabels(_ item: AgentAttentionItem) -> Bool {
        guard let keys = model.answerKeysCard, keys.id == item.id else { return false }
        if case .sent = keys.phase { return false }
        return true
    }

    /// The ring around the whole card is the keyboard spotlight card's alone (#428, Paper L frame 2);
    /// a clicked card with the keyboard shows only its key labels (Paper K frame C).
    private func keyboardRing(_ item: AgentAttentionItem) -> Bool {
        model.keyboardCard?.id == item.id && keyLabels(item)
    }

    /// Open takes O while the card can be answered here, and Return once it cannot.
    private func openShortcut(_ item: AgentAttentionItem) -> NotchShortcut {
        model.answerKeysCard?.phase == .answering ? NotchShortcut.open : NotchShortcut.returnKey
    }

    /// Frame 4: the send left Herdly. The question with its options dim and the sent ones filled, then
    /// one text-gray line; no controls. The panel folds a second later.
    @ViewBuilder
    private func sentCardBody(_ answer: SpotlightSentAnswer, item: AgentAttentionItem, subject: String) -> some View {
        if let text = answer.question { questionText(text) }
        optionList(answer.options, subject: subject, tone: spriteColor(for: item.session), selectedSet: answer.chosen,
                   enabled: false, select: nil)
        Text(answer.line).font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    /// Frame 7: the countdown ended while the card had the keyboard. The agent asks again itself and
    /// nothing was sent; options dim, and "Open in <agent>" is the only control and takes Return.
    @ViewBuilder
    private func handedBackCardBody(_ question: AgentQuestion, item: AgentAttentionItem, subject: String,
                                    askedAt: Double) -> some View {
        let prompts = questionPrompts(question)
        let viewed = viewedQuestionIndex(question).viewed
        if prompts.indices.contains(viewed) {
            if let text = prompts[viewed].question { questionText(text) }
            optionList(prompts[viewed].options, subject: subject, tone: spriteColor(for: item.session), selected: nil,
                       enabled: false, select: nil)
        }
        HStack(alignment: .center, spacing: 6) {
            // Steps with the clock like the other countdowns here, so "asked Ns ago" stays true.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(SpotlightCardLines.handedBack(askedAt: askedAt, now: context.date.timeIntervalSince1970))
                    .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            let agent = item.session.source.displayName
            if item.session.source == .claude {
                claudeReturnControl(item, subject: subject, emphasized: true, openTitle: "Open in \(agent)",
                                    openHint: "Claude asks this question itself now.", shortcut: NotchShortcut.returnKey)
            } else if let open = questionOpen(item) {
                NotchButton(title: "Open in \(agent)", emphasized: true, shortcut: NotchShortcut.returnKey, action: open)
                    .accessibilityLabel("Open Session: \(subject)")
                    .accessibilityHint(NotchShortcut.hint(nil, shortcut: NotchShortcut.returnKey))
            }
        }
        .padding(.top, 2)
    }

    /// The lines under a spotlight question card: the request waiting behind a keyboard card (frame
    /// 8), then the foot line naming the keys (frames 1, 2, 5, 7) or the fold (frame 4).
    @ViewBuilder
    private var spotlightQuestionFoot: some View {
        if case let .agentSpotlight(id) = model.presentationMode,
           let item = model.spotlightItem(id), let question = item.question {
            let keyboard = model.keyboardCard?.id == id ? model.keyboardCard : nil
            let (viewed, count) = viewedQuestionIndex(question)
            let card: SpotlightCardFocus = keyboard.map { .keyboard($0.phase) }
                ?? .withoutKeyboard(answerable: model.canAnswerAgentQuestion(question))
            let waiting = keyboard == nil ? nil : model.keyboardWaiting.flatMap { waitingID in
                model.orderedAgentAttentionItems.first { $0.id == waitingID }
            }
            let foot = SpotlightCardFoot.make(card: card, questionCount: count, viewedIsLast: viewed >= count - 1,
                                              returnApp: model.keyboardReturnApp, hotkey: model.cardHotkey,
                                              openOffered: questionOpenOffered(item))
            if waiting != nil || foot != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let waiting {
                        let line = SpotlightKeyboardWait.line(waiting, name: QueueRowPresentation.sessionName(waiting.session,
                                                                                                         names: sessionNames))
                        HStack(alignment: .firstTextBaseline, spacing: Sprite.slotGap) {
                            spriteSlot(working: false, color: spriteColor(for: waiting.session))
                            Text(line).font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(line)
                    }
                    if let foot {
                        Text(foot.text).font(QuestionCardStyle.font(10)).foregroundStyle(NotchStyle.dim)
                            .lineLimit(1).truncationMode(.tail)
                            .accessibilityLabel(foot.spoken)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func statusLine(_ text: String, tone: Color = NotchStyle.dim) -> some View {
        Text(text).font(QuestionCardStyle.font(11)).foregroundStyle(tone).fixedSize(horizontal: false, vertical: true)
    }

    /// The viewed question's option wells. `select` nil draws them for reading only.
    private func optionList(_ options: [String], subject: String, tone: Int, selected: Int? = nil,
                            selectedSet: Set<Int> = [], enabled: Bool,
                            readOnly: Bool = false, select: ((Int) -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { offset, label in
                OptionButton(number: offset + 1, label: label, tone: NotchStyle.spriteColor(tone),
                             selected: selected == offset || selectedSet.contains(offset), readOnly: readOnly) { select?(offset) }
                    .disabled(!enabled || select == nil)
                    .accessibilityLabel("Option \(offset + 1): \(label), for \(subject)")
                    .accessibilityHint(readOnly || select == nil || !enabled ? "Reference only."
                                       : "Selects this answer. Nothing is sent until Send.")
            }
        }
    }

    @ViewBuilder
    private func codexQuestionCard(_ card: CodexCard, subject: String) -> some View {
        let tone = spriteColor(for: card.agent.identity.session)
        let canSelect = selectable(card)
        if let request = card.request {
            questionHead(card.prompts, question: card.agent, current: card.current, viewed: card.viewed,
                         answer: card.progress.answer(for:))
            let prompt = request.questions[min(card.viewed, request.questions.count - 1)]
            let shown = prompt.displayPrompt
            if let text = shown.question { questionText(text) }
            if prompt.isSecret {
                statusLine(QuestionCardLines.secret)
            } else {
                let typed = questionDraft(card)
                let typing = !typed.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let chosen: Int? = { if !typing, case let .option(option) = card.progress.selection(for: card.viewed) { return option }; return nil }()
                optionList(shown.options, subject: subject, tone: tone, selected: chosen, enabled: canSelect) { select(card, option: $0) }
                if prompt.takesText {
                    let committed: String? = { if case let .text(text) = card.progress.answer(for: card.viewed) { return text }; return nil }()
                    QuestionTypedField(text: typed, fieldLabel: "Typed answer for \(subject)", committedText: committed,
                                       onEscape: model.escape) {
                        if card.viewed < card.current {
                            model.selectQuestionAnswer(card.question, question: card.viewed, answer: .text(typed.wrappedValue))
                        } else if let primary = primary(card) {
                            perform(primary, card)
                        }
                    }
                    .disabled(!canSelect)
                }
                if shown.truncated { statusLine("Shortened; the full question is in Codex.") }
            }
            if let status = daemonStatus(card.progress) { statusLine(status) }
        } else if card.prompts.isEmpty {
            statusLine("Codex asked a question Herdly could not read; answer it in Codex.", tone: NotchStyle.text)
        } else {
            questionHead(card.prompts, question: card.agent, current: card.current, viewed: card.viewed,
                         sentKeys: card.keyRoute, answer: card.progress.answer(for:))
            let prompt = card.prompts[card.viewed]
            if let text = prompt.question { questionText(text) }
            else { statusLine("Herdly could not read this question; continue in Codex.") }
            if card.route == .desktopReadOnly {
                if !prompt.isSecret {
                    optionList(prompt.options, subject: subject, tone: tone, selected: nil, enabled: false, readOnly: true, select: nil)
                }
            } else if !prompt.isSecret {
                let chosen: Int? = { if case let .option(option) = card.progress.selection(for: card.viewed) { return option }; return nil }()
                optionList(prompt.options, subject: subject, tone: tone, selected: chosen, enabled: canSelect,
                           select: canSelect ? { select(card, option: $0) } : nil)
                if card.keyRoute, card.controls, card.viewed == card.current, card.progress.phase == .ready,
                   case .options = QuestionAnswerProgress.offer(card.question, at: card.viewed) {
                    statusLine(QuestionCardLines.otherAnswersInCodex)
                }
            }
            if prompt.truncated { statusLine("Shortened; the full question is in Codex.") }
            if card.route == .desktopReadOnly {
                statusLine(prompt.isSecret ? QuestionCardLines.secret : QuestionCardLines.desktopReadOnly, tone: NotchStyle.text)
            } else if card.route == .daemonAnswered {
                if let status = daemonStatus(card.progress) { statusLine(status) }
            } else if let status = questionStatus(card) {
                statusLine(status)
            }
        }
    }

    /// What a Codex card's bottom row offers besides Dismiss.
    private enum CodexFooterMode {
        /// The Codex app without the daemon: "Open in Codex" only.
        case desktopReadOnly
        /// A CLI session with every terminal host off: "Set up a Terminal" only.
        case setUpTerminal
        /// Open, and the card's Next or Send where its route answers.
        case answer
    }

    /// The Codex card's bottom row (#382): Open alone on the left; Dismiss, then Next or Send (or a step
    /// on), on the right. The Codex app without the daemon offers only "Open in Codex" (left,
    /// emphasized) and Dismiss.
    private func codexFooterMode(_ card: CodexCard?, item: AgentAttentionItem) -> CodexFooterMode {
        card?.route == .desktopReadOnly ? .desktopReadOnly
            : (item.session.surface == .cli && !model.cliTerminalHostOn ? .setUpTerminal : .answer)
    }

    /// A Codex card offers Open unless herdr or the latest terminal scan rules it out (#267).
    private func codexOpenOffered(_ item: AgentAttentionItem) -> Bool {
        herdrOpen(item.session).offersOpen && model.offersTerminalOpen(item.session)
    }

    /// A Claude card's Open is shown: herdr can reach the session, or Herdly can open it in its terminal
    /// and the terminal scan has not replaced Open with its line (#267).
    private func claudeOpenOffered(_ session: AgentSessionIdentity) -> Bool {
        let herdr = herdrOpen(session)
        return herdr == .available
            || (herdr == .notInHerdr && model.canOpenClaude(session) && model.offersTerminalOpen(session))
    }

    private func codexQuestionFooter(_ card: CodexCard?, item: AgentAttentionItem, subject: String, codexOpen: Bool) -> some View {
        let mode = codexFooterMode(card, item: item)
        let keys = keyLabels(item)
        return HStack(spacing: 6) {
            switch mode {
            case .desktopReadOnly:
                if codexOpen {
                    let key = keys ? NotchShortcut.returnKey : nil
                    NotchButton(title: "Open in Codex", emphasized: true, shortcut: key) { model.openAgent(item.session) }
                        .disabled(model.openingTask)
                        .accessibilityLabel("Open Session: \(subject)")
                        .accessibilityHint(NotchShortcut.hint("Answer the question in the Codex app.", shortcut: key))
                }
                Spacer(minLength: 6)
            case .setUpTerminal:
                NotchButton(title: "Set up a Terminal", emphasized: true, action: model.showControls)
                    .accessibilityLabel("Set up a terminal: \(subject)")
                    .accessibilityHint("Opens Herdly controls to switch on a terminal.")
                Spacer(minLength: 6)
            case .answer:
                if codexOpen {
                    let key = keys ? openShortcut(item) : nil
                    NotchButton(title: "Open", shortcut: key) { model.openAgent(item.session) }
                        .disabled(model.openingTask)
                        .accessibilityLabel("Open Session: \(subject)")
                        .accessibilityHint(NotchShortcut.hint("Answer the question in Codex's own panel.", shortcut: key))
                }
                Spacer(minLength: 6)
            }
            // Dismiss only clears the card; nothing is sent, so the agent's own question stays authoritative.
            let dismissKey = keys ? NotchShortcut.dismiss : nil
            NotchButton(title: "Dismiss", shortcut: dismissKey) { model.dismissAgent(item.id) }
                .accessibilityLabel("Dismiss question: \(subject)")
                .accessibilityHint(NotchShortcut.hint(nil, shortcut: dismissKey))
            // The answering button is always the far-right one (#382).
            if mode == .answer, let card, let primary = primary(card) {
                primaryButton(primary, card: card, subject: subject,
                              shortcut: keys && model.answerKeysCard?.phase == .answering ? NotchShortcut.returnKey : nil)
            }
        }
        .padding(.top, 2)
    }

    private func primaryButton(_ primary: QuestionCardPrimary, card: CodexCard, subject: String,
                               shortcut: NotchShortcut? = nil) -> some View {
        primaryButton(primary, prompts: card.prompts, subject: subject, shortcut: shortcut,
                      sendHint: card.keyRoute ? "Types this option's digit into the session for this question only."
                                              : "Sends every answer on this card to Codex once.") {
            perform(primary, card)
        }
        .disabled(model.answering)
    }

    /// A question card's answering button: Next, Send, or a step on while reviewing.
    private func primaryButton(_ primary: QuestionCardPrimary, prompts: [QuestionPrompt], subject: String,
                               shortcut: NotchShortcut? = nil, sendHint: String, action: @escaping () -> Void) -> some View {
        let title: String
        let label: String
        let hint: String
        switch primary {
        case .next:
            title = "Next ›"
            label = "Next: keep this answer for \(subject)"
            hint = "Keeps the answer here and shows the next question. Nothing is sent until Send."
        case .send:
            title = "Send"
            label = "Send answer to \(subject)"
            hint = sendHint
        case let .step(to):
            let next = QuestionSteps.label(prompts[to], index: to)
            title = "\(next) ›"
            label = "Next question: \(next)"
            hint = "Shows the next question. Changes nothing."
        }
        return NotchButton(title: title, emphasized: true, shortcut: shortcut, action: action)
            .disabled(!primary.enabled)
            .accessibilityLabel(label)
            .accessibilityHint(NotchShortcut.hint(hint, shortcut: shortcut))
    }

    /// Unsupported routes can browse the questions, but never acquire answer controls.
    @ViewBuilder
    private func readOnlyQuestions(_ prompts: [QuestionPrompt], agent: String, question: AgentQuestion, subject: String,
                                   tone: Int) -> some View {
        Text(QuestionSteps.answerElsewhere(count: prompts.count, agent: agent))
            .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
        let viewed = viewedQuestion(question, current: 0, count: prompts.count)
        questionHead(prompts, question: question, current: 0, viewed: viewed) { _ in nil }
        if prompts.indices.contains(viewed) {
            prompt(prompts[viewed], subject: subject, tone: tone, agent: agent)
        }
    }

    /// A Claude card: the call answered through the live helper on the same step-through card as a
    /// Codex daemon call (#382): select (ticks for multi-select) or type on any question, in any order
    /// (#388); Next moves on, Send on the last question sends the whole set once every question has an
    /// answer. Otherwise read-only references.
    @ViewBuilder
    private func claudeQuestionCard(_ question: AgentQuestion, subject: String) -> some View {
        let tone = spriteColor(for: question.identity.session)
        if question.prompts.isEmpty {
            statusLine("Claude asked a question Herdly could not read; answer it in Claude.", tone: NotchStyle.text)
        } else if !model.canAnswerAgentQuestion(question) {
            readOnlyQuestions(question.prompts, agent: "Claude", question: question, subject: subject, tone: tone)
        } else {
            let call = claudeCall(question)
            let viewed = claudeViewed(question)
            let prompt = question.prompts[viewed]
            let canSelect = call.canSelect(question: viewed)
            questionHead(question.prompts, question: question, current: call.current, viewed: viewed,
                         answeredWhenHeld: true) { index in
                call.railAnswer(at: index, labels: question.prompts[index].options)
            }
            if let text = prompt.question { questionText(text) }
            let selection = call.selection(at: viewed)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(prompt.options.enumerated()), id: \.offset) { option, label in
                    let ticked = selection.options.contains(option)
                    OptionButton(number: option + 1, label: label, tone: NotchStyle.spriteColor(tone), selected: ticked,
                                 checked: prompt.multiSelect ? ticked : nil) {
                        toggleClaudeSelection(question, question: viewed, option: option)
                    }
                    .disabled(!canSelect)
                    .accessibilityLabel("\(prompt.multiSelect ? "Tick" : "Select") \(option + 1): \(label), for \(subject)")
                    .accessibilityHint("Nothing is sent until Send.")
                }
            }
            QuestionTypedField(placeholder: prompt.options.isEmpty ? "Type your answer" : "Or type an answer",
                               text: claudeTypedText(question, question: viewed), fieldLabel: "Typed answer for \(subject)",
                               onEscape: model.escape) {
                performClaude(call.primary(viewed: viewed), question)
            }
            .disabled(!canSelect)
            if prompt.truncated { statusLine("Shortened; the full question is in Claude.") }
        }
    }

    /// The Claude card's bottom row (#382): Open alone on the left; Dismiss, then Next or Send (or a
    /// step on), on the right.
    private func claudeQuestionFooter(_ question: AgentQuestion, item: AgentAttentionItem, subject: String) -> some View {
        let keys = keyLabels(item)
        return HStack(spacing: 6) {
            claudeReturnControl(item, subject: subject, openTitle: "Open",
                                openHint: model.canAnswerAgentQuestion(question)
                                    ? "Hands this question back to Claude's own prompt." : nil,
                                shortcut: keys ? openShortcut(item) : nil)
            Spacer(minLength: 6)
            let dismissKey = keys ? NotchShortcut.dismiss : nil
            NotchButton(title: "Dismiss", shortcut: dismissKey) { model.dismissAgent(item.id) }
                .accessibilityLabel("Dismiss question: \(subject)")
                .accessibilityHint(NotchShortcut.hint(nil, shortcut: dismissKey))
            if model.canAnswerAgentQuestion(question) {
                let primary = claudeCall(question).primary(viewed: claudeViewed(question))
                primaryButton(primary, prompts: question.prompts, subject: subject,
                              shortcut: keys ? NotchShortcut.returnKey : nil,
                              sendHint: question.prompts.count > 1
                                  ? "Sends every answer on this card to Claude once."
                                  : "Sends the selected option, the ticked options, or the typed answer to Claude once.") {
                    performClaude(primary, question)
                }
                .disabled(model.answering)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func questionHead(_ prompts: [QuestionPrompt], question: AgentQuestion, current: Int, viewed: Int,
                              sentKeys: Bool = false, answeredWhenHeld: Bool = false,
                              answer: (Int) -> ChosenAnswer?) -> some View {
        if prompts.count > 1 {
            let steps = QuestionSteps.make(prompts, current: current, viewed: viewed, currentStatus: nil,
                                           sentKeys: sentKeys, answeredWhenHeld: answeredWhenHeld, answer: answer)
            QuestionStepRail(steps: steps.steps) { showQuestion($0, of: question) }
        } else if let only = prompts.first, only.header?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            Text(QuestionSteps.label(only, index: 0)).font(QuestionCardStyle.font(10)).foregroundStyle(NotchStyle.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func questionText(_ text: String) -> some View {
        ResultMarkdown(text: text, style: .question)
    }

    private var showsTestRow: Bool {
        model.attention.pending && !model.desktopForeground && model.presentationMode.showsAll
    }

    /// A spotlit or clicked card renders the single-item spotlight body.
    private func isSpotlight(_ item: AgentAttentionItem) -> Bool {
        model.presentationMode.singleCard == item.id
    }

    /// An approval or question row in the full queue opens as its own card when clicked (D5, D18).
    private func opensAsCard(_ item: AgentAttentionItem) -> Bool {
        model.presentationMode.showsAll && item.id.isRequest
    }

    /// Makes a row header the click target that opens its card, keeping its look. VoiceOver reads it
    /// as a button naming the action.
    @ViewBuilder
    private func cardOpener<Header: View>(_ item: AgentAttentionItem, countdown: ApprovalCountdown? = nil,
                                          @ViewBuilder header: () -> Header) -> some View {
        if opensAsCard(item) {
            Button { model.openCard(item.id) } label: { header().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel("Open card: \(rowHeading(item, countdown: countdown, quiet: false))")
                .accessibilityHint("Shows this request alone. Escape or Queue returns to the queue.")
        } else {
            header()
        }
    }

    /// Makes a working row's header line the click target that opens or closes it in place (#319).
    /// Like `cardOpener` it is left out of Tab order; the arrow selection and Return reach it.
    private func runningOpener<Header: View>(_ item: AgentAttentionItem, open: Bool, quiet: Bool,
                                             @ViewBuilder header: () -> Header) -> some View {
        Button { model.toggleRunningRow(item.id) } label: { header().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("Open details: \(rowHeading(item, quiet: quiet))")
            .accessibilityValue(open ? "expanded" : "collapsed")
            .accessibilityHint(open ? "Hides this session's details. Escape also closes them."
                                    : "Shows what the session is doing, your last prompt, where it runs, and Open.")
    }

    /// Makes a result row's header line the click target that opens its session (#322, D20), through
    /// the same Open the cards use, which revalidates the exact target. Like `cardOpener` it is left
    /// out of Tab order; the arrow selection and Return reach it. A click while another Open runs is
    /// ignored (`Companion.activateRow`) rather than drawn disabled, so the row never dims. An
    /// unreachable row is not a button: it reads its heading, "Unreachable", and then its reason line.
    @ViewBuilder
    private func sessionOpener<Header: View>(_ item: AgentAttentionItem, target: ResultRowTarget,
                                             @ViewBuilder header: () -> Header) -> some View {
        if target == .reachable {
            sessionOpenButton(item, header: header)
        } else {
            header()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(rowHeading(item, quiet: false)), \(RowException.unreachable.word)")
        }
    }

    /// The result card's header line (#323, 8DW "New ones"): the same click as a result row while the
    /// session is reachable; otherwise its plain heading, since the card's body says why Open is not
    /// offered.
    @ViewBuilder
    private func resultCardHeaderOpener<Header: View>(_ item: AgentAttentionItem, target: ResultRowTarget,
                                                      @ViewBuilder header: () -> Header) -> some View {
        if target == .reachable { sessionOpenButton(item, header: header) } else { header() }
    }

    private func sessionOpenButton<Header: View>(_ item: AgentAttentionItem, @ViewBuilder header: () -> Header) -> some View {
        Button { model.activateRow(item.id) } label: { header().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("Open Session: \(rowHeading(item, quiet: false))")
            .accessibilityHint(Self.resultOpenHint(item.session.source))
    }

    /// A result row's one control, a quiet × in the fixed lane after the age (D34, #347): Dismiss on a
    /// result, which clears only that turn; Remove on a waiting or status-unknown Claude row once it
    /// looks stuck. A row with neither keeps the lane empty, so the ages line up. It is its own button
    /// in Tab order, a sibling of the row's button, never inside it.
    @ViewBuilder
    private func resultRowControl(_ item: AgentAttentionItem, subject: String) -> some View {
        ZStack {
            // Holds the lane open on a row with no control, so the ages line up.
            Color.clear.accessibilityHidden(true)
            if item.outcome != nil {
                RowDismissButton { model.dismissAgent(item.id) }
                    .accessibilityLabel("Dismiss completion: \(subject)")
            } else {
                claudeRemoveControl(item, subject: subject, quiet: true)
            }
        }
        .frame(width: RowDismissButton.lane, height: RowDismissButton.lane)
    }

    /// A result's Open (#323): beside a result row's "Not delivered · reply in …" note, where the user
    /// replies in the agent, and on the result card. Codex's only when Open is offered and the result's
    /// reading (`target`, the one its click and reason line read) is reachable; Claude's return control,
    /// whose Open follows the same reading.
    @ViewBuilder
    private func resultOpen(_ item: AgentAttentionItem, subject: String, codexOpen: Bool,
                            target: ResultRowTarget, shortcut: NotchShortcut? = nil) -> some View {
        if let open = resultOpenAction(item, codexOpen: codexOpen, target: target) {
            NotchButton(title: Self.rowOpenTitle, shortcut: shortcut, action: open)
                .disabled(model.openingTask)
                .accessibilityLabel("Open Session: \(subject)")
                .accessibilityHint(NotchShortcut.hint(Self.resultOpenHint(item.session.source), shortcut: shortcut))
        } else {
            // No Open: a Claude result that cannot be opened may offer "Set up a Terminal" instead.
            claudeReturnControl(item, subject: subject, openTitle: Self.rowOpenTitle,
                                openHint: Self.resultOpenHint(item.session.source))
        }
    }

    /// A result's Open, or nil where it shows none: the one decision its button and the walk's O key
    /// (#440) both read, so a key never opens what the card does not show. Codex's while Open is
    /// offered and the result's reading is reachable; Claude's by `claudeReturnControl`'s own rule.
    /// Opening acknowledges nothing.
    private func resultOpenAction(_ item: AgentAttentionItem, codexOpen: Bool, target: ResultRowTarget) -> (() -> Void)? {
        let session = item.session
        if session.source == .codex {
            return codexOpen && target == .reachable ? { model.openAgent(session) } : nil
        }
        let herdr = herdrOpen(session)
        guard herdr == .available || (herdr == .notInHerdr && model.canOpenClaude(session)),
              claudeOpenOffered(session) else { return nil }
        return { model.openAgent(session) }
    }

    /// O or X the panel handed to the walk's result card (#440), already mapped by `ResultCardKeys`:
    /// exactly as clicking Open or Dismiss. Dismiss clears this one result, and the walk moves on
    /// once it has left.
    private func handleResultCardKey(_ press: ResultCardKeyPress?) {
        guard let press, press.card == model.presentationMode.singleCard,
              let item = model.orderedAgentAttentionItems.first(where: { $0.id == press.card }), item.outcome != nil
        else { return }
        switch press.action {
        case .open:
            guard !model.openingTask else { return }
            resultOpenAction(item, codexOpen: codexOpenOffered(item), target: model.resultRowReading(item.session).target)?()
        case .dismiss: model.dismissAgent(item.id)
        case .none: break
        }
    }

    /// The line under a result row's name (`ResultRowReading.line`): why Open is not offered, or
    /// why the last click did not open, in the cards' own copy (product.md, "Open unavailable").
    /// Every unreachable row has one.
    @ViewBuilder
    private func resultRowLine(_ item: AgentAttentionItem, reading: ResultRowReading) -> some View {
        switch reading.line {
        case let .herdr(cause)?:
            herdrReasonLine(item, cause: cause)
        case let .terminal(reason)?:
            terminalOpenLine(item, reason: reason, replacesOpen: reading.target == .unreachable)
        case let .claudeLastSeen(reason)?:
            terminalOpenLine(item, reason: reason, replacesOpen: true)
        case .claudeNotVerified?:
            claudeNotVerifiedLine
        case nil:
            EmptyView()
        }
    }

    /// The opened running row's details (#319, F3): "now", "you" and "where" (`RunningRowDetails`),
    /// any line saying why Open is not offered, then the prompt's disclosure and Open. Inset to the
    /// title; Open still revalidates its target through the session's usual route.
    @ViewBuilder
    private func runningDetails(_ item: AgentAttentionItem, subject: String, herdr: HerdrOpenAvailability,
                                codexOpen: Bool) -> some View {
        if let running = item.running {
            // The prompt's disclosure below reads only `you`, which does not depend on the time.
            let you = RunningRowDetails.you(running)
            let promptKey = "prompt:\(item.session.session)"
            let agent = item.session.source.displayName
            // #397: with running subagents, a switcher above the lines picks whose they are. Every
            // open starts on the session; a subagent that finishes hands them back at once.
            let shownSubagent = model.openRunningRow.shownSubagent(in: item)
            VStack(alignment: .leading, spacing: 6) {
                if !running.subagents.isEmpty {
                    SubagentSwitcher(subagents: running.subagents,
                                     selected: shownSubagent.map { .subagent($0.id) } ?? .session,
                                     sprite: model.appearance.sprite, color: spriteColor(for: item.session),
                                     reduceMotion: model.reduceMotion, focus: $switcherFocus) { choice in
                        model.showInOpenRunningRow(choice, row: item.id)
                    }
                    .padding(.bottom, 4)
                }
                if let subagent = shownSubagent {
                    subagentLines(subagent, item: item, subject: subject)
                } else {
                    // #419: the lines redraw when the row turns quiet, then every 30 s while it stays
                    // quiet so the "quiet" line's minutes keep up; nothing ticks before then.
                    // "now" is read at the same moment, so a quiet row's unfinished command and its
                    // "since this command started" appear together, at the quiet moment itself.
                    TimelineView(QuietSchedule(changes: [item.quietAt].compactMap { $0 }, every: 30)) { context in
                        let time = QuietSchedule.now(context.date)
                        let details = RunningRowDetails.make(running, host: model.lastSeenHost(for: item.session), now: time)
                        VStack(alignment: .leading, spacing: 6) {
                            if let now = details.now {
                                runningLine("now", now.text, tone: now.isUnknown ? NotchStyle.dim : NotchStyle.ink)
                                if let full = now.full, let title = now.disclosureTitle {
                                    // D11: a shortened command stays marked and its full text is one click away.
                                    NotchDisclosure(title: title, subject: subject, expanded: disclosure("action:\(item.session.session)")) {
                                        fullText(full)
                                    }
                                    .padding(.leading, Self.runningLabelWidth + Self.runningLabelGap)
                                }
                            }
                            if let you = details.you { runningLine("you", you.text, tone: NotchStyle.text) }
                            if let quiet = QuietLine.make(running, now: time) {
                                runningLine("quiet", quiet.text, tone: NotchStyle.text, spoken: "quiet, \(quiet.spoken)")
                            }
                            runningLine("where", details.place, tone: NotchStyle.text)
                        }
                    }
                }
                if item.session.source == .codex, case let .unavailable(cause) = herdr {
                    herdrReasonLine(item, cause: cause)
                } else if item.session.source == .codex, let reason = model.terminalOpenLine(item.session) {
                    terminalOpenLine(item, reason: reason)
                }
                if item.session.source == .claude { claudeReturnMessage(item) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if shownSubagent == nil, let you, let title = you.disclosureTitle {
                        // The toggle only; what it reveals goes below the whole line, not beside Open.
                        NotchDisclosure(title: title, expandedTitle: "Show less", subject: subject,
                                        expanded: disclosure(promptKey)) { EmptyView() }
                    }
                    Spacer(minLength: 6)
                    if item.session.source == .codex, codexOpen {
                        NotchButton(title: Self.rowOpenTitle, emphasized: true, focus: $runningOpenFocused) {
                            model.openAgent(item.session)
                        }
                        .disabled(model.openingTask)
                        .accessibilityLabel("Open Session: \(subject)")
                        .accessibilityHint("Open this session in Codex.")
                    }
                    claudeReturnControl(item, subject: subject, emphasized: true, openTitle: Self.rowOpenTitle,
                                        openFocus: $runningOpenFocused)
                    claudeRemoveControl(item, subject: subject)
                }
                .padding(.top, 4)
                if shownSubagent == nil, let you, you.disclosureTitle != nil, openDisclosures.contains(promptKey) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let full = you.full { fullText(full) }
                        if you.keptOnlyStart {
                            // Herdly kept only the start; the disclosure must not call it full.
                            Text("Shortened; the full prompt is in \(agent).")
                                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.runningLabelWidth + Self.runningLabelGap)
                }
            }
            .padding(.leading, Sprite.slotWidth + Sprite.slotGap)
            // With the row's 3pt spacing below the header line, 4pt above the first detail line.
            .padding(.top, 1)
            .padding(.bottom, 8)
            // #397: keyboard focus stays in the row when a focused well's subagent finishes: to
            // "Session" while wells remain, to Open once the last one leaves with the switcher. Watched
            // here, outside the switcher, which is gone by then.
            .onChange(of: switcherFocus) { _, now in
                lastSwitcherFocus = OpenRunningRow.rememberedFocus(previous: lastSwitcherFocus, now: now,
                                                                   running: running.subagents.map(\.id))
            }
            .onChange(of: running.subagents.map(\.id)) { _, ids in
                switch OpenRunningRow.focusAfterSubagentsChange(lastFocused: lastSwitcherFocus, running: ids) {
                case .well(let well)?: switcherFocus = well; lastSwitcherFocus = well
                case .open?: runningOpenFocused = true; lastSwitcherFocus = nil
                case nil: break
                }
            }
        }
    }

    /// A running subagent's lines in the opened row (#397, `SubagentDetails`): "now", its latest action
    /// ("Unknown" in dim while none is known); "asked" and "role" when the source reports them; and
    /// "for", how long it has run. Open below still opens the session.
    @ViewBuilder
    private func subagentLines(_ subagent: SubagentActivity, item: AgentAttentionItem, subject: String) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let details = SubagentDetails.make(subagent, now: context.date.timeIntervalSince1970)
            let key = "subagent:\(item.session.session):\(subagent.id)"
            VStack(alignment: .leading, spacing: 6) {
                runningLine("now", details.now.text, tone: details.now.isUnknown ? NotchStyle.dim : NotchStyle.ink)
                if let full = details.now.full, let title = details.now.disclosureTitle {
                    NotchDisclosure(title: title, subject: subject, expanded: disclosure("action:" + key)) { fullText(full) }
                        .padding(.leading, Self.runningLabelWidth + Self.runningLabelGap)
                }
                if let asked = details.asked {
                    runningLine("asked", asked.text, tone: NotchStyle.text)
                    if let full = asked.full, let title = asked.disclosureTitle {
                        NotchDisclosure(title: title, subject: subject, expanded: disclosure("asked:" + key)) { fullText(full) }
                            .padding(.leading, Self.runningLabelWidth + Self.runningLabelGap)
                    }
                }
                if let role = details.role { runningLine("role", role, tone: NotchStyle.text) }
                runningLine("for", details.age, tone: NotchStyle.text)
            }
        }
    }

    private static let runningLabelWidth: CGFloat = 40
    /// The plain "Open" a queue row offers on its own line: an opened running row (#319) and an
    /// approval row's "Not delivered" note (#320). Cards name theirs from `ApprovalCardReading`.
    private static let rowOpenTitle = "Open"
    private static let runningLabelGap: CGFloat = 10

    /// One labelled detail line: an 11pt dim label in a 40pt column, then the 11pt mono value at a
    /// 16pt line height. Read by VoiceOver as one element, label first.
    /// `spoken` replaces what VoiceOver reads for the line, label included.
    private func runningLine(_ label: String, _ value: String, tone: Color, spoken: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.runningLabelGap) {
            Text(label).foregroundStyle(NotchStyle.dim).frame(width: Self.runningLabelWidth, alignment: .leading)
            Text(value).foregroundStyle(tone).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(NotchStyle.mono(11))
        .accessibilityElement(children: .combine)
        .modifier(SpokenLabel(text: spoken))
    }

    private func fullText(_ text: String) -> some View {
        Text(text).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// D10/D21: the row's note after the user acted, in place of its dim "project @ branch" until
    /// its request clears.
    private func rowNote(_ item: AgentAttentionItem) -> RowNote? {
        model.presentationMode.showsAll ? model.rowNote(for: item.id) : nil
    }

    /// The keyboard hint at the foot of the queue the notch hotkey opened (#427, Paper K "A · Hotkey"):
    /// 10pt dim, 12pt apart, inset to the row edge. A clicked queue has none.
    private func keyboardFoot(hotkey: String) -> some View {
        HStack(spacing: 12) {
            ForEach(["↑↓ select", "⏎ open", "esc close", "\(hotkey) hide"], id: \.self) { part in
                Text(part).font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.dim)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keys: up and down arrows select, Return opens, Escape closes, \(hotkey) gives the keyboard back.")
    }

    /// The "‹ Queue" bar above a clicked card: back to the queue, nothing dismissed. No stepper to
    /// other items (D19); a question card with several questions steps through this request's own.
    private var clickedCardBar: some View {
        HStack(spacing: 6) {
            NotchButton(title: "‹ Queue", action: model.backToQueue)
                .accessibilityLabel("Back to queue")
                .accessibilityHint("Returns to the full queue. Nothing is dismissed.")
            Spacer(minLength: 0)
            if let id = model.presentationMode.clickedCard,
               let question = model.orderedAgentAttentionItems.first(where: { $0.id == id })?.question {
                questionStepper(question)
            }
        }
    }

    // MARK: The to-check walk (#440, Paper K "D · Walk the to-check list")

    /// The walk's header above its card: the ‹ › wells around "3 of 4 to check" (the index in ink,
    /// the rest in text gray), then one dashed mark per item on the right, the passed ones dim, the current
    /// one ink, the ones still ahead in the well's gray. The wells move by item; ← → also step a
    /// card's own questions first. Moving shows another card and clears nothing.
    private func walkHeader(_ position: ToCheckWalk.Position) -> some View {
        HStack(spacing: 8) {
            WalkStepWell(symbol: "‹", enabled: position.index > 1) { model.stepWalk(.previous) }
                .accessibilityLabel("Previous item")
            (Text(verbatim: "\(position.index)").foregroundStyle(NotchStyle.ink).fontWeight(.semibold)
                + Text(verbatim: " of \(position.count) to check").foregroundStyle(NotchStyle.text))
                .font(NotchStyle.mono(10)).monospacedDigit().lineLimit(1).fixedSize()
                .accessibilityLabel(position.spoken)
            WalkStepWell(symbol: "›", enabled: position.index < position.count) { model.stepWalk(.next) }
                .accessibilityLabel("Next item")
            HStack(spacing: 4) {
                // Positional marks: the walk's items have no other identity on screen.
                ForEach(Array(1...position.count), id: \.self) { mark in
                    Rectangle()
                        .fill(mark < position.index ? NotchStyle.dim : mark == position.index ? NotchStyle.ink : NotchStyle.well)
                        .frame(minWidth: 2, maxWidth: 18)
                        .frame(height: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
    }

    /// The space between the walk's header and its card (Paper K frame D).
    private static let walkHeaderGap: CGFloat = 10

    /// The walk's end (#440): the last item was done, so the panel says so, then folds and gives the
    /// keyboard back. It names nothing as checked beyond what was decided, answered or dismissed.
    private var allCheckedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Sprite.slotGap) {
            spriteSlot(working: false, color: 0, unlit: true)
            Text("All checked").font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }

    /// ← or → on a walk card that shows a question (#440): the walk is asked with the viewed question,
    /// so a call of several questions steps its own first, and shows the one the step names.
    private func handleWalkKey(_ press: WalkKeyPress?) {
        guard let press, press.card == model.presentationMode.singleCard,
              let question = model.spotlightItem(press.card)?.question else { return }
        let (viewed, count) = viewedQuestionIndex(question)
        if case let .question(next) = model.stepWalk(press.action, question: .init(viewed: viewed, count: count)) {
            showQuestion(next, of: question)
        }
    }

    private func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The spotlight question card's stepper (#384, Paper "G · Claude: answer several questions",
    /// panel 4): a card that opened by itself has no "‹ Queue" bar, so a request with two or more
    /// questions gets a slim row above the title with the same right-aligned stepper.
    private var spotlightStepperQuestion: AgentQuestion? {
        guard let id = model.presentationMode.singleCard,
              let question = model.orderedAgentAttentionItems.first(where: { $0.id == id })?.question,
              QuestionStepperPlacement.resolve(mode: model.presentationMode, card: id,
                                               questionCount: questionPrompts(question).count) == .ownRow
        else { return nil }
        return question
    }

    private func spotlightStepperRow(_ question: AgentQuestion) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            questionStepper(question)
        }
    }

    /// "‹ question N of M ›" (D19): steps the view through this request's questions only; the arrows
    /// are dim and cannot be pressed at either end. Viewing changes no answer.
    @ViewBuilder
    private func questionStepper(_ question: AgentQuestion) -> some View {
        let prompts = questionPrompts(question)
        if prompts.count > 1 {
            let viewed = viewedQuestionIndex(question).viewed
            NotchButton(title: "‹") { showQuestion(viewed - 1, of: question) }
                .disabled(viewed == 0)
                .accessibilityLabel("Previous question")
            Text(QuestionCardLines.stepper(viewed: viewed, count: prompts.count))
                .font(QuestionCardStyle.font(10)).foregroundStyle(NotchStyle.dim).monospacedDigit().fixedSize()
            NotchButton(title: "›") { showQuestion(viewed + 1, of: question) }
                .disabled(viewed + 1 >= prompts.count)
                .accessibilityLabel("Next question")
        }
    }

    /// One approval card body (#320) for the spotlight and the clicked card, Codex and Claude alike,
    /// read top to bottom and inset to the title: the agent's ask, the action and its full command,
    /// where it runs, the raw request when it adds detail, then where the request stands and its
    /// controls. Only the user's own Approve or Deny decides; the countdown only reads the deadline.
    @ViewBuilder
    private func approvalCardBody(_ request: SpotlightRequest, item: AgentAttentionItem, subject: String,
                                  herdr: HerdrOpenAvailability, decidable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ask = request.ask {
                Text(ask).font(NotchStyle.mono(12)).foregroundStyle(NotchStyle.ink)
                    // 12pt mono sets about 14pt of line; three more make the 17pt line height.
                    .lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 8) {
                if let action = request.action {
                    Text(action).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize()
                }
                if let command = request.command {
                    ApprovalCommandBox(command: command, subject: subject,
                                       expanded: disclosure("command:\(item.id)"))
                } else {
                    // D9: never guess; say who left it out. Approve, Deny and Open stay offered.
                    Text(SpotlightRequest.missingCommand(from: item.session.source))
                        .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
            let task = request.task(besidesSessionName: sessionNames[item.session])
            if task != nil || request.directory != nil {
                let place = request.directory.map { "in \($0.display)" }
                Text([task, place].compactMap { $0 }.joined(separator: " · "))
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                    .help(request.directory?.full ?? "")
                    .accessibilityLabel([task, request.directory.map { "in \($0.full)" }].compactMap { $0 }.joined(separator: ", "))
                    .contextMenu { if let full = request.directory?.full { copyPathButton(full) } }
            }
            if let full = request.fullRequest {
                // Per request, like the command's disclosure, so one request's open state never opens another's.
                NotchDisclosure(title: "Show full request", subject: subject, expanded: disclosure("request:\(item.id)")) {
                    Text(full).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if item.kind == .handedBackApproval {
                // Herdly records when the request arrived, not when or why it was handed back, so the
                // elapsed time names the arrival and no cause is given.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Handed back with no decision · asked \(SpotlightRequest.elapsed(since: request.arrivedAt, now: context.date.timeIntervalSince1970))")
                        .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            if item.session.source == .claude {
                // `decidable` has no deadline, so this line does not flicker on at the deadline itself.
                if item.kind == .actionableApproval, !decidable {
                    Text("Claude's native permission prompt remains available.")
                        .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                }
                claudeReturnMessage(item)
            } else if case let .unavailable(cause) = herdr {
                herdrReasonLine(item, cause: cause)
            } else if let reason = model.terminalOpenLine(item.session) {
                terminalOpenLine(item, reason: reason)
            }
            // Everything below reads one `ApprovalCardReading` from the card's own clock. `decidable`
            // (`Companion.canDecide`) has no deadline; the reading alone disables Approve and Deny at
            // the deadline, and the decide path re-checks the request, deadline included, before
            // writing anything.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let reading = ApprovalCardReading(item, decidable: decidable, now: context.date.timeIntervalSince1970) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let countdown = reading.countdown { ApprovalCountdownRow(countdown: countdown) }
                        // A key label shows only while that key acts (#439): ⌘⏎ and ⌘⌫ while Approve and
                        // Deny are enabled, on a card with deliberate keyboard focus.
                        let keys = model.approvalKeysCard == item.id
                        let decisionKeys = keys && reading.decisionEnabled
                        HStack(spacing: 6) {
                            if reading.showsDecision, let approval = item.approval {
                                let request = "\(item.session.source.displayName) \(Self.requestKind(approval)) request"
                                let approveKey = decisionKeys ? NotchShortcut.commandReturn : nil
                                let denyKey = decisionKeys ? NotchShortcut.commandDelete : nil
                                NotchButton(title: "Approve", emphasized: true, shortcut: approveKey) {
                                    model.decideAgent(approval, as: .allowOnce)
                                }
                                    .disabled(!reading.decisionEnabled)
                                    .accessibilityLabel("Approve this request once: \(subject)")
                                    .accessibilityHint(NotchShortcut.hint("Approves this \(request) once.", shortcut: approveKey))
                                NotchButton(title: "Deny", shortcut: denyKey) { model.decideAgent(approval, as: .deny) }
                                    .disabled(!reading.decisionEnabled)
                                    .accessibilityLabel("Deny: \(subject)")
                                    .accessibilityHint(NotchShortcut.hint("Denies this \(request).", shortcut: denyKey))
                            }
                            Spacer(minLength: 6)
                            // O opens while a decision is on offer; once none is, Return opens too
                            // and the label names it, as on a handed-back question card.
                            approvalOpenControl(item, reading: reading, subject: subject,
                                                shortcut: keys ? (reading.decisionEnabled ? .open : .returnKey) : nil)
                        }
                    }
                }
            }
        }
        .padding(.leading, Sprite.slotWidth + Sprite.slotGap)
        .padding(.trailing, 6)
        .padding(.top, 2)
    }

    /// The card's Open: "Open" beside Approve and Deny, "Open in Codex" or "Open in Claude" once handed
    /// back (emphasized, as the card's one action). VoiceOver reads "Open Session: <subject>" either way;
    /// Open still revalidates its exact target.
    @ViewBuilder
    private func approvalOpenControl(_ item: AgentAttentionItem, reading: ApprovalCardReading, subject: String,
                                     shortcut: NotchShortcut? = nil) -> some View {
        let handedBack = reading.stage == .handedBack
        if let open = approvalOpen(item, handedBack: handedBack) {
            let hint = item.session.source == .claude ? "Open this Claude session in its terminal."
                : handedBack ? "Open this session in Codex." : "Hands this request back to Codex's own prompt."
            NotchButton(title: reading.openTitle, emphasized: handedBack, shortcut: shortcut, action: open)
                .disabled(model.openingTask)
                .accessibilityLabel("Open Session: \(subject)")
                .accessibilityHint(NotchShortcut.hint(hint, shortcut: shortcut))
        } else {
            // No Open: a Claude card that cannot be opened may offer "Set up a Terminal" instead.
            claudeReturnControl(item, subject: subject, emphasized: handedBack, openTitle: reading.openTitle)
        }
    }

    /// The approval card's Open, or nil where the card shows none: the one decision its button and its
    /// keys (#439: O, and Return once no decision is on offer) both read, so a key never opens what the
    /// card does not show. A Codex request before its hand-back goes back to Codex's own prompt
    /// (`openAgentApproval`) and after it the session opens; a Claude request opens its session's
    /// terminal (`claudeOpenOffered`, as `claudeReturnControl` decides for every Claude card).
    private func approvalOpen(_ item: AgentAttentionItem, handedBack: Bool) -> (() -> Void)? {
        guard let approval = item.approval else { return nil }
        if item.session.source == .claude {
            return claudeOpenOffered(item.session) ? { model.openAgentApproval(approval) } : nil
        }
        guard codexOpenOffered(item) else { return nil }
        return handedBack ? { model.openAgent(item.session) } : { model.openAgentApproval(approval) }
    }

    /// A key the panel handed to the approval card on screen (#439), already mapped by
    /// `ApprovalCardKeys`. The card is read again now through `approvalCardNow`, the helper the
    /// mapping used: Approve and Deny do exactly what clicking them does, only while the card as drawn
    /// now enables them, and `decideAgent` then checks the request again before writing anything.
    /// Open acts as the card's Open, where it shows one and it is enabled.
    private func handleApprovalCardKey(_ press: ApprovalCardKeyPress?) {
        guard let press, press.card == model.presentationMode.singleCard,
              let card = model.approvalCardNow(press.card) else { return }
        switch press.action {
        case .approve, .deny:
            guard card.reading.decisionEnabled, let decision = press.action.decision else { return }
            model.decideAgent(card.approval, as: decision)
        case .open:
            guard !model.openingTask else { return }
            approvalOpen(card.item, handedBack: card.reading.stage == .handedBack)?()
        case .none:
            return
        }
    }

    /// The exact turn's working directory, home shortened to `~`; hover and Copy Path give the full path.
    private func directoryLine(_ directory: SpotlightDirectory) -> some View {
        Text("in \(directory.display)").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
            .fixedSize(horizontal: false, vertical: true)
            .help(directory.full)
            .accessibilityLabel("in \(directory.full)")
            .contextMenu { copyPathButton(directory.full) }
    }

    private func copyPathButton(_ path: String) -> some View {
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }

    /// A question for reading only: its text and its options as read-only wells.
    @ViewBuilder
    private func prompt(_ prompt: QuestionPrompt, subject: String = "", tone: Int = 0, agent: String = "Codex") -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = prompt.question { questionText(question) }
            else { Text("Herdly could not read this question; continue in \(agent).")
                .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim) }
            optionList(prompt.options, subject: subject, tone: tone, selected: nil, enabled: false, readOnly: true, select: nil)
            if prompt.truncated {
                Text("Shortened; the full question is in \(agent).").font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
            }
        }
    }

    /// The daemon card's status sentence: which path, and where the answer stands.
    private func daemonStatus(_ progress: QuestionAnswerProgress) -> String? {
        switch progress.phase {
        case .ready:
            // Nothing sent yet: the controls speak for themselves. The path is named once something is.
            return nil
        case .sending: return "Sending to Codex's daemon…"
        case .sent: return "Answered through Codex's daemon. Waiting for Codex to record it."
        case .unconfirmed: return "Answered through Codex's daemon, but Codex has not recorded an answer. Check Codex; Herdly will not resend."
        case let .failed(reason): return reason
        }
    }

    /// Why the card is not on the daemon path, for the fallback sentences.
    private var noDaemon: String {
        model.daemonConnected ? "Codex's daemon does not hold this question" : "No Codex daemon"
    }

    /// The key-route card's one sentence about where the answer stands (D24). Every phase names what
    /// Herdly knows and nothing more; a typed key is never described as an answer Codex has.
    private func questionStatus(_ card: CodexCard) -> String? {
        let question = card.question
        // The card's one reason line already says to answer it in Codex (`herdrReasonLine`, `terminalOpenLine`).
        if unrelayedQuestion(question) { return nil }
        let index = card.current
        let destination = HerdrPresentation.keyDestination(for: card.route)
        let digit = { (question: Int) in card.progress.picks[question].map { $0 + 1 } }
        switch card.progress.phase {
        case .ready:
            if card.keyRoute, card.viewed < index, let sent = digit(card.viewed) {
                return QuestionCardLines.typedReview(digit: sent, noun: destination.noun)
            }
            if index >= question.prompts.count {
                return "Codex is on question \(index + 1) of \(max(question.questionCount, card.prompts.count)). Continue in Codex."
            }
            if card.viewed >= index, case let .continueInCodex(reason) = QuestionAnswerProgress.offer(question, at: card.viewed) {
                return reason
            }
            if case let .relayUnavailable(reason) = card.route { return HerdrPresentation.relayUnavailableLine(for: reason) }
            if question.source == .cli, !card.controls { return "\(noDaemon); enable Ghostty controls to answer from here, or answer in Codex." }
            if card.keyRoute, index > 0, card.viewed == index, let sent = digit(index - 1) {
                return QuestionCardLines.typed(digit: sent, noun: destination.noun, next: index)
            }
            // Nothing sent yet: no sentence. The path is named once something is.
            return nil
        case .sending:
            return "Sending the key to \(destination.place)…"
        case .sent:
            return QuestionCardLines.typed(digit: digit(index) ?? 0, noun: destination.noun, next: nil)
        case .unconfirmed:
            return QuestionCardLines.typedUnconfirmed(digit: digit(index) ?? 0, noun: destination.noun)
        case let .failed(reason):
            return reason
        }
    }

    /// A Codex question that no relay can answer while Open is unavailable too, in herdr or in a
    /// terminal host (#267). Its card shows only one line: "Answer this in Codex." then Open's reason
    /// (`HerdrPresentation.unrelayedQuestionLine`, `OpenUnavailableLines.cardLine`); why the relay failed
    /// stays in diagnostics. With Open still offered (a click-time line included) the card keeps its
    /// typed-input sentence and Open as before.
    private func unrelayedQuestion(_ question: AttentionQuestion) -> Bool {
        guard case .relayUnavailable = model.route(for: question) else { return false }
        let identity = CodexAttentionAdapter.session(question.session, surface: .cli)
        if case .unavailable = herdrOpen(identity) { return true }
        return !model.offersTerminalOpen(identity)
    }

    /// The result card a finished turn pops (#323, Paper D33, 9NU, 9RW), inset to the title: the last
    /// message whole in its own scroll, cut to five lines, or one line (Settings › Response length), or
    /// one dim line saying why it cannot be read; the restored-result line; the reply field
    /// only where Herdly can reach the session; the line its result row would show when Open is not
    /// offered (`reading`, the same one its header click reads); then Open and Dismiss on the right.
    /// Show all is view state only (`openDisclosures`); nothing on the card
    /// acknowledges the result: not seeing it, not unfolding it, not sending.
    @ViewBuilder
    private func resultCardBody(_ item: AgentAttentionItem, subject: String, reading: ResultRowReading,
                                codexOpen: Bool) -> some View {
        let details = model.spotlightDetails(for: item)
        VStack(alignment: .leading, spacing: 10) {
            switch details?.response {
            case let .available(preview)?:
                resultMessage(preview, item: item, subject: subject)
            case let .unavailable(reason)?:
                Text(reason).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
            if item.outcome?.uncertain == true {
                Text("Queued before Herdly last started. You may already have seen this result; Herdly cannot verify it.")
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
            }
            if let outcome = item.outcome { resultReplyField(outcome, subject: subject) }
            resultRowLine(item, reading: reading)
            // The walk's result card with the keyboard shows its keys, "O" and "X" (#440).
            let keys = model.resultKeysCard == item.id
            HStack(spacing: 6) {
                Spacer(minLength: 6)
                resultOpen(item, subject: subject, codexOpen: codexOpen, target: reading.target,
                           shortcut: keys ? NotchShortcut.open : nil)
                NotchButton(title: "Dismiss", shortcut: keys ? NotchShortcut.dismiss : nil) { model.dismissAgent(item.id) }
                    .accessibilityLabel("Dismiss completion: \(subject)")
                    .accessibilityHint(NotchShortcut.hint(nil, shortcut: keys ? NotchShortcut.dismiss : nil))
            }
        }
        .padding(.leading, Sprite.slotWidth + Sprite.slotGap)
        .padding(.trailing, 6)
        .padding(.top, 2)
    }

    /// Open on a result never marks it as checked; only a verified visit (ADR 0016), the Codex app's
    /// read state, a new prompt, or Dismiss does.
    private static func resultOpenHint(_ source: AgentSource) -> String {
        "Opens this session in \(source.displayName). Opening it does not mark anything as checked."
    }

    /// The last message: whole in its own bounded scroll, its first five lines, or its first line, as
    /// Settings › Notifications › "Response length" starts every card; "Show all ›" / "Show less"
    /// flips one card (`ResultCardMessage`) and appears only when the length shortened it. On a
    /// Glance card it sits at the end of the one line. A message Herdly kept only the start of says
    /// so: the full message stays in the agent.
    @ViewBuilder
    private func resultMessage(_ preview: CompletionPreview, item: AgentAttentionItem, subject: String) -> some View {
        let key = "result-message:\(item.id)"
        let length = model.resultResponseLength
        let shown = ResultCardMessage.shown(preview, length: length, flipped: openDisclosures.contains(key))
        let showAll = NotchDisclosure(title: "Show all", expandedTitle: "Show less", subject: subject, chevron: .trailing,
                                      expanded: resultMessageDisclosure(key, shown: shown)) { EmptyView() }
        switch shown {
        case .whole:
            ResultMessageScroll(text: preview.extent.full ?? preview.text)
            if case .cutAndCapped = preview.extent {
                Text("Shortened; the full message is in \(item.session.source.displayName).")
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ResultCardMessage.folds(preview, length: length) { showAll }
        case .brief:
            ResultMarkdown(text: preview.text)
            showAll
        case let .glance(line):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(ResultMarkdown.styled(line)).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                showAll.fixedSize()
            }
        }
    }

    /// Show all reads open while the card shows the whole message; `openDisclosures` holds the cards
    /// clicked away from the Settings choice.
    private func resultMessageDisclosure(_ key: String, shown: ResultCardMessage.Shown) -> Binding<Bool> {
        Binding(get: { shown == .whole },
                set: { open in
                    if open != (shown == .whole) {
                        if openDisclosures.contains(key) { openDisclosures.remove(key) } else { openDisclosures.insert(key) }
                    }
                })
    }

    /// One follow-up prompt for the finished session, sent to that session and no other, by its
    /// agent's one-reply path (`Companion.sendResultReply`). The field is shown only while a verified
    /// route reaches the session and the card has sent nothing; otherwise there is no field and no
    /// reason line. A send that leaves `.ready` folds the card; a refusal keeps the text.
    @ViewBuilder
    private func resultReplyField(_ outcome: AgentOutcome, subject: String) -> some View {
        if model.resultCardOffersReply(outcome), let reply = model.resultReply(outcome.id) {
            let key = "reply:\(outcome.session.sourceScope):\(outcome.session.session):\(outcome.turn)"
            DraftField(placeholder: Self.replyPlaceholder, text: draft(key), sendTitle: "Send",
                       fieldLabel: "Reply to \(subject)", sendLabel: "Send reply to \(subject)",
                       hint: reply.hint, onEscape: model.escape) {
                if model.sendResultReply(outcome, text: drafts[key] ?? "") != .ready { drafts[key] = nil }
            }
        }
    }

    private static let replyPlaceholder = "› Reply to this session"

    /// The open queue with nothing in it, in a row's own grammar: the unlit sprite leads the title,
    /// one line follows, and Open Controls appears only while no source reports to Herdly.
    @ViewBuilder
    private func emptyQueueRow(_ reading: EmptyQueueReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: Sprite.slotGap) {
                spriteSlot(working: false, color: 0, unlit: true)
                Text(reading.title).font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            if let sentence = reading.sentence {
                Text(sentence).font(NotchStyle.mono(11))
                    .foregroundStyle(reading == .notConnected ? NotchStyle.text : NotchStyle.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if reading == .notConnected {
                NotchButton(title: "Open Controls", action: model.showControls)
                    .accessibilityHint("Opens Herdly controls to connect Codex or Claude.")
            }
        }
    }

    @ViewBuilder
    private func attentionRow(_ item: AgentAttentionItem) -> some View {
        let spotlightDetails = isSpotlight(item) ? model.spotlightDetails(for: item) : nil
        let subject = rowSubject(item)
        let herdr = herdrOpen(item.session)
        // A Codex card offers Open unless herdr or the latest terminal scan rules it out (#267).
        let codexOpen = codexOpenOffered(item)
        let spotlit = isSpotlight(item)
        let selected = model.presentationMode.showsAll && model.queueSelection.selected == item.id
        // In the open queue a row's heading line is 26pt tall, so one-line rows stack like the
        // artboards; the space it adds above and below the text replaces part of the row spacing.
        let inQueue = model.presentationMode.showsAll
        // #319: a working row in the open queue is its header line alone until it is opened in place.
        let runningRow = inQueue && item.kind == .running
        let runningOpen = runningRow && model.openRunningRow.isOpen(item.id)
        let bodySpacing: CGFloat = 8
        // #320: an approval row in the open queue is its header line alone; its body is the card.
        let approvalRow = item.kind == .actionableApproval || item.kind == .handedBackApproval
        // #321: so is a question row; one question card at a time takes digits and Return.
        let questionRow = item.kind == .question
        // "Not delivered · answer in Claude" keeps its Open inline on the row line, before the age.
        let opensFromNote = inQueue && approvalRow && rowNote(item)?.offersOpen == true
        // #322: a result row in the open queue (Earlier included) is one line: the header opens the
        // session, Dismiss (or Remove) is a × after the age (D34), and an unreachable row's reason
        // line sits under the name. Its body, reply field and preview stay on the spotlight card.
        let resultRow = inQueue && !spotlit && item.kind.opensSession
        // Whether Approve and Deny are this card's to offer; one rule with the decide path.
        let decidable = spotlit && approvalRow && model.canDecide(item)
        // #323: a result on its own card (the pop). Its header line opens the session like a result row.
        let resultCard = spotlit && item.outcome != nil
        // One reading of the session for a result row or card: its click, word, reason line and Open
        // all read it, so they never disagree. Nil for every other row.
        let sessionReading = resultRow || resultCard ? model.resultRowReading(item.session) : nil
        VStack(alignment: .leading, spacing: inQueue ? bodySpacing - 5 : bodySpacing) {
            // Every row is headed by its session's mark and name; the mark steps only while the
            // session is working, and a word appears only when the row is off its normal path.
            let working = item.running?.status == .working
            if questionRow && spotlit {
                questionCardHeader(item)
            } else {
                Group {
                    if item.kind == .actionableApproval && inQueue {
                        // A live approval's "Ns left" steps once a second, seen and spoken. The
                        // spotlight and clicked card show it as their countdown row instead.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let countdown = QueueRowPresentation.countdown(item, now: context.date.timeIntervalSince1970)
                            cardOpener(item, countdown: countdown) {
                                headerLine(item, working: working, countdown: countdown, quiet: false)
                            }
                        }
                    } else if runningRow {
                        // #419: redrawn once more when the row turns quiet, with no event; nothing ticks before.
                        TimelineView(QuietSchedule(changes: [item.quietAt].compactMap { $0 })) { context in
                            let now = QuietSchedule.now(context.date)
                            let quiet = item.isQuiet(at: now)
                            runningOpener(item, open: runningOpen, quiet: quiet) {
                                headerLine(item, working: item.spriteSteps(at: now), countdown: nil, quiet: quiet)
                            }
                        }
                    } else if resultRow, let reading = sessionReading {
                        // The control sits outside the row's own button, so the two never nest. It
                        // follows the age in its own fixed lane (D34), centred on the text line.
                        HStack(alignment: .center, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                sessionOpener(item, target: reading.target) {
                                    headerLine(item, working: working, countdown: nil, target: reading.target, showsAge: false, quiet: false)
                                }
                                if rowNote(item)?.offersOpen == true {
                                    // "Not delivered · reply in Codex": Open beside the note, as on an approval row.
                                    resultOpen(item, subject: subject, codexOpen: codexOpen, target: reading.target)
                                }
                                rowAge(item)
                            }
                            resultRowControl(item, subject: subject)
                        }
                    } else if opensFromNote {
                        // Open sits outside the row's own button, so the two never nest.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            cardOpener(item) {
                                headerLine(item, working: working, countdown: nil, showsAge: false, quiet: false)
                            }
                            claudeReturnControl(item, subject: subject, openTitle: Self.rowOpenTitle)
                            rowAge(item)
                        }
                    } else if resultCard, let reading = sessionReading {
                        // 8DW "New ones": clicking the pop opens the session, by the result row's rule.
                        resultCardHeaderOpener(item, target: reading.target) {
                            headerLine(item, working: working, countdown: nil, quiet: false)
                        }
                    } else if spotlit && approvalRow {
                        // The card header reads the same `ApprovalCardReading` as the card body below.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            headerLine(item, working: working, countdown: nil,
                                       card: ApprovalCardReading(item, decidable: decidable,
                                                                 now: context.date.timeIntervalSince1970),
                                       quiet: false)
                        }
                    } else if inQueue, let question = item.question, question.identity.session.source == .claude,
                              model.canAnswerAgentQuestion(question) {
                        // A Claude question Herdly can answer steps its "Ns left" once a second, as
                        // a live approval does; one it cannot answer takes the plain row, with no timer.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let countdown = model.claudeQuestionCountdown(question, now: context.date.timeIntervalSince1970)
                            cardOpener(item, countdown: countdown) {
                                headerLine(item, working: working, countdown: countdown, quiet: false)
                            }
                        }
                    } else {
                        cardOpener(item) {
                            headerLine(item, working: working, countdown: nil, quiet: false)
                        }
                    }
                }
                // A result row's line is 30pt (D34); other queue rows and the result card keep 26pt.
                .frame(minHeight: resultRow ? QueueRowMetrics.resultLine : inQueue || resultCard ? 26 : nil)
                .modifier(CardRowHover(id: item.id, active: opensAsCard(item) || (resultRow && sessionReading?.target == .reachable),
                                       hovered: $hoveredCardRow,
                                       reduceMotion: model.reduceMotion))
            }
            if runningRow {
                if runningOpen {
                    runningDetails(item, subject: subject, herdr: herdr, codexOpen: codexOpen)
                        .transition(QueueMotion.rowTransition(reduceMotion: model.reduceMotion))
                }
            } else if approvalRow {
                // One card body for the spotlight and the clicked card (#320); nothing under a queue row.
                if spotlit, let card = model.approvalCard(for: item) {
                    approvalCardBody(card, item: item, subject: subject, herdr: herdr,
                                     decidable: decidable)
                }
            } else if questionRow {
                // One question card body for the spotlight and the clicked card (#321); nothing under a queue row.
                if spotlit {
                    questionCardBody(item, subject: subject, herdr: herdr, codexOpen: codexOpen)
                }
            } else if resultCard, let reading = sessionReading {
                resultCardBody(item, subject: subject, reading: reading, codexOpen: codexOpen)
            } else if resultRow, let reading = sessionReading {
                // Why Open is not offered (an unreachable row), or why the last click did not open,
                // under the name: the cards' own line, never a greyed button.
                resultRowLine(item, reading: reading)
                    .padding(.leading, Sprite.slotWidth + Sprite.slotGap)
                    .padding(.bottom, 4)
            } else {
                VStack(alignment: .leading, spacing: bodySpacing) {
                    if let note = rowNote(item), note.offersOpen {
                        // "Not delivered · answer in Claude": Open takes the user to the session to answer there.
                        HStack(spacing: 6) { claudeReturnControl(item, subject: subject) }
                    }
                    if item.kind != .question, let directory = spotlightDetails?.directory {
                        directoryLine(directory)
                    }
                    switch item.kind {
                    case .actionableApproval, .handedBackApproval:
                        // Approval rows render the approval card body instead (#320).
                        EmptyView()
                    case .outcome, .earlierOutcome:
                        // A result is its row in the queue and its result card when spotlit (#322, #323).
                        EmptyView()
                    case .question:
                        // Question rows render the question card body instead (#321).
                        EmptyView()
                    case .waiting, .running:
                        if let running = item.running, let row = running.rowText {
                            // A prompt opens in place: the row's own text grows to the full prompt rather
                            // than repeating it below. An action keeps its labelled row and shows the full
                            // command beneath, since the row may not be the command itself.
                            let promptKey = "prompt:\(item.session.session)"
                            let expandsPrompt = running.fullAction == nil && running.fullPrompt.map { $0 != row } == true
                            let promptOpen = expandsPrompt && openDisclosures.contains(promptKey)
                            if promptOpen, let full = running.fullPrompt {
                                Text(full).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text(row).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).lineLimit(2).truncationMode(.tail)
                            }
                            if let full = running.fullAction {
                                // D11: a shortened shell command is named as a command; other tools keep "action".
                                NotchDisclosure(title: running.action?.disclosureTitle ?? "Show full action", subject: subject, expanded: disclosure("action:\(item.session.session)")) {
                                    Text(full).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } else if expandsPrompt {
                                // A shortened prompt is only its start; the disclosure must not call it full.
                                let title = running.promptShortened ? "Show more of prompt" : "Show full prompt"
                                NotchDisclosure(title: title, expandedTitle: "Show less", subject: subject, expanded: disclosure(promptKey)) {
                                    if running.promptShortened {
                                        Text("Shortened; the full prompt is in \(item.session.source.displayName).")
                                            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                                    }
                                }
                            }
                        }
                        if item.session.source == .claude {
                            claudeReturnMessage(item)
                        }
                    case .statusUnavailable:
                        Text(item.unavailableReason ?? "Status unavailable. Continue in Claude to inspect the session.")
                            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
                    }
                    if item.session.source == .codex, case let .unavailable(cause) = herdr {
                        herdrReasonLine(item, cause: cause)
                    } else if item.session.source == .codex, let reason = model.terminalOpenLine(item.session) {
                        terminalOpenLine(item, reason: reason)
                    }
                    HStack(spacing: 6) {
                        switch item.kind {
                        case .actionableApproval, .handedBackApproval:
                            // Approval rows render their controls in the approval card body (#320).
                            EmptyView()
                        case .statusUnavailable:
                            if item.session.source == .codex, codexOpen {
                                NotchButton(title: "Open Session") { model.openAgent(item.session) }
                                    .disabled(model.openingTask)
                                    .accessibilityLabel("Open Session: \(subject)")
                                    .accessibilityHint("Open this session in Codex.")
                            }
                            claudeRemoveControl(item, subject: subject)
                        case .question:
                            // Question rows render their controls in the question card body (#321).
                            EmptyView()
                        case .outcome, .earlierOutcome:
                            // The result card has its own controls (#323).
                            EmptyView()
                        case .waiting, .running:
                            if item.session.source == .codex, codexOpen {
                                NotchButton(title: "Open Session") { model.openAgent(item.session) }
                                    .disabled(model.openingTask)
                                    .accessibilityLabel("Open Session: \(subject)")
                                    .accessibilityHint("Open this session in Codex.")
                            }
                            claudeReturnControl(item, subject: subject)
                            claudeRemoveControl(item, subject: subject)
                        }
                    }
                }
                // Room below a row's details before the next row's 26pt heading line.
                .padding(.bottom, inQueue ? 8 : 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rowHeading(item, quiet: false)), \(subject)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // The opened running row is one container on its own ground (NotchStyle.openRow), 6pt outside
        // the row's left and right edges so the header line does not move when it opens (F3).
        .background {
            if runningOpen {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(NotchStyle.openRow)
                    .padding(.horizontal, -6)
                    .transition(.opacity)
            }
        }
        // The keyboard selection reuses the focus ring's vocabulary around the whole row. On a result
        // row it stays inside the row's own band (its line plus half the gap), stroke included.
        // A spotlight question card that has the keyboard wears the same ring around the whole card
        // (#428, Paper L "2 · Keyboard in"), until its send is shown.
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(selected || keyboardRing(item) ? 0.9 : 0), lineWidth: QueueRowMetrics.ringWidth)
            .padding(.horizontal, -6)
            .padding(.vertical, resultRow ? -QueueRowMetrics.resultRingOutset : -4))
        .environment(\.questionCard, item.kind == .question)
        // Result rows sit 4pt apart (D34): half the gap above and below each.
        .padding(.vertical, resultRow ? QueueRowMetrics.resultGap / 2 : 0)
    }

    /// The spoken heading (`QueueRowPresentation.spokenHeading`): name, place (a finished row's work
    /// status in words first, #418), any row note, the full state the visual word shortens, and a live
    /// approval's seconds left.
    private func rowHeading(_ item: AgentAttentionItem, countdown: ApprovalCountdown? = nil, quiet: Bool) -> String {
        let note = rowNote(item)
        return QueueRowPresentation.spokenHeading(item, name: QueueRowPresentation.sessionName(item.session, names: sessionNames),
                                                  place: model.rowPlaceLine(for: item, note: note, quiet: quiet)?.spoken,
                                                  note: note, countdown: countdown)
    }

    /// A non-question row's heading line (D17): sprite, name, dim "· place" (it truncates first),
    /// then at most one word or a live approval's "Ns left", then the age lane. A single approval
    /// card's header (`card`, #320) says its kind instead ("Approve" while it can be decided here,
    /// "Handed back", or none), then the dim source ("CLI", "Claude"); queue rows keep D17 and name
    /// neither. With `showsAge` false the caller draws the age lane, putting a row note's Open before
    /// it; a result row's × lane follows it (D34). A result row whose session is unreachable
    /// (`target`, #322) reads "Unreachable" in the word slot.
    private func headerLine(_ item: AgentAttentionItem, working: Bool, countdown: ApprovalCountdown?,
                            card: ApprovalCardReading? = nil, target: ResultRowTarget = .reachable,
                            showsAge: Bool = true, quiet: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: Sprite.slotGap) {
                spriteSlot(working: working, color: spriteColor(for: item.session))
                rowHeader(item, countdown: countdown, quiet: quiet)
            }
            if let countdown {
                SecondsLeftPill(countdown: countdown)
            } else if let card {
                if let kind = card.kindWord { ApprovalKindWordView(word: kind) }
                Text(card.source)
                    .font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.dim)
                    .lineLimit(1).fixedSize()
                    .accessibilityLabel(item.session.sourceLabel)
            } else if let exception = QueueRowPresentation.exception(item, target: target) {
                ExceptionWord(exception: exception)
            }
            if showsAge { rowAge(item) }
        }
    }

    /// A row's leading mark: the chosen sprite in a fixed slot as wide as the widest kind and as tall
    /// as the tallest, leading-aligned and centred in it, so titles line up whichever kind is chosen.
    /// The slot's bottom sits on the title's baseline, which keeps its centre where the old 12x8pt
    /// sprite's was.
    private func spriteSlot(working: Bool, color: Int, unlit: Bool = false) -> some View {
        Sprite(kind: model.appearance.sprite, working: working, reduceMotion: model.reduceMotion,
               color: color, unlit: unlit)
            .frame(width: Sprite.slotWidth, height: Sprite.slotHeight, alignment: .leading)
    }

    /// The row's name, then "· project @ branch" (in the profile's label format) when Herdly has seen
    /// the working directory. The place takes the free width and tail-truncates first, so the name
    /// and any word after it stay whole. A finished row's work status (#418) leads the place in its
    /// tone and never truncates; the pull request or place after it gives way. Presentation only;
    /// nothing here selects a target.
    private func rowHeader(_ item: AgentAttentionItem, countdown: ApprovalCountdown?, quiet: Bool) -> some View {
        let note = rowNote(item)
        return RowHeaderNamePlace(name: QueueRowPresentation.sessionName(item.session, names: sessionNames), note: note,
                                  place: model.rowPlaceLine(for: item, note: note, quiet: quiet), help: model.rowDirectory(for: item))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowHeading(item, countdown: countdown, quiet: quiet))
        .accessibilityAddTraits(.isHeader)
    }

    /// The trailing age lane: time since the row's latest evidence, refreshed every 30 seconds; a
    /// dash for a status-unavailable row, which has no arrival time.
    private func rowAge(_ item: AgentAttentionItem) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let age = QueueRowPresentation.rowAge(item, now: context.date.timeIntervalSince1970)
            Text(age.text)
                .font(item.kind == .question ? QuestionCardStyle.font(11) : NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).monospacedDigit()
                .lineLimit(1).fixedSize()
                .frame(minWidth: 36, alignment: .trailing)
                .accessibilityLabel(age.spoken)
        }
        .fixedSize()
    }

    /// A herdr session's Open availability for this card, as the notch presents it
    /// (`HerdrOpenAvailability.presented`, one reading with the result rows). `ghosttyTTY` is the
    /// shared support reading the model reads too; the view observes it, so a change redraws.
    private func herdrOpen(_ session: AgentSessionIdentity) -> HerdrOpenAvailability {
        model.presentedHerdrOpen(session)
    }

    /// The one line that replaces Open for a herdr session (product.md, "Agreed herdr
    /// presentation"). A Codex question whose options cannot be relayed gets "Answer this in
    /// Codex." ahead of Open's reason. The exact reason stays in settings diagnostics.
    @ViewBuilder
    private func herdrReasonLine(_ item: AgentAttentionItem, cause: HerdrUnavailableCause) -> some View {
        let agent: HerdrAgentKind = item.session.source == .claude ? .claude : .codex
        let unrelayed = item.kind == .question
            && item.question.flatMap(model.codexQuestion(for:)).map(unrelayedQuestion) == true
        let line = unrelayed ? HerdrPresentation.unrelayedQuestionLine(openCause: cause)
            : HerdrPresentation.cardLine(for: cause, agent: agent)
        Text(line)
            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// The kind of request for VoiceOver hints: "permission" for Codex; for Claude the action the
    /// card shows ("Edit file"), lowercased, "Bash", or "permission" when it named none.
    static func requestKind(_ approval: AgentApproval) -> String {
        guard approval.identity.session.source == .claude,
              let action = approval.details?.action, !action.isEmpty else { return "permission" }
        return action == "Bash" ? action : action.lowercased()
    }

    @ViewBuilder
    private func claudeReturnMessage(_ item: AgentAttentionItem) -> some View {
        let session = item.session
        let herdr = herdrOpen(session)
        if case let .unavailable(cause) = herdr {
            herdrReasonLine(item, cause: cause)
        } else if herdr == .notInHerdr, !model.isBackgroundClaudeSession(session), !model.canOpenClaude(session) {
            // H7 (#280): the app the session's process last walked to names the line once it is not live.
            if let reason = model.claudeLastSeenLine(session) {
                terminalOpenLine(item, reason: reason, replacesOpen: true)
            } else {
                claudeNotVerifiedLine
            }
        } else if herdr == .notInHerdr, let reason = model.terminalOpenLine(session) {
            terminalOpenLine(item, reason: reason)
        }
    }

    /// "Open is unavailable until Herdly can verify this Claude session is live." (or Ghostty's
    /// awaiting-permission line), shared by the card and the result row.
    private var claudeNotVerifiedLine: some View {
        Text(model.claudeReturnUnavailableMessage)
            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func claudeReturnControl(_ item: AgentAttentionItem, subject: String, emphasized: Bool = false,
                                     openTitle: String = "Open Session", openHint: String? = nil,
                                     openFocus: FocusState<Bool>.Binding? = nil, shortcut: NotchShortcut? = nil) -> some View {
        if item.session.source == .claude {
            let herdr = herdrOpen(item.session)
            if herdr == .available || (herdr == .notInHerdr && model.canOpenClaude(item.session)) {
                // The terminal scan's line replaces Open with no disabled button (#267).
                if claudeOpenOffered(item.session) {
                    claudeOpenButton(item, subject: subject, emphasized: emphasized, title: openTitle, hint: openHint,
                                     focus: openFocus, shortcut: shortcut)
                }
            } else if herdr == .notInHerdr, !model.cliTerminalHostOn, model.claudeLastSeenLine(item.session) == nil {
                NotchButton(title: "Set up a Terminal", emphasized: emphasized, action: model.showControls)
                    .accessibilityLabel("Set up a terminal: \(subject)")
                    .accessibilityHint("Opens Herdly controls to switch on a terminal.")
            }
        }
    }

    /// Remove clears a Claude row that looks stuck: its status is unavailable, no live Claude process
    /// holds its session, or it has had no evidence for 30 minutes. It never contacts Claude; new
    /// activity shows the session again. `quiet` draws it as a result row's × (D34) rather than a well.
    @ViewBuilder
    private func claudeRemoveControl(_ item: AgentAttentionItem, subject: String, quiet: Bool = false) -> some View {
        if model.canRemoveAgentRow(item) {
            Group {
                if quiet {
                    RowDismissButton { model.removeAgentRow(item) }
                } else {
                    NotchButton(title: "Remove") { model.removeAgentRow(item) }
                }
            }
            .accessibilityLabel("Remove: \(subject)")
            .accessibilityHint("Removes this row from Herdly until the session shows new activity. Claude is not changed.")
        }
    }

    private func claudeOpenButton(_ item: AgentAttentionItem, subject: String, emphasized: Bool,
                                  title: String = "Open Session", hint: String? = nil,
                                  focus: FocusState<Bool>.Binding? = nil, shortcut: NotchShortcut? = nil) -> some View {
        NotchButton(title: title, emphasized: emphasized, focus: focus, shortcut: shortcut) {
            if let approval = item.approval {
                model.openAgentApproval(approval)
            } else if let question = item.question {
                model.openClaudeQuestion(question)
            } else {
                model.openAgent(item.session)
            }
        }
            .disabled(model.openingTask)
            .accessibilityLabel("Open Session: \(subject)")
            .accessibilityHint(NotchShortcut.hint(hint ?? "Open this Claude session in its terminal.", shortcut: shortcut))
    }

    /// The one line a terminal card shows when Open is unavailable (product.md, "Open unavailable"):
    /// the scan's, which replaces Open, or a click's, beside Open until the next scan. `replacesOpen` marks a
    /// line shown where Open is not offered at all (a Claude card's last-seen app, #280). A Codex question
    /// whose option cannot be typed shares the line ("Answer this in Codex." first). Static text, so
    /// nothing moves under Reduce Motion.
    @ViewBuilder
    private func terminalOpenLine(_ item: AgentAttentionItem, reason: OpenUnavailableReason,
                                  replacesOpen: Bool = false) -> some View {
        let unanswerable = item.kind == .question
            && item.question.flatMap(model.codexQuestion(for:)).map(unrelayedQuestion) == true
        let line = OpenUnavailableLines<String>.cardLine(reason, questionCannotBeTyped: unanswerable)
        Text(line)
            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .accessibilityLabel(replacesOpen || !model.offersTerminalOpen(item.session)
                                ? "Open Session unavailable. \(line)" : "Open Session did not open. \(line)")
    }

    private var stripLabel: String {
        strip.spokenLabel(emptyQueueTitle: model.emptyQueueReading.title,
                          readouts: model.usageStripReadouts.flatMap(\.spokenLabels))
    }

    /// Rows under their optional group headings, with each run of Earlier rows under its count. Each
    /// group is its own stack: heading 2pt above its first row, rows on their 26pt heading lines
    /// (result rows 30pt, 4pt apart, D34), a kind section's "+N more" beneath, and 16pt between
    /// groups. A folded Earlier (D34) draws its heading alone; its rows stay in the group, in place,
    /// so the fold opens without moving anything above it.
    @ViewBuilder
    private func groupRows(_ groups: [QueueGroup]) -> some View {
        let rowTransition = QueueMotion.rowTransition(reduceMotion: model.reduceMotion)
        VStack(alignment: .leading, spacing: 16) {
            // Groups are identified by heading so a regrouped row moves rather than every
            // later group redrawing under a new index.
            ForEach(groups, id: \.heading) { group in
                VStack(alignment: .leading, spacing: 0) {
                    if let heading = group.heading {
                        groupHeading(heading, group: group)
                            .padding(.bottom, 2)
                            .transition(rowTransition)
                    }
                    // The lines come from Core (`QueueGroup.lines`): which Earlier rows a fold hides,
                    // the heading's arrow stop, and where "+N more" sits are its rules, not the view's.
                    ForEach(group.lines, id: \.layoutID) { line in
                        switch line {
                        case .row(let item):
                            attentionRow(item)
                                .transition(rowTransition)
                        case .earlierHeading(let stop):
                            // The heading counts every Earlier result in the group, folded ones
                            // included, and Dismiss all clears exactly those.
                            let earlierIDs = group.earlierIDs
                            EarlierHeading(count: earlierIDs.count, open: !group.earlierFolded,
                                           selected: stop != nil && model.queueSelection.selected == stop,
                                           toggle: { model.setEarlierFold(group.earlierFolded ? .opened : .folded) },
                                           dismissAll: { model.dismissAgents(earlierIDs) })
                                .padding(.vertical, 2)
                                .transition(rowTransition)
                        case .moreRows:
                            if let section = group.section {
                                // Indented to the title, past the sprite slot.
                                MoreRowsPill(count: group.folded, section: section.heading) {
                                    model.openQueueFolds.insert(section)
                                }
                                .padding(.leading, Sprite.slotWidth + Sprite.slotGap)
                                .padding(.top, 2)
                                .transition(rowTransition)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A group heading: a kind section reads "Approve" in 10pt dim with its count in 10pt semibold
    /// text gray (D13); other groupings keep their plain 10pt dim caption.
    @ViewBuilder
    private func groupHeading(_ heading: String, group: QueueGroup) -> some View {
        if group.section != nil {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(heading).font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.dim)
                Text("\(group.count)").font(NotchStyle.mono(10, .semibold)).foregroundStyle(NotchStyle.text).monospacedDigit()
            }
            .padding(.horizontal, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(heading), \(group.count)")
            .accessibilityAddTraits(.isHeader)
        } else {
            Text(heading).font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.dim)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var questionStateKeys: Set<ClaudeQuestionViewStateKey> {
        Set(model.orderedAgentAttentionItems.compactMap(\.question).flatMap { question in
            (0..<max(1, questionPrompts(question).count)).map { questionViewStateKey(question, $0) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: model.expand) {
                // The sprites and the to-check count sit together in the wing left of the housing
                // (`StripWing`: up to three sprites and the bare count collapsed, one sprite and
                // "N to check" open); the usage rings sit in the wing right of it, Claude's (orange)
                // ahead of Codex's (blue), with each ring's numbers while the panel is open.
                // The gap between them is the housing itself. On a display without a housing the
                // gap holds the optional center label instead; otherwise the name is read from the
                // open queue and the accessibility label. The 8pt content inset on each side comes
                // out of the wings. What each wing shows follows the active display profile.
                let layout = model.stripLayout
                HStack(spacing: 0) {
                    // #419: a quiet session's sprite stands still, so the wing redraws once more at each
                    // moment a working row turns quiet; nothing ticks for it in between.
                    TimelineView(QuietSchedule(changes: model.orderedAgentAttentionItems.compactMap(\.quietAt))) { context in
                        let wing = StripWing.make(summary: strip(at: QuietSchedule.now(context.date)),
                                                  leftWing: model.appearance.leftWing, expanded: model.expanded)
                        HStack(spacing: 6) {
                            ForEach(wing.sprites, id: \.identity) { sprite in
                                switch sprite {
                                case .unlit:
                                    Sprite(kind: model.appearance.sprite, working: false, reduceMotion: model.reduceMotion, unlit: true)
                                case .session(let session):
                                    Sprite(kind: model.appearance.sprite, working: session.stepping, reduceMotion: model.reduceMotion,
                                           color: session.color)
                                }
                            }
                            if let badge = wing.badge { Badge(badge) }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.leading, 4)
                    .frame(width: max(0, layout.leading - 8))
                    if let label = centerLabel {
                        // Only laid out where no housing covers the centre; see `NotchPlacement.strip`.
                        Text(label).font(NotchStyle.mono(12)).foregroundStyle(NotchStyle.text)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(width: layout.gap)
                    } else {
                        Color.clear.frame(width: layout.gap)
                    }
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        // One ring per source, Claude's then Codex's; numbers only while open.
                        HStack(spacing: model.expanded ? UsageStripReadouts.openGroupGap : UsageStripReadouts.collapsedRingGap) {
                            ForEach(model.usageStripReadouts, id: \.source) { readout in
                                UsageRing(readout: readout, showsNumbers: model.expanded)
                            }
                        }
                    }
                    .frame(width: max(0, layout.trailing - 8))
                }
                .frame(height: layout.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($headerFocused)
            // The plain style draws no focus ring of its own; keyboard focus stays visible here.
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(NotchStyle.ink.opacity(headerFocused ? 0.9 : 0), lineWidth: 1.5).padding(.horizontal, -6).padding(.vertical, 4))
            .accessibilityLabel(stripLabel)
            .accessibilityHint(model.expanded ? "Herdly attention queue is expanded." : "Expands the Herdly attention queue.")

            if model.expanded {
                Rectangle().fill(NotchStyle.seam).frame(height: 1).padding(.bottom, 12)
                let sections = model.visibleSections
                let rowTransition = QueueMotion.rowTransition(reduceMotion: model.reduceMotion)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.presentationMode.clickedCard != nil { clickedCardBar }
                        if model.presentationMode == .allChecked { allCheckedRow }
                        if let position = model.walkPosition {
                            // Frame D sets the walk's header 10pt above its card, closer than the column's 14pt.
                            VStack(alignment: .leading, spacing: Self.walkHeaderGap) {
                                walkHeader(position)
                                if let question = spotlightStepperQuestion { spotlightStepperRow(question) }
                                if !sections.attention.isEmpty { groupRows(sections.attention) }
                            }
                        } else {
                            if let question = spotlightStepperQuestion { spotlightStepperRow(question) }
                            // An empty stack would still take the column's spacing, so each part is drawn only with rows.
                            if !sections.attention.isEmpty { groupRows(sections.attention) }
                        }
                        spotlightQuestionFoot
                        if sections.foldsWorking {
                            NotchDisclosure(title: "\(sections.workingCount) working", expanded: $model.workingFoldOpen) {
                                groupRows(sections.working)
                            }
                        } else if !sections.working.isEmpty {
                            groupRows(sections.working)
                        }
                        if model.presentationMode.showsAll && sections.isEmpty && !showsTestRow {
                            emptyQueueRow(model.emptyQueueReading)
                                .transition(rowTransition)
                        }
                        if model.presentationMode.showsAll && model.needsGhosttySetup {
                            Text("Enable Ghostty controls in Herdly’s controls window to open these sessions.")
                                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text)
                        }
                        if showsTestRow {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Test notification").font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
                                NotchButton(title: "Dismiss", action: model.dismissTest).accessibilityLabel("Dismiss test notification")
                            }
                            .transition(rowTransition)
                        }
                        if model.presentationMode.showsAll, let hotkey = model.keyboardQueueHotkey {
                            keyboardFoot(hotkey: hotkey)
                        }
                    }
                    .animation(QueueMotion.curve(reduceMotion: model.reduceMotion), value: QueueMotion.layoutKey(sections.attention + sections.working))
                    .animation(QueueMotion.curve(reduceMotion: model.reduceMotion), value: showsTestRow)
                    // Keyed to which row is open only: switching whose lines it shows (#397) redraws at once.
                    .animation(QueueMotion.curve(reduceMotion: model.reduceMotion), value: model.openRunningRow.open)
                    // #397: a remembered switcher well belongs to the row it was in; opening another
                    // row or closing this one forgets it, so it never moves focus in a different row.
                    .onChange(of: model.openRunningRow.open) { lastSwitcherFocus = nil }
                    .padding(.bottom, 14)
                    // Room inside the scroll view's clip for the selection ring and focus rings at
                    // the row edges; the outer negative padding keeps the column where it was.
                    .padding(.horizontal, 8)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: proxy.size.height + model.stripLayout.height + 13)
                    })
                }
                // The queue scrolls without a visible scroller: a scroll bar would be the only
                // light edge inside the panel and would break its fused shape.
                .scrollIndicators(.hidden)
                .padding(.horizontal, -8)
                .focusSection()
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { model.reportContentHeight($0) }
        .onPreferenceChange(DraftInProgressKey.self) { model.notchDraftInProgress = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Herdly notch")
        .padding(.horizontal, NotchPlacement.earRadius + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(NotchStyle.ink)
        .background(NotchStyle.ground, in: NotchShape())
        .preferredColorScheme(.dark)
        .onHover(perform: model.setHovering)
        .onChange(of: model.answerProgress) { previous, next in
            for question in model.orderedAgentAttentionItems.compactMap(\.question) {
                guard let legacy = model.codexQuestion(for: question), let progress = next[legacy.id],
                      progress.questionIndex != previous[legacy.id]?.questionIndex || progress.picks != previous[legacy.id]?.picks
                        || progress.texts != previous[legacy.id]?.texts else { continue }
                // Next or a key moves the view to the new question; changing an earlier draft stays on it.
                if progress.questionIndex != previous[legacy.id]?.questionIndex {
                    viewedQuestions[questionViewStateKey(question, 0)] = nil
                }
                let key = questionViewStateKey(question, 0)
                questionDrafts[key] = questionDrafts[key]?.committing(progress)
            }
        }
        .onChange(of: model.questionCardKeyPress) { _, press in handleQuestionCardKey(press) }
        .onChange(of: model.approvalCardKeyPress) { _, press in handleApprovalCardKey(press) }
        .onChange(of: model.resultCardKeyPress) { _, press in handleResultCardKey(press) }
        .onChange(of: model.walkKeyPress) { _, press in handleWalkKey(press) }
        // "All checked" is said aloud as the walk ends (#440).
        .onChange(of: model.presentationMode == .allChecked) { _, done in if done { announce("All checked") } }
        // VoiceOver reads the question on screen whenever a card takes the keyboard, by the hotkey or
        // a click (#428).
        .onChange(of: model.keyboardCard?.id) { _, id in announceKeyboardCard(id) }
        .onChange(of: questionStateKeys) { _, keys in
            viewedQuestions = viewedQuestions.filter { keys.contains($0.key) }
            questionDrafts = questionDrafts.filter { keys.contains($0.key) }
            claudeSelections = claudeSelections.filter { keys.contains($0.key) }
        }
        .onAppear { ghosttyTTY.refreshIfStale() }
        .onChange(of: model.herdrScanOutcome) { _, _ in ghosttyTTY.refreshIfStale() }
        // A hover highlight belongs to the queue it was drawn on; leaving the queue clears it.
        .onChange(of: model.presentationMode) { _, _ in hoveredCardRow = nil }
    }
}

private extension HerdrOpenAvailability {
    /// Open stays on the card unless herdr's binding or Ghostty's `tty` support rules it out.
    var offersOpen: Bool {
        if case .unavailable = self { return false }
        return true
    }
}
