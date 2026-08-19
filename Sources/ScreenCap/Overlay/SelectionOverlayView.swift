import AppKit
import Carbon.HIToolbox
@preconcurrency import VisionKit

@MainActor
protocol SelectionOverlayViewDelegate: AnyObject {
    /// The pointer entered this display — it should take keyboard focus.
    func overlayWantsKeyFocus(_ view: SelectionOverlayView)
    /// This display just started a brand-new selection — every other display's
    /// selection is no longer the only one and must clear itself.
    func overlayDidBeginSelection(_ view: SelectionOverlayView)
    func overlayWillChange(_ view: SelectionOverlayView)
    func overlayDidRequestUndo(_ view: SelectionOverlayView)
    func overlayDidRequestRedo(_ view: SelectionOverlayView)
    func overlayHistoryAvailabilityDidChange(_ view: SelectionOverlayView)
    func overlayDidRequestCancel(_ view: SelectionOverlayView)
    func overlay(
        _ view: SelectionOverlayView,
        didFinish image: CapturedImage,
        action: OutputAction,
        globalRect: CGRect
    )
}

/// State of one display inside a capture session. The controller stores an
/// array of these states, one per overlay window, so history can cross display
/// boundaries without converting the selection into global coordinates.
struct SelectionOverlayState {
    var annotations: [Annotation]
    var selection: CGRect?
    var counterNext: Int
}

/// The whole capture experience for one display: frozen screenshot, dimming,
/// selection, annotation tools and the chrome around them.
///
/// The view's coordinate space is the display in Cocoa points with the origin at
/// its bottom-left corner, which is also the space every annotation is stored in.
@MainActor
final class SelectionOverlayView: NSView, ImageAnalysisOverlayViewDelegate {

    private enum Phase {
        case idle
        case creating(origin: CGPoint)
        case ready
        case moving(grabOffset: CGSize)
        case resizing(handle: SelectionHandle)
        case panning(startImageOrigin: CGPoint, startWindowPoint: CGPoint)
        case drawing(origin: CGPoint)
    }

    // MARK: - Model

    weak var delegate: SelectionOverlayViewDelegate?

    private let snapshot: DisplaySnapshot
    private let obfuscation: ObfuscationSource
    /// The mode requested when the session started. Command switching is
    /// momentary and always derives from this value rather than toggling the
    /// current variant repeatedly.
    private let baseCaptureMode: CaptureMode
    private var mode: CaptureMode
    private var windowTargets: [WindowTarget] = []

    private var phase: Phase = .idle
    private(set) var selection: CGRect?
    private var annotations: [Annotation] = []
    private var draft: Annotation?

    /// One undo step. Resizing or moving the selection is an edit like any other,
    /// so the frame travels through history together with the drawing. The actual
    /// stack lives in `OverlayController`, allowing one step to cover every display.
    private enum HistoryReason {
        case annotation
        case selection
        /// Arrow-key nudges, which coalesce so holding a key is one undo step.
        case nudge
    }

    private var lastHistoryReason: HistoryReason?

    /// Ordinary annotations, flattened into a transparent foreground sheet over
    /// the screenshot. Obfuscations have their own sheet so later passes can sit
    /// above earlier passes while all ordinary annotations remain on top.
    private var annotationLayer: AnnotationLayer?
    private var obfuscationLayer: AnnotationLayer?
    /// Temporary sheets used to preview a rectangular/elliptical erase without
    /// mutating the committed annotation layers until mouse-up.
    private var erasePreviewAnnotationLayer: AnnotationLayer?
    private var erasePreviewObfuscationLayer: AnnotationLayer?
    /// Points of the eraser stroke currently being dragged.
    private var eraseStroke: [CGPoint] = []

    private var tool: ToolKind = .move
    private var style: ToolStyle = .current()
    private var counterNext = 1

    private var cursorPoint: CGPoint = .zero
    /// Whether the pointer is over *this* display. Everything that follows the
    /// pointer — magnifier, eraser ring, window highlight — hides when it is not,
    /// so a two-monitor setup does not show two loupes at once.
    private var pointerInside = false
    private var activeModifiers: NSEvent.ModifierFlags = []
    private var hoveredWindow: WindowTarget?
    private var eyedropperActive = false
    private var eyedropperTarget: StyleColorTarget = .stroke

    // MARK: - Chrome

    private let toolStrip = ToolStrip()
    private let actionBar = ActionBar()
    private let magnifierView = MagnifierOverlayView()
    private var stylePopover: StylePopover?
    private var textEditor: AnnotationTextView?
    private var textEditorOrigin: CGPoint = .zero
    private var textMoveHandle: TextMoveHandle?
    private var textEditorStyle: ToolStyle?
    private var editingTextID: UUID?
    private var textAnalysisOverlay: ImageAnalysisOverlayView?
    private var textAnalysisTask: Task<Void, Never>?
    nonisolated(unsafe) private var textRecognitionKeyMonitor: Any?
    nonisolated(unsafe) private var overlayKeyMonitor: Any?
    /// The opened-image editor has a larger canvas around the image. Keeping
    /// this separate from `bounds` lets its panels live in that surrounding
    /// space while annotations remain image-local.
    private var chromeBounds: CGRect?

    private var trackingAreaRef: NSTrackingArea?
    nonisolated(unsafe) private var textEditorFocusObserver: NSObjectProtocol?
    private let handleRadius: CGFloat = 4.5
    private let handleHitRadius: CGFloat = 9

    private var isOpenedImageMode: Bool {
        if case .openedImage = mode { return true }
        return false
    }

    /// Image-local coordinates remain anchored at (0, 0), even when the view's
    /// bounds includes the surrounding canvas reserve.
    private var imageRect: CGRect {
        CGRect(origin: .zero, size: snapshot.cocoaFrame.size)
    }

    /// The complete content that Move should be able to reveal. An outward
    /// crop immediately becomes part of the scrollable canvas; an inward crop
    /// does not make the source image disappear from it.
    private var openedImageCanvasRect: CGRect {
        guard isOpenedImageMode, let selection else { return imageRect }
        return imageRect.union(selection)
    }

    // MARK: - Init

    init(snapshot: DisplaySnapshot, mode: CaptureMode, windows: [WindowTarget]) {
        self.snapshot = snapshot
        self.baseCaptureMode = mode
        self.mode = mode
        self.obfuscation = ObfuscationSource(
            source: snapshot.image,
            pointSize: snapshot.cocoaFrame.size,
            pixelScale: snapshot.pixelScale
        )
        super.init(frame: CGRect(origin: .zero, size: snapshot.cocoaFrame.size))
        if isOpenedImageMode {
            let inset = OpenedImageEditorGeometry.canvasInset
            setFrameSize(CGSize(
                width: snapshot.cocoaFrame.width + inset * 2,
                height: snapshot.cocoaFrame.height + inset * 2
            ))
            setBoundsOrigin(CGPoint(x: -inset, y: -inset))
        }
        wantsLayer = true
        annotationLayer = AnnotationLayer(
            pointSize: snapshot.cocoaFrame.size,
            scale: snapshot.pixelScale
        )
        obfuscationLayer = AnnotationLayer(
            pointSize: snapshot.cocoaFrame.size,
            scale: snapshot.pixelScale
        )
        erasePreviewAnnotationLayer = AnnotationLayer(
            pointSize: snapshot.cocoaFrame.size,
            scale: snapshot.pixelScale
        )
        erasePreviewObfuscationLayer = AnnotationLayer(
            pointSize: snapshot.cocoaFrame.size,
            scale: snapshot.pixelScale
        )

        // Keep only the windows that intersect this display, in local coordinates.
        windowTargets = windows.compactMap { target in
            let local = CGRect(
                x: target.frame.minX - snapshot.cocoaFrame.minX,
                y: target.frame.minY - snapshot.cocoaFrame.minY,
                width: target.frame.width,
                height: target.frame.height
            )
            guard local.intersects(bounds) else { return nil }
            return WindowTarget(
                windowID: target.windowID,
                frame: local,
                title: target.title,
                appName: target.appName
            )
        }

        setUpChrome()

        // The Character Viewer temporarily makes its own window key. Restore
        // the editor when this overlay becomes key again so the selected emoji
        // is still delivered to the text input client rather than to the
        // canvas view.
        textEditorFocusObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let keyWindow = notification.object as? NSWindow else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      keyWindow === self.window,
                      let editor = self.textEditor,
                      keyWindow.firstResponder !== editor
                else { return }
                keyWindow.makeFirstResponder(editor)
            }
        }

        switch mode {
        case .preselected(let globalRect):
            let local = globalToLocal(globalRect).clamped(to: bounds)
            if local.width >= 2, local.height >= 2 {
                selection = local
                phase = .ready
            }
        case .openedImage:
            selection = imageRect
            phase = .ready
        default:
            break
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        textAnalysisTask?.cancel()
        if let textRecognitionKeyMonitor {
            NSEvent.removeMonitor(textRecognitionKeyMonitor)
        }
        if let overlayKeyMonitor {
            NSEvent.removeMonitor(overlayKeyMonitor)
        }
        if let textEditorFocusObserver {
            NotificationCenter.default.removeObserver(textEditorFocusObserver)
        }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    /// Give the floating chrome first refusal in every editor mode. The opened
    /// image editor already performs this routing from `OverlayCanvasView`, but
    /// a normal screenshot hosts this view directly as the window content view.
    /// Relying on AppKit's default recursive hit-test in that second hierarchy
    /// lets a click on a visual-effect panel reach `mouseDown(with:)` here and
    /// be interpreted as a new selection.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = hitTestChrome(point, from: self) {
            return hit
        }
        return super.hitTest(point)
    }

    /// Hit-tests panels that may extend beyond the image view in the opened
    /// image editor. The point is supplied by a common ancestor (the full-size
    /// canvas), so this remains correct even when the editor's bounds origin
    /// and frame have moved independently during panning or canvas growth.
    func hitTestChrome(_ point: NSPoint, from ancestor: NSView) -> NSView? {
        var panels: [NSView] = [toolStrip, actionBar]
        if let stylePopover { panels.append(stylePopover) }
        for panel in panels where !panel.isHidden {
            let localPoint = panel.convert(point, from: ancestor)
            guard panel.bounds.contains(localPoint) else { continue }
            // Return the deepest control so NSButton receives the mouse-down
            // and performs its action. Returning the panel as a fallback is
            // intentional only for its empty background area, which should
            // swallow the click without starting a capture underneath.
            return panel.hitTest(localPoint) ?? panel
        }
        return nil
    }

    private func globalToLocal(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - snapshot.cocoaFrame.minX,
            y: rect.minY - snapshot.cocoaFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Tracking
    //
    // A tracking area rather than the window's `mouseMoved`: only the key window
    // receives `mouseMoved`, so on a second display the pointer would appear stuck
    // at the origin. `.activeAlways` delivers moves to every overlay regardless.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        delegate?.overlayWantsKeyFocus(self)
        updatePointer(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        hoveredWindow = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    /// Called by the controller when a SIBLING display's view is about to take
    /// key focus. Relying solely on this view's own `mouseExited` was not
    /// reliable enough in practice — crossing the boundary between two adjacent
    /// shielding-level windows could leave the loupe stuck showing on the
    /// display the pointer just left. Clearing it explicitly, from the one place
    /// that always knows focus moved, makes it unconditional.
    func clearPointerState() {
        guard pointerInside else { return }
        pointerInside = false
        hoveredWindow = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if !pointerInside {
            pointerInside = true
            delegate?.overlayWantsKeyFocus(self)
        }
        updatePointer(with: event)
    }

    private func updatePointer(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        activeModifiers = normalized(event.modifierFlags)
        updateCommandCaptureMode(for: activeModifiers)

        if case .window = mode, selection == nil {
            let previous = hoveredWindow?.windowID
            hoveredWindow = windowTargets.first { $0.frame.contains(cursorPoint) }
            if hoveredWindow?.windowID != previous { needsDisplay = true }
        }
        // The loupe and brush-size ring both live under the pointer, so any move
        // is a redraw while either is on screen.
        if shouldShowMagnifier || brushCursorDiameter != nil || eyedropperActive {
            needsDisplay = true
        }
        updateCursor()
    }

    /// Seeds pointer state before the first mouse event arrives, so the loupe is
    /// already under the cursor the instant the overlay appears.
    func syncPointer(globalLocation: CGPoint) {
        let inside = snapshot.cocoaFrame.contains(globalLocation)
        pointerInside = inside
        if inside {
            cursorPoint = CGPoint(
                x: globalLocation.x - snapshot.cocoaFrame.minX,
                y: globalLocation.y - snapshot.cocoaFrame.minY
            )
        }
        needsDisplay = true
    }

    private func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
    }

    override func flagsChanged(with event: NSEvent) {
        let updated = normalized(event.modifierFlags)
        guard updated != activeModifiers else { return }
        activeModifiers = updated
        updateCommandCaptureMode(for: updated)
        // ⌃ swaps what the current tool draws; the strip shows that immediately so
        // the alternate is discoverable without committing to a drag.
        toolStrip.setAlternate(activeModifiers.contains(.control), style: style)
        if case .drawing(let origin) = phase {
            draft = makeDraft(from: origin, to: cursorPoint)
            rebuildErasePreviewLayers()
        }
        needsDisplay = true
    }

    /// Command is a temporary mode switch only while the overlay is waiting for
    /// its first selection. It is deliberately not Control: Control already
    /// changes drawing-tool variants and is also used for the secondary-drag
    /// path. Command therefore has no conflict with annotation behavior before
    /// selection, while the existing ⌘S/⌘Z/⌘P actions remain available after a
    /// selection exists.
    private func updateCommandCaptureMode(for modifiers: NSEvent.ModifierFlags) {
        guard selection == nil, baseCaptureMode.supportsCommandCaptureToggle else { return }
        let next = baseCaptureMode.commandVariant(commandHeld: modifiers.contains(.command))
        guard next.isWindowCapture != mode.isWindowCapture else { return }
        mode = next
        hoveredWindow = nil
        if mode.isWindowCapture {
            hoveredWindow = windowTargets.first { $0.frame.contains(cursorPoint) }
        }
        updateCursor()
        needsDisplay = true
    }

    // MARK: - Chrome setup

    private func setUpChrome() {
        style = .current()

        for panel in [toolStrip as NSView, actionBar as NSView] {
            panel.translatesAutoresizingMaskIntoConstraints = true
            panel.isHidden = true
            addSubview(panel)
        }
        magnifierView.frame = bounds
        magnifierView.autoresizingMask = [.width, .height]
        magnifierView.isHidden = true
        magnifierView.drawContent = { [weak self] in
            guard let self else { return }
            self.drawMagnifier(at: self.cursorPoint)
        }
        // The loupe is a transparent, non-hit-testing view above the in-overlay
        // chrome. The style popover is added later and is raised above it too.
        addSubview(magnifierView, positioned: .above, relativeTo: nil)

        toolStrip.onToolSelected = { [weak self] in self?.select(tool: $0) }
        toolStrip.onStyleTapped = { [weak self] in self?.toggleStylePopover() }
        toolStrip.onStyleDoubleTapped = { [weak self] in self?.toggleStylePopover() }
        toolStrip.onUndo = { [weak self] in self?.undo() }
        toolStrip.onRedo = { [weak self] in self?.redo() }
        toolStrip.setSelected(tool)
        toolStrip.setColor(style.color)

        actionBar.onCopy = { [weak self] in self?.finish(with: .copy) }
        actionBar.onSave = { [weak self] shiftHeld in
            self?.finish(with: shiftHeld ? .saveAs : .save)
        }
        actionBar.onPrint = { [weak self] in self?.finish(with: .print) }
        actionBar.onCancel = { [weak self] in self?.cancel() }
    }

    /// Called once the view is in a window and its size is final.
    func activate() {
        installOverlayKeyMonitorIfNeeded()
        updateChromeBoundsForCurrentViewport()
        updateChromeVisibility()
        layoutChrome()
        needsDisplay = true
    }

    /// Tool buttons and VisionKit can become the first responder. Keep the
    /// overlay-level Escape and tool shortcuts reliable regardless of which
    /// child currently owns keyboard focus.
    private func installOverlayKeyMonitorIfNeeded() {
        guard overlayKeyMonitor == nil else { return }
        overlayKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.window?.isKeyWindow == true else {
                return event
            }
            guard self.textEditor == nil else { return event }

            let modifiers = self.normalized(event.modifierFlags)
            if event.keyCode == UInt16(kVK_Escape) {
                if self.eyedropperActive {
                    self.eyedropperActive = false
                    self.stylePopover?.setEyedropperActive(false)
                    self.updateCursor()
                    self.needsDisplay = true
                } else {
                    // Escape is the unambiguous cancel action for both the
                    // screenshot and opened-image sessions.
                    self.cancel()
                }
                return nil
            }

            guard modifiers.isEmpty || modifiers == .shift,
                  let matched = ToolStrip.tools.first(where: { $0.shortcutKeyCode == event.keyCode })
            else { return event }

            self.select(tool: matched)
            return nil
        }
    }

    /// Sets the larger coordinate area available to the floating chrome. Normal
    /// screenshot overlays leave this unset and retain their existing layout.
    func setChromeBounds(_ bounds: CGRect) {
        chromeBounds = bounds
        layoutChrome()
    }

    // MARK: - Tool + style

    private func select(tool newTool: ToolKind) {
        // Clicking Text again is a way to keep working in the current editor,
        // including its single/double-click variants. It must not commit
        // the editor merely because the selected tool is already Text.
        if textEditor != nil, newTool == .text {
            if let editor = textEditor {
                window?.makeFirstResponder(editor)
            }
            return
        }
        // A tool change ends the color-picker interaction as well as the text
        // editor. Do this before reconfiguring the shared StylePopover so the
        // system panel cannot remain attached to the old tool.
        stylePopover?.detachSystemColorPanel()
        commitTextEditorIfNeeded()
        if newTool != .recognizeText { stopTextRecognition() }
        tool = newTool
        toolStrip.setSelected(newTool)
        toolStrip.setAlternate(activeModifiers.contains(.control), style: style)
        stylePopover?.configure(for: newTool, style: style)
        if newTool != .recognizeText {
            window?.makeFirstResponder(self)
        }
        layoutChrome()
        if newTool == .recognizeText { startTextRecognition() }
        updateCursor()
        needsDisplay = true
    }

    private func stopTextRecognition() {
        textAnalysisTask?.cancel()
        textAnalysisTask = nil
        if let textRecognitionKeyMonitor {
            NSEvent.removeMonitor(textRecognitionKeyMonitor)
            self.textRecognitionKeyMonitor = nil
        }
        textAnalysisOverlay?.removeFromSuperview()
        textAnalysisOverlay = nil
    }

    private func startTextRecognition() {
        stopTextRecognition()
        guard tool == .recognizeText, let selection,
              #available(macOS 13.0, *), ImageAnalyzer.isSupported,
              let image = snapshot.crop(toGlobalRect: CGRect(
                  x: selection.minX + snapshot.cocoaFrame.minX,
                  y: selection.minY + snapshot.cocoaFrame.minY,
                  width: selection.width,
                  height: selection.height
              ))
        else {
            if #available(macOS 13.0, *), !ImageAnalyzer.isSupported {
                Feedback.flash(message: L10n.t("error.textRecognition"))
            }
            return
        }

        let overlay = ImageAnalysisOverlayView(frame: selection)
        overlay.preferredInteractionTypes = [.textSelection]
        overlay.selectableItemsHighlighted = true
        overlay.delegate = self
        addSubview(overlay, positioned: .above, relativeTo: nil)
        textAnalysisOverlay = overlay
        // The analysis surface covers the selected image, but the toolbar and
        // action bar must remain reachable even when macOS has placed them
        // inside that rectangle on a small display.
        addSubview(toolStrip, positioned: .above, relativeTo: nil)
        addSubview(actionBar, positioned: .above, relativeTo: nil)
        if let stylePopover { addSubview(stylePopover, positioned: .above, relativeTo: nil) }
        textRecognitionKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self,
                  self.tool == .recognizeText,
                  let overlay = self.textAnalysisOverlay,
                  self.handleTextRecognitionKey(event, overlay: overlay)
            else { return event }
            return nil
        }
        let analyzer = ImageAnalyzer()
        textAnalysisTask = Task { @MainActor [weak self, weak overlay] in
            do {
                let analysis = try await analyzer.analyze(
                    image,
                    orientation: .up,
                    configuration: ImageAnalyzer.Configuration([.text])
                )
                guard let self,
                      let overlay,
                      !Task.isCancelled,
                      self.tool == .recognizeText,
                      self.textAnalysisOverlay === overlay
                else { return }
                overlay.analysis = analysis
                overlay.selectableItemsHighlighted = true
                self.window?.makeFirstResponder(overlay)
                self.needsDisplay = true
            } catch {
                guard !Task.isCancelled else { return }
                Log.debug("text recognition failed: \(error.localizedDescription)")
                Feedback.flash(message: L10n.t("error.textRecognitionFailed"))
            }
        }
    }

    private func copyRecognizedText(from overlay: ImageAnalysisOverlayView) {
        let text = overlay.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Feedback.flash(message: L10n.t("toast.textCopied"))
    }

    private func handleTextRecognitionKey(
        _ event: NSEvent,
        overlay: ImageAnalysisOverlayView
    ) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return false }

        switch Int(event.keyCode) {
        case kVK_ANSI_A:
            let text = overlay.text
            guard !text.isEmpty else { return true }
            overlay.selectedRanges = [text.startIndex..<text.endIndex]
            return true
        case kVK_ANSI_C:
            copyRecognizedText(from: overlay)
            return true
        default:
            return false
        }
    }

    // MARK: - VisionKit text selection

    func overlayView(
        _ overlayView: ImageAnalysisOverlayView,
        shouldBeginAt point: CGPoint,
        forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes
    ) -> Bool {
        analysisType.contains(.textSelection)
            && (overlayView.analysisHasText(at: point) || overlayView.hasActiveTextSelection)
    }

    func overlayView(
        _ overlayView: ImageAnalysisOverlayView,
        shouldHandleKeyDownEvent event: NSEvent
    ) -> Bool {
        handleTextRecognitionKey(event, overlay: overlayView)
    }

    func textSelectionDidChange(_ overlayView: ImageAnalysisOverlayView) {
        needsDisplay = true
    }

    @available(macOS 13.0, *)
    func overlayView(
        _ overlayView: ImageAnalysisOverlayView,
        shouldShowMenuForEvent event: NSEvent,
        atPoint point: CGPoint
    ) -> Bool {
        overlayView.hasActiveTextSelection || overlayView.analysisHasText(at: point)
    }

    // Keep VisionKit's native text actions, including Look Up and Translate.
    // Remove only actions that operate on the underlying image/subject or
    // unrelated sharing/search destinations. Using the native menu is
    // important: those actions carry their system-provided services and
    // localization, which a manually rebuilt menu cannot reproduce.
    @available(macOS 14.0, *)
    func overlayView(
        _ overlayView: ImageAnalysisOverlayView,
        updatedMenuFor menu: NSMenu,
        for event: NSEvent,
        at point: CGPoint
    ) -> NSMenu {
        filterTextRecognitionMenu(menu)
        return menu
    }

    @available(macOS 14.0, *)
    func overlayView(_ overlayView: ImageAnalysisOverlayView, needsUpdate menu: NSMenu) {
        filterTextRecognitionMenu(menu)
    }

    @available(macOS 14.0, *)
    func overlayView(_ overlayView: ImageAnalysisOverlayView, willOpen menu: NSMenu) {
        filterTextRecognitionMenu(menu)
    }

    @available(macOS 14.0, *)
    private func filterTextRecognitionMenu(_ menu: NSMenu) {
        let hiddenTags: Set<Int> = [
            ImageAnalysisOverlayView.MenuTag.copyImage,
            ImageAnalysisOverlayView.MenuTag.shareImage,
            ImageAnalysisOverlayView.MenuTag.copySubject,
            ImageAnalysisOverlayView.MenuTag.shareSubject
        ]
        let hiddenTitleTokens = [
            "google", "search", "share", "image", "subject", "подел", "найти",
            "изображ", "объект"
        ]

        for index in menu.items.indices.reversed() {
            let item = menu.items[index]
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hasHiddenSemantic = hiddenTitleTokens.contains { title.contains($0) }
            if hiddenTags.contains(item.tag) || hasHiddenSemantic {
                menu.removeItem(at: index)
                continue
            }
            if let submenu = item.submenu {
                filterTextRecognitionMenu(submenu)
            }
        }

        // VisionKit can leave a separator behind after a tagged action is
        // removed. Keep the native menu compact and avoid leading/trailing or
        // doubled separators.
        while menu.items.first?.isSeparatorItem == true {
            menu.removeItem(at: 0)
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        var index = menu.items.count - 1
        while index > 0 {
            if menu.items[index].isSeparatorItem && menu.items[index - 1].isSeparatorItem {
                menu.removeItem(at: index)
            }
            index -= 1
        }
    }

    private func toggleStylePopover() {
        if let popover = stylePopover {
            popover.detachSystemColorPanel()
            popover.removeFromSuperview()
            stylePopover = nil
            eyedropperActive = false
            updateCursor()
            return
        }

        let popover = StylePopover(tool: tool, style: style)
        popover.translatesAutoresizingMaskIntoConstraints = true
        popover.onStyleChange = { [weak self] newStyle in
            guard let self else { return }
            style = newStyle
            Settings.shared.toolColor = newStyle.color
            Settings.shared.strokeWidth = newStyle.lineWidth
            Settings.shared.fontSize = newStyle.fontSize
            Settings.shared.textBackdrop = newStyle.textBackdrop
            Settings.shared.textBackdropColor = newStyle.backdropColor
            Settings.shared.obfuscation = newStyle.obfuscation
            Settings.shared.markerShape = newStyle.markerShape
            Settings.shared.eraserRadius = newStyle.eraserRadius
            Settings.shared.eraserShape = newStyle.eraserShape
            Settings.shared.eraserMode = newStyle.eraserMode
            Settings.shared.counterSize = newStyle.counterSize
            Settings.shared.counterArrowWidth = newStyle.counterArrowWidth
            Settings.shared.shapeFilled = newStyle.filled
            Settings.shared.arrowDoubleHeaded = newStyle.arrowDoubleHeaded
            toolStrip.setColor(newStyle.color)
            toolStrip.setAlternate(activeModifiers.contains(.control), style: newStyle)
            // The editor's own glyphs stay `.clear` — see `beginTextEditing` —
            // so only the caret color and the layout-affecting font need to
            // track the new style here. The visible, styled preview (color,
            // backdrop, shadow) is the `draft` annotation rebuilt below;
            // without that rebuild a color/backdrop change wouldn't show up
            // until the next keystroke happened to trigger it.
            if let editor = textEditor {
                // When an existing annotation is reopened, textEditorStyle
                // starts as the annotation's old style. Keep it in sync with
                // the complete style emitted by the popover, otherwise the
                // preview and the committed annotation continue using the old
                // color/backdrop/font while only the string appears editable.
                textEditorStyle = newStyle
                editor.font = NSFont.systemFont(ofSize: newStyle.fontSize, weight: .semibold)
                editor.insertionPointColor = newStyle.color
                editor.relayoutToContent()
                updateLiveTextDraft()
            }
            needsDisplay = true
        }
        // Any content change can resize the panel — a new swatch row, a tool with
        // different controls — so its frame is recomputed instead of being left at
        // whatever it measured on creation.
        popover.onContentChanged = { [weak self] in self?.layoutChrome() }
        popover.onEyedropperToggled = { [weak self] active, target in
            guard let self else { return }
            eyedropperActive = active
            eyedropperTarget = target
            updateCursor()
            needsDisplay = true
        }
        addSubview(popover)
        stylePopover = popover
        addSubview(magnifierView, positioned: .above, relativeTo: nil)
        layoutChrome()
    }

    // MARK: - History

    func sessionState() -> SelectionOverlayState {
        SelectionOverlayState(annotations: annotations, selection: selection, counterNext: counterNext)
    }

    private func pushUndoState(_ reason: HistoryReason = .annotation) {
        // A run of nudges collapses into the step before the run started.
        if reason == .nudge, lastHistoryReason == .nudge { return }
        delegate?.overlayWillChange(self)
        lastHistoryReason = reason
        updateHistoryButtons()
    }

    private func undo() {
        commitTextEditorIfNeeded()
        delegate?.overlayDidRequestUndo(self)
    }

    private func redo() {
        delegate?.overlayDidRequestRedo(self)
    }

    /// Called by the controller when a SIBLING display just started a new
    /// selection. Only one selection may exist across the whole capture
    /// session, so this one gives up everything it had — there is nothing
    /// useful left to keep once it can no longer be the chosen area.
    func discardSelectionForSelectionElsewhere() {
        guard selection != nil else { return }
        commitTextEditorIfNeeded()
        lastHistoryReason = nil
        annotations = []
        selection = nil
        counterNext = 1
        draft = nil
        eraseStroke = []
        phase = .idle
        rebuildLayer()
        updateChromeVisibility()
        layoutChrome()
        updateCursor()
        updateHistoryButtons()
        needsDisplay = true
    }

    func apply(_ state: SelectionOverlayState) {
        annotations = state.annotations
        selection = state.selection
        counterNext = state.counterNext
        draft = nil
        eraseStroke = []
        rebuildLayer()
        phase = selection == nil ? .idle : .ready
        lastHistoryReason = nil
        updateChromeVisibility()
        layoutChrome()
        updateCursor()
        updateHistoryButtons()
        needsDisplay = true
    }

    /// Repaints the raster sheet. Called whenever the annotation list changes by
    /// any route other than an in-progress eraser drag, which punches directly.
    private func rebuildLayer() {
        let visibleAnnotations = editingTextID.map { id in
            annotations.filter { $0.id != id }
        } ?? annotations

        // The foreground sheet keeps ordinary annotations above every processed
        // screenshot region. The background sheet contains obfuscations and
        // erase operations, with source-over so a later pass covers an earlier
        // one without deleting the earlier vector annotation from history.
        annotationLayer?.rebuild(
            annotations: visibleAnnotations.filter { !$0.isObfuscation },
            obfuscation: nil
        )
        obfuscationLayer?.rebuild(
            annotations: visibleAnnotations.filter { $0.isObfuscation || $0.isErase },
            obfuscation: obfuscation,
            obfuscationBlendMode: .normal
        )
    }

    /// Applies a live rectangle/ellipse eraser to copies of both sheets. This
    /// previews the same result as release without punching through the frozen
    /// screenshot itself or changing undo state before mouse-up.
    private func rebuildErasePreviewLayers() {
        guard let draft, draft.isErase else { return }
        let visibleAnnotations = editingTextID.map { id in
            annotations.filter { $0.id != id }
        } ?? annotations
        erasePreviewAnnotationLayer?.rebuild(
            annotations: visibleAnnotations.filter { !$0.isObfuscation } + [draft],
            obfuscation: nil
        )
        erasePreviewObfuscationLayer?.rebuild(
            annotations: visibleAnnotations.filter { $0.isObfuscation || $0.isErase } + [draft],
            obfuscation: obfuscation,
            obfuscationBlendMode: .normal
        )
    }

    private func recomputeCounter() {
        var highest = 0
        for annotation in annotations {
            if case .counter(_, let number, _) = annotation.shape { highest = max(highest, number) }
        }
        counterNext = highest + 1
    }

    private func updateHistoryButtons() {
        delegate?.overlayHistoryAvailabilityDidChange(self)
    }

    func setHistoryState(canUndo: Bool, canRedo: Bool) {
        toolStrip.setHistoryState(canUndo: canUndo, canRedo: canRedo)
    }

    // MARK: - Mouse

    // macOS turns ⌃-click into a secondary click at the window-server level, so a
    // ⌃-drag arrives as `rightMouse*`. Since ⌃ is the modifier for a tool's
    // alternate behaviour, those events have to be routed back to the normal path
    // or the alternate would be unusable with the mouse.
    private var forwardingRightDrag = false

    override func rightMouseDown(with event: NSEvent) {
        guard normalized(event.modifierFlags).contains(.control) else { return }
        forwardingRightDrag = true
        mouseDown(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard forwardingRightDrag else { return }
        mouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard forwardingRightDrag else { return }
        forwardingRightDrag = false
        mouseUp(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        activeModifiers = normalized(event.modifierFlags)
        updateCommandCaptureMode(for: activeModifiers)

        if eyedropperActive {
            if let color = sampleColor(at: point) {
                stylePopover?.updateSampledColor(color, target: eyedropperTarget)
            }
            eyedropperActive = false
            stylePopover?.setEyedropperActive(false, target: eyedropperTarget)
            updateCursor()
            needsDisplay = true
            return
        }

        if textEditor != nil {
            commitTextEditorIfNeeded()
            return
        }

        // A double-click outside the selection (or with none yet) closes the
        // whole session — chrome panels swallow their own clicks before this
        // method ever sees them, so reaching here already means the click
        // landed on the capture surface, not a button.
        if event.clickCount >= 2 {
            let outsideSelection = selection.map { !$0.contains(point) } ?? true
            if outsideSelection {
                cancel()
                return
            }
        }

        guard let selection else {
            if case .window = mode, let hovered = hoveredWindow {
                pushUndoState(.selection)
                delegate?.overlayDidBeginSelection(self)
                self.selection = hovered.frame.clamped(to: bounds)
                phase = .ready
                finishSelectionChange()
                return
            }
            beginNewSelection(at: point)
            return
        }

        if let handle = handle(at: point, in: selection) {
            pushUndoState(.selection)
            phase = .resizing(handle: handle)
            updateChromeVisibility()
            needsDisplay = true
            return
        }

        // In the opened-image editor Move pans the 100% image. Crop handles
        // were handled above, so dragging anywhere else never changes the crop
        // rectangle and can safely navigate a large image.
        if isOpenedImageMode, tool == .move {
            let imageOrigin = CGPoint(
                x: frame.minX - bounds.minX,
                y: frame.minY - bounds.minY
            )
            phase = .panning(
                startImageOrigin: imageOrigin,
                startWindowPoint: event.locationInWindow
            )
            updateChromeVisibility()
            updateCursor()
            needsDisplay = true
            return
        }

        // Outside the selection: drop it and rubber-band a new one, whatever tool
        // is active. Reaching for a different area is more common mid-session than
        // drawing outside the frame, which is not possible anyway.
        guard selection.contains(point) else {
            beginNewSelection(at: point)
            return
        }

        switch tool {
        case .move:
            pushUndoState(.selection)
            phase = .moving(grabOffset: CGSize(
                width: point.x - selection.minX,
                height: point.y - selection.minY
            ))
            updateChromeVisibility()
            needsDisplay = true
        case .text:
            if let existing = editableTextAnnotation(at: point) {
                beginTextEditing(existing: existing)
            } else {
                beginTextEditing(at: point)
            }
        case .counter:
            // A click commits a plain numbered circle; dragging keeps the same
            // number at the start point and previews an arrow to the cursor.
            phase = .drawing(origin: point)
            draft = makeDraft(from: point, to: point)
            needsDisplay = true
        case .recognizeText:
            phase = .ready
            return
        case .eraser:
            if style.eraserMode == .objects {
                if let index = annotationIndex(at: point) {
                    pushUndoState()
                    annotations.remove(at: index)
                    recomputeCounter()
                    rebuildLayer()
                    updateHistoryButtons()
                    needsDisplay = true
                }
                phase = .ready
                return
            }
            switch style.eraserShape {
            case .brush:
                // Punched straight into the layer as it moves — see below —
                // rather than staged through `draft`, so undo is pushed
                // up front like the pen/marker tools it behaves like.
                pushUndoState()
                phase = .drawing(origin: point)
                eraseStroke = [point]
                annotationLayer?.erase(points: eraseStroke, width: style.eraserRadius * 2)
                obfuscationLayer?.erase(points: eraseStroke, width: style.eraserRadius * 2)
                needsDisplay = true
            case .rectangle, .ellipse:
                // A rubber-band region, like the shape tools: staged in `draft`
                // and only committed (and undo-pushed) on release.
                phase = .drawing(origin: point)
                draft = makeDraft(from: point, to: point)
                rebuildErasePreviewLayers()
                needsDisplay = true
            }
        default:
            phase = .drawing(origin: point)
            draft = makeDraft(from: point, to: point)
            needsDisplay = true
        }
    }

    private func beginNewSelection(at point: CGPoint) {
        commitTextEditorIfNeeded()
        pushUndoState(.selection)
        delegate?.overlayDidBeginSelection(self)
        selection = CGRect(corner: point, corner: point)
        phase = .creating(origin: point)
        updateChromeVisibility()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        activeModifiers = normalized(event.modifierFlags)

        switch phase {
        case .creating(let origin):
            selection = rubberBandRect(origin: origin, current: point).clamped(to: bounds)

        case .moving(let grabOffset):
            guard let current = selection else { return }
            let moved = CGRect(
                x: point.x - grabOffset.width,
                y: point.y - grabOffset.height,
                width: current.width,
                height: current.height
            )
            selection = moved.nudgedInside(bounds)

        case .resizing(let handle):
            guard let current = selection else { return }
            let resized = handle.resize(current, to: point)
            if isOpenedImageMode {
                expandOpenedImageCanvas(to: resized)
            }
            selection = resized.clamped(to: bounds)

        case .panning(let startImageOrigin, let startWindowPoint):
            let delta = CGSize(
                width: event.locationInWindow.x - startWindowPoint.x,
                height: event.locationInWindow.y - startWindowPoint.y
            )
            setImageOrigin(startImageOrigin.offsetBy(dx: delta.width, dy: delta.height))

        case .drawing(let origin):
            if tool == .eraser, style.eraserShape == .brush {
                let previous = eraseStroke.last ?? point
                eraseStroke.append(point)
                // Punch just the new segment: re-punching the whole path every
                // frame would cost a full-display pass per mouse move.
                annotationLayer?.erase(points: [previous, point], width: style.eraserRadius * 2)
                obfuscationLayer?.erase(points: [previous, point], width: style.eraserRadius * 2)
            } else {
                draft = makeDraft(from: origin, to: point)
                rebuildErasePreviewLayers()
            }

        case .idle, .ready:
            return
        }

        needsDisplay = true
        layoutChrome()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch phase {
        case .creating:
            if let current = selection, current.width < 4 || current.height < 4 {
                // A click without a drag clears the selection rather than leaving
                // a useless sliver behind.
                selection = nil
                phase = .idle
            } else {
                phase = .ready
            }
            finishSelectionChange()

        case .moving, .resizing:
            phase = .ready
            finishSelectionChange()

        case .panning:
            phase = .ready
            updateChromeVisibility()
            updateChromeBoundsForCurrentViewport()
            updateCursor()
            needsDisplay = true

        case .drawing(let origin):
            phase = .ready
            if tool == .eraser, style.eraserShape == .brush {
                // The layer already shows the stroke; recording it keeps undo and
                // export in step without a second full repaint.
                annotations.append(Annotation(
                    shape: .erase(points: eraseStroke, width: style.eraserRadius * 2),
                    style: style
                ))
                eraseStroke = []
            } else if let annotation = makeDraft(from: origin, to: point), isMeaningful(annotation) {
                pushUndoState()
                annotations.append(annotation)
                if case .counter = annotation.shape { counterNext += 1 }
                rebuildLayer()
            }
            draft = nil
            needsDisplay = true

        case .idle, .ready:
            break
        }
    }

    /// In the opened-image editor the Move tool also behaves like a lightweight
    /// scroll view. Both wheel mice and precise trackpad gestures arrive here;
    /// using `scrollingDelta` preserves the smoother trackpad values while the
    /// fallback keeps ordinary wheel notches useful.
    override func scrollWheel(with event: NSEvent) {
        guard isOpenedImageMode else {
            super.scrollWheel(with: event)
            return
        }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 20
        let rawDelta = CGSize(
            width: event.scrollingDeltaX * multiplier,
            height: event.scrollingDeltaY * multiplier
        )
        panOpenedImage(by: SystemScrollDirection.contentDelta(rawDelta))
    }

    /// Trackpad swipe gestures are separate from ordinary two-finger scrolling
    /// on some macOS versions. Both gestures pan the image regardless of the
    /// selected annotation tool; no click-drag or Move tool is required.
    override func swipe(with event: NSEvent) {
        guard isOpenedImageMode else {
            super.swipe(with: event)
            return
        }
        panOpenedImage(by: SystemScrollDirection.contentDelta(CGSize(
            width: event.deltaX * 80,
            height: event.deltaY * 80
        )))
    }

    func panOpenedImage(by delta: CGSize) {
        guard isOpenedImageMode else { return }
        guard abs(delta.width) > 0.001 || abs(delta.height) > 0.001 else { return }

        let imageOrigin = CGPoint(
            x: frame.minX - bounds.minX,
            y: frame.minY - bounds.minY
        )
        setImageOrigin(imageOrigin.offsetBy(dx: delta.width, dy: delta.height))
        updateChromeVisibility()
        updateChromeBoundsForCurrentViewport()
        updateCursor()
        needsDisplay = true
    }

    private func finishSelectionChange() {
        if var current = selection {
            current = Geometry.pixelAligned(current, scale: snapshot.pixelScale)
            selection = current.clamped(to: bounds)
        }
        updateChromeVisibility()
        layoutChrome()
        if tool == .recognizeText { startTextRecognition() }
        updateCursor()
        needsDisplay = true
    }

    /// Applies a panning position while preserving a 300–400 point safety
    /// margin, so the image never fills the entire viewport edge-to-edge.
    private func setImageOrigin(_ proposed: CGPoint) {
        guard isOpenedImageMode, let canvas = superview else { return }
        let origin = OpenedImageEditorGeometry.constrainedCanvasImageOrigin(
            proposedImageOrigin: proposed,
            canvasRect: openedImageCanvasRect,
            viewport: canvas.bounds
        )
        frame.origin = CGPoint(
            x: origin.x + bounds.minX,
            y: origin.y + bounds.minY
        )
        updateChromeBoundsForCurrentViewport()
        needsDisplay = true
    }

    /// Grows the editor view when a crop handle reaches the current reserve.
    /// The new area therefore becomes real content that Move can pan through,
    /// instead of stopping at the old image-plus-reserve boundary. The source
    /// image keeps the same screen position while the local bounds grow around
    /// it.
    private func expandOpenedImageCanvas(to proposedSelection: CGRect) {
        guard isOpenedImageMode else { return }
        let target = imageRect.union(proposedSelection)
        let reserve = OpenedImageEditorGeometry.canvasInset
        let newMinX = min(bounds.minX, target.minX - reserve)
        let newMinY = min(bounds.minY, target.minY - reserve)
        let newMaxX = max(bounds.maxX, target.maxX + reserve)
        let newMaxY = max(bounds.maxY, target.maxY + reserve)
        let targetBounds = CGRect(
            x: newMinX,
            y: newMinY,
            width: newMaxX - newMinX,
            height: newMaxY - newMinY
        )
        guard targetBounds != bounds else { return }

        let imageOrigin = CGPoint(
            x: frame.minX - bounds.minX,
            y: frame.minY - bounds.minY
        )
        setFrameSize(targetBounds.size)
        setBoundsOrigin(targetBounds.origin)
        frame.origin = CGPoint(
            x: imageOrigin.x + bounds.minX,
            y: imageOrigin.y + bounds.minY
        )
        updateTrackingAreas()
        updateChromeBoundsForCurrentViewport()
        needsDisplay = true
    }

    /// Converts the visible window viewport into this view's image-local
    /// coordinates so the floating panels remain outside the image after a pan.
    private func updateChromeBoundsForCurrentViewport() {
        guard isOpenedImageMode, let canvas = superview else { return }
        let imageOrigin = CGPoint(
            x: frame.minX - bounds.minX,
            y: frame.minY - bounds.minY
        )
        chromeBounds = CGRect(
            x: canvas.bounds.minX - imageOrigin.x,
            y: canvas.bounds.minY - imageOrigin.y,
            width: canvas.bounds.width,
            height: canvas.bounds.height
        )
        layoutChrome()
    }

    // MARK: - Drafts

    /// Rubber-band geometry shared by the selection and every shape tool.
    /// ⇧ constrains to a square, ⌥ grows from the starting point as the centre.
    private func rubberBandRect(origin: CGPoint, current: CGPoint) -> CGRect {
        var dx = current.x - origin.x
        var dy = current.y - origin.y

        if activeModifiers.contains(.shift) {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if activeModifiers.contains(.option) {
            return CGRect(
                x: origin.x - abs(dx), y: origin.y - abs(dy),
                width: abs(dx) * 2, height: abs(dy) * 2
            )
        }
        return CGRect(corner: origin, corner: CGPoint(x: origin.x + dx, y: origin.y + dy))
    }

    /// Style for the shape currently being drawn, with ⌃ applied. ⌃ always
    /// TOGGLES away from whatever the popover already has set as the default,
    /// rather than forcing a fixed alternate — so it stays a genuine "the other
    /// option" regardless of which one is currently chosen.
    private var draftStyle: ToolStyle {
        var result = style
        guard activeModifiers.contains(.control) else { return result }
        switch tool {
        case .rectangle, .ellipse:
            result.filled.toggle()
        case .arrow:
            result.arrowDoubleHeaded.toggle()
        case .obfuscate:
            result.obfuscation.style = result.obfuscation.style.alternate
        default:
            break
        }
        return result
    }

    private func makeDraft(from origin: CGPoint, to point: CGPoint) -> Annotation? {
        let style = draftStyle

        switch tool {
        case .pen:
            var points: [CGPoint]
            if case .pen(let existing) = draft?.shape {
                points = existing
                points.append(point)
            } else {
                points = [origin, point]
            }
            return Annotation(shape: .pen(points: points), style: style)

        case .marker:
            switch style.markerShape {
            case .rectangle:
                return Annotation(
                    shape: .markerRect(rubberBandRect(origin: origin, current: point)),
                    style: style
                )
            case .ellipse:
                return Annotation(
                    shape: .markerEllipse(rubberBandRect(origin: origin, current: point)),
                    style: style
                )
            case .brush:
                var points: [CGPoint]
                if case .marker(let existing) = draft?.shape {
                    points = existing
                    points.append(point)
                } else {
                    points = [origin, point]
                }
                return Annotation(shape: .marker(points: points), style: style)
            }

        case .line, .arrow:
            var (from, to) = endpoints(origin: origin, current: point)
            if activeModifiers.contains(.shift) {
                to = snapTo45Degrees(from: from, to: to)
                if activeModifiers.contains(.option) {
                    // Keep the midpoint pinned when both modifiers are held.
                    let dx = to.x - from.x, dy = to.y - from.y
                    from = CGPoint(x: origin.x - dx / 2, y: origin.y - dy / 2)
                    to = CGPoint(x: origin.x + dx / 2, y: origin.y + dy / 2)
                }
            }
            return Annotation(
                shape: tool == .line
                    ? .line(from: from, to: to)
                    : .arrow(from: from, to: to, doubleHeaded: style.arrowDoubleHeaded),
                style: style
            )

        case .rectangle:
            return Annotation(shape: .rectangle(rubberBandRect(origin: origin, current: point)), style: style)

        case .ellipse:
            return Annotation(shape: .ellipse(rubberBandRect(origin: origin, current: point)), style: style)

        case .obfuscate:
            switch style.obfuscation.shape {
            case .rectangle:
                return Annotation(
                    shape: .obfuscateRect(rubberBandRect(origin: origin, current: point)),
                    style: style
                )
            case .ellipse:
                return Annotation(
                    shape: .obfuscateEllipse(rubberBandRect(origin: origin, current: point)),
                    style: style
                )
            case .brush:
                var points: [CGPoint]
                if case .obfuscateBrush(let existing) = draft?.shape {
                    points = existing
                    points.append(point)
                } else {
                    points = [origin, point]
                }
                return Annotation(shape: .obfuscateBrush(points: points), style: style)
            }

        case .eraser:
            // Brush erasing punches straight into the layer as it moves (see
            // `mouseDragged`/`mouseDown`) rather than staging through `draft`,
            // so it never reaches this branch.
            switch style.eraserShape {
            case .rectangle:
                return Annotation(shape: .eraseRect(rubberBandRect(origin: origin, current: point)), style: style)
            case .ellipse:
                return Annotation(shape: .eraseEllipse(rubberBandRect(origin: origin, current: point)), style: style)
            case .brush:
                return nil
            }

        case .counter:
            let arrowTo = origin.distance(to: point) > 3 ? point : nil
            return Annotation(
                shape: .counter(center: origin, number: counterNext, arrowTo: arrowTo),
                style: style
            )

        case .move, .recognizeText, .text:
            return nil
        }
    }

    /// Endpoints for line-like tools, honouring ⌥ (grow from the centre).
    private func endpoints(origin: CGPoint, current: CGPoint) -> (CGPoint, CGPoint) {
        guard activeModifiers.contains(.option) else { return (origin, current) }
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        return (
            CGPoint(x: origin.x - dx, y: origin.y - dy),
            current
        )
    }

    private func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.shape {
        case .pen(let points), .marker(let points), .obfuscateBrush(let points):
            return points.count > 1
        case .line(let a, let b), .arrow(let a, let b, _):
            return a.distance(to: b) > 3
        case .rectangle(let rect), .ellipse(let rect),
             .markerRect(let rect), .markerEllipse(let rect),
             .obfuscateRect(let rect), .obfuscateEllipse(let rect),
             .eraseRect(let rect), .eraseEllipse(let rect):
            return rect.width > 3 && rect.height > 3
        case .counter, .text:
            return true
        case .erase(let points, _):
            return !points.isEmpty
        }
    }

    private func snapTo45Degrees(from origin: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    // MARK: - Text editing

    private func beginTextEditing(at point: CGPoint) {
        beginTextEditing(
            origin: point,
            initialText: "",
            annotationID: nil,
            editorStyle: style
        )
    }

    private func beginTextEditing(existing annotation: Annotation) {
        guard case .text(let origin, let string) = annotation.shape else { return }
        // The settings panel must describe the text being edited, rather than
        // the last defaults used for a newly created annotation. This also
        // gives a subsequent style change a complete, correct baseline.
        style = annotation.style
        toolStrip.setColor(style.color)
        toolStrip.setAlternate(activeModifiers.contains(.control), style: style)
        stylePopover?.configure(for: .text, style: style)
        beginTextEditing(
            origin: origin,
            initialText: string,
            annotationID: annotation.id,
            editorStyle: annotation.style
        )
    }

    private func beginTextEditing(
        origin: CGPoint,
        initialText: String,
        annotationID: UUID?,
        editorStyle: ToolStyle
    ) {
        commitTextEditorIfNeeded()

        let font = NSFont.systemFont(ofSize: editorStyle.fontSize, weight: .semibold)
        let height = ceil(font.ascender - font.descender + font.leading) + 4
        let editor = AnnotationTextView(frame: CGRect(
            x: origin.x,
            y: origin.y - height,
            width: max(160, Annotation.textSize(initialText, style: editorStyle).width + 4),
            height: height
        ))
        editor.font = font
        // Glyphs are invisible — the styled preview (color, backdrop, shadow)
        // is drawn separately below, through `draft`, using the exact same
        // `AnnotationRenderer` call that bakes the final annotation. That makes
        // what is on screen while typing pixel-identical to what gets
        // committed, with no separate "editor look" that can drift out of sync.
        // Only the caret stays visible, in the tool's current color.
        editor.textColor = .clear
        editor.insertionPointColor = editorStyle.color
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.string = initialText
        editor.onCommit = { [weak self] in self?.commitTextEditorIfNeeded() }
        editor.onCancel = { [weak self] in self?.discardTextEditor() }
        editor.onTextChanged = { [weak self] in self?.updateLiveTextDraft() }

        textEditorOrigin = origin
        // A new label follows the current tool style while it is being typed;
        // an existing label keeps its own style so editing it does not silently
        // recolor it just because the tool defaults changed.
        textEditorStyle = annotationID == nil ? nil : editorStyle
        editingTextID = annotationID
        if annotationID != nil { rebuildLayer() }
        textEditor = editor
        addSubview(editor)

        let handle = TextMoveHandle()
        handle.onDrag = { [weak self] delta in self?.moveTextEditor(by: delta) }
        addSubview(handle)
        textMoveHandle = handle
        positionTextMoveHandle()

        window?.makeFirstResponder(editor)
        editor.relayoutToContent()
        updateLiveTextDraft()
    }

    /// Keeps the on-screen preview in step with every keystroke, reusing the
    /// same `draft` slot the shape tools stage their in-progress drag in.
    private func updateLiveTextDraft() {
        guard let editor = textEditor else { return }
        draft = Annotation(
            shape: .text(origin: textEditorOrigin, string: editor.string),
            style: textEditorStyle ?? style
        )
        positionTextMoveHandle()
        needsDisplay = true
    }

    /// Drag callback from the move handle: shifts the anchor point, the editor
    /// itself, and the live preview together, in the overlay's own coordinate
    /// space (see `TextMoveHandle` for why the delta needs no conversion).
    private func moveTextEditor(by delta: CGPoint) {
        guard let editor = textEditor else { return }
        textEditorOrigin.x += delta.x
        textEditorOrigin.y += delta.y
        editor.frame.origin.x += delta.x
        editor.frame.origin.y += delta.y
        updateLiveTextDraft()
    }

    private func positionTextMoveHandle() {
        guard let editor = textEditor, let handle = textMoveHandle else { return }
        let size = handle.frame.size
        let target = CGRect(
            x: editor.frame.minX - size.width / 2,
            y: editor.frame.maxY - size.height / 2,
            width: size.width, height: size.height
        )
        handle.frame = target.nudgedInside(bounds.insetBy(dx: 2, dy: 2))
    }

    private func commitTextEditorIfNeeded() {
        guard let editor = textEditor else { return }
        stylePopover?.detachSystemColorPanel()
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = textEditorOrigin
        let editorStyle = textEditorStyle ?? style
        let editingID = editingTextID
        textEditor = nil
        editor.removeFromSuperview()
        textMoveHandle?.removeFromSuperview()
        textMoveHandle = nil
        textEditorStyle = nil
        editingTextID = nil
        draft = nil
        window?.makeFirstResponder(self)

        guard !text.isEmpty || editingID != nil else { needsDisplay = true; return }
        pushUndoState()
        if let editingID, let index = annotations.firstIndex(where: { $0.id == editingID }) {
            if text.isEmpty {
                annotations.remove(at: index)
            } else {
                annotations[index] = Annotation(
                    shape: .text(origin: origin, string: text),
                    style: editorStyle
                )
            }
        } else if !text.isEmpty {
            annotations.append(Annotation(
                shape: .text(origin: origin, string: text),
                style: editorStyle
            ))
        }
        rebuildLayer()
        needsDisplay = true
    }

    private func discardTextEditor() {
        stylePopover?.detachSystemColorPanel()
        let wasEditingExisting = editingTextID != nil
        textEditor?.removeFromSuperview()
        textEditor = nil
        textMoveHandle?.removeFromSuperview()
        textMoveHandle = nil
        textEditorStyle = nil
        editingTextID = nil
        draft = nil
        if wasEditingExisting { rebuildLayer() }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Every shortcut below is matched on the physical key, never on the typed
        // character: on a Cyrillic layout "C" produces "с" and character matching
        // would silently break every shortcut in the overlay.
        let modifiers = normalized(event.modifierFlags)
        let code = event.keyCode

        if modifiers.contains(.command) {
            switch Int(code) {
            case kVK_ANSI_C: finish(with: .copy); return
            case kVK_ANSI_S: finish(with: modifiers.contains(.shift) ? .saveAs : .save); return
            case kVK_ANSI_P: finish(with: .print); return
            case kVK_ANSI_Z: modifiers.contains(.shift) ? redo() : undo(); return
            case kVK_ANSI_A:
                pushUndoState(.selection)
                delegate?.overlayDidBeginSelection(self)
                selection = isOpenedImageMode ? imageRect : bounds
                phase = .ready
                finishSelectionChange()
                return
            default: break
            }
        }

        switch Int(code) {
        case kVK_Escape:
            if eyedropperActive {
                eyedropperActive = false
                stylePopover?.setEyedropperActive(false)
                updateCursor()
                needsDisplay = true
                return
            }
            // Esc backs out one step at a time: away from whatever tool is
            // drawing first, and only closes the session once there is nothing
            // left to back out of (already on the plain selection tool, or no
            // selection at all).
            if selection != nil, tool != .move {
                select(tool: .move)
                return
            }
            cancel()
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            finish(with: .copy)
            return
        case kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow:
            nudgeSelection(keyCode: code, fine: !modifiers.contains(.shift))
            return
        case kVK_Delete, kVK_ForwardDelete:
            deleteLastAnnotation()
            return
        case kVK_Tab:
            guard selection != nil else { break }
            toggleStylePopover()
            return
        default:
            break
        }

        if modifiers.isEmpty || modifiers == .shift {
            if Int(code) == kVK_ANSI_C, selection == nil {
                copyPickedColor()
                return
            }
            if let matched = ToolStrip.tools.first(where: { $0.shortcutKeyCode == code }) {
                select(tool: matched)
                return
            }
        }

        super.keyDown(with: event)
    }

    private func nudgeSelection(keyCode: UInt16, fine: Bool) {
        guard var current = selection else { return }
        pushUndoState(.nudge)
        let step: CGFloat = fine ? 1 : 10
        switch Int(keyCode) {
        case kVK_LeftArrow: current.origin.x -= step
        case kVK_RightArrow: current.origin.x += step
        case kVK_DownArrow: current.origin.y -= step
        case kVK_UpArrow: current.origin.y += step
        default: break
        }
        selection = current.nudgedInside(bounds)
        finishSelectionChange()
    }

    private func deleteLastAnnotation() {
        guard !annotations.isEmpty else { return }
        pushUndoState()
        annotations.removeLast()
        recomputeCounter()
        rebuildLayer()
        needsDisplay = true
    }

    private func annotationIndex(at point: CGPoint) -> Int? {
        annotations.indices.reversed().first { index in
            let annotation = annotations[index]
            return !annotation.isErase && annotation.boundingBox.contains(point)
        }
    }

    private func editableTextAnnotation(at point: CGPoint) -> Annotation? {
        for index in annotations.indices.reversed() {
            let annotation = annotations[index]
            guard case .text = annotation.shape,
                  annotation.boundingBox.contains(point),
                  !textWasPartiallyErased(at: index)
            else { continue }
            return annotation
        }
        return nil
    }

    /// Erasing is raster-destructive, but the original vector annotations remain
    /// for undo/export. Any later erase annotation intersecting the text's bounds
    /// therefore makes the text intentionally non-editable. The conservative
    /// bounds check avoids offering an editor for text that is only partly left.
    private func textWasPartiallyErased(at index: Int) -> Bool {
        let textBounds = annotations[index].boundingBox
        guard index + 1 < annotations.count else { return false }
        return annotations[(index + 1)...].contains { annotation in
            annotation.isErase && annotation.boundingBox.intersects(textBounds)
        }
    }

    private func copyPickedColor() {
        guard let color = sampleColor(at: cursorPoint) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.hexString, forType: .string)
        Feedback.flash(message: L10n.t("toast.color.copied", color.hexString))
    }

    private func sampleColor(at point: CGPoint) -> NSColor? {
        snapshot.color(atGlobalPoint: CGPoint(
            x: point.x + snapshot.cocoaFrame.minX,
            y: point.y + snapshot.cocoaFrame.minY
        ))
    }

    // MARK: - Finishing

    private func cancel() {
        Log.debug("cancel requested")
        stylePopover?.detachSystemColorPanel()
        delegate?.overlayDidRequestCancel(self)
    }

    private func finish(with action: OutputAction) {
        commitTextEditorIfNeeded()
        guard let selection, selection.width >= 1, selection.height >= 1 else { return }
        stylePopover?.detachSystemColorPanel()

        guard let image = renderImage(selection: selection) else {
            delegate?.overlayDidRequestCancel(self)
            return
        }
        let globalRect = CGRect(
            x: selection.minX + snapshot.cocoaFrame.minX,
            y: selection.minY + snapshot.cocoaFrame.minY,
            width: selection.width,
            height: selection.height
        )
        delegate?.overlay(self, didFinish: image, action: action, globalRect: globalRect)
    }

    /// Bakes the screenshot and every annotation into one image at native
    /// resolution, using the same renderer that painted the live preview.
    private func renderImage(selection: CGRect) -> CapturedImage? {
        let rect = Geometry.pixelAligned(selection, scale: snapshot.pixelScale)
        let scale = Settings.shared.downscaleRetina ? 1 : snapshot.pixelScale
        let pixelWidth = Int((rect.width * scale).rounded())
        let pixelHeight = Int((rect.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)

        let previous = NSGraphicsContext.current
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphicsContext

        context.interpolationQuality = .high
        if isOpenedImageMode {
            context.draw(snapshot.image, in: imageRect)
            drawOpenedImageCanvasFill(for: rect)
        } else {
            context.draw(snapshot.image, in: bounds)
        }

        // Re-flatten at the export scale rather than upsampling the on-screen
        // layer, so a 1× export is genuinely rendered at 1× and a Retina export
        // keeps full detail.
        let layerPointSize = isOpenedImageMode ? imageRect.size : bounds.size
        let layerRect = isOpenedImageMode ? imageRect : bounds
        let exportObfuscationLayer = AnnotationLayer(pointSize: layerPointSize, scale: scale)
        exportObfuscationLayer?.rebuild(
            annotations: annotations.filter { $0.isObfuscation || $0.isErase },
            obfuscation: obfuscation,
            obfuscationBlendMode: .normal
        )
        let exportAnnotationLayer = AnnotationLayer(pointSize: layerPointSize, scale: scale)
        exportAnnotationLayer?.rebuild(
            annotations: annotations.filter { !$0.isObfuscation },
            obfuscation: nil
        )
        if let obfuscations = exportObfuscationLayer?.image,
           let annotations = exportAnnotationLayer?.image {
            context.saveGState()
            context.clip(to: rect)
            context.draw(obfuscations, in: layerRect)
            context.draw(annotations, in: layerRect)
            context.restoreGState()
        }

        NSGraphicsContext.current = previous

        guard let cgImage = context.makeImage() else { return nil }
        return CapturedImage(cgImage: cgImage, pointSize: rect.size)
    }

    // MARK: - Chrome layout

    /// Creating, resizing or repositioning the selection is a fast-moving drag
    /// the panels would otherwise have to chase every frame — hiding them for
    /// its duration reads a lot less janky than a toolbar that races the
    /// pointer around the screen.
    private var isAdjustingSelectionBounds: Bool {
        switch phase {
        case .creating, .moving, .resizing, .panning: return true
        case .idle, .ready, .drawing: return false
        }
    }

    private func updateChromeVisibility() {
        let hasSelection = selection != nil
        let visible = hasSelection && !isAdjustingSelectionBounds
        toolStrip.isHidden = !visible
        actionBar.isHidden = !visible
        stylePopover?.isHidden = !visible
        if !hasSelection {
            stylePopover?.detachSystemColorPanel()
            stylePopover?.removeFromSuperview()
            stylePopover = nil
            eyedropperActive = false
            stopTextRecognition()
        }
        updateHistoryButtons()
    }

    private func layoutChrome() {
        guard let selection, !toolStrip.isHidden else { return }
        let gap: CGFloat = 8
        let safe = (chromeBounds ?? bounds).insetBy(dx: 4, dy: 4)

        var stripFrame = CGRect(origin: .zero, size: toolStrip.fittingSize)
        stripFrame.origin.x = selection.maxX + gap
        if stripFrame.maxX > safe.maxX {
            stripFrame.origin.x = selection.minX - gap - stripFrame.width
        }
        stripFrame.origin.y = selection.maxY - stripFrame.height
        stripFrame = stripFrame.nudgedInside(safe)
        toolStrip.frame = stripFrame

        var barFrame = CGRect(origin: .zero, size: actionBar.fittingSize)
        barFrame.origin.x = selection.maxX - barFrame.width
        barFrame.origin.y = selection.minY - gap - barFrame.height
        if barFrame.minY < safe.minY {
            barFrame.origin.y = selection.maxY + gap
        }
        if barFrame.maxY > safe.maxY {
            barFrame.origin.y = max(selection.minY + gap, safe.minY)
        }
        barFrame = barFrame.nudgedInside(safe)
        actionBar.frame = barFrame

        if let popover = stylePopover {
            // Re-measure every time: the popover changes height when the tool
            // changes and width when a "recent colors" row appears, and a stale
            // frame is what makes a panel look torn.
            popover.invalidateIntrinsicContentSize()
            popover.layoutSubtreeIfNeeded()
            var popoverFrame = CGRect(origin: .zero, size: popover.fittingSize)
            popoverFrame.origin.x = stripFrame.maxX + gap
            if popoverFrame.maxX > safe.maxX {
                popoverFrame.origin.x = stripFrame.minX - gap - popoverFrame.width
            }
            // Align to the strip's top, then pull back inside if it overflows.
            popoverFrame.origin.y = stripFrame.maxY - popoverFrame.height
            popoverFrame = popoverFrame.nudgedInside(safe)
            popover.frame = popoverFrame
        }
    }

    // MARK: - Cursor

    private func updateCursor() {
        guard let window, window.isKeyWindow else { return }

        if let handle = textMoveHandle, !handle.isHidden, handle.frame.contains(cursorPoint) {
            NSCursor.openHand.set()
            return
        }

        if tool == .recognizeText, !isPointerOverChrome {
            NSCursor.iBeam.set()
            return
        }

        if isPointerOverChrome {
            NSCursor.arrow.set()
            return
        }

        if eyedropperActive {
            NSCursor.crosshair.set()
            return
        }
        guard let selection else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = handle(at: cursorPoint, in: selection) {
            handle.cursor.set()
            return
        }
        if selection.contains(cursorPoint) {
            switch tool {
            case .move: NSCursor.openHand.set()
            case .text: NSCursor.iBeam.set()
        case .pen:
            Self.transparentBrushCursor.set()
            case .marker where style.markerShape == .brush:
                Self.transparentBrushCursor.set()
            case .obfuscate where brushCursorDiameter != nil,
                 .eraser where brushCursorDiameter != nil:
                Self.transparentBrushCursor.set()
            default: NSCursor.crosshair.set()
            }
            return
        }
        if isOpenedImageMode, tool == .move, bounds.contains(cursorPoint) {
            NSCursor.openHand.set()
            return
        }
        NSCursor.crosshair.set()
    }

    /// Whether the cursor sits over one of the floating panels rather than the
    /// capture surface — those should show the ordinary pointer, not a
    /// crosshair or the eraser ring, like any other clickable UI.
    private var isPointerOverChrome: Bool {
        if !toolStrip.isHidden, toolStrip.frame.contains(cursorPoint) { return true }
        if !actionBar.isHidden, actionBar.frame.contains(cursorPoint) { return true }
        if let popover = stylePopover, popover.frame.contains(cursorPoint) { return true }
        return false
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> SelectionHandle? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return SelectionHandle.allCases.first { handle in
            handle.position(in: rect).distance(to: point) <= handleHitRadius
        }
    }

    // MARK: - Drawing

    /// The brush outline is rendered by the overlay itself. A transparent
    /// cursor keeps that outline unobstructed by either an arrow or a crosshair.
    private static let transparentBrushCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override func draw(_ dirtyRect: NSRect) {
        magnifierView.isHidden = !shouldShowMagnifier
        if !magnifierView.isHidden { magnifierView.needsDisplay = true }
        guard let context = NSGraphicsContext.current else { return }
        let cgContext = context.cgContext

        cgContext.interpolationQuality = .none
        if isOpenedImageMode {
            cgContext.draw(snapshot.image, in: imageRect)
            if let selection {
                drawOpenedImageCanvasFill(for: selection)
            }
        } else {
            cgContext.draw(snapshot.image, in: bounds)
        }

        if let selection {
            // Obfuscations are a separate background sheet. A live pass is
            // drawn over the committed background, then the ordinary foreground
            // sheet is drawn last so text, arrows and shapes stay readable.
            if let draft, draft.isObfuscation {
                drawAnnotationLayer(clippedTo: selection, layer: obfuscationLayer)
                AnnotationRenderer.draw(
                    [draft],
                    obfuscation: obfuscation,
                    clipTo: selection,
                    obfuscationBlendMode: .normal
                )
                drawAnnotationLayer(clippedTo: selection, layer: annotationLayer)
            } else if draft?.isErase == true {
                drawAnnotationLayer(clippedTo: selection, layer: erasePreviewObfuscationLayer)
                drawAnnotationLayer(clippedTo: selection, layer: erasePreviewAnnotationLayer)
            } else {
                drawAnnotationLayers(clippedTo: selection)
            }
            if let draft, !draft.isObfuscation {
                if !draft.isErase {
                    // The stroke in progress goes straight on top: nothing can
                    // have erased it yet, so it does not need to go through the
                    // layer.
                    AnnotationRenderer.draw([draft], obfuscation: obfuscation, clipTo: selection)
                }
            }
            drawDimming(excluding: selection)
            drawSelectionChrome(selection)
            if let draft, shouldDrawDashedPreview(for: draft) {
                drawDashedPreviewOutline(draft)
            }
        } else {
            drawDimming(excluding: nil)
            drawWindowHighlight()
            drawHint()
        }

        if pointerInside, let diameter = brushCursorDiameter,
           selection?.contains(cursorPoint) == true, textEditor == nil,
           !isPointerOverChrome {
            drawBrushCursor(diameter: diameter)
        }
    }

    /// Fills only the newly added canvas inside an outward crop. The rest of
    /// the surrounding editor stays clear, allowing the overlay window's
    /// semi-transparent background to remain visible just like in screenshot
    /// capture mode.
    private func drawOpenedImageCanvasFill(for selection: CGRect) {
        let extensionRects = OpenedImageEditorGeometry.canvasExtensionRects(
            selection: selection,
            imageRect: imageRect
        )
        guard !extensionRects.isEmpty else { return }

        style.color.setFill()
        for rect in extensionRects {
            rect.intersection(bounds).fill(using: .sourceOver)
        }
    }

    private func shouldDrawDashedPreview(for annotation: Annotation) -> Bool {
        switch annotation.shape {
        case .eraseRect, .eraseEllipse:
            return true
        case .markerRect, .markerEllipse, .obfuscateRect, .obfuscateEllipse:
            return true
        default:
            return false
        }
    }

    private func drawDashedPreviewOutline(_ annotation: Annotation) {
        let path: NSBezierPath
        switch annotation.shape {
        case .eraseRect(let rect): path = NSBezierPath(rect: rect)
        case .eraseEllipse(let rect): path = NSBezierPath(ovalIn: rect)
        case .markerRect(let rect), .obfuscateRect(let rect): path = NSBezierPath(rect: rect)
        case .markerEllipse(let rect), .obfuscateEllipse(let rect): path = NSBezierPath(ovalIn: rect)
        default: return
        }
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        // Difference with opaque white is a true colour inversion, so the dash
        // remains visible over the screenshot, all annotation layers and blur.
        context.cgContext.setBlendMode(.difference)
        path.lineWidth = 1.5
        path.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.white.setStroke()
        path.stroke()
        context.restoreGraphicsState()
    }

    private func drawAnnotationLayers(clippedTo rect: CGRect) {
        drawAnnotationLayer(clippedTo: rect, layer: obfuscationLayer)
        drawAnnotationLayer(clippedTo: rect, layer: annotationLayer)
    }

    private func drawAnnotationLayer(clippedTo rect: CGRect, layer: AnnotationLayer?) {
        guard let image = layer?.image,
              let context = NSGraphicsContext.current
        else { return }
        context.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(image, in: isOpenedImageMode ? imageRect : bounds)
        context.restoreGraphicsState()
    }

    private var shouldShowMagnifier: Bool {
        guard pointerInside, !isPointerOverChrome else { return false }
        if eyedropperActive { return true }
        guard Settings.shared.showMagnifier else { return false }
        // Picking a whole window needs no pixel precision, and the loupe would
        // just cover the window you are trying to aim at.
        if case .window = mode, selection == nil { return false }
        switch phase {
        case .idle, .creating, .resizing: return true
        default: return false
        }
    }

    private var brushCursorDiameter: CGFloat? {
        switch tool {
        case .pen:
            return style.lineWidth
        case .marker where style.markerShape == .brush:
            return max(style.lineWidth * 4, 12)
        case .obfuscate where style.obfuscation.shape == .brush:
            return style.obfuscation.brushSize
        case .eraser where style.eraserMode == .pixels && style.eraserShape == .brush:
            return style.eraserRadius * 2
        default:
            return nil
        }
    }

    private func drawBrushCursor(diameter: CGFloat) {
        let radius = diameter / 2
        let ring = NSBezierPath(ovalIn: CGRect(
            x: cursorPoint.x - radius, y: cursorPoint.y - radius,
            width: radius * 2, height: radius * 2
        ))
        NSColor.black.withAlphaComponent(0.55).setStroke()
        ring.lineWidth = 3
        ring.stroke()
        NSColor.white.setStroke()
        ring.lineWidth = 1.5
        ring.stroke()
    }

    private func drawDimming(excluding selection: CGRect?) {
        // Opened-image windows already provide the general semi-transparent
        // backdrop through `OverlayWindow`. Painting these bands as well would
        // create a second, visibly darker halo around the image/canvas.
        guard !isOpenedImageMode else { return }

        let dim = NSColor.black.withAlphaComponent(
            CGFloat(Settings.shared.dimOpacity)
        )
        dim.setFill()

        guard let selection else {
            bounds.fill(using: .sourceOver)
            return
        }
        // Four bands around the selection, so the selected pixels stay untouched.
        let above = CGRect(
            x: bounds.minX, y: selection.maxY,
            width: bounds.width, height: bounds.maxY - selection.maxY
        )
        let below = CGRect(
            x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: selection.minY - bounds.minY
        )
        let left = CGRect(
            x: bounds.minX, y: selection.minY,
            width: selection.minX - bounds.minX, height: selection.height
        )
        let right = CGRect(
            x: selection.maxX, y: selection.minY,
            width: bounds.maxX - selection.maxX, height: selection.height
        )
        for band in [above, below, left, right] where band.width > 0 && band.height > 0 {
            band.fill(using: .sourceOver)
        }
    }

    private func drawSelectionChrome(_ selection: CGRect) {
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.9).setStroke()
        border.stroke()

        NSColor.controlAccentColor.setFill()
        NSColor.white.setStroke()
        for handle in SelectionHandle.allCases {
            let center = handle.position(in: selection)
            let dot = NSBezierPath(ovalIn: CGRect(
                x: center.x - handleRadius, y: center.y - handleRadius,
                width: handleRadius * 2, height: handleRadius * 2
            ))
            dot.fill()
            dot.lineWidth = 1.5
            dot.stroke()
        }

        if Settings.shared.showSizeBadge {
            let pixels = Settings.shared.downscaleRetina ? 1 : snapshot.pixelScale
            let text = "\(Int((selection.width * pixels).rounded())) × \(Int((selection.height * pixels).rounded()))"
            var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
            if origin.y + 20 > bounds.maxY { origin.y = selection.maxY - 26 }
            drawBadge(text, at: origin)
        }
    }

    private func drawWindowHighlight() {
        guard case .window = mode, pointerInside, let hovered = hoveredWindow,
              let context = NSGraphicsContext.current
        else { return }

        context.saveGraphicsState()
        NSBezierPath(rect: hovered.frame).addClip()
        context.cgContext.interpolationQuality = .none
        context.cgContext.draw(snapshot.image, in: bounds)
        context.restoreGraphicsState()

        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: hovered.frame.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 2
        outline.stroke()

        let label = hovered.title.isEmpty ? hovered.appName : "\(hovered.appName) — \(hovered.title)"
        drawBadge(label, at: CGPoint(x: hovered.frame.minX + 8, y: hovered.frame.maxY - 30))
    }

    private func drawHint() {
        guard pointerInside else { return }
        let modeHint = mode.isWindowCapture
            ? L10n.t("overlay.hint.window")
            : L10n.t("overlay.hint.area")
        let toggleHint = baseCaptureMode.supportsCommandCaptureToggle
            ? " · " + L10n.t("overlay.hint.commandToggle")
            : ""
        drawCenteredHint(modeHint + toggleHint)
    }

    private func drawCenteredHint(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        let padding: CGFloat = 10
        let box = CGRect(
            x: bounds.midX - size.width / 2 - padding,
            y: bounds.maxY - size.height - 60,
            width: size.width + padding * 2,
            height: size.height + padding
        )
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        attributed.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }

    private func drawBadge(_ text: String, at origin: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let size = attributed.size()
        let box = CGRect(
            x: origin.x, y: origin.y,
            width: size.width + 12, height: size.height + 6
        ).nudgedInside(bounds)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        attributed.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }

    // MARK: - Magnifier

    private func drawMagnifier(at point: CGPoint) {
        let pixelsAcross = 15
        let blockSize: CGFloat = 10
        let side = CGFloat(pixelsAcross) * blockSize
        let labelHeight: CGFloat = 42
        let offset: CGFloat = 22

        // Coordinates, hex and RGB each get their own line. RGB is padded to a
        // fixed digit width (see `fixedWidthRgbString`) so the box doesn't keep
        // resizing as the cursor crosses pixels with different digit counts —
        // hex is already fixed-width on its own (`#RRGGBB`), and coordinates
        // vary little enough in practice not to matter.
        let color = sampleColor(at: point) ?? .black
        let sourceHeight = isOpenedImageMode ? imageRect.height : bounds.height
        let coordText = "\(Int(point.x)), \(Int(sourceHeight - point.y))"
        let hexText = color.hexString
        let rgbText = color.fixedWidthRgbString
        let readoutFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let readoutAttributes: [NSAttributedString.Key: Any] = [
            .font: readoutFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let textWidth = [coordText, hexText, rgbText]
            .map { ($0 as NSString).size(withAttributes: readoutAttributes).width }
            .max() ?? 0
        let swatchSize: CGFloat = 12
        let swatchLeading: CGFloat = 6
        let swatchTrailing: CGFloat = 6
        let trailingPadding: CGFloat = 8
        let neededWidth = swatchLeading + swatchSize + swatchTrailing + textWidth + trailingPadding
        let width = max(side, neededWidth)

        var frame = CGRect(
            x: point.x + offset,
            y: point.y - offset - side - labelHeight,
            width: width,
            height: side + labelHeight
        )
        if frame.maxX > bounds.maxX - 4 { frame.origin.x = point.x - offset - width }
        if frame.minY < 4 { frame.origin.y = point.y + offset }
        frame = frame.nudgedInside(bounds.insetBy(dx: 4, dy: 4))

        // The pixel grid itself stays a fixed square, centred within whatever
        // extra width the readout line demanded.
        let imageRect = CGRect(
            x: frame.minX + (frame.width - side) / 2, y: frame.minY + labelHeight,
            width: side, height: side
        )

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()

        let container = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.82).setFill()
        container.fill()

        // Crop out the pixels around the cursor and blow them up with no
        // interpolation, so individual pixels stay square.
        let scale = snapshot.pixelScale
        let centerPixelX = (point.x * scale).rounded(.down)
        let centerPixelY = ((sourceHeight - point.y) * scale).rounded(.down)
        let half = CGFloat(pixelsAcross / 2)
        let cropRect = CGRect(
            x: centerPixelX - half,
            y: centerPixelY - half,
            width: CGFloat(pixelsAcross),
            height: CGFloat(pixelsAcross)
        )

        context.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: 4, yRadius: 4).addClip()
        NSColor(white: 0.12, alpha: 1).setFill()
        imageRect.fill()

        // Near a screen edge the sample window hangs off the screenshot. Clip it
        // and blit the surviving part at its true position, so the crosshair keeps
        // pointing at the pixel actually under the cursor instead of drifting.
        let imageBounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        let visible = cropRect.intersection(imageBounds).integral
        if !visible.isNull, visible.width >= 1, visible.height >= 1,
           let crop = snapshot.image.cropping(to: visible) {
            let insetLeft = (visible.minX - cropRect.minX) * blockSize
            let insetTop = (visible.minY - cropRect.minY) * blockSize
            let destination = CGRect(
                x: imageRect.minX + insetLeft,
                y: imageRect.maxY - insetTop - visible.height * blockSize,
                width: visible.width * blockSize,
                height: visible.height * blockSize
            )
            context.cgContext.interpolationQuality = .none
            context.cgContext.draw(crop, in: destination)
        }

        // Pixel grid. Difference blending keeps it visible over both a white page
        // and a black terminal, which a fixed grey never manages.
        context.compositingOperation = .difference
        NSColor(white: 0.22, alpha: 1).setStroke()
        let grid = NSBezierPath()
        for step in 1..<pixelsAcross {
            let offsetValue = CGFloat(step) * blockSize
            grid.move(to: CGPoint(x: imageRect.minX + offsetValue, y: imageRect.minY))
            grid.line(to: CGPoint(x: imageRect.minX + offsetValue, y: imageRect.maxY))
            grid.move(to: CGPoint(x: imageRect.minX, y: imageRect.minY + offsetValue))
            grid.line(to: CGPoint(x: imageRect.maxX, y: imageRect.minY + offsetValue))
        }
        grid.lineWidth = 1
        grid.stroke()

        // Centre cell marks the exact pixel under the cursor.
        let centerCell = CGRect(
            x: imageRect.minX + half * blockSize,
            y: imageRect.minY + half * blockSize,
            width: blockSize, height: blockSize
        )
        NSColor.white.setStroke()
        let marker = NSBezierPath(rect: centerCell.insetBy(dx: -0.5, dy: -0.5))
        marker.lineWidth = 1.5
        marker.stroke()
        context.compositingOperation = .sourceOver
        context.restoreGraphicsState()

        // Readout: coordinates, hex and RGB, using the width already measured
        // above so this never has to clip against the container edge.
        let readout = NSAttributedString(
            string: "\(coordText)\n\(hexText)\n\(rgbText)",
            attributes: readoutAttributes
        )
        let swatch = CGRect(
            x: frame.minX + swatchLeading, y: frame.minY + (labelHeight - swatchSize) / 2,
            width: swatchSize, height: swatchSize
        )
        color.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).stroke()
        readout.draw(at: CGPoint(x: swatch.maxX + swatchTrailing, y: frame.minY + 4))

        NSColor.white.withAlphaComponent(0.2).setStroke()
        container.lineWidth = 1
        container.stroke()

        context.restoreGraphicsState()
    }
}

/// Full-size transparent canvas around an opened image. It shields the area
/// outside the image from the application underneath while forwarding events
/// to the image editor and its panels.
final class OverlayCanvasView: NSView {
    weak var editorView: SelectionOverlayView?

    override var isOpaque: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        guard let editorView else {
            super.scrollWheel(with: event)
            return
        }
        let rawDelta = CGSize(
            width: event.scrollingDeltaX * (event.hasPreciseScrollingDeltas ? 1 : 20),
            height: event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 20)
        )
        editorView.panOpenedImage(by: SystemScrollDirection.contentDelta(rawDelta))
    }

    override func swipe(with event: NSEvent) {
        guard let editorView else {
            super.swipe(with: event)
            return
        }
        editorView.panOpenedImage(by: SystemScrollDirection.contentDelta(CGSize(
            width: event.deltaX * 80,
            height: event.deltaY * 80
        )))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let editorView else {
            return super.hitTest(point) ?? self
        }

        let editorPoint = convert(point, to: editorView)

        // The opened-image editor deliberately lets its panels live outside the
        // editor view's image frame. Route those points explicitly first;
        // relying on the normal parent hit-test would otherwise stop at the
        // editor view and never reach a toolbar button after the canvas moves
        // or grows.
        if let hit = editorView.hitTestChrome(point, from: self) {
            return hit
        }

        // For points over the actual editor, ask the editor to resolve its own
        // subviews (Live Text, text editing and the canvas itself) directly.
        // This keeps the transparent canvas as a shield without making it the
        // responder for clicks that belong to the editor.
        if editorView.frame.contains(point) {
            return editorView.hitTest(editorPoint) ?? editorView
        }

        return self
    }
}

/// Full-size transparent canvas for the loupe. Returning nil from `hitTest`
/// lets clicks pass through to the tool panels or capture surface underneath.
private final class MagnifierOverlayView: NSView {
    var drawContent: (() -> Void)?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        drawContent?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Text view used for the in-place text tool. Its own glyphs are invisible —
/// see `SelectionOverlayView.beginTextEditing` — so it exists purely to own the
/// caret, IME candidate window and keyboard input; only its FRAME (for caret
/// travel) and its STRING (read out on every change) matter to the overlay.
final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Fired after the string OR the frame changes, so the live styled preview
    /// and the move handle can follow.
    var onTextChanged: (() -> Void)?

    /// The annotation renderer uses the top edge of the text block as its
    /// anchor. A flipped text view gives AppKit the same top-to-bottom line
    /// order, so caret rectangles for later lines do not appear above the
    /// corresponding rendered line.
    override var isFlipped: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // ⌘↩ commits; a bare ↩ inserts a newline so multi-line labels work.
        if event.keyCode == UInt16(kVK_Return), event.modifierFlags.contains(.command) {
            onCommit?()
            return
        }
        super.keyDown(with: event)
    }

    /// Character Viewer can send either a String or an attributed string to
    /// the first responder. Normalize both forms explicitly: the editor is
    /// intentionally plain text, and forwarding only the default AppKit path
    /// can lose the insertion when the overlay regains key status after the
    /// Character Viewer closes.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let string: String
        if let value = insertString as? String {
            string = value
        } else if let value = insertString as? NSAttributedString {
            string = value.string
        } else if let value = insertString as? NSString {
            string = value as String
        } else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let currentRange = replacementRange.location == NSNotFound
            ? selectedRange
            : replacementRange
        guard currentRange.location != NSNotFound else { return }
        replaceCharacters(in: currentRange, with: string)
        setSelectedRange(NSRange(
            location: currentRange.location + (string as NSString).length,
            length: 0
        ))
        scrollRangeToVisible(selectedRange)

        // `replaceCharacters(in:with:)` is also used for Character Viewer
        // input, but it does not consistently deliver NSTextView's
        // `didChangeText()` callback on every macOS version. Keep the overlay
        // draft synchronized explicitly so newly typed text is visible
        // immediately, without requiring a later style change to trigger a
        // redraw.
        relayoutToContent()
        onTextChanged?()
    }

    override func didChangeText() {
        super.didChangeText()
        relayoutToContent()
        onTextChanged?()
    }

    /// Recomputes the editor frame after text or font changes while keeping its
    /// top edge anchored to the annotation's origin. This is also called when
    /// a reopened annotation changes font size in the style popover.
    func relayoutToContent() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        // A little slack past the last glyph so the caret never renders flush
        // against the view's own edge; harmless now that insets are zero and
        // the glyphs themselves are invisible.
        let width = max(used.width + 4, 24)
        let minimumHeight = font.map { $0.ascender - $0.descender + $0.leading + 4 } ?? 4
        let height = max(used.height, minimumHeight)
        // Grow downwards from the anchor point the user clicked.
        let top = frame.maxY
        frame = CGRect(x: frame.minX, y: top - height, width: width, height: height)
    }
}

/// Small drag handle shown beside the text tool's live editor, letting the
/// user reposition what they are typing without discarding it.
final class TextMoveHandle: NSView {
    /// Delta since the last callback, in THIS view's own local coordinate
    /// space — which, since the handle applies no scale or rotation, is
    /// numerically identical to a delta in its superview's space.
    var onDrag: ((CGPoint) -> Void)?

    private let side: CGFloat = 20
    /// Tracked in WINDOW coordinates rather than local ones: the callback moves
    /// this very view each time it fires, and re-deriving a local point from a
    /// window-space event after the view has already shifted would silently
    /// double-count the motion. Window coordinates do not change under the
    /// handle moving, so consecutive raw positions can just be subtracted.
    private var lastWindowLocation: NSPoint?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = side / 2
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)

        let imageView = NSImageView(frame: bounds.insetBy(dx: 4, dy: 4))
        imageView.autoresizingMask = [.width, .height]
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        imageView.image = NSImage
            .freshSystemSymbol("arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        imageView.contentTintColor = .white
        imageView.imageScaling = .scaleProportionallyDown
        addSubview(imageView)

        toolTip = L10n.t("text.moveHandle")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        lastWindowLocation = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastWindowLocation else { return }
        let current = event.locationInWindow
        self.lastWindowLocation = current
        onDrag?(CGPoint(x: current.x - lastWindowLocation.x, y: current.y - lastWindowLocation.y))
    }

    override func mouseUp(with event: NSEvent) {
        lastWindowLocation = nil
    }
}
