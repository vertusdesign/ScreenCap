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

/// Converts raw scrolling deltas into content movement while respecting the
/// user's macOS "Natural scrolling" preference. AppKit's raw event deltas are
/// not consistent with the direction users expect from a content surface when
/// natural scrolling is disabled, so the preference has to be applied by the
/// custom canvas itself.
enum SystemScrollDirection {
    private static let preferenceKey = "com.apple.swipescrolldirection"

    static var usesNaturalScrolling: Bool {
        let globalDomain = UserDefaults.standard.persistentDomain(
            forName: UserDefaults.globalDomain
        )
        // The preference is normally present as an NSNumber-backed Bool. If a
        // system has never written it, macOS's default is Natural scrolling.
        return (globalDomain?[preferenceKey] as? Bool) ?? true
    }

    static func contentDelta(_ delta: CGSize, naturalScrolling: Bool) -> CGSize {
        naturalScrolling
            ? delta
            : CGSize(width: -delta.width, height: -delta.height)
    }

    static func contentDelta(_ delta: CGSize) -> CGSize {
        contentDelta(delta, naturalScrolling: usesNaturalScrolling)
    }
}

/// Geometry rules shared by the opened-image editor. The extra canvas reserve
/// gives crop handles room to grow the output and leaves a comfortable blank
/// strip at the edge of the viewport for the floating controls.
enum OpenedImageEditorGeometry {
    static let canvasInset: CGFloat = 400
    static let edgeReserve: CGFloat = 360

    /// Returns the parts of `selection` that lie outside the original image.
    /// Those are the only pixels that should receive the current canvas-fill
    /// colour when an opened image is cropped outward. The editor background
    /// itself remains transparent so the overlay window can provide its usual
    /// semi-transparent dimming.
    static func canvasExtensionRects(selection: CGRect, imageRect: CGRect) -> [CGRect] {
        guard !selection.isNull, selection.width > 0, selection.height > 0 else {
            return []
        }

        let overlap = selection.intersection(imageRect)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else {
            return [selection]
        }

        let candidates = [
            CGRect(
                x: selection.minX,
                y: overlap.maxY,
                width: selection.width,
                height: selection.maxY - overlap.maxY
            ),
            CGRect(
                x: selection.minX,
                y: selection.minY,
                width: selection.width,
                height: overlap.minY - selection.minY
            ),
            CGRect(
                x: selection.minX,
                y: overlap.minY,
                width: overlap.minX - selection.minX,
                height: overlap.height
            ),
            CGRect(
                x: overlap.maxX,
                y: overlap.minY,
                width: selection.maxX - overlap.maxX,
                height: overlap.height
            )
        ]
        return candidates.filter { $0.width > 0 && $0.height > 0 }
    }

    static func initialImageOrigin(imageSize: CGSize, viewport: CGRect) -> CGPoint {
        // Start every opened image at its visual centre. For an image larger
        // than the display this shows its centre and leaves equal content on
        // either side; the edge reserve is a panning limit, not an initial
        // alignment rule.
        CGPoint(
            x: viewport.midX - imageSize.width / 2,
            y: viewport.midY - imageSize.height / 2
        )
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

    /// Applies the edge-margin rule to an editable canvas whose local origin
    /// may extend beyond the source image. The returned point is still the
    /// position of the source image, so callers do not need to change their
    /// existing image-local coordinate system.
    static func constrainedCanvasImageOrigin(
        proposedImageOrigin: CGPoint,
        canvasRect: CGRect,
        viewport: CGRect
    ) -> CGPoint {
        let proposedCanvasOrigin = CGPoint(
            x: proposedImageOrigin.x + canvasRect.minX,
            y: proposedImageOrigin.y + canvasRect.minY
        )
        let constrainedCanvasOrigin = constrainedImageOrigin(
            proposed: proposedCanvasOrigin,
            imageSize: canvasRect.size,
            viewport: viewport
        )
        return CGPoint(
            x: constrainedCanvasOrigin.x - canvasRect.minX,
            y: constrainedCanvasOrigin.y - canvasRect.minY
        )
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
