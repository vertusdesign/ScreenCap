import AppKit
import AVFoundation
import CoreMedia

@available(macOS 15.0, *)
enum RecorderOutputType: Hashable {
    case screen
    case systemAudio
    case microphone
}

@available(macOS 15.0, *)
enum RecorderState: Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case failed(String)
}

@available(macOS 15.0, *)
enum RecorderStartMode {
    case displayUnderPointer
    case displayPicker
}

@available(macOS 15.0, *)
struct RecordingCaptureOptions: Equatable {
    var systemAudio: Bool
    var microphone: Bool
    var noiseSuppression: Bool

    /// The picker starts from the saved recording preferences, then lets the
    /// user make a one-off choice for this recording without changing them.
    static var current: Self {
        Self(
            systemAudio: !Settings.shared.recordingSkipSystemAudio,
            microphone: !Settings.shared.recordingSkipMicrophone,
            noiseSuppression: Settings.shared.recordingNoiseSuppression
        )
    }
}

@available(macOS 15.0, *)
enum RecorderError: LocalizedError {
    case permissionDenied
    case noDisplay
    case noAudioTracks
    case diskSpaceLow(available: Int64)
    case captureFailed(String)
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L10n.t("error.permissionDenied")
        case .noDisplay:
            return L10n.t("error.noDisplays")
        case .noAudioTracks:
            return L10n.t("recording.failed")
        case .diskSpaceLow(let available):
            let gigabytes = Double(available) / 1_073_741_824
            return L10n.t("recording.diskSpaceLow", String(format: "%.1f", gigabytes))
        case .captureFailed(let reason):
            return L10n.t("error.captureFailed", reason)
        case .writerFailed(let reason):
            return L10n.t("recording.failed") + ": " + reason
        }
    }
}

@available(macOS 15.0, *)
struct RecorderDisplay {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int

    init?(screen: NSScreen, logicalSize: Bool = false) {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }

        let scale = logicalSize ? 1.0 : screen.backingScaleFactor
        let rawWidth = Int((screen.frame.width * scale).rounded())
        let rawHeight = Int((screen.frame.height * scale).rounded())
        guard rawWidth >= 2, rawHeight >= 2 else { return nil }

        displayID = number.uint32Value
        // H.264/HEVC require even dimensions. Keep the native Retina size and
        // trim only a possible odd final pixel.
        width = rawWidth.isMultiple(of: 2) ? rawWidth : rawWidth - 1
        height = rawHeight.isMultiple(of: 2) ? rawHeight : rawHeight - 1
    }
}

@available(macOS 15.0, *)
struct RecorderFile {
    let url: URL
    let width: Int
    let height: Int
}

@available(macOS 15.0, *)
enum RecorderFileNaming {
    static func makeFile(width: Int, height: Int) throws -> RecorderFile {
        let directory = Settings.shared.recordingDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH.mm.ss"
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"

        var name = Settings.shared.recordingFilenameTemplate
        name = name.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: now))
        name = name.replacingOccurrences(of: "{time}", with: timeFormatter.string(from: now))
        name = name.replacingOccurrences(of: "{timestamp}", with: stampFormatter.string(from: now))
        name = name.replacingOccurrences(of: "{width}", with: "\(width)")
        name = name.replacingOccurrences(of: "{height}", with: "\(height)")

        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        name = name.components(separatedBy: illegal).joined(separator: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Recording" }

        var url = directory.appendingPathComponent(name).appendingPathExtension("mov")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory
                .appendingPathComponent("\(name) (\(counter))")
                .appendingPathExtension("mov")
            counter += 1
        }
        return RecorderFile(url: url, width: width, height: height)
    }

    static func makeFile(
        url: URL,
        width: Int,
        height: Int
    ) throws -> RecorderFile {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return RecorderFile(url: url, width: width, height: height)
    }
}
