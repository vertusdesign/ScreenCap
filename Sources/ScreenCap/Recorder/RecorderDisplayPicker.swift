import AppKit

@MainActor
private enum RecorderDisplayPickerCursor {
    static let recordingReticle: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            guard rect.width > 0, rect.height > 0 else { return false }

            // A compact recording reticle: four white corner marks and a
            // red center point. The dark under-stroke keeps it legible over
            // both the clear selected display and dimmed displays.
            let reticle = NSBezierPath()
            reticle.move(to: CGPoint(x: 4, y: 9))
            reticle.line(to: CGPoint(x: 4, y: 5))
            reticle.line(to: CGPoint(x: 9, y: 5))
            reticle.move(to: CGPoint(x: 15, y: 5))
            reticle.line(to: CGPoint(x: 20, y: 5))
            reticle.line(to: CGPoint(x: 20, y: 9))
            reticle.move(to: CGPoint(x: 4, y: 15))
            reticle.line(to: CGPoint(x: 4, y: 19))
            reticle.line(to: CGPoint(x: 9, y: 19))
            reticle.move(to: CGPoint(x: 15, y: 19))
            reticle.line(to: CGPoint(x: 20, y: 19))
            reticle.line(to: CGPoint(x: 20, y: 15))

            reticle.lineCapStyle = .round
            reticle.lineJoinStyle = .round
            NSColor.black.withAlphaComponent(0.8).setStroke()
            reticle.lineWidth = 4
            reticle.stroke()
            NSColor.white.setStroke()
            reticle.lineWidth = 2
            reticle.stroke()

            let centerShadow = NSBezierPath(ovalIn: CGRect(x: 9, y: 9, width: 6, height: 6))
            NSColor.black.withAlphaComponent(0.8).setFill()
            centerShadow.fill()

            let center = NSBezierPath(ovalIn: CGRect(x: 10, y: 10, width: 4, height: 4))
            NSColor.systemRed.setFill()
            center.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
}

/// A lightweight display chooser for recording. Unlike Apple's content-sharing
/// picker, this does not add a header or shift the user's desktop. Each display
/// is covered by a transparent overlay: the display under the pointer stays
/// clear and all other displays are dimmed.
@available(macOS 15.0, *)
@MainActor
final class RecorderDisplayPicker: NSObject {
    var onSelection: ((RecorderDisplay, RecordingCaptureOptions) -> Void)?
    var onCancel: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private struct Target {
        let display: RecorderDisplay
        let screenFrame: CGRect
    }

    private var targets: [Target] = []
    private var windows: [NSWindow] = []
    private var views: [RecorderDisplayPickerView] = []
    private var selectedDisplayID: CGDirectDisplayID?
    private var localEventMonitor: Any?
    private var selectionFooter: RecorderDisplayPickerFooterView?
    private var captureOptions = RecordingCaptureOptions.current
    private var isFinished = false

    func present() {
        captureOptions = .current
        targets = NSScreen.screens.compactMap { screen in
            guard let display = RecorderDisplay(
                screen: screen,
                logicalSize: Settings.shared.recordingAtLogicalSize
            ) else { return nil }
            return Target(display: display, screenFrame: screen.frame)
        }

        guard !targets.isEmpty else {
            onFailure?(RecorderError.noDisplay)
            return
        }

        let footer = RecorderDisplayPickerFooterView(
            options: captureOptions,
            onOptionsChanged: { [weak self] options in
                self?.captureOptions = options
            },
            onStart: { [weak self] in
                guard let self, let selectedDisplayID = self.selectedDisplayID else { return }
                self.start(displayID: selectedDisplayID)
            },
            onCancel: { [weak self] in self?.cancel() }
        )
        selectionFooter = footer

        for target in targets {
            let window = RecorderDisplayPickerWindow(
                contentRect: target.screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .fullScreenAuxiliary,
                .ignoresCycle
            ]
            window.acceptsMouseMovedEvents = true
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false

            let view = RecorderDisplayPickerView(
                display: target.display,
                screenFrame: target.screenFrame
            )
            view.onHover = { [weak self] in self?.select(displayID: $0) }
            view.onStart = { [weak self] in
                self?.start(displayID: target.display.displayID)
            }
            window.contentView = view
            windows.append(window)
            views.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .mouseMoved {
                self.select(displayAt: NSEvent.mouseLocation)
                self.updateCursor(at: NSEvent.mouseLocation)
                return event
            }
            return self.handleKey(event) ? nil : event
        }

        select(displayAt: NSEvent.mouseLocation)
    }

    func cancel() {
        guard !isFinished else { return }
        finish()
        onCancel?()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Escape
            cancel()
            return true
        case 36, 76: // Return / numpad Enter
            guard let selectedDisplayID else { return true }
            start(displayID: selectedDisplayID)
            return true
        default:
            return false
        }
    }

    private func select(displayAt point: CGPoint) {
        let target = targets.first { $0.screenFrame.contains(point) } ?? targets.first
        guard let target else { return }
        select(displayID: target.display.displayID)
    }

    private func select(displayID: CGDirectDisplayID) {
        if selectedDisplayID == displayID,
           let index = targets.firstIndex(where: { $0.display.displayID == displayID }),
           selectionFooter?.superview === views[index]
        {
            updateCursor(at: NSEvent.mouseLocation)
            return
        }
        selectedDisplayID = displayID

        // The footer is a single view that moves between display overlays.
        // Detach it from every old parent before attaching it to the new one;
        // otherwise the old view can remove it again while this loop is still
        // processing the newly selected display.
        views.forEach { $0.detachFooter() }
        for (index, target) in targets.enumerated() {
            let isSelected = target.display.displayID == displayID
            views[index].isSelected = isSelected
            if isSelected {
                selectionFooter?.update(display: target.display)
                if let selectionFooter {
                    views[index].attachFooter(selectionFooter)
                }
                windows[index].makeKeyAndOrderFront(nil)
                windows[index].makeFirstResponder(views[index])
                views[index].layoutSubtreeIfNeeded()
                selectionFooter?.focusStartButton(in: windows[index])
            } else {
                views[index].needsDisplay = true
            }
            views[index].needsDisplay = true
        }
        updateCursor(at: NSEvent.mouseLocation)
    }

    private func updateCursor(at point: CGPoint) {
        guard let selectedDisplayID,
              let index = targets.firstIndex(where: { $0.display.displayID == selectedDisplayID }),
              index < windows.count,
              index < views.count
        else {
            RecorderDisplayPickerCursor.recordingReticle.set()
            return
        }

        guard let footer = selectionFooter, footer.superview === views[index] else {
            RecorderDisplayPickerCursor.recordingReticle.set()
            return
        }

        let windowPoint = windows[index].convertPoint(fromScreen: point)
        let viewPoint = views[index].convert(windowPoint, from: nil)
        if footer.frame.contains(viewPoint) {
            NSCursor.arrow.set()
        } else {
            RecorderDisplayPickerCursor.recordingReticle.set()
        }
    }

    private func start(displayID: CGDirectDisplayID) {
        guard let display = targets.first(where: { $0.display.displayID == displayID })?.display else {
            return
        }
        let options = captureOptions
        finish()
        onSelection?(display, options)
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        selectionFooter?.removeFromSuperview()
        selectionFooter = nil
        for window in windows {
            window.contentView = nil
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        views.removeAll()
        targets.removeAll()
        selectedDisplayID = nil
        NSCursor.arrow.set()
    }
}

@available(macOS 15.0, *)
private final class RecorderDisplayPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@available(macOS 15.0, *)
private final class RecorderDisplayPickerView: NSView {
    let display: RecorderDisplay
    let screenFrame: CGRect
    var isSelected = false
    var onHover: ((CGDirectDisplayID) -> Void)?
    var onStart: (() -> Void)?

    private weak var footerView: RecorderDisplayPickerFooterView?
    private var interactionView: RecorderDisplayPickerInteractionView!

    init(display: RecorderDisplay, screenFrame: CGRect) {
        self.display = display
        self.screenFrame = screenFrame
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true
        autoresizingMask = [.width, .height]

        // The selected display is intentionally clear, but it still needs a
        // full-screen event target. This transparent view is kept underneath
        // the footer so clicks on the desktop start recording while controls
        // in the footer remain interactive.
        let displayID = display.displayID
        interactionView = RecorderDisplayPickerInteractionView(frame: bounds)
        interactionView.autoresizingMask = [.width, .height]
        interactionView.onHover = { [weak self] in
            self?.onHover?(displayID)
        }
        interactionView.onMouseDown = { [weak self] in
            guard let self else { return }
            if self.isSelected {
                self.onStart?()
            } else {
                self.onHover?(displayID)
            }
        }
        addSubview(interactionView)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func attachFooter(_ footer: RecorderDisplayPickerFooterView) {
        if footer.superview !== self {
            footer.removeFromSuperview()
            addSubview(footer)
        }
        footerView = footer
        needsLayout = true
    }

    func detachFooter() {
        if let footerView, footerView.superview === self {
            footerView.removeFromSuperview()
        }
        footerView = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        footerView?.frame = footerRect
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if !isSelected {
            NSColor.black.withAlphaComponent(0.58).setFill()
            bounds.fill()
            return
        }

        // Keep the selected display visually clear while ensuring the
        // borderless window has a real composited surface across its whole
        // area. A 0.1% alpha fill is imperceptible but prevents macOS from
        // passing clicks in clear regions to the window underneath.
        NSColor.black.withAlphaComponent(0.001).setFill()
        bounds.fill()

        let border = bounds.insetBy(dx: 2, dy: 2)
        NSColor.controlAccentColor.withAlphaComponent(0.72).setStroke()
        let outline = NSBezierPath(roundedRect: border, xRadius: 10, yRadius: 10)
        outline.lineWidth = 2
        outline.stroke()
    }

    private var footerRect: CGRect {
        let width = min(max(bounds.width - 48, 560), 640)
        return CGRect(
            x: (bounds.width - width) / 2,
            y: 28,
            width: width,
            height: 190
        ).integral
    }
}

@available(macOS 15.0, *)
private final class RecorderDisplayPickerInteractionView: NSView {
    var onHover: (() -> Void)?
    var onMouseDown: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Keep the clear portion of the overlay clickable. AppKit may
        // otherwise allow events through a transparent window region.
        self
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?()
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}

@available(macOS 15.0, *)
private final class RecorderDisplayPickerFooterView: NSVisualEffectView {
    private let titleField: NSTextField
    private let subtitleField: NSTextField
    private let hintField: NSTextField
    private let systemAudioButton: NSButton
    private let microphoneButton: NSButton
    private let noiseSuppressionButton: NSButton
    private let showMouseClicksButton: NSButton
    private let cancelButton: NSButton
    private let startButton: NSButton

    private var options: RecordingCaptureOptions
    private let onOptionsChanged: (RecordingCaptureOptions) -> Void
    private let onStart: () -> Void
    private let onCancel: () -> Void

    init(
        options: RecordingCaptureOptions,
        onOptionsChanged: @escaping (RecordingCaptureOptions) -> Void,
        onStart: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.options = options
        self.onOptionsChanged = onOptionsChanged
        self.onStart = onStart
        self.onCancel = onCancel

        titleField = NSTextField(labelWithString: L10n.t("recording.selection.title"))
        subtitleField = NSTextField(labelWithString: "")
        hintField = NSTextField(labelWithString: L10n.t("recording.selection.hint"))
        systemAudioButton = NSButton(
            checkboxWithTitle: L10n.t("recording.selection.systemAudio"),
            target: nil,
            action: nil
        )
        microphoneButton = NSButton(
            checkboxWithTitle: L10n.t("recording.selection.microphone"),
            target: nil,
            action: nil
        )
        noiseSuppressionButton = NSButton(
            checkboxWithTitle: L10n.t("recording.selection.noiseSuppression"),
            target: nil,
            action: nil
        )
        showMouseClicksButton = NSButton(
            checkboxWithTitle: L10n.t("recording.selection.showMouseClicks"),
            target: nil,
            action: nil
        )
        cancelButton = NSButton(title: L10n.t("recording.selection.cancel"), target: nil, action: nil)
        startButton = NSButton(title: L10n.t("recording.selection.start"), target: nil, action: nil)

        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.textColor = .labelColor
        subtitleField.font = .systemFont(ofSize: 12)
        subtitleField.textColor = .secondaryLabelColor
        hintField.font = .systemFont(ofSize: 11)
        hintField.textColor = .secondaryLabelColor
        hintField.lineBreakMode = .byTruncatingTail

        for button in [systemAudioButton, microphoneButton, noiseSuppressionButton, showMouseClicksButton] {
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        startButton.bezelStyle = .rounded
        startButton.controlSize = .regular
        startButton.bezelColor = .controlAccentColor
        startButton.contentTintColor = .white
        startButton.attributedTitle = NSAttributedString(
            string: startButton.title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            ]
        )
        startButton.focusRingType = .exterior
        startButton.keyEquivalent = "\r"
        startButton.keyEquivalentModifierMask = []
        startButton.setContentHuggingPriority(.required, for: .horizontal)

        systemAudioButton.target = self
        systemAudioButton.action = #selector(systemAudioChanged(_:))
        microphoneButton.target = self
        microphoneButton.action = #selector(microphoneChanged(_:))
        noiseSuppressionButton.target = self
        noiseSuppressionButton.action = #selector(noiseSuppressionChanged(_:))
        showMouseClicksButton.target = self
        showMouseClicksButton.action = #selector(showMouseClicksChanged(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        startButton.target = self
        startButton.action = #selector(startPressed(_:))

        let heading = NSStackView(views: [titleField, subtitleField, hintField])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        let optionsLabel = NSTextField(labelWithString: L10n.t("recording.selection.audio"))
        optionsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        optionsLabel.textColor = .secondaryLabelColor

        let optionsStack = NSStackView(
            views: [optionsLabel, systemAudioButton, microphoneButton, noiseSuppressionButton, showMouseClicksButton]
        )
        optionsStack.orientation = .horizontal
        optionsStack.alignment = .centerY
        optionsStack.spacing = 14

        let separator = NSBox()
        separator.boxType = .separator

        let actions = NSStackView(views: [cancelButton, startButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 148).isActive = true

        let content = NSStackView(views: [heading, optionsStack, separator, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 11
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 17),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -17),
            separator.widthAnchor.constraint(equalTo: content.widthAnchor),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor),
            startButton.trailingAnchor.constraint(equalTo: actions.trailingAnchor)
        ])

        updateOptionsControls()
    }

    required init?(coder: NSCoder) { nil }

    func focusStartButton(in window: NSWindow) {
        window.makeFirstResponder(startButton)
    }

    func update(display: RecorderDisplay) {
        subtitleField.stringValue = L10n.t(
            "recording.selection.display",
            String(display.width),
            String(display.height)
        )
    }

    private func updateOptionsControls() {
        systemAudioButton.state = options.systemAudio ? .on : .off
        microphoneButton.state = options.microphone ? .on : .off
        noiseSuppressionButton.state = options.noiseSuppression ? .on : .off
        // Keep this control available even when the microphone is currently
        // off. The setting belongs to the microphone DSP pipeline and is
        // safely ignored by the writer when no microphone track is captured;
        // disabling it here makes the one-off recording choices needlessly
        // dependent on the order in which the user toggles options.
        noiseSuppressionButton.isEnabled = true
        showMouseClicksButton.state = options.showMouseClicks ? .on : .off
    }

    @objc private func systemAudioChanged(_ sender: NSButton) {
        options.systemAudio = sender.state == .on
        onOptionsChanged(options)
    }

    @objc private func microphoneChanged(_ sender: NSButton) {
        options.microphone = sender.state == .on
        updateOptionsControls()
        onOptionsChanged(options)
    }

    @objc private func noiseSuppressionChanged(_ sender: NSButton) {
        options.noiseSuppression = sender.state == .on
        onOptionsChanged(options)
    }

    @objc private func showMouseClicksChanged(_ sender: NSButton) {
        options.showMouseClicks = sender.state == .on
        onOptionsChanged(options)
    }

    @objc private func cancelPressed(_ sender: NSButton) {
        onCancel()
    }

    @objc private func startPressed(_ sender: NSButton) {
        onStart()
    }
}
