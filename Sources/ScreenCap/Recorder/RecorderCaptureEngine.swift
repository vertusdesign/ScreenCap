import AppKit
import AVFoundation
import CoreMedia
import CoreAudio
import ScreenCaptureKit

@available(macOS 15.0, *)
final class RecorderCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(
        label: "com.vertusdesign.ScreenCap.recorder.video",
        qos: .userInitiated
    )
    private let audioQueue = DispatchQueue(
        label: "com.vertusdesign.ScreenCap.recorder.audio",
        qos: .userInitiated
    )
    private let microphoneQueue = DispatchQueue(
        label: "com.vertusdesign.ScreenCap.recorder.microphone",
        qos: .userInitiated
    )
    private let inputRouteQueue = DispatchQueue(
        label: "com.vertusdesign.ScreenCap.recorder.input-route",
        qos: .utility
    )

    private var skippedNonCompleteFrames = 0
    private var screenSamples = 0
    private var hasEmittedScreenFrame = false
    private var leadingBlankScreenFrames = 0
    private var systemAudioSamples = 0
    private var microphoneSamples = 0
    private var streamStopErrors = 0
    private let metricsLock = NSLock()
    private var streamConfiguration: SCStreamConfiguration?
    private var inputRouteListener: AudioObjectPropertyListenerBlock?
    private var inputRouteUpdateTask: Task<Void, Never>?
    private var isCapturing = false
    private var observedInputDeviceID: String?
    private var deviceNotificationTokens: [NSObjectProtocol] = []

    private var inputRoutePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    var onSampleBuffer: ((CMSampleBuffer, RecorderOutputType) -> Void)?
    var onFailure: ((Error) -> Void)?

    private override init() {
        super.init()
    }

    static func make(
        display: RecorderDisplay,
        captureSystemAudio: Bool,
        captureMicrophone: Bool,
        showMouseClicks: Bool
    ) async throws -> RecorderCaptureEngine {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            if !ScreenCapture.hasPermission { throw RecorderError.permissionDenied }
            throw RecorderError.captureFailed(error.localizedDescription)
        }

        guard let selectedDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            throw RecorderError.noDisplay
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedApplications = content.applications.filter { application in
            guard let ownBundleID else { return false }
            return application.bundleIdentifier == ownBundleID
        }
        let filter = SCContentFilter(
            display: selectedDisplay,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        return try make(
            filter: filter,
            width: display.width,
            height: display.height,
            captureSystemAudio: captureSystemAudio,
            captureMicrophone: captureMicrophone,
            showMouseClicks: showMouseClicks
        )
    }

    static func make(
        filter: SCContentFilter,
        width: Int,
        height: Int,
        captureSystemAudio: Bool,
        captureMicrophone: Bool,
        showMouseClicks: Bool
    ) throws -> RecorderCaptureEngine {
        guard width >= 2, height >= 2 else {
            throw RecorderError.noDisplay
        }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        // Feed the hardware encoder the same 4:2:0 video representation it
        // writes. BGRA forces an additional conversion at Retina dimensions
        // and has caused VideoToolbox to reject otherwise valid frames on
        // long captures (AVFoundation -11800 / OSStatus -16122).
        // ScreenCaptureKit's native click indicator is composited only for
        // BGRA streams. Keep the lower-cost 4:2:0 path for normal recordings,
        // and switch formats only when the user explicitly requests clicks.
        configuration.pixelFormat = showMouseClicks
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = .best
        // Keep the recorder's output deterministic across display capabilities.
        // HDR recording is not supported by the ScreenCaptureKit recording path.
        configuration.captureDynamicRange = SCCaptureDynamicRange(rawValue: 0)!
        configuration.scalesToFit = false
        configuration.showsCursor = true
        configuration.showMouseClicks = showMouseClicks
        configuration.capturesAudio = captureSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = captureMicrophone
        // Leave the device unspecified so ScreenCaptureKit resolves the
        // system-default input through its native path. Teams, Zoom and similar
        // apps can select their own input independently; their per-app choice
        // does not alter ScreenCap's microphone stream. This also preserves
        // compatibility with devices whose AVCaptureDevice identifier cannot
        // be passed back to ScreenCaptureKit (some Bluetooth/radio routes).
        configuration.microphoneCaptureDeviceID = nil

        Log.diagnostic(
            "recorder configuration os=\(ProcessInfo.processInfo.operatingSystemVersionString) "
                + "arch=\(Self.machineArchitecture) display=\(width)x\(height) "
                + "fps=60 queueDepth=5 pixelFormat=\(showMouseClicks ? "BGRA" : "420v") dynamicRange=SDR "
                + "systemAudio=\(captureSystemAudio) microphone=\(captureMicrophone) "
                + "showMouseClicks=\(showMouseClicks) "
                + "sampleRate=48000 channels=2"
        )

        let engine = RecorderCaptureEngine()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: engine)
        engine.stream = stream
        engine.streamConfiguration = configuration

        do {
            try stream.addStreamOutput(engine, type: .screen, sampleHandlerQueue: engine.videoQueue)
            if captureSystemAudio {
                try stream.addStreamOutput(engine, type: .audio, sampleHandlerQueue: engine.audioQueue)
            }
            if captureMicrophone {
                try stream.addStreamOutput(
                    engine,
                    type: .microphone,
                    sampleHandlerQueue: engine.microphoneQueue
                )
            }
        } catch {
            throw RecorderError.captureFailed(error.localizedDescription)
        }

        if captureMicrophone {
            engine.startInputRouteMonitoring()
        }

        return engine
    }

    static func pixelSize(for filter: SCContentFilter) -> (width: Int, height: Int)? {
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let width = Int((info.contentRect.width * scale).rounded())
        let height = Int((info.contentRect.height * scale).rounded())
        guard width >= 2, height >= 2 else { return nil }
        // H.264/HEVC require even dimensions.
        return (
            width.isMultiple(of: 2) ? width : width - 1,
            height.isMultiple(of: 2) ? height : height - 1
        )
    }

    func start() async throws {
        guard let stream else { throw RecorderError.captureFailed("stream is unavailable") }
        do {
            try await stream.startCapture()
            isCapturing = true
        } catch {
            Log.error("recorder stream start failed: \(error.localizedDescription)")
            throw RecorderError.captureFailed(error.localizedDescription)
        }
    }

    func stop() async throws {
        guard let stream else { return }
        isCapturing = false
        inputRouteUpdateTask?.cancel()
        inputRouteUpdateTask = nil
        do {
            try await stream.stopCapture()
        } catch {
            Log.error("recorder stream stop failed: \(error.localizedDescription)")
            throw RecorderError.captureFailed(error.localizedDescription)
        }
    }

    func metricsSnapshot() -> RecorderEngineMetrics {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return RecorderEngineMetrics(
            screenSamples: screenSamples,
            systemAudioSamples: systemAudioSamples,
            microphoneSamples: microphoneSamples,
            skippedNonCompleteFrames: skippedNonCompleteFrames,
            streamStopErrors: streamStopErrors
        )
    }

    deinit {
        inputRouteUpdateTask?.cancel()
        deviceNotificationTokens.forEach(NotificationCenter.default.removeObserver)
        if let inputRouteListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &inputRoutePropertyAddress,
                inputRouteQueue,
                inputRouteListener
            )
        }
    }

    private func startInputRouteMonitoring() {
        guard inputRouteListener == nil else { return }
        observedInputDeviceID = currentInputDeviceID()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.inputRouteQueue.async { [weak self] in
                self?.scheduleInputRouteUpdate(force: false)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputRoutePropertyAddress,
            inputRouteQueue,
            listener
        )
        guard status == noErr else {
            Log.error(
                "recorder could not monitor default microphone route: status="
                    + String(status)
            )
            return
        }
        inputRouteListener = listener

        let center = NotificationCenter.default
        deviceNotificationTokens = [
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.inputRouteQueue.async { [weak self] in
                    self?.scheduleInputRouteUpdate(force: true)
                }
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.inputRouteQueue.async { [weak self] in
                    self?.scheduleInputRouteUpdate(force: true)
                }
            }
        ]
    }

    private func scheduleInputRouteUpdate(force: Bool) {
        inputRouteUpdateTask?.cancel()
        inputRouteUpdateTask = Task { [weak self] in
            // Bluetooth route changes can emit several HAL notifications while
            // macOS tears down and recreates the input device. Wait until the
            // new default has settled before updating ScreenCaptureKit.
            let retryDelays: [UInt64] = [
                250_000_000,
                750_000_000,
                1_500_000_000,
                2_500_000_000
            ]
            for delay in retryDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                if await self?.updateInputRoute(force: force) == true {
                    return
                }
            }
        }
    }

    @discardableResult
    private func updateInputRoute(force: Bool) async -> Bool {
        let deviceID = currentInputDeviceID()
        guard force || deviceID != observedInputDeviceID else { return true }
        observedInputDeviceID = deviceID
        guard isCapturing,
              let stream,
              let streamConfiguration
        else { return true }

        // Passing the current AVCaptureDevice uniqueID makes the behavior
        // explicit instead of leaving the stream pinned to the device it
        // resolved during creation. nil is intentional when the default route
        // is temporarily unavailable: ScreenCaptureKit then falls back to the
        // system default once the route is restored.
        streamConfiguration.microphoneCaptureDeviceID = deviceID
        do {
            try await stream.updateConfiguration(streamConfiguration)
            Log.debug(
                "recorder microphone route updated: "
                    + (deviceID ?? "system default")
            )
            return true
        } catch {
            // A route can disappear between the HAL notification and the
            // update. The retry loop above keeps recording and reapplies the
            // new device after macOS finishes rebuilding the Bluetooth route.
            Log.error(
                "recorder microphone route update failed: "
                    + error.localizedDescription
            )
            return false
        }
    }

    private func currentInputDeviceID() -> String? {
        AVCaptureDevice.default(for: .audio)?.uniqueID
    }

    private static var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .screen:
            // ScreenCaptureKit also emits bookkeeping buffers when the
            // display is idle, blank, suspended, or stopping. They do not
            // contain a new image and must never be handed to AVAssetWriter.
            guard isUsableScreenSample(sampleBuffer) else { return }
            incrementMetric(.screen)
            onSampleBuffer?(sampleBuffer, .screen)
        case .audio:
            incrementMetric(.systemAudio)
            onSampleBuffer?(sampleBuffer, .systemAudio)
        case .microphone:
            incrementMetric(.microphone)
            onSampleBuffer?(sampleBuffer, .microphone)
        @unknown default:
            break
        }
    }

    private func isUsableScreenSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let statusValue = attachments.first?[SCStreamFrameInfo.status] as? NSNumber,
        let status = SCFrameStatus(rawValue: statusValue.intValue)
        else {
            incrementMetric(.skipped)
            return false
        }

        switch status {
        case .complete:
            // Some macOS/display combinations mark the first surface buffer
            // as complete even though it is still an all-black initialization
            // frame. Do not let that buffer become the first encoded frame of
            // a quick recording. The bounded fallback preserves intentional
            // recordings of a genuinely black screen.
            if !hasEmittedScreenFrame,
               isLeadingBlankScreenSample(sampleBuffer),
               leadingBlankScreenFrames < 12
            {
                leadingBlankScreenFrames += 1
                incrementMetric(.skipped)
                return false
            }
            hasEmittedScreenFrame = true
            return true
        case .started, .idle, .blank, .suspended, .stopped:
            // The started status is a stream lifecycle marker, not a
            // guarantee that the first surface image is ready. On some
            // macOS/display combinations it is encoded as a black frame.
            // Wait for the first complete frame so quick-start recordings do
            // not begin with a visible black prefix.
            incrementMetric(.skipped)
            return false
        @unknown default:
            incrementMetric(.skipped)
            return false
        }
    }

    private func isLeadingBlankScreenSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPixelFormatType(imageBuffer)
                  == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0) != nil
        else {
            return false
        }

        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(imageBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(imageBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0)
        let baseAddress = CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0)!
            .assumingMemoryBound(to: UInt8.self)

        // Video-range black is Y=16. A small margin tolerates encoder and
        // color-conversion rounding while still distinguishing a real frame.
        var maximumLuma = 16
        for y in stride(from: 0, to: height, by: max(1, height / 24)) {
            for x in stride(from: 0, to: width, by: max(1, width / 24)) {
                maximumLuma = max(maximumLuma, Int(baseAddress[y * bytesPerRow + x]))
                if maximumLuma > 20 { return false }
            }
        }
        return true
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        metricsLock.lock()
        streamStopErrors += 1
        metricsLock.unlock()
        Log.error("recorder stream stopped with error: \(error.localizedDescription)")
        onFailure?(error)
    }

    private enum Metric {
        case screen
        case systemAudio
        case microphone
        case skipped
    }

    private func incrementMetric(_ metric: Metric) {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        switch metric {
        case .screen:
            screenSamples += 1
        case .systemAudio:
            systemAudioSamples += 1
        case .microphone:
            microphoneSamples += 1
        case .skipped:
            skippedNonCompleteFrames += 1
        }
    }

    static func currentMicrophoneRoute() -> (name: String, isBluetooth: Bool)? {
        guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
        let transport = UInt32(bitPattern: device.transportType)
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
        return (device.localizedName, isBluetooth)
    }
}
