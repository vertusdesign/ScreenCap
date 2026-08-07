import AppKit

/// Conversions between Core Graphics' global space (origin at the top-left of the
/// primary display, y growing downwards) and Cocoa's (origin at the bottom-left,
/// y growing upwards). ScreenCaptureKit reports frames in the former; every window
/// and view in this app lives in the latter.
enum Geometry {
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cocoaRect(fromCG rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func cgRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Snaps a rect to whole pixels on a display of the given backing scale, so a
    /// selection never lands on a half-pixel and produces a blurred edge.
    static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect.integral }
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension CGRect {
    /// A rect spanning two arbitrary corner points.
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Clamps the receiver so it stays fully inside `bounds`, shrinking if needed.
    func clamped(to bounds: CGRect) -> CGRect {
        intersection(bounds)
    }

    /// Moves the receiver so it stays inside `bounds` without changing its size.
    func nudgedInside(_ bounds: CGRect) -> CGRect {
        var result = self
        if result.maxX > bounds.maxX { result.origin.x = bounds.maxX - result.width }
        if result.maxY > bounds.maxY { result.origin.y = bounds.maxY - result.height }
        if result.minX < bounds.minX { result.origin.x = bounds.minX }
        if result.minY < bounds.minY { result.origin.y = bounds.minY }
        return result
    }
}

extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
