import AppKit

/// How a capture session starts.
enum CaptureMode {
    /// Free-hand area selection.
    case area
    /// Highlight and click a window.
    case window
    /// Open with a ready-made selection (repeat-last-area, full screen).
    case preselected(globalRect: CGRect)
}

/// What to do with the finished capture.
enum OutputAction {
    case copy
    case save
    case saveAs
    case print
}

/// The rendered result of a capture session.
struct CapturedImage {
    let cgImage: CGImage
    /// Logical size in points; `cgImage` may be 2× that on a Retina display.
    let pointSize: CGSize

    var nsImage: NSImage {
        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(representation)
        return image
    }
}

/// Which resize grip of the selection is being dragged.
enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func position(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            return modernFrameResizeCursor
        }

        switch self {
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return .resizeLeftRight
        }
    }

    @available(macOS 15.0, *)
    private var modernFrameResizeCursor: NSCursor {
        switch self {
        case .top: return NSCursor.__frameResize(from: .top, in: .all)
        case .topLeft: return NSCursor.__frameResize(from: .topLeft, in: .all)
        case .left: return NSCursor.__frameResize(from: .left, in: .all)
        case .bottomLeft: return NSCursor.__frameResize(from: .bottomLeft, in: .all)
        case .bottom: return NSCursor.__frameResize(from: .bottom, in: .all)
        case .bottomRight: return NSCursor.__frameResize(from: .bottomRight, in: .all)
        case .right: return NSCursor.__frameResize(from: .right, in: .all)
        case .topRight: return NSCursor.__frameResize(from: .topRight, in: .all)
        }
    }

    /// Applies a drag delta to `rect`, keeping the opposite edge pinned.
    func resize(_ rect: CGRect, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch self {
        case .topLeft: minX = point.x; maxY = point.y
        case .top: maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .right: maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom: minY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .left: minX = point.x
        }
        return CGRect(
            x: min(minX, maxX), y: min(minY, maxY),
            width: abs(maxX - minX), height: abs(maxY - minY)
        )
    }
}
