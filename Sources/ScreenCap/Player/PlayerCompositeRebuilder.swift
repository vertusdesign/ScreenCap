@preconcurrency import AVFoundation
import CoreMedia

/// Renders a fresh physical composite track from ScreenCap's raw audio tracks.
/// The original video and raw tracks are copied into a temporary movie so the
/// user's source remains untouched until an explicit export/replace action.
enum PlayerCompositeRebuilder {
    private final class QueueConfined<Value>: @unchecked Sendable {
        var value: Value

        init(_ value: Value) { self.value = value }
    }

    private struct OriginalAudioSource: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let firstSample: CMSampleBuffer
    }

    static func rebuild(
        sourceURL: URL,
        volumes: [PlayerTrackKind: Double],
        removedTracks: Set<PlayerTrackKind>
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        guard let videoTrack = videoTracks.first else { throw PlayerCompositeRebuilderError.noVideo }
        let rawTracks = Array(audioTracks.dropFirst())
        guard !rawTracks.isEmpty else { throw PlayerCompositeRebuilderError.noRawTracks }

        let videoDescriptions = try await videoTrack.load(.formatDescriptions)
        var rawSources: [OriginalAudioSource] = []
        for track in rawTracks {
            let descriptions = try await track.load(.formatDescriptions)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: linearPCMSettings(sourceFormatHint: descriptions.first)
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading(), let firstSample = output.copyNextSampleBuffer() else {
                throw PlayerCompositeRebuilderError.readerFailed(
                    reader.error?.localizedDescription ?? "Could not read raw audio track."
                )
            }
            rawSources.append(OriginalAudioSource(reader: reader, output: output, firstSample: firstSample))
        }

        let mixedReader = try AVAssetReader(asset: asset)
        let mixedOutput = AVAssetReaderAudioMixOutput(
            audioTracks: rawTracks,
            audioSettings: linearPCMSettings(sourceFormatHint: nil)
        )
        let mix = AVMutableAudioMix()
        mix.inputParameters = rawTracks.enumerated().map { offset, track in
            let kind: PlayerTrackKind = offset == 0 ? .systemAudio : .microphone
            let parameter = AVMutableAudioMixInputParameters(track: track)
            // Rebuild deliberately uses every raw track that was not removed.
            // Mute is a playback audition state; a zero gain still provides an
            // explicit way to exclude a source from the newly rendered mix.
            let gain = removedTracks.contains(kind)
                ? 0
                : min(max(volumes[kind] ?? 1, 0), 4)
            parameter.setVolume(Float(gain), at: .zero)
            return parameter
        }
        mixedOutput.audioMix = mix
        mixedOutput.alwaysCopiesSampleData = false
        mixedReader.add(mixedOutput)

        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        videoReader.add(videoOutput)

        guard videoReader.startReading(),
              let firstVideoSample = videoOutput.copyNextSampleBuffer(),
              mixedReader.startReading(),
              let firstMixedSample = mixedOutput.copyNextSampleBuffer()
        else {
            throw PlayerCompositeRebuilderError.readerFailed(
                videoReader.error?.localizedDescription
                    ?? mixedReader.error?.localizedDescription
                    ?? "Could not start composite readers."
            )
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("screencap-composite-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: destination)
        do {
            let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
            writer.shouldOptimizeForNetworkUse = false

            let videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: videoDescriptions.first
            )
            videoInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput) else { throw PlayerCompositeRebuilderError.writerFailed("Could not add video input.") }
            writer.add(videoInput)

            let compositeInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings(sourceFormatHint: firstMixedSample.formatDescription, bitRate: 256_000),
                sourceFormatHint: firstMixedSample.formatDescription
            )
            compositeInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(compositeInput) else { throw PlayerCompositeRebuilderError.writerFailed("Could not add composite input.") }
            writer.add(compositeInput)

            var rawInputs: [AVAssetWriterInput] = []
            for source in rawSources {
                let input = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: audioSettings(sourceFormatHint: source.firstSample.formatDescription, bitRate: 192_000),
                    sourceFormatHint: source.firstSample.formatDescription
                )
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else { throw PlayerCompositeRebuilderError.writerFailed("Could not add raw audio input.") }
                writer.add(input)
                rawInputs.append(input)
            }

            guard writer.startWriting() else {
                throw PlayerCompositeRebuilderError.writerFailed(
                    writer.error?.localizedDescription ?? "Could not start composite writer."
                )
            }
            writer.startSession(atSourceTime: .zero)

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = try await appendAll(label: "composite-video", from: videoOutput, to: videoInput, writer: writer, initialSample: firstVideoSample)
                }
                group.addTask {
                    _ = try await appendAll(label: "composite-audio", from: mixedOutput, to: compositeInput, writer: writer, initialSample: firstMixedSample)
                }
                for (index, pair) in zip(rawSources, rawInputs).enumerated() {
                    let (source, input) = pair
                    group.addTask {
                        _ = try await appendAll(label: "composite-raw-\(index)", from: source.output, to: input, writer: writer, initialSample: source.firstSample)
                    }
                }
                try await group.waitForAll()
            }

            try await finish(writer: writer)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func appendAll(
        label: String,
        from output: AVAssetReaderOutput,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        initialSample: CMSampleBuffer
    ) async throws -> Int {
        let outputBox = QueueConfined(output)
        let inputBox = QueueConfined(input)
        let writerBox = QueueConfined(writer)
        let initialBox = QueueConfined<CMSampleBuffer?>(initialSample)

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "com.vertusdesign.ScreenCap.player-composite", qos: .userInitiated)
            var count = 0
            var finished = false

            func complete(_ result: Result<Int, Error>) {
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            inputBox.value.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while inputBox.value.isReadyForMoreMediaData {
                    guard writerBox.value.status != .failed, writerBox.value.status != .cancelled else {
                        complete(.failure(PlayerCompositeRebuilderError.writerFailed(
                            writerBox.value.error?.localizedDescription ?? "Composite writer stopped."
                        )))
                        return
                    }
                    let sample = initialBox.value ?? outputBox.value.copyNextSampleBuffer()
                    initialBox.value = nil
                    guard let sample else {
                        inputBox.value.markAsFinished()
                        complete(.success(count))
                        return
                    }
                    guard inputBox.value.append(sample) else {
                        complete(.failure(PlayerCompositeRebuilderError.writerFailed(
                            writerBox.value.error?.localizedDescription ?? "Could not append composite sample."
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
                    continuation.resume(throwing: PlayerCompositeRebuilderError.writerFailed(
                        writerBox.value.error?.localizedDescription ?? "Could not finish composite movie."
                    ))
                }
            }
        }
    }

    private static func linearPCMSettings(sourceFormatHint: CMFormatDescription?) -> [String: Any] {
        var sampleRate = 48_000.0
        var channels = 2
        if let sourceFormatHint,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormatHint) {
            sampleRate = asbd.pointee.mSampleRate > 0 ? asbd.pointee.mSampleRate : sampleRate
            channels = asbd.pointee.mChannelsPerFrame > 0 ? Int(asbd.pointee.mChannelsPerFrame) : channels
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static func audioSettings(sourceFormatHint: CMFormatDescription?, bitRate: Int) -> [String: Any] {
        var sampleRate = 48_000.0
        var channels = 2
        if let sourceFormatHint,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(sourceFormatHint) {
            sampleRate = asbd.pointee.mSampleRate > 0 ? asbd.pointee.mSampleRate : sampleRate
            channels = asbd.pointee.mChannelsPerFrame > 0 ? Int(asbd.pointee.mChannelsPerFrame) : channels
        }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVEncoderBitRateKey: bitRate,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
    }
}

enum PlayerCompositeRebuilderError: LocalizedError {
    case noVideo
    case noRawTracks
    case readerFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: return "The recording has no video track."
        case .noRawTracks: return "There are no independent audio tracks to mix."
        case .readerFailed(let message), .writerFailed(let message): return message
        }
    }
}
