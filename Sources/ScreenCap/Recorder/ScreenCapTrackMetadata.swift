import AVFoundation

/// Stable, language-independent roles for ScreenCap audio streams.
///
/// Track titles are intended for people and can change with localization. The
/// role comment is deliberately stable so the Player can still identify a
/// raw/recovered recording after a post-processing interruption.
enum ScreenCapTrackRole: String, Codable, Sendable {
    case compositeAudio = "composite"
    case systemAudio = "system_audio"
    case microphoneRaw = "microphone_raw"
    case microphoneEchoReduced = "microphone_echo_reduced"
}

enum ScreenCapTrackMetadata {
    private static let schemaVersion = "1"
    private static let rolePrefix = "ScreenCapTrackRole="
    private static let schemaPrefix = "ScreenCapTrackSchema="

    static func metadata(
        role: ScreenCapTrackRole,
        displayName: String
    ) -> [AVMutableMetadataItem] {
        let name = AVMutableMetadataItem()
        name.keySpace = .quickTimeUserData
        name.key = AVMetadataKey.quickTimeUserDataKeyTrackName as NSString
        name.value = displayName as NSString

        let comment = AVMutableMetadataItem()
        comment.keySpace = .quickTimeUserData
        comment.key = AVMetadataKey.quickTimeUserDataKeyComment as NSString
        comment.value = "\(rolePrefix)\(role.rawValue);\(schemaPrefix)\(schemaVersion)" as NSString
        return [name, comment]
    }

    static func apply(
        role: ScreenCapTrackRole,
        displayName: String,
        to input: AVAssetWriterInput
    ) {
        input.metadata = metadata(role: role, displayName: displayName)
    }

    static func role(fromValue value: String) -> ScreenCapTrackRole? {
        parseRole(value)
    }

    static func role(of track: AVAssetTrack) async -> ScreenCapTrackRole? {
        for item in (try? await track.load(.metadata)) ?? [] {
            if let value = try? await item.load(.stringValue),
               let role = parseRole(value) { return role }
        }
        return nil
    }

    private static func parseRole(_ value: String) -> ScreenCapTrackRole? {
        if let token = value
            .split(separator: ";")
            .first(where: { $0.hasPrefix(rolePrefix) })?
            .dropFirst(rolePrefix.count),
           let role = ScreenCapTrackRole(rawValue: String(token)) {
            return role
        }
        return nil
    }
}
