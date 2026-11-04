import CoreMedia
import CoreVideo

/// Audio can arrive before ScreenCaptureKit's first complete image. Preserve
/// that common source clock and cover only the video track's empty prefix with
/// the first accepted image. Moving the session origin to video would discard
/// early audio or change the synchronization of every subsequent sample.
enum RecorderVideoTimeline {
    enum TimelineError: Error {
        case invalidTime
        case invalidImage
        case copyFailed(OSStatus)
    }

    /// Returns one raw image sample spanning [origin, firstImagePTS), or nil
    /// when video already starts at the common origin. The source sample and
    /// all original audio/video timestamps remain unchanged.
    static func leadingFrame(
        from firstImage: CMSampleBuffer,
        origin: CMTime
    ) throws -> CMSampleBuffer? {
        let firstTime = firstImage.presentationTimeStamp
        guard origin.isNumeric, firstTime.isNumeric,
              origin.epoch == firstTime.epoch else { throw TimelineError.invalidTime }
        guard CMTimeCompare(firstTime, origin) > 0 else { return nil }
        guard CMSampleBufferIsValid(firstImage),
              CMSampleBufferDataIsReady(firstImage),
              CMSampleBufferGetNumSamples(firstImage) == 1,
              CMSampleBufferGetImageBuffer(firstImage) != nil else {
            throw TimelineError.invalidImage
        }

        var timing = CMSampleTimingInfo(
            duration: CMTimeSubtract(firstTime, origin),
            presentationTimeStamp: origin,
            decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: firstImage,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &result
        )
        guard status == noErr, let result else { throw TimelineError.copyFailed(status) }
        return result
    }
}
