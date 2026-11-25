import HerdlyCore
import SwiftUI

/// The opened working row's switcher (#397, Paper H2 "E · Switcher"): a "Session" well, then one well
/// per running subagent, oldest first, each with the session's sprite at two-thirds size before its
/// name. The selected well is drawn pressed (ink fill, black text, its sprite in the session colour). Wells sit 4pt
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

/// The session's standing sprite at two-thirds size, in the session's colour whether or not its
/// well is selected.
private struct WellSprite: View {
    let kind: SpriteKind
    let color: Int
    let reduceMotion: Bool

    var body: some View {
        Sprite(kind: kind, working: false, reduceMotion: reduceMotion, color: color,
               cellSize: Sprite.subagentCell)
    }
}
