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

    /// Icon reflecting the CURRENT persisted choice for tools that have one
    /// (shape fill, arrow heads, redaction style), with `alternate` showing what
    /// ⌃ would switch it to instead — so holding ⌃ always previews a swap away
    /// from whatever is already selected, not a hard-coded "filled" or
    /// "pixelate" regardless of the popover's own setting.
    func symbolName(alternate: Bool, style: ToolStyle) -> String {
        switch self {
        case .obfuscate:
            let effective = alternate ? style.obfuscation.style.alternate : style.obfuscation.style
            return effective.symbolName
        case .rectangle:
            let filled = alternate ? !style.filled : style.filled
            return filled ? "rectangle.fill" : "rectangle"
        case .ellipse:
            let filled = alternate ? !style.filled : style.filled
            return filled ? "oval.fill" : "oval"
        case .arrow:
            let double = alternate ? !style.arrowDoubleHeaded : style.arrowDoubleHeaded
            return double ? "arrow.left.and.right" : "arrow.up.right"
        default:
            return symbolName
        }
    }

    /// Whether ⌃ changes what this tool draws.
    var hasAlternate: Bool {
        self == .rectangle || self == .ellipse || self == .obfuscate || self == .arrow
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

/// Shared by redaction and the eraser: both act on a rectangle, an ellipse, or a
/// free brush stroke, and both default to the brush — declared first so it also
/// leads every segmented-control selector built from `allCases`.
enum ObfuscationShape: String, CaseIterable, Codable {
    case brush
    case rectangle
    case ellipse

    var title: String { L10n.t("obfuscation.shape.\(rawValue)") }

    var symbolName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .brush: return "paintbrush.pointed"
        }
    }
}

/// How the Eraser tool acts on a click. Pixel erasing keeps the existing
/// brush/rectangle/ellipse behaviour; object deletion removes one complete
/// annotation instead of punching a hole in the rendered layer.
enum EraserMode: String, CaseIterable, Codable {
    case pixels
    case objects

    var title: String { L10n.t("style.eraserMode.\(rawValue)") }

    var symbolName: String {
        switch self {
        case .pixels: return "eraser"
        case .objects: return "trash"
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
        case .none: return "textformat.size.larger"
        case .solid: return "a.square.fill"
        case .translucent: return "square.on.square.intersection.dashed"
        case .shadow: return "shadow"
        }
    }

    /// Whether the backdrop has a color the user can choose.
    var usesBackdropColor: Bool { self != .none }
}

// MARK: - Style

/// Stroke, fill and text parameters shared by every annotation.
struct ToolStyle: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    /// Persisted default for rectangle/ellipse: filled vs outlined. ⌃ toggles
    /// this temporarily for the shape being drawn, same as `obfuscation.style`.
    var filled: Bool
    /// Persisted default for the arrow: one head vs two. ⌃ toggles it too.
    var arrowDoubleHeaded: Bool
    var fontSize: CGFloat
    var textBackdrop: TextBackdrop
    var backdropColor: NSColor
    var obfuscation: ObfuscationSettings
    var eraserRadius: CGFloat
    var eraserShape: ObfuscationShape
    var eraserMode: EraserMode
    /// Size of the numbered circle, kept separate from drawing stroke width.
    var counterSize: CGFloat
    /// Stroke width of the arrow attached to a numbered circle.
    var counterArrowWidth: CGFloat

    static func current() -> ToolStyle {
        let settings = Settings.shared
        return ToolStyle(
            color: settings.toolColor,
            lineWidth: settings.strokeWidth,
            filled: settings.shapeFilled,
            arrowDoubleHeaded: settings.arrowDoubleHeaded,
            fontSize: settings.fontSize,
            textBackdrop: settings.textBackdrop,
            backdropColor: settings.textBackdropColor,
            obfuscation: settings.obfuscation,
            eraserRadius: settings.eraserRadius,
            eraserShape: settings.eraserShape,
            eraserMode: settings.eraserMode,
            counterSize: settings.counterSize,
            counterArrowWidth: settings.counterArrowWidth
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
    case arrow(from: CGPoint, to: CGPoint, doubleHeaded: Bool)
    case rectangle(CGRect)
    case ellipse(CGRect)
    case obfuscateRect(CGRect)
    case obfuscateEllipse(CGRect)
    case obfuscateBrush(points: [CGPoint])
    /// A numbered circle, optionally followed by an arrow drawn from its centre.
    case counter(center: CGPoint, number: Int, arrowTo: CGPoint?)
    case text(origin: CGPoint, string: String)
    /// A stroke that rubs out whatever was drawn before it.
    case erase(points: [CGPoint], width: CGFloat)
    case eraseRect(CGRect)
    case eraseEllipse(CGRect)
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
        switch shape {
        case .erase, .eraseRect, .eraseEllipse: return true
        default: return false
        }
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
        case .line(let a, let b), .arrow(let a, let b, _):
            return CGRect(corner: a, corner: b)
        case .rectangle(let rect), .ellipse(let rect),
             .obfuscateRect(let rect), .obfuscateEllipse(let rect),
             .eraseRect(let rect), .eraseEllipse(let rect):
            return rect
        case .counter(let center, _, let arrowTo):
            let radius = Self.counterRadius(for: style)
            var bounds = CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )
            if let arrowTo {
                bounds = bounds.union(
                    CGRect(corner: center, corner: arrowTo)
                        .insetBy(dx: -style.counterArrowWidth * 2, dy: -style.counterArrowWidth * 2)
                )
            }
            return bounds
        case .text(let origin, let string):
            let size = Self.textSize(string, style: style)
            return CGRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height)
        }
    }

    static func counterRadius(for style: ToolStyle) -> CGFloat {
        max(12, style.counterSize * 4)
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
