import AppKit

extension NSWindow {
    /// Centres on the display holding the pointer rather than on `NSScreen.main`.
    ///
    /// For a menu-bar app "main" is whichever display last had key focus, which is
    /// rarely the one the user is looking at when they pick something from the
    /// status menu — the panel then opens on another monitor and reads as broken.
    func centerOnPointerScreen() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main
        else {
            center()
            return
        }
        let visible = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        ))
    }
}
