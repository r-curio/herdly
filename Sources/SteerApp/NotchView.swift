import AppKit
import SwiftUI
import SteerCore

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

/// A control in the panel's own vocabulary: a dark well that inverts to light when pressed and
/// shows a visible ring when it has keyboard focus.
struct NotchButtonStyle: ButtonStyle {
    var emphasized = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NotchStyle.mono(11, emphasized ? .semibold : .regular))
            .foregroundStyle(configuration.isPressed ? Color.black : (enabled ? NotchStyle.ink : NotchStyle.dim))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(configuration.isPressed ? NotchStyle.ink : NotchStyle.well,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(enabled ? 1 : 0.6)
    }
}

struct NotchButton: View {
    let title: String
    var emphasized = false
    let action: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        Button(title, action: action)
            .buttonStyle(NotchButtonStyle(emphasized: emphasized))
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(NotchStyle.ink.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
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

    private var strip: StripSummary {
        StripSummary.make(items: model.orderedAttentionItems, testPending: model.attention.pending && !model.desktopForeground,
                          names: model.threadNames)
    }

    private func rowTitle(_ item: AttentionItem) -> String {
        switch item.kind {
        case .actionableRequest: return "Permission needed"
        case .handedBackRequest: return "Continue in Codex"
        case .question: return "Codex needs an answer"
        case .completion: return item.completion?.source == .cli ? "Codex CLI finished" : "Codex desktop finished"
        case .running: return item.running?.source == .cli ? "Codex CLI working" : "Codex desktop working"
        }
    }

    private func sessionLabel(_ item: AttentionItem) -> String { StripSummary.sessionLabel(item.session, names: model.threadNames) }

    /// The color the strip gives this session, or its preferred color if it is not on the strip.
    private func spriteColor(for session: UUID) -> Int {
        strip.sessions.first { $0.session == session }?.color ?? StripSummary.preferredColor(for: session)
    }

    private func rowSubject(_ item: AttentionItem) -> String {
        if model.threadNames[item.session] != nil { return sessionLabel(item) }
        guard let task = item.request?.details?.taskName, !task.isEmpty else { return sessionLabel(item) }
        return "\(task), \(sessionLabel(item))"
    }

    /// Which rows the open panel shows: everything while the user is in it, otherwise only the item
    /// that opened it.
    private var visibleItems: [AttentionItem] {
        if model.showAll { return model.orderedAttentionItems }
        if let id = model.spotlightItem { return model.orderedAttentionItems.filter { $0.id == id } }
        return []
    }

    private var showsTestRow: Bool {
        model.attention.pending && !model.desktopForeground && (model.showAll || (model.spotlightItem == nil && model.attention.expanded))
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?, selectable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).foregroundStyle(NotchStyle.dim).frame(width: 58, alignment: .leading)
            if selectable {
                Text(value ?? "Not provided by Codex").foregroundStyle(value == nil ? NotchStyle.dim : NotchStyle.text).textSelection(.enabled)
            } else {
                Text(value ?? "Not provided by Codex").foregroundStyle(value == nil ? NotchStyle.dim : NotchStyle.text)
            }
        }
        .font(NotchStyle.mono(11)).fixedSize(horizontal: false, vertical: true)
    }

    /// One question as Codex's own panel shows it: header with the "1 of N" pager, the question, and
    /// the option labels. Descriptions and the free-text field stay in Codex.
    @ViewBuilder
    private func prompt(_ prompt: QuestionPrompt, index: Int, of total: Int) -> some View {
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
                HStack(alignment: .top, spacing: 8) {
                    Text("\(offset + 1)").foregroundStyle(NotchStyle.dim).frame(width: 14, alignment: .trailing)
                    Text(label).foregroundStyle(NotchStyle.text)
                }
                .font(NotchStyle.mono(11)).fixedSize(horizontal: false, vertical: true)
            }
            if prompt.truncated {
                Text("Shortened; the full question is in Codex.").font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
            }
        }
    }

    @ViewBuilder
    private func questionBody(_ question: AttentionQuestion) -> some View {
        if question.prompts.isEmpty {
            Text("Codex asked a question Steer could not read; answer it in Codex.")
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
        } else {
            prompt(question.prompts[0], index: 0, of: question.prompts.count)
            if question.prompts.count > 1 {
                DisclosureGroup("Show all \(question.prompts.count) questions") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(question.prompts.dropFirst().enumerated()), id: \.offset) { offset, rest in
                            prompt(rest, index: offset + 1, of: question.prompts.count)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text)
                .accessibilityLabel("Show all \(question.prompts.count) questions")
            }
        }
        Text("Answer in Codex. This clears when Codex records the answer, the turn ends, or the session ends.")
            .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func attentionRow(_ item: AttentionItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if item.kind == .running {
                    Sprite(working: true, reduceMotion: model.reduceMotion, color: spriteColor(for: item.session)).offset(y: -1)
                }
                Text(rowTitle(item)).font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(sessionLabel(item)).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.dim)
                    .lineLimit(1).truncationMode(.tail)
            }
            switch item.kind {
            case .handedBackRequest:
                Text("Handed back with no decision. Steer has not seen an answer yet; this clears when Codex records one, the turn ends, or the session ends.")
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
            case .completion:
                if item.completion?.uncertain == true {
                    Text("Queued before Steer last started. You may already have seen this result; Steer cannot verify it.")
                        .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).fixedSize(horizontal: false, vertical: true)
                }
            case .question:
                if let question = item.question { questionBody(question) }
            case .actionableRequest, .running:
                EmptyView()
            }
            if let details = item.request?.details {
                // Long commands and reasons wrap in full; nothing is truncated with an ellipsis.
                VStack(alignment: .leading, spacing: 3) {
                    if let name = model.threadNames[item.session] { detail("thread", name, selectable: true) }
                    detail("task", details.taskName)
                    detail("project", details.project)
                    detail("action", details.action)
                    detail("command", details.command, selectable: true)
                    detail("reason", details.reason, selectable: true)
                }
                if let longText = details.longText {
                    DisclosureGroup("Show full request") {
                        Text(longText).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text)
                    .accessibilityLabel("Show full request for \(rowSubject(item))")
                }
            }
            HStack(spacing: 6) {
                switch item.kind {
                case .actionableRequest:
                    if item.request?.source == .cli {
                        NotchButton(title: "Approve once", emphasized: true) { if let request = item.request { model.decide(request, as: .allowOnce) } }
                            .accessibilityLabel("Approve once: \(rowSubject(item))")
                        NotchButton(title: "Deny") { if let request = item.request { model.decide(request, as: .deny) } }
                            .accessibilityLabel("Deny: \(rowSubject(item))")
                    }
                    NotchButton(title: "Open in Codex") { if let request = item.request { model.openApprovalInCodex(request) } }
                        .disabled(model.openingTask)
                        .accessibilityLabel("Open in Codex: \(rowSubject(item))")
                        .accessibilityHint("Hands this request back to Codex's own prompt.")
                case .handedBackRequest:
                    NotchButton(title: "Open in Codex") {
                        if let request = item.request { model.openAttentionSession(source: request.source, session: request.session) }
                    }
                    .disabled(model.openingTask)
                    .accessibilityLabel("Open in Codex: \(rowSubject(item))")
                case .question:
                    NotchButton(title: "Open in Codex", emphasized: true) {
                        if let question = item.question { model.openAttentionSession(source: question.source, session: question.session) }
                    }
                    .disabled(model.openingTask)
                    .accessibilityLabel("Open in Codex: \(rowSubject(item))")
                    .accessibilityHint("Answer the question in Codex's own panel.")
                    NotchButton(title: "Dismiss") { if let question = item.question { model.dismissQuestion(question) } }
                        .accessibilityLabel("Dismiss question: \(rowSubject(item))")
                case .completion:
                    NotchButton(title: "Open in Codex") {
                        if item.completion?.source == .cli { model.openCLI(item.session) } else { model.openDesktop(item.session) }
                    }
                    .disabled(model.openingTask)
                    .accessibilityLabel("Open in Codex: \(rowSubject(item))")
                    NotchButton(title: "Dismiss") { if let completion = item.completion { model.dismissAttention(completion) } }
                        .accessibilityLabel("Dismiss completion: \(rowSubject(item))")
                case .running:
                    NotchButton(title: "Open in Codex") {
                        if item.running?.source == .cli { model.openCLI(item.session) } else { model.openDesktop(item.session) }
                    }
                    .disabled(model.openingTask)
                    .accessibilityLabel("Open in Codex: \(rowSubject(item))")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rowTitle(item)), \(rowSubject(item))")
    }

    private var stripLabel: String {
        let summary = strip
        var parts: [String] = [summary.subject]
        let sessions = summary.sessions.count + summary.overflow
        if sessions > 1 { parts.append("\(sessions) sessions") }
        if summary.working { parts.append("working") }
        if summary.toCheck > 0 { parts.append("\(summary.toCheck) to check") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let summary = strip
        VStack(alignment: .leading, spacing: 0) {
            Button(action: model.expand) {
                // One sprite per session (at most three) sits in the wing left of the housing; the
                // overflow mark and the count sit in the wing right of it. The gap between them is
                // the housing itself. The name is read from the open queue and the accessibility
                // label, never from the strip. The 8pt content inset on each side comes out of the wings.
                let layout = model.stripLayout
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        if summary.sessions.isEmpty {
                            Sprite(working: false, reduceMotion: model.reduceMotion)
                        }
                        ForEach(summary.sessions, id: \.session) { session in
                            Sprite(working: session.working, reduceMotion: model.reduceMotion, color: session.color)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 4)
                    .frame(width: max(0, layout.leading - 8))
                    Color.clear.frame(width: layout.gap)
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        if summary.overflow > 0 {
                            Text("+\(summary.overflow)")
                                .font(NotchStyle.mono(11, .medium)).monospacedDigit()
                                .foregroundStyle(NotchStyle.text)
                                .accessibilityLabel("\(summary.overflow) more sessions")
                        }
                        if summary.toCheck > 0 { Badge(count: summary.toCheck) }
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
                        ForEach(visibleItems) { item in
                            attentionRow(item)
                        }
                        if model.showAll && model.needsGhosttySetup {
                            Text("Enable Ghostty controls in Steer’s controls window to open these sessions.")
                                .font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text)
                        }
                        if !model.navigationMessage.isEmpty {
                            Text(model.navigationMessage).font(NotchStyle.mono(11)).foregroundStyle(NotchStyle.text)
                        }
                        if showsTestRow {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Test notification").font(NotchStyle.mono(12, .semibold)).foregroundStyle(NotchStyle.ink)
                                NotchButton(title: "Dismiss", action: model.dismissTest).accessibilityLabel("Dismiss test notification")
                            }
                        }
                        if model.showAll {
                            Text("Tab moves between controls · Esc returns to your app")
                                .font(NotchStyle.mono(10)).foregroundStyle(NotchStyle.dim).padding(.top, 2)
                        }
                    }
                    .padding(.bottom, 14)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self,
                                               value: proxy.size.height + model.stripLayout.height + 13)
                    })
                }
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
        .onHover { model.hovering = $0 }
    }
}
