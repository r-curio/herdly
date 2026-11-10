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
    let reduceMotion: Bool
    /// Owned by the row, which moves focus when a focused well's subagent finishes (`OpenRunningRow.Focus`).
    let focus: FocusState<OpenRunningRow.Shown?>.Binding
    let select: (OpenRunningRow.Shown) -> Void

    var body: some View {
        WrappingRow(spacing: 4) {
            well(.session, title: "Session", label: "Show session")
            ForEach(subagents) { subagent in
                well(.subagent(subagent.id), title: subagent.name, label: "Show \(subagent.name) subagent")
            }
        }
    }

    private func well(_ choice: OpenRunningRow.Shown, title: String, label: String) -> some View {
        let isSelected = choice == selected
        return Button { select(choice) } label: {
            HStack(spacing: 6) {
                if case .subagent = choice { WellSprite(kind: sprite, color: color, reduceMotion: reduceMotion) }
                Text(title).lineLimit(1).truncationMode(.tail)
            }
            .frame(minHeight: 14)
        }
        .buttonStyle(NotchButtonStyle(selected: isSelected, verticalPadding: 2))
        .focused(focus, equals: choice)
        // Space activates a focused button natively. Return does not: the panel's key handler takes
        // it for the selected queue row (`NotchPanel.keyDown`), which would close this row instead,
        // so a focused well claims Return here. Escape keeps its panel-wide meaning.
        .onKeyPress(.return) {
            select(choice)
            return .handled
        }
        .modifier(NotchFocusRing(focused: focus.wrappedValue == choice))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The session's standing sprite at two-thirds size, black on an inverted well.
private struct WellSprite: View {
    let kind: SpriteKind
    let color: Int
    let reduceMotion: Bool
    @Environment(\.notchButtonInverted) private var inverted

    var body: some View {
        Sprite(kind: kind, working: false, reduceMotion: reduceMotion, color: color,
               cellSize: Sprite.subagentCell, tint: inverted ? .black : nil)
    }
}

/// Lays subviews left to right at their own size, `spacing` apart, starting a new line, `spacing`
/// below, when the next one would pass the proposed width. No subview is offered more than that
/// width, so a well with a long name truncates its label rather than running past the edge.
private struct WrappingRow: Layout {
    let spacing: CGFloat

    /// Each subview's size when offered at most `width`.
    private func sizes(_ width: CGFloat, _ subviews: Subviews) -> [CGSize] {
        let offer = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        return subviews.map { subview in
            let size = subview.sizeThatFits(offer)
            return CGSize(width: min(size.width, width), height: size.height)
        }
    }

    private func lines(_ width: CGFloat, _ sizes: [CGSize]) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var lines: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, size) in sizes.enumerated() {
            if let last = lines.last, last.width + spacing + size.width <= width {
                lines[lines.count - 1].indices.append(index)
                lines[lines.count - 1].width += spacing + size.width
                lines[lines.count - 1].height = max(last.height, size.height)
            } else {
                lines.append(([index], size.width, size.height))
            }
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = lines(width, sizes(width, subviews))
        let height: CGFloat = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(lines.count - 1, 0))
        // Never wider than the wells need, so an unconstrained proposal gets a finite size.
        let widest = lines.reduce(0) { max($0, $1.width) }
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(bounds.width, subviews)
        var y = bounds.minY
        for line in lines(bounds.width, sizes) {
            var x = bounds.minX
            for index in line.indices {
                let size = sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }
}
