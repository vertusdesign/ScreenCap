import AppKit

/// A custom floating tooltip.
///
/// AppKit's native `NSView.toolTip` renders in a system tooltip window at
/// roughly `.popUpMenu` level, which sits well below the overlay's
/// `CGShieldingWindowLevel()`. Over the overlay that native tooltip is drawn,
/// it is just never visible — it is permanently hidden behind the capture
/// surface. This reimplements the same idea as a tiny borderless window one
/// level above the overlay, driven manually from hover events.
@MainActor
final class TooltipWindow: NSWindow {
    static let shared = TooltipWindow()

    private let label: NSTextField = {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = .white
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        container.layer?.cornerRadius = 6
        container.layer?.cornerCurve = .continuous
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        contentView = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    /// `sourceScreenRect` is the hovered control's frame in screen coordinates.
    /// The tooltip appears just below it, flipping above when that would run
    /// off the bottom of the screen, and clamped horizontally to stay on it.
    func show(text: String, near sourceScreenRect: CGRect) {
        guard !text.isEmpty else { return }
        label.stringValue = text
        label.preferredMaxLayoutWidth = 260
        let fitting = label.fittingSize
        let width = min(fitting.width, 260) + 16
        let height = fitting.height + 10

        let screen = NSScreen.screens.first { $0.frame.contains(sourceScreenRect.origin) } ?? NSScreen.main
        var origin = CGPoint(x: sourceScreenRect.minX, y: sourceScreenRect.minY - height - 6)
        if let screen {
            if origin.y < screen.frame.minY {
                origin.y = sourceScreenRect.maxY + 6
            }
            origin.x = min(max(origin.x, screen.frame.minX + 4), screen.frame.maxX - width - 4)
        }

        setFrame(CGRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        orderFront(nil)
    }

    func hide() {
        orderOut(nil)
    }
}

/// Schedules and cancels a `TooltipWindow` presentation for one hover-tracked
/// view, so `OverlayButton`/`ColorSwatchButton` don't each reimplement the
/// same delay-then-show/hide bookkeeping.
@MainActor
final class HoverTooltip {
    private weak var view: NSView?
    private var text: String?
    private var pendingShow: Task<Void, Never>?

    init(for view: NSView) { self.view = view }

    func setText(_ text: String?) { self.text = text }

    func scheduleShow() {
        cancelPending()
        guard let text, !text.isEmpty else { return }
        pendingShow = Task { @MainActor [weak self] in
            // Keep the custom overlay tooltip responsive while retaining a
            // short debounce so moving across adjacent controls does not
            // flash a tooltip for every pixel.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.present()
        }
    }

    func hide() {
        cancelPending()
        TooltipWindow.shared.hide()
    }

    private func cancelPending() {
        pendingShow?.cancel()
        pendingShow = nil
    }

    private func present() {
        guard let view, let window = view.window, let text, !text.isEmpty else { return }
        let screenRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        TooltipWindow.shared.show(text: text, near: screenRect)
    }
}
