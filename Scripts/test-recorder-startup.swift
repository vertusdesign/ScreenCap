// Compile together with RecorderWriterStartup, RecorderAudioTimelineNormalizer,
// RecorderVideoTimeline and ScreenCapTrackMetadata. Uses only synthetic media.
import AVFoundation
import Foundation

#if !SCREENCAP_RECORDER_INTEGRATION_TESTS
enum Log {
    static func diagnostic(_ message: @autoclosure () -> String) { print(message()) }
    static func error(_ message: @autoclosure () -> String) { print(message()) }
}
#endif

@main
@available(macOS 15.0, *)
struct RecorderStartupTests {
    struct TestFailure: Error { let message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message: message) }
    }

    static func pcm(rate: Double, channels: UInt32, frames: Int, time: Double) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: channels * 4, mFramesPerPacket: 1,
            mBytesPerFrame: channels * 4, mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        ) == noErr, "PCM format creation")
        var block: CMBlockBuffer?
        let bytes = frames * Int(channels) * MemoryLayout<Float>.size
        try check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
        ) == noErr, "PCM allocation")
        let data = (0..<(frames * Int(channels))).map {
            Float(0.2 * sin(2 * .pi * 440 * (time + Double($0 / Int(channels)) / rate)))
        }
        let status = data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!,
                offsetIntoDestination: 0, dataLength: bytes)
        }
        try check(status == noErr, "PCM data copy")
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var stride = Int(channels) * 4
        var buffer: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: description!,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &stride, sampleBufferOut: &buffer
        ) == noErr, "PCM buffer creation")
        return buffer!
    }

    static func waitForInput(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData {
            try check(writer.status == .writing && Date() < deadline, "encoder stalled: \(String(describing: writer.error))")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func encodingTest(
        directory: URL,
        forceFallback: Bool,
        overlap: Bool = false,
        videoDelay: Double = 0,
        coverGap: Bool = true
    ) async throws {
        let suffix = videoDelay > 0 ? "-video-delay-\(Int(videoDelay * 1_000))\(coverGap ? "" : "-control")" : ""
        let url = directory.appendingPathComponent("\(forceFallback ? "fallback" : "automatic")\(overlap ? "-overlap" : "")\(suffix).mov")
        var writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 1_000)
        let microphone = try pcm(rate: 16_000, channels: 1, frames: 320, time: 0)
        let system = try pcm(rate: 48_000, channels: 2, frames: 960, time: 0)
        var attempts: [RecorderWriterStartup.AudioProfile] = []
        let (tracks, adaptor) = try RecorderWriterStartup.start(writer: &writer, hasAudio: true) { candidate, profile in
            attempts.append(profile)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
                AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false]
            ])
            candidate.add(video)
            var inputs = [video]
            for (sample, bitrate, role) in [(system, 256_000, ScreenCapTrackRole.systemAudio),
                                            (microphone, 192_000, .microphoneRaw)] {
                var settings = profile.settings(bitRate: bitrate, sourceFormat: sample.formatDescription)
                // Reproduce the actual regression, through the real startWriting
                // rejection path; no production environment flag is needed.
                if forceFallback && profile == .automatic && role == .microphoneRaw {
                    settings[AVSampleRateKey] = 16_000.0
                    settings[AVNumberOfChannelsKey] = 1
                }
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings,
                    sourceFormatHint: sample.formatDescription)
                ScreenCapTrackMetadata.apply(role: role, displayName: role.rawValue, to: input)
                candidate.add(input)
                inputs.append(input)
            }
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
            return (inputs, adaptor)
        }
        try check(attempts == (forceFallback ? [.automatic, .compatible] : [.automatic]), "retry count/profile")
        try check(writer.movieFragmentInterval == CMTime(seconds: 5, preferredTimescale: 1_000), "fragment interval lost")
        writer.startSession(atSourceTime: .zero)
        let normalizer = RecorderAudioTimelineNormalizer(label: "startup-test-microphone")
        for index in 0..<50 {
            let time = Double(index) * 0.02
            var pixel: CVPixelBuffer?
            try check(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                nil, &pixel) == kCVReturnSuccess, "video allocation")
            CVPixelBufferLockBaseAddress(pixel!, [])
            memset(CVPixelBufferGetBaseAddress(pixel!), 48, CVPixelBufferGetBytesPerRow(pixel!) * 180)
            CVPixelBufferUnlockBaseAddress(pixel!, [])
            let videoTime = videoDelay + time * (1 - videoDelay)
            if index == 0, coverGap {
                var format: CMVideoFormatDescription?
                try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: pixel!, formatDescriptionOut: &format) == noErr, "video format")
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 50),
                    presentationTimeStamp: CMTime(seconds: videoTime, preferredTimescale: 48_000),
                    decodeTimeStamp: .invalid)
                var firstImage: CMSampleBuffer?
                try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                    imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing,
                    sampleBufferOut: &firstImage) == noErr, "first image sample")
                let lead = try RecorderVideoTimeline.leadingFrame(from: firstImage!, origin: .zero)
                try check((lead != nil) == (videoDelay > 0), "unexpected leading sample")
                if let lead {
                    try check(abs(lead.duration.seconds - videoDelay) < 0.0001,
                        "leading sample does not cover the gap exactly")
                    try check(firstImage!.presentationTimeStamp == timing.presentationTimeStamp,
                        "source video timestamp was modified")
                    try await waitForInput(tracks[0], writer: writer)
                    try check(tracks[0].append(lead), "leading image append")
                }
            }
            try await waitForInput(tracks[0], writer: writer)
            try check(adaptor.append(pixel!, withPresentationTime: CMTime(seconds: videoTime,
                preferredTimescale: 48_000)), "video append")
            let sys = try pcm(rate: 48_000, channels: 2, frames: 960, time: time)
            let mic = normalizer.normalize(try pcm(rate: 16_000, channels: 1,
                frames: overlap ? 640 : 320, time: time))
            try await waitForInput(tracks[1], writer: writer)
            try check(tracks[1].append(sys), "system append")
            try await waitForInput(tracks[2], writer: writer)
            try check(tracks[2].append(mic), "microphone append")
        }
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 48_000))
        tracks.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        try check(writer.status == .completed, "finish failed: \(String(describing: writer.error))")
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try check(videoTracks.count == 1 && audioTracks.count == 2, "missing video/source audio track")
        let duration = try await asset.load(.duration).seconds
        try check(abs(duration - 1) < 0.12, "movie duration stretched: \(duration)")
        if coverGap {
            try await checkVideoStart(asset: asset)
        } else {
            let segments = try await videoTracks[0].load(.segments)
            try check(segments.first?.isEmpty == true, "control did not reproduce the empty video prefix")
            print("PASS control reproduces the original empty video edit")
        }
        for (index, track) in audioTracks.enumerated() {
            let timeRange = try await track.load(.timeRange)
            try check(abs(timeRange.duration.seconds - 1) < 0.12, "audio duration stretched")
            let metadata = try await track.load(.metadata)
            var roles: [ScreenCapTrackRole] = []
            for item in metadata {
                if let text = try await item.load(.stringValue), let role = ScreenCapTrackMetadata.role(fromValue: text) {
                    roles.append(role)
                }
            }
            try check(roles.contains(index == 0 ? .systemAudio : .microphoneRaw), "track role lost")
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output)
            try check(reader.startReading(), "decoder start")
            var sampleCount = 0
            var energy = 0.0
            var firstAudioPTS: Double?
            while let sample = output.copyNextSampleBuffer() {
                if firstAudioPTS == nil { firstAudioPTS = sample.presentationTimeStamp.seconds }
                guard let block = sample.dataBuffer else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                try check(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                    totalLengthOut: &length, dataPointerOut: &pointer) == noErr, "decoded PCM read")
                let floats = UnsafeRawPointer(pointer!).assumingMemoryBound(to: Float.self)
                for i in 0..<(length / 4) { energy += Double(floats[i] * floats[i]); sampleCount += 1 }
            }
            try check(reader.status == .completed && sampleCount > 0 && energy / Double(sampleCount) > 0.001,
                "empty/silent/corrupt source track")
            try check(abs(firstAudioPTS ?? .infinity) < 0.0001,
                "early audio was dropped or shifted to the first video frame")
        }
        if videoDelay > 0, coverGap {
            // A later container-only export must keep a real image at zero.
            let copy = directory.appendingPathComponent("remux-" + url.lastPathComponent)
            let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)!
            try await exporter.export(to: copy, as: .mov)
            let exported = AVURLAsset(url: copy)
            try await checkVideoStart(asset: exported)
            let exportedDuration = try await exported.load(.duration).seconds
            try check(abs(exportedDuration - 1) < 0.12, "passthrough duration stretched")
        }
        print("PASS \(url.lastPathComponent): video + both named audio tracks decode, duration=\(duration)s")
    }

    static func checkVideoStart(asset: AVAsset) async throws {
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let segments = try await video.load(.segments)
        try check(segments.first?.isEmpty == false, "movie begins with an empty video edit")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        try check(reader.startReading(), "video decode failed")
        defer { reader.cancelReading() }
        for index in 0..<3 {
            guard let frame = output.copyNextSampleBuffer(), let pixel = frame.imageBuffer else {
                throw TestFailure(message: "missing leading decoded frame")
            }
            if index == 0 {
                try check(abs(frame.presentationTimeStamp.seconds) < 0.0001, "first image is not at zero")
            }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let rgb = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let value = max(rgb[0], rgb[1], rgb[2])
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            try check(value > 25, "unexpected black decoded frame at startup")
        }
    }

    #if SCREENCAP_RECORDER_INTEGRATION_TESTS
    /// Run against the actual recorder, including PCM normalization, muting,
    /// relative timestamps, final validation and composite-audio rewriting.
    /// No screen/microphone capture or application launch is involved.
    static func writerServiceTest(
        directory: URL,
        videoDelay: Double,
        captureAudio: Bool,
        muteSystem: Bool = false,
        microphoneOnly: Bool = false
    ) async throws {
        let url = directory.appendingPathComponent("service-\(microphoneOnly ? "microphone" : captureAudio ? "audio" : "video")-\(Int(videoDelay * 1_000))-\(muteSystem).mov")
        let service = try RecorderWriterService(
            file: RecorderFile(url: url, width: 320, height: 180),
            captureSystemAudio: captureAudio && !microphoneOnly, captureMicrophone: captureAudio,
            noiseSuppression: false, echoReduction: false, videoCodecPreference: .h264
        )
        defer { service.cancel(preserveMarker: true) }
        service.setSystemAudioEnabled(!muteSystem)
        let sourceOrigin = 12.0
        for index in 0..<50 {
            let time = Double(index) * 0.02
            if captureAudio {
                if !microphoneOnly {
                await service.append(try pcm(rate: 48_000, channels: 2, frames: 960,
                    time: sourceOrigin + time), type: .systemAudio)
                }
                // The microphone starts later than system audio. It must not
                // move to zero or the video start during finalization.
                if index >= 3 {
                    await service.append(try pcm(rate: 16_000, channels: 1, frames: 320,
                        time: sourceOrigin + time), type: .microphone)
                }
            }
            var pixel: CVPixelBuffer?
            try check(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
                nil, &pixel) == kCVReturnSuccess, "service image allocation")
            CVPixelBufferLockBaseAddress(pixel!, [])
            memset(CVPixelBufferGetBaseAddress(pixel!), 48, CVPixelBufferGetBytesPerRow(pixel!) * 180)
            CVPixelBufferUnlockBaseAddress(pixel!, [])
            var format: CMVideoFormatDescription?
            try check(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixel!, formatDescriptionOut: &format) == noErr, "service video format")
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 50),
                presentationTimeStamp: CMTime(seconds: sourceOrigin + videoDelay + time * (1 - videoDelay),
                    preferredTimescale: 48_000), decodeTimeStamp: .invalid)
            var frame: CMSampleBuffer?
            try check(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixel!, formatDescription: format!, sampleTiming: &timing,
                sampleBufferOut: &frame) == noErr, "service screen buffer")
            await service.append(frame!, type: .screen)
            try check(service.failure == nil, "actual writer failed: \(String(describing: service.failure))")
        }
        let beforeComposite = directory.appendingPathComponent("before-composite-" + url.lastPathComponent)
        guard let result = try await service.finish(onProcessingStage: { stage in
            if stage == .processingAudio {
                try? FileManager.default.copyItem(at: url, to: beforeComposite)
            }
        }) else {
            throw TestFailure(message: "actual writer returned no movie")
        }
        try check(result.warning == nil, "finalization warning: \(String(describing: result.warning))")
        let asset = AVURLAsset(url: result.url)
        try await checkVideoStart(asset: AVURLAsset(url: beforeComposite))
        try await checkVideoStart(asset: asset)
        let duration = try await asset.load(.duration).seconds
        try check(abs(duration - 1) < 0.1, "service timeline stretched: \(duration)")
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try check(audio.count == (captureAudio ? (microphoneOnly ? 2 : 3) : 0), "source tracks/composite lost")
        for (index, track) in audio.enumerated() where index > 0 {
            let expectedRole: ScreenCapTrackRole = index == 1 && !microphoneOnly ? .systemAudio : .microphoneRaw
            let actualRole = await ScreenCapTrackMetadata.role(of: track)
            try check(actualRole == expectedRole, "source track was relabelled during finalization")
            let expectedStart = expectedRole == .systemAudio ? 0.0 : (0.06 - (microphoneOnly ? videoDelay : 0))
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(output)
            try check(reader.startReading(), "service audio decode")
            var samples = 0, energy = 0.0
            var firstPTS: Double?
            var earlySamples = 0, earlyEnergy = 0.0
            while let sample = output.copyNextSampleBuffer() {
                if firstPTS == nil { firstPTS = sample.presentationTimeStamp.seconds }
                guard let block = sample.dataBuffer else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                try check(CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                    totalLengthOut: &length, dataPointerOut: &pointer) == noErr, "service PCM decode")
                let data = UnsafeRawPointer(pointer!).assumingMemoryBound(to: Float.self)
                let format = CMAudioFormatDescriptionGetStreamBasicDescription(sample.formatDescription!)!.pointee
                for i in 0..<(length / 4) {
                    let e = Double(data[i] * data[i])
                    energy += e
                    samples += 1
                    let time = sample.presentationTimeStamp.seconds
                        + Double(i / Int(format.mChannelsPerFrame)) / format.mSampleRate
                    if expectedRole == .microphoneRaw, time < expectedStart - 0.025 {
                        earlySamples += 1
                        earlyEnergy += e
                    }
                }
            }
            try check(reader.status == .completed && samples > 0, "source audio empty/corrupt")
            // AVAssetReader may materialize the microphone's empty prefix as
            // silent PCM starting at zero. Inspect its audible content rather
            // than mistaking that padding for a timestamp shift. Allow AAC's
            // short pre-echo window around the actual 60 ms onset.
            try check((firstPTS ?? .infinity) >= 0 && (firstPTS ?? .infinity) <= expectedStart + 0.003,
                "source audio begins after its captured onset")
            if expectedRole == .microphoneRaw, earlySamples > 0 {
                try check(earlyEnergy / Double(earlySamples) < 0.00001,
                    "microphone speech shifted into its leading silent interval")
            }
            if expectedRole == .systemAudio && muteSystem {
                try check(energy / Double(samples) < 0.00001, "muted source became audible")
            } else {
                try check(energy / Double(samples) > 0.001, "audible source was lost")
            }
        }
        print("PASS actual writer + composite: \(url.lastPathComponent), duration=\(duration)s")
    }
    #endif

    static func terminalFailureTest(directory: URL, hasAudio: Bool) throws {
        let url = directory.appendingPathComponent("terminal-\(hasAudio).mov")
        var writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let source = try pcm(rate: 16_000, channels: 1, frames: 320, time: 0)
        var attempts = 0
        do {
            _ = try RecorderWriterStartup.start(writer: &writer, hasAudio: hasAudio) { candidate, _ in
                attempts += 1
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 192_000
                ], sourceFormatHint: source.formatDescription)
                candidate.add(input)
                return input
            }
            throw TestFailure(message: "unsupported settings unexpectedly accepted")
        } catch let error as NSError where error.domain == AVFoundationErrorDomain {
            try check(error.code == AVError.unsupportedOutputSettings.rawValue, "wrong terminal error")
            try check(attempts == (hasAudio ? 2 : 1), "unbounded retry or retry without audio")
        }
        writer.cancelWriting()
        print("PASS bounded terminal failure, audio=\(hasAudio), attempts=\(attempts)")
    }

    static func main() async {
        do { try await run() }
        catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screencap-startup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // Retain the tiny generated movies for inspection if a check fails.
        print("Test output: \(directory.path)")
        try check(RecorderAudioTimelineNormalizer.selfTest(), "normalizer regression")
        let variablePackets = RecorderAudioTimelineNormalizer(label: "variable-packet-test")
        _ = variablePackets.normalize(try pcm(rate: 16_000, channels: 1, frames: 320, time: 0))
        let longerPacket = variablePackets.normalize(try pcm(rate: 16_000, channels: 1, frames: 640, time: 0.02))
        let shorterPacket = variablePackets.normalize(try pcm(rate: 16_000, channels: 1, frames: 320, time: 0.06))
        try check(CMSampleBufferGetNumSamples(longerPacket) == 640
            && CMSampleBufferGetNumSamples(shorterPacket) == 320, "valid variable-sized audio packets were truncated")
        print("PASS valid variable-sized audio packets are preserved")
        let duplicateTimestamp = RecorderAudioTimelineNormalizer(label: "near-duplicate-test")
        _ = duplicateTimestamp.normalize(try pcm(rate: 16_000, channels: 1, frames: 640, time: 0))
        let nearlyDuplicate = duplicateTimestamp.normalize(try pcm(rate: 16_000, channels: 1, frames: 640, time: 0.001))
        try check(CMSampleBufferGetNumSamples(nearlyDuplicate) == 640, "near-duplicate PTS erased an audio packet")
        let routeChange = RecorderAudioTimelineNormalizer(label: "format-change-test")
        _ = routeChange.normalize(try pcm(rate: 16_000, channels: 1, frames: 640, time: 0))
        let newFormat = routeChange.normalize(try pcm(rate: 48_000, channels: 2, frames: 1_920, time: 0.02))
        try check(CMSampleBufferGetNumSamples(newFormat) == 1_920, "old-route timing truncated a new format")
        let unsupported = NSError(domain: AVFoundationErrorDomain, code: AVError.unsupportedOutputSettings.rawValue)
        try check(RecorderWriterStartup.canRetry(unsupported), "unsupported settings must retry")
        for error in [NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue),
                      NSError(domain: AVFoundationErrorDomain, code: AVError.encoderTemporarilyUnavailable.rawValue),
                      NSError(domain: AVFoundationErrorDomain, code: AVError.unsupportedOutputSettings.rawValue,
                        userInfo: [AVErrorMediaTypeKey: AVMediaType.video.rawValue]),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                      NSError(domain: AVFoundationErrorDomain, code: AVError.unsupportedOutputSettings.rawValue,
                        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])] {
            try check(!RecorderWriterStartup.canRetry(error), "non-configuration error must not retry")
        }
        try await encodingTest(directory: directory, forceFallback: false)
        try await encodingTest(directory: directory, forceFallback: true)
        try await encodingTest(directory: directory, forceFallback: true, overlap: true)
        try await encodingTest(directory: directory, forceFallback: false, videoDelay: 0.014, coverGap: false)
        try await encodingTest(directory: directory, forceFallback: false, videoDelay: 0.014)
        try await encodingTest(directory: directory, forceFallback: true, overlap: true, videoDelay: 0.35)
        try terminalFailureTest(directory: directory, hasAudio: true)
        try terminalFailureTest(directory: directory, hasAudio: false)
        #if SCREENCAP_RECORDER_INTEGRATION_TESTS
        try await writerServiceTest(directory: directory, videoDelay: 0.014, captureAudio: true)
        try await writerServiceTest(directory: directory, videoDelay: 0.35, captureAudio: true)
        try await writerServiceTest(directory: directory, videoDelay: 0.014, captureAudio: true, muteSystem: true)
        try await writerServiceTest(directory: directory, videoDelay: 0, captureAudio: false)
        try await writerServiceTest(directory: directory, videoDelay: 0.014, captureAudio: true, microphoneOnly: true)
        #endif
        print("PASS all recorder startup regression checks")
    }
}
