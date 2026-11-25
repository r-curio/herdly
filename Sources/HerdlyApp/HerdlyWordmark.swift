import SwiftUI

/// The lowercase "herdly" wordmark. The master artwork is `docs/brand/herdly-wordmark.svg`, drawn on
/// an 856x308-unit view box (origin 28,8) as round-capped, round-joined strokes 32 units wide; this
/// draws the same geometry so the app bundles no image. Its "h" is the crook h of `HerdlyMark`.
/// The shape is the stroke's outline, so fill it with the colour the mark should take.
struct HerdlyWordmark: Shape {
    /// The master view box, stroke included.
    static let viewBox = CGRect(x: 28, y: 8, width: 856, height: 308)
    private static let strokeWidth: CGFloat = 32

    func path(in rect: CGRect) -> Path {
        let box = Self.viewBox
        let scale = min(rect.width / box.width, rect.height / box.height)
        let origin = CGPoint(x: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
        // Master coordinates run y-down, like SwiftUI's. An arc's `clockwise: true` turns toward
        // decreasing angles, which is the SVG's sweep flag 0.
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + (x - box.minX) * scale, y: origin.y + (y - box.minY) * scale)
        }
        func arc(_ path: inout Path, _ x: CGFloat, _ y: CGFloat, _ radius: CGFloat,
                 from start: Double, to end: Double, clockwise: Bool) {
            path.addArc(center: p(x, y), radius: radius * scale, startAngle: .degrees(start),
                        endAngle: .degrees(end), clockwise: clockwise)
        }
        var path = Path()
        // h: stem and crook, then shoulder and right leg.
        path.move(to: p(116, 216)); path.addLine(to: p(116, 68))
        arc(&path, 88, 68, 28, from: 0, to: -180, clockwise: true)
        path.addLine(to: p(60, 84))
        path.move(to: p(116, 140))
        arc(&path, 156, 140, 40, from: 180, to: 360, clockwise: false)
        path.addLine(to: p(196, 216))
        // e: crossbar, bowl, and the tail ending at 30 degrees.
        path.move(to: p(272, 158)); path.addLine(to: p(352, 158)); path.addLine(to: p(352, 140))
        arc(&path, 312, 140, 40, from: 0, to: -180, clockwise: true)
        path.addLine(to: p(272, 176))
        arc(&path, 312, 176, 40, from: 180, to: 30, clockwise: true)
        // r: stem, then the shoulder running into its flag.
        path.move(to: p(428, 216)); path.addLine(to: p(428, 100))
        path.move(to: p(428, 140))
        arc(&path, 468, 140, 40, from: 180, to: 270, clockwise: false)
        path.addLine(to: p(484, 100))
        // d: bowl, then the stem.
        path.move(to: p(620, 140))
        arc(&path, 580, 140, 40, from: 0, to: -180, clockwise: true)
        path.addLine(to: p(540, 176))
        arc(&path, 580, 176, 40, from: 180, to: 0, clockwise: true)
        path.move(to: p(620, 40)); path.addLine(to: p(620, 216))
        // l
        path.move(to: p(696, 40)); path.addLine(to: p(696, 216))
        // y: the cup, then the descender hooking left.
        path.move(to: p(772, 100)); path.addLine(to: p(772, 176))
        arc(&path, 812, 176, 40, from: 180, to: 0, clockwise: true)
        path.move(to: p(852, 100)); path.addLine(to: p(852, 250))
        arc(&path, 822, 250, 30, from: 0, to: 90, clockwise: false)
        path.addLine(to: p(794, 280))
        return path.strokedPath(StrokeStyle(lineWidth: Self.strokeWidth * scale, lineCap: .round, lineJoin: .round))
    }
}
