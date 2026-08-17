import AppKit

/// Brief, non-blocking confirmations — "Скопировано", "Сохранено в …".
///
/// A menu-bar app has nowhere else to say that something worked, and silently
/// closing the overlay leaves the user guessing.
@MainActor
enum Feedback {
    private static var hud: NSWindow?
    private static var dismissTimer: Timer?

    static func flash(message: String, subtitle: String? = nil) {
        DispatchQueue.main.async { present(message: message, subtitle: subtitle) }
    }

    static func shutter() {
        guard Settings.shared.playShutterSound else { return }
        shutterSound?.play()
    }

    /// The system camera-shutter sound lives outside `NSSound(named:)`'s search
    /// path, so it has to be loaded by path; `Tink` is the fallback if Apple ever
    /// moves it.
    private static let shutterSound: NSSound? = {
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) { return sound }
        }
        return NSSound(named: "Tink")
    }()

    private static func present(message: String, subtitle: String?) {
        dismissTimer?.invalidate()
        hud?.orderOut(nil)

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.appearance = NSAppearance(named: .darkAqua)
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.maskImage = NSImage.roundedMask(radius: 12)

        let title = NSTextField(labelWithString: message)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .white
        title.alignment = .center

        let stack = NSStackView(views: [title])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let subtitle {
            let detail = NSTextField(labelWithString: subtitle)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = NSColor.white.withAlphaComponent(0.7)
            detail.alignment = .center
            detail.lineBreakMode = .byTruncatingMiddle
            detail.maximumNumberOfLines = 1
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
            stack.addArrangedSubview(detail)
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let size = stack.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 96,
            width: size.width,
            height: size.height
        )

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .init(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.contentView = container
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }

        hud = window
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { _ in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
                if hud === window { hud = nil }
            })
        }
    }
}
