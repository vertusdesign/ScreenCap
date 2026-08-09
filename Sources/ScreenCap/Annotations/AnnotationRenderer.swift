import AppKit

/// Draws annotations into whatever graphics context is current.
///
/// The exact same code path paints the live overlay and bakes the exported image,
/// so what you see while drawing is what lands in the PNG.
enum AnnotationRenderer {

    static func draw(
        _ annotations: [Annotation],
        obfuscation: ObfuscationSource?,
        clipTo clipRect: CGRect? = nil,
        obfuscationBlendMode: CGBlendMode = .destinationOver
    ) {
        guard let context = NSGraphicsContext.current else { return }

        context.saveGraphicsState()
        if let clipRect {
            NSBezierPath(rect: clipRect).addClip()
        }
        for annotation in annotations {
            draw(
                annotation,
                obfuscation: obfuscation,
                obfuscationBlendMode: obfuscationBlendMode
            )
        }
        context.restoreGraphicsState()
    }

    static func draw(
        _ annotation: Annotation,
        obfuscation: ObfuscationSource?,
        obfuscationBlendMode: CGBlendMode = .destinationOver
    ) {
        guard let context = NSGraphicsContext.current else { return }
        let style = annotation.style

        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }

        switch annotation.shape {
        case .pen(let points):
            style.color.setStroke()
            strokePath(smoothPath(through: points), width: style.lineWidth)

        case .marker(let points):
            // Multiply blending is what makes a highlighter read as a highlighter
            // instead of a translucent smear.
            context.compositingOperation = .multiply
            style.color.withAlphaComponent(0.4).setStroke()
            strokePath(smoothPath(through: points), width: max(style.lineWidth * 4, 12))

        case .line(let from, let to):
            style.color.setStroke()
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            strokePath(path, width: style.lineWidth)

        case .arrow(let from, let to, let doubleHeaded):
            style.color.setFill()
            style.color.setStroke()
            drawArrow(from: from, to: to, width: style.lineWidth, doubleHeaded: doubleHeaded)

        case .rectangle(let rect):
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: min(2, rect.width / 4),
                yRadius: min(2, rect.height / 4)
            )
            fillAndStroke(path, style: style)

        case .ellipse(let rect):
            fillAndStroke(NSBezierPath(ovalIn: rect), style: style)

        case .obfuscateRect(let rect):
            // The processed screenshot is an opaque image. Put it behind the
            // transparent annotation pixels already in this layer; drawing it
            // source-over would make an obfuscation region behave like an eraser
            // for every annotation painted before it.
            context.cgContext.setBlendMode(obfuscationBlendMode)
            obfuscation?.draw(
                clip: NSBezierPath(rect: rect),
                style: style.obfuscation.style,
                intensity: style.obfuscation.intensity
            )

        case .obfuscateEllipse(let rect):
            context.cgContext.setBlendMode(obfuscationBlendMode)
            obfuscation?.draw(
                clip: NSBezierPath(ovalIn: rect),
                style: style.obfuscation.style,
                intensity: style.obfuscation.intensity
            )

        case .obfuscateBrush(let points):
            guard let clip = brushOutline(points: points, width: style.obfuscation.brushSize) else { break }
            context.cgContext.setBlendMode(obfuscationBlendMode)
            obfuscation?.draw(
                clip: clip,
                style: style.obfuscation.style,
                intensity: style.obfuscation.intensity
            )

        case .counter(let center, let number, let arrowTo):
            if let arrowTo {
                style.color.setFill()
                style.color.setStroke()
                drawArrow(from: center, to: arrowTo, width: style.counterArrowWidth, doubleHeaded: false)
            }
            drawCounter(at: center, number: number, style: style)

        case .text(let origin, let string):
            drawText(string, at: origin, style: style)

        case .erase(let points, let width):
            erase(points: points, width: width)

        case .eraseRect(let rect):
            eraseShape(NSBezierPath(rect: rect))

        case .eraseEllipse(let rect):
            eraseShape(NSBezierPath(ovalIn: rect))
        }
    }

    /// Rubs out part of the current layer. Only meaningful in a transparent
    /// context — `destinationOut` against the screenshot itself would punch a hole
    /// straight through the capture.
    static func erase(points: [CGPoint], width: CGFloat) {
        guard let context = NSGraphicsContext.current, !points.isEmpty else { return }
        context.saveGraphicsState()
        context.cgContext.setBlendMode(.destinationOut)
        NSColor.black.setStroke()
        NSColor.black.setFill()
        if points.count == 1 {
            let radius = width / 2
            NSBezierPath(ovalIn: CGRect(
                x: points[0].x - radius, y: points[0].y - radius,
                width: width, height: width
            )).fill()
        } else {
            strokePath(smoothPath(through: points), width: width)
        }
        context.restoreGraphicsState()
    }

    /// Shared by `.eraseRect`/`.eraseEllipse`: cuts a filled shape out of
    /// whatever is already on the layer, same as the brush stroke above.
    private static func eraseShape(_ path: NSBezierPath) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.cgContext.setBlendMode(.destinationOut)
        NSColor.black.setFill()
        path.fill()
        context.restoreGraphicsState()
    }

    // MARK: - Shapes

    private static func fillAndStroke(_ path: NSBezierPath, style: ToolStyle) {
        if style.filled {
            style.color.setFill()
            path.fill()
        } else {
            style.color.setStroke()
            strokePath(path, width: style.lineWidth)
        }
    }

    private static func strokePath(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    /// Outline of a round brush stroke, usable as a clipping region.
    static func brushOutline(points: [CGPoint], width: CGFloat) -> NSBezierPath? {
        guard !points.isEmpty else { return nil }
        guard points.count > 1 else {
            let radius = width / 2
            let dot = CGRect(
                x: points[0].x - radius, y: points[0].y - radius,
                width: width, height: width
            )
            return NSBezierPath(ovalIn: dot)
        }
        let stroked = smoothPath(through: points).cgPath.copy(
            strokingWithWidth: width,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        return NSBezierPath(cgPath: stroked)
    }

    private static func drawArrow(from: CGPoint, to: CGPoint, width: CGFloat, doubleHeaded: Bool) {
        let length = from.distance(to: to)
        guard length > 0.5 else { return }

        let headLength = min(max(width * 4.5, 12), length / (doubleHeaded ? 2 : 1))
        let angle = atan2(to.y - from.y, to.x - from.x)

        // Stop the shaft short of each head so the tips stay crisp.
        let shaftStart = doubleHeaded
            ? CGPoint(x: from.x + cos(angle) * headLength * 0.75, y: from.y + sin(angle) * headLength * 0.75)
            : from
        let shaftEnd = CGPoint(
            x: to.x - cos(angle) * headLength * 0.75,
            y: to.y - sin(angle) * headLength * 0.75
        )

        let shaft = NSBezierPath()
        shaft.move(to: shaftStart)
        shaft.line(to: shaftEnd)
        strokePath(shaft, width: width)

        drawArrowhead(at: to, angle: angle, length: headLength, width: width)
        if doubleHeaded {
            drawArrowhead(at: from, angle: angle + .pi, length: headLength, width: width)
        }
    }

    private static func drawArrowhead(at tip: CGPoint, angle: CGFloat, length: CGFloat, width: CGFloat) {
        let headWidth = max(width * 3.2, 9)
        let base = CGPoint(x: tip.x - cos(angle) * length, y: tip.y - sin(angle) * length)
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: CGPoint(
            x: base.x + cos(angle + .pi / 2) * headWidth,
            y: base.y + sin(angle + .pi / 2) * headWidth
        ))
        head.line(to: CGPoint(
            x: base.x + cos(angle - .pi / 2) * headWidth,
            y: base.y + sin(angle - .pi / 2) * headWidth
        ))
        head.close()
        head.fill()
    }

    private static func drawCounter(at center: CGPoint, number: Int, style: ToolStyle) {
        let radius = Annotation.counterRadius(for: style)
        let circle = NSBezierPath(ovalIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
        style.color.setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        circle.lineWidth = max(1, radius * 0.08)
        circle.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
            .foregroundColor: style.color.readableForeground
        ]
        let label = NSAttributedString(string: "\(number)", attributes: attributes)
        let size = label.size()
        label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    // MARK: - Text

    private static func drawText(_ string: String, at origin: CGPoint, style: ToolStyle) {
        guard !string.isEmpty else { return }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: Annotation.font(for: style),
            .foregroundColor: style.color
        ]

        if style.textBackdrop == .shadow {
            let shadow = NSShadow()
            shadow.shadowColor = style.backdropColor
            shadow.shadowBlurRadius = max(3, style.fontSize * 0.18)
            shadow.shadowOffset = NSSize(width: 0, height: -max(1, style.fontSize * 0.05))
            attributes[.shadow] = shadow
        }

        let attributed = NSAttributedString(string: string, attributes: attributes)
        let size = attributed.size()
        // `origin` is the top-left of the text block, matching where the caret was.
        let textOrigin = CGPoint(x: origin.x, y: origin.y - size.height)

        switch style.textBackdrop {
        case .solid, .translucent:
            let padding = max(4, style.fontSize * 0.2)
            let box = CGRect(origin: textOrigin, size: size).insetBy(dx: -padding, dy: -padding * 0.6)
            let alpha: CGFloat = style.textBackdrop == .solid ? 1 : 0.55
            style.backdropColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: box, xRadius: padding * 0.8, yRadius: padding * 0.8).fill()
        case .none, .shadow:
            break
        }

        attributed.draw(at: textOrigin)
    }

    // MARK: - Freehand smoothing

    /// Builds a rounded path through the sampled points. Raw mouse samples are
    /// coarse enough that a polyline looks visibly faceted; joining midpoints with
    /// quadratic curves removes that without the overshoot of a spline fit.
    static func smoothPath(through points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }

        guard points.count > 2 else {
            path.move(to: first)
            path.line(to: points.last ?? first)
            return path
        }

        path.move(to: first)
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.curve(to: midpoint, controlPoint1: current, controlPoint2: current)
        }
        path.line(to: points[points.count - 1])
        return path
    }
}
