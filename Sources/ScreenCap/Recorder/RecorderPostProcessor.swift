@preconcurrency import AVFoundation
import CoreMedia

@available(macOS 15.0, *)
enum RecorderPostProcessor {
    // AVFoundation's writer/reader objects are intentionally confined to the
    // serial post-processing queue below. The SDK marks them non-Sendable, but
    // requestMediaDataWhenReady uses a @Sendable callback even though the
    // callback is executed on that explicitly owned queue. Keep the boundary
    // explicit until the planned Swift 6 actor migration can replace it with
    // a stronger isolation model.
    private final class QueueConfined<Value>: @unchecked Sendable {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    struct ValidationResult: Sendable {
        let isValid: Bool
        let summary: String
    }

    static func validateFinalRecording(at url: URL) async -> ValidationResult {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.load(.tracks)
            guard let video = tracks.first(where: { $0.mediaType == .video }) else {
                Log.error("recorder validation failed: final file has no video track")
                return ValidationResult(isValid: false, summary: "no video track")
            }
            let videoRange = try await video.load(.timeRange)
            let videoDuration = videoRange.duration.seconds
            let audioTracks = tracks.filter { $0.mediaType == .audio }
            var audioDurations: [Double] = []
            for track in audioTracks {
                let range = try await track.load(.timeRange)
                let duration = range.duration.seconds
                if duration.isFinite && duration > 0 {
                    audioDurations.append(duration)
                }
            }
            Log.diagnostic(
                "recorder final validation file=\(url.lastPathComponent) "
                    + "videoDuration=\(String(format: "%.3f", videoDuration))s "
                    + "audioTracks=\(audioTracks.count) "
                    + "audioDurations=\(audioDurations.map { String(format: "%.3f", $0) }.joined(separator: ","))"
            )
            guard videoDuration.isFinite, videoDuration > 0 else {
                Log.error("recorder validation failed: video duration is invalid")
                return ValidationResult(isValid: false, summary: "invalid video duration")
            }

            let timeline = try inspectVideoTimeline(asset: asset, track: video)
            if timeline.invalidTimingSamples > 0 {
                Log.error(
                    "recorder validation failed: video contains "
                        + "\(timeline.invalidTimingSamples) invalid timing samples"
                )
            }
            if timeline.negativeCompositionSamples > 0 {
                Log.error(
                    "recorder validation failed: video contains "
                        + "\(timeline.negativeCompositionSamples) negative PTS/DTS offsets"
                )
            }
            if timeline.maxDecodeGap > 2.0 {
                Log.diagnostic(
                    "recorder video timeline gap="
                        + String(format: "%.3f", timeline.maxDecodeGap)
                        + "s (a static screen can legitimately produce a gap)"
                )
            }
            for duration in audioDurations where abs(duration - videoDuration) > 1.0 {
                Log.error(
                    "recorder final media duration mismatch: video="
                        + String(format: "%.3f", videoDuration)
                        + "s audio="
                        + String(format: "%.3f", duration)
                        + "s"
                )
            }
            let valid = timeline.sampleCount > 0
                && timeline.invalidTimingSamples == 0
                && timeline.negativeCompositionSamples == 0
            let summary = timeline.summary
            return ValidationResult(isValid: valid, summary: summary)
        } catch {
            Log.error("recorder final validation failed: \(error.localizedDescription)")
            return ValidationResult(isValid: false, summary: error.localizedDescription)
        }
    }

    /// Adds one mixed audio track before the original system-audio and
    /// microphone tracks. The source movie is otherwise passed through.
    ///
    /// This is deliberately a best-effort enhancement: if a finished capture
    /// cannot be rewritten, the original valid movie remains in place.
    static func addCompositeAudioTrack(to url: URL) async -> URL {
        do {
            try await rewriteWithCompositeAudio(at: url)
        } catch {
            Log.error(
                "recorder composite audio track failed: " + error.localizedDescription
            )
        }
        return url
    }

    private static func rewriteWithCompositeAudio(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            return
        }

        let audioTracks = tracks.filter { $0.mediaType == .audio }
        guard !audioTracks.isEmpty else { return }
        Log.debug(
            "composite source tracks: video=1 audio=" + String(audioTracks.count)
        )

        let videoDescriptions = try await videoTrack.load(.formatDescriptions)

        // The mixed reader consumes its audio tracks. Independent readers
        // keep the two original streams available for the separate tracks.
        var originalAudioSources: [OriginalAudioSource] = []
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            let originalReader = try AVAssetReader(asset: asset)
            let originalOutput = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: linearPCMSettings(sourceFormatHint: descriptions.first)
            )
            originalOutput.alwaysCopiesSampleData = false
            originalReader.add(originalOutput)
            guard originalReader.startReading(),
                  let firstSample = originalOutput.copyNextSampleBuffer()
            else {
                throw RecorderPostProcessorError.readerFailed(
                    originalReader.error?.localizedDescription
                        ?? "could not read source audio"
                )
            }
            originalAudioSources.append(
                OriginalAudioSource(
                    reader: originalReader,
                    output: originalOutput,
                    firstSample: firstSample
                )
            )
        }

        // Keep video and audio-mix reading independent. AVAssetReader does
        // not reliably support concurrent consumption of two outputs from
        // the same reader when each output is drained on its own queue.
        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: nil
        )
        videoOutput.alwaysCopiesSampleData = false
        videoReader.add(videoOutput)

        let mixedReader = try AVAssetReader(asset: asset)
        let mixedOutput = AVAssetReaderAudioMixOutput(
            audioTracks: audioTracks,
            audioSettings: linearPCMSettings(sourceFormatHint: nil)
        )
        let mix = AVMutableAudioMix()
        // Leave headroom for the sum of system audio and microphone.
        mix.inputParameters = audioTracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(0.65, at: .zero)
            return parameters
        }
        mixedOutput.audioMix = mix
        mixedOutput.alwaysCopiesSampleData = false
        mixedReader.add(mixedOutput)

        guard videoReader.startReading(),
              let firstVideoSample = videoOutput.copyNextSampleBuffer(),
              mixedReader.startReading(),
              let firstMixedSample = mixedOutput.copyNextSampleBuffer()
        else {
            throw RecorderPostProcessorError.readerFailed(
                videoReader.error?.localizedDescription
                    ?? mixedReader.error?.localizedDescription
                    ?? "could not start audio mix reader"
            )
        }

        let temporaryURL = url
            .deletingPathExtension()
            .appendingPathExtension("composite.mov")
        try? FileManager.default.removeItem(at: temporaryURL)

        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoDescriptions.first
        )
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw RecorderPostProcessorError.writerFailed(
                "could not add video input"
            )
        }
        writer.add(videoInput)

        // This is added first among audio inputs so ordinary players select
        // it by default. The original system/microphone tracks follow it.
        let compositeInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: audioSettings(bitRate: 256_000),
            sourceFormatHint: firstMixedSample.formatDescription
        )
        compositeInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(compositeInput) else {
            throw RecorderPostProcessorError.writerFailed(
                "could not add composite audio input"
            )
        }
        writer.add(compositeInput)

        var originalAudioInputs: [AVAssetWriterInput] = []
        for source in originalAudioSources {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings(
                    bitRate: 192_000,
                    sourceFormatHint: source.firstSample.formatDescription
                ),
                sourceFormatHint: source.firstSample.formatDescription
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw RecorderPostProcessorError.writerFailed(
                    "could not add original audio track"
                )
            }
            writer.add(input)
            originalAudioInputs.append(input)
        }

        guard writer.startWriting() else {
            throw RecorderPostProcessorError.writerFailed(
                writer.error?.localizedDescription
                    ?? "could not start composite writer"
            )
        }
        writer.startSession(atSourceTime: .zero)

        // Feed every track concurrently. AVAssetWriter can apply backpressure
        // to one input while it is waiting for another input, so sequentially
        // draining the inputs can deadlock on longer recordings.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await appendAll(
                    label: "video",
                    from: videoOutput,
                    to: videoInput,
                    writer: writer,
                    initialSample: firstVideoSample
                )
            }
            group.addTask {
                _ = try await appendAll(
                    label: "composite",
                    from: mixedOutput,
                    to: compositeInput,
                    writer: writer,
                    initialSample: firstMixedSample
                )
            }
            for (index, pair) in zip(originalAudioSources, originalAudioInputs)
                .enumerated()
            {
                let (source, input) = pair
                group.addTask {
                    let count = try await appendAll(
                        label: "original-" + String(index),
                        from: source.output,
                        to: input,
                        writer: writer,
                        initialSample: source.firstSample
                    )
                    Log.debug(
                        "composite source audio[" + String(index) + "] samples="
                            + String(count)
                    )
                }
            }
            try await group.waitForAll()
        }

        try await finish(writer: writer)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    }

    private static func appendAll(
        label: String,
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        initialSample: CMSampleBuffer? = nil
    ) async throws -> Int {
        let outputBox = QueueConfined(output)
        let inputBox = QueueConfined(input)
        let writerBox = QueueConfined(writer)
        let pendingInitialSampleBox = QueueConfined(initialSample)
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int, Error>) in
            let queue = DispatchQueue(
                label: "com.vertusdesign.ScreenCap.recorder.postprocess",
                qos: .userInitiated
            )
            var count = 0
            var didFinish = false

            func finish(_ result: Result<Int, Error>) {
                guard !didFinish else { return }
                didFinish = true
                Log.debug("append " + label + " finished count=" + String(count))
                continuation.resume(with: result)
            }

            inputBox.value.requestMediaDataWhenReady(on: queue) {
                guard !didFinish else { return }

                while inputBox.value.isReadyForMoreMediaData {
                    if writerBox.value.status == .failed || writerBox.value.status == .cancelled {
                        finish(.failure(RecorderPostProcessorError.writerFailed(
                            writerBox.value.error?.localizedDescription
                                ?? "writer stopped during post-processing"
                        )))
                        return
                    }

                    let sampleBuffer: CMSampleBuffer?
                    if let initial = pendingInitialSampleBox.value {
                        sampleBuffer = initial
                        pendingInitialSampleBox.value = nil
                    } else {
                        sampleBuffer = outputBox.value.copyNextSampleBuffer()
                    }

                    guard let sampleBuffer else {
                        inputBox.value.markAsFinished()
                        finish(.success(count))
                        return
                    }

                    guard inputBox.value.append(sampleBuffer) else {
                        finish(.failure(RecorderPostProcessorError.writerFailed(
                            writerBox.value.error?.localizedDescription
                                ?? "could not append media sample"
                        )))
                        return
                    }
                    count += 1
                }
            }
        }
    }

    private static func finish(writer: AVAssetWriter) async throws {
        let writerBox = QueueConfined(writer)
        try await withCheckedThrowingContinuation { continuation in
            writerBox.value.finishWriting {
                if writerBox.value.status == .completed {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: RecorderPostProcessorError.writerFailed(
                        writerBox.value.error?.localizedDescription
                            ?? "could not finish composite movie"
                    ))
                }
            }
        }
    }

    private static func audioSettings(
        bitRate: Int,
        sourceFormatHint: CMFormatDescription? = nil
    ) -> [String: Any] {
        var sampleRate = 48_000.0
        var channelCount = 2
        if let sourceFormatHint,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormatHint) {
            if asbd.pointee.mSampleRate > 0 {
                sampleRate = asbd.pointee.mSampleRate
            }
            if asbd.pointee.mChannelsPerFrame > 0 {
                channelCount = Int(asbd.pointee.mChannelsPerFrame)
            }
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: bitRate,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount
        ]
    }

    private struct VideoTimelineReport {
        var sampleCount = 0
        var invalidTimingSamples = 0
        var negativeCompositionSamples = 0
        var maxDecodeGap = 0.0

        var summary: String {
            "samples=\(sampleCount), invalidTiming=\(invalidTimingSamples), "
                + "negativeComposition=\(negativeCompositionSamples), "
                + "maxDecodeGap=\(String(format: "%.3f", maxDecodeGap))s"
        }
    }

    private static func inspectVideoTimeline(
        asset: AVAsset,
        track: AVAssetTrack
    ) throws -> VideoTimelineReport {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw RecorderPostProcessorError.readerFailed("could not inspect final video track")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw RecorderPostProcessorError.readerFailed(
                reader.error?.localizedDescription ?? "could not read final video track"
            )
        }

        var report = VideoTimelineReport()
        var previousDecodeTime: Double?
        while let sample = output.copyNextSampleBuffer() {
            // AVAssetReader may expose zero-sample boundary buffers at the
            // beginning/end of a compressed track. They carry no media data
            // and legitimately have an indefinite timestamp; treating them
            // as video samples creates a false validation failure on otherwise
            // playable long recordings.
            guard CMSampleBufferGetNumSamples(sample) > 0 else {
                continue
            }

            report.sampleCount += 1
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let decode = CMSampleBufferGetDecodeTimeStamp(sample).seconds
            let duration = CMSampleBufferGetDuration(sample).seconds

            guard presentation.isFinite,
                  presentation >= -0.001
            else {
                report.invalidTimingSamples += 1
                continue
            }
            if duration.isInfinite {
                report.invalidTimingSamples += 1
            }

            if decode.isFinite {
                if let previousDecodeTime {
                    let gap = decode - previousDecodeTime
                    if gap < -0.001 {
                        report.invalidTimingSamples += 1
                    } else {
                        report.maxDecodeGap = max(report.maxDecodeGap, gap)
                    }
                }
                previousDecodeTime = decode
            }

            if presentation + 0.001 < decode {
                // A negative composition offset requires ctts version 1. The
                // current recorder deliberately disables frame reordering so
                // this is a portable-container failure, not merely a seek
                // quirk in one player.
                report.negativeCompositionSamples += 1
            }
        }

        guard reader.status == .completed else {
            throw RecorderPostProcessorError.readerFailed(
                reader.error?.localizedDescription ?? "video timeline inspection did not complete"
            )
        }
        return report
    }

    private static func linearPCMSettings(
        sourceFormatHint: CMFormatDescription?
    ) -> [String: Any] {
        var sampleRate = 48_000.0
        var channelCount = 2
        if let sourceFormatHint,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormatHint) {
            if asbd.pointee.mSampleRate > 0 {
                sampleRate = asbd.pointee.mSampleRate
            }
            if asbd.pointee.mChannelsPerFrame > 0 {
                channelCount = Int(asbd.pointee.mChannelsPerFrame)
            }
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }
}

@available(macOS 15.0, *)
private struct OriginalAudioSource {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let firstSample: CMSampleBuffer
}

@available(macOS 15.0, *)
private enum RecorderPostProcessorError: LocalizedError {
    case readerFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .readerFailed(let reason), .writerFailed(let reason):
            return reason
        }
    }
}
