import AppKit

/// Tandem's paired return paths: repeat actions and a companion working beside you.
/// One vector source supplies the Dock, title bar and monochrome menu bar mark.
enum AutomaterBrand {
    static let name = "Tandem"

    private static func track(_ second: Bool, in rect: CGRect, arrowheads: Bool = true) -> CGPath {
        let path = CGMutablePath()
        // The second track is a half-turn of the first; the gap stays legible at 18 px.
        path.move(to: CGPoint(x: 67, y: 75))
        path.addLine(to: CGPoint(x: 42, y: 75))
        path.addCurve(to: CGPoint(x: 42, y: 42), control1: CGPoint(x: 20, y: 75), control2: CGPoint(x: 20, y: 42))
        path.addLine(to: CGPoint(x: 49, y: 42))
        let filled = CGMutablePath()
        filled.addPath(path.copy(strokingWithWidth: 10, lineCap: .round, lineJoin: .round, miterLimit: 2))
        if arrowheads {
            filled.move(to: CGPoint(x: 59, y: 42))
            filled.addLine(to: CGPoint(x: 47, y: 52))
            filled.addQuadCurve(to: CGPoint(x: 45, y: 50), control: CGPoint(x: 45, y: 53))
            filled.addLine(to: CGPoint(x: 45, y: 34))
            filled.addQuadCurve(to: CGPoint(x: 48, y: 33), control: CGPoint(x: 45, y: 31))
            filled.closeSubpath()
        }
        let rotation = second ? CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 100, ty: 100) : .identity
        let transform = rotation.concatenating(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 100))
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        var mapping = transform
        return filled.copy(using: &mapping)!
    }

    static func glyph(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addPath(track(false, in: rect))
        path.addPath(track(true, in: rect))
        return path
    }

    static func icon(side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let tile = rect.insetBy(dx: side * 0.06, dy: side * 0.06)
            let outline = CGPath(roundedRect: tile, cornerWidth: side * 0.205,
                                 cornerHeight: side * 0.205, transform: nil)
            context.saveGState()
            context.addPath(outline)
            context.clip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
                CGColor(srgbRed: 0.99, green: 0.98, blue: 0.95, alpha: 1),
                CGColor(srgbRed: 0.87, green: 0.88, blue: 0.86, alpha: 1)
            ] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: tile.midX, y: tile.maxY),
                                       end: CGPoint(x: tile.midX, y: tile.minY), options: [])
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.7))
            context.setLineWidth(side * 0.002)
            context.addPath(outline); context.strokePath()
            context.restoreGState()
            let mark = rect.insetBy(dx: side * 0.09, dy: side * 0.09)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -side * 0.007), blur: side * 0.016,
                              color: CGColor(srgbRed: 0.06, green: 0.15, blue: 0.28, alpha: 0.12))
            for second in [false, true] {
                context.setFillColor(second
                    ? CGColor(srgbRed: 0.05, green: 0.42, blue: 0.48, alpha: 1)
                    : CGColor(srgbRed: 0.16, green: 0.31, blue: 0.75, alpha: 1))
                context.addPath(track(second, in: mark)); context.fillPath()
            }
            context.restoreGState()
            return true
        }
    }

    static let menuBarIcon: NSImage = {
        // Omit the small arrowhead cutouts and fit the ink to 16 pt, rather
        // than shrinking the entire 100-unit icon canvas into the status bar.
        let paths = CGMutablePath()
        paths.addPath(track(false, in: CGRect(x: 0, y: 0, width: 100, height: 100), arrowheads: false))
        paths.addPath(track(true, in: CGRect(x: 0, y: 0, width: 100, height: 100), arrowheads: false))
        let bounds = paths.boundingBoxOfPath
        let scale = 16 / max(bounds.width, bounds.height)
        let artwork = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(paths)
            context.fillPath()
            return true
        }
        let image = artwork.tiffRepresentation.flatMap { NSImage(data: $0) } ?? artwork
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = name
        return image
    }()
}
