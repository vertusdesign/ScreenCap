import AppKit

enum OverlayStyle {
    static let panelCornerRadius: CGFloat = 10
    static let buttonSize: CGFloat = 30
    static let buttonSpacing: CGFloat = 2
    static let panelPadding: CGFloat = 4
    static let accent = NSColor.controlAccentColor
}

/// A rounded, blurred container used for the tool strip, the action bar and the
/// colour popover, so all floating overlay chrome reads as one system.
class OverlayPanel: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        // Pinned to dark regardless of the system theme: the panel floats over an
        // arbitrary screenshot, and a light HUD over a light screenshot disappears.
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = OverlayStyle.panelCornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.masksToBounds = true
        maskImage = NSImage.roundedMask(radius: OverlayStyle.panelCornerRadius)
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            return shadow
        }()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The panel swallows clicks so a press on a button never falls through and
    /// starts a new selection underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit ?? (bounds.contains(convert(point, from: superview)) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) { /* swallow */ }
}

/// Square icon button used throughout the overlay chrome.
final class OverlayButton: NSButton {
    var isActive = false {
        didSet { if isActive != oldValue { needsDisplay = true; updateTint() } }
    }

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var trackingAreaRef: NSTrackingArea?
    private let accented: Bool

    init(
        symbolName: String,
        tooltip: String,
        shortcut: String? = nil,
        hint: String? = nil,
        size: CGFloat = OverlayStyle.buttonSize,
        accented: Bool = false
    ) {
        self.accented = accented
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        wantsLayer = true
        setTooltip(tooltip, shortcut: shortcut, hint: hint)
        setSymbol(symbolName)
        updateTint()
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// "Rectangle  R" on the first line, an optional modifier hint on the second.
    func setTooltip(_ title: String, shortcut: String?, hint: String? = nil) {
        var text = title
        if let shortcut, !shortcut.isEmpty { text += "  ·  \(shortcut)" }
        if let hint, !hint.isEmpty { text += "\n\(hint)" }
        toolTip = text
    }

    func setSymbol(_ symbolName: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        // Symbol availability shifts between macOS releases; an empty button is a
        // worse failure than a generic glyph.
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: toolTip)
        image = symbol?.withSymbolConfiguration(configuration)
    }

    private func updateTint() {
        contentTintColor = isActive || accented ? .white : NSColor.white.withAlphaComponent(0.82)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor?
        if accented {
            background = isHovered
                ? (OverlayStyle.accent.blended(withFraction: 0.18, of: .white) ?? OverlayStyle.accent)
                : OverlayStyle.accent
        } else if isActive {
            background = OverlayStyle.accent
        } else if isHovered {
            background = NSColor.white.withAlphaComponent(0.16)
        } else {
            background = nil
        }

        if let background {
            background.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Button that shows the current colour as a filled swatch.
final class ColorSwatchButton: NSButton {
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    init(size: CGFloat = OverlayStyle.buttonSize) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        wantsLayer = true
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 6, dy: 6)
        color.setFill()
        NSBezierPath(ovalIn: inset).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: inset)
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

extension NSImage {
    /// Mask image that gives an `NSVisualEffectView` rounded corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension NSView {
    /// Thin divider used between groups of buttons.
    static func overlaySeparator(vertical: Bool) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        if vertical {
            view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        return view
    }
}
