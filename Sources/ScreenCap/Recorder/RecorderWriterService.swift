import AVFoundation
import CoreMedia
import VideoToolbox

@available(macOS 15.0, *)
final class RecorderWriterService: @unchecked Sendable {
    private let file: RecorderFile
    private let captureSystemAudio: Bool
    private let captureMicrophone: Bool
    private let writer: AVAssetWriter
    private let videoCodec: AVVideoCodecType
    private let usesHardwareVideoEncoder: Bool

    private var inputs: [RecorderOutputType: AVAssetWriterInput] = [:]
    private var pending: [RecorderOutputType: [CMSampleBuffer]] = [:]
    private var baseTime: CMTime?
    private var hasStarted = false
    private var hasFinished = false
    private var microphoneEnabled = true
    private var systemAudioEnabled = true
    private let microphoneProcessor: MicrophoneAudioProcessor
    private var silentSampleFailureLogged = Set<RecorderOutputType>()

    private(set) var droppedVideoFrames = 0
    private(set) var failure: Error?
    private var receivedSamples: [RecorderOutputType: Int] = [:]
    private var appendedSamples: [RecorderOutputType: Int] = [:]
    private var lastEndTimes: [RecorderOutputType: Double] = [:]
    private let backpressureTimeout: TimeInterval = 5.0

    var outputURL: URL { file.url }
    var requestedMicrophone: Bool { captureMicrophone }

    init(
        file: RecorderFile,
        captureSystemAudio: Bool,
        captureMicrophone: Bool,
        noiseSuppression: Bool,
        videoCodecPreference: RecordingVideoCodec
    ) throws {
        self.file = file
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.microphoneProcessor = MicrophoneAudioProcessor(
            noiseSuppression: noiseSuppression && captureMicrophone
        )
        let codecChoice = Self.videoCodec(
            for: file.width,
            height: file.height,
            preference: videoCodecPreference
        )
        self.videoCodec = codecChoice.codec
        self.usesHardwareVideoEncoder = codecChoice.hardware
        Log.diagnostic(
            "writer configuration dimensions=\(file.width)x\(file.height) "
                + "codec=\(codecChoice.codec.rawValue) hardwareEncoder=\(codecChoice.hardware) "
                + "systemAudio=\(captureSystemAudio) microphone=\(captureMicrophone) "
                + "noiseSuppression=\(noiseSuppression)"
        )
        do {
            writer = try AVAssetWriter(outputURL: file.url, fileType: .mov)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }
        try RecorderRecovery.markInProgress(for: file.url)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 1_000)
    }

    func append(_ sampleBuffer: CMSampleBuffer, type: RecorderOutputType) async {
        guard !hasFinished else { return }
        guard type != .systemAudio || captureSystemAudio else { return }
        guard type != .microphone || captureMicrophone else { return }
        receivedSamples[type, default: 0] += 1
        // Muting is local to ScreenCap's microphone track. We intentionally do
        // not touch AVAudioApplication's input mute state, which could affect a
        // live Teams/Zoom/Meet call using the same physical device.
        // Keep muted audio tracks continuous. Dropping the buffers creates a
        // hole that AVAssetWriter may compact when it encodes AAC, causing the
        // next enabled fragment to play immediately after the previous one
        // instead of at its original video time.
        let bufferToAppend: CMSampleBuffer
        let shouldMute = (type == .microphone && !microphoneEnabled)
            || (type == .systemAudio && !systemAudioEnabled)
        if shouldMute {
            guard let silentBuffer = makeSilentSampleBuffer(from: sampleBuffer) else {
                if silentSampleFailureLogged.insert(type).inserted {
                    Log.error("recorder could not create a silent \(type) sample")
                }
                return
            }
            bufferToAppend = silentBuffer
        } else if type == .microphone {
            bufferToAppend = microphoneProcessor.process(sampleBuffer)
        } else {
            bufferToAppend = sampleBuffer
        }

        if !hasStarted {
            // Keep startup bounded if a device never emits its first buffer.
            // The session will fall back to video + system audio after the
            // startup grace period.
            let limit = type == .screen ? 600 : 256
            if pending[type, default: []].count < limit {
                pending[type, default: []].append(bufferToAppend)
            } else {
                let reason = "recorder startup queue overflow for \(type)"
                failure = RecorderError.writerFailed(reason)
                Log.error(reason)
                return
            }
            if canStart {
                await startIfPossible()
            }
            return
        }

        await appendRetimed(bufferToAppend, type: type)
    }

    /// If a microphone is unavailable, finish with video + system audio rather
    /// than discarding an otherwise valid recording.
    func finish(
        onProcessingStage: (@Sendable (RecorderProcessingStage) async -> Void)? = nil
    ) async throws -> RecorderFinalizationResult? {
        guard !hasFinished else { return nil }
        microphoneProcessor.finish()
        hasFinished = true

        if let failure {
            writer.cancelWriting()
            throw failure
        }

        if !hasStarted {
            let screenCount = pending[.screen]?.count ?? 0
            let systemAudioCount = pending[.systemAudio]?.count ?? 0
            let microphoneCount = pending[.microphone]?.count ?? 0
            guard screenCount > 0 else {
                Log.error(
                    "recorder writer stopped before first video sample " +
                    "(screen=\(screenCount), systemAudio=\(systemAudioCount), microphone=\(microphoneCount))"
                )
                writer.cancelWriting()
                return nil
            }
            // A silent output route may not emit a system-audio sample at all.
            // Finish a valid video (and any microphone track already available)
            // instead of turning that case into a zero-byte recording. When
            // system audio is present, it is still added normally.
            await startIfPossible(
                forceWithoutMicrophone: false,
                forceWithoutSystemAudio: true
            )
        }

        guard hasStarted else {
            Log.error("recorder writer could not start during finish")
            writer.cancelWriting()
            return nil
        }

        inputs.values.forEach { $0.markAsFinished() }
        var writerWarning: String?
        do {
            try await withCheckedThrowingContinuation { continuation in
                writer.finishWriting {
                    if self.writer.status == .completed {
                        continuation.resume(returning: ())
                    } else {
                        let reason = self.writer.error?.localizedDescription ?? "unknown writer error"
                        continuation.resume(throwing: RecorderError.writerFailed(reason))
                    }
                }
            }
        } catch {
            // A fragmented MOV may still be playable after AVAssetWriter
            // reports a finish error. Keep searching candidates below before
            // classifying the recording as a total failure.
            writerWarning = error.localizedDescription
            let reason = writerWarning ?? "unknown error"
            Log.error("recorder writer finish failed; checking playable fallback: \(reason)")
        }
        let composite = await RecorderPostProcessor.addCompositeAudioTrack(
            to: file.url,
            onProcessingStage: onProcessingStage
        )
        await onProcessingStage?(.checking)

        var selected: (url: URL, validation: RecorderPostProcessor.ValidationResult)?
        var playableFallback: (url: URL, validation: RecorderPostProcessor.ValidationResult)?
        for candidate in RecorderRecovery.relatedRecordingURLs(for: file.url)
            where FileManager.default.fileExists(atPath: candidate.path)
        {
            let validation = await RecorderPostProcessor.validateFinalRecording(at: candidate)
            if validation.isValid {
                selected = (candidate, validation)
                break
            }
            if playableFallback == nil,
               await RecorderPostProcessor.isPlayableRecording(at: candidate)
            {
                playableFallback = (candidate, validation)
            }
        }

        let chosen: (url: URL, validation: RecorderPostProcessor.ValidationResult)
        if let selected {
            chosen = selected
        } else if let playableFallback {
            chosen = playableFallback
        } else {
            RecorderRecovery.clearMarker(for: file.url)
            throw RecorderError.writerFailed(
                "final recording failed container validation or no playable file was found"
            )
        }

        // A failed atomic replace can leave a completed temporary composite
        // movie beside a valid source. Do not let that implementation detail
        // become a duplicate recording in the Player library; preserve it only
        // when it is the candidate we are actually returning.
        let temporaryCompositeURL = file.url
            .deletingPathExtension()
            .appendingPathExtension("composite.mov")
        if temporaryCompositeURL.standardizedFileURL != chosen.url.standardizedFileURL {
            try? FileManager.default.removeItem(at: temporaryCompositeURL)
        }

        var warnings: [String] = []
        if let writerWarning {
            warnings.append("writer finish: \(writerWarning)")
        }
        if let compositeWarning = composite.warning {
            warnings.append("composite audio: \(compositeWarning)")
        }
        if !chosen.validation.isValid {
            warnings.append("validation: \(chosen.validation.summary)")
        }
        let usedRecoveredFile = chosen.url.standardizedFileURL != file.url.standardizedFileURL
        if usedRecoveredFile {
            warnings.append("recording path changed during finalization")
            Log.error(
                "recorder finalization selected fallback file "
                    + "\(chosen.url.lastPathComponent) instead of \(file.url.lastPathComponent)"
            )
        }
        RecorderRecovery.clearMarker(for: file.url)
        RecorderRecovery.clearMarker(for: chosen.url)
        return RecorderFinalizationResult(
            url: chosen.url,
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "; "),
            usedRecoveredFile: usedRecoveredFile
        )
    }

    func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        writer.cancelWriting()
    }

    func startWithAvailableTracksIfNeeded() async {
        guard !hasStarted else { return }
        await startIfPossible(
            forceWithoutMicrophone: false,
            forceWithoutSystemAudio: true
        )
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        microphoneEnabled = enabled
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        systemAudioEnabled = enabled
    }

    func metricsSnapshot() -> RecorderWriterMetrics {
        RecorderWriterMetrics(
            receivedScreenSamples: receivedSamples[.screen, default: 0],
            receivedSystemAudioSamples: receivedSamples[.systemAudio, default: 0],
            receivedMicrophoneSamples: receivedSamples[.microphone, default: 0],
            appendedScreenSamples: appendedSamples[.screen, default: 0],
            appendedSystemAudioSamples: appendedSamples[.systemAudio, default: 0],
            appendedMicrophoneSamples: appendedSamples[.microphone, default: 0],
            droppedVideoFrames: droppedVideoFrames,
            lastVideoEnd: lastEndTimes[.screen],
            lastSystemAudioEnd: lastEndTimes[.systemAudio],
            lastMicrophoneEnd: lastEndTimes[.microphone],
            microphoneInputRMS: microphoneProcessor.lastInputRMS,
            microphoneOutputRMS: microphoneProcessor.lastOutputRMS
        )
    }

    private var canStart: Bool {
        guard pending[.screen]?.isEmpty == false else { return false }
        if captureSystemAudio, pending[.systemAudio]?.isEmpty != false {
            return false
        }
        return !captureMicrophone || pending[.microphone]?.isEmpty == false
    }

    private func startIfPossible(
        forceWithoutMicrophone: Bool = false,
        forceWithoutSystemAudio: Bool = false
    ) async {
        guard !hasStarted, failure == nil else { return }
        let useMicrophone = captureMicrophone && !forceWithoutMicrophone

        guard let firstScreen = pending[.screen]?.first else { return }
        let firstSystemAudio = pending[.systemAudio]?.first
        guard !captureSystemAudio || forceWithoutSystemAudio || firstSystemAudio != nil else {
            return
        }

        do {
            let videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: videoSettings,
                sourceFormatHint: firstScreen.formatDescription
            )
            videoInput.expectsMediaDataInRealTime = true
            inputs[.screen] = videoInput
            writer.add(videoInput)

            if captureSystemAudio, let firstSystemAudio {
                let systemAudioInput = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: audioSettings(bitRate: 256_000),
                    sourceFormatHint: firstSystemAudio.formatDescription
                )
                systemAudioInput.expectsMediaDataInRealTime = true
                inputs[.systemAudio] = systemAudioInput
                writer.add(systemAudioInput)
            }

            if useMicrophone, let firstMicrophone = pending[.microphone]?.first {
                let microphoneInput = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: audioSettings(bitRate: 192_000),
                    sourceFormatHint: firstMicrophone.formatDescription
                )
                microphoneInput.expectsMediaDataInRealTime = true
                inputs[.microphone] = microphoneInput
                writer.add(microphoneInput)
            }

            guard writer.startWriting() else {
                throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "could not start writer")
            }

            let firstTimes = inputs.keys.compactMap { pending[$0]?.first?.presentationTimeStamp }
            guard let firstTime = firstTimes.min(by: { CMTimeCompare($0, $1) < 0 }) else {
                throw RecorderError.writerFailed("no presentation timestamp")
            }
            baseTime = firstTime
            writer.startSession(atSourceTime: .zero)
            hasStarted = true

            let buffers = pending
            pending.removeAll(keepingCapacity: true)
            for (type, samples) in buffers {
                guard inputs[type] != nil else { continue }
                for sample in samples {
                    await appendRetimed(sample, type: type)
                }
            }
        } catch {
            failure = error
            writer.cancelWriting()
            pending.removeAll(keepingCapacity: false)
            if let recorderError = error as? RecorderError {
                Log.debug("recorder writer failed: \(recorderError.localizedDescription)")
            } else {
                Log.debug("recorder writer failed: \(error.localizedDescription)")
            }
            Log.error("recorder writer start failed: \(error.localizedDescription)")
        }
    }

    private var videoSettings: [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: file.width,
            AVVideoHeightKey: file.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                // ScreenCap writes a real-time screen stream. B-frame
                // reordering produces negative composition offsets in the
                // MOV ctts table. Apple players understand the resulting
                // cslg workaround, but VLC and several other players do not.
                // A no-reordering stream keeps PTS/DTS portable and stable.
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        if usesHardwareVideoEncoder {
            settings[AVVideoEncoderSpecificationKey] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue
            ] as CFDictionary
        }
        return settings
    }

    private static func videoCodec(
        for width: Int,
        height: Int,
        preference: RecordingVideoCodec
    ) -> (codec: AVVideoCodecType, hardware: Bool) {
        // H.264 is the conservative real-time path for ScreenCaptureKit's
        // BGRA frames. Some macOS/driver combinations report a hardware HEVC
        // encoder but later reject an otherwise valid screen sample at runtime
        // (AVFoundation -11800 / OSStatus -16122). H.264 remains hardware
        // accelerated here and is broadly playable.
        switch preference {
        case .h264:
            return (
                .h264,
                hardwareEncoderAvailable(
                    codecType: kCMVideoCodecType_H264,
                    width: width,
                    height: height
                )
            )
        case .hevc:
            if hardwareEncoderAvailable(
                codecType: kCMVideoCodecType_HEVC,
                width: width,
                height: height
            ) {
                return (.hevc, true)
            }
            // A requested HEVC profile must not turn a valid recording into a
            // runtime failure on an Intel/T2 or older encoder. Fall back to the
            // broadly supported H.264 path when hardware HEVC is unavailable.
            Log.debug("requested HEVC encoder unavailable; falling back to H.264")
            return (
                .h264,
                hardwareEncoderAvailable(
                    codecType: kCMVideoCodecType_H264,
                    width: width,
                    height: height
                )
            )
        case .automatic:
            if hardwareEncoderAvailable(
                codecType: kCMVideoCodecType_H264,
                width: width,
                height: height
            ) {
                return (.h264, true)
            }
            if hardwareEncoderAvailable(
                codecType: kCMVideoCodecType_HEVC,
                width: width,
                height: height
            ) {
                return (.hevc, true)
            }
        }
        // On an unusual machine without either hardware encoder, AVFoundation
        // may use software H.264 encoding; the performance tier will be
        // measured before release.
        return (.h264, false)
    }

    private static func hardwareEncoderAvailable(
        codecType: CMVideoCodecType,
        width: Int,
        height: Int
    ) -> Bool {
        var encoderID: CFString?
        var properties: CFDictionary?
        let specification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue
        ] as CFDictionary
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: Int32(width),
            height: Int32(height),
            codecType: codecType,
            encoderSpecification: specification,
            encoderIDOut: &encoderID,
            supportedPropertiesOut: &properties
        )
        return status == noErr
    }

    private func audioSettings(bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: bitRate
        ]
    }

    private func describe(_ error: Error?) -> String {
        guard let error else { return "none" }
        let nsError = error as NSError
        var result = "\(nsError.domain)(\(nsError.code))"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            result += " underlying=\(underlying.domain)(\(underlying.code))"
        }
        return result
    }

    private func appendRetimed(_ sampleBuffer: CMSampleBuffer, type: RecorderOutputType) async {
        guard failure == nil else { return }
        guard let input = inputs[type] else {
            return
        }
        guard let baseTime else { return }

        let presentationTime = sampleBuffer.presentationTimeStamp
        guard presentationTime.isValid else {
            let reason = "recorder received a video sample without a valid presentation timestamp"
            if type == .screen { droppedVideoFrames += 1 }
            failure = RecorderError.writerFailed(reason)
            Log.error(reason)
            return
        }
        guard CMTimeCompare(presentationTime, baseTime) >= 0 else {
            let reason = "recorder received a sample before the recording timeline origin"
            if type == .screen { droppedVideoFrames += 1 }
            failure = RecorderError.writerFailed(reason)
            Log.error(reason)
            return
        }

        guard let adjusted = copy(sampleBuffer, subtracting: baseTime) else {
            if type == .screen { droppedVideoFrames += 1 }
            failure = RecorderError.writerFailed(
                "recorder could not retime a \(type) sample"
            )
            Log.error("recorder could not retime a \(type) sample")
            return
        }

        let deadline = Date().addingTimeInterval(backpressureTimeout)
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed || writer.status == .cancelled {
                failure = RecorderError.writerFailed(
                    writer.error?.localizedDescription ?? "writer stopped while accepting media"
                )
                return
            }
            if Date() >= deadline {
                let reason = "recorder writer backpressure timeout for \(type)"
                failure = RecorderError.writerFailed(reason)
                Log.error(reason)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        guard input.append(adjusted) else {
            let reason = writer.error?.localizedDescription ?? "could not append media sample"
            if writer.status == .failed {
                failure = RecorderError.writerFailed(reason)
            } else {
                failure = RecorderError.writerFailed(
                    "recorder input append failed for \(type): \(reason)"
                )
            }
            Log.error(
                "recorder input append failed: type=\(type) writerStatus=\(writer.status.rawValue) " +
                "reason=\(reason) details=\(describe(writer.error))"
            )
            return
        }
        appendedSamples[type, default: 0] += 1
        if let end = sampleEndTime(sampleBuffer) {
            lastEndTimes[type] = end
        }
    }

    private func sampleEndTime(_ sampleBuffer: CMSampleBuffer) -> Double? {
        let start = sampleBuffer.presentationTimeStamp.seconds
        let duration = CMSampleBufferGetDuration(sampleBuffer).seconds
        guard start.isFinite else { return nil }
        return start + (duration.isFinite && duration > 0 ? duration : 0)
    }

    private func copy(_ sampleBuffer: CMSampleBuffer, subtracting offset: CMTime) -> CMSampleBuffer? {
        var timingCount = 0
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard timingStatus == noErr, timingCount > 0 else { return nil }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingCount
        )
        let fillStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: timingCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        }
        guard fillStatus == noErr else { return nil }

        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = CMTimeSubtract(
                    timing[index].presentationTimeStamp,
                    offset
                )
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeSubtract(
                    timing[index].decodeTimeStamp,
                    offset
                )
            }
        }

        var adjusted: CMSampleBuffer?
        let status = timing.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: timingCount,
                sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &adjusted
            )
        }
        return status == noErr ? adjusted : nil
    }

    /// Makes a deep, silent copy of an audio sample while preserving its
    /// format, sample count, duration and timestamps. The source sample's
    /// block buffer is never modified because ScreenCaptureKit may still own
    /// and reuse it after this callback returns.
    private func makeSilentSampleBuffer(from sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let sourceData = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return makeSilentAudioBufferListSampleBuffer(from: sampleBuffer)
        }

        let dataLength = CMBlockBufferGetDataLength(sourceData)
        var silentData: CMBlockBuffer?
        let copyStatus = CMBlockBufferCreateContiguous(
            allocator: kCFAllocatorDefault,
            sourceBuffer: sourceData,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: kCMBlockBufferAlwaysCopyDataFlag,
            blockBufferOut: &silentData
        )
        guard copyStatus == kCMBlockBufferNoErr, let silentData else {
            return silentSampleFailure("data-copy status=\(copyStatus) length=\(dataLength)")
        }

        let fillStatus = CMBlockBufferFillDataBytes(
            with: 0,
            blockBuffer: silentData,
            offsetIntoDestination: 0,
            dataLength: dataLength
        )
        guard fillStatus == kCMBlockBufferNoErr else {
            return silentSampleFailure("data-fill status=\(fillStatus) length=\(dataLength)")
        }

        var timingCount = 0
        let timingStatus = CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard timingStatus == noErr, timingCount > 0 else {
            return silentSampleFailure("timing-query status=\(timingStatus) count=\(timingCount)")
        }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingCount
        )
        let fillTimingStatus = timing.withUnsafeMutableBufferPointer({ buffer in
            CMSampleBufferGetSampleTimingInfoArray(
                sampleBuffer,
                entryCount: timingCount,
                arrayToFill: buffer.baseAddress,
                entriesNeededOut: nil
            )
        })
        guard fillTimingStatus == noErr else {
            return silentSampleFailure("timing-fill status=\(fillTimingStatus)")
        }

        var silentSample: CMSampleBuffer?
        let status = timing.withUnsafeBufferPointer { timingBuffer in
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: silentData,
                formatDescription: CMSampleBufferGetFormatDescription(sampleBuffer),
                sampleCount: CMSampleBufferGetNumSamples(sampleBuffer),
                sampleTimingEntryCount: timingCount,
                sampleTimingArray: timingBuffer.baseAddress,
                // ScreenCaptureKit delivers PCM here. Its sample buffer does
                // not expose per-sample sizes, so let Core Media derive them
                // from the format and the contiguous block buffer.
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &silentSample
            )
        }
        guard status == noErr, let silentSample else {
            return silentSampleFailure(
                "sample-create status=\(status) samples=\(CMSampleBufferGetNumSamples(sampleBuffer)) "
                    + "data=\(dataLength)"
            )
        }
        return silentSample
    }

    /// System audio can arrive as a non-interleaved AudioBufferList without a
    /// top-level data buffer. Build a new sample with the same audio layout,
    /// but with separately allocated zeroed buffers, rather than mutating the
    /// capture sample's memory.
    private func makeSilentAudioBufferListSampleBuffer(
        from sampleBuffer: CMSampleBuffer
    ) -> CMSampleBuffer? {
        var bufferListSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, bufferListSize > 0 else {
            return silentSampleFailure("audio-list-size status=\(sizeStatus) size=\(bufferListSize)")
        }

        let sourceRaw = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { sourceRaw.deallocate() }
        let sourceList = sourceRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let listStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: sourceList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard listStatus == noErr else {
            return silentSampleFailure("audio-list-fill status=\(listStatus) size=\(bufferListSize)")
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceList)
        let bufferCount = sourceBuffers.count
        guard bufferCount > 0 else {
            return silentSampleFailure("audio-list-empty")
        }

        let zeroRaw = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { zeroRaw.deallocate() }
        let zeroList = zeroRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        zeroList.pointee.mNumberBuffers = sourceList.pointee.mNumberBuffers
        let zeroBuffers = UnsafeMutableAudioBufferListPointer(zeroList)
        var allocatedData: [UnsafeMutableRawPointer] = []
        defer { allocatedData.forEach { $0.deallocate() } }

        for index in 0..<bufferCount {
            let source = sourceBuffers[index]
            let byteCount = Int(source.mDataByteSize)
            guard byteCount > 0 else {
                zeroBuffers[index] = AudioBuffer(
                    mNumberChannels: source.mNumberChannels,
                    mDataByteSize: 0,
                    mData: nil
                )
                continue
            }
            let data = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
            data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            allocatedData.append(data)
            zeroBuffers[index] = AudioBuffer(
                mNumberChannels: source.mNumberChannels,
                mDataByteSize: source.mDataByteSize,
                mData: data
            )
        }

        var silentSample: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &silentSample
        ) == noErr, let silentSample else {
            return nil
        }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            silentSample,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: zeroList
        )
        guard setStatus == noErr else {
            return silentSampleFailure("audio-list-set status=\(setStatus) buffers=\(bufferCount)")
        }
        return silentSample
    }

    private func silentSampleFailure(_ reason: String) -> CMSampleBuffer? {
        Log.debug("recorder silent-audio diagnostic: \(reason)")
        return nil
    }
}
