import SwiftUI

/// Lays subviews left to right at their own size, `spacing` apart, starting a new line, `spacing`
/// below, when the next one would pass the proposed width. No subview is offered more than that
/// width, so a well with a long name truncates its label rather than running past the edge. Each line
/// sits flush left unless `alignment` says otherwise.
struct WrappingRow: Layout {
    let spacing: CGFloat
    /// Where each line sits within the row's width: flush left (the default), centred, or flush right.
    var alignment: HorizontalAlignment = .leading

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

    private func lineOffset(free: CGFloat) -> CGFloat {
        switch alignment {
        case .trailing: max(free, 0)
        case .center: max(free, 0) / 2
        default: 0
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(bounds.width, subviews)
        var y = bounds.minY
        for line in lines(bounds.width, sizes) {
            var x = bounds.minX + lineOffset(free: bounds.width - line.width)
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
