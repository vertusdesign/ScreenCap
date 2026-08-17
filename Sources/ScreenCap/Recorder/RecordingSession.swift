import AVFoundation
import CoreMedia

@available(macOS 15.0, *)
private struct RecordingSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
    let type: RecorderOutputType
}

@available(macOS 15.0, *)
actor RecordingSession {
    private let engine: RecorderCaptureEngine
    private let writer: RecorderWriterService
    private var state: RecorderState = .idle
    private var hasFailed = false
    private var healthTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var didReportDiskWarning = false
    private var didReportMicrophoneUnavailable = false
    private let sampleStream: AsyncStream<RecordingSample>
    private let sampleContinuation: AsyncStream<RecordingSample>.Continuation
    private var sampleConsumer: Task<Void, Never>?

    var onStateChange: (@Sendable (RecorderState) -> Void)?
    var onDiskSpaceLow: (@Sendable () -> Void)?
    var onMicrophoneUnavailable: (@Sendable () -> Void)?

    init(engine: RecorderCaptureEngine, writer: RecorderWriterService) {
        self.engine = engine
        self.writer = writer

        var createdContinuation: AsyncStream<RecordingSample>.Continuation?
        // Keep the oldest samples when the writer is briefly busy. The old
        // bufferingNewest policy silently discarded video samples, creating
        // multi-minute holes in the final timeline. If this bounded queue is
        // ever exhausted, fail the session explicitly instead of publishing a
        // file with an unexplained gap.
        let stream = AsyncStream<RecordingSample>(bufferingPolicy: .bufferingOldest(4096)) { continuation in
            createdContinuation = continuation
        }
        guard let continuation = createdContinuation else {
            fatalError("RecordingSession could not create its sample queue")
        }
        sampleStream = stream
        sampleContinuation = continuation
    }

    func connectCallbacks() {
        let continuation = sampleContinuation
        let stream = sampleStream
        sampleConsumer = Task { [weak self] in
            for await sample in stream {
                await self?.append(sample)
            }
        }
        engine.onSampleBuffer = { [weak self] sampleBuffer, outputType in
            guard self != nil else { return }
            switch continuation.yield(RecordingSample(buffer: sampleBuffer, type: outputType)) {
            case .enqueued(_):
                break
            case .dropped:
                Log.error("recorder sample queue overflow; stopping before a timeline gap is created")
                Task { await self?.fail(RecorderError.writerFailed("recording pipeline overloaded")) }
            case .terminated:
                break
            @unknown default:
                break
            }
        }
        engine.onFailure = { [weak self] error in
            Task { await self?.fail(error) }
        }
    }

    func start() async throws {
        guard state == .idle else { return }
        setState(.preparing)
        do {
            try await engine.start()
            recordingStartedAt = Date()
            setState(.recording)
            startHealthMonitoring()
            Task { [weak self] in
                // A broken or disconnected microphone must not keep the writer
                // from starting indefinitely. A silent output route can also
                // produce no system-audio sample, so after the same grace
                // period start with every track that is actually available.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.startWithAvailableTracksIfNeeded()
            }
        } catch {
            writer.cancel()
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    func stop() async throws -> URL? {
        guard state == .recording || state == .preparing else { return nil }
        setState(.stopping)
        healthTask?.cancel()
        healthTask = nil

        do {
            try await engine.stop()
        } catch {
            Log.debug("recorder stream stop failed: \(error.localizedDescription)")
        }

        sampleContinuation.finish()
        await sampleConsumer?.value
        sampleConsumer = nil

        logHealth(label: "final")
        let result = try await writer.finish()
        setState(.idle)
        return result
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        writer.setMicrophoneEnabled(enabled)
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        writer.setSystemAudioEnabled(enabled)
    }

    func cancel() async {
        guard state != .idle else { return }
        healthTask?.cancel()
        healthTask = nil
        do { try await engine.stop() } catch { }
        sampleContinuation.finish()
        await sampleConsumer?.value
        sampleConsumer = nil
        writer.cancel()
        setState(.idle)
    }

    private func append(_ sample: RecordingSample) async {
        let sampleBuffer = sample.buffer
        let type = sample.type
        guard !hasFailed, state == .recording || state == .preparing else { return }
        await writer.append(sampleBuffer, type: type)
        if let failure = writer.failure {
            fail(failure)
        }
    }

    private func fail(_ error: Error) {
        guard !hasFailed, state != .stopping, state != .idle else { return }
        hasFailed = true
        healthTask?.cancel()
        healthTask = nil
        Log.error("recorder session failed: \(error.localizedDescription)")
        sampleContinuation.finish()
        writer.cancel()
        Task { [weak self] in
            try? await self?.engine.stop()
        }
        setState(.failed(error.localizedDescription))
    }

    private func startWithAvailableTracksIfNeeded() async {
        guard state == .recording else { return }
        await writer.startWithAvailableTracksIfNeeded()
        let metrics = writer.metricsSnapshot()
        if writer.requestedMicrophone,
           metrics.receivedMicrophoneSamples == 0,
           !didReportMicrophoneUnavailable
        {
            didReportMicrophoneUnavailable = true
            let handler = onMicrophoneUnavailable
            DispatchQueue.main.async {
                handler?()
            }
        }
        if let failure = writer.failure {
            fail(failure)
        }
    }

    private func setState(_ newState: RecorderState) {
        state = newState
        let handler = onStateChange
        DispatchQueue.main.async {
            handler?(newState)
        }
    }

    func setDiskSpaceLowHandler(_ handler: @escaping @Sendable () -> Void) {
        onDiskSpaceLow = handler
    }

    func setMicrophoneUnavailableHandler(_ handler: @escaping @Sendable () -> Void) {
        onMicrophoneUnavailable = handler
    }

    private func startHealthMonitoring() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.reportHealth()
            }
        }
    }

    private func reportHealth() {
        guard state == .recording || state == .preparing else { return }
        guard let free = RecorderDiskSpace.freeBytes(at: writer.outputURL) else {
            logHealth(label: "periodic", freeBytes: nil)
            return
        }
        logHealth(label: "periodic", freeBytes: free)
        guard free < RecorderDiskSpace.minimumFreeBytes, !didReportDiskWarning else {
            return
        }
        didReportDiskWarning = true
        Log.error(
            "recorder stopping because free disk space is low: \(free) bytes"
        )
        let handler = onDiskSpaceLow
        DispatchQueue.main.async {
            handler?()
        }
    }

    private func logHealth(label: String, freeBytes: Int64? = nil) {
        let engineMetrics = engine.metricsSnapshot()
        let writerMetrics = writer.metricsSnapshot()
        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let videoEnd = writerMetrics.lastVideoEnd
        let systemSkew = audioVideoSkew(
            audioEnd: writerMetrics.lastSystemAudioEnd,
            videoEnd: videoEnd
        )
        let microphoneSkew = audioVideoSkew(
            audioEnd: writerMetrics.lastMicrophoneEnd,
            videoEnd: videoEnd
        )
        let free = freeBytes.map(String.init) ?? "unknown"
        Log.diagnostic(
            "recorder health label=\(label) elapsed=\(String(format: "%.1f", elapsed))s "
                + "freeBytes=\(free) "
                + "engineScreen=\(engineMetrics.screenSamples) "
                + "engineSystemAudio=\(engineMetrics.systemAudioSamples) "
                + "engineMicrophone=\(engineMetrics.microphoneSamples) "
                + "skippedFrames=\(engineMetrics.skippedNonCompleteFrames) "
                + "streamStops=\(engineMetrics.streamStopErrors) "
                + "writerScreen=\(writerMetrics.appendedScreenSamples)/\(writerMetrics.receivedScreenSamples) "
                + "writerSystemAudio=\(writerMetrics.appendedSystemAudioSamples)/\(writerMetrics.receivedSystemAudioSamples) "
                + "writerMicrophone=\(writerMetrics.appendedMicrophoneSamples)/\(writerMetrics.receivedMicrophoneSamples) "
                + "droppedVideo=\(writerMetrics.droppedVideoFrames) "
                + "systemSkew=\(formatSkew(systemSkew)) "
                + "microphoneSkew=\(formatSkew(microphoneSkew)) "
                + "micRMS=\(formatLevel(writerMetrics.microphoneInputRMS))/"
                + "\(formatLevel(writerMetrics.microphoneOutputRMS))"
        )

        for (name, skew) in [("systemAudio", systemSkew), ("microphone", microphoneSkew)] {
            if let skew, abs(skew) > 1.0 {
                Log.error(
                    "recorder long-sync drift: track=\(name) skew="
                        + String(format: "%.3f", skew)
                        + "s"
                )
            }
        }
    }

    private func audioVideoSkew(audioEnd: Double?, videoEnd: Double?) -> Double? {
        guard let audioEnd, let videoEnd else { return nil }
        return audioEnd - videoEnd
    }

    private func formatSkew(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.3f", value)
    }

    private func formatLevel(_ value: Float?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.3f", value)
    }
}
