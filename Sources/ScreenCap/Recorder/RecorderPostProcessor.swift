import AVFoundation
import CoreMedia

@available(macOS 15.0, *)
enum RecorderPostProcessor {
    static func validateFinalRecording(at url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.load(.tracks)
            guard let video = tracks.first(where: { $0.mediaType == .video }) else {
                Log.error("recorder validation failed: final file has no video track")
                return
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
                return
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
        } catch {
            Log.error("recorder final validation failed: \(error.localizedDescription)")
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
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int, Error>) in
            let queue = DispatchQueue(
                label: "com.vertusdesign.ScreenCap.recorder.postprocess",
                qos: .userInitiated
            )
            var pendingInitialSample = initialSample
            var count = 0
            var didFinish = false

            func finish(_ result: Result<Int, Error>) {
                guard !didFinish else { return }
                didFinish = true
                Log.debug("append " + label + " finished count=" + String(count))
                continuation.resume(with: result)
            }

            input.requestMediaDataWhenReady(on: queue) {
                guard !didFinish else { return }

                while input.isReadyForMoreMediaData {
                    if writer.status == .failed || writer.status == .cancelled {
                        finish(.failure(RecorderPostProcessorError.writerFailed(
                            writer.error?.localizedDescription
                                ?? "writer stopped during post-processing"
                        )))
                        return
                    }

                    let sampleBuffer: CMSampleBuffer?
                    if let initial = pendingInitialSample {
                        sampleBuffer = initial
                        pendingInitialSample = nil
                    } else {
                        sampleBuffer = output.copyNextSampleBuffer()
                    }

                    guard let sampleBuffer else {
                        input.markAsFinished()
                        finish(.success(count))
                        return
                    }

                    guard input.append(sampleBuffer) else {
                        finish(.failure(RecorderPostProcessorError.writerFailed(
                            writer.error?.localizedDescription
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
        try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: RecorderPostProcessorError.writerFailed(
                        writer.error?.localizedDescription
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
