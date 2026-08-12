import AppKit

/// Owns one overlay window per display for the duration of a capture session.
final class OverlayController: NSObject, SelectionOverlayViewDelegate {

    var onFinish: ((CapturedImage, OutputAction, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var windows: [OverlayWindow] = []
    private var views: [SelectionOverlayView] = []
    private struct SessionHistoryState {
        var views: [SelectionOverlayState]
    }
    private var undoStack: [SessionHistoryState] = []
    private var redoStack: [SessionHistoryState] = []
    private var isDismissing = false

    // MARK: - Presentation

    func present(snapshots: [DisplaySnapshot], mode: CaptureMode, windowTargets: [WindowTarget]) {
        undoStack.removeAll()
        redoStack.removeAll()
        isDismissing = false
        for snapshot in snapshots {
            let isOpenedImage: Bool
            if case .openedImage = mode {
                isOpenedImage = true
            } else {
                isOpenedImage = false
            }

            let windowFrame = isOpenedImage
                ? snapshot.screen.visibleFrame
                : snapshot.cocoaFrame
            let window = OverlayWindow(
                screenFrame: windowFrame,
                transparentBackground: isOpenedImage
            )
            let view = SelectionOverlayView(
                snapshot: snapshot,
                mode: mode,
                windows: windowTargets
            )
            view.delegate = self
            view.frame = CGRect(
                x: snapshot.cocoaFrame.minX - windowFrame.minX,
                y: snapshot.cocoaFrame.minY - windowFrame.minY,
                width: snapshot.cocoaFrame.width,
                height: snapshot.cocoaFrame.height
            )
            view.autoresizingMask = []
            if isOpenedImage {
                let canvas = OverlayCanvasView(frame: CGRect(origin: .zero, size: windowFrame.size))
                canvas.editorView = view
                canvas.addSubview(view)
                window.contentView = canvas
                view.setChromeBounds(CGRect(
                    x: windowFrame.minX - snapshot.cocoaFrame.minX,
                    y: windowFrame.minY - snapshot.cocoaFrame.minY,
                    width: windowFrame.width,
                    height: windowFrame.height
                ))
            } else {
                window.contentView = view
            }
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
        undoStack.removeAll()
        redoStack.removeAll()
        NSCursor.arrow.set()
    }

    // MARK: - SelectionOverlayViewDelegate

    /// Hands key status to whichever display the pointer is over, so typing and
    /// modifier keys always apply to the overlay being looked at.
    func overlayWantsKeyFocus(_ view: SelectionOverlayView) {
        // Belt and braces alongside each view's own `mouseExited`: whichever
        // display is NOT the one gaining focus is, by definition, no longer
        // under the pointer, so its loupe/hover state is cleared unconditionally
        // rather than trusting tracking-area exit events alone across adjacent
        // shielding-level windows.
        for other in views where other !== view {
            other.clearPointerState()
        }

        guard let window = view.window, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// One selection may exist across the whole session: whichever display just
    /// started a new one wins, and every other display gives up what it had.
    func overlayDidBeginSelection(_ view: SelectionOverlayView) {
        for other in views where other !== view {
            other.discardSelectionForSelectionElsewhere()
        }
    }

    /// Captures every display before one of them changes. The active display is
    /// not special here: a later undo may need to restore a selection on another
    /// monitor, so the complete multi-display state is the atomic history unit.
    func overlayWillChange(_ view: SelectionOverlayView) {
        undoStack.append(SessionHistoryState(views: views.map { $0.sessionState() }))
        redoStack.removeAll()
        if undoStack.count > 64 { undoStack.removeFirst() }
        updateHistoryButtons()
    }

    func overlayDidRequestUndo(_ view: SelectionOverlayView) {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(SessionHistoryState(views: views.map { $0.sessionState() }))
        apply(previous, preferred: view)
    }

    func overlayDidRequestRedo(_ view: SelectionOverlayView) {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(SessionHistoryState(views: views.map { $0.sessionState() }))
        apply(next, preferred: view)
    }

    func overlayHistoryAvailabilityDidChange(_ view: SelectionOverlayView) {
        updateHistoryButtons()
    }

    private func apply(_ state: SessionHistoryState, preferred: SelectionOverlayView) {
        guard state.views.count == views.count else { return }
        for (view, viewState) in zip(views, state.views) {
            view.apply(viewState)
        }

        // After undo/redo the selected display can change. Give it keyboard
        // focus so the restored toolbar and the next shortcut belong to the
        // monitor whose state is now visible.
        let target = views.enumerated().first { index, _ in
            state.views[index].selection != nil
        }?.element ?? preferred
        target.window?.makeKeyAndOrderFront(nil)
        target.window?.makeFirstResponder(target)
        updateHistoryButtons()
    }

    private func updateHistoryButtons() {
        let canUndo = !undoStack.isEmpty
        let canRedo = !redoStack.isEmpty
        for view in views {
            view.setHistoryState(canUndo: canUndo, canRedo: canRedo)
        }
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
