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
    // Source values chosen so the captured tones match the reference's greens (109,201,125 and 135,222,154).
    static let sprite = Color(red: 0.133, green: 0.773, blue: 0.369)    // #22c55e body
    static let spriteLight = Color(red: 0.298, green: 0.863, blue: 0.502) // #4cdc80 highlight
    static let seam = Color.white.opacity(0.08)
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

/// A 6-by-4 cell creature at two points per cell. It steps between two frames while a session is
/// working and stands still otherwise; with Reduce Motion it breathes instead of stepping. Unlit, it
/// is the empty notch's mark: the silhouette in well gray with its eyes shut, still, and no session's
/// color, so it never reads as a session.
struct Sprite: View {
    var working: Bool
    var reduceMotion: Bool
    var color: Int = 0
    var unlit = false
    static let cell: CGFloat = 2
    /// `#` is the body green, `+` the lighter highlight on the ears and eyes.
    static let frames: [[String]] = [
        [".++.++", "######", "#+##+#", ".#..#."],
        [".++.++", "######", "#+##+#", "#....#"]
    ]

    var body: some View {
        Group {
            if unlit {
                bitmap(Sprite.frames[0])
            } else if working && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let frame = Int(context.date.timeIntervalSinceReferenceDate * 2) & 1
                    bitmap(Sprite.frames[frame])
                }
            } else if working {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let phase = sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.4)
                    bitmap(Sprite.frames[0]).opacity(0.75 + 0.25 * phase)
                }
            } else {
                bitmap(Sprite.frames[0])
            }
        }
        .frame(width: Sprite.cell * 6, height: Sprite.cell * 4)
        .accessibilityHidden(true)
    }

    private func bitmap(_ rows: [String]) -> some View {
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    let rect = CGRect(x: CGFloat(x) * Sprite.cell, y: CGFloat(y) * Sprite.cell, width: Sprite.cell, height: Sprite.cell)
                    // One tone when unlit: the highlight cells fill like the body, so the eyes close.
                    let tone = unlit ? (body: NotchStyle.well, light: NotchStyle.well) : NotchStyle.spriteColor(color)
                    context.fill(Path(rect), with: .color(ch == "+" ? tone.light : tone.body))
                }
            }
        }
    }
}

/// The mark leading a queue row in the user's chosen style. Dot and bar step between the session's
/// body and highlight on the sprite's 0.5 s beat while working and hold still otherwise; tint is
/// drawn behind the row header by `SessionTint`, so it has no mark of its own.
struct SessionMark: View {
    var style: SessionIndicatorStyle
    var working: Bool
    var reduceMotion: Bool
    var color: Int

    var body: some View {
        switch style {
        case .sprite:
            Sprite(working: working, reduceMotion: reduceMotion, color: color)
        case .dot, .bar:
            Group {
                if working && !reduceMotion {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        shape(lit: Int(context.date.timeIntervalSinceReferenceDate * 2) & 1 == 1)
                    }
                } else {
                    shape(lit: working)
                }
            }
            .frame(width: Sprite.cell * 6, height: style == .bar ? 12 : Sprite.cell * 4)
            .accessibilityHidden(true)
        case .tint:
            EmptyView()
        }
    }

    @ViewBuilder
    private func shape(lit: Bool) -> some View {
        let tone = NotchStyle.spriteColor(color)
        let fill = lit ? tone.light : tone.body
        if style == .bar {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(fill).frame(width: 3, height: 12)
        } else {
            Circle().fill(fill).frame(width: 6, height: 6)
        }
    }
}

/// The tint style: the row header sits on a well of the session's body colour, stepping from 18% to
/// 26% on the sprite's beat while working.
struct SessionTint: ViewModifier {
    var active: Bool
    var working: Bool
    var reduceMotion: Bool
    var color: Int

    func body(content: Content) -> some View {
        if active {
            content
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background {
                    if working && !reduceMotion {
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            well(Int(context.date.timeIntervalSinceReferenceDate * 2) & 1 == 1 ? 0.26 : 0.18)
                        }
                    } else {
                        well(working ? 0.26 : 0.18)
                    }
                }
                .padding(.horizontal, -6)
        } else {
            content
        }
    }

    private func well(_ opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(NotchStyle.spriteColor(color).body.opacity(opacity))
    }
}

/// The count of items that need the user; hidden at zero by the caller.
struct Badge: View {
    var count: Int
    var body: some View {
        Text("\(count)")
            .font(NotchStyle.mono(11, .medium)).monospacedDigit()
            .foregroundStyle(NotchStyle.ink)
            .frame(minWidth: 16, minHeight: 16)
            .padding(.horizontal, 2)
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
    let tag: String?
    /// The full spoken heading, since the tag is a shortened reading.
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
                if let tag { RowTag(text: tag) }
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

/// A small gray well holding a short reading: a row's source, or what the row needs from the user.
struct RowTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.text)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(NotchStyle.well, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
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

    private func rowTitle(_ item: AgentAttentionItem) -> String {
        switch item.kind {
        case .actionableApproval: return item.session.source == .claude ? "Claude permission needed" : "Permission needed"
        case .handedBackApproval: return item.session.source == .claude ? "Continue in Claude" : "Continue in Codex"
        case .question: return item.session.source == .claude ? "Claude waiting" : "Codex needs an answer"
        case .outcome, .earlierOutcome:
            let status = item.outcome?.status
            let label = switch status {
            case .finished: "finished"
            case .failed: "failed"
            case .stopped: "stopped"
            case .unavailable, nil: "status unavailable"
            }
            return "\(item.session.source == .claude ? "Claude" : "Codex") \(label)"
        case .statusUnavailable: return "Claude status unavailable"
        case .waiting: return "Waiting"
        case .running: return "Working"
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
    private func cardOpener<Header: View>(_ item: AgentAttentionItem, @ViewBuilder header: () -> Header) -> some View {
        if opensAsCard(item) {
            Button { model.openCard(item.id) } label: { header().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel("Open card: \(rowHeading(item))")
                .accessibilityHint("Shows this request alone. Escape or Queue returns to the queue.")
        } else {
            header()
        }
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

    @ViewBuilder
    private func detail(_ label: String, _ value: String?, selectable: Bool = false,
                        missing: String = "Not provided by Codex") -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(NotchStyle.dim).frame(width: 58, alignment: .leading)
            if selectable {
                Text(value ?? missing).foregroundStyle(value == nil ? NotchStyle.dim : NotchStyle.text).textSelection(.enabled)
            } else {
                Text(value ?? missing).foregroundStyle(value == nil ? NotchStyle.dim : NotchStyle.text)
            }
        }
        .font(NotchStyle.mono(11)).fixedSize(horizontal: false, vertical: true)
    }

    /// A spotlit approval request read top to bottom: Codex's ask, then what it wants to run and
    /// where, then where the request stands. The raw request appears only behind a disclosure, and
    /// only when it holds something this card does not already show.
    @ViewBuilder
    private func spotlightRequest(_ request: SpotlightRequest, item: AgentAttentionItem, subject: String) -> some View {
        if let ask = request.ask {
            Text(ask).font(NotchStyle.mono(12)).foregroundStyle(NotchStyle.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let action = request.action { Text(action).foregroundStyle(NotchStyle.dim) }
                if let command = request.command {
                    Text(command).foregroundStyle(NotchStyle.ink).textSelection(.enabled)
                } else {
                    Text("Command not provided by Codex").foregroundStyle(NotchStyle.dim)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            let task = request.task(besidesSessionName: sessionNames[item.session])
            if task != nil || request.directory != nil {
                let place = request.directory.map { "in \($0.display)" }
                Text([task, place].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                    .help(request.directory?.full ?? "")
                    .accessibilityLabel([task, request.directory.map { "in \($0.full)" }].compactMap { $0 }.joined(separator: ", "))
                    .contextMenu { if let full = request.directory?.full { copyPathButton(full) } }
            }
        }
        .font(NotchStyle.mono(11))
        if item.kind == .handedBackApproval {
            // Herdly records when the request arrived, not when it was handed back, so the elapsed
            // time names the arrival.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Handed back with no decision · asked \(SpotlightRequest.elapsed(since: request.arrivedAt, now: context.date.timeIntervalSince1970))")
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Decide by \(Date(timeIntervalSince1970: request.expiresAt).formatted(date: .omitted, time: .standard))")
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
        }
        if let full = request.fullRequest {
            NotchDisclosure(title: "Show full request", subject: subject, expanded: disclosure("request:\(item.session.session)")) {
                Text(full).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Sprite(working: false, reduceMotion: model.reduceMotion, unlit: true).offset(y: -1)
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
        VStack(alignment: .leading, spacing: item.kind == .question ? 14 : 8) {
            // Every row is headed by its session's mark and name; the mark steps only while the
            // session is working, and the tag says what, if anything, the row needs from the user.
            let folded = item.kind == .earlierOutcome && !spotlit
            let marked = !folded
            let indicator = model.appearance.indicator
            let working = item.running?.status == .working
            if item.kind == .question {
                cardOpener(item) { questionHeader(item) }
            } else {
                cardOpener(item) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if marked && indicator != .tint {
                        SessionMark(style: indicator, working: working, reduceMotion: model.reduceMotion,
                                    color: spriteColor(for: item.session)).offset(y: -1)
                    }
                    if folded {
                        earlierToggle(item, open: earlierOpen)
                    } else {
                        rowHeader(item)
                    }
                    Spacer(minLength: 8)
                    if !folded { RowTag(text: QueueRowPresentation.sourceTag(item.session)) }
                    rowAge(item)
                }
                .modifier(SessionTint(active: marked && indicator == .tint, working: working,
                                      reduceMotion: model.reduceMotion, color: spriteColor(for: item.session)))
                }
            }
            if let note = rowNote(item), note.offersOpen {
                // "Not delivered · answer in Claude": Open takes the user to the session to answer there.
                HStack(spacing: 6) { claudeReturnControl(item, subject: subject) }
            }
            if !collapsed {
                if let request = spotlightDetails?.request {
                    spotlightRequest(request, item: item, subject: subject)
                } else if item.kind != .question, let directory = spotlightDetails?.directory {
                    directoryLine(directory)
                }
                if let details = item.approval?.details, spotlightDetails == nil {
                    let missing = item.session.source == .claude ? "Not provided by Claude" : "Not provided by Codex"
                    VStack(alignment: .leading, spacing: 3) {
                        detail("task", details.taskName, missing: missing)
                        detail("project", details.project, missing: missing)
                        detail("action", details.action, missing: missing)
                        detail(details.commandLabel ?? "command", details.command, selectable: true, missing: missing)
                        detail("reason", details.reason, selectable: true, missing: missing)
                    }
                    if let longText = details.longText {
                        NotchDisclosure(title: "Show full request", subject: subject, expanded: disclosure("request:\(item.session.session)")) {
                            Text(longText).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                switch item.kind {
                case .handedBackApproval where spotlightDetails?.request != nil:
                    EmptyView()
                case .handedBackApproval:
                    Text("Handed back with no decision. Continue in \(item.session.source == .claude ? "Claude" : "Codex") to decide.")
                        .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
                    if item.session.source == .claude {
                        claudeReturnMessage(item)
                    }
                case .actionableApproval:
                    if item.session.source == .claude {
                        if let approval = item.approval, !model.canDecideAgent(approval) {
                            Text("Claude's native permission prompt remains available.")
                                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                        }
                        claudeReturnMessage(item)
                    }
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
                            NotchDisclosure(title: "Show full action", subject: subject, expanded: disclosure("action:\(item.session.session)")) {
                                Text(full).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else if expandsPrompt {
                            // A shortened prompt is only its start; the disclosure must not call it full.
                            let title = running.promptShortened ? "Show more of prompt" : "Show full prompt"
                            NotchDisclosure(title: title, expandedTitle: "Show less", subject: subject, expanded: disclosure(promptKey)) {
                                if running.promptShortened {
                                    Text("Shortened; the full prompt is in \(item.session.source == .claude ? "Claude" : "Codex").")
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
                    case .actionableApproval:
                        if item.session.source == .codex && item.session.surface == .cli {
                            NotchButton(title: "Approve once", emphasized: true) { if let approval = item.approval { model.decideAgent(approval, as: .allowOnce) } }
                                .accessibilityLabel("Approve once: \(subject)")
                                .accessibilityHint("Approves this Codex permission request once.")
                            NotchButton(title: "Deny") { if let approval = item.approval { model.decideAgent(approval, as: .deny) } }
                                .accessibilityLabel("Deny: \(subject)")
                                .accessibilityHint("Denies this Codex permission request.")
                        }
                        if item.session.source == .claude, let approval = item.approval, model.canDecideAgent(approval) {
                            NotchButton(title: "Approve once", emphasized: true) { model.decideAgent(approval, as: .allowOnce) }
                                .accessibilityLabel("Approve once: \(subject)")
                                .accessibilityHint("Approves this Claude \(Self.claudeRequestKind(approval)) request once.")
                            NotchButton(title: "Deny") { model.decideAgent(approval, as: .deny) }
                                .accessibilityLabel("Deny: \(subject)")
                                .accessibilityHint("Denies this Claude \(Self.claudeRequestKind(approval)) request.")
                        }
                        if item.session.source == .codex, codexOpen {
                            NotchButton(title: "Open Session") {
                                if let approval = item.approval { model.openAgentApproval(approval) }
                            }
                            .disabled(model.openingTask)
                            .accessibilityLabel("Open Session: \(subject)")
                            .accessibilityHint("Hands this request back to Codex's own prompt.")
                        }
                        claudeReturnControl(item, subject: subject)
                    case .handedBackApproval:
                        if item.session.source == .codex, codexOpen {
                            NotchButton(title: "Open Session") { model.openAgent(item.session) }
                                .disabled(model.openingTask)
                                .accessibilityLabel("Open Session: \(subject)")
                                .accessibilityHint("Open this session in Codex.")
                        }
                        claudeReturnControl(item, subject: subject)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rowHeading(item)), \(subject)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // The keyboard selection reuses the focus ring's vocabulary around the whole row.
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(selected ? 0.9 : 0), lineWidth: 1.5).padding(.horizontal, -6).padding(.vertical, -4))
        .environment(\.questionCard, item.kind == .question)
    }

    /// The spoken heading: the session's name, its place when known, then the full reading the
    /// visual tag shortens.
    private func rowHeading(_ item: AgentAttentionItem) -> String {
        let name = QueueRowPresentation.sessionName(item.session, names: sessionNames)
        let place = (rowNote(item)?.text ?? model.rowPlace(for: item)).map { ", \($0)" } ?? ""
        return "\(name)\(place), \(rowTitle(item))"
    }

    private func earlierKey(_ item: AgentAttentionItem) -> String { "earlier:\(item.id)" }

    private func earlierToggle(_ item: AgentAttentionItem, open: Binding<Bool>) -> some View {
        EarlierFold(name: QueueRowPresentation.sessionName(item.session, names: sessionNames),
                    tag: QueueRowPresentation.attentionTag(item), spoken: rowHeading(item),
                    subject: rowSubject(item), reduceMotion: model.reduceMotion, open: open)
    }

    private func questionHeader(_ item: AgentAttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if model.appearance.indicator != .tint {
                    SessionMark(style: model.appearance.indicator, working: false, reduceMotion: model.reduceMotion,
                                color: spriteColor(for: item.session))
                }
                Text(QueueRowPresentation.sessionName(item.session, names: sessionNames))
                    .font(QuestionCardStyle.font(12, .semibold)).foregroundStyle(NotchStyle.ink)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                if let note = rowNote(item) {
                    rowNoteText(note, questionCard: true)
                } else if let place = model.rowPlace(for: item) {
                    Text(place).font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
                        .lineLimit(1).help(place)
                }
                Spacer(minLength: 0)
                rowAge(item)
            }
            .modifier(SessionTint(active: model.appearance.indicator == .tint, working: false,
                                  reduceMotion: model.reduceMotion, color: spriteColor(for: item.session)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowHeading(item))
            .accessibilityAddTraits(.isHeader)
            let directory = model.rowDirectory(for: item)
            let source = item.session.source == .claude ? "Claude Code" : (item.session.surface == .cli ? "Codex CLI" : "Codex Desktop")
            Text(source + (directory.map { " · " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""))
                .font(QuestionCardStyle.font(11)).foregroundStyle(NotchStyle.dim)
                .padding(.leading, model.appearance.indicator == .tint ? 0 : 20)
                .fixedSize(horizontal: false, vertical: true)
                .help(directory ?? source)
        }
    }

    /// The row's one-line heading: the session's name, then "· project @ branch" when Herdly has seen
    /// the working directory, then the tag saying what the row needs. The place truncates first so
    /// the name and tag stay whole. Presentation only; nothing here selects a target.
    private func rowHeader(_ item: AgentAttentionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(QueueRowPresentation.sessionName(item.session, names: sessionNames))
                .font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
                .lineLimit(1).truncationMode(.tail).layoutPriority(2)
            if let note = rowNote(item) {
                Text("·").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                rowNoteText(note, questionCard: false)
            } else if let place = model.rowPlace(for: item) {
                Text("· \(place)").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                    .lineLimit(1).truncationMode(.tail)
                    .help(model.rowDirectory(for: item) ?? place)
            }
            if let tag = QueueRowPresentation.attentionTag(item) { RowTag(text: tag).layoutPriority(3) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowHeading(item))
        .accessibilityAddTraits(.isHeader)
    }

    /// The trailing age lane: time since the row's latest evidence, refreshed every 30 seconds.
    private func rowAge(_ item: AgentAttentionItem) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date.timeIntervalSince1970
            Text(QueueRowPresentation.age(since: item.lastUpdate, now: now))
                .font(item.kind == .question ? QuestionCardStyle.font(11) : NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).monospacedDigit()
                .lineLimit(1).fixedSize()
                .frame(minWidth: 36, alignment: .trailing)
                .accessibilityLabel(QueueRowPresentation.spokenAge(since: item.lastUpdate, now: now))
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
    private func claudeReturnControl(_ item: AgentAttentionItem, subject: String, emphasized: Bool = false) -> some View {
        if item.session.source == .claude {
            let herdr = herdrOpen(item.session)
            if herdr == .available || (herdr == .notInHerdr && model.canOpenClaude(item.session)) {
                // The terminal scan's line replaces Open with no disabled button (#267).
                if herdr == .available || model.offersTerminalOpen(item.session) {
                    claudeOpenButton(item, subject: subject, emphasized: emphasized)
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

    private func claudeOpenButton(_ item: AgentAttentionItem, subject: String, emphasized: Bool) -> some View {
        NotchButton(title: "Open Session", emphasized: emphasized) {
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
        let summary = strip
        let empty = summary.sessions.isEmpty && summary.toCheck == 0
        var parts: [String] = [empty ? model.emptyQueueReading.title : summary.subject]
        let sessions = summary.sessions.count + summary.overflow
        if sessions > 1 { parts.append("\(sessions) sessions") }
        if summary.working { parts.append("working") }
        if summary.toCheck > 0 { parts.append("\(summary.toCheck) to check") }
        parts += model.usageStripReadouts.map(\.spokenLabel)
        return parts.joined(separator: ", ")
    }

    /// Rows under their optional group headings, with each run of Earlier rows under its count.
    @ViewBuilder
    private func groupRows(_ groups: [QueueGroup]) -> some View {
        let rowTransition = QueueMotion.rowTransition(reduceMotion: model.reduceMotion)
        // Groups are identified by heading so a regrouped row moves rather than every
        // later group redrawing under a new index.
        ForEach(groups, id: \.heading) { group in
            if let heading = group.heading {
                // Group headings: 10pt dim caption, 6pt above the group's first row.
                Text(heading).font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.dim)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, -8)
                    .transition(rowTransition)
            }
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                if item.kind == .earlierOutcome && (index == 0 || group.items[index - 1].kind != .earlierOutcome) {
                    // Dismiss all clears exactly the results listed under this heading.
                    let earlierIDs = group.items[index...].prefix { $0.kind == .earlierOutcome }.map(\.id)
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
                    .transition(rowTransition)
                }
                attentionRow(item)
                    .transition(rowTransition)
            }
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
                // One sprite per session (at most three), the overflow mark, and the to-check count
                // sit together in the wing left of the housing; Codex's weekly limit reading sits in the
                // wing right of it, with its five-hour reading ahead of it while Codex reports one, and
                // Claude's current five-hour and seven-day readings (orange) ahead of Codex's (blue).
                // The gap between them is the housing itself. On a display without a housing the
                // gap holds the optional center label instead; otherwise the name is read from the
                // open queue and the accessibility label. The 8pt content inset on each side comes
                // out of the wings. What each wing shows follows the active display profile.
                let layout = model.stripLayout
                let leftWing = model.appearance.leftWing
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        switch leftWing {
                        case .spritesAndCount:
                            if summary.sessions.isEmpty {
                                Sprite(working: false, reduceMotion: model.reduceMotion, unlit: true)
                            }
                            ForEach(summary.sessions, id: \.session) { session in
                                Sprite(working: session.working, reduceMotion: model.reduceMotion, color: session.color)
                            }
                        case .countOnly:
                            // One stepping sprite keeps the working signal when sessions are hidden.
                            if let busy = summary.sessions.first(where: \.working) {
                                Sprite(working: true, reduceMotion: model.reduceMotion, color: busy.color)
                            }
                        case .none:
                            EmptyView()
                        }
                        if leftWing == .spritesAndCount && summary.overflow > 0 {
                            Text("+\(summary.overflow)")
                                .font(NotchStyle.mono(11, .medium)).monospacedDigit()
                                .foregroundStyle(NotchStyle.text).lineLimit(1).fixedSize()
                                .accessibilityLabel("\(summary.overflow) more sessions")
                        }
                        if leftWing != .none && summary.toCheck > 0 { Badge(count: summary.toCheck) }
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
                        groupRows(sections.attention)
                        if sections.foldsWorking {
                            NotchDisclosure(title: "\(sections.workingCount) working", expanded: $model.workingFoldOpen) {
                                VStack(alignment: .leading, spacing: 14) { groupRows(sections.working) }
                            }
                        } else {
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
    }
}

private extension HerdrOpenAvailability {
    /// Open stays on the card unless herdr's binding or Ghostty's `tty` support rules it out.
    var offersOpen: Bool {
        if case .unavailable = self { return false }
        return true
    }
}
