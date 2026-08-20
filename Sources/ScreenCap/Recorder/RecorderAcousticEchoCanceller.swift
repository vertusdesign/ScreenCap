@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Conservative, offline acoustic echo reduction for ScreenCap recordings.
///
/// This is intentionally a post-processing stage, not a modification of the
/// microphone callback. ScreenCap always retains the original system and
/// microphone streams. The stage produces a temporary echo-reduced microphone
/// stream, renders a derived composite, and is committed only after the new
/// movie has been written successfully. Any uncertainty (no reference signal,
/// route/timeline mismatch, excessive duration, weak confidence or a writer
/// failure) returns the original-mix path instead of changing user audio.
@available(macOS 15.0, *)
enum RecorderAcousticEchoCanceller {
    private final class QueueConfined<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    struct Preparation: Sendable {
        let compositeURL: URL?
        let applied: Bool
        let warning: String?
    }

    private struct DecodedTrack {
        let samples: [Float]
        let sampleRate: Double
        let duration: Double
    }

    private struct SignalResult {
        let samples: [Float]
        let confidence: Double
        let beforeRMS: Float
        let afterRMS: Float
    }

    private static let analysisRate = 16_000.0
    private static let maximumDuration: Double = 30 * 60
    private static let maximumSamples = Int(analysisRate * maximumDuration)
    private static let maximumDelaySamples = Int(analysisRate * 0.5)
    private static let subtractionStrength: Float = 0.78

    /// Deterministic signal-only regression probe. It never touches a device,
    /// file or user's recording and is suitable for the existing headless
    /// self-test command.
    static func selfTest() -> Bool {
        let count = 16_000
        let delay = 320
        var reference = Array(repeating: Float.zero, count: count)
        var microphone = Array(repeating: Float.zero, count: count)
        for index in 0..<count {
            let t = Double(index) / analysisRate
            let render = Float(sin(t * 2 * .pi * 380) * 0.35)
            reference[index] = render
            let echo = index >= delay ? reference[index - delay] * 0.42 : 0
            microphone[index] = Float(sin(t * 2 * .pi * 170) * 0.06) + echo
        }
        guard let result = cancelEcho(reference: reference, microphone: microphone) else { return false }
        return result.confidence >= 0.08
            && result.afterRMS.isFinite
            && result.afterRMS >= result.beforeRMS * 0.30
            && result.afterRMS < result.beforeRMS
    }

    /// Attempts to prepare a mixed audio file from exactly two raw streams:
    /// system audio followed by microphone. A source with a different track
    /// layout is deliberately left to the existing raw-mix implementation.
    static func prepareCompositeAudio(
        asset: AVAsset,
        audioTracks: [AVAssetTrack]
    ) async -> Preparation {
        guard audioTracks.count == 2 else {
            return Preparation(compositeURL: nil, applied: false, warning: nil)
        }

        do {
            let system = try await decode(audioTracks[0], in: asset)
            let microphone = try await decode(audioTracks[1], in: asset)
            guard system.duration.isFinite, microphone.duration.isFinite,
                  system.duration > 0.1, microphone.duration > 0.1
            else {
                return Preparation(compositeURL: nil, applied: false, warning: nil)
            }
            guard max(system.duration, microphone.duration) <= maximumDuration else {
                Log.diagnostic(
                    "aec skipped: recording duration exceeds safe offline limit "
                        + String(format: "%.1f", maximumDuration) + "s"
                )
                return Preparation(
                    compositeURL: nil,
                    applied: false,
                    warning: L10n.t("recording.aec.skipped.long")
                )
            }
            guard abs(system.duration - microphone.duration) <= 1.0 else {
                Log.diagnostic(
                    "aec skipped: raw track duration mismatch system="
                        + String(format: "%.3f", system.duration)
                        + " microphone=" + String(format: "%.3f", microphone.duration)
                )
                return Preparation(compositeURL: nil, applied: false, warning: nil)
            }

            guard let result = cancelEcho(
                reference: system.samples,
                microphone: microphone.samples
            ) else {
                return Preparation(compositeURL: nil, applied: false, warning: nil)
            }
            guard result.confidence >= 0.08,
                  result.afterRMS.isFinite,
                  result.beforeRMS.isFinite,
                  result.afterRMS >= result.beforeRMS * 0.30,
                  result.afterRMS <= max(result.beforeRMS * 1.35, 0.002)
            else {
                Log.diagnostic(
                    "aec rejected: confidence=" + String(format: "%.3f", result.confidence)
                        + " beforeRMS=" + String(format: "%.5f", result.beforeRMS)
                        + " afterRMS=" + String(format: "%.5f", result.afterRMS)
                )
                return Preparation(compositeURL: nil, applied: false, warning: nil)
            }

            let temporaryMic = FileManager.default.temporaryDirectory
                .appendingPathComponent("screencap_aec_mic_\(UUID().uuidString).caf")
            let temporaryComposite = FileManager.default.temporaryDirectory
                .appendingPathComponent("screencap_aec_composite_\(UUID().uuidString).m4a")
            do {
                try writeMonoAudio(result.samples, to: temporaryMic)
                try await renderComposite(
                    asset: asset,
                    systemTrack: audioTracks[0],
                    processedMicrophoneURL: temporaryMic,
                    destination: temporaryComposite
                )
                try? FileManager.default.removeItem(at: temporaryMic)
                Log.diagnostic(
                    "aec applied: confidence=" + String(format: "%.3f", result.confidence)
                        + " delay-estimated and source microphone preserved"
                )
                return Preparation(compositeURL: temporaryComposite, applied: true, warning: nil)
            } catch {
                try? FileManager.default.removeItem(at: temporaryMic)
                try? FileManager.default.removeItem(at: temporaryComposite)
                throw error
            }
        } catch {
            Log.error(
                "aec preparation failed; keeping original microphone: "
                    + error.localizedDescription
            )
            return Preparation(
                compositeURL: nil,
                applied: false,
                warning: L10n.t("recording.aec.failed")
            )
        }
    }

    private static func decode(_ track: AVAssetTrack, in asset: AVAsset) async throws -> DecodedTrack {
        let sourceRange = try await track.load(.timeRange)
        let duration = sourceRange.duration.seconds
        guard duration.isFinite, duration > 0 else { throw CancellationError() }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: analysisRate
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CancellationError() }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CancellationError()
        }

        var samples: [Float] = []
        samples.reserveCapacity(min(max(Int(duration * analysisRate), 1), maximumSamples))
        while let sample = output.copyNextSampleBuffer() {
            guard samples.count < maximumSamples else {
                throw NSError(domain: "ScreenCap.AEC", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Audio exceeds the safe AEC buffer limit."
                ])
            }
            var listSize = 0
            let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample,
                bufferListSizeNeededOut: &listSize,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: nil
            )
            guard sizeStatus == noErr, listSize > 0 else { continue }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: listSize,
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { raw.deallocate() }
            let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
            var retained: CMBlockBuffer?
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample,
                bufferListSizeNeededOut: nil,
                bufferListOut: list,
                bufferListSize: listSize,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
                blockBufferOut: &retained
            )
            guard status == noErr else { continue }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let values = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count where samples.count < maximumSamples {
                    let value = values[index]
                    samples.append(value.isFinite ? min(max(value, -1), 1) : 0)
                }
            }
        }
        guard reader.status == .completed || reader.status == .reading else {
            throw reader.error ?? CancellationError()
        }
        return DecodedTrack(samples: samples, sampleRate: analysisRate, duration: Double(samples.count) / analysisRate)
    }

    private static func cancelEcho(reference: [Float], microphone: [Float]) -> SignalResult? {
        guard !reference.isEmpty, !microphone.isEmpty else { return nil }
        let referenceRMS = rms(reference)
        let microphoneRMS = rms(microphone)
        guard referenceRMS >= 0.001, microphoneRMS >= 0.0005 else { return nil }

        let delay = estimateDelay(reference: reference, microphone: microphone)
        let beforeCorrelation = correlation(
            reference: reference,
            microphone: microphone,
            delay: delay
        )
        guard beforeCorrelation >= 0.08 else { return nil }

        var output = Array(repeating: Float.zero, count: microphone.count)
        // A full WebRTC-style frequency-domain AEC is intentionally not
        // reimplemented here. This bounded blockwise single-path canceller is
        // conservative and O(n), so long recordings cannot turn post-processing
        // into an unbounded quadratic job. It estimates a slowly changing
        // reference gain per 32 ms block and freezes adaptation during
        // double-talk.
        let blockSize = 512
        var smoothedGain: Float = 0
        var adaptedBlocks = 0
        for blockStart in stride(from: 0, to: microphone.count, by: blockSize) {
            let blockEnd = min(microphone.count, blockStart + blockSize)
            var dot: Float = 0
            var referenceEnergy: Float = 0
            var microphoneEnergy: Float = 0
            var validSamples = 0
            for index in blockStart..<blockEnd {
                let referenceIndex = index - delay
                guard referenceIndex >= 0, referenceIndex < reference.count else { continue }
                let render = reference[referenceIndex]
                let near = microphone[index]
                dot += render * near
                referenceEnergy += render * render
                microphoneEnergy += near * near
                validSamples += 1
            }
            let referenceRMS = validSamples > 0
                ? sqrt(referenceEnergy / Float(validSamples))
                : 0
            let microphoneRMS = validSamples > 0
                ? sqrt(microphoneEnergy / Float(validSamples))
                : 0
            let doubleTalk = microphoneRMS > max(referenceRMS * 4, 0.025)
            if !doubleTalk, referenceEnergy > 0.0001, validSamples > 0 {
                let candidate = min(max(dot / referenceEnergy, -0.9), 0.9)
                smoothedGain += (candidate - smoothedGain) * 0.12
                adaptedBlocks += 1
            }
            let subtraction = min(max(smoothedGain * subtractionStrength, -0.8), 0.8)
            for index in blockStart..<blockEnd {
                let referenceIndex = index - delay
                guard referenceIndex >= 0, referenceIndex < reference.count else {
                    output[index] = microphone[index]
                    continue
                }
                output[index] = min(
                    max(microphone[index] - reference[referenceIndex] * subtraction, -1),
                    1
                )
            }
        }

        guard adaptedBlocks > 2 else { return nil }
        let afterCorrelation = correlation(reference: reference, microphone: output, delay: delay)
        let reduction = max(0, beforeCorrelation - afterCorrelation)
        let confidence = min(1, reduction * 2.5 + beforeCorrelation * 0.15)
        guard reduction >= 0.025 else { return nil }
        return SignalResult(
            samples: output,
            confidence: Double(confidence),
            beforeRMS: microphoneRMS,
            afterRMS: rms(output)
        )
    }

    private static func estimateDelay(reference: [Float], microphone: [Float]) -> Int {
        let coarseStep = 160 // 10 ms at 16 kHz
        let refineStep = 16 // 1 ms at 16 kHz
        let maxDelay = min(maximumDelaySamples, max(reference.count, 1) - 1)
        var bestDelay = 0
        var bestScore = -Float.infinity
        for delay in stride(from: 0, through: maxDelay, by: coarseStep) {
            let score = correlation(reference: reference, microphone: microphone, delay: delay, stride: 16)
            if score > bestScore { bestScore = score; bestDelay = delay }
        }
        let lower = max(0, bestDelay - coarseStep)
        let upper = min(maxDelay, bestDelay + coarseStep)
        for delay in stride(from: lower, through: upper, by: refineStep) {
            let score = correlation(reference: reference, microphone: microphone, delay: delay, stride: 8)
            if score > bestScore { bestScore = score; bestDelay = delay }
        }
        return bestDelay
    }

    private static func correlation(
        reference: [Float],
        microphone: [Float],
        delay: Int,
        stride: Int = 16
    ) -> Float {
        let start = max(delay, 0)
        let end = min(microphone.count, reference.count + delay)
        guard end - start > 512 else { return 0 }
        var xy: Double = 0
        var xx: Double = 0
        var yy: Double = 0
        var count = 0
        for index in Swift.stride(from: start, to: end, by: max(stride, 1)) {
            let x = Double(reference[index - delay])
            let y = Double(microphone[index])
            xy += x * y
            xx += x * x
            yy += y * y
            count += 1
        }
        guard count > 0, xx > 0.000001, yy > 0.000001 else { return 0 }
        return Float(xy / sqrt(xx * yy))
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples where sample.isFinite {
            sum += Double(sample * sample)
        }
        return Float(sqrt(sum / Double(samples.count)))
    }

    private static func writeMonoAudio(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: analysisRate, channels: 1)
        guard let format,
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              )
        else { throw CancellationError() }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else { throw CancellationError() }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private static func renderComposite(
        asset: AVAsset,
        systemTrack: AVAssetTrack,
        processedMicrophoneURL: URL,
        destination: URL
    ) async throws {
        let processedAsset = AVURLAsset(url: processedMicrophoneURL)
        let processedTracks = try await processedAsset.loadTracks(withMediaType: .audio)
        guard let processedTrack = processedTracks.first else { throw CancellationError() }
        let systemRange = try await systemTrack.load(.timeRange)
        let processedRange = try await processedTrack.load(.timeRange)
        let composition = AVMutableComposition()
        guard let systemCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let microphoneCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw CancellationError() }
        try systemCompositionTrack.insertTimeRange(systemRange, of: systemTrack, at: .zero)
        try microphoneCompositionTrack.insertTimeRange(processedRange, of: processedTrack, at: .zero)

        let mix = AVMutableAudioMix()
        let systemParameters = AVMutableAudioMixInputParameters(track: systemCompositionTrack)
        let microphoneParameters = AVMutableAudioMixInputParameters(track: microphoneCompositionTrack)
        systemParameters.setVolume(0.65, at: .zero)
        microphoneParameters.setVolume(0.65, at: .zero)
        mix.inputParameters = [systemParameters, microphoneParameters]

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CancellationError()
        }
        exporter.audioMix = mix
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false
        let exporterBox = QueueConfined(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporterBox.value.exportAsynchronously {
                switch exporterBox.value.status {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: continuation.resume(throwing: exporterBox.value.error ?? CancellationError())
                }
            }
        }
    }
}
