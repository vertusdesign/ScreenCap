import AppKit

/// Borderless, full-display window that hosts the frozen screenshot and the
/// selection UI. Sits above everything, including other apps' full-screen spaces.
final class OverlayWindow: NSWindow {
    init(screenFrame: CGRect, transparentBackground: Bool = false) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = !transparentBackground
        backgroundColor = transparentBackground
            ? NSColor.black.withAlphaComponent(0.58)
            : .black
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        // Without this, the first window shown right after `NSApp.activate`
        // wakes an accessory (no-Dock-icon) app from the background gets a
        // brief system zoom-in transition — visible as the whole capture
        // surface "popping" into place instead of appearing instantly.
        animationBehavior = .none
        setFrame(screenFrame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
