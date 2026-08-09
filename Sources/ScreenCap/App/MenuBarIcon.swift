import AppKit

/// The menu-bar version of the app mark.
///
/// Menu-bar images are template images: macOS supplies the foreground colour,
/// so the mark is intentionally monochrome while retaining the lightning bolt
/// and the four corner brackets from the full application icon.
enum MenuBarIcon {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let unit = rect.width / 18
            let frame = rect.insetBy(dx: 2.2 * unit, dy: 2.2 * unit)
            let arm = 4.0 * unit
            let lineWidth = 1.65 * unit

            NSColor.black.setStroke()
            let brackets = NSBezierPath()
            brackets.lineWidth = lineWidth
            brackets.lineCapStyle = .round
            brackets.lineJoinStyle = .round

            // Top-left and top-right corners.
            brackets.move(to: CGPoint(x: frame.minX, y: frame.maxY - arm))
            brackets.line(to: CGPoint(x: frame.minX, y: frame.maxY))
            brackets.line(to: CGPoint(x: frame.minX + arm, y: frame.maxY))
            brackets.move(to: CGPoint(x: frame.maxX - arm, y: frame.maxY))
            brackets.line(to: CGPoint(x: frame.maxX, y: frame.maxY))
            brackets.line(to: CGPoint(x: frame.maxX, y: frame.maxY - arm))

            // Bottom-left and bottom-right corners.
            brackets.move(to: CGPoint(x: frame.minX, y: frame.minY + arm))
            brackets.line(to: CGPoint(x: frame.minX, y: frame.minY))
            brackets.line(to: CGPoint(x: frame.minX + arm, y: frame.minY))
            brackets.move(to: CGPoint(x: frame.maxX - arm, y: frame.minY))
            brackets.line(to: CGPoint(x: frame.maxX, y: frame.minY))
            brackets.line(to: CGPoint(x: frame.maxX, y: frame.minY + arm))
            brackets.stroke()

            // A deliberately generous bolt, so it stays legible at menu-bar size.
            let bolt = NSBezierPath()
            bolt.move(to: CGPoint(x: rect.midX + 1.9 * unit, y: rect.maxY - 4.0 * unit))
            bolt.line(to: CGPoint(x: rect.midX - 2.2 * unit, y: rect.midY + 0.8 * unit))
            bolt.line(to: CGPoint(x: rect.midX - 0.1 * unit, y: rect.midY + 0.8 * unit))
            bolt.line(to: CGPoint(x: rect.midX - 1.8 * unit, y: rect.minY + 4.0 * unit))
            bolt.line(to: CGPoint(x: rect.midX + 2.2 * unit, y: rect.midY - 0.9 * unit))
            bolt.line(to: CGPoint(x: rect.midX + 0.1 * unit, y: rect.midY - 0.9 * unit))
            bolt.close()
            NSColor.black.setFill()
            bolt.fill()

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppInfo.name
        return image
    }
}
