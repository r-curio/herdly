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
/// working and stands still otherwise; with Reduce Motion it breathes instead of stepping.
struct Sprite: View {
    var working: Bool
    var reduceMotion: Bool
    var color: Int = 0
    static let cell: CGFloat = 2
    /// `#` is the body green, `+` the lighter highlight on the ears and eyes.
    static let frames: [[String]] = [
        [".++.++", "######", "#+##+#", ".#..#."],
        [".++.++", "######", "#+##+#", "#....#"]
    ]

    var body: some View {
        Group {
            if working && !reduceMotion {
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
                    let tone = NotchStyle.spriteColor(color)
                    context.fill(Path(rect), with: .color(ch == "+" ? tone.light : tone.body))
                }
            }
        }
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

/// One of Codex's usage limits as a vertical bar: a dark-well track filled in ink from the bottom
/// to the used share, with the percent beside it; an empty track and a dash while Steer has no
/// current reading. A dim caption ahead of the bar names a second window ("5h") when two readouts
/// share the strip; the weekly readout carries none, as it always has. Gray only, per the One
/// Color Rule. Hidden from VoiceOver; the strip label speaks it.
struct UsageLimitReading: View {
    var limit: CodexUsageWindow?
    var caption: String? = nil
    static let barWidth: CGFloat = 4
    static let barHeight: CGFloat = 14

    private var fraction: CGFloat { CGFloat(min(100, max(0, limit?.usedPercent ?? 0)) / 100) }

    var body: some View {
        HStack(spacing: 5) {
            if let caption { Text(caption).foregroundStyle(NotchStyle.dim) }
            ZStack(alignment: .bottom) {
                Capsule().fill(NotchStyle.well)
                Capsule().fill(NotchStyle.ink).frame(height: Self.barHeight * fraction)
            }
            .frame(width: Self.barWidth, height: Self.barHeight)
            Text(limit?.percentText ?? "—").foregroundStyle(limit == nil ? NotchStyle.dim : NotchStyle.ink).monospacedDigit()
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

/// Reports the open panel's natural content height so the window can be exactly that tall.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct Notch: View {
    @ObservedObject var model: Companion
    @FocusState private var headerFocused: Bool
    /// Disclosures the user opened, by the item they belong to; cleared when the item leaves.
    @State private var openDisclosures: Set<String> = []
    /// Typed answers being composed, by call id and question index; sent only on Return or Send.
    @State private var drafts: [String: String] = [:]
    /// Multi-select labels are kept in the view until the user presses Send.
    @State private var claudeSelections: [ClaudeQuestionViewStateKey: Set<Int>] = [:]

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

    /// Running rows already carry the session name as their title; a CLI session gets its source
    /// noted where the session label would otherwise sit.
    private func rowTrailing(_ item: AgentAttentionItem) -> String? {
        sessionLabel(item.session)
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
        case .queue: return model.orderedAgentAttentionItems
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
        let index = progress.questionIndex
        switch progress.phase {
        case .ready:
            if index >= question.prompts.count { return "Codex is on question \(index + 1) of \(total). Continue in Codex." }
            if case let .continueInCodex(reason) = QuestionAnswerProgress.offer(question, at: index) { return reason }
            if question.source == .cli, !model.showsOptionControls(for: question) { return "\(noDaemon); enable Ghostty controls to answer from here, or answer in Codex." }
            if index > 0, let previous = progress.picks[index - 1] { return "Sent \(previous + 1) as a key to the Ghostty tab. Codex should now show question \(index + 1)." }
            // Nothing sent yet: no sentence. The path is named once something is.
            return nil
        case .sending:
            return "Sending the key to the Ghostty tab…"
        case .sent:
            return "Sent \(progress.picks[index].map { $0 + 1 } ?? 0) as a key to the Ghostty tab. Waiting for Codex to record it."
        case .unconfirmed:
            return "Sent \(progress.picks[index].map { $0 + 1 } ?? 0) as a key to the Ghostty tab, but Codex has not recorded an answer. Check the tab; Steer will not resend."
        case let .failed(reason):
            return reason
        case .pickedInCodex:
            return "Choose it in Codex to answer."
        }
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

    @ViewBuilder
    private func attentionRow(_ item: AgentAttentionItem) -> some View {
        let spotlightDetails = isSpotlight(item) ? model.spotlightDetails(for: item) : nil
        let subject = rowSubject(item)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if item.kind == .running || item.kind == .waiting || item.kind == .question {
                    Sprite(working: item.running?.status == .working, reduceMotion: model.reduceMotion,
                           color: spriteColor(for: item.session)).offset(y: -1)
                }
                Text(rowTitle(item)).font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(rowTrailing(item) ?? "").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                    .lineLimit(1).truncationMode(.tail)
            }
            if let spotlightDetails {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(spotlightDetails.context) { field in detail(field.label, field.value, selectable: true) }
                }
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
            case .handedBackApproval:
                Text("Handed back with no decision. Continue in \(item.session.source == .claude ? "Claude" : "Codex") to decide.")
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
                if item.session.source == .claude {
                    claudeReturnMessage(item.session)
                }
            case .actionableApproval:
                if item.session.source == .claude {
                    if let approval = item.approval, !model.canDecideAgent(approval) {
                        Text("Claude's native permission prompt remains available.")
                            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
                    }
                    claudeReturnMessage(item.session)
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
                    claudeReturnMessage(item.session)
                }
            case .question:
                if let question = item.question { agentQuestionBody(question, subject: subject) }
                if item.session.source == .claude {
                    claudeReturnMessage(item.session)
                }
                if item.session.source == .claude, let question = item.question,
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
                        NotchDisclosure(title: "Show full prompt", expanded: disclosure("prompt:\(item.session.session)")) {
                            Text(full).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityLabel("Show full prompt for \(subject)")
                    }
                }
                if item.session.source == .claude {
                    claudeReturnMessage(item.session)
                }
            case .statusUnavailable:
                Text(item.unavailableReason ?? "Status unavailable. Continue in Claude to inspect the session.")
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
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
                    if item.session.source == .codex {
                        NotchButton(title: "Open in Codex") {
                            if let approval = item.approval { model.openAgentApproval(approval) }
                        }
                        .disabled(model.openingTask)
                        .accessibilityLabel("Open in Codex: \(subject)")
                        .accessibilityHint("Hands this request back to Codex's own prompt.")
                    }
                    claudeReturnControl(item, subject: subject)
                case .handedBackApproval:
                    if item.session.source == .codex {
                        NotchButton(title: "Open in Codex") { model.openAgent(item.session) }
                            .disabled(model.openingTask)
                            .accessibilityLabel("Open in Codex: \(subject)")
                            .accessibilityHint("Open this session in Codex.")
                    }
                    claudeReturnControl(item, subject: subject)
                case .statusUnavailable:
                    if item.session.source == .codex {
                        NotchButton(title: "Open in Codex") { model.openAgent(item.session) }
                            .disabled(model.openingTask)
                            .accessibilityLabel("Open in Codex: \(subject)")
                            .accessibilityHint("Open this session in Codex.")
                    }
                case .question:
                    if item.session.source == .claude {
                        claudeReturnControl(item, subject: subject, emphasized: true)
                    } else if item.session.surface == .cli && !model.ghosttyEnabled {
                        NotchButton(title: "Set up Ghostty", emphasized: true, action: model.showControls)
                            .accessibilityLabel("Set up Ghostty: \(subject)")
                            .accessibilityHint("Opens Steer controls to enable Ghostty controls.")
                    } else {
                        NotchButton(title: "Open in Codex", emphasized: true) { model.openAgent(item.session) }
                            .disabled(model.openingTask)
                            .accessibilityLabel("Open in Codex: \(subject)")
                            .accessibilityHint("Answer the question in Codex's own panel.")
                    }
                    if item.session.source == .codex {
                        NotchButton(title: "Dismiss") { model.dismissAgent(item.id) }
                            .accessibilityLabel("Dismiss question: \(subject)")
                    }
                case .outcome, .earlierOutcome:
                    if item.session.source == .codex {
                        NotchButton(title: "Open in Codex") { model.openAgent(item.session) }
                            .disabled(model.openingTask)
                            .accessibilityLabel("Open in Codex: \(subject)")
                            .accessibilityHint("Open this session in Codex.")
                    }
                    claudeReturnControl(item, subject: subject)
                    NotchButton(title: "Dismiss") { model.dismissAgent(item.id) }
                        .accessibilityLabel("Dismiss completion: \(subject)")
                case .waiting, .running:
                    if item.session.source == .codex {
                        NotchButton(title: "Open in Codex") { model.openAgent(item.session) }
                            .disabled(model.openingTask)
                            .accessibilityLabel("Open in Codex: \(subject)")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rowTitle(item)), \(subject)")
    }

    @ViewBuilder
    private func claudeReturnMessage(_ session: AgentSessionIdentity) -> some View {
        if !model.canOpenClaude(session) {
            Text(model.claudeReturnUnavailableMessage)
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func claudeReturnControl(_ item: AgentAttentionItem, subject: String, emphasized: Bool = false) -> some View {
        if item.session.source == .claude {
            if model.canOpenClaude(item.session) {
                NotchButton(title: "Open in Claude", emphasized: emphasized) { model.openAgent(item.session) }
                    .disabled(model.openingTask)
                    .accessibilityLabel("Open in Claude: \(subject)")
                    .accessibilityHint("Open the exact Claude Ghostty tab for this session.")
            } else if !model.ghosttyEnabled {
                NotchButton(title: "Set up Ghostty", emphasized: emphasized, action: model.showControls)
                    .accessibilityLabel("Set up Ghostty: \(subject)")
                    .accessibilityHint("Opens Steer controls to enable Ghostty controls.")
            }
        }
    }

    private var stripLabel: String {
        let summary = strip
        var parts: [String] = [summary.subject]
        let sessions = summary.sessions.count + summary.overflow
        if sessions > 1 { parts.append("\(sessions) sessions") }
        if summary.working { parts.append("working") }
        if summary.toCheck > 0 { parts.append("\(summary.toCheck) to check") }
        if let limit = model.currentFiveHourLimit { parts.append("five-hour limit \(limit.percentText) used") }
        if let limit = model.currentWeeklyLimit { parts.append("weekly limit \(limit.percentText) used") }
        else { parts.append("weekly limit unknown") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let summary = strip
        VStack(alignment: .leading, spacing: 0) {
            Button(action: model.expand) {
                // One sprite per session (at most three), the overflow mark, and the to-check count
                // sit together in the wing left of the housing; the weekly limit reading sits in the
                // wing right of it, with the five-hour reading ahead of it while Codex reports one.
                // The gap between them is the housing itself. The name is read from
                // the open queue and the accessibility label, never from the strip. The 8pt content
                // inset on each side comes out of the wings.
                let layout = model.stripLayout
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        if summary.sessions.isEmpty {
                            Sprite(working: false, reduceMotion: model.reduceMotion)
                        }
                        ForEach(summary.sessions, id: \.session) { session in
                            Sprite(working: session.working, reduceMotion: model.reduceMotion, color: session.color)
                        }
                        if summary.overflow > 0 {
                            Text("+\(summary.overflow)")
                                .font(NotchStyle.mono(11, .medium)).monospacedDigit()
                                .foregroundStyle(NotchStyle.text).lineLimit(1).fixedSize()
                                .accessibilityLabel("\(summary.overflow) more sessions")
                        }
                        if summary.toCheck > 0 { Badge(count: summary.toCheck) }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 4)
                    .frame(width: max(0, layout.leading - 8))
                    Color.clear.frame(width: layout.gap)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if let fiveHour = model.currentFiveHourLimit {
                            UsageLimitReading(limit: fiveHour, caption: "5h").padding(.trailing, 8)
                        }
                        UsageLimitReading(limit: model.currentWeeklyLimit)
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            if item.kind == .earlierOutcome && (index == 0 || visibleItems[index - 1].kind != .earlierOutcome) {
                                Text("Earlier").font(NotchStyle.mono(11, .semibold)).foregroundStyle(NotchStyle.dim)
                            }
                            attentionRow(item)
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
                        }
                    }
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
    }
}
