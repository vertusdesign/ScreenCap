import AppKit

/// Drives a capture from hotkey press to finished image.
final class CaptureController {
    static let shared = CaptureController()

    private var overlay: OverlayController?
    private var isCapturing = false
    private var isEditingOpenedImage = false
    private var openedImageURL: URL?
    private var previousApp: NSRunningApplication?

    /// Remembered for the "repeat last area" shortcut.
    private(set) var lastGlobalRect: CGRect?

    private init() {}

    var hasLastArea: Bool { lastGlobalRect != nil }

    /// Re-issues macOS's native Screen Recording request from the status menu
    /// or at launch; a fallback alert appears only if access remains missing.
    @MainActor
    func requestScreenRecordingPermission(showFallback: Bool = true) {
        requestPermission(showFallback: showFallback)
    }

    // MARK: - Entry points

    func perform(_ action: HotkeyAction) {
        switch action {
        case .captureArea:
            begin(mode: .area)

        case .repeatLastArea:
            guard let rect = lastGlobalRect, isStillOnScreen(rect) else {
                Feedback.flash(message: L10n.t("toast.noLastArea"), subtitle: L10n.t("toast.noLastArea.detail"))
                begin(mode: .area)
                return
            }
            begin(mode: .preselected(globalRect: rect))

        case .captureWindow:
            begin(mode: .window)

        case .captureFullScreen:
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            guard let screen else { return }
            begin(mode: .preselected(globalRect: screen.frame))

        case .toggleRecording:
            if #available(macOS 15.0, *) {
                RecorderController.shared.toggle(startMode: .displayUnderPointer)
            } else {
                Feedback.flash(message: L10n.t("recording.unavailable"))
            }

        case .chooseRecordingDisplay:
            if #available(macOS 15.0, *) {
                RecorderController.shared.toggle(startMode: .displayPicker)
            } else {
                Feedback.flash(message: L10n.t("recording.unavailable"))
            }

        case .toggleRecordingMicrophone:
            if #available(macOS 15.0, *) {
                RecorderController.shared.toggleMicrophone()
            } else {
                Feedback.flash(message: L10n.t("recording.unavailable"))
            }

        case .toggleRecordingSystemAudio:
            if #available(macOS 15.0, *) {
                RecorderController.shared.toggleSystemAudio()
            } else {
                Feedback.flash(message: L10n.t("recording.unavailable"))
            }
        }
    }

    /// Opens an image received from Finder in the same annotation overlay as a
    /// fresh screenshot. The source stays at 100% and can be panned when it is
    /// larger than the display; the editor's reserved canvas also supports
    /// expanding the crop with a solid fill.
    func openImage(_ url: URL) {
        guard !isCapturing else { return }
        guard url.isFileURL else { return }

        Log.debug("open image \(url.path)")
        isCapturing = true
        isEditingOpenedImage = true
        openedImageURL = url.standardizedFileURL
        previousApp = NSWorkspace.shared.frontmostApplication

        Task { @MainActor in
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try ImageFileLoader.loadCGImage(from: url)
                }.value
                presentOpenedImage(image)
            } catch {
                isCapturing = false
                isEditingOpenedImage = false
                openedImageURL = nil
                Feedback.flash(message: L10n.t("error.openImage"), subtitle: error.localizedDescription)
                previousApp = nil
            }
        }
    }

    // MARK: - Session

    private func begin(mode: CaptureMode) {
        Log.debug("begin capture")
        guard !isCapturing else { return }

        // No preflight gate here on purpose. `CGPreflightScreenCaptureAccess`
        // reports false whenever the app's signature has changed since the grant,
        // even though capture still works — gating on it produced a permission
        // dialog before every single capture. Just try, and only explain if the
        // attempt actually comes back denied.
        isCapturing = true
        isEditingOpenedImage = false
        previousApp = NSWorkspace.shared.frontmostApplication

        Task { @MainActor in
            do {
                let snapshots = try await ScreenCapture.snapshotAllDisplays()
                var targets: [WindowTarget] = []
                if case .window = mode {
                    targets = (try? await ScreenCapture.onScreenWindows()) ?? []
                }
                presentOverlay(snapshots: snapshots, mode: mode, targets: targets)
            } catch {
                isCapturing = false
                handle(error)
            }
        }
    }

    @MainActor
    private func presentOpenedImage(_ image: CGImage) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            isCapturing = false
            isEditingOpenedImage = false
            openedImageURL = nil
            previousApp = nil
            return
        }

        let visible = screen.visibleFrame.insetBy(dx: 48, dy: 72)
        let imageSize = CGSize(width: image.width, height: image.height)
        // Opened images use a literal 100% canvas: one source pixel is one
        // editor point. Large images are navigated with the Move tool instead
        // of being silently reduced to fit the display.
        let pointSize = imageSize
        let origin = OpenedImageEditorGeometry.initialImageOrigin(
            imageSize: pointSize,
            viewport: visible
        )
        let frame = CGRect(
            x: origin.x,
            y: origin.y,
            width: pointSize.width,
            height: pointSize.height
        )
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID(truncating: $0) } ?? 0
        let snapshot = DisplaySnapshot(
            displayID: displayID,
            screen: screen,
            cocoaFrame: frame,
            image: image
        )
        presentOverlay(
            snapshots: [snapshot],
            mode: .openedImage,
            targets: []
        )
    }

    @MainActor
    private func presentOverlay(
        snapshots: [DisplaySnapshot],
        mode: CaptureMode,
        targets: [WindowTarget]
    ) {
        let controller = OverlayController()
        controller.onCancel = { [weak self] in
            self?.endSession(restoreFocus: true)
        }
        controller.onFinish = { [weak self] image, action, globalRect in
            self?.complete(image: image, action: action, globalRect: globalRect)
        }
        overlay = controller
        controller.present(snapshots: snapshots, mode: mode, windowTargets: targets)
    }

    @MainActor
    private func complete(image: CapturedImage, action: OutputAction, globalRect: CGRect) {
        if !isEditingOpenedImage {
            lastGlobalRect = globalRect
        }
        let sourceURL = isEditingOpenedImage ? openedImageURL : nil

        // Take the overlay down first: the save and print panels are ordinary
        // modal windows and behave badly underneath a shielding-level window.
        let needsPanel = action == .saveAs || action == .print
            || (action == .save && Settings.shared.askWhereToSave)
        overlay?.dismiss()
        overlay = nil
        isEditingOpenedImage = false

        switch action {
        case .copy:
            ImageOutput.copyToClipboard(image)
            Feedback.shutter()
            Feedback.flash(message: L10n.t("toast.copied"))

        case .save, .saveAs:
            let savedURL: URL?
            if let sourceURL {
                savedURL = ImageOutput.save(
                    image,
                    forcePanel: action == .saveAs,
                    preferredDirectory: sourceURL.deletingLastPathComponent(),
                    suggestedName: ImageOutput.openedImageFilename(for: sourceURL)
                )
            } else {
                savedURL = ImageOutput.save(image, forcePanel: action == .saveAs)
            }
            if let url = savedURL {
                if Settings.shared.copyOnSave { ImageOutput.copyToClipboard(image) }
                Feedback.shutter()
                Feedback.flash(
                    message: L10n.t("toast.saved"),
                    subtitle: url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
                )
            }

        case .print:
            ImageOutput.print(image)
        }

        endSession(restoreFocus: !needsPanel)
    }

    private func endSession(restoreFocus: Bool) {
        Log.debug("endSession restoreFocus=\(restoreFocus)")
        overlay?.dismiss()
        overlay = nil
        isCapturing = false
        isEditingOpenedImage = false
        openedImageURL = nil
        // The tooltip is a singleton window outliving any one overlay — if the
        // session ends (e.g. a shortcut fires) while the pointer is still
        // sitting over a button, its scheduled/visible tooltip would otherwise
        // hang around with nothing left to dismiss it.
        TooltipWindow.shared.hide()

        if restoreFocus, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    // MARK: - Errors

    private func isStillOnScreen(_ rect: CGRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(rect) }
    }

    @MainActor
    private func handle(_ error: Error) {
        if case ScreenCaptureError.permissionDenied = error {
            requestPermission(showFallback: true)
            return
        }
        // A toast rather than a modal: capture is triggered by a hotkey that is
        // easy to hit twice, and stacked alerts are worse than the failure.
        Feedback.flash(message: L10n.t("error.captureTitle"), subtitle: error.localizedDescription)
    }

    private var permissionRequestInFlight = false
    private var permissionFallbackShowing = false

    /// Called when a capture actually came back denied, or when the user chooses
    /// the warning item in the status menu.
    @MainActor
    private func requestPermission(showFallback: Bool) {
        // First give macOS a chance to show its own request. The fallback alert
        // is presented only after that call and a live ScreenCaptureKit check
        // have completed, so it can never cover the native prompt.
        guard !permissionRequestInFlight else { return }
        permissionRequestInFlight = true

        DispatchQueue.global(qos: .userInitiated).async {
            _ = ScreenCapture.requestPermission { granted in
                DispatchQueue.main.async {
                    CaptureController.shared.permissionRequestInFlight = false
                    guard showFallback, !granted, !ScreenCapture.hasPermission else { return }
                    CaptureController.shared.showPermissionFallback()
                }
            }
        }
    }

    @MainActor
    private func showPermissionFallback() {
        guard !permissionFallbackShowing else { return }
        permissionFallbackShowing = true
        defer { permissionFallbackShowing = false }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.t("permission.title")
        alert.informativeText = L10n.t("permission.body", AppInfo.name)
        alert.addButton(withTitle: L10n.t("permission.open"))
        alert.addButton(withTitle: L10n.t("common.later"))

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCapture.openSettings()
        }
    }
}
