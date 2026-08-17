import AVFoundation
import AVFAudio
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@available(macOS 15.0, *)
@MainActor
final class RecorderController {
    static let shared = RecorderController()

    private(set) var state: RecorderState = .idle {
        didSet {
            NotificationCenter.default.post(name: .recorderStateChanged, object: nil)
        }
    }

    private(set) var microphoneEnabled = true {
        didSet {
            NotificationCenter.default.post(name: .recorderMicrophoneChanged, object: nil)
        }
    }

    private(set) var systemAudioEnabled = true {
        didSet {
            NotificationCenter.default.post(name: .recorderSystemAudioChanged, object: nil)
        }
    }

    private var session: RecordingSession?
    private var displayPicker: RecorderDisplayPicker?
    private var startRequestID = UUID()
    private var stopRequested = false
    private var terminationCompletions: [() -> Void] = []

    private init() {}

    var menuTitle: String {
        switch state {
        case .recording: return L10n.t("recording.stop")
        case .preparing: return L10n.t("recording.preparing")
        case .stopping: return L10n.t("recording.stopping")
        default: return L10n.t("recording.start")
        }
    }

    var microphoneMenuTitle: String {
        microphoneEnabled ? L10n.t("recording.microphoneOff") : L10n.t("recording.microphoneOn")
    }

    var microphoneSymbolName: String {
        microphoneEnabled ? "mic.fill" : "mic.slash.fill"
    }

    var systemAudioMenuTitle: String {
        systemAudioEnabled
            ? L10n.t("recording.systemAudioOff")
            : L10n.t("recording.systemAudioOn")
    }

    var systemAudioSymbolName: String {
        systemAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
    }

    var isActive: Bool {
        switch state {
        case .preparing, .recording, .stopping:
            return true
        default:
            return false
        }
    }

    func stopForTermination(completion: @escaping () -> Void) {
        guard isActive else {
            completion()
            return
        }
        terminationCompletions.append(completion)
        if case .stopping = state { return }
        // During the asynchronous preparation window there may be no session
        // yet (especially while the display picker is open). Cancel that
        // preparation so termination is not left waiting forever.
        guard session != nil else {
            cancelPendingStart()
            return
        }
        stop()
    }

    func toggle(startMode: RecorderStartMode = .displayUnderPointer) {
        switch state {
        case .idle, .failed:
            start(mode: startMode)
        case .preparing, .recording:
            stop()
        case .stopping:
            break
        }
    }

    func toggleMicrophone() {
        guard state == .preparing || state == .recording else { return }
        microphoneEnabled.toggle()
        let enabled = microphoneEnabled
        guard let session else { return }
        Task { await session.setMicrophoneEnabled(enabled) }
    }

    func toggleSystemAudio() {
        guard state == .preparing || state == .recording else { return }
        systemAudioEnabled.toggle()
        let enabled = systemAudioEnabled
        guard let session else { return }
        Task { await session.setSystemAudioEnabled(enabled) }
    }

    private func start(mode: RecorderStartMode) {
        guard state == .idle || isFailed else { return }
        state = .preparing
        let savedOptions = RecordingCaptureOptions.current
        microphoneEnabled = savedOptions.microphone
        systemAudioEnabled = savedOptions.systemAudio
        stopRequested = false

        let requestID = UUID()
        startRequestID = requestID

        if case .displayPicker = mode {
            presentDisplayPicker(requestID: requestID)
            return
        }

        guard let display = currentDisplay() else {
            state = .failed(L10n.t("error.noDisplays"))
            Feedback.flash(message: L10n.t("error.noDisplays"))
            completeTerminationRequests()
            return
        }

        beginSession(
            display: display,
            requestID: requestID
        )
    }

    private func presentDisplayPicker(requestID: UUID) {
        let picker = RecorderDisplayPicker()
        picker.onSelection = { [weak self] display, options in
            DispatchQueue.main.async {
                self?.handleDisplaySelection(
                    display,
                    options: options,
                    requestID: requestID
                )
            }
        }
        picker.onCancel = { [weak self] in
            DispatchQueue.main.async {
                self?.handleDisplayPickerCancel(requestID: requestID)
            }
        }
        picker.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                Task { await self?.failStart(error, requestID: requestID) }
            }
        }
        displayPicker = picker
        picker.present()
    }

    private func handleDisplaySelection(
        _ display: RecorderDisplay,
        options: RecordingCaptureOptions,
        requestID: UUID
    ) {
        guard startRequestID == requestID, state == .preparing else { return }
        displayPicker = nil
        microphoneEnabled = options.microphone
        systemAudioEnabled = options.systemAudio
        beginSession(
            display: display,
            options: options,
            requestID: requestID
        )
    }

    private func handleDisplayPickerCancel(requestID: UUID) {
        guard startRequestID == requestID, state == .preparing else { return }
        displayPicker = nil
        state = .idle
        completeTerminationRequests()
    }

    private func beginSession(
        display: RecorderDisplay,
        options: RecordingCaptureOptions = .current,
        requestID: UUID
    ) {
        let file: RecorderFile
        do {
            guard let chosenFile = try recordingFile(for: display) else {
                state = .idle
                completeTerminationRequests()
                return
            }
            file = chosenFile
        } catch {
            state = .failed(error.localizedDescription)
            Feedback.flash(message: L10n.t("recording.failed"), subtitle: error.localizedDescription)
            completeTerminationRequests()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            guard self.startRequestID == requestID else { return }
            let captureSystemAudio = options.systemAudio
            let showMouseClicks = options.showMouseClicks
            var microphone = options.microphone
                ? await self.microphoneAvailability()
                : false
            guard self.startRequestID == requestID else { return }
            do {
                if microphone,
                   let route = RecorderCaptureEngine.currentMicrophoneRoute(),
                   route.isBluetooth
                {
                    DispatchQueue.main.async {
                        Feedback.flash(message: L10n.t("recording.bluetoothHFP"))
                    }
                    Log.diagnostic(
                        "recorder microphone route bluetooth name=\(route.name)"
                    )
                }

                let engine: RecorderCaptureEngine
                do {
                    engine = try await RecorderCaptureEngine.make(
                        display: display,
                        captureSystemAudio: captureSystemAudio,
                        captureMicrophone: microphone,
                        showMouseClicks: showMouseClicks
                    )
                } catch {
                    guard microphone else { throw error }
                    // Permission can be granted while the physical device is
                    // disappearing or still being rebuilt by Core Audio. A
                    // screen + system-audio recording is still useful, so
                    // retry once without the optional microphone stream.
                    Log.error(
                        "recorder microphone stream unavailable; retrying without microphone: "
                            + error.localizedDescription
                    )
                    microphone = false
                    DispatchQueue.main.async {
                        Feedback.flash(message: L10n.t("recording.noMicrophone"))
                    }
                    engine = try await RecorderCaptureEngine.make(
                        display: display,
                        captureSystemAudio: captureSystemAudio,
                        captureMicrophone: false,
                        showMouseClicks: showMouseClicks
                    )
                }
                let writer = try RecorderWriterService(
                    file: file,
                    captureSystemAudio: captureSystemAudio,
                    captureMicrophone: microphone,
                    noiseSuppression: options.noiseSuppression,
                    videoCodecPreference: Settings.shared.recordingVideoCodec
                )
                let session = RecordingSession(
                    engine: engine,
                    writer: writer
                )
                await session.connectCallbacks()
                guard self.startRequestID == requestID else {
                    await session.cancel()
                    return
                }
                await self.install(session: session)
                await session.setMicrophoneEnabled(self.microphoneEnabled)
                await session.setSystemAudioEnabled(self.systemAudioEnabled)
                try await session.start()

                guard self.startRequestID == requestID else {
                    await session.cancel()
                    return
                }

                if self.stopRequested || self.hasTerminationRequests() {
                    self.stopRequested = false
                    self.stopActiveSession()
                }

                if options.microphone && !microphone {
                    DispatchQueue.main.async {
                        Feedback.flash(message: L10n.t("recording.noMicrophone"))
                    }
                }
            } catch {
                await self.failStart(error, requestID: requestID)
            }
        }
    }

    private func stop() {
        guard let session else {
            cancelPendingStart()
            return
        }
        if state == .preparing {
            // `session.start()` is still awaiting SCStream.startCapture().
            // Defer the stop until that transition completes; stopping the
            // writer concurrently can produce an empty file and a second
            // toggle can then accidentally start another session.
            stopRequested = true
            return
        }
        stopActiveSession(session)
    }

    /// Stops a session that has completed `start()`. This is separate from
    /// `stop()` because the controller's main-queue state callback can still
    /// say `.preparing` for one turn after the actor has become recordable.
    private func stopActiveSession(_ session: RecordingSession? = nil) {
        guard let session = session ?? self.session else {
            cancelPendingStart()
            return
        }
        stopRequested = false
        state = .stopping

        Task { [weak self] in
            do {
                let url = try await session.stop()
                await self?.finish(url: url)
            } catch {
                await self?.failStop(error)
            }
        }
    }

    private func cancelPendingStart() {
        startRequestID = UUID()
        stopRequested = false
        let picker = displayPicker
        displayPicker = nil
        picker?.cancel()
        session = nil
        state = .idle
        completeTerminationRequests()
    }

    private func currentDisplay() -> RecorderDisplay? {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return nil }
        return RecorderDisplay(
            screen: screen,
            logicalSize: Settings.shared.recordingAtLogicalSize
        )
    }

    /// Creates the destination before capture starts. This preserves the
    /// recorder's crash-safe streaming path and avoids moving a large movie
    /// after the user has already finished recording.
    private func recordingFile(for display: RecorderDisplay) throws -> RecorderFile? {
        let suggested = try RecorderFileNaming.makeFile(
            width: display.width,
            height: display.height
        )
        guard Settings.shared.recordingAskWhereToSave else {
            try RecorderDiskSpace.ensureAvailable(at: suggested.url)
            return suggested
        }

        let panel = NSSavePanel()
        panel.title = L10n.t("recording.chooseDestination")
        panel.prompt = L10n.t("recording.chooseDestinationPrompt")
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.movie]
        panel.directoryURL = Settings.shared.recordingDirectory
        panel.nameFieldStringValue = suggested.url.lastPathComponent

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        let normalizedURL: URL
        if selectedURL.pathExtension.lowercased() == "mov" {
            normalizedURL = selectedURL
        } else {
            normalizedURL = selectedURL.deletingPathExtension().appendingPathExtension("mov")
        }
        let file = try RecorderFileNaming.makeFile(
            url: normalizedURL,
            width: display.width,
            height: display.height
        )
        try RecorderDiskSpace.ensureAvailable(at: file.url)
        return file
    }

    @MainActor
    private func microphoneAvailability() async -> Bool {
        let permission = AVAudioApplication.shared.recordPermission
        Log.debug("microphone permission state: \(String(describing: permission))")
        switch permission {
        case .granted:
            // The capture engine snapshots the default device ID when the
            // stream is created. Do not reject a valid grant just because
            // AVCaptureDevice cannot enumerate it momentarily.
            return true
        case .denied:
            DispatchQueue.main.async {
                Feedback.flash(message: L10n.t("recording.microphoneDenied"))
            }
            return false
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            Log.debug("microphone permission request result: \(granted)")
            guard granted else {
                DispatchQueue.main.async {
                    Feedback.flash(message: L10n.t("recording.microphoneDenied"))
                }
                return false
            }
            return true
        @unknown default:
            return false
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func install(session: RecordingSession) async {
        self.session = session
        await session.setStateHandler { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = newState
                if case .failed(let reason) = newState {
                    self.session = nil
                    Feedback.flash(message: L10n.t("recording.failed"), subtitle: reason)
                }
            }
        }
        await session.setDiskSpaceLowHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.session != nil, self.isActive else { return }
                Feedback.flash(message: L10n.t("recording.diskSpaceWarning"))
                self.stopActiveSession()
            }
        }
        await session.setMicrophoneUnavailableHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.microphoneEnabled = false
                Feedback.flash(message: L10n.t("recording.noMicrophone"))
            }
        }
    }

    private func failStart(_ error: Error, requestID: UUID? = nil) async {
        await MainActor.run {
            if let requestID, self.startRequestID != requestID { return }
            Log.error("recorder start failed: \(error.localizedDescription)")
            self.stopRequested = false
            self.displayPicker = nil
            self.session = nil
            self.state = .failed(error.localizedDescription)
            self.completeTerminationRequests()
            if case RecorderError.permissionDenied = error {
                CaptureController.shared.requestScreenRecordingPermission()
            } else {
                Feedback.flash(message: L10n.t("recording.failed"), subtitle: error.localizedDescription)
            }
        }
    }

    private func finish(url: URL?) async {
        await MainActor.run {
            self.stopRequested = false
            self.session = nil
            self.state = .idle
            guard let url else {
                Feedback.flash(message: L10n.t("recording.failed"))
                self.completeTerminationRequests()
                return
            }
            Feedback.shutter()
            Feedback.flash(
                message: L10n.t("recording.saved"),
                subtitle: url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
            )
            self.performAfterCaptureAction(for: url)
            self.completeTerminationRequests()
        }
    }

    private func performAfterCaptureAction(for url: URL) {
        guard let action = Settings.shared.recordingAfterCaptureAction else {
            promptForAfterCaptureAction(for: url)
            return
        }
        switch action {
        case RecordingAfterCaptureAction.nothing:
            break
        case RecordingAfterCaptureAction.showInFolder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case RecordingAfterCaptureAction.openInPlayer:
            DispatchQueue.main.async { PlayerWindowController.shared.show(url: url) }
        default:
            guard let bundleIdentifier = RecordingAfterCaptureAction.bundleIdentifier(from: action),
                  let applicationURL = NSWorkspace.shared
                    .urlsForApplications(toOpen: .quickTimeMovie)
                    .first(where: { Bundle(url: $0)?.bundleIdentifier == bundleIdentifier })
            else {
                NSWorkspace.shared.open(url)
                return
            }

            if bundleIdentifier == "org.videolan.vlc" {
                openWithVLC(url, applicationURL: applicationURL)
                return
            }

            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        }
    }

    private struct AfterCaptureChoice {
        let value: String
        let title: String
    }

    /// The first successful recording is the least surprising moment to ask:
    /// the user has a real file to act on, and no preference was silently
    /// imposed. Choosing an action applies it to this recording and persists
    /// it for subsequent recordings; closing or choosing Later leaves the
    /// setting unconfigured and asks again next time.
    private func promptForAfterCaptureAction(for url: URL) {
        let choices = afterCaptureChoices()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        for choice in choices {
            popup.addItem(withTitle: choice.title)
            popup.lastItem?.representedObject = choice.value
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.t("recording.afterCapture.choose.title")
        alert.informativeText = L10n.t("recording.afterCapture.choose.message")
        alert.accessoryView = popup
        alert.addButton(withTitle: L10n.t("recording.afterCapture.choose.save"))
        alert.addButton(withTitle: L10n.t("common.later"))

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let selected = popup.selectedItem?.representedObject as? String,
              selected != RecordingAfterCaptureAction.notConfigured
        else { return }

        Settings.shared.recordingAfterCaptureAction = selected
        performAfterCaptureAction(for: url)
    }

    private func afterCaptureChoices() -> [AfterCaptureChoice] {
        var choices = [
            AfterCaptureChoice(
                value: RecordingAfterCaptureAction.openInPlayer,
                title: L10n.t("prefs.recording.afterCapture.openInPlayer")
            ),
            AfterCaptureChoice(
                value: RecordingAfterCaptureAction.showInFolder,
                title: L10n.t("prefs.recording.afterCapture.showInFolder")
            ),
            AfterCaptureChoice(
                value: RecordingAfterCaptureAction.nothing,
                title: L10n.t("prefs.recording.afterCapture.nothing")
            )
        ]

        let applications = NSWorkspace.shared
            .urlsForApplications(toOpen: .quickTimeMovie)
            .compactMap { url -> (bundleIdentifier: String, name: String)? in
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      bundleIdentifier != AppInfo.bundleIdentifier
                else { return nil }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return (bundleIdentifier, name)
            }
            .reduce(into: [(bundleIdentifier: String, name: String)]()) { result, application in
                guard !result.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) else {
                    return
                }
                result.append(application)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        choices.append(contentsOf: applications.map {
            AfterCaptureChoice(
                value: RecordingAfterCaptureAction.application($0.bundleIdentifier),
                title: L10n.t("prefs.recording.afterCapture.openWith", $0.name)
            )
        })
        return choices
    }

    /// VLC 3 on macOS has two separate quirks: starting with
    /// `--play-and-pause` can create only its transport bar, and an Open
    /// Documents event does not carry a pause flag. Start VLC normally, send
    /// the movie to its existing playlist, then use VLC's AppleScript command
    /// to toggle the just-opened item to pause after its video output is ready.
    private func openWithVLC(_ url: URL, applicationURL: URL) {
        let controller = self
        let openDocument: @MainActor @Sendable () -> Void = {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: { _, error in
                    if let error {
                        Log.error("VLC could not open recording: \(error.localizedDescription)")
                    }
                    Task { @MainActor in
                        controller.scheduleVLCPlaybackPause(for: url)
                    }
                }
            )
        }

        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "org.videolan.vlc" && !$0.isTerminated
        }

        if isRunning {
            // This appends the movie to VLC's current playlist without making
            // a second process or a second VLC window.
            openDocument()
        } else {
            // First let VLC create its normal main/video window. Passing the
            // movie as launch arguments is what produced the toolbar-only
            // cold-start window reported by users.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    Log.error("VLC could not launch: \(error.localizedDescription)")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    Task { @MainActor in
                        openDocument()
                    }
                }
            }
        }
    }

    private func scheduleVLCPlaybackPause(for url: URL, attempt: Int = 0) {
        guard attempt < 12 else {
            Log.error("VLC did not expose the new recording for pausing")
            return
        }

        // Apple Events can block while VLC is creating its video output, so
        // never run this on ScreenCap's main/UI thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.pauseVLCPlaybackIfCurrentItemMatches(url)
            guard case .retry = result else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self?.scheduleVLCPlaybackPause(for: url, attempt: attempt + 1)
            }
        }
    }

    private enum VLCPauseResult {
        case pausedOrAlreadyPaused
        case retry
        case failed
    }

    private nonisolated static func pauseVLCPlaybackIfCurrentItemMatches(_ url: URL) -> VLCPauseResult {
        let path = appleScriptString(url.path)
        let source = """
        tell application id "org.videolan.vlc"
            try
                if (path of current item as text) is \(path) then
                    if playing then play
                    return 1
                end if
            on error
                return 0
            end try
            return 0
        end tell
        """

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            Log.error("VLC pause command could not be created")
            return .failed
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.error("VLC pause command failed: \(error)")
            return .failed
        }

        if result.int32Value == 1 {
            return .pausedOrAlreadyPaused
        }
        return .retry
    }

    private nonisolated static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func failStop(_ error: Error) async {
        await MainActor.run {
            self.stopRequested = false
            Log.error("recorder stop failed: \(error.localizedDescription)")
            self.session = nil
            self.state = .failed(error.localizedDescription)
            Feedback.flash(message: L10n.t("recording.failed"), subtitle: error.localizedDescription)
            self.completeTerminationRequests()
        }
    }

    private func completeTerminationRequests() {
        let completions = terminationCompletions
        terminationCompletions.removeAll(keepingCapacity: true)
        completions.forEach { $0() }
    }

    private func hasTerminationRequests() -> Bool {
        !terminationCompletions.isEmpty
    }
}

@available(macOS 15.0, *)
private extension RecordingSession {
    func setStateHandler(_ handler: @escaping @Sendable (RecorderState) -> Void) {
        onStateChange = handler
    }
}

extension Notification.Name {
    static let recorderStateChanged = Notification.Name("ScreenCap.recorderStateChanged")
    static let recorderMicrophoneChanged = Notification.Name("ScreenCap.recorderMicrophoneChanged")
    static let recorderSystemAudioChanged = Notification.Name("ScreenCap.recorderSystemAudioChanged")
}
