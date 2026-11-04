import AVFoundation

/// Startup-only retry. No sample may be appended until this function returns.
/// A failed writer cannot be restarted, so rebuild it and all of its inputs
/// while keeping the caller's original sample queue and timeline intact.
@available(macOS 15.0, *)
enum RecorderWriterStartup {
    enum AudioProfile: String {
        case automatic
        case compatible

        func settings(bitRate: Int, sourceFormat: CMFormatDescription?) -> [String: Any] {
            var settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC]
            switch self {
            case .automatic:
                // AVAssetWriter can choose missing fields from sourceFormatHint.
                // Do not combine a low-rate Bluetooth input with a high fixed
                // AAC bitrate; e.g. 16 kHz + 192 kbps is rejected at startup.
                settings[AVEncoderBitRateKey] = bitRate
            case .compatible:
                let channels = sourceFormat.flatMap {
                    CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
                }
                if let channels, channels == 1 || channels == 2 {
                    // Resampling is the encoder's job. PCM sample counts and
                    // capture timestamps must remain in the source clock.
                    settings[AVSampleRateKey] = 48_000.0
                    settings[AVNumberOfChannelsKey] = Int(channels)
                    settings[AVEncoderBitRateKey] = Int(channels) * 64_000
                }
                // An unexpected multichannel source keeps its layout via the
                // hint and lets AVFoundation choose all encoding parameters.
                // Never silently downmix a user's source to enable a retry.
            }
            return settings
        }
    }

    static func start<InputState>(
        writer: inout AVAssetWriter,
        hasAudio: Bool,
        configure: (AVAssetWriter, AudioProfile) throws -> InputState
    ) throws -> InputState {
        for profile in [AudioProfile.automatic, .compatible] {
            let state = try configure(writer, profile)
            if writer.startWriting() {
                Log.diagnostic("recorder writer started audioProfile=\(profile.rawValue)")
                return state
            }

            let error = (writer.error as NSError?)
                ?? NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)
            Log.error("recorder writer startup rejected audioProfile=\(profile.rawValue) error=\(error)")
            guard profile == .automatic, hasAudio, canRetry(error) else { throw error }

            let url = writer.outputURL
            let fragmentInterval = writer.movieFragmentInterval
            writer.cancelWriting()
            // The caller has not submitted any media yet. Only this attempt's
            // empty/header-only partial file can be removed; final movies and
            // recovery markers are never touched by the retry.
            if FileManager.default.fileExists(atPath: url.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteFileExists.rawValue)
                }
                try FileManager.default.removeItem(at: url)
            }
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.movieFragmentInterval = fragmentInterval
            Log.diagnostic("recorder writer retrying with compatible AAC before first media sample")
        }
        throw NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)
    }

    static func canRetry(_ error: NSError) -> Bool {
        var current: NSError? = error
        var unsupportedSettings = false
        // Bound traversal even for malformed/cyclic NSError userInfo graphs.
        for _ in 0..<8 {
            guard let item = current else { return unsupportedSettings }
            if item.domain == NSPOSIXErrorDomain || item.domain == NSCocoaErrorDomain {
                return false // Permissions, missing volume and other I/O failures.
            }
            if item.domain == AVFoundationErrorDomain {
                if item.userInfo[AVErrorMediaTypeKey] as? String == AVMediaType.video.rawValue {
                    return false // An AAC retry cannot fix rejected video settings.
                }
                guard item.code == AVError.unsupportedOutputSettings.rawValue
                    || item.code == AVError.unknown.rawValue else { return false }
                unsupportedSettings = unsupportedSettings
                    || item.code == AVError.unsupportedOutputSettings.rawValue
            }
            current = item.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
