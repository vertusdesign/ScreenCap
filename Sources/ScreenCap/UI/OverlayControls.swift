import AppKit

enum OverlayStyle {
    static let panelCornerRadius: CGFloat = 10
    // 56x56px / 32x32px / 12px / 8px at the standard @2x backing scale.
    static let buttonSize: CGFloat = 28
    static let iconPointSize: CGFloat = 16
    static let buttonSpacing: CGFloat = 6
    static let panelPadding: CGFloat = 4
    static let accent = NSColor.controlAccentColor
}

/// Fixed square slot used by the two overlay toolbars.
///
/// AppKit controls have symbol-dependent intrinsic sizes. Putting the control
/// in a fixed slot makes the toolbar layout depend only on product geometry,
/// never on whether the symbol happens to be `xmark`, `textformat`, or a larger
/// compound glyph.
final class OverlaySquareSlot: NSView {
    init(control: NSView, size: CGFloat = OverlayStyle.buttonSize) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            control.centerXAnchor.constraint(equalTo: centerXAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

/// A rounded, blurred container used for the tool strip, the action bar and the
/// color popover, so all floating overlay chrome reads as one system.
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
    private let fixedSize: CGFloat
    private lazy var hoverTooltip = HoverTooltip(for: self)

    init(
        symbolName: String,
        tooltip: String,
        shortcut: String? = nil,
        hint: String? = nil,
        size: CGFloat = OverlayStyle.buttonSize,
        accented: Bool = false
    ) {
        self.accented = accented
        self.fixedSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        // The default focus ring AppKit draws on click extends a few points
        // past the button's own bounds — with buttons packed 2pt apart in the
        // tool strip, that ring bled into neighbouring buttons and past the
        // panel's rounded corners, reading as "non-square, overlapping
        // highlights." The custom hover/active fill in `draw(_:)` is the only
        // highlight this control needs.
        focusRingType = .none
        wantsLayer = true
        setTooltip(tooltip, shortcut: shortcut, hint: hint)
        setSymbol(symbolName)
        updateTint()
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
        // NSButton has non-zero alignment-rect insets on some macOS versions.
        // Constraints then describe a 28pt alignment rect while the visible
        // frame becomes larger, and NSStackView can distribute different
        // symbols with subtly different outer heights. Keep the control a
        // fixed square at both the layout and intrinsic-size levels.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedSize, height: fixedSize)
    }

    /// "Rectangle  R" on the first line, an optional modifier hint on the second.
    func setTooltip(_ title: String, shortcut: String?, hint: String? = nil) {
        var text = title
        if let shortcut, !shortcut.isEmpty { text += "  ·  \(shortcut)" }
        if let hint, !hint.isEmpty { text += "\n\(hint)" }
        toolTip = text
        hoverTooltip.setText(text)
    }

    func setSymbol(_ symbolName: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: OverlayStyle.iconPointSize, weight: .medium)
        // Symbol availability shifts between macOS releases; an empty button is a
        // worse failure than a generic glyph.
        // A capture session can show its overlay on a 1x external display right
        // after the SAME symbol was rasterised for the 2x built-in one earlier in
        // the app's lifetime. NSImage's default caching can reuse that bitmap
        // instead of re-rendering at the new scale, which is what reads as
        // "crisp on Retina, blurry on the external monitor" — `.freshSystemSymbol`
        // forces a fresh render from the vector source for every draw, at
        // whatever scale that draw actually happens at.
        let symbol = NSImage.freshSystemSymbol(symbolName, accessibilityDescription: toolTip)
            ?? NSImage.freshSystemSymbol("questionmark", accessibilityDescription: toolTip)
        let resolved = symbol?.withSymbolConfiguration(configuration)
        // `withSymbolConfiguration` returns a new wrapper image, which does not
        // necessarily inherit the base image's cache mode — set it again on the
        // actual object that ends up assigned to `image`.
        resolved?.cacheMode = .never
        image = resolved
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hoverTooltip.scheduleShow()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverTooltip.hide()
    }

    override func mouseDown(with event: NSEvent) {
        hoverTooltip.hide()
        super.mouseDown(with: event)
    }

    // Each capture session creates a fresh OverlayWindow per display, so a
    // layer's contentsScale is normally right from the start — this only
    // matters for the rare case of a window actually migrating to a
    // different-scale screen while live, and costs nothing to keep correct.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { layer?.contentsScale = scale }
        needsDisplay = true
    }

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
            // The button's whole 28pt frame is the 56px @2x highlight. An inset
            // here makes the visible hover/active state smaller than the button.
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Button that shows the current color as a filled swatch.
final class ColorSwatchButton: NSButton {
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var trackingAreaRef: NSTrackingArea?
    private let fixedSize: CGFloat
    private lazy var hoverTooltip = HoverTooltip(for: self)

    override var toolTip: String? {
        didSet { hoverTooltip.setText(toolTip) }
    }

    init(size: CGFloat = OverlayStyle.buttonSize) {
        fixedSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedSize, height: fixedSize)
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hoverTooltip.scheduleShow()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverTooltip.hide()
    }

    override func mouseDown(with event: NSEvent) {
        hoverTooltip.hide()
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let inset = bounds.insetBy(dx: 6, dy: 6)
        color.setFill()
        NSBezierPath(ovalIn: inset).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: inset)
        ring.lineWidth = 1.5
        ring.stroke()
    }
}

/// `NSSegmentedControl` with a custom per-segment tooltip, since its native
/// `setToolTip(_:forSegment:)` has the same problem as a plain button's
/// `toolTip` — see `HoverTooltip` — and one control here has several segments
/// worth naming individually.
final class TooltipSegmentedControl: NSSegmentedControl {
    private var segmentTooltips: [String] = []
    private var hoveredSegment: Int?
    private var trackingAreaRef: NSTrackingArea?
    private lazy var hoverTooltip = HoverTooltip(for: self)

    func setSegmentTooltips(_ tooltips: [String]) {
        segmentTooltips = tooltips
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSegment = nil
        hoverTooltip.hide()
    }

    override func mouseDown(with event: NSEvent) {
        hoverTooltip.hide()
        super.mouseDown(with: event)
    }

    private func updateHover(at point: CGPoint) {
        var x: CGFloat = 0
        for index in 0..<segmentCount {
            let segmentWidth = width(forSegment: index)
            let segmentRect = CGRect(x: x, y: 0, width: segmentWidth, height: bounds.height)
            if segmentRect.contains(point) {
                if hoveredSegment != index {
                    hoveredSegment = index
                    hoverTooltip.setText(index < segmentTooltips.count ? segmentTooltips[index] : nil)
                    hoverTooltip.scheduleShow()
                }
                return
            }
            x += segmentWidth
        }
        hoveredSegment = nil
        hoverTooltip.hide()
    }
}

extension NSImage {
    /// A system symbol that always re-renders from its vector source instead of
    /// reusing a bitmap cached at a different screen's scale. See
    /// `OverlayButton.setSymbol` for why that caching is otherwise a problem.
    static func freshSystemSymbol(_ name: String, accessibilityDescription: String?) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        image?.cacheMode = .never
        return image
    }

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
