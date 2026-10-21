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

    /// Every row and heading in display order: a change here is an arrival, departure, or reorder.
    static func layoutKey(_ groups: [QueueGroup]) -> [AnyHashable] {
        groups.flatMap { group in [AnyHashable(group.heading)] + group.items.map { AnyHashable($0.id) } }
    }
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
    // Source values chosen so the captured tones match the reference's greens (109,201,125 and 135,222,154).
    static let sprite = Color(red: 0.133, green: 0.773, blue: 0.369)    // #22c55e body
    static let spriteLight = Color(red: 0.298, green: 0.863, blue: 0.502) // #4cdc80 highlight
    static let seam = Color.white.opacity(0.08)
    /// The well behind "Failed" and nothing else: the one red in the panel (D14).
    static let failure = Color(red: 0.227, green: 0.114, blue: 0.114)  // #3a1d1d
    /// Usage bar fills name their source: Codex blue, Claude orange. Nothing else uses these.
    static let codexUsage = Color(red: 0.231, green: 0.510, blue: 0.965)  // #3b82f6
    static let claudeUsage = Color(red: 0.851, green: 0.467, blue: 0.341) // #d97757

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
    /// Points per cell: the notch's 2pt, or larger for a Settings preview so edges stay crisp.
    var cellSize: CGFloat = Sprite.cell
    static let cell: CGFloat = 2
    /// The fixed leading slot of a queue row, 18x10pt: the widest and tallest kinds, so titles
    /// align whichever kind is chosen. The title follows 6pt after it.
    static let slotWidth = cell * CGFloat(SpriteKind.maximumColumns)
    static let slotHeight = cell * CGFloat(SpriteKind.maximumRows)
    static let slotGap: CGFloat = 6

    var body: some View {
        let frames = kind.frames
        Group {
            if unlit {
                bitmap(frames[0])
            } else if working && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let frame = Int(context.date.timeIntervalSinceReferenceDate * 2) & 1
                    bitmap(frames[frame])
                }
            } else if working {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
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

    private func bitmap(_ rows: [String]) -> some View {
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    let rect = CGRect(x: CGFloat(x) * cellSize, y: CGFloat(y) * cellSize, width: cellSize, height: cellSize)
                    // One tone when unlit: the highlight cells fill like the body and close into it.
                    let tone = unlit ? (body: NotchStyle.well, light: NotchStyle.well) : NotchStyle.spriteColor(color)
                    context.fill(Path(rect), with: .color(ch == "+" ? tone.light : tone.body))
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

/// One usage limit as a vertical bar: a dark-well track filled from the bottom to the used share in
/// its source's hue (Codex blue, Claude orange), with the percent beside it in gray; an empty track
/// and a dash while Herdly has no current reading. A dim caption ahead of the bar names the window
/// ("5h", "7d"); Codex's weekly readout carries none, as it always has. Hidden from VoiceOver; the
/// strip label speaks it.
struct UsageLimitReading: View {
    var percent: Double?
    var percentText: String?
    var caption: String? = nil
    var tint: Color
    static let barWidth: CGFloat = 4
    static let barHeight: CGFloat = 14

    init(_ readout: UsageStripReadout) {
        percent = readout.usedPercent
        percentText = readout.percentText
        caption = readout.caption
        tint = readout.source == .claude ? NotchStyle.claudeUsage : NotchStyle.codexUsage
    }

    private var fraction: CGFloat { CGFloat(min(100, max(0, percent ?? 0)) / 100) }

    var body: some View {
        HStack(spacing: 5) {
            if let caption { Text(caption).foregroundStyle(NotchStyle.dim) }
            ZStack(alignment: .bottom) {
                Capsule().fill(NotchStyle.well)
                Capsule().fill(tint).frame(height: Self.barHeight * fraction)
            }
            .frame(width: Self.barWidth, height: Self.barHeight)
            Text(percentText ?? "—").foregroundStyle(percentText == nil ? NotchStyle.dim : NotchStyle.ink).monospacedDigit()
        }
        .font(NotchStyle.mono(11, .medium))
        .accessibilityHidden(true)
    }
}

/// A control in the panel's own vocabulary: a dark well that inverts to light when pressed and
/// shows a visible ring when it has keyboard focus.
struct NotchButtonStyle: ButtonStyle {
    var emphasized = false
    /// A choice the user made here: drawn in the pressed look until Codex records the answer.
    var selected = false
    @Environment(\.questionCard) private var questionCard
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let inverted = configuration.isPressed || selected
        configuration.label
            .font(questionCard ? QuestionCardStyle.font(11) : NotchStyle.mono(11, emphasized ? .semibold : .regular))
            .foregroundStyle(inverted ? Color.black : (enabled ? NotchStyle.ink : NotchStyle.dim))
            .padding(.horizontal, questionCard ? 9 : 8).padding(.vertical, questionCard ? 5 : 4)
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
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(title, action: action)
            .buttonStyle(NotchButtonStyle(emphasized: emphasized, selected: selected))
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
    }
}

/// One line of text the user types into a card and sends: a typed answer to a Codex question, or a
/// reply to a finished session. Return in the field and the button do the same thing, and an empty
/// or all-space draft sends nothing. Escape follows the panel's one Escape rule from the field (a
/// clicked card steps back to the queue, otherwise the panel collapses) without dismissing
/// anything. The caller owns the text and decides what sending means.
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
    @Environment(\.questionCard) private var questionCard
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(questionCard ? QuestionCardStyle.font(11) : NotchStyle.mono(11)).foregroundStyle(NotchStyle.ink)
                .padding(.horizontal, 8).padding(.vertical, questionCard ? 6 : 4)
                .background(NotchStyle.well, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .onSubmit { if enabled { send() } }
                .onExitCommand(perform: onEscape)
                .accessibilityLabel(fieldLabel)
                .accessibilityHint(hint ?? "")
            NotchButton(title: sendTitle, action: send)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(sendLabel)
        }
        .preference(key: DraftInProgressKey.self, value: text != committedText && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

/// True while any `DraftField` on screen holds unsent text. Only rendered fields report, so text
/// left in a card that has since gone away holds nothing open.
struct DraftInProgressKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// One answer option: its digit in the session's colour, the label in ink. The option the user
/// chose fills with that colour and reads in black, the way a pressed control inverts; the colour
/// says which session's question this is, the fill says what was chosen. Focus ring as elsewhere.
/// Each option spans the column, so the list reads as one stack of answers and every label wraps.
struct OptionButton: View {
    let number: Int
    let label: String
    let tone: (body: Color, light: Color)
    var selected = false
    let action: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let display = QuestionOptionLabel(label)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)").monospacedDigit().foregroundStyle(selected ? Color.black : (enabled ? tone.light : NotchStyle.dim))
                    .frame(width: 14, alignment: .leading)
                Text(display.text).foregroundStyle(selected ? Color.black : (enabled ? NotchStyle.ink : NotchStyle.dim))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if display.recommended {
                    Text("Recommended").font(QuestionCardStyle.font(10))
                        .foregroundStyle(selected ? Color.black.opacity(0.8) : NotchStyle.dim)
                        .fixedSize()
                }
            }
            .font(QuestionCardStyle.font(11, selected ? .semibold : .regular))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? tone.body : NotchStyle.well, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

        }
        .accessibilityValue(selected ? "Selected" : "")
        .buttonStyle(QuestionOptionButtonStyle())
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
    }
}

private struct QuestionOptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // PlainButtonStyle dims disabled selections, obscuring the answer being reviewed.
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Viewed position and answer progress are independent; changing a step only navigates.
struct QuestionStepRail: View {
    let steps: [QuestionSteps.Step]
    let show: (Int) -> Void
    @FocusState private var focusedStep: Int?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(steps) { step in cell(step, inline: true).frame(maxWidth: .infinity, alignment: .leading) }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(steps) { step in cell(step) }
            }
        }
    }

    private func cell(_ step: QuestionSteps.Step, inline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { show(step.id) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(step.state == .current ? NotchStyle.ink :
                        (step.state == .answered ? NotchStyle.dim : NotchStyle.well)).frame(height: 2)
                    Text("\(step.id + 1) \(step.label)")
                        .font(QuestionCardStyle.font(10, step.state == .current ? .semibold : .regular))
                        .foregroundStyle(step.state == .current ? NotchStyle.ink : NotchStyle.dim)
                        .fixedSize(horizontal: inline, vertical: !inline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedStep, equals: step.id)
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(NotchStyle.ink.opacity(focusedStep == step.id ? 0.9 : 0), lineWidth: 1).padding(-2))
            .accessibilityLabel("View question \(step.id + 1): \(step.label)")
            .accessibilityValue(step.state == .current ? "Viewing" : "")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let summary = step.summary {
                    Text(summary).font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if step.canEdit {
                    Button("change") { show(step.id) }
                        .buttonStyle(.plain).underline().fixedSize()
                        .font(QuestionCardStyle.font(10)).foregroundStyle(NotchStyle.dim)
                        .accessibilityLabel("Change answer to \(step.label)")
                }
            }
        }
        .padding(.bottom, 6)
    }
}

/// A disclosure that keeps its content on the panel's left edge. SwiftUI's DisclosureGroup indents
/// and centers what it reveals; here the revealed rows align with everything above them.
/// The label names what pressing it does, so an open disclosure reads "Hide …" (or `expandedTitle`)
/// rather than still offering to show what is already shown.
struct NotchDisclosure<Content: View>: View {
    let title: String
    var expandedTitle: String? = nil
    /// Names the item for VoiceOver, so the spoken label follows the visible one.
    var subject: String? = nil
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content
    @FocusState private var focused: Bool
    private var currentTitle: String {
        guard expanded else { return title }
        if let expandedTitle { return expandedTitle }
        return title.hasPrefix("Show ") ? "Hide " + title.dropFirst(5) : title
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    Text(currentTitle)
                }
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text)
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

/// An Earlier row folded to one line: its title and session name. Opening it shows the identity
/// line, details, and controls. While closed the fold is the row's only pressable surface, so Open
/// Session and Dismiss stay one keypress away for keyboard and VoiceOver users.
struct EarlierFold: View {
    let name: String
    let exception: RowException?
    /// The full spoken heading, since the word is a shortened reading.
    let spoken: String
    let subject: String
    let reduceMotion: Bool
    @Binding var open: Bool
    @FocusState private var focused: Bool
    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { open.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .frame(width: 10)
                    .foregroundStyle(NotchStyle.dim)
                Text(name)
                    .font(NotchStyle.mono(open ? 12 : 11, open ? .semibold : .regular))
                    .foregroundStyle(open ? NotchStyle.ink : NotchStyle.text)
                    .lineLimit(1).truncationMode(.tail)
                if let exception { ExceptionWord(exception: exception) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(.horizontal, -4).padding(.vertical, -2))
        .accessibilityLabel("\(spoken), \(subject)")
        .accessibilityValue(open ? "expanded" : "collapsed")
        .accessibilityHint(open ? "Hides this earlier result's details." : "Shows Open Session and Dismiss for this earlier result.")
        .accessibilityAddTraits(.isHeader)
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
/// "Handed back", "Waiting", and "Status unknown" are plain dim text with no well. Spoken through the
/// row heading, so it is hidden from VoiceOver here.
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
    static let cap: CGFloat = 84
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

/// The hover ground behind a queue row that opens as a card (#320): #1c1c1c with 5pt continuous
/// corners, 6pt outside the row horizontally like the selection ring. Hover only highlights; it never
/// opens, selects, or acts. Under Reduce Motion the ground appears without animation.
struct CardRowHover: ViewModifier {
    let id: AgentAttentionID
    let active: Bool
    @Binding var hovered: AgentAttentionID?
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let lit = active && hovered == id
        content
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(NotchStyle.hoverRow)
                    .padding(.horizontal, -6)
                    .opacity(lit ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: lit)
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

/// Reports the open panel's natural content height so the window can be exactly that tall.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Notch: View {
    @ObservedObject var model: Companion
    /// Observed so the empty queue's reading follows Claude setup changes; read through `model`.
    @ObservedObject var claudeSetup: ClaudeSetupModel
    @FocusState private var headerFocused: Bool
    /// Disclosures the user opened, by the item they belong to; cleared when the item leaves.
    @State private var openDisclosures: Set<String> = []
    /// Typed answers being composed, by call id and question index; sent only on Return or Send.
    @State private var drafts: [String: String] = [:]
    @State private var questionDrafts: [ClaudeQuestionViewStateKey: String] = [:]
    @State private var viewedQuestions: [ClaudeQuestionViewStateKey: Int] = [:]
    /// Multi-select labels are kept in the view until the user presses Send.
    @State private var claudeSelections: [ClaudeQuestionViewStateKey: Set<Int>] = [:]
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

    private func claudeSelectionKey(_ question: AgentQuestion, _ index: Int) -> ClaudeQuestionViewStateKey {
        let requestID: String?
        if let legacy = model.codexQuestion(for: question), case let .daemon(request) = model.route(for: legacy) {
            requestID = "\(request.requestID):\(request.receivedAt)"
        } else {
            requestID = nil
        }
        return ClaudeQuestionViewStateKey(question: question, index: index, requestID: requestID)
    }

    private func questionDraft(_ question: AgentQuestion, index: Int, answer: ChosenAnswer? = nil) -> Binding<String> {
        let key = claudeSelectionKey(question, index)
        return Binding(get: {
            if let text = questionDrafts[key] { return text }
            if case let .text(text) = answer { return text }
            return ""
        }, set: { questionDrafts[key] = $0 })
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
        min(max(viewedQuestions[claudeSelectionKey(question, 0)] ?? model.previewViewedQuestion ?? current, 0), max(0, count - 1))
    }

    private func showQuestion(_ index: Int, of question: AgentQuestion) {
        viewedQuestions[claudeSelectionKey(question, 0)] = index
    }

    @ViewBuilder
    private func questionNavigation(_ question: AgentQuestion) -> some View {
        let prompts = questionPrompts(question)
        let current = model.codexQuestion(for: question).map { model.progress(for: $0).questionIndex } ?? 0
        let viewed = viewedQuestion(question, current: current, count: prompts.count)
        if prompts.count > 1 {
            if viewed > 0 {
                NotchButton(title: "← \(QuestionSteps.label(prompts[viewed - 1], index: viewed - 1))") {
                    showQuestion(viewed - 1, of: question)
                }
                .accessibilityLabel("Previous question: \(QuestionSteps.label(prompts[viewed - 1], index: viewed - 1))")
            }
            if viewed + 1 < prompts.count {
                NotchButton(title: "\(QuestionSteps.label(prompts[viewed + 1], index: viewed + 1)) →") {
                    showQuestion(viewed + 1, of: question)
                }
                .accessibilityLabel("Next question: \(QuestionSteps.label(prompts[viewed + 1], index: viewed + 1))")
            }
        }
    }

    private func toggleClaudeSelection(_ question: AgentQuestion, index: Int, option: Int) {
        let key = claudeSelectionKey(question, index)
        var selected = claudeSelections[key] ?? []
        if !selected.insert(option).inserted { selected.remove(option) }
        claudeSelections[key] = selected
    }

    private var sessionNames: [AgentSessionIdentity: String] {
        var names = model.claudeSessionNames
        for (session, name) in model.threadNames {
            names[CodexAttentionAdapter.session(session, surface: .desktop)] = name
            names[CodexAttentionAdapter.session(session, surface: .cli)] = name
        }
        return names
    }

    private var strip: AgentStripSummary {
        AgentStripSummary.make(items: model.orderedAgentAttentionItems,
                               testPending: model.attention.pending && !model.desktopForeground,
                               names: sessionNames)
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

    @ViewBuilder
    private func agentQuestionBody(_ question: AgentQuestion, subject: String) -> some View {
        if question.identity.session.source == .claude {
            claudeQuestionBody(question, subject: subject)
        } else if let legacy = model.codexQuestion(for: question) {
            questionBody(legacy, subject: subject)
        } else if question.prompts.isEmpty {
            Text("Codex asked a question Herdly could not read; answer it in Codex.")
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
        } else {
            // Not in the queue Herdly answers from, so nothing here is pressable.
            readOnlyQuestions(question.prompts, agent: "Codex", question: question, subject: subject,
                              tone: spriteColor(for: question.identity.session))
        }
    }

    /// Unsupported routes can browse the questions, but never acquire answer controls.
    @ViewBuilder
    private func readOnlyQuestions(_ prompts: [QuestionPrompt], agent: String, question: AgentQuestion, subject: String,
                                   tone: Int) -> some View {
        Text(QuestionSteps.answerElsewhere(count: prompts.count, agent: agent))
            .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
        let viewed = viewedQuestion(question, current: 0, count: prompts.count)
        questionHead(prompts, question: question, current: 0, viewed: viewed, currentStatus: nil) { _ in nil }
        if prompts.indices.contains(viewed) {
            prompt(prompts[viewed], subject: subject, tone: tone, agent: agent)
        }
    }

    @ViewBuilder
    private func claudeQuestionBody(_ question: AgentQuestion, subject: String) -> some View {
        let controls = model.canAnswerAgentQuestion(question)
        let tone = spriteColor(for: question.identity.session)
        if question.prompts.isEmpty {
            Text("Claude asked a question Herdly could not read; answer it in Claude.")
                .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
        } else if !controls {
            readOnlyQuestions(question.prompts, agent: "Claude", question: question, subject: subject, tone: tone)
        } else {
            // Claude's answer control takes exactly one question (`canAnswerAgentQuestion`).
            ForEach(Array(question.prompts.enumerated()), id: \.offset) { index, prompt in
                questionHead(question.prompts, question: question, current: index, viewed: index) { _ in nil }
                if let text = prompt.question { questionText(text) }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { option, label in
                        if prompt.multiSelect {
                            let selected = claudeSelections[claudeSelectionKey(question, index)]?.contains(option) == true
                            OptionButton(number: option + 1, label: label, tone: NotchStyle.spriteColor(tone), selected: selected) {
                                toggleClaudeSelection(question, index: index, option: option)
                            }
                            .accessibilityLabel("Select \(option + 1): \(label), for \(subject)")
                        } else {
                            OptionButton(number: option + 1, label: label, tone: NotchStyle.spriteColor(tone)) {
                                model.answerClaudeQuestion(question, kind: .option, answer: label)
                            }
                            .accessibilityLabel("Answer \(option + 1): \(label), for \(subject)")
                        }
                    }
                }
                if prompt.multiSelect {
                    let selected = claudeSelections[claudeSelectionKey(question, index)] ?? []
                    NotchButton(title: "Send") {
                        let labels = selected.sorted().compactMap { prompt.options.indices.contains($0) ? prompt.options[$0] : nil }
                        model.answerClaudeQuestion(question, kind: .multiSelect, answer: labels.joined(separator: ", "))
                        claudeSelections[claudeSelectionKey(question, index)] = nil
                    }
                    .disabled(selected.isEmpty)
                    .accessibilityLabel("Send selected answers for \(subject)")
                }
                DraftField(placeholder: prompt.options.isEmpty ? "Type your answer" : "Or type another answer",
                           text: questionDraft(question, index: index), sendTitle: "Send",
                           fieldLabel: "Typed answer for \(subject)", sendLabel: "Send typed answer for \(subject)",
                           onEscape: model.escape) {
                    model.answerClaudeQuestion(question, kind: .text,
                                               answer: questionDrafts[claudeSelectionKey(question, index)] ?? "")
                    questionDrafts[claudeSelectionKey(question, index)] = nil
                }
            }
        }
    }

    @ViewBuilder
    private func questionHead(_ prompts: [QuestionPrompt], question: AgentQuestion, current: Int, viewed: Int,
                              editable: Bool = false, currentStatus: String? = "Answering now",
                              answer: (Int) -> ChosenAnswer?) -> some View {
        if prompts.count > 1 {
            let steps = QuestionSteps.make(prompts, current: current, viewed: viewed, editable: editable,
                                           currentStatus: currentStatus, answer: answer)
            QuestionStepRail(steps: steps.steps) { showQuestion($0, of: question) }
        } else if let only = prompts.first, only.header?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            Text(QuestionSteps.label(only, index: 0)).font(QuestionCardStyle.font(10)).foregroundStyle(NotchStyle.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func questionText(_ text: String) -> some View {
        Text(text).font(QuestionCardStyle.font(12)).lineSpacing(2).foregroundStyle(NotchStyle.ink).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
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
                .accessibilityLabel("Open card: \(rowHeading(item, countdown: countdown))")
                .accessibilityHint("Shows this request alone. Escape or Queue returns to the queue.")
        } else {
            header()
        }
    }

    /// Makes a working row's header line the click target that opens or closes it in place (#319).
    /// Like `cardOpener` it is left out of Tab order; the arrow selection and Return reach it.
    private func runningOpener<Header: View>(_ item: AgentAttentionItem, open: Bool,
                                             @ViewBuilder header: () -> Header) -> some View {
        Button { model.toggleRunningRow(item.id) } label: { header().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel("Open details: \(rowHeading(item))")
            .accessibilityValue(open ? "expanded" : "collapsed")
            .accessibilityHint(open ? "Hides this session's details. Escape also closes them."
                                    : "Shows what the session is doing, your last prompt, where it runs, and Open.")
    }

    /// The opened running row's details (#319, F3): "now", "you" and "where" (`RunningRowDetails`),
    /// any line saying why Open is not offered, then the prompt's disclosure and Open. Inset to the
    /// title; Open still revalidates its target through the session's usual route.
    @ViewBuilder
    private func runningDetails(_ item: AgentAttentionItem, subject: String, herdr: HerdrOpenAvailability,
                                codexOpen: Bool) -> some View {
        if let running = item.running {
            let details = RunningRowDetails.make(running, host: model.lastSeenHost(for: item.session))
            let promptKey = "prompt:\(item.session.session)"
            let agent = item.session.source.displayName
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
                runningLine("where", details.place, tone: NotchStyle.text)
                if item.session.source == .codex, case let .unavailable(cause) = herdr {
                    herdrReasonLine(item, cause: cause)
                } else if item.session.source == .codex, let reason = model.terminalOpenLine(item.session) {
                    terminalOpenLine(item, reason: reason)
                }
                if item.session.source == .claude { claudeReturnMessage(item) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let you = details.you, let title = you.disclosureTitle {
                        // The toggle only; what it reveals goes below the whole line, not beside Open.
                        NotchDisclosure(title: title, expandedTitle: "Show less", subject: subject,
                                        expanded: disclosure(promptKey)) { EmptyView() }
                    }
                    Spacer(minLength: 6)
                    if item.session.source == .codex, codexOpen {
                        NotchButton(title: "Open", emphasized: true) { model.openAgent(item.session) }
                            .disabled(model.openingTask)
                            .accessibilityLabel("Open Session: \(subject)")
                            .accessibilityHint("Open this session in Codex.")
                    }
                    claudeReturnControl(item, subject: subject, emphasized: true, openTitle: "Open")
                    claudeRemoveControl(item, subject: subject)
                }
                .padding(.top, 4)
                if let you = details.you, you.disclosureTitle != nil, openDisclosures.contains(promptKey) {
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
        }
    }

    private static let runningLabelWidth: CGFloat = 40
    private static let runningLabelGap: CGFloat = 10

    /// One labelled detail line: an 11pt dim label in a 40pt column, then the 11pt mono value at a
    /// 16pt line height. Read by VoiceOver as one element, label first.
    private func runningLine(_ label: String, _ value: String, tone: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.runningLabelGap) {
            Text(label).foregroundStyle(NotchStyle.dim).frame(width: Self.runningLabelWidth, alignment: .leading)
            Text(value).foregroundStyle(tone).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(NotchStyle.mono(11))
        .accessibilityElement(children: .combine)
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

    private func rowNoteText(_ note: RowNote, questionCard: Bool) -> some View {
        Text(note.text).font(questionCard ? QuestionCardStyle.font(11) : NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
            .lineLimit(1).truncationMode(.tail)
    }

    /// The "‹ Queue" bar above a clicked card: back to the queue, nothing dismissed. No stepper (D19).
    private var clickedCardBar: some View {
        HStack(spacing: 0) {
            NotchButton(title: "‹ Queue", action: model.backToQueue)
                .accessibilityLabel("Back to queue")
                .accessibilityHint("Returns to the full queue. Nothing is dismissed.")
            Spacer(minLength: 0)
        }
    }

    /// One approval card body (#320) for the spotlight and the clicked card, Codex and Claude alike,
    /// read top to bottom and inset to the title: the agent's ask, the action and its full command,
    /// where it runs, the raw request when it adds detail, then where the request stands and its
    /// controls. Only the user's own Approve or Deny decides; the countdown only reads the deadline.
    @ViewBuilder
    private func approvalCardBody(_ request: SpotlightRequest, item: AgentAttentionItem, subject: String,
                                  herdr: HerdrOpenAvailability, codexOpen: Bool) -> some View {
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
                NotchDisclosure(title: "Show full request", subject: subject, expanded: disclosure("request:\(item.session.session)")) {
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
                if item.kind == .actionableApproval, let approval = item.approval, !model.canDecideAgent(approval) {
                    Text("Claude's native permission prompt remains available.")
                        .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                }
                claudeReturnMessage(item)
            } else if case let .unavailable(cause) = herdr {
                herdrReasonLine(item, cause: cause)
            } else if let reason = model.terminalOpenLine(item.session) {
                terminalOpenLine(item, reason: reason)
            }
            if item.kind == .handedBackApproval {
                HStack(spacing: 6) {
                    Spacer(minLength: 6)
                    approvalOpenControl(item, stage: .handedBack, subject: subject, codexOpen: codexOpen)
                }
            } else {
                // Whether this source takes a decision from Herdly, read when the card renders; the
                // per-second clock below only ever narrows it (at the deadline Approve and Deny
                // disable), and each decide path re-checks the request before writing anything.
                let decidable = item.approval.map { approval in
                    item.session.source == .claude ? model.canDecideAgent(approval)
                        : item.session.source == .codex && item.session.surface == .cli
                } ?? false
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let stage = ApprovalCardStage(item, now: context.date.timeIntervalSince1970) ?? .expired
                    VStack(alignment: .leading, spacing: 10) {
                        if let countdown = stage.countdown { ApprovalCountdownRow(countdown: countdown) }
                        HStack(spacing: 6) {
                            if decidable && stage.showsDecisionControls, let approval = item.approval {
                                let agent = item.session.source.displayName
                                NotchButton(title: "Approve", emphasized: true) { model.decideAgent(approval, as: .allowOnce) }
                                    .disabled(!stage.offersDecision)
                                    .accessibilityLabel("Approve this request once: \(subject)")
                                    .accessibilityHint("Approves this \(agent) \(item.session.source == .claude ? Self.claudeRequestKind(approval) : "permission") request once.")
                                NotchButton(title: "Deny") { model.decideAgent(approval, as: .deny) }
                                    .disabled(!stage.offersDecision)
                                    .accessibilityLabel("Deny: \(subject)")
                                    .accessibilityHint("Denies this \(agent) \(item.session.source == .claude ? Self.claudeRequestKind(approval) : "permission") request.")
                            }
                            Spacer(minLength: 6)
                            approvalOpenControl(item, stage: stage, subject: subject, codexOpen: codexOpen)
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
    private func approvalOpenControl(_ item: AgentAttentionItem, stage: ApprovalCardStage, subject: String,
                                     codexOpen: Bool) -> some View {
        let title = stage.openTitle(for: item.session.source)
        let emphasized = stage == .handedBack
        if item.session.source == .codex, codexOpen {
            NotchButton(title: title, emphasized: emphasized) {
                if stage != .handedBack, let approval = item.approval {
                    model.openAgentApproval(approval)
                } else {
                    model.openAgent(item.session)
                }
            }
            .disabled(model.openingTask)
            .accessibilityLabel("Open Session: \(subject)")
            .accessibilityHint(stage == .handedBack ? "Open this session in Codex." : "Hands this request back to Codex's own prompt.")
        }
        claudeReturnControl(item, subject: subject, emphasized: emphasized, openTitle: title)
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

    @ViewBuilder
    private func prompt(_ prompt: QuestionPrompt, subject: String = "", tone: Int = 0, agent: String = "Codex",
                        pick: Int? = nil, typed: String? = nil, choose: ((Int) -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = prompt.question { questionText(question) }
            else { Text("Herdly could not read this question; continue in \(agent).")
                .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(prompt.options.enumerated()), id: \.offset) { offset, label in
                    OptionButton(number: offset + 1, label: label, tone: NotchStyle.spriteColor(tone), selected: pick == offset) {
                        choose?(offset)
                    }
                    .disabled(choose == nil)
                    .accessibilityLabel("Option \(offset + 1): \(label), for \(subject)")
                    .accessibilityHint(choose == nil ? "Reference only." : "Choose this answer.")
                }
            }
            if let typed {
                Text("Typed: \(typed)").font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if prompt.truncated {
                Text("Shortened; the full question is in \(agent).").font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
            }
        }
    }

    @ViewBuilder
    private func daemonPrompt(_ prompt: AppServerQuestion, index: Int, question: AgentQuestion, subject: String,
                              tone: Int, answer: ChosenAnswer?, enabled: Bool,
                              choose: @escaping (ChosenAnswer) -> Void) -> some View {
        let pick: Int? = { if case let .option(option) = answer { return option }; return nil }()
        let shown = prompt.displayPrompt
        VStack(alignment: .leading, spacing: 10) {
            if let text = shown.question { questionText(text) }
            if prompt.isSecret {
                Text("Codex asked for a secret; answer it in Codex.").font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(shown.options.enumerated()), id: \.offset) { offset, label in
                        OptionButton(number: offset + 1, label: label, tone: NotchStyle.spriteColor(tone), selected: pick == offset) {
                            choose(.option(offset))
                        }
                        .disabled(!enabled)
                        .accessibilityLabel("Answer \(offset + 1): \(label), for \(subject)")
                    }
                }
                if prompt.takesText {
                    let binding = questionDraft(question, index: index, answer: answer)
                    let committed: String? = { if case let .text(text) = answer { return text }; return nil }()
                    DraftField(placeholder: prompt.isOther ? "Or type another answer" : "Type your answer",
                               text: binding, sendTitle: "Send",
                               fieldLabel: "Typed answer for \(subject)", sendLabel: "Send typed answer for \(subject)",
                               committedText: committed, onEscape: model.escape) {
                        choose(.text(binding.wrappedValue))
                    }
                    .disabled(!enabled)
                }
            }
        }
    }

    /// The daemon card's status sentence: which path, and where the answer stands.
    private func daemonStatus(_ question: AttentionQuestion, request: AppServerQuestionRequest?, progress: QuestionAnswerProgress) -> String? {
        switch progress.phase {
        case .ready:
            // Nothing sent yet: the controls speak for themselves. The path is named once something is.
            return nil
        case .sending: return "Sending to Codex's daemon…"
        case .sent: return "Answered through Codex's daemon. Waiting for Codex to record it."
        case .unconfirmed: return "Answered through Codex's daemon, but Codex has not recorded an answer. Check Codex; Herdly will not resend."
        case let .failed(reason): return reason
        case .pickedInCodex: return "Your pick opened Codex; Codex's daemon now holds the question, choose again here or in Codex."
        }
    }

    /// Why the card is not on the daemon path, for the fallback sentences.
    private var noDaemon: String {
        model.daemonConnected ? "Codex's daemon does not hold this question" : "No Codex daemon"
    }

    /// The card's one sentence about where the answer stands. Every phase names what Herdly knows
    /// and nothing more; a relayed key is never described as an answer Codex has.
    private func questionStatus(_ question: AttentionQuestion, progress: QuestionAnswerProgress, total: Int) -> String? {
        // The card's one reason line already says to answer it in Codex (`herdrReasonLine`, `terminalOpenLine`).
        if unrelayedQuestion(question) { return nil }
        let index = progress.questionIndex
        let destination = HerdrPresentation.keyDestination(for: model.route(for: question))
        switch progress.phase {
        case .ready:
            if index >= question.prompts.count { return "Codex is on question \(index + 1) of \(total). Continue in Codex." }
            if case let .continueInCodex(reason) = QuestionAnswerProgress.offer(question, at: index) { return reason }
            if case let .relayUnavailable(reason) = model.route(for: question) { return HerdrPresentation.relayUnavailableLine(for: reason) }
            if question.source == .cli, !model.showsOptionControls(for: question) { return "\(noDaemon); enable Ghostty controls to answer from here, or answer in Codex." }
            // Nothing sent yet: no sentence. The path is named once something is.
            return nil
        case .sending:
            return "Sending the key to \(destination.place)…"
        case .sent:
            return "Sent \(progress.picks[index].map { $0 + 1 } ?? 0) as a key to \(destination.place). Waiting for Codex to record it."
        case .unconfirmed:
            return "Sent \(progress.picks[index].map { $0 + 1 } ?? 0) as a key to \(destination.place), but Codex has not recorded an answer. Check the \(destination.noun); Herdly will not resend."
        case let .failed(reason):
            return reason
        case .pickedInCodex:
            return "Choose it in Codex to answer."
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

    @ViewBuilder
    private func questionBody(_ question: AttentionQuestion, subject: String) -> some View {
        let agent = CodexAttentionAdapter.question(from: question)
        let progress = model.progress(for: question)
        let index = progress.questionIndex
        let route = model.route(for: question)
        let tone = spriteColor(for: agent.identity.session)
        let prompts = questionPrompts(agent)
        let viewed = viewedQuestion(agent, current: index, count: prompts.count)
        if case let .daemon(request) = route, !request.questions.isEmpty {
            let editable = progress.phase == .ready
            questionHead(prompts, question: agent, current: index, viewed: viewed, editable: editable,
                         currentStatus: viewed == index ? "Answering now" : "Not answered yet", answer: progress.answer(for:))
            daemonPrompt(request.questions[viewed], index: viewed, question: agent, subject: subject, tone: tone,
                         answer: progress.answer(for: viewed), enabled: editable && viewed <= index) { answer in
                model.answerThroughDaemon(question, question: viewed, answer: answer, expectedRequest: request)
            }
            if let status = daemonStatus(question, request: request, progress: progress) {
                Text(status).font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
            }
        } else if prompts.isEmpty {
            Text("Codex asked a question Herdly could not read; answer it in Codex.")
                .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
        } else {
            let offer = QuestionAnswerProgress.offer(question, at: index)
            let interactive: Bool = {
                guard viewed == index, model.showsOptionControls(for: question), case .options = offer else { return false }
                switch progress.phase {
                case .ready, .pickedInCodex: return true
                case .sending, .sent, .unconfirmed, .failed: return false
                }
            }()
            questionHead(prompts, question: agent, current: index, viewed: viewed,
                         currentStatus: progress.phase == .ready ? (viewed == index ? "Answering now" : "Codex is here now") : nil,
                         answer: progress.answer(for:))
            prompt(prompts[viewed], subject: subject, tone: tone, pick: progress.picks[viewed], typed: progress.texts[viewed],
                   choose: interactive ? { option in
                       model.chooseOption(question, question: viewed, option: option)
                          } : nil)
            if route == .daemonAnswered, let status = daemonStatus(question, request: nil, progress: progress) {
                Text(status).font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
        if case .daemon = route {} else if route != .daemonAnswered,
            let status = questionStatus(question, progress: progress, total: max(question.questionCount, prompts.count)) {
            Text(status).font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The completion card's own sentence about the reply the user sent from it. Every phase says
    /// what Herdly did and nothing more; a reply the daemon took, or text typed into the session's tab
    /// (ADR 0017), is never called an answer the agent has.
    private func replyStatus<ID>(_ progress: ReplyProgress<ID>, target: SessionReplyTarget,
                                 agent: AgentSource = .codex) -> String? {
        let name = agent == .claude ? "Claude" : "Codex"
        let typed = progress.route.map { $0 != .daemon } ?? false
        switch progress.phase {
        case .ready:
            if case let .unavailable(reason) = target { return SessionReplyPolicy.message(for: reason, agent: agent) }
            return nil
        case .sending:
            return typed ? "Typing your reply into the session…" : "Sending your reply to Codex's daemon…"
        case let .sent(text, _):
            if progress.composerMayHoldText {
                return "Typed “\(text)”, but Herdly couldn't press Return. The text may be waiting in Codex's composer; Herdly won't press Return later."
            }
            return typed ? "Typed “\(text)”. Waiting for \(name) to start the turn." : "Sent “\(text)”. Waiting for Codex to record the turn."
        case let .working(text):
            // A Codex reply's turn may already have finished (#271), so its card never claims the
            // session is working. Claude cards keep their sentence.
            guard agent == .codex else { return "Sent “\(text)”. \(name) started a turn; this session is working again." }
            return "Sent “\(text)”. Codex started a turn after your reply."
        case let .unconfirmed(text, _):
            return typed ? "Typed “\(text)”, but \(name) has not started a turn. Check the session; Herdly will not resend."
                : "Sent “\(text)”, but Codex has not started a turn. Check Codex; Herdly will not resend."
        case let .failed(reason):
            return reason
        }
    }

    /// A Claude completion card's reply (ADR 0017): typed into the session's bound tab, shown only
    /// while a host that types replies is on. The same one-reply rules as a Codex card.
    @ViewBuilder
    private func claudeReplyBody(_ outcome: AgentOutcome, target: SessionReplyTarget, subject: String) -> some View {
        let progress = model.claudeReply(for: outcome)
        let key = "reply:\(outcome.session.sourceScope):\(outcome.session.session):\(outcome.turn)"
        DraftField(placeholder: "Reply to this session", text: draft(key), sendTitle: "Send",
                   fieldLabel: "Reply to \(subject)", sendLabel: "Send reply to \(subject)",
                   hint: "Types a follow-up prompt into this session's tab.", onEscape: model.escape) {
            model.sendClaudeReply(outcome, text: drafts[key] ?? "")
            if model.claudeReply(for: outcome).phase != .ready { drafts[key] = nil }
        }
        .disabled(!target.isReachable || progress.phase != .ready)
        if let status = replyStatus(progress, target: target, agent: .claude) {
            Text(status).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One follow-up prompt for a finished session, sent to that session and no other. The field is
    /// disabled whenever Herdly cannot reach the session or has already sent this card's one reply;
    /// the sentence below says which. Sending never acknowledges the completion.
    @ViewBuilder
    private func replyBody(_ completion: AttentionCompletion, subject: String) -> some View {
        let progress = model.reply(for: completion)
        let target = model.replyTarget(for: completion)
        let key = "reply:\(completion.session.uuidString):\(completion.turn.uuidString)"
        DraftField(placeholder: "Reply to this session", text: draft(key), sendTitle: "Send",
                   fieldLabel: "Reply to \(subject)", sendLabel: "Send reply to \(subject)",
                   hint: "Sends a follow-up prompt to this session.", onEscape: model.escape) {
            // The typed text is cleared only once the send is under way; a refusal keeps it to edit.
            model.sendReply(to: completion, text: drafts[key] ?? "")
            if model.reply(for: completion).phase != .ready { drafts[key] = nil }
        }
        .disabled(!target.isReachable || progress.phase != .ready)
        // ADR 0017: a session another host may hold gets that host's line through its typed route.
        if let status = replyStatus(progress, target: target) {
            Text(status).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

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
        let codexOpen = herdr.offersOpen && model.offersTerminalOpen(item.session)
        let spotlit = isSpotlight(item)
        let earlierOpen = disclosure(earlierKey(item))
        let collapsed = item.kind == .earlierOutcome && !earlierOpen.wrappedValue && !spotlit
        let selected = model.presentationMode.showsAll && model.queueSelection.selected == item.id
        // In the open queue a row's heading line is 26pt tall, so one-line rows stack like the
        // artboards; the space it adds above and below the text replaces part of the row spacing.
        let inQueue = model.presentationMode.showsAll
        // #319: a working row in the open queue is its header line alone until it is opened in place.
        let runningRow = inQueue && item.kind == .running
        let runningOpen = runningRow && model.openRunningRow.isOpen(item.id)
        let bodySpacing: CGFloat = item.kind == .question ? 14 : 8
        // #320: an approval row in the open queue is its header line alone; its body is the card.
        let approvalRow = item.kind == .actionableApproval || item.kind == .handedBackApproval
        // "Not delivered · answer in Claude" keeps its Open inline on the row line, before the age.
        let noteOpen = inQueue && approvalRow && rowNote(item)?.offersOpen == true
        VStack(alignment: .leading, spacing: inQueue ? bodySpacing - 5 : bodySpacing) {
            // Every row is headed by its session's mark and name; the mark steps only while the
            // session is working, and a word appears only when the row is off its normal path.
            let folded = item.kind == .earlierOutcome && !spotlit
            let working = item.running?.status == .working
            if item.kind == .question {
                cardOpener(item) { questionHeader(item, inQueue: inQueue) }
                    .modifier(CardRowHover(id: item.id, active: opensAsCard(item), hovered: $hoveredCardRow,
                                           reduceMotion: model.reduceMotion))
            } else {
                Group {
                    if item.kind == .actionableApproval && inQueue {
                        // A live approval's "Ns left" steps once a second, seen and spoken. The
                        // spotlight and clicked card show it as their countdown row instead.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let countdown = QueueRowPresentation.countdown(item, now: context.date.timeIntervalSince1970)
                            cardOpener(item, countdown: countdown) {
                                headerLine(item, folded: folded, working: working, earlierOpen: earlierOpen, countdown: countdown)
                            }
                        }
                    } else if runningRow {
                        runningOpener(item, open: runningOpen) {
                            headerLine(item, folded: false, working: working, earlierOpen: earlierOpen, countdown: nil)
                        }
                    } else if noteOpen {
                        // Open sits outside the row's own button, so the two never nest.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            cardOpener(item) {
                                headerLine(item, folded: false, working: working, earlierOpen: earlierOpen, countdown: nil,
                                           showsAge: false)
                            }
                            claudeReturnControl(item, subject: subject, openTitle: "Open")
                            rowAge(item)
                        }
                    } else {
                        cardOpener(item) {
                            headerLine(item, folded: folded, working: working, earlierOpen: earlierOpen, countdown: nil,
                                       cardHeader: spotlit && approvalRow)
                        }
                    }
                }
                .frame(minHeight: inQueue ? 26 : nil)
                .modifier(CardRowHover(id: item.id, active: opensAsCard(item), hovered: $hoveredCardRow,
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
                    approvalCardBody(card, item: item, subject: subject, herdr: herdr, codexOpen: codexOpen)
                }
            } else if !collapsed || rowNote(item)?.offersOpen == true {
                VStack(alignment: .leading, spacing: bodySpacing) {
                    if let note = rowNote(item), note.offersOpen {
                        // "Not delivered · answer in Claude": Open takes the user to the session to answer there.
                        HStack(spacing: 6) { claudeReturnControl(item, subject: subject) }
                    }
                    if !collapsed {
                        if item.kind != .question, let directory = spotlightDetails?.directory {
                            directoryLine(directory)
                        }
                        switch item.kind {
                        case .actionableApproval, .handedBackApproval:
                            // Approval rows render the approval card body instead (#320).
                            EmptyView()
                        case .outcome, .earlierOutcome:
                            if item.outcome?.uncertain == true {
                                Text("Queued before Herdly last started. You may already have seen this result; Herdly cannot verify it.")
                                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
                            }
                            if let prompt = spotlightDetails?.originalPrompt {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Original prompt").font(NotchStyle.mono(11, .semibold)).foregroundStyle(NotchStyle.ink)
                                    Text(prompt).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if item.session.source == .claude {
                                claudeReturnMessage(item)
                            }
                        case .question:
                            if let question = item.question { agentQuestionBody(question, subject: subject) }
                            if item.session.source == .claude {
                                claudeReturnMessage(item)
                            }
                            if item.session.source == .claude, herdr == .notInHerdr, let question = item.question,
                               !model.isBackgroundClaudeSession(item.session),
                               !model.canAnswerAgentQuestion(question) {
                                Text("The exact Claude tab cannot be opened until Herdly can verify it; continue in Claude.")
                                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                            }
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
                            if let question = item.question {
                                questionNavigation(question)
                                Spacer(minLength: 6)
                            }
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
                                if item.session.source == .claude {
                                    claudeReturnControl(item, subject: subject, emphasized: true)
                                } else if item.session.surface == .cli && !model.cliTerminalHostOn {
                                    NotchButton(title: "Set up Ghostty", emphasized: true, action: model.showControls)
                                        .accessibilityLabel("Set up Ghostty: \(subject)")
                                        .accessibilityHint("Opens Herdly controls to enable Ghostty controls.")
                                } else if codexOpen {
                                    NotchButton(title: "Open Session", emphasized: true) { model.openAgent(item.session) }
                                        .disabled(model.openingTask)
                                        .accessibilityLabel("Open Session: \(subject)")
                                        .accessibilityHint("Answer the question in Codex's own panel.")
                                }
                                // Dismiss only clears the card; nothing is sent, so the agent's own question stays authoritative.
                                NotchButton(title: "Dismiss") { model.dismissAgent(item.id) }
                                    .accessibilityLabel("Dismiss question: \(subject)")
                            case .outcome, .earlierOutcome:
                                if item.session.source == .codex, codexOpen {
                                    NotchButton(title: "Open Session") { model.openAgent(item.session) }
                                        .disabled(model.openingTask)
                                        .accessibilityLabel("Open Session: \(subject)")
                                        .accessibilityHint("Open this session in Codex.")
                                }
                                claudeReturnControl(item, subject: subject)
                                NotchButton(title: "Dismiss") { model.dismissAgent(item.id) }
                                    .accessibilityLabel("Dismiss completion: \(subject)")
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
                        if let outcome = item.outcome, outcome.session.source == .codex, let completion = model.codexCompletion(for: outcome),
                           completion.source == .cli {
                            replyBody(completion, subject: subject)
                        }
                        if let outcome = item.outcome, let target = model.claudeReplyTarget(for: outcome) {
                            claudeReplyBody(outcome, target: target, subject: subject)
                        }
                        if item.outcome != nil, let spotlightDetails {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Final response").font(NotchStyle.mono(11, .semibold)).foregroundStyle(NotchStyle.ink)
                                switch spotlightDetails.response {
                                case let .available(preview): Text(preview.text).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                case let .unavailable(reason): Text(reason).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                                case nil: EmptyView()
                                }
                            }
                        }
                    }
                }
                // Room below a row's details before the next row's 26pt heading line.
                .padding(.bottom, inQueue ? 8 : 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rowHeading(item)), \(subject)")
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
        // The keyboard selection reuses the focus ring's vocabulary around the whole row.
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(selected ? 0.9 : 0), lineWidth: 1.5).padding(.horizontal, -6).padding(.vertical, -4))
        .environment(\.questionCard, item.kind == .question)
    }

    /// The spoken heading (`QueueRowPresentation.spokenHeading`): name, place, any row note, the
    /// full state the visual word shortens, and a live approval's seconds left.
    private func rowHeading(_ item: AgentAttentionItem, countdown: ApprovalCountdown? = nil) -> String {
        QueueRowPresentation.spokenHeading(item, name: QueueRowPresentation.sessionName(item.session, names: sessionNames),
                                           place: model.rowPlace(for: item), note: rowNote(item), countdown: countdown)
    }

    /// A non-question row's heading line (D17): sprite, name, dim "· place" (it truncates first),
    /// then at most one word or a live approval's "Ns left", then the age lane. A single approval
    /// card's header (`cardHeader`, #320) says its kind instead: the "Approve" pill or "Handed back",
    /// then the dim source ("CLI", "Claude"); queue rows keep D17 and name neither. `showsAge` false
    /// leaves the age lane to the caller, which puts a row note's Open before it.
    private func headerLine(_ item: AgentAttentionItem, folded: Bool, working: Bool, earlierOpen: Binding<Bool>,
                            countdown: ApprovalCountdown?, cardHeader: Bool = false, showsAge: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if folded {
                earlierToggle(item, open: earlierOpen)
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Sprite.slotGap) {
                    spriteSlot(working: working, color: spriteColor(for: item.session))
                    rowHeader(item, countdown: countdown)
                }
                if let countdown {
                    SecondsLeftPill(countdown: countdown)
                } else if cardHeader, let stage = ApprovalCardStage(item, now: Date().timeIntervalSince1970) {
                    // The word depends only on whether the request was handed back, not on the clock.
                    ApprovalKindWordView(word: stage.kindWord)
                    Text(item.session.cardSourceLabel)
                        .font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.dim)
                        .lineLimit(1).fixedSize()
                        .accessibilityLabel(item.session.sourceLabel)
                } else if let exception = QueueRowPresentation.exception(item) {
                    ExceptionWord(exception: exception)
                }
            }
            if showsAge { rowAge(item) }
        }
    }

    private func earlierKey(_ item: AgentAttentionItem) -> String { "earlier:\(item.id)" }

    /// A row's leading mark: the chosen sprite in a fixed slot as wide as the widest kind and as tall
    /// as the tallest, leading-aligned and centred in it, so titles line up whichever kind is chosen.
    /// The slot's bottom sits on the title's baseline, which keeps its centre where the old 12x8pt
    /// sprite's was.
    private func spriteSlot(working: Bool, color: Int, unlit: Bool = false) -> some View {
        Sprite(kind: model.appearance.sprite, working: working, reduceMotion: model.reduceMotion,
               color: color, unlit: unlit)
            .frame(width: Sprite.slotWidth, height: Sprite.slotHeight, alignment: .leading)
    }

    private func earlierToggle(_ item: AgentAttentionItem, open: Binding<Bool>) -> some View {
        EarlierFold(name: QueueRowPresentation.sessionName(item.session, names: sessionNames),
                    exception: QueueRowPresentation.exception(item), spoken: rowHeading(item),
                    subject: rowSubject(item), reduceMotion: model.reduceMotion, open: open)
    }

    private func questionHeader(_ item: AgentAttentionItem, inQueue: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: Sprite.slotGap) {
                    spriteSlot(working: false, color: spriteColor(for: item.session))
                    Text(QueueRowPresentation.sessionName(item.session, names: sessionNames))
                        .font(QuestionCardStyle.font(12, .semibold)).foregroundStyle(NotchStyle.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                .layoutPriority(1)
                if let note = rowNote(item) {
                    rowNoteText(note, questionCard: true)
                } else if let place = model.rowPlace(for: item) {
                    Text(place).font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
                        .lineLimit(1).help(place)
                }
                Spacer(minLength: 0)
                rowAge(item)
            }
            .frame(minHeight: inQueue ? 26 : nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowHeading(item))
            .accessibilityAddTraits(.isHeader)
            let directory = model.rowDirectory(for: item)
            let source = item.session.sourceLabel
            Text(source + (directory.map { " · " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""))
                .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
                .padding(.leading, Sprite.slotWidth + Sprite.slotGap)
                .fixedSize(horizontal: false, vertical: true)
                .help(directory ?? source)
        }
    }

    /// The row's name, then "· project @ branch" (in the profile's label format) when Herdly has seen
    /// the working directory. The place takes the free width and tail-truncates first, so the name
    /// and any word after it stay whole. Presentation only; nothing here selects a target.
    private func rowHeader(_ item: AgentAttentionItem, countdown: ApprovalCountdown? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(QueueRowPresentation.sessionName(item.session, names: sessionNames))
                .font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
                .lineLimit(1).truncationMode(.tail).layoutPriority(2)
            if let note = rowNote(item) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("·").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                    rowNoteText(note, questionCard: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let place = model.rowPlace(for: item) {
                Text("· \(place)").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.rowDirectory(for: item) ?? place)
            } else {
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowHeading(item, countdown: countdown))
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

    /// A herdr session's Open availability for this card. With Ghostty controls off the card keeps
    /// its Set up Ghostty path, so that reason is presented as the Ghostty rules present it.
    private func herdrOpen(_ session: AgentSessionIdentity) -> HerdrOpenAvailability {
        let availability = model.herdrOpenAvailability(session, ttySupport: ghosttyTTY.support)
        if case .unavailable(.session(.ghosttyControlsOff)) = availability { return .notInHerdr }
        return availability
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

    /// The kind of Claude request for VoiceOver: the action the row shows ("Edit file"), lowercased, or "Bash".
    static func claudeRequestKind(_ approval: AgentApproval) -> String {
        guard let action = approval.details?.action, !action.isEmpty else { return "permission" }
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
                Text(model.claudeReturnUnavailableMessage)
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
            }
        } else if herdr == .notInHerdr, let reason = model.terminalOpenLine(session) {
            terminalOpenLine(item, reason: reason)
        }
    }

    @ViewBuilder
    private func claudeReturnControl(_ item: AgentAttentionItem, subject: String, emphasized: Bool = false,
                                     openTitle: String = "Open Session") -> some View {
        if item.session.source == .claude {
            let herdr = herdrOpen(item.session)
            if herdr == .available || (herdr == .notInHerdr && model.canOpenClaude(item.session)) {
                // The terminal scan's line replaces Open with no disabled button (#267).
                if herdr == .available || model.offersTerminalOpen(item.session) {
                    claudeOpenButton(item, subject: subject, emphasized: emphasized, title: openTitle)
                }
            } else if herdr == .notInHerdr, !model.ghosttyEnabled, model.claudeLastSeenLine(item.session) == nil {
                NotchButton(title: "Set up Ghostty", emphasized: emphasized, action: model.showControls)
                    .accessibilityLabel("Set up Ghostty: \(subject)")
                    .accessibilityHint("Opens Herdly controls to enable Ghostty controls.")
            }
        }
    }

    /// Remove clears a Claude row that looks stuck: its status is unavailable, no live Claude process
    /// holds its session, or it has had no evidence for 30 minutes. It never contacts Claude; new
    /// activity shows the session again.
    @ViewBuilder
    private func claudeRemoveControl(_ item: AgentAttentionItem, subject: String) -> some View {
        if model.canRemoveAgentRow(item) {
            NotchButton(title: "Remove") { model.removeAgentRow(item) }
                .accessibilityLabel("Remove: \(subject)")
                .accessibilityHint("Removes this row from Herdly until the session shows new activity. Claude is not changed.")
        }
    }

    private func claudeOpenButton(_ item: AgentAttentionItem, subject: String, emphasized: Bool,
                                  title: String = "Open Session") -> some View {
        NotchButton(title: title, emphasized: emphasized) {
            if let approval = item.approval {
                model.openAgentApproval(approval)
            } else {
                model.openAgent(item.session)
            }
        }
            .disabled(model.openingTask)
            .accessibilityLabel("Open Session: \(subject)")
            .accessibilityHint("Open this Claude session in its terminal.")
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
                          readouts: model.usageStripReadouts.map(\.spokenLabel))
    }

    /// Rows under their optional group headings, with each run of Earlier rows under its count. Each
    /// group is its own stack: heading 2pt above its first row, rows on their 26pt heading lines, a
    /// kind section's "+N more" beneath, and 16pt between groups.
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
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        if item.kind == .earlierOutcome && (index == 0 || group.items[index - 1].kind != .earlierOutcome) {
                            // The heading counts every Earlier result in the group, folded ones
                            // included, and Dismiss all clears exactly those.
                            let earlierIDs = group.earlierIDs
                            let count = earlierIDs.count
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("Earlier").font(NotchStyle.mono(11, .semibold))
                                    Text("\(count)").font(NotchStyle.mono(11)).monospacedDigit()
                                }
                                .foregroundStyle(NotchStyle.dim)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Earlier, \(count) \(count == 1 ? "result" : "results")")
                                .accessibilityAddTraits(.isHeader)
                                Spacer(minLength: 8)
                                NotchButton(title: "Dismiss all") { model.dismissAgents(earlierIDs) }
                                    .accessibilityLabel("Dismiss all \(count) earlier \(count == 1 ? "result" : "results")")
                            }
                            .padding(.vertical, 4)
                            .transition(rowTransition)
                        }
                        attentionRow(item)
                            .transition(rowTransition)
                    }
                    if let section = group.section, group.folded > 0 {
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
            (0..<max(1, questionPrompts(question).count)).map { claudeSelectionKey(question, $0) }
        })
    }

    var body: some View {
        let summary = strip
        VStack(alignment: .leading, spacing: 0) {
            Button(action: model.expand) {
                // The sprites and the to-check count sit together in the wing left of the housing
                // (`StripWing`: up to three sprites and the bare count collapsed, one sprite and
                // "N to check" open); Codex's weekly limit reading sits in the
                // wing right of it, with its five-hour reading ahead of it while Codex reports one, and
                // Claude's current five-hour and seven-day readings (orange) ahead of Codex's (blue).
                // The gap between them is the housing itself. On a display without a housing the
                // gap holds the optional center label instead; otherwise the name is read from the
                // open queue and the accessibility label. The 8pt content inset on each side comes
                // out of the wings. What each wing shows follows the active display profile.
                let layout = model.stripLayout
                let wing = StripWing.make(summary: summary, leftWing: model.appearance.leftWing, expanded: model.expanded)
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        ForEach(wing.sprites, id: \.identity) { sprite in
                            switch sprite {
                            case .unlit:
                                Sprite(kind: model.appearance.sprite, working: false, reduceMotion: model.reduceMotion, unlit: true)
                            case .session(let session):
                                Sprite(kind: model.appearance.sprite, working: session.working, reduceMotion: model.reduceMotion,
                                       color: session.color)
                            }
                        }
                        if let badge = wing.badge { Badge(badge) }
                        Spacer(minLength: 0)
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
                        let readouts = model.usageStripReadouts
                        ForEach(readouts.indices, id: \.self) { index in
                            let readout = readouts[index]
                            UsageLimitReading(readout)
                            if index + 1 < readouts.count {
                                // 8pt between readouts; the groupGap more where Claude's bars end.
                                Color.clear.frame(width: 8 + (readout.source != readouts[index + 1].source
                                                              ? UsageStripReadouts.groupGap : 0))
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
                        // An empty stack would still take the column's spacing, so each part is drawn only with rows.
                        if !sections.attention.isEmpty { groupRows(sections.attention) }
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
                    }
                    .animation(QueueMotion.curve(reduceMotion: model.reduceMotion), value: QueueMotion.layoutKey(sections.attention + sections.working))
                    .animation(QueueMotion.curve(reduceMotion: model.reduceMotion), value: showsTestRow)
                    .animation(QueueMotion.curve(reduceMotion: model.reduceMotion), value: model.openRunningRow)
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
        .onPreferenceChange(ContentHeightKey.self) { height in
            if abs(model.contentHeight - height) > 0.5 { model.contentHeight = height }
        }
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
                viewedQuestions[claudeSelectionKey(question, 0)] = nil
                for index in questionPrompts(question).indices {
                    let key = claudeSelectionKey(question, index)
                    if case let .text(text) = progress.answer(for: index),
                       questionDrafts[key]?.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) {
                        questionDrafts[key] = nil
                    }
                }
            }
        }
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
