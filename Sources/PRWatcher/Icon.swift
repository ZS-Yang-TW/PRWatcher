import AppKit

enum StatusIcon {
    static var badgeSymbol = "bell.fill"

    /// Pull-request glyph (two branches, the right one merging back with an arrow).
    /// With `badge`, a yellow symbol replaces the bottom-right node; that version can't be
    /// a template image, so it resolves labelColor against the menu bar's appearance at draw time.
    static func make(badge: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            NSColor.labelColor.set()
            let r: CGFloat = 2.3
            func ring(_ x: CGFloat, _ y: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }

            let path = NSBezierPath()
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            // Left branch.
            path.append(ring(4.5, 3.5))
            path.move(to: NSPoint(x: 4.5, y: 3.5 + r))
            path.line(to: NSPoint(x: 4.5, y: 14.5 - r))
            path.append(ring(4.5, 14.5))
            // Right branch curving back to the left with an arrowhead.
            if !badge { path.append(ring(13.5, 14.5)) }
            path.move(to: NSPoint(x: 13.5, y: badge ? 7.2 : 14.5 - r))
            path.line(to: NSPoint(x: 13.5, y: 7))
            path.curve(to: NSPoint(x: 10.5, y: 4), controlPoint1: NSPoint(x: 13.5, y: 5.3), controlPoint2: NSPoint(x: 12.2, y: 4))
            path.line(to: NSPoint(x: 8, y: 4))
            path.move(to: NSPoint(x: 10, y: 2))
            path.line(to: NSPoint(x: 8, y: 4))
            path.line(to: NSPoint(x: 10, y: 6))
            path.stroke()

            // Palette: single-layer symbols take the first color; ones like
            // exclamationmark.circle.fill draw the mark in the first and the disc in the second.
            let palette = NSImage.SymbolConfiguration(paletteColors: badgeSymbol.hasSuffix("circle.fill")
                ? [.black, .systemYellow] : [.systemYellow])
            if badge, let symbol = NSImage(systemSymbolName: badgeSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold).applying(palette)) {
                // Aspect-fit into the bottom-right corner.
                let box = NSRect(x: 9, y: 7, width: 11, height: 11)
                let k = min(box.width / symbol.size.width, box.height / symbol.size.height)
                let w = symbol.size.width * k, h = symbol.size.height * k
                symbol.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
            }
            return true
        }
        image.isTemplate = !badge
        return image
    }
}
