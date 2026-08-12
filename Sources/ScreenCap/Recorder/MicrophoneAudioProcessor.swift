import AVFoundation
import CoreMedia
import RNNoise

/// Applies a small, source-independent voice-leveling stage to ScreenCap's
/// microphone track.
///
/// ScreenCaptureKit supplies microphone PCM, but it does not expose a
/// per-stream input-gain or voice-leveling control. This processor therefore
/// works on the samples after capture, without changing the system input route
/// used by Teams, Zoom, browsers, or any other application.
@available(macOS 15.0, *)
final class MicrophoneAudioProcessor {
    /// RNNoise has no public "strength" control. The compact upstream model
    /// keeps the CPU cost lower, while this blend deliberately keeps 35% of
    /// the original signal so quiet speech is less likely to be damaged.
    fileprivate static let noiseSuppressionMix: Float = 0.65

    private let targetRMS: Float = 0.14
    private let minimumAudibleRMS: Float = 0.003
    private let maximumGain: Float = 4.0
    private let gainAttack: TimeInterval = 0.18
    private let gainRelease: TimeInterval = 0.45
    private let compressorThreshold: Float = 0.72
    private let compressorRatio: Float = 4.0
    private let limiterCeiling: Float = 0.97
    private let noiseSuppression: Bool
    private var rnnoiseProcessors: [RNNoiseStreamProcessor] = []

    private var gain: Float = 1.0
    private var didLogUnsupportedFormat = false
    private var didLogProcessingFailure = false
    private var didLogNoiseSuppressionFallback = false

    private(set) var lastInputRMS: Float?
    private(set) var lastOutputRMS: Float?

    init(noiseSuppression: Bool = false) {
        self.noiseSuppression = noiseSuppression
    }

    func finish() {
        rnnoiseProcessors.forEach { $0.finish() }
        rnnoiseProcessors.removeAll(keepingCapacity: false)
    }

    /// Returns a copy with the original timestamps and format preserved.
    /// If a device exposes a PCM layout that this processor does not support,
    /// the untouched capture buffer is returned so recording remains safe.
    func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = PCMFormat(asbd: asbd.pointee)
        else {
            logUnsupportedFormatIfNeeded(sampleBuffer)
            return sampleBuffer
        }

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
            logProcessingFailureIfNeeded("audio-list-size status=\(sizeStatus)")
            return sampleBuffer
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
            logProcessingFailureIfNeeded("audio-list-fill status=\(listStatus)")
            return sampleBuffer
        }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceList)
        guard sourceBuffers.count > 0 else {
            logProcessingFailureIfNeeded("audio-list-empty")
            return sampleBuffer
        }

        let channelCount = sourceBuffers.reduce(into: 0) { total, buffer in
            total += max(1, Int(buffer.mNumberChannels))
        }
        let useNoiseSuppression = noiseSuppression
            && abs(asbd.pointee.mSampleRate - 48_000) < 0.5
            && prepareRNNoiseProcessors(count: channelCount)

        if noiseSuppression && !useNoiseSuppression {
            logNoiseSuppressionFallbackIfNeeded(
                asbd: asbd.pointee,
                channelCount: channelCount,
                bufferCount: sourceBuffers.count
            )
        }

        var processedChannels: [[[Float]]] = []
        processedChannels.reserveCapacity(sourceBuffers.count)
        var inputMeasurement = Measurement()
        var outputMeasurement = Measurement()
        var processorIndex = 0
        for buffer in sourceBuffers {
            let channels = readChannels(from: buffer, format: format)
            for channel in channels {
                for sample in channel {
                    inputMeasurement.add(sample)
                }
            }
            var filteredChannels = channels
            for channelIndex in channels.indices {
                if useNoiseSuppression {
                    filteredChannels[channelIndex] = rnnoiseProcessors[processorIndex].process(
                        channels[channelIndex],
                        mix: Self.noiseSuppressionMix
                    )
                }
                processorIndex += 1
            }
            for channel in filteredChannels {
                for sample in channel {
                    outputMeasurement.add(sample)
                }
            }
            processedChannels.append(filteredChannels)
        }
        guard outputMeasurement.sampleCount > 0 else {
            return sampleBuffer
        }

        lastInputRMS = inputMeasurement.rms
        lastOutputRMS = outputMeasurement.rms

        let duration = CMSampleBufferGetDuration(sampleBuffer).seconds
        updateGain(
            rms: outputMeasurement.rms,
            duration: duration.isFinite && duration > 0 ? duration : 0.01
        )
        lastOutputRMS = min(1, outputMeasurement.rms * gain)

        let destinationRaw = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { destinationRaw.deallocate() }
        let destinationList = destinationRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        destinationList.pointee.mNumberBuffers = sourceList.pointee.mNumberBuffers
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(destinationList)
        var allocatedData: [UnsafeMutableRawPointer] = []
        defer { allocatedData.forEach { $0.deallocate() } }

        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            let byteCount = Int(source.mDataByteSize)
            guard byteCount > 0, let sourceData = source.mData else {
                destinationBuffers[index] = AudioBuffer(
                    mNumberChannels: source.mNumberChannels,
                    mDataByteSize: 0,
                    mData: nil
                )
                continue
            }

            let destinationData = UnsafeMutableRawPointer.allocate(
                byteCount: byteCount,
                alignment: 16
            )
            allocatedData.append(destinationData)
            let channels = processedChannels[index]
            let channelCount = max(1, Int(source.mNumberChannels))
            let frameCount = channels.map(\.count).min() ?? 0
            var sampleIndex = 0
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<min(channelCount, channels.count) {
                    let value = shape(channels[channelIndex][frameIndex] * gain)
                    format.write(
                        value,
                        to: destinationData.advanced(by: sampleIndex * format.bytesPerSample)
                    )
                    sampleIndex += 1
                }
            }
            let expectedSampleCount = byteCount / format.bytesPerSample
            if sampleIndex < expectedSampleCount {
                // This should only be reachable for a malformed capture list;
                // preserve the tail rather than leaving uninitialized bytes.
                let tailOffset = sampleIndex * format.bytesPerSample
                destinationData
                    .advanced(by: tailOffset)
                    .copyMemory(
                        from: sourceData.advanced(by: tailOffset),
                        byteCount: byteCount - tailOffset
                    )
            }
            destinationBuffers[index] = AudioBuffer(
                mNumberChannels: source.mNumberChannels,
                mDataByteSize: source.mDataByteSize,
                mData: destinationData
            )
        }

        var processedSample: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &processedSample
        ) == noErr,
        let processedSample
        else {
            logProcessingFailureIfNeeded("sample-copy")
            return sampleBuffer
        }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            processedSample,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: destinationList
        )
        guard setStatus == noErr else {
            logProcessingFailureIfNeeded("audio-list-set status=\(setStatus)")
            return sampleBuffer
        }
        return processedSample
    }

    /// A small deterministic probe used by the headless self-test. It checks
    /// the two safety invariants of the DSP stage without requiring a live mic.
    static func selfTest() -> Bool {
        let processor = MicrophoneAudioProcessor()
        var quietVoice = [Float](repeating: 0.04, count: 480)
        let before = quietVoice[0]
        processor.processForTest(&quietVoice, duration: 0.01)
        let boosted = quietVoice[0]
        guard boosted > before, abs(boosted) < 1 else { return false }

        var loudVoice = [Float](repeating: 0.9, count: 480)
        processor.processForTest(&loudVoice, duration: 0.01)
        guard loudVoice.allSatisfy({ abs($0) <= 0.97 }) else { return false }

        return RNNoiseStreamProcessor.selfTest()
    }

    private func processForTest(_ samples: inout [Float], duration: TimeInterval) {
        var measurement = Measurement()
        for sample in samples {
            measurement.add(sample)
        }
        updateGain(rms: measurement.rms, duration: duration)
        for index in samples.indices {
            samples[index] = shape(samples[index] * gain)
        }
    }

    private func readChannels(from buffer: AudioBuffer, format: PCMFormat) -> [[Float]] {
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return [] }
        let channelCount = max(1, Int(buffer.mNumberChannels))
        let scalarCount = Int(buffer.mDataByteSize) / format.bytesPerSample
        let frameCount = scalarCount / channelCount
        var channels = Array(repeating: [Float](), count: channelCount)
        for channel in channels.indices {
            channels[channel].reserveCapacity(frameCount)
        }
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let scalarIndex = frame * channelCount + channel
                channels[channel].append(
                    format.read(from: data.advanced(by: scalarIndex * format.bytesPerSample))
                )
            }
        }
        return channels
    }

    private func updateGain(rms: Float, duration: TimeInterval) {
        let desiredGain: Float
        if rms < minimumAudibleRMS {
            // Do not hold a large voice gain during a long pause: that would
            // raise the microphone's noise floor when speech resumes.
            desiredGain = 1.0
        } else {
            desiredGain = min(maximumGain, max(1.0, targetRMS / rms))
        }

        let timeConstant = desiredGain > gain ? gainAttack : gainRelease
        let alpha = Float(1 - exp(-max(0.001, duration) / timeConstant))
        gain += (desiredGain - gain) * alpha
    }

    private func shape(_ input: Float) -> Float {
        guard input.isFinite else { return 0 }
        let sign: Float = input < 0 ? -1 : 1
        let magnitude = abs(input)
        let compressed: Float
        if magnitude <= compressorThreshold {
            compressed = magnitude
        } else {
            compressed = compressorThreshold
                + (magnitude - compressorThreshold) / compressorRatio
        }
        return sign * min(limiterCeiling, compressed)
    }

    private func logUnsupportedFormatIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        guard !didLogUnsupportedFormat else { return }
        didLogUnsupportedFormat = true
        let description = CMSampleBufferGetFormatDescription(sampleBuffer)
            .map { String(describing: $0) } ?? "unknown"
        Log.debug("recorder microphone DSP skipped unsupported format: \(description)")
    }

    private func logProcessingFailureIfNeeded(_ reason: String) {
        guard !didLogProcessingFailure else { return }
        didLogProcessingFailure = true
        Log.debug("recorder microphone DSP failed: \(reason)")
    }

    private func prepareRNNoiseProcessors(count: Int) -> Bool {
        guard count > 0 else { return false }
        if rnnoiseProcessors.count != count {
            rnnoiseProcessors.forEach { $0.finish() }
            rnnoiseProcessors = (0..<count).compactMap { _ in RNNoiseStreamProcessor() }
        }
        return rnnoiseProcessors.count == count
    }

    private func logNoiseSuppressionFallbackIfNeeded(
        asbd: AudioStreamBasicDescription,
        channelCount: Int,
        bufferCount: Int
    ) {
        guard !didLogNoiseSuppressionFallback else { return }
        didLogNoiseSuppressionFallback = true
        Log.debug(
            "recorder RNNoise skipped: sampleRate=\(asbd.mSampleRate), "
                + "channels=\(channelCount), buffers=\(bufferCount)"
        )
    }
}

@available(macOS 15.0, *)
private final class RNNoiseStreamProcessor {
    private let state: UnsafeMutableRawPointer
    private let frameSize: Int
    private var inputBuffer: [Float] = []
    private var outputBuffer: [Float] = []
    private var rawSamplesAhead = 0

    init?() {
        guard let state = screencap_rnnoise_create() else { return nil }
        let frameSize = Int(screencap_rnnoise_frame_size())
        guard frameSize > 0 else {
            screencap_rnnoise_destroy(state)
            return nil
        }
        self.state = state
        self.frameSize = frameSize
    }

    deinit {
        screencap_rnnoise_destroy(state)
    }

    func process(_ samples: [Float], mix: Float) -> [Float] {
        guard !samples.isEmpty else { return [] }
        inputBuffer.append(contentsOf: samples)
        processCompleteFrames()

        // The capture callback does not promise 480-sample buffers. When a
        // partial frame is waiting, keep the original samples for that short
        // interval; once RNNoise catches up, discard the corresponding
        // processed prefix and continue with the same media timeline.
        if rawSamplesAhead > 0 {
            let discardCount = min(rawSamplesAhead, outputBuffer.count)
            if discardCount > 0 {
                outputBuffer.removeFirst(discardCount)
                rawSamplesAhead -= discardCount
            }
        }

        let processedCount = min(samples.count, outputBuffer.count)
        var result: [Float] = []
        result.reserveCapacity(samples.count)
        for index in 0..<processedCount {
            let original = samples[index]
            let denoised = outputBuffer[index]
            result.append(original + (denoised - original) * mix)
        }
        if processedCount > 0 {
            outputBuffer.removeFirst(processedCount)
        }

        if processedCount < samples.count {
            result.append(contentsOf: samples[processedCount...])
            rawSamplesAhead += samples.count - processedCount
        }
        return result
    }

    func finish() {
        guard !inputBuffer.isEmpty else { return }
        let count = inputBuffer.count
        inputBuffer.append(contentsOf: repeatElement(0, count: frameSize - count))
        processCompleteFrames()
        let discardCount = min(rawSamplesAhead, outputBuffer.count)
        if discardCount > 0 {
            outputBuffer.removeFirst(discardCount)
        }
        inputBuffer.removeAll(keepingCapacity: false)
        outputBuffer.removeAll(keepingCapacity: false)
        rawSamplesAhead = 0
    }

    static func selfTest() -> Bool {
        guard let processor = RNNoiseStreamProcessor() else { return false }
        var input: [Float] = []
        input.reserveCapacity(960)
        for index in 0..<960 {
            let phase = Double(index)
            let value = sin(phase * 0.11) * 0.08 + sin(phase * 1.7) * 0.01
            input.append(Float(value))
        }
        let output = processor.process(input, mix: MicrophoneAudioProcessor.noiseSuppressionMix)
        guard output.count == input.count && output.allSatisfy({ $0.isFinite }) else {
            return false
        }

        guard let chunkedProcessor = RNNoiseStreamProcessor() else { return false }
        var chunkedOutput: [Float] = []
        var offset = 0
        for chunkSize in [137, 271, 72, 480] {
            let end = offset + chunkSize
            chunkedOutput.append(contentsOf: chunkedProcessor.process(
                Array(input[offset..<end]),
                mix: MicrophoneAudioProcessor.noiseSuppressionMix
            ))
            offset = end
        }
        return offset == input.count
            && chunkedOutput.count == input.count
            && chunkedOutput.allSatisfy { $0.isFinite }
    }

    private func processCompleteFrames() {
        while inputBuffer.count >= frameSize {
            let inputFrame = Array(inputBuffer.prefix(frameSize))
            inputBuffer.removeFirst(frameSize)
            var outputFrame = [Float](repeating: 0, count: frameSize)
            inputFrame.withUnsafeBufferPointer { inputPointer in
                outputFrame.withUnsafeMutableBufferPointer { outputPointer in
                    _ = screencap_rnnoise_process_frame(
                        state,
                        outputPointer.baseAddress,
                        inputPointer.baseAddress
                    )
                }
            }
            outputBuffer.append(contentsOf: outputFrame)
        }
    }
}

@available(macOS 15.0, *)
private struct Measurement {
    var squareSum: Double = 0
    var sampleCount = 0
    var peak: Float = 0

    var rms: Float {
        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(squareSum / Double(sampleCount)))
    }

    mutating func add(_ sample: Float) {
        guard sample.isFinite else { return }
        squareSum += Double(sample) * Double(sample)
        sampleCount += 1
        peak = max(peak, abs(sample))
    }
}

@available(macOS 15.0, *)
private struct PCMFormat {
    enum Kind {
        case float32
        case signedInteger16
        case signedInteger32
    }

    let kind: Kind
    let bytesPerSample: Int
    let isBigEndian: Bool

    init?(asbd: AudioStreamBasicDescription) {
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let flags = asbd.mFormatFlags
        let bits = Int(asbd.mBitsPerChannel)
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSigned = flags & kAudioFormatFlagIsSignedInteger != 0
        let isPacked = flags & kAudioFormatFlagIsPacked != 0
        guard isPacked else { return nil }

        switch (isFloat, isSigned, bits) {
        case (true, false, 32):
            kind = .float32
            bytesPerSample = 4
        case (false, true, 16):
            kind = .signedInteger16
            bytesPerSample = 2
        case (false, true, 32):
            kind = .signedInteger32
            bytesPerSample = 4
        default:
            return nil
        }
        isBigEndian = flags & kAudioFormatFlagIsBigEndian != 0
    }

    func read(from pointer: UnsafeRawPointer) -> Float {
        switch kind {
        case .float32:
            let raw = pointer.load(as: UInt32.self)
            let bits = isBigEndian ? raw.byteSwapped : raw
            return Float(bitPattern: bits)
        case .signedInteger16:
            let raw = pointer.load(as: UInt16.self)
            let bits = isBigEndian ? raw.byteSwapped : raw
            return Float(Int16(bitPattern: bits)) / 32_768
        case .signedInteger32:
            let raw = pointer.load(as: UInt32.self)
            let bits = isBigEndian ? raw.byteSwapped : raw
            return Float(Int32(bitPattern: bits)) / 2_147_483_648
        }
    }

    func write(_ value: Float, to pointer: UnsafeMutableRawPointer) {
        let clamped = max(-1, min(1, value))
        switch kind {
        case .float32:
            var bits = clamped.bitPattern
            if isBigEndian { bits = bits.byteSwapped }
            pointer.storeBytes(of: bits, as: UInt32.self)
        case .signedInteger16:
            let scaled = clamped < 0 ? clamped * 32_768 : clamped * 32_767
            var bits = UInt16(bitPattern: Int16(scaled.rounded()))
            if isBigEndian { bits = bits.byteSwapped }
            pointer.storeBytes(of: bits, as: UInt16.self)
        case .signedInteger32:
            let scaled = clamped < 0
                ? Double(clamped) * 2_147_483_648
                : Double(clamped) * 2_147_483_647
            var bits = UInt32(bitPattern: Int32(scaled.rounded()))
            if isBigEndian { bits = bits.byteSwapped }
            pointer.storeBytes(of: bits, as: UInt32.self)
        }
    }
}
