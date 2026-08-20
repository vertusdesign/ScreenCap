@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import Foundation

/// Timestamp-aware, offline acoustic echo reduction for ScreenCap recordings.
///
/// The recorder never overwrites the captured microphone stream. The stage
/// decodes the system and microphone tracks onto a common timestamp grid,
/// applies a conservative frequency-domain adaptive filter with double-talk
/// protection, and returns both a derived microphone stream and a derived
/// composite. Any uncertainty falls back to the raw mix and keeps the source
/// tracks unchanged.
@available(macOS 15.0, *)
enum RecorderAcousticEchoCanceller {
    private final class QueueConfined<Value>: @unchecked Sendable {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    struct Preparation: Sendable {
        let compositeURL: URL?
        let processedMicrophoneURL: URL?
        let applied: Bool
        let warning: String?
    }

    private struct DecodedTrack {
        let samples: [Float]
        let valid: [Bool]
        let sampleRate: Double
        let startTime: Double
        let endTime: Double
        let discontinuityCount: Int
    }

    private struct AlignedSignals {
        let reference: [Float]
        let microphone: [Float]
        let valid: [Bool]
        let microphoneOffset: Int
    }

    private struct SignalResult {
        let samples: [Float]
        let confidence: Double
        let beforeRMS: Float
        let afterRMS: Float
        let envelopeReduction: Double
        let predictedEchoRatio: Double
        let adaptedFrames: Int
    }

    /// A real-input FFT workspace. vDSP's packed real FFT stores the Nyquist
    /// component in `imagp[0]`; DC/Nyquist are passed through, while all
    /// interior bins receive independent adaptive complex gains.
    private final class RealFFTWorkspace {
        let size: Int
        let bins: Int
        private let log2Size: vDSP_Length
        private let setup: FFTSetup
        private let input = UnsafeMutablePointer<DSPComplex>.allocate(capacity: 2048)
        private let inverseOutput = UnsafeMutablePointer<DSPComplex>.allocate(capacity: 2048)

        init?(size: Int) {
            guard size > 0, size.isPowerOfTwo else { return nil }
            self.size = size
            self.bins = size / 2
            self.log2Size = vDSP_Length(log2(Float(size)))
            guard let setup = vDSP_create_fftsetup(
                self.log2Size,
                FFTRadix(kFFTRadix2)
            ) else {
                return nil
            }
            self.setup = setup
        }

        deinit {
            input.deallocate()
            inverseOutput.deallocate()
            vDSP_destroy_fftsetup(setup)
        }

        func forward(
            _ source: UnsafePointer<Float>,
            real: UnsafeMutablePointer<Float>,
            imaginary: UnsafeMutablePointer<Float>
        ) {
            for index in 0..<size {
                input[index] = DSPComplex(real: source[index], imag: 0)
            }
            var split = DSPSplitComplex(realp: real, imagp: imaginary)
            vDSP_ctoz(input, 2, &split, 1, vDSP_Length(bins))
            vDSP_fft_zrip(
                setup,
                &split,
                1,
                log2Size,
                FFTDirection(FFT_FORWARD)
            )
        }

        func inverse(
            real: UnsafeMutablePointer<Float>,
            imaginary: UnsafeMutablePointer<Float>,
            output: UnsafeMutablePointer<Float>
        ) {
            var split = DSPSplitComplex(realp: real, imagp: imaginary)
            vDSP_fft_zrip(
                setup,
                &split,
                1,
                log2Size,
                FFTDirection(FFT_INVERSE)
            )
            vDSP_ztoc(&split, 1, inverseOutput, 2, vDSP_Length(bins))
            let scale = 1 / Float(size)
            for index in 0..<size {
                output[index] = inverseOutput[index].real * scale
            }
        }
    }

    private static let analysisRate = 16_000.0
    private static let maximumDuration: Double = 30 * 60
    private static let maximumSamples = Int(analysisRate * maximumDuration)
    private static let fftSize = 1_024
    private static let hopSize = fftSize / 2
    private static let adaptationRate: Float = 0.16
    private static let maximumFilterGain: Float = 2.0

    /// Pure signal regression checks used by the headless self-test. No device,
    /// file or user recording is touched.
    static func selfTest() -> Bool {
        let count = 32_000
        let delay = 320
        var reference = Array(repeating: Float.zero, count: count)
        var microphone = Array(repeating: Float.zero, count: count)
        for index in 0..<count {
            let t = Double(index) / analysisRate
            let render = Float(
                sin(t * 2 * .pi * 380) * 0.30
                    + sin(t * 2 * .pi * 1_100) * 0.14
            )
            reference[index] = render
            let echo = index >= delay ? reference[index - delay] * 0.52 : 0
            let nearSpeech = Float(sin(t * 2 * .pi * 170) * 0.045)
            microphone[index] = nearSpeech + echo
        }
        let valid = Array(repeating: true, count: count)
        guard let result = cancelEcho(
            reference: reference,
            microphone: microphone,
            valid: valid
        ) else {
            return false
        }
        let gapValid = valid.enumerated().map { index, value in
            index < 2_000 || index >= 3_000 ? value : false
        }
        guard let gapResult = cancelEcho(
            reference: reference,
            microphone: microphone,
            valid: gapValid
        ) else {
            return false
        }
        let gapChanged = zip(
            gapResult.samples[2_000..<3_000],
            microphone[2_000..<3_000]
        ).contains { abs($0 - $1) > 0.0001 }
        return result.confidence >= 0.05
            && result.afterRMS.isFinite
            && result.afterRMS < result.beforeRMS * 0.98
            && result.predictedEchoRatio > 0.01
            && !gapChanged
    }

    /// Attempts to produce a derived microphone stream and a derived
    /// composite. The source layout is intentionally strict: exactly two
    /// audio tracks means system audio followed by raw microphone audio.
    static func prepareCompositeAudio(
        asset: AVAsset,
        audioTracks: [AVAssetTrack]
    ) async -> Preparation {
        guard audioTracks.count == 2 else {
            return Preparation(
                compositeURL: nil,
                processedMicrophoneURL: nil,
                applied: false,
                warning: nil
            )
        }

        do {
            let system = try await decode(audioTracks[0], in: asset)
            let microphone = try await decode(audioTracks[1], in: asset)
            guard system.sampleRate == analysisRate,
                  microphone.sampleRate == analysisRate,
                  system.endTime.isFinite,
                  microphone.endTime.isFinite,
                  system.endTime > system.startTime + 0.1,
                  microphone.endTime > microphone.startTime + 0.1
            else {
                return Preparation(
                    compositeURL: nil,
                    processedMicrophoneURL: nil,
                    applied: false,
                    warning: nil
                )
            }
            guard max(
                system.endTime - system.startTime,
                microphone.endTime - microphone.startTime
            ) <= maximumDuration else {
                Log.diagnostic(
                    "aec skipped: recording duration exceeds safe offline limit "
                        + String(format: "%.1f", maximumDuration) + "s"
                )
                return Preparation(
                    compositeURL: nil,
                    processedMicrophoneURL: nil,
                    applied: false,
                    warning: L10n.t("recording.aec.skipped.long")
                )
            }

            let aligned = try align(system: system, microphone: microphone)
            guard aligned.valid.filter({ $0 }).count > fftSize * 4 else {
                return Preparation(
                    compositeURL: nil,
                    processedMicrophoneURL: nil,
                    applied: false,
                    warning: nil
                )
            }
            if system.discontinuityCount > 0 || microphone.discontinuityCount > 0 {
                Log.diagnostic(
                    "aec timestamp gaps: system=" + String(system.discontinuityCount)
                        + " microphone=" + String(microphone.discontinuityCount)
                )
            }

            guard let result = cancelEcho(
                reference: aligned.reference,
                microphone: aligned.microphone,
                valid: aligned.valid
            ) else {
                Log.diagnostic("aec skipped: insufficient stable reference")
                return Preparation(
                    compositeURL: nil,
                    processedMicrophoneURL: nil,
                    applied: false,
                    warning: L10n.t("recording.aec.lowConfidence")
                )
            }
            guard result.confidence >= 0.05,
                  result.predictedEchoRatio >= 0.01,
                  result.afterRMS.isFinite,
                  result.beforeRMS.isFinite,
                  result.afterRMS >= result.beforeRMS * 0.35,
                  result.afterRMS <= max(result.beforeRMS * 1.20, 0.002)
            else {
                Log.diagnostic(
                    "aec rejected: confidence=" + String(format: "%.3f", result.confidence)
                        + " predictedEchoRatio=" + String(format: "%.3f", result.predictedEchoRatio)
                        + " beforeRMS=" + String(format: "%.5f", result.beforeRMS)
                        + " afterRMS=" + String(format: "%.5f", result.afterRMS)
                )
                return Preparation(
                    compositeURL: nil,
                    processedMicrophoneURL: nil,
                    applied: false,
                    warning: L10n.t("recording.aec.lowConfidence")
                )
            }

            var processedFull = microphone.samples
            let alignedStart = aligned.microphoneOffset
            let alignedEnd = min(
                processedFull.count,
                alignedStart + result.samples.count
            )
            if alignedEnd > alignedStart {
                for index in alignedStart..<alignedEnd {
                    processedFull[index] = result.samples[index - alignedStart]
                }
            }

            let temporaryMic = FileManager.default.temporaryDirectory
                .appendingPathComponent("screencap_aec_mic_\(UUID().uuidString).caf")
            let temporaryComposite = FileManager.default.temporaryDirectory
                .appendingPathComponent("screencap_aec_composite_\(UUID().uuidString).m4a")
            do {
                try writeMonoAudio(processedFull, to: temporaryMic)
                try await renderComposite(
                    asset: asset,
                    systemTrack: audioTracks[0],
                    processedMicrophoneURL: temporaryMic,
                    destination: temporaryComposite
                )
                Log.diagnostic(
                    "aec applied: confidence=" + String(format: "%.3f", result.confidence)
                        + " predictedEchoRatio=" + String(format: "%.3f", result.predictedEchoRatio)
                        + " envelopeReduction=" + String(format: "%.3f", result.envelopeReduction)
                        + " adaptedFrames=" + String(result.adaptedFrames)
                        + " timestamp-aware processed microphone preserved"
                )
                return Preparation(
                    compositeURL: temporaryComposite,
                    processedMicrophoneURL: temporaryMic,
                    applied: true,
                    warning: nil
                )
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
                processedMicrophoneURL: nil,
                applied: false,
                warning: L10n.t("recording.aec.failed")
            )
        }
    }

    private static func decode(_ track: AVAssetTrack, in asset: AVAsset) async throws -> DecodedTrack {
        let sourceRange = try await track.load(.timeRange)
        let startTime = sourceRange.start.seconds.isFinite ? sourceRange.start.seconds : 0
        let duration = sourceRange.duration.seconds
        guard duration.isFinite, duration > 0 else { throw CancellationError() }

        let expectedSamples = min(
            max(Int(ceil(duration * analysisRate)) + Int(analysisRate), fftSize),
            maximumSamples
        )
        var samples = Array(repeating: Float.zero, count: expectedSamples)
        var valid = Array(repeating: false, count: expectedSamples)
        var maxWritten = 0
        var previousEnd: Double?
        var discontinuityCount = 0

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

        while let sample = output.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let sampleDuration = CMSampleBufferGetDuration(sample).seconds
            guard presentationTime.isFinite else { continue }
            let relativeTime = presentationTime - startTime
            let baseIndex = Int((relativeTime * analysisRate).rounded())
            if let previousEnd {
                let gap = presentationTime - previousEnd
                if abs(gap) > 0.020 {
                    discontinuityCount += 1
                }
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

            var offset = 0
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let values = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count {
                    let destination = baseIndex + offset + index
                    guard destination >= 0, destination < samples.count else { continue }
                    let value = values[index]
                    samples[destination] = value.isFinite ? min(max(value, -1), 1) : 0
                    valid[destination] = value.isFinite
                    maxWritten = max(maxWritten, destination + 1)
                }
                offset += count
            }
            let frameCount = max(0, offset)
            previousEnd = presentationTime + (sampleDuration.isFinite
                ? sampleDuration
                : Double(frameCount) / analysisRate)
        }
        guard reader.status == .completed || reader.status == .reading else {
            throw reader.error ?? CancellationError()
        }
        let expectedEnd = Int(ceil(duration * analysisRate))
        let trimCount = min(max(maxWritten, expectedEnd), samples.count)
        guard trimCount > 0 else { throw CancellationError() }
        return DecodedTrack(
            samples: Array(samples[0..<trimCount]),
            valid: Array(valid[0..<trimCount]),
            sampleRate: analysisRate,
            startTime: startTime,
            endTime: startTime + Double(trimCount) / analysisRate,
            discontinuityCount: discontinuityCount
        )
    }

    private static func align(
        system: DecodedTrack,
        microphone: DecodedTrack
    ) throws -> AlignedSignals {
        let commonStart = max(system.startTime, microphone.startTime)
        let commonEnd = min(system.endTime, microphone.endTime)
        guard commonEnd > commonStart + Double(fftSize) / analysisRate else {
            throw CancellationError()
        }
        let referenceOffset = max(
            0,
            Int(((commonStart - system.startTime) * analysisRate).rounded())
        )
        let microphoneOffset = max(
            0,
            Int(((commonStart - microphone.startTime) * analysisRate).rounded())
        )
        let requestedCount = Int(((commonEnd - commonStart) * analysisRate).rounded())
        let availableSystem = system.samples.count - referenceOffset
        let availableMicrophone = microphone.samples.count - microphoneOffset
        guard availableSystem > 0, availableMicrophone > 0, requestedCount > 0 else {
            throw CancellationError()
        }
        let count = min(
            requestedCount,
            min(availableSystem, availableMicrophone)
        )
        guard count > fftSize else { throw CancellationError() }
        var reference = Array(repeating: Float.zero, count: count)
        var microphoneSamples = Array(repeating: Float.zero, count: count)
        var valid = Array(repeating: false, count: count)
        for index in 0..<count {
            let systemIndex = referenceOffset + index
            let microphoneIndex = microphoneOffset + index
            reference[index] = system.samples[systemIndex]
            microphoneSamples[index] = microphone.samples[microphoneIndex]
            valid[index] = system.valid[systemIndex] && microphone.valid[microphoneIndex]
        }
        return AlignedSignals(
            reference: reference,
            microphone: microphoneSamples,
            valid: valid,
            microphoneOffset: microphoneOffset
        )
    }

    private static func cancelEcho(
        reference: [Float],
        microphone: [Float],
        valid: [Bool]
    ) -> SignalResult? {
        guard reference.count == microphone.count,
              microphone.count == valid.count,
              !reference.isEmpty
        else { return nil }
        let validCount = valid.filter { $0 }.count
        guard validCount > fftSize * 4 else { return nil }
        let referenceRMS = rms(reference, valid: valid)
        let microphoneRMS = rms(microphone, valid: valid)
        guard referenceRMS >= 0.0005, microphoneRMS >= 0.0002 else { return nil }
        guard let fft = RealFFTWorkspace(size: fftSize) else { return nil }

        var processed = Array(repeating: Float.zero, count: microphone.count)
        var weights = Array(repeating: Float.zero, count: microphone.count)
        var referenceFrame = Array(repeating: Float.zero, count: fftSize)
        var microphoneFrame = Array(repeating: Float.zero, count: fftSize)
        var errorFrame = Array(repeating: Float.zero, count: fftSize)
        var realReference = Array(repeating: Float.zero, count: fft.bins)
        var imaginaryReference = Array(repeating: Float.zero, count: fft.bins)
        var realMicrophone = Array(repeating: Float.zero, count: fft.bins)
        var imaginaryMicrophone = Array(repeating: Float.zero, count: fft.bins)
        var realError = Array(repeating: Float.zero, count: fft.bins)
        var imaginaryError = Array(repeating: Float.zero, count: fft.bins)
        var filterReal = Array(repeating: Float.zero, count: fft.bins)
        var filterImaginary = Array(repeating: Float.zero, count: fft.bins)
        let window = sqrtHannWindow(count: fftSize)
        let windowSquared = window.map { $0 * $0 }

        var predictedEnergy: Double = 0
        var microphoneEnergy: Double = 0
        var adaptedFrames = 0
        var activeFrames = 0

        for frameStart in stride(from: 0, to: microphone.count, by: hopSize) {
            var validInFrame = 0
            var referenceFrameRMS: Float = 0
            var microphoneFrameRMS: Float = 0
            for offset in 0..<fftSize {
                let index = frameStart + offset
                if index < microphone.count, valid[index] {
                    validInFrame += 1
                    let referenceValue = reference[index]
                    let microphoneValue = microphone[index]
                    referenceFrame[offset] = referenceValue
                    microphoneFrame[offset] = microphoneValue
                    referenceFrameRMS += referenceValue * referenceValue
                    microphoneFrameRMS += microphoneValue * microphoneValue
                } else {
                    referenceFrame[offset] = 0
                    microphoneFrame[offset] = index < microphone.count ? microphone[index] : 0
                }
            }
            let validity = Float(validInFrame) / Float(fftSize)
            let bypass = validity < 0.75
            if !bypass {
                let safeValidCount = validInFrame > 0 ? validInFrame : 1
                let validFrameCount = Float(safeValidCount)
                referenceFrameRMS = sqrt(referenceFrameRMS / validFrameCount)
                microphoneFrameRMS = sqrt(microphoneFrameRMS / validFrameCount)
            }
            for offset in 0..<fftSize {
                referenceFrame[offset] *= window[offset]
                microphoneFrame[offset] *= window[offset]
            }

            if bypass {
                for offset in 0..<fftSize {
                    let index = frameStart + offset
                    errorFrame[offset] = index < microphone.count ? microphone[index] : 0
                }
            } else {
                fftForward(
                    fft,
                    frame: referenceFrame,
                    real: &realReference,
                    imaginary: &imaginaryReference
                )
                fftForward(
                    fft,
                    frame: microphoneFrame,
                    real: &realMicrophone,
                    imaginary: &imaginaryMicrophone
                )

                let doubleTalk = microphoneFrameRMS > max(referenceFrameRMS * 2.2, 0.018)
                let adaptationWeight: Float = doubleTalk
                    ? 0
                    : min(1, referenceFrameRMS / max(microphoneFrameRMS, 0.001))
                var frameReferencePower: Double = 0
                var frameMicrophonePower: Double = 0
                var framePredictedPower: Double = 0
                for bin in 1..<fft.bins {
                    let referenceReal = realReference[bin]
                    let referenceImaginary = imaginaryReference[bin]
                    let microphoneReal = realMicrophone[bin]
                    let microphoneImaginary = imaginaryMicrophone[bin]
                    let referencePower = referenceReal * referenceReal
                        + referenceImaginary * referenceImaginary
                    let microphonePower = microphoneReal * microphoneReal
                        + microphoneImaginary * microphoneImaginary
                    let predictedReal = filterReal[bin] * referenceReal
                        - filterImaginary[bin] * referenceImaginary
                    let predictedImaginary = filterReal[bin] * referenceImaginary
                        + filterImaginary[bin] * referenceReal
                    if adaptationWeight > 0, referencePower > 0.00001 {
                        let step = adaptationRate * adaptationWeight
                        let errorReal = microphoneReal - predictedReal
                        let errorImaginary = microphoneImaginary - predictedImaginary
                        let denominator = referencePower + 0.00001
                        filterReal[bin] += step
                            * (errorReal * referenceReal + errorImaginary * referenceImaginary)
                            / denominator
                        filterImaginary[bin] += step
                            * (errorImaginary * referenceReal - errorReal * referenceImaginary)
                            / denominator
                        let gainSquared = filterReal[bin] * filterReal[bin]
                            + filterImaginary[bin] * filterImaginary[bin]
                        let maximumSquared = maximumFilterGain * maximumFilterGain
                        if gainSquared > maximumSquared {
                            let scale = maximumFilterGain / sqrt(gainSquared)
                            filterReal[bin] *= scale
                            filterImaginary[bin] *= scale
                        }
                    }
                    let updatedPredictedReal = filterReal[bin] * referenceReal
                        - filterImaginary[bin] * referenceImaginary
                    let updatedPredictedImaginary = filterReal[bin] * referenceImaginary
                        + filterImaginary[bin] * referenceReal
                    let subtraction: Float = doubleTalk ? 0.80 : 1.0
                    realError[bin] = microphoneReal - updatedPredictedReal * subtraction
                    imaginaryError[bin] = microphoneImaginary - updatedPredictedImaginary * subtraction
                    frameReferencePower += Double(referencePower)
                    frameMicrophonePower += Double(microphonePower)
                    framePredictedPower += Double(
                        updatedPredictedReal * updatedPredictedReal
                            + updatedPredictedImaginary * updatedPredictedImaginary
                    )
                }
                realError[0] = realMicrophone[0]
                imaginaryError[0] = imaginaryMicrophone[0]
                fftInverse(
                    fft,
                    real: &realError,
                    imaginary: &imaginaryError,
                    output: &errorFrame
                )
                if frameReferencePower > 0.0001, frameMicrophonePower > 0.0001 {
                    activeFrames += 1
                    predictedEnergy += framePredictedPower
                    microphoneEnergy += frameMicrophonePower
                    if !doubleTalk {
                        adaptedFrames += 1
                    }
                }
            }

            for offset in 0..<fftSize {
                let index = frameStart + offset
                guard index < microphone.count else { continue }
                let value = bypass
                    ? errorFrame[offset] * windowSquared[offset]
                    : errorFrame[offset] * window[offset]
                processed[index] += value
                weights[index] += windowSquared[offset]
            }
        }

        for index in processed.indices {
            if valid[index], weights[index] > 0.0001 {
                processed[index] = min(max(processed[index] / weights[index], -1), 1)
            } else {
                processed[index] = microphone[index]
            }
        }
        guard activeFrames > 4, microphoneEnergy > 0.0001 else { return nil }
        let afterRMS = rms(processed, valid: valid)
        let predictedRatio = min(1, predictedEnergy / microphoneEnergy)
        let beforeEnvelope = energyEnvelopeCorrelation(
            reference: reference,
            microphone: microphone,
            valid: valid
        )
        let afterEnvelope = energyEnvelopeCorrelation(
            reference: reference,
            microphone: processed,
            valid: valid
        )
        let envelopeReduction = max(0, beforeEnvelope - afterEnvelope)
        let confidence = min(
            1,
            predictedRatio * 0.55
                + envelopeReduction * 0.35
                + min(Double(adaptedFrames) / Double(max(activeFrames, 1)), 1) * 0.10
        )
        return SignalResult(
            samples: processed,
            confidence: confidence,
            beforeRMS: microphoneRMS,
            afterRMS: afterRMS,
            envelopeReduction: envelopeReduction,
            predictedEchoRatio: predictedRatio,
            adaptedFrames: adaptedFrames
        )
    }

    private static func fftForward(
        _ fft: RealFFTWorkspace,
        frame: [Float],
        real: inout [Float],
        imaginary: inout [Float]
    ) {
        frame.withUnsafeBufferPointer { framePointer in
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    fft.forward(
                        framePointer.baseAddress!,
                        real: realPointer.baseAddress!,
                        imaginary: imaginaryPointer.baseAddress!
                    )
                }
            }
        }
    }

    private static func fftInverse(
        _ fft: RealFFTWorkspace,
        real: inout [Float],
        imaginary: inout [Float],
        output: inout [Float]
    ) {
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                output.withUnsafeMutableBufferPointer { outputPointer in
                    fft.inverse(
                        real: realPointer.baseAddress!,
                        imaginary: imaginaryPointer.baseAddress!,
                        output: outputPointer.baseAddress!
                    )
                }
            }
        }
    }

    private static func sqrtHannWindow(count: Int) -> [Float] {
        guard count > 1 else { return [1] }
        return (0..<count).map { index in
            let phase = 2 * Double.pi * Double(index) / Double(count - 1)
            return Float(sqrt(max(0, 0.5 - 0.5 * cos(phase))))
        }
    }

    private static func rms(_ samples: [Float], valid: [Bool]) -> Float {
        var sum: Double = 0
        var count = 0
        for index in samples.indices where index < valid.count && valid[index] {
            let value = samples[index]
            guard value.isFinite else { continue }
            sum += Double(value * value)
            count += 1
        }
        return count > 0 ? Float(sqrt(sum / Double(count))) : 0
    }

    private static func energyEnvelopeCorrelation(
        reference: [Float],
        microphone: [Float],
        valid: [Bool]
    ) -> Double {
        let frameSize = 320
        var referenceEnvelope: [Double] = []
        var microphoneEnvelope: [Double] = []
        for start in stride(from: 0, to: min(reference.count, microphone.count), by: frameSize) {
            let end = min(min(reference.count, microphone.count), start + frameSize)
            var referenceEnergy = 0.0
            var microphoneEnergy = 0.0
            var count = 0
            for index in start..<end where index < valid.count && valid[index] {
                referenceEnergy += Double(reference[index] * reference[index])
                microphoneEnergy += Double(microphone[index] * microphone[index])
                count += 1
            }
            guard count > frameSize / 2 else { continue }
            referenceEnvelope.append(sqrt(referenceEnergy / Double(count)))
            microphoneEnvelope.append(sqrt(microphoneEnergy / Double(count)))
        }
        guard referenceEnvelope.count == microphoneEnvelope.count,
              referenceEnvelope.count > 4
        else { return 0 }
        let referenceMean = referenceEnvelope.reduce(0, +) / Double(referenceEnvelope.count)
        let microphoneMean = microphoneEnvelope.reduce(0, +) / Double(microphoneEnvelope.count)
        var xy = 0.0
        var xx = 0.0
        var yy = 0.0
        for index in referenceEnvelope.indices {
            let x = referenceEnvelope[index] - referenceMean
            let y = microphoneEnvelope[index] - microphoneMean
            xy += x * y
            xx += x * x
            yy += y * y
        }
        guard xx > 0.000001, yy > 0.000001 else { return 0 }
        return max(0, min(1, xy / sqrt(xx * yy)))
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

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else { throw CancellationError() }
        exporter.audioMix = mix
        exporter.outputURL = destination
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = false
        let exporterBox = QueueConfined(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporterBox.value.exportAsynchronously {
                switch exporterBox.value.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(
                        throwing: exporterBox.value.error ?? CancellationError()
                    )
                }
            }
        }
    }
}

private extension Int {
    var isPowerOfTwo: Bool { self > 0 && (self & (self - 1)) == 0 }
}
