import HerdlyCore
import SwiftUI

/// The opened working row's switcher (#397, Paper H2 "E · Switcher"): a "Session" well, then one well
/// per running subagent, oldest first, each with the session's sprite at two-thirds size before its
/// name. The selected well is drawn pressed (ink fill, black text, its sprite black). Wells sit 4pt
/// apart and wrap to further lines; none is hidden. Which well is selected is `OpenRunningRow`'s rule;
/// this view only draws it and reports a choice.
struct SubagentSwitcher: View {
    let subagents: [SubagentActivity]
    let selected: OpenRunningRow.Shown
    let sprite: SpriteKind
    let color: Int
    let select: (OpenRunningRow.Shown) -> Void
    @FocusState private var focused: OpenRunningRow.Shown?

    var body: some View {
        WrappingRow(spacing: 4) {
            well(.session, title: "Session", label: "Show session")
            ForEach(subagents) { subagent in
                well(.subagent(subagent.id), title: subagent.name, label: "Show \(subagent.name) subagent")
            }
        }
        // A focused well whose subagent finished leaves with it; focus moves to "Session" so it stays
        // in the row rather than falling out of the panel.
        .onChange(of: subagents.map(\.id)) { _, ids in
            if case let .subagent(id)? = focused, !ids.contains(id) { focused = .session }
        }
    }

    private func well(_ choice: OpenRunningRow.Shown, title: String, label: String) -> some View {
        let isSelected = choice == selected
        let isFocused = focused == choice
        return Button { select(choice) } label: {
            HStack(spacing: 6) {
                if case .subagent = choice { WellSprite(kind: sprite, color: color) }
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(SwitcherWellStyle(selected: isSelected))
        .focused($focused, equals: choice)
        // Return and Space choose the focused well; Escape keeps its panel-wide meaning.
        .onKeyPress(keys: [.return, .space]) { _ in
            select(choice)
            return .handled
        }
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(NotchStyle.ink.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// `button-notch` with the switcher's tighter 2pt vertical padding (Paper "E · Switcher"): a well with
/// an ink 11pt regular label, inverted to an ink fill with black text while selected or pressed.
private struct SwitcherWellStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let inverted = configuration.isPressed || selected
        configuration.label
            .font(NotchStyle.mono(11))
            .frame(minHeight: 14)
            .foregroundStyle(inverted ? Color.black : NotchStyle.ink)
            .environment(\.switcherWellInverted, inverted)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(inverted ? NotchStyle.ink : NotchStyle.well,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The session's standing sprite at two-thirds size, black on an inverted well.
private struct WellSprite: View {
    let kind: SpriteKind
    let color: Int
    @Environment(\.switcherWellInverted) private var inverted

    var body: some View {
        Sprite(kind: kind, working: false, reduceMotion: true, color: color,
               cellSize: Sprite.subagentCell, tint: inverted ? .black : nil)
    }
}

private extension EnvironmentValues {
    @Entry var switcherWellInverted = false
}

/// Lays subviews left to right at their own size, `spacing` apart, starting a new line, `spacing`
/// below, when the next one would pass the proposed width.
private struct WrappingRow: Layout {
    let spacing: CGFloat

    private func lines(_ width: CGFloat, _ subviews: Subviews) -> [(indices: [Int], height: CGFloat)] {
        var lines: [(indices: [Int], height: CGFloat)] = []
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if lines.isEmpty || (x > 0 && x + size.width > width) {
                lines.append(([], 0))
                x = 0
            }
            lines[lines.count - 1].indices.append(index)
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
            x += size.width + spacing
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = lines(width, subviews)
        let gaps = CGFloat(max(lines.count - 1, 0))
        let height: CGFloat = lines.reduce(0) { $0 + $1.height } + spacing * gaps
        var widest: CGFloat = 0
        for line in lines {
            var lineWidth: CGFloat = 0
            for index in line.indices { lineWidth += subviews[index].sizeThatFits(.unspecified).width }
            lineWidth += spacing * CGFloat(max(line.indices.count - 1, 0))
            widest = max(widest, lineWidth)
        }
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(bounds.width, subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }
}
