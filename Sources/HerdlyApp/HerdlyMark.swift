import AppKit

/// Herdly's mark, the "crook h": a lowercase h whose ascender curls into a shepherd's crook. The master
/// artwork is `docs/brand/herdly-crook-h.svg`, drawn on a 256-unit canvas as round-capped strokes 32
/// units wide; this draws the same geometry so neither the menu bar nor the app icon needs a bundled
/// image. `scripts/make-app-icon.swift` compiles this file to build the app icon.
enum HerdlyMark {
    /// The mark's ink bounds on the 256-unit master canvas, stroke included.
    static let inkBounds = CGRect(x: 44, y: 24, width: 168, height: 208)
    private static let strokeWidth: CGFloat = 32

    /// The mark as a stroke-ready path (line width and caps set) whose ink is `glyphHeight` tall,
    /// centred on `center`, in a y-up coordinate space.
    static func path(glyphHeight: CGFloat, center: CGPoint) -> NSBezierPath {
        let scale = glyphHeight / inkBounds.height
        // Master coordinates run y-down; map them into a y-up space around `center`.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: center.x + (x - inkBounds.midX) * scale,
                    y: center.y - (y - inkBounds.midY) * scale)
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
        return path
    }

    /// A template image for the menu bar status item. macOS tints a template for light, dark, and
    /// highlighted menu bars, so the mark keeps the system's own menu bar colour.
    static func menuBarImage(pointSize: CGFloat = 18, glyphHeight: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            NSColor.black.setStroke()
            path(glyphHeight: glyphHeight, center: CGPoint(x: rect.midX, y: rect.midY)).stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Herdly"
        return image
    }

    /// Draws the app icon ("Night Pasture") into the current graphics context on a y-up `canvas`
    /// square. The master is `docs/brand/herdly-app-icon.svg`, on a 1024-unit canvas:
    /// - the macOS icon-grid body (824 units) in black lit softly from the top, with a soft drop shadow,
    ///   fine grain so the gradient never bands, and a glass rim brightest along the top edge;
    /// - a faint dot grid, the herd, fading down the field;
    /// - the mark, 460 units tall, in white settling to light grey toward its feet, so it reads as lit
    ///   from the same source as the tile.
    static func drawAppIcon(in canvas: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let unit = canvas.width / 1024
        // Master units (y-down, 1024 canvas) to this context's y-up space.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: canvas.minX + x * unit, y: canvas.maxY - y * unit)
        }
        let body = CGRect(x: canvas.minX + 100 * unit, y: canvas.minY + 100 * unit, width: 824 * unit, height: 824 * unit)
        let shape = squircle(in: body).cgPath
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func gradient(_ stops: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)]) -> CGGradient {
            let colors = stops.map { CGColor(srgbRed: $0.1, green: $0.2, blue: $0.3, alpha: $0.4) }
            return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops.map(\.0))!
        }

        // Body: drop shadow, then black lit from above.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit,
                          color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0.01, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(shape)
        context.clip()
        let grey: (CGFloat, CGFloat) -> (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = { ($0, $1, $1, $1, 1) }
        context.drawRadialGradient(
            gradient([grey(0, 0.165), grey(0.2, 0.125), grey(0.4, 0.082), grey(0.6, 0.047), grey(0.8, 0.024), grey(1, 0.008)]),
            startCenter: point(512, 100), startRadius: 0, endCenter: point(512, 100), endRadius: 906 * unit,
            options: [.drawsAfterEndLocation])
        drawGrain(in: context, rect: body)
        // The herd: a dot grid fading from 10% to 2% white down the field.
        for row in stride(from: 160, to: 900, by: 48) {
            let alpha = 0.10 - 0.08 * CGFloat(row - 160) / CGFloat(852 - 160)
            context.setFillColor(CGColor(gray: 1, alpha: alpha))
            for column in stride(from: 160, to: 900, by: 48) {
                let center = point(CGFloat(column), CGFloat(row))
                context.fillEllipse(in: CGRect(x: center.x - 5 * unit, y: center.y - 5 * unit, width: 10 * unit, height: 10 * unit))
            }
        }
        context.restoreGState()

        // Glass rim: 28% white along the top, settling to 4% by the bottom.
        context.saveGState()
        context.addPath(shape.copy(strokingWithWidth: 4 * unit, lineCap: .butt, lineJoin: .round, miterLimit: 10))
        context.clip()
        context.drawLinearGradient(
            gradient([(0, 1, 1, 1, 0.28), (0.25, 1, 1, 1, 0.06), (1, 1, 1, 1, 0.04)]),
            start: point(512, 100), end: point(512, 924), options: [])
        context.restoreGState()

        // The mark: white at its top, cooling to light grey (#A8A8AD) at its feet.
        let glyphHeight = 460 * unit
        let mark = path(glyphHeight: glyphHeight, center: point(512, 506)).cgPath
        let scale = glyphHeight / inkBounds.height
        context.saveGState()
        context.addPath(mark.copy(strokingWithWidth: strokeWidth * scale, lineCap: .round, lineJoin: .round, miterLimit: 10))
        context.clip()
        context.drawLinearGradient(
            gradient([(0, 1, 1, 1, 1), (1, 0xA8 / 255, 0xA8 / 255, 0xAD / 255, 1)]),
            start: point(512, 506 + (40 - 128) * scale / unit), end: point(512, 506 + (232 - 128) * scale / unit),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    /// Fine white grain at up to 5% opacity over `rect`, from a fixed seed so every build draws the
    /// same icon. It breaks up the banding a smooth dark gradient shows at icon sizes.
    private static func drawGrain(in context: CGContext, rect: CGRect) {
        let width = max(1, Int(rect.width.rounded())), height = max(1, Int(rect.height.rounded()))
        var state: UInt64 = 0x48455244_4C59  // "HERDLY"
        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in alpha.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            alpha[index] = UInt8(truncatingIfNeeded: (state >> 33) % 14)  // 0 to 5% of 255
        }
        guard let provider = CGDataProvider(data: Data(alpha) as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.alphaOnly.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        context.saveGState()
        context.clip(to: rect, mask: mask)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.restoreGState()
    }

    /// The continuous-corner icon body: a superellipse (exponent 5) close to the macOS icon shape.
    private static func squircle(in rect: CGRect) -> NSBezierPath {
        let shape = NSBezierPath()
        let steps = 720
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let cosine = cos(angle), sine = sin(angle)
            let x = pow(abs(cosine), 2.0 / 5) * (cosine < 0 ? -1 : 1)
            let y = pow(abs(sine), 2.0 / 5) * (sine < 0 ? -1 : 1)
            let point = NSPoint(x: rect.midX + x * rect.width / 2, y: rect.midY + y * rect.height / 2)
            step == 0 ? shape.move(to: point) : shape.line(to: point)
        }
        shape.close()
        return shape
    }
}
