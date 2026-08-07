import AppKit

/// Owns one overlay window per display for the duration of a capture session.
final class OverlayController: NSObject, SelectionOverlayViewDelegate {

    var onFinish: ((CapturedImage, OutputAction, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [OverlayWindow] = []
    private var views: [SelectionOverlayView] = []
    private var isDismissing = false

    // MARK: - Presentation

    func present(snapshots: [DisplaySnapshot], mode: CaptureMode, windowTargets: [WindowTarget]) {
        for snapshot in snapshots {
            let window = OverlayWindow(screenFrame: snapshot.cocoaFrame)
            let view = SelectionOverlayView(
                snapshot: snapshot,
                mode: mode,
                windows: windowTargets
            )
            view.delegate = self
            view.frame = CGRect(origin: .zero, size: snapshot.cocoaFrame.size)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            windows.append(window)
            views.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }

        // Focus the display the pointer is already on, and seed every view with the
        // pointer position so the loupe is correct on the first frame rather than
        // after the first mouse move.
        let pointer = NSEvent.mouseLocation
        let preferred = windows.first { $0.frame.contains(pointer) } ?? windows.first
        preferred?.makeKeyAndOrderFront(nil)

        for (index, view) in views.enumerated() {
            view.syncPointer(globalLocation: pointer)
            view.activate()
            if windows[index] === preferred {
                windows[index].makeFirstResponder(view)
            }
        }
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true

        for window in windows {
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
    }

    // MARK: - SelectionOverlayViewDelegate

    /// Hands key status to whichever display the pointer is over, so typing and
    /// modifier keys always apply to the overlay being looked at.
    func overlayWantsKeyFocus(_ view: SelectionOverlayView) {
        guard let window = view.window, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    func overlayDidRequestCancel(_ view: SelectionOverlayView) {
        onCancel?()
    }

    func overlay(
        _ view: SelectionOverlayView,
        didFinish image: CapturedImage,
        action: OutputAction,
        globalRect: CGRect
    ) {
        onFinish?(image, action, globalRect)
    }
}
