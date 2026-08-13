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

/// Geometry rules shared by the opened-image editor. The extra canvas reserve
/// gives crop handles room to grow the output and leaves a comfortable blank
/// strip at the edge of the viewport for the floating controls.
enum OpenedImageEditorGeometry {
    static let canvasInset: CGFloat = 400
    static let edgeReserve: CGFloat = 360

    static func initialImageOrigin(imageSize: CGSize, viewport: CGRect) -> CGPoint {
        let x: CGFloat
        if imageSize.width <= viewport.width {
            x = viewport.midX - imageSize.width / 2
        } else {
            x = viewport.minX + edgeReserve
        }

        let y: CGFloat
        if imageSize.height <= viewport.height {
            y = viewport.midY - imageSize.height / 2
        } else {
            y = viewport.minY + edgeReserve
        }
        return CGPoint(x: x, y: y)
    }

    /// Keeps at least `edgeReserve` points of the image visible at each side
    /// when the image is larger than the viewport. Smaller images stay centred.
    static func constrainedImageOrigin(
        proposed: CGPoint,
        imageSize: CGSize,
        viewport: CGRect
    ) -> CGPoint {
        let x: CGFloat
        if imageSize.width <= viewport.width {
            x = viewport.midX - imageSize.width / 2
        } else {
            x = min(
                viewport.maxX - edgeReserve,
                max(viewport.minX + edgeReserve - imageSize.width, proposed.x)
            )
        }

        let y: CGFloat
        if imageSize.height <= viewport.height {
            y = viewport.midY - imageSize.height / 2
        } else {
            y = min(
                viewport.maxY - edgeReserve,
                max(viewport.minY + edgeReserve - imageSize.height, proposed.y)
            )
        }
        return CGPoint(x: x, y: y)
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
