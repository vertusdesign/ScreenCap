import AppKit
import Carbon.HIToolbox

protocol SelectionOverlayViewDelegate: AnyObject {
    /// The pointer entered this display — it should take keyboard focus.
    func overlayWantsKeyFocus(_ view: SelectionOverlayView)
    func overlayDidRequestCancel(_ view: SelectionOverlayView)
    func overlay(
        _ view: SelectionOverlayView,
        didFinish image: CapturedImage,
        action: OutputAction,
        globalRect: CGRect
    )
}

/// The whole capture experience for one display: frozen screenshot, dimming,
/// selection, annotation tools and the chrome around them.
///
/// The view's coordinate space is the display in Cocoa points with the origin at
/// its bottom-left corner, which is also the space every annotation is stored in.
final class SelectionOverlayView: NSView {

    private enum Phase {
        case idle
        case creating(origin: CGPoint)
        case ready
        case moving(grabOffset: CGSize)
        case resizing(handle: SelectionHandle)
        case drawing(origin: CGPoint)
    }

    // MARK: - Model

    weak var delegate: SelectionOverlayViewDelegate?

    private let snapshot: DisplaySnapshot
    private let obfuscation: ObfuscationSource
    private let mode: CaptureMode
    private var windowTargets: [WindowTarget] = []

    private var phase: Phase = .idle
    private(set) var selection: CGRect?
    private var annotations: [Annotation] = []
    private var draft: Annotation?

    /// One undo step. Resizing or moving the selection is an edit like any other,
    /// so the frame travels through history together with the drawing.
    private struct HistoryState {
        var annotations: [Annotation]
        var selection: CGRect?
        var counterNext: Int
    }

    private enum HistoryReason {
        case annotation
        case selection
        /// Arrow-key nudges, which coalesce so holding a key is one undo step.
        case nudge
    }

    private var undoStack: [HistoryState] = []
    private var redoStack: [HistoryState] = []
    private var lastHistoryReason: HistoryReason?

    /// Everything the user drew, flattened into one transparent raster sheet over
    /// the screenshot. Keeping it as pixels is what lets the eraser take away part
    /// of a stroke rather than the whole annotation.
    private var annotationLayer: AnnotationLayer?
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

    // MARK: - Chrome

    private let toolStrip = ToolStrip()
    private let actionBar = ActionBar()
    private var stylePopover: StylePopover?
    private var textEditor: AnnotationTextView?
    private var textEditorOrigin: CGPoint = .zero

    private var trackingAreaRef: NSTrackingArea?
    private let handleRadius: CGFloat = 4.5
    private let handleHitRadius: CGFloat = 9

    // MARK: - Init

    init(snapshot: DisplaySnapshot, mode: CaptureMode, windows: [WindowTarget]) {
        self.snapshot = snapshot
        self.mode = mode
        self.obfuscation = ObfuscationSource(
            source: snapshot.image,
            pointSize: snapshot.cocoaFrame.size,
            pixelScale: snapshot.pixelScale
        )
        super.init(frame: CGRect(origin: .zero, size: snapshot.cocoaFrame.size))
        wantsLayer = true
        annotationLayer = AnnotationLayer(
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

        if case .preselected(let globalRect) = mode {
            let local = globalToLocal(globalRect).clamped(to: bounds)
            if local.width >= 2, local.height >= 2 {
                selection = local
                phase = .ready
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

        if case .window = mode, selection == nil {
            let previous = hoveredWindow?.windowID
            hoveredWindow = windowTargets.first { $0.frame.contains(cursorPoint) }
            if hoveredWindow?.windowID != previous { needsDisplay = true }
        }
        // The loupe and the eraser ring both live under the pointer, so any move
        // is a redraw while either is on screen.
        if shouldShowMagnifier || tool == .eraser || eyedropperActive {
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
        // ⌃ swaps what the current tool draws; the strip shows that immediately so
        // the alternate is discoverable without committing to a drag.
        toolStrip.setAlternate(
            activeModifiers.contains(.control),
            obfuscationStyle: style.obfuscation.style
        )
        if case .drawing(let origin) = phase {
            draft = makeDraft(from: origin, to: cursorPoint)
        }
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

        toolStrip.onToolSelected = { [weak self] in self?.select(tool: $0) }
        toolStrip.onStyleTapped = { [weak self] in self?.toggleStylePopover() }
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
        updateChromeVisibility()
        layoutChrome()
        needsDisplay = true
    }

    // MARK: - Tool + style

    private func select(tool newTool: ToolKind) {
        commitTextEditorIfNeeded()
        tool = newTool
        toolStrip.setSelected(newTool)
        toolStrip.setAlternate(
            activeModifiers.contains(.control),
            obfuscationStyle: style.obfuscation.style
        )
        stylePopover?.configure(for: newTool, style: style)
        layoutChrome()
        updateCursor()
        needsDisplay = true
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
            let colorChanged = newStyle.color.hexString != style.color.hexString
            style = newStyle
            Settings.shared.toolColor = newStyle.color
            Settings.shared.strokeWidth = newStyle.lineWidth
            Settings.shared.fontSize = newStyle.fontSize
            Settings.shared.textBackdrop = newStyle.textBackdrop
            Settings.shared.textBackdropColor = newStyle.backdropColor
            Settings.shared.obfuscation = newStyle.obfuscation
            Settings.shared.eraserRadius = newStyle.eraserRadius
            if colorChanged { Settings.shared.noteColorUsed(newStyle.color) }
            toolStrip.setColor(newStyle.color)
            toolStrip.setAlternate(
                activeModifiers.contains(.control),
                obfuscationStyle: newStyle.obfuscation.style
            )
            textEditor?.font = NSFont.systemFont(ofSize: newStyle.fontSize, weight: .semibold)
            textEditor?.textColor = newStyle.color
            needsDisplay = true
        }
        // Any content change can resize the panel — a new swatch row, a tool with
        // different controls — so its frame is recomputed instead of being left at
        // whatever it measured on creation.
        popover.onContentChanged = { [weak self] in self?.layoutChrome() }
        popover.onEyedropperToggled = { [weak self] active in
            guard let self else { return }
            eyedropperActive = active
            updateCursor()
            needsDisplay = true
        }
        addSubview(popover)
        stylePopover = popover
        layoutChrome()
    }

    // MARK: - History

    private var currentState: HistoryState {
        HistoryState(annotations: annotations, selection: selection, counterNext: counterNext)
    }

    private func pushUndoState(_ reason: HistoryReason = .annotation) {
        // A run of nudges collapses into the step before the run started.
        if reason == .nudge, lastHistoryReason == .nudge { return }
        undoStack.append(currentState)
        redoStack.removeAll()
        if undoStack.count > 64 { undoStack.removeFirst() }
        lastHistoryReason = reason
        updateHistoryButtons()
    }

    private func undo() {
        commitTextEditorIfNeeded()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentState)
        apply(previous)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentState)
        apply(next)
    }

    private func apply(_ state: HistoryState) {
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
        annotationLayer?.rebuild(annotations: annotations, obfuscation: obfuscation)
    }

    private func recomputeCounter() {
        var highest = 0
        for annotation in annotations {
            if case .counter(_, let number) = annotation.shape { highest = max(highest, number) }
        }
        counterNext = highest + 1
    }

    private func updateHistoryButtons() {
        toolStrip.setHistoryState(canUndo: !undoStack.isEmpty, canRedo: !redoStack.isEmpty)
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

        if eyedropperActive {
            if let color = sampleColor(at: point) {
                style.color = color
                Settings.shared.toolColor = color
                Settings.shared.noteColorUsed(color)
                toolStrip.setColor(color)
                stylePopover?.updateSampledColor(color)
            }
            eyedropperActive = false
            stylePopover?.setEyedropperActive(false)
            updateCursor()
            needsDisplay = true
            return
        }

        if textEditor != nil {
            commitTextEditorIfNeeded()
            return
        }

        guard let selection else {
            if case .window = mode, let hovered = hoveredWindow {
                pushUndoState(.selection)
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
        case .text:
            beginTextEditing(at: point)
        case .counter:
            pushUndoState()
            annotations.append(Annotation(
                shape: .counter(center: point, number: counterNext),
                style: style
            ))
            counterNext += 1
            rebuildLayer()
            needsDisplay = true
        case .eraser:
            pushUndoState()
            phase = .drawing(origin: point)
            eraseStroke = [point]
            annotationLayer?.erase(points: eraseStroke, width: style.eraserRadius * 2)
            needsDisplay = true
        default:
            phase = .drawing(origin: point)
            draft = makeDraft(from: point, to: point)
            needsDisplay = true
        }
    }

    private func beginNewSelection(at point: CGPoint) {
        commitTextEditorIfNeeded()
        pushUndoState(.selection)
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
            selection = handle.resize(current, to: point).clamped(to: bounds)

        case .drawing(let origin):
            if tool == .eraser {
                let previous = eraseStroke.last ?? point
                eraseStroke.append(point)
                // Punch just the new segment: re-punching the whole path every
                // frame would cost a full-display pass per mouse move.
                annotationLayer?.erase(points: [previous, point], width: style.eraserRadius * 2)
            } else {
                draft = makeDraft(from: origin, to: point)
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

        case .drawing(let origin):
            phase = .ready
            if tool == .eraser {
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
                rebuildLayer()
            }
            draft = nil
            needsDisplay = true

        case .idle, .ready:
            break
        }
    }

    private func finishSelectionChange() {
        if var current = selection {
            current = Geometry.pixelAligned(current, scale: snapshot.pixelScale)
            selection = current.clamped(to: bounds)
        }
        updateChromeVisibility()
        layoutChrome()
        updateCursor()
        needsDisplay = true
    }

    // MARK: - Erasing

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

    /// Style for the shape currently being drawn, with ⌃ applied.
    private var draftStyle: ToolStyle {
        var result = style
        guard activeModifiers.contains(.control) else { return result }
        switch tool {
        case .rectangle, .ellipse:
            result.filled = true
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
        case .pen, .marker:
            var points: [CGPoint]
            switch draft?.shape {
            case .pen(let existing), .marker(let existing):
                points = existing
                points.append(point)
            default:
                points = [origin, point]
            }
            return Annotation(
                shape: tool == .pen ? .pen(points: points) : .marker(points: points),
                style: style
            )

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
                shape: tool == .line ? .line(from: from, to: to) : .arrow(from: from, to: to),
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

        case .move, .counter, .text, .eraser:
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
        case .line(let a, let b), .arrow(let a, let b):
            return a.distance(to: b) > 3
        case .rectangle(let rect), .ellipse(let rect),
             .obfuscateRect(let rect), .obfuscateEllipse(let rect):
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
        commitTextEditorIfNeeded()

        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        let height = ceil(font.ascender - font.descender + font.leading) + 6
        let editor = AnnotationTextView(frame: CGRect(
            x: point.x, y: point.y - height, width: 220, height: height
        ))
        editor.font = font
        editor.textColor = style.color
        editor.insertionPointColor = style.color
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.textContainerInset = NSSize(width: 2, height: 2)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.onCommit = { [weak self] in self?.commitTextEditorIfNeeded() }
        editor.onCancel = { [weak self] in self?.discardTextEditor() }

        textEditorOrigin = point
        textEditor = editor
        addSubview(editor)
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    private func commitTextEditorIfNeeded() {
        guard let editor = textEditor else { return }
        let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        textEditor = nil
        editor.removeFromSuperview()
        window?.makeFirstResponder(self)

        guard !text.isEmpty else { needsDisplay = true; return }
        pushUndoState()
        annotations.append(Annotation(
            shape: .text(origin: textEditorOrigin, string: text),
            style: style
        ))
        rebuildLayer()
        needsDisplay = true
    }

    private func discardTextEditor() {
        textEditor?.removeFromSuperview()
        textEditor = nil
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
                selection = bounds
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
        context.draw(snapshot.image, in: bounds)

        // Re-flatten at the export scale rather than upsampling the on-screen
        // layer, so a 1× export is genuinely rendered at 1× and a Retina export
        // keeps full detail.
        let exportLayer = AnnotationLayer(pointSize: bounds.size, scale: scale)
        exportLayer?.rebuild(annotations: annotations, obfuscation: obfuscation)
        if let flattened = exportLayer?.image {
            context.saveGState()
            context.clip(to: rect)
            context.draw(flattened, in: bounds)
            context.restoreGState()
        }

        NSGraphicsContext.current = previous

        guard let cgImage = context.makeImage() else { return nil }
        return CapturedImage(cgImage: cgImage, pointSize: rect.size)
    }

    // MARK: - Chrome layout

    private func updateChromeVisibility() {
        let visible = selection != nil
        toolStrip.isHidden = !visible
        actionBar.isHidden = !visible
        if !visible {
            stylePopover?.detachSystemColorPanel()
            stylePopover?.removeFromSuperview()
            stylePopover = nil
            eyedropperActive = false
        }
        updateHistoryButtons()
    }

    private func layoutChrome() {
        guard let selection, !toolStrip.isHidden else { return }
        let gap: CGFloat = 8
        let safe = bounds.insetBy(dx: 4, dy: 4)

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
            // changes and width when a "recent colours" row appears, and a stale
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

        if eyedropperActive || tool == .eraser {
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
            default: NSCursor.crosshair.set()
            }
            return
        }
        NSCursor.crosshair.set()
    }

    private func handle(at point: CGPoint, in rect: CGRect) -> SelectionHandle? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return SelectionHandle.allCases.first { handle in
            handle.position(in: rect).distance(to: point) <= handleHitRadius
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let cgContext = context.cgContext

        cgContext.interpolationQuality = .none
        cgContext.draw(snapshot.image, in: bounds)

        if let selection {
            drawAnnotationLayer(clippedTo: selection)
            if let draft {
                // The stroke in progress goes straight on top: nothing can have
                // erased it yet, so it does not need to go through the layer.
                AnnotationRenderer.draw([draft], obfuscation: obfuscation, clipTo: selection)
            }
            drawDimming(excluding: selection)
            drawSelectionChrome(selection)
        } else {
            drawDimming(excluding: nil)
            drawWindowHighlight()
            drawHint()
        }

        if pointerInside, tool == .eraser, selection != nil, textEditor == nil {
            drawEraserRing()
        }
        if shouldShowMagnifier {
            drawMagnifier(at: cursorPoint)
        }
    }

    private func drawAnnotationLayer(clippedTo rect: CGRect) {
        guard let image = annotationLayer?.image,
              let context = NSGraphicsContext.current
        else { return }
        context.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        context.cgContext.interpolationQuality = .high
        context.cgContext.draw(image, in: bounds)
        context.restoreGraphicsState()
    }

    private var shouldShowMagnifier: Bool {
        guard pointerInside else { return false }
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

    private func drawEraserRing() {
        let radius = style.eraserRadius
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
        let dim = NSColor.black.withAlphaComponent(CGFloat(Settings.shared.dimOpacity))
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
        if case .window = mode {
            drawCenteredHint(L10n.t("overlay.hint.window"))
        } else {
            drawCenteredHint(L10n.t("overlay.hint.area"))
        }
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
        let labelHeight: CGFloat = 32
        let offset: CGFloat = 22

        var frame = CGRect(
            x: point.x + offset,
            y: point.y - offset - side - labelHeight,
            width: side,
            height: side + labelHeight
        )
        if frame.maxX > bounds.maxX - 4 { frame.origin.x = point.x - offset - side }
        if frame.minY < 4 { frame.origin.y = point.y + offset }
        frame = frame.nudgedInside(bounds.insetBy(dx: 4, dy: 4))

        let imageRect = CGRect(
            x: frame.minX, y: frame.minY + labelHeight,
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
        let centerPixelY = ((bounds.height - point.y) * scale).rounded(.down)
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

        // Readout: coordinates and the sampled colour.
        let color = sampleColor(at: point) ?? .black
        let readout = NSAttributedString(
            string: "\(Int(point.x)), \(Int(bounds.height - point.y))\n\(color.hexString)  ·  \(color.rgbString)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ]
        )
        let swatch = CGRect(x: frame.minX + 6, y: frame.minY + 9, width: 12, height: 12)
        color.setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        NSBezierPath(roundedRect: swatch, xRadius: 3, yRadius: 3).stroke()
        readout.draw(at: CGPoint(x: swatch.maxX + 6, y: frame.minY + 4))

        NSColor.white.withAlphaComponent(0.2).setStroke()
        container.lineWidth = 1
        container.stroke()

        context.restoreGraphicsState()
    }
}

/// Text view used for the in-place text tool.
final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

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

    override func didChangeText() {
        super.didChangeText()
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let width = max(used.width + 12, 40)
        let height = max(used.height + 6, frame.height)
        // Grow downwards from the anchor point the user clicked.
        let top = frame.maxY
        frame = CGRect(x: frame.minX, y: top - height, width: width, height: height)
    }
}
