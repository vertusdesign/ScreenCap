import AppKit
import Carbon.HIToolbox

/// The drawing tools available once an area has been selected.
enum ToolKind: String, CaseIterable, Codable {
    case move
    case pen
    case marker
    case line
    case arrow
    case rectangle
    case ellipse
    case obfuscate
    case counter
    case text
    case eraser

    var titleKey: String { "tool.\(rawValue)" }
    var title: String { L10n.t(titleKey) }

    var symbolName: String {
        switch self {
        case .move: return "arrow.up.left.and.arrow.down.right"
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .obfuscate: return "square.grid.3x3.fill"
        case .counter: return "1.circle"
        case .text: return "textformat"
        case .eraser: return "eraser"
        }
    }

    /// Icon shown while ⌃ is held, so the alternate behaviour is visible before
    /// the user commits to a drag.
    func symbolName(alternate: Bool, obfuscationStyle: ObfuscationStyle = .pixelate) -> String {
        guard alternate else {
            if self == .obfuscate { return obfuscationStyle.symbolName }
            return symbolName
        }
        switch self {
        case .rectangle: return "rectangle.fill"
        case .ellipse: return "oval.fill"
        case .obfuscate: return obfuscationStyle.alternate.symbolName
        default: return symbolName
        }
    }

    /// Whether ⌃ changes what this tool draws.
    var hasAlternate: Bool {
        self == .rectangle || self == .ellipse || self == .obfuscate
    }

    /// Single-key shortcut shown in the tool's tooltip.
    var shortcutKey: String {
        switch self {
        case .move: return "V"
        case .pen: return "P"
        case .marker: return "H"
        case .line: return "L"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "O"
        case .obfuscate: return "B"
        case .counter: return "N"
        case .text: return "T"
        case .eraser: return "E"
        }
    }

    /// Physical key position for the shortcut.
    ///
    /// Matching on the key code rather than the typed character is what makes the
    /// shortcuts work on a Cyrillic (or any non-Latin) layout, where the "A" key
    /// reports "ф".
    var shortcutKeyCode: UInt16 {
        switch self {
        case .move: return UInt16(kVK_ANSI_V)
        case .pen: return UInt16(kVK_ANSI_P)
        case .marker: return UInt16(kVK_ANSI_H)
        case .line: return UInt16(kVK_ANSI_L)
        case .arrow: return UInt16(kVK_ANSI_A)
        case .rectangle: return UInt16(kVK_ANSI_R)
        case .ellipse: return UInt16(kVK_ANSI_O)
        case .obfuscate: return UInt16(kVK_ANSI_B)
        case .counter: return UInt16(kVK_ANSI_N)
        case .text: return UInt16(kVK_ANSI_T)
        case .eraser: return UInt16(kVK_ANSI_E)
        }
    }

    /// Tools whose drag is a rubber-band rectangle, and so honour ⇧ (square) and
    /// ⌥ (draw from centre).
    var isRubberBand: Bool {
        self == .rectangle || self == .ellipse || self == .obfuscate
    }

    var supportsLineWidth: Bool {
        switch self {
        case .pen, .marker, .line, .arrow, .rectangle, .ellipse, .counter: return true
        default: return false
        }
    }
}

// MARK: - Obfuscation

enum ObfuscationStyle: String, CaseIterable, Codable {
    case pixelate
    case blur

    var title: String { L10n.t("obfuscation.style.\(rawValue)") }

    var symbolName: String {
        switch self {
        case .pixelate: return "square.grid.3x3.fill"
        case .blur: return "drop.fill"
        }
    }

    var alternate: ObfuscationStyle {
        self == .pixelate ? .blur : .pixelate
    }
}

enum ObfuscationShape: String, CaseIterable, Codable {
    case rectangle
    case ellipse
    case brush

    var title: String { L10n.t("obfuscation.shape.\(rawValue)") }

    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .brush: return "paintbrush.pointed"
        }
    }
}

struct ObfuscationSettings: Equatable {
    var style: ObfuscationStyle
    var shape: ObfuscationShape
    /// Brush diameter in points, used when `shape == .brush`.
    var brushSize: CGFloat
    /// Mosaic block edge, or Gaussian sigma, in points.
    var intensity: CGFloat

    static let intensityRange: ClosedRange<CGFloat> = 3...30
    static let brushRange: ClosedRange<CGFloat> = 10...120
}

// MARK: - Text

/// What sits behind text so it stays readable over a busy screenshot.
enum TextBackdrop: String, CaseIterable, Codable {
    case none
    case solid
    case translucent
    case shadow

    var title: String { L10n.t("text.backdrop.\(rawValue)") }

    var symbolName: String {
        switch self {
        case .none: return "textformat"
        case .solid: return "textformat.size.larger"
        case .translucent: return "square.on.square.intersection.dashed"
        case .shadow: return "shadow"
        }
    }

    /// Whether the backdrop has a colour the user can choose.
    var usesBackdropColor: Bool { self != .none }
}

// MARK: - Style

/// Stroke, fill and text parameters shared by every annotation.
struct ToolStyle: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    /// Filled rather than outlined. Driven by ⌃ at draw time, not by a setting.
    var filled: Bool
    var fontSize: CGFloat
    var textBackdrop: TextBackdrop
    var backdropColor: NSColor
    var obfuscation: ObfuscationSettings
    var eraserRadius: CGFloat

    static func current() -> ToolStyle {
        let settings = Settings.shared
        return ToolStyle(
            color: settings.toolColor,
            lineWidth: settings.strokeWidth,
            filled: false,
            fontSize: settings.fontSize,
            textBackdrop: settings.textBackdrop,
            backdropColor: settings.textBackdropColor,
            obfuscation: settings.obfuscation,
            eraserRadius: settings.eraserRadius
        )
    }
}

// MARK: - Shapes

/// Geometry of a single annotation. Coordinates are in the overlay's Cocoa point
/// space (origin at the bottom-left of the display the capture happened on).
enum AnnotationShape {
    case pen(points: [CGPoint])
    case marker(points: [CGPoint])
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
    case obfuscateRect(CGRect)
    case obfuscateEllipse(CGRect)
    case obfuscateBrush(points: [CGPoint])
    case counter(center: CGPoint, number: Int)
    case text(origin: CGPoint, string: String)
    /// A stroke that rubs out whatever was drawn before it.
    case erase(points: [CGPoint], width: CGFloat)
}

struct Annotation: Identifiable {
    let id = UUID()
    var shape: AnnotationShape
    var style: ToolStyle

    var isObfuscation: Bool {
        switch shape {
        case .obfuscateRect, .obfuscateEllipse, .obfuscateBrush: return true
        default: return false
        }
    }

    var isErase: Bool {
        if case .erase = shape { return true }
        return false
    }

    /// Bounding box including stroke width.
    var boundingBox: CGRect {
        let padding = max(style.lineWidth * 2, 24)
        return rawBounds.insetBy(dx: -padding, dy: -padding)
    }

    private var rawBounds: CGRect {
        switch shape {
        case .pen(let points), .marker(let points):
            return Self.box(of: points)
        case .obfuscateBrush(let points):
            return Self.box(of: points).insetBy(dx: -style.obfuscation.brushSize, dy: -style.obfuscation.brushSize)
        case .erase(let points, let width):
            return Self.box(of: points).insetBy(dx: -width, dy: -width)
        case .line(let a, let b), .arrow(let a, let b):
            return CGRect(corner: a, corner: b)
        case .rectangle(let rect), .ellipse(let rect),
             .obfuscateRect(let rect), .obfuscateEllipse(let rect):
            return rect
        case .counter(let center, _):
            let radius = Self.counterRadius(for: style)
            return CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
        case .text(let origin, let string):
            let size = Self.textSize(string, style: style)
            return CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height)
        }
    }

    static func counterRadius(for style: ToolStyle) -> CGFloat {
        max(12, style.lineWidth * 4)
    }

    static func font(for style: ToolStyle) -> NSFont {
        NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
    }

    static func textSize(_ string: String, style: ToolStyle) -> CGSize {
        let attributed = NSAttributedString(
            string: string.isEmpty ? " " : string,
            attributes: [.font: font(for: style)]
        )
        return attributed.size()
    }

    // MARK: - Geometry helpers

    private static func box(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
