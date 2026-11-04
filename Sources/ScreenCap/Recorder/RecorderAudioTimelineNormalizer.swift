import AVFoundation
import CoreMedia

/// Keeps ScreenCaptureKit audio buffers on the same clock as the video.
///
/// Most audio routes report a sample count whose duration agrees with the
/// CMSampleBuffer timing. Some Bluetooth input routes on macOS can instead
/// report a larger PCM payload while keeping the shorter capture duration.
/// Passing those buffers directly to AVAssetWriter makes the encoder trust the
/// payload size and can stretch the resulting movie by minutes or hours.
///
/// The normalizer treats the capture timestamps as authoritative. It only
/// creates a new buffer when the PCM payload is materially longer than the
/// declared/timestamp duration; otherwise the original buffer is returned
/// unchanged. This keeps the normal path zero-copy and makes the recovery path
/// conservative and reversible.
@available(macOS 15.0, *)
final class RecorderAudioTimelineNormalizer: @unchecked Sendable {
    private let label: String
    private var previousPresentationTimeStamp: CMTime?
    private var previousPayloadDuration: Double?
    private var previousAudioFormat: CMFormatDescription?
    private var didLogCorrection = false
    private var didLogFailure = false

    init(label: String) {
        self.label = label
    }

    /// Deterministic regression probe for the Bluetooth-route failure mode:
    /// the PCM payload advertises twice as many frames as its timing entry.
    /// The normalizer must keep the timestamp duration and reduce the sample
    /// count before the buffer reaches AVAssetWriter.
    static func selfTest() -> Bool {
        let sampleRate = 48_000.0
        let sourceFrameCount = 1_920
        let expectedFrameCount = 960
        let byteCount = sourceFrameCount * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr,
        let blockBuffer
        else { return false }

        var formatDescription: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let formatDescription
        else { return false }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 96_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var source: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: sourceFrameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [MemoryLayout<Float>.size],
            sampleBufferOut: &source
        ) == noErr,
        let source
        else { return false }

        let normalizer = RecorderAudioTimelineNormalizer(label: "self-test")
        let normalized = normalizer.normalize(source)
        let declaredDurationPass = CMSampleBufferGetNumSamples(normalized) == expectedFrameCount
            // The declared capture timing is 20 ms. After keeping that timing
            // and halving the malformed payload, the rebuilt sample buffer
            // must still represent the same 20 ms on the capture clock.
            && abs(CMSampleBufferGetDuration(normalized).seconds - 0.02) < 0.0001

        // The affected Bluetooth route can also report a payload duration of
        // ~35 ms while successive PTS values advance by ~17 ms. Verify that
        // the second overlapping buffer follows the PTS clock, even when its
        // own declared duration agrees with the (too-large) payload.
        var overlapTiming = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var overlapFirst: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: sourceFrameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &overlapTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [MemoryLayout<Float>.size],
            sampleBufferOut: &overlapFirst
        ) == noErr,
        let overlapFirst
        else { return false }

        var nextTiming = CMSampleTimingInfo(
            duration: overlapTiming.duration,
            presentationTimeStamp: CMTime(value: 1, timescale: 50),
            decodeTimeStamp: .invalid
        )
        var overlapSecond: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: overlapFirst,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &nextTiming,
            sampleBufferOut: &overlapSecond
        ) == noErr,
        let overlapSecond
        else { return false }

        let overlapNormalizer = RecorderAudioTimelineNormalizer(label: "self-test-overlap")
        _ = overlapNormalizer.normalize(overlapFirst)
        let normalizedOverlap = overlapNormalizer.normalize(overlapSecond)
        // A valid 20 ms packet followed by a valid 40 ms packet also advances
        // PTS by 20 ms. That delta describes the *previous* packet, so it must
        // not cause the current longer packet to lose half of its samples.
        let variablePacketNormalizer = RecorderAudioTimelineNormalizer(label: "self-test-variable")
        _ = variablePacketNormalizer.normalize(normalized)
        let normalizedVariablePacket = variablePacketNormalizer.normalize(overlapSecond)
        return declaredDurationPass
            && CMSampleBufferGetNumSamples(normalizedOverlap) == expectedFrameCount
            && CMSampleBufferGetNumSamples(normalizedVariablePacket) == sourceFrameCount
    }

    func normalize(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard sampleBuffer.isValid,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              asbd.pointee.mSampleRate.isFinite,
              asbd.pointee.mSampleRate > 0
        else {
            previousPayloadDuration = nil
            previousAudioFormat = nil
            rememberTimestamp(of: sampleBuffer)
            return sampleBuffer
        }

        let sampleRate = asbd.pointee.mSampleRate
        let actualFrameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let actualDuration = Double(actualFrameCount) / sampleRate
        let declaredDuration = CMSampleBufferGetDuration(sampleBuffer).seconds
        let timestampDuration = timestampDelta(from: previousPresentationTimeStamp, to: sampleBuffer)
        let priorPayloadDuration: Double?
        if let previousAudioFormat,
           CMFormatDescriptionEqual(previousAudioFormat, otherFormatDescription: formatDescription) {
            priorPayloadDuration = previousPayloadDuration
        } else {
            priorPayloadDuration = nil
        }
        previousPayloadDuration = actualDuration
        previousAudioFormat = formatDescription
        rememberTimestamp(of: sampleBuffer)

        // A PTS delta describes the previous packet, not the current one.
        // Require evidence of overlap in both payloads before using that
        // delta to trim the current packet. Format changes reset this evidence.
        let referenceDuration = referenceDuration(
            actualDuration: actualDuration,
            declaredDuration: declaredDuration,
            timestampDuration: timestampDuration,
            previousPayloadDuration: priorPayloadDuration
        )
        guard let referenceDuration,
              referenceDuration.isFinite,
              referenceDuration > 0
        else {
            return sampleBuffer
        }

        let expectedFrameCount = max(
            1,
            min(actualFrameCount, Int((referenceDuration * sampleRate).rounded()))
        )
        let correctionRatio = Double(actualFrameCount) / Double(expectedFrameCount)
        guard correctionRatio > 1.25 else {
            return sampleBuffer
        }

        guard let corrected = makeBuffer(
            from: sampleBuffer,
            formatDescription: formatDescription,
            frameCount: expectedFrameCount,
            sampleRate: sampleRate
        ) else {
            logFailure(
                "could not rebuild PCM buffer frames=\(actualFrameCount) "
                    + "target=\(expectedFrameCount)"
            )
            return sampleBuffer
        }

        if !didLogCorrection {
            didLogCorrection = true
            Log.diagnostic(
                "recorder corrected \(label) audio timeline: "
                    + "frames=\(actualFrameCount)->\(expectedFrameCount) "
                    + "sampleRate=\(String(format: "%.1f", sampleRate)) "
                    + "declaredDuration=\(String(format: "%.6f", declaredDuration)) "
                    + "timestampDuration=\(String(format: "%.6f", timestampDuration ?? -1))"
            )
        }
        return corrected
    }

    private func referenceDuration(
        actualDuration: Double,
        declaredDuration: Double,
        timestampDuration: Double?,
        previousPayloadDuration: Double?
    ) -> Double? {
        // A Bluetooth route can deliver overlapping buffers: the payload and
        // declared duration describe ~35 ms, while consecutive presentation
        // timestamps advance by ~17 ms. In that case the timestamp delta is
        // the capture clock and must win; otherwise AVAssetWriter appends the
        // overlap twice and stretches the movie. Ignore implausibly tiny
        // deltas (duplicate callbacks) via the 20% guard above.
        if let timestampDuration,
           let previousPayloadDuration,
           timestampDuration < 1.0,
           timestampDuration >= actualDuration * 0.20,
           timestampDuration < actualDuration * 0.80,
           timestampDuration < previousPayloadDuration * 0.80 {
            return timestampDuration
        }
        if declaredDuration.isFinite,
           declaredDuration > 0,
           declaredDuration < 1.0,
           declaredDuration >= actualDuration * 0.20,
           declaredDuration < actualDuration * 0.80 {
            return declaredDuration
        }

        // No confirmed inconsistency: preserve the complete PCM payload.
        // Never infer its duration solely from a differently sized predecessor.
        return actualDuration.isFinite && actualDuration > 0 ? actualDuration : nil
    }

    private func timestampDelta(
        from previous: CMTime?,
        to sampleBuffer: CMSampleBuffer
    ) -> Double? {
        guard let previous,
              previous.isValid,
              previous.isNumeric
        else { return nil }
        let current = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard current.isValid, current.isNumeric else { return nil }
        let delta = CMTimeGetSeconds(CMTimeSubtract(current, previous))
        return delta.isFinite && delta > 0 ? delta : nil
    }

    private func rememberTimestamp(of sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid, timestamp.isNumeric else { return }
        previousPresentationTimeStamp = timestamp
    }

    private func makeBuffer(
        from sampleBuffer: CMSampleBuffer,
        formatDescription: CMFormatDescription,
        frameCount: Int,
        sampleRate: Double
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
        guard sizeStatus == noErr, bufferListSize > 0 else { return nil }

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
        guard listStatus == noErr else { return nil }

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(sourceList)
        guard !sourceBuffers.isEmpty else { return nil }

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

        let actualFrameCount = max(1, CMSampleBufferGetNumSamples(sampleBuffer))
        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            guard source.mDataByteSize > 0, let sourceData = source.mData else {
                destinationBuffers[index] = AudioBuffer(
                    mNumberChannels: source.mNumberChannels,
                    mDataByteSize: 0,
                    mData: nil
                )
                continue
            }

            // Deriving bytes-per-frame from the actual payload supports both
            // interleaved and non-interleaved PCM layouts without guessing
            // from a device-specific ASBD flag.
            let bytesPerFrame = max(
                1,
                Int(source.mDataByteSize) / actualFrameCount
            )
            let requestedBytes = frameCount.multipliedReportingOverflow(by: bytesPerFrame)
            guard !requestedBytes.overflow else { return nil }
            let byteCount = min(Int(source.mDataByteSize), requestedBytes.partialValue)
            let destinationData = UnsafeMutableRawPointer.allocate(
                byteCount: byteCount,
                alignment: 16
            )
            destinationData.copyMemory(from: sourceData, byteCount: byteCount)
            allocatedData.append(destinationData)
            destinationBuffers[index] = AudioBuffer(
                mNumberChannels: source.mNumberChannels,
                mDataByteSize: UInt32(byteCount),
                mData: destinationData
            )
        }

        let timescale = Int32(max(1, Int(sampleRate.rounded())))
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            decodeTimeStamp: .invalid
        )
        var normalized: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &normalized
        )
        guard createStatus == noErr, let normalized else { return nil }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            normalized,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: destinationList
        )
        guard setStatus == noErr else { return nil }
        return normalized
    }

    private func logFailure(_ reason: String) {
        guard !didLogFailure else { return }
        didLogFailure = true
        Log.error("recorder audio timeline normalization failed for \(label): \(reason)")
    }
}
