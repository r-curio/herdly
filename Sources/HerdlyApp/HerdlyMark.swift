import AppKit

/// Herdly's mark, the "crook h": a lowercase h whose ascender curls into a shepherd's crook. The master
/// artwork is `docs/brand/herdly-crook-h.svg`, drawn on a 256-unit canvas as round-capped strokes 32
/// units wide; this draws the same geometry so the menu bar needs no bundled image.
enum HerdlyMark {
    /// The mark's ink bounds on the 256-unit master canvas, stroke included.
    private static let inkBounds = CGRect(x: 44, y: 24, width: 168, height: 208)
    private static let strokeWidth: CGFloat = 32

    /// A template image for the menu bar status item. macOS tints a template for light, dark, and
    /// highlighted menu bars, so the mark keeps the system's own menu bar colour.
    static func menuBarImage(pointSize: CGFloat = 18, glyphHeight: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            let scale = glyphHeight / inkBounds.height
            let originX = (rect.width - inkBounds.width * scale) / 2
            let originY = (rect.height - inkBounds.height * scale) / 2
            // Master coordinates run y-down; map them into this y-up rect.
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: originX + (x - inkBounds.minX) * scale,
                        y: rect.height - (originY + (y - inkBounds.minY) * scale))
            }
            let path = NSBezierPath()
            // Stem and crook: up the stem, over the top, and down the short hooked tip.
            path.move(to: point(116, 216))
            path.line(to: point(116, 68))
            path.appendArc(withCenter: point(88, 68), radius: 28 * scale, startAngle: 0, endAngle: 180, clockwise: false)
            path.line(to: point(60, 84))
            // Shoulder and right leg.
            path.move(to: point(116, 140))
            path.appendArc(withCenter: point(156, 140), radius: 40 * scale, startAngle: 180, endAngle: 0, clockwise: true)
            path.line(to: point(196, 216))
            path.lineWidth = strokeWidth * scale
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Herdly"
        return image
    }
}
