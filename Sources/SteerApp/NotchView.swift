import AppKit
import SwiftUI
import SteerCore

struct ClaudeQuestionViewStateKey: Hashable, Sendable {
    let sourceScope: String
    let sessionID: String
    let promptID: String
    let toolUseID: String
    let requestID: String
    let index: Int

    init(question: AgentQuestion, index: Int) {
        sourceScope = question.identity.session.sourceScope
        sessionID = question.identity.session.session
        promptID = question.identity.turn
        toolUseID = question.identity.call
        requestID = question.helperRequestID ?? ""
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
/// and a dash while Steer has no current reading. A dim caption ahead of the bar names the window
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
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let inverted = configuration.isPressed || selected
        configuration.label
            .font(NotchStyle.mono(11, emphasized ? .semibold : .regular))
            .foregroundStyle(inverted ? Color.black : (enabled ? NotchStyle.ink : NotchStyle.dim))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(inverted ? NotchStyle.ink : NotchStyle.well,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(enabled ? 1 : 0.6)
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
/// or all-space draft sends nothing. Escape collapses the panel from the field without dismissing
/// anything. The caller owns the text and decides what sending means.
struct DraftField: View {
    let placeholder: String
    @Binding var text: String
    let sendTitle: String
    /// Names the subject session in both labels, for keyboard and VoiceOver use.
    let fieldLabel: String
    let sendLabel: String
    var hint: String?
    let onEscape: () -> Void
    let send: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.ink)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(NotchStyle.well, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .onSubmit { if enabled { send() } }
                .onExitCommand(perform: onEscape)
                .accessibilityLabel(fieldLabel)
                .accessibilityHint(hint ?? "")
            NotchButton(title: sendTitle, action: send)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(sendLabel)
        }
    }
}

/// One answer option: its digit in the session's colour, the label in ink. The option the user
/// chose fills with that colour and reads in black, the way a pressed control inverts; the colour
/// says which session's question this is, the fill says what was chosen. Focus ring as elsewhere.
struct OptionButton: View {
    let number: Int
    let label: String
    let tone: (body: Color, light: Color)
    var selected = false
    let action: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)").monospacedDigit().foregroundStyle(selected ? Color.black : (enabled ? tone.light : NotchStyle.dim))
                Text(label).foregroundStyle(selected ? Color.black : (enabled ? NotchStyle.ink : NotchStyle.dim))
            }
            .font(NotchStyle.mono(11, selected ? .semibold : .regular))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? tone.body : NotchStyle.well, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(enabled || selected ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
    }
}

/// A disclosure that keeps its content on the panel's left edge. SwiftUI's DisclosureGroup indents
/// and centers what it reveals; here the revealed rows align with everything above them.
struct NotchDisclosure<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder let content: () -> Content
    @FocusState private var focused: Bool
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
                    Text(title)
                }
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(.horizontal, -4).padding(.vertical, -2))
            .accessibilityLabel(title)
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
        ClaudeQuestionViewStateKey(question: question, index: index)
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

    /// The open queue's rows under their group headings; a spotlight card is never grouped.
    private var visibleGroups: [QueueGroup] {
        let grouping = model.presentationMode.showsAll ? model.appearance.grouping : .none
        return QueueGroups.make(visibleItems, grouping: grouping, project: model.projectFolder(for:))
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

    private func spriteColor(for session: UUID) -> Int {
        let identity = CodexAttentionAdapter.session(session, surface: .cli)
        return strip.sessions.first { $0.session == identity }?.color ?? AgentStripSummary.preferredColor(for: identity)
    }

    @ViewBuilder
    private func agentQuestionBody(_ question: AgentQuestion, subject: String) -> some View {
        if question.identity.session.source == .claude {
            claudeQuestionBody(question, subject: subject)
        } else if let legacy = model.codexQuestion(for: question) {
            questionBody(legacy, subject: subject)
        } else if question.prompts.isEmpty {
            Text("Codex asked a question Steer could not read; answer it in Codex.")
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(Array(question.prompts.enumerated()), id: \.offset) { index, prompt in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let header = prompt.header { Text(header).font(NotchStyle.mono(11, .semibold)).foregroundStyle(NotchStyle.ink) }
                        if question.prompts.count > 1 { Text("\(index + 1) of \(question.prompts.count)").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim) }
                    }
                    if let text = prompt.question {
                        Text(text).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { option, label in
                        if model.canAnswerAgentQuestion(question) {
                            OptionButton(number: option + 1, label: label, tone: NotchStyle.spriteColor(spriteColor(for: question.identity.session))) {
                                model.chooseAgentOption(question, index: index, option: option)
                            }
                            .accessibilityLabel("Answer \(option + 1): \(label), for \(subject)")
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(option + 1)").foregroundStyle(NotchStyle.dim).frame(width: 14, alignment: .trailing)
                                Text(label).foregroundStyle(NotchStyle.text)
                            }.font(NotchStyle.mono(11)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func claudeQuestionBody(_ question: AgentQuestion, subject: String) -> some View {
        let controls = model.canAnswerAgentQuestion(question)
        if question.prompts.isEmpty {
            Text("Claude's question answer control is unavailable; check Claude's native question.")
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(Array(question.prompts.enumerated()), id: \.offset) { index, prompt in
                VStack(alignment: .leading, spacing: 3) {
                    if !controls {
                        Text("Claude's question answer control is unavailable; check Claude's native question.")
                            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let header = prompt.header { Text(header).font(NotchStyle.mono(11, .semibold)).foregroundStyle(NotchStyle.ink) }
                        if question.prompts.count > 1 { Text("\(index + 1) of \(question.prompts.count)").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim) }
                    }
                    if let text = prompt.question {
                        Text(text).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { option, label in
                        if controls && prompt.multiSelect {
                            let selected = claudeSelections[claudeSelectionKey(question, index)]?.contains(option) == true
                            OptionButton(number: option + 1, label: label,
                                         tone: NotchStyle.spriteColor(spriteColor(for: question.identity.session)),
                                         selected: selected) {
                                toggleClaudeSelection(question, index: index, option: option)
                            }
                            .accessibilityLabel("Select \(option + 1): \(label), for \(subject)")
                        } else if controls {
                            OptionButton(number: option + 1, label: label,
                                         tone: NotchStyle.spriteColor(spriteColor(for: question.identity.session))) {
                                model.answerClaudeQuestion(question, kind: .option, answer: label)
                            }
                            .accessibilityLabel("Answer \(option + 1): \(label), for \(subject)")
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(option + 1)").foregroundStyle(NotchStyle.dim).frame(width: 14, alignment: .trailing)
                                Text(label).foregroundStyle(NotchStyle.text)
                            }.font(NotchStyle.mono(11)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if controls && prompt.multiSelect {
                        let selected = claudeSelections[claudeSelectionKey(question, index)] ?? []
                        NotchButton(title: "Send") {
                            let labels = selected.sorted().compactMap { prompt.options.indices.contains($0) ? prompt.options[$0] : nil }
                            model.answerClaudeQuestion(question, kind: .multiSelect, answer: labels.joined(separator: ", "))
                            claudeSelections[claudeSelectionKey(question, index)] = nil
                        }
                        .disabled(selected.isEmpty)
                        .accessibilityLabel("Send selected answers for \(subject)")
                    }
                    if controls {
                        DraftField(placeholder: prompt.options.isEmpty ? "Type your answer" : "Or type another answer",
                                   text: draft(claudeSelectionKey(question, index).storageKey), sendTitle: "Send",
                                   fieldLabel: "Typed answer for \(subject)", sendLabel: "Send typed answer for \(subject)",
                                   onEscape: model.collapse) {
                            model.answerClaudeQuestion(question, kind: .text,
                                                       answer: drafts[claudeSelectionKey(question, index).storageKey] ?? "")
                            drafts[claudeSelectionKey(question, index).storageKey] = nil
                        }
                    }
                }
            }
        }
    }

    /// Which rows the open panel shows: the explicit queue, or only the notification that opened it.
    private var visibleItems: [AgentAttentionItem] {
        switch model.presentationMode {
        case .collapsed: return []
        case .queue: return model.queueAgentAttentionItems
        case .agentSpotlight(let id): return model.orderedAgentAttentionItems.filter { $0.id == id }
        case .spotlight: return []
        }
    }

    private var showsTestRow: Bool {
        model.attention.pending && !model.desktopForeground && model.presentationMode.showsAll
    }

    private func isSpotlight(_ item: AgentAttentionItem) -> Bool {
        model.presentationMode == .agentSpotlight(item.id)
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
            // Steer records when the request arrived, not when it was handed back, so the elapsed
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
            NotchDisclosure(title: "Show full request", expanded: disclosure("request:\(item.session.session)")) {
                Text(full).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityLabel("Show full request for \(subject)")
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

    /// One question as Codex's own panel shows it: header with the "1 of N" pager, the question, and
    /// the option labels. Descriptions and the free-text field stay in Codex. With `choose` set the
    /// options are controls for the question Codex is on; `pick` is the one the user chose here.
    @ViewBuilder
    private func prompt(_ prompt: QuestionPrompt, index: Int, of total: Int, subject: String = "", tone: Int = 0,
                        pick: Int? = nil, typed: String? = nil, enabled: Bool = true, choose: ((Int) -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let header = prompt.header {
                    Text(header).font(NotchStyle.mono(11, .semibold)).foregroundStyle(NotchStyle.ink)
                }
                if total > 1 { Text("\(index + 1) of \(total)").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim) }
            }
            if let question = prompt.question {
                Text(question).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(prompt.options.enumerated()), id: \.offset) { offset, label in
                if let choose {
                    OptionButton(number: offset + 1, label: label, tone: NotchStyle.spriteColor(tone), selected: pick == offset) { choose(offset) }
                        .disabled(!enabled)
                        .accessibilityLabel("Answer \(offset + 1): \(label), for \(subject)")
                        .accessibilityHint(pick == offset ? "Your pick." : "Sends \(offset + 1) as your answer.")
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(offset + 1)").foregroundStyle(pick == offset ? NotchStyle.spriteColor(tone).light : NotchStyle.dim)
                            .frame(width: 14, alignment: .trailing)
                        Text(pick == offset ? "\(label) (sent)" : label).foregroundStyle(pick == offset ? NotchStyle.ink : NotchStyle.text)
                    }
                    .font(NotchStyle.mono(11)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let typed {
                Text("Typed: \(typed)").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.ink).fixedSize(horizontal: false, vertical: true)
            }
            if prompt.truncated {
                Text("Shortened; the full question is in Codex.").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
            }
        }
    }

    /// One question as the daemon describes it, complete: every option Codex lists is a control,
    /// and a question that takes typed text gets a field. The answer goes back by call id.
    @ViewBuilder
    private func daemonPrompt(_ question: AppServerQuestion, index: Int, of total: Int, callID: String, subject: String,
                              tone: Int, answer: ChosenAnswer?, enabled: Bool,
                              choose: @escaping (ChosenAnswer) -> Void) -> some View {
        let pick: Int? = { if case let .option(option) = answer { return option }; return nil }()
        let shown = question.displayPrompt
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let header = shown.header {
                    Text(header).font(NotchStyle.mono(11, .semibold)).foregroundStyle(NotchStyle.ink)
                }
                if total > 1 { Text("\(index + 1) of \(total)").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim) }
            }
            if let text = shown.question {
                Text(text).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if question.isSecret {
                Text("Codex asked for a secret; answer it in Codex.").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
            } else {
                ForEach(Array(shown.options.enumerated()), id: \.offset) { offset, label in
                    OptionButton(number: offset + 1, label: label,
                                 tone: NotchStyle.spriteColor(tone), selected: pick == offset) { choose(.option(offset)) }
                        .disabled(!enabled)
                        .accessibilityLabel("Answer \(offset + 1): \(label), for \(subject)")
                        .accessibilityHint(pick == offset ? "Your answer." : "Answers with this option through Codex's daemon.")
                }
                if question.takesText {
                    let key = "\(callID):\(index)"
                    DraftField(placeholder: question.isOther ? "Or type another answer" : "Type your answer",
                               text: draft(key), sendTitle: index + 1 < total ? "Next" : "Send",
                               fieldLabel: "Typed answer for \(subject)", sendLabel: "Send typed answer for \(subject)",
                               onEscape: model.collapse) {
                        choose(.text(drafts[key] ?? ""))
                        drafts[key] = nil
                    }
                    .disabled(!enabled)
                }
            }
        }
    }

    /// The daemon card's status sentence: which path, and where the answer stands.
    private func daemonStatus(_ question: AttentionQuestion, request: AppServerQuestionRequest?, progress: QuestionAnswerProgress) -> String? {
        let total = request?.questions.count ?? question.questionCount
        switch progress.phase {
        case .ready:
            // Nothing sent yet: the controls speak for themselves. The path is named once something is.
            if progress.questionIndex > 0, progress.questionIndex < total {
                return "Answer kept. Question \(progress.questionIndex + 1) of \(total); the whole call is sent after the last one."
            }
            return nil
        case .sending: return "Sending to Codex's daemon…"
        case .sent: return "Answered through Codex's daemon. Waiting for Codex to record it."
        case .unconfirmed: return "Answered through Codex's daemon, but Codex has not recorded an answer. Check Codex; Steer will not resend."
        case let .failed(reason): return reason
        case .pickedInCodex: return "Your pick opened Codex; Codex's daemon now holds the question, choose again here or in Codex."
        }
    }

    /// Why the card is not on the daemon path, for the fallback sentences.
    private var noDaemon: String {
        model.daemonConnected ? "Codex's daemon does not hold this question" : "No Codex daemon"
    }

    /// The card's one sentence about where the answer stands. Every phase names what Steer knows
    /// and nothing more; a relayed key is never described as an answer Codex has.
    private func questionStatus(_ question: AttentionQuestion, progress: QuestionAnswerProgress, total: Int) -> String? {
        // The card's one reason line already says to answer it in Codex (`herdrReasonLine`).
        if unrelayedHerdrQuestion(question) { return nil }
        let index = progress.questionIndex
        let destination = HerdrPresentation.keyDestination(for: model.route(for: question))
        switch progress.phase {
        case .ready:
            if index >= question.prompts.count { return "Codex is on question \(index + 1) of \(total). Continue in Codex." }
            if case let .continueInCodex(reason) = QuestionAnswerProgress.offer(question, at: index) { return reason }
            if case let .relayUnavailable(reason) = model.route(for: question) { return HerdrPresentation.relayUnavailableLine(for: reason) }
            if question.source == .cli, !model.showsOptionControls(for: question) { return "\(noDaemon); enable Ghostty controls to answer from here, or answer in Codex." }
            if index > 0, let previous = progress.picks[index - 1] { return "Sent \(previous + 1) as a key to \(destination.place). Codex should now show question \(index + 1)." }
            // Nothing sent yet: no sentence. The path is named once something is.
            return nil
        case .sending:
            return "Sending the key to \(destination.place)…"
        case .sent:
            return "Sent \(progress.picks[index].map { $0 + 1 } ?? 0) as a key to \(destination.place). Waiting for Codex to record it."
        case .unconfirmed:
            return "Sent \(progress.picks[index].map { $0 + 1 } ?? 0) as a key to \(destination.place), but Codex has not recorded an answer. Check the \(destination.noun); Steer will not resend."
        case let .failed(reason):
            return reason
        case .pickedInCodex:
            return "Choose it in Codex to answer."
        }
    }

    /// A Codex question in a herdr session that no relay can answer while Open is unavailable too.
    /// Its card shows only `HerdrPresentation.unrelayedQuestionLine`; why the relay failed stays in
    /// diagnostics. With Open available the card keeps offering Open in Codex as before.
    private func unrelayedHerdrQuestion(_ question: AttentionQuestion) -> Bool {
        guard case .relayUnavailable = model.route(for: question),
              case .unavailable = herdrOpen(CodexAttentionAdapter.session(question.session, surface: .cli)) else { return false }
        return true
    }

    @ViewBuilder
    private func questionBody(_ question: AttentionQuestion, subject: String) -> some View {
        let progress = model.progress(for: question)
        let index = progress.questionIndex
        let total = max(question.questionCount, question.prompts.count)
        let route = model.route(for: question)
        if case let .daemon(request) = route {
            let current = min(max(index, 0), request.questions.count - 1)
            daemonPrompt(request.questions[current], index: current, of: request.questions.count, callID: question.callID,
                         subject: subject, tone: spriteColor(for: question.session), answer: progress.answer(for: current),
                         enabled: progress.phase == .ready && index == current) { answer in
                switch answer {
                case let .option(option): model.chooseOption(question, question: index, option: option)
                case let .text(text): model.answerText(question, question: index, text: text)
                }
            }
            if request.questions.count > 1 {
                NotchDisclosure(title: "Show all \(request.questions.count) questions", expanded: disclosure("questions:\(question.callID)")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(request.questions.enumerated()).filter { $0.offset != current }, id: \.offset) { offset, rest in
                            prompt(rest.displayPrompt, index: offset, of: request.questions.count, tone: spriteColor(for: question.session),
                                   pick: progress.picks[offset], typed: progress.texts[offset])
                        }
                    }
                }
            }
            if let status = daemonStatus(question, request: request, progress: progress) {
                Text(status).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
            }
        } else if route == .daemonAnswered {
            if let first = question.prompts.first {
                prompt(first, index: 0, of: total, tone: spriteColor(for: question.session), pick: progress.picks[0], typed: progress.texts[0])
            }
            if let status = daemonStatus(question, request: nil, progress: progress) {
                Text(status).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
            }
        } else if question.prompts.isEmpty {
            Text("Codex asked a question Steer could not read; answer it in Codex.")
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
        } else {
            let current = min(index, question.prompts.count - 1)
            let offer = QuestionAnswerProgress.offer(question, at: index)
            let interactive: Bool = {
                guard index == current, model.showsOptionControls(for: question), case .options = offer else { return false }
                switch progress.phase {
                case .ready, .pickedInCodex: return true
                case .sending, .sent, .unconfirmed, .failed: return false
                }
            }()
            prompt(question.prompts[current], index: current, of: total, subject: subject, tone: spriteColor(for: question.session),
                   pick: progress.picks[current], enabled: progress.phase != .sending,
                   choose: interactive ? { option in model.chooseOption(question, question: index, option: option) } : nil)
            if question.prompts.count > 1 {
                NotchDisclosure(title: "Show all \(total) questions", expanded: disclosure("questions:\(question.callID)")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(question.prompts.enumerated()).filter { $0.offset != current }, id: \.offset) { offset, rest in
                            prompt(rest, index: offset, of: total, tone: spriteColor(for: question.session), pick: progress.picks[offset])
                        }
                    }
                }
            }
        }
        if let status = questionStatus(question, progress: progress, total: total) {
            Text(status).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The completion card's own sentence about the reply the user sent from it. Every phase says
    /// what Steer did and nothing more; a reply the daemon took is never called an answer Codex has.
    private func replyStatus(_ progress: SessionReplyProgress, target: SessionReplyTarget) -> String? {
        switch progress.phase {
        case .ready:
            if case let .unavailable(reason) = target { return SessionReplyPolicy.message(for: reason) }
            return nil
        case .sending:
            return "Sending your reply to Codex's daemon…"
        case let .sent(text, _):
            return "Sent “\(text)”. Waiting for Codex to record the turn."
        case let .working(text):
            return "Sent “\(text)”. Codex started a turn; this session is working again."
        case let .unconfirmed(text, _):
            return "Sent “\(text)”, but Codex has not started a turn. Check Codex; Steer will not resend."
        case let .failed(reason):
            return reason
        }
    }

    /// One follow-up prompt for a finished session, sent to that session and no other. The field is
    /// disabled whenever Steer cannot reach the session or has already sent this card's one reply;
    /// the sentence below says which. Sending never acknowledges the completion.
    @ViewBuilder
    private func replyBody(_ completion: AttentionCompletion, subject: String) -> some View {
        let progress = model.reply(for: completion)
        let target = model.replyTarget(for: completion)
        let key = "reply:\(completion.session.uuidString):\(completion.turn.uuidString)"
        DraftField(placeholder: "Reply to this session", text: draft(key), sendTitle: "Send",
                   fieldLabel: "Reply to \(subject)", sendLabel: "Send reply to \(subject)",
                   hint: "Sends a follow-up prompt to this session.", onEscape: model.collapse) {
            // The typed text is cleared only once the send is under way; a refusal keeps it to edit.
            model.sendReply(to: completion, text: drafts[key] ?? "")
            if model.reply(for: completion).phase != .ready { drafts[key] = nil }
        }
        .disabled(!target.isReachable || progress.phase != .ready)
        if let status = replyStatus(progress, target: target) {
            Text(status).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The open queue with nothing in it, in a row's own grammar: the unlit sprite leads the title,
    /// one line follows, and Open Controls appears only while no source reports to Steer.
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
                    .accessibilityHint("Opens Steer controls to connect Codex or Claude.")
            }
        }
    }

    @ViewBuilder
    private func attentionRow(_ item: AgentAttentionItem) -> some View {
        let spotlightDetails = isSpotlight(item) ? model.spotlightDetails(for: item) : nil
        let subject = rowSubject(item)
        let herdr = herdrOpen(item.session)
        let spotlit = isSpotlight(item)
        let earlierOpen = disclosure(earlierKey(item))
        let collapsed = item.kind == .earlierOutcome && !earlierOpen.wrappedValue && !spotlit
        VStack(alignment: .leading, spacing: 8) {
            // Every row is headed by its session's mark and name; the mark steps only while the
            // session is working, and the tag says what, if anything, the row needs from the user.
            let folded = item.kind == .earlierOutcome && !spotlit
            let marked = !folded
            let indicator = model.appearance.indicator
            let working = item.running?.status == .working
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
            if !collapsed {
                if let request = spotlightDetails?.request {
                    spotlightRequest(request, item: item, subject: subject)
                } else if let directory = spotlightDetails?.directory {
                    directoryLine(directory)
                }
                if let details = item.approval?.details, spotlightDetails == nil {
                    let missing = item.session.source == .claude ? "Not provided by Claude" : "Not provided by Codex"
                    VStack(alignment: .leading, spacing: 3) {
                        detail("task", details.taskName, missing: missing)
                        detail("project", details.project, missing: missing)
                        detail("action", details.action, missing: missing)
                        detail("command", details.command, selectable: true, missing: missing)
                        detail("reason", details.reason, selectable: true, missing: missing)
                    }
                    if let longText = details.longText {
                        NotchDisclosure(title: "Show full request", expanded: disclosure("request:\(item.session.session)")) {
                            Text(longText).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityLabel("Show full request for \(subject)")
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
                        Text("Queued before Steer last started. You may already have seen this result; Steer cannot verify it.")
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
                        Text("The exact Claude tab cannot be opened until Steer can verify it; continue in Claude.")
                            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                    }
                case .waiting, .running:
                    if let running = item.running, let row = running.rowText {
                        Text(row).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).lineLimit(2).truncationMode(.tail)
                        if let full = running.fullAction {
                            NotchDisclosure(title: "Show full action", expanded: disclosure("action:\(item.session.session)")) {
                                Text(full).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityLabel("Show full action for \(subject)")
                        } else if let full = running.fullPrompt, full != row {
                            // A shortened prompt is only its start; the disclosure must not call it full.
                            let title = running.promptShortened ? "Show more of prompt" : "Show full prompt"
                            NotchDisclosure(title: title, expanded: disclosure("prompt:\(item.session.session)")) {
                                Text(full).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if running.promptShortened {
                                    Text("Shortened; the full prompt is in \(item.session.source == .claude ? "Claude" : "Codex").")
                                        .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                                }
                            }
                            .accessibilityLabel("\(title) for \(subject)")
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
                }
                HStack(spacing: 6) {
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
                                .accessibilityHint("Approves this Claude Bash request once.")
                            NotchButton(title: "Deny") { model.decideAgent(approval, as: .deny) }
                                .accessibilityLabel("Deny: \(subject)")
                                .accessibilityHint("Denies this Claude Bash request.")
                        }
                        if item.session.source == .codex, herdr.offersOpen {
                            NotchButton(title: "Open Session") {
                                if let approval = item.approval { model.openAgentApproval(approval) }
                            }
                            .disabled(model.openingTask)
                            .accessibilityLabel("Open Session: \(subject)")
                            .accessibilityHint("Hands this request back to Codex's own prompt.")
                        }
                        claudeReturnControl(item, subject: subject)
                    case .handedBackApproval:
                        if item.session.source == .codex, herdr.offersOpen {
                            NotchButton(title: "Open Session") { model.openAgent(item.session) }
                                .disabled(model.openingTask)
                                .accessibilityLabel("Open Session: \(subject)")
                                .accessibilityHint("Open this session in Codex.")
                        }
                        claudeReturnControl(item, subject: subject)
                    case .statusUnavailable:
                        if item.session.source == .codex, herdr.offersOpen {
                            NotchButton(title: "Open Session") { model.openAgent(item.session) }
                                .disabled(model.openingTask)
                                .accessibilityLabel("Open Session: \(subject)")
                                .accessibilityHint("Open this session in Codex.")
                        }
                    case .question:
                        if item.session.source == .claude {
                            claudeReturnControl(item, subject: subject, emphasized: true)
                        } else if item.session.surface == .cli && !model.ghosttyEnabled {
                            NotchButton(title: "Set up Ghostty", emphasized: true, action: model.showControls)
                                .accessibilityLabel("Set up Ghostty: \(subject)")
                                .accessibilityHint("Opens Steer controls to enable Ghostty controls.")
                        } else if herdr.offersOpen {
                            NotchButton(title: "Open Session", emphasized: true) { model.openAgent(item.session) }
                                .disabled(model.openingTask)
                                .accessibilityLabel("Open Session: \(subject)")
                                .accessibilityHint("Answer the question in Codex's own panel.")
                        }
                        if item.session.source == .codex {
                            NotchButton(title: "Dismiss") { model.dismissAgent(item.id) }
                                .accessibilityLabel("Dismiss question: \(subject)")
                        }
                    case .outcome, .earlierOutcome:
                        if item.session.source == .codex, herdr.offersOpen {
                            NotchButton(title: "Open Session") { model.openAgent(item.session) }
                                .disabled(model.openingTask)
                                .accessibilityLabel("Open Session: \(subject)")
                                .accessibilityHint("Open this session in Codex.")
                        }
                        claudeReturnControl(item, subject: subject)
                        NotchButton(title: "Dismiss") { model.dismissAgent(item.id) }
                            .accessibilityLabel("Dismiss completion: \(subject)")
                    case .waiting, .running:
                        if item.session.source == .codex, herdr.offersOpen {
                            NotchButton(title: "Open Session") { model.openAgent(item.session) }
                                .disabled(model.openingTask)
                                .accessibilityLabel("Open Session: \(subject)")
                                .accessibilityHint("Open this session in Codex.")
                        }
                        claudeReturnControl(item, subject: subject)
                    }
                }
                if let outcome = item.outcome, outcome.session.source == .codex, let completion = model.codexCompletion(for: outcome),
                   completion.source == .cli {
                    replyBody(completion, subject: subject)
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
    }

    /// The spoken heading: the session's name, its place when known, then the full reading the
    /// visual tag shortens.
    private func rowHeading(_ item: AgentAttentionItem) -> String {
        let name = QueueRowPresentation.sessionName(item.session, names: sessionNames)
        let place = model.rowPlace(for: item).map { ", \($0)" } ?? ""
        return "\(name)\(place), \(rowTitle(item))"
    }

    private func earlierKey(_ item: AgentAttentionItem) -> String { "earlier:\(item.id)" }

    private func earlierToggle(_ item: AgentAttentionItem, open: Binding<Bool>) -> some View {
        EarlierFold(name: QueueRowPresentation.sessionName(item.session, names: sessionNames),
                    tag: QueueRowPresentation.attentionTag(item), spoken: rowHeading(item),
                    subject: rowSubject(item), reduceMotion: model.reduceMotion, open: open)
    }

    /// The row's one-line heading: the session's name, then "· project @ branch" when Steer has seen
    /// the working directory, then the tag saying what the row needs. The place truncates first so
    /// the name and tag stay whole. Presentation only; nothing here selects a target.
    private func rowHeader(_ item: AgentAttentionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(QueueRowPresentation.sessionName(item.session, names: sessionNames))
                .font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
                .lineLimit(1).truncationMode(.tail).layoutPriority(2)
            if let place = model.rowPlace(for: item) {
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
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).monospacedDigit()
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
            && item.question.flatMap(model.codexQuestion(for:)).map(unrelayedHerdrQuestion) == true
        let line = unrelayed ? HerdrPresentation.unrelayedQuestionLine(openCause: cause)
            : HerdrPresentation.cardLine(for: cause, agent: agent)
        Text(line)
            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func claudeReturnMessage(_ item: AgentAttentionItem) -> some View {
        let session = item.session
        let herdr = herdrOpen(session)
        if case let .unavailable(cause) = herdr {
            herdrReasonLine(item, cause: cause)
        } else if herdr == .notInHerdr, !model.isBackgroundClaudeSession(session), !model.canOpenClaude(session) {
            Text(model.claudeReturnUnavailableMessage)
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func claudeReturnControl(_ item: AgentAttentionItem, subject: String, emphasized: Bool = false) -> some View {
        if item.session.source == .claude {
            let herdr = herdrOpen(item.session)
            if herdr == .available || (herdr == .notInHerdr && model.canOpenClaude(item.session)) {
                NotchButton(title: "Open Session", emphasized: emphasized) {
                    if let approval = item.approval {
                        model.openAgentApproval(approval)
                    } else {
                        model.openAgent(item.session)
                    }
                }
                    .disabled(model.openingTask)
                    .accessibilityLabel("Open Session: \(subject)")
                    .accessibilityHint("Open the exact Claude Ghostty tab for this session.")
            } else if herdr == .notInHerdr, !model.ghosttyEnabled {
                NotchButton(title: "Set up Ghostty", emphasized: emphasized, action: model.showControls)
                    .accessibilityLabel("Set up Ghostty: \(subject)")
                    .accessibilityHint("Opens Steer controls to enable Ghostty controls.")
            }
        }
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
            .accessibilityHint(model.expanded ? "Steer attention queue is expanded." : "Expands the Steer attention queue.")

            if model.expanded {
                Rectangle().fill(NotchStyle.seam).frame(height: 1).padding(.bottom, 12)
                let groups = visibleGroups
                let rowTransition = QueueMotion.rowTransition(reduceMotion: model.reduceMotion)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
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
                                    let count = group.items[index...].prefix { $0.kind == .earlierOutcome }.count
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("Earlier").font(NotchStyle.mono(11, .semibold))
                                        Text("\(count)").font(NotchStyle.mono(11)).monospacedDigit()
                                    }
                                    .foregroundStyle(NotchStyle.dim)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Earlier, \(count) \(count == 1 ? "result" : "results")")
                                    .accessibilityAddTraits(.isHeader)
                                    .transition(rowTransition)
                                }
                                attentionRow(item)
                                    .transition(rowTransition)
                            }
                        }
                        if model.presentationMode.showsAll && visibleItems.isEmpty && !showsTestRow {
                            emptyQueueRow(model.emptyQueueReading)
                                .transition(rowTransition)
                        }
                        if model.presentationMode.showsAll && model.needsGhosttySetup {
                            Text("Enable Ghostty controls in Steer’s controls window to open these sessions.")
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
                    .animation(QueueMotion.curve(reduceMotion: model.reduceMotion), value: QueueMotion.layoutKey(groups))
                    .animation(QueueMotion.curve(reduceMotion: model.reduceMotion), value: showsTestRow)
                    .padding(.bottom, 14)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: proxy.size.height + model.stripLayout.height + 13)
                    })
                }
                // The queue scrolls without a visible scroller: a scroll bar would be the only
                // light edge inside the panel and would break its fused shape.
                .scrollIndicators(.hidden)
                .focusSection()
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            if abs(model.contentHeight - height) > 0.5 { model.contentHeight = height }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Steer notch")
        .padding(.horizontal, NotchPlacement.earRadius + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(NotchStyle.ink)
        .background(NotchStyle.ground, in: NotchShape())
        .preferredColorScheme(.dark)
        .onHover(perform: model.setHovering)
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
