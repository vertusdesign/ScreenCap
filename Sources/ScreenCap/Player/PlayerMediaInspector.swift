import AVFoundation
import AppKit

@MainActor
enum PlayerMediaInspector {
    static func inspect(url: URL) -> PlayerMediaInfo? {
        let asset = AVURLAsset(url: url)
        let videoTracks = asset.tracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { return nil }
        let duration = asset.duration.seconds.isFinite ? max(asset.duration.seconds, 0) : 0
        let size = videoTracks.first?.naturalSize ?? .zero
        return PlayerMediaInfo(
            duration: duration,
            naturalSize: size,
            videoTrackCount: videoTracks.count,
            audioTrackCount: asset.tracks(withMediaType: .audio).count
        )
    }

    static func tracks(url: URL) -> [PlayerTrackDescriptor] {
        let asset = AVURLAsset(url: url)
        let audioTracks = asset.tracks(withMediaType: .audio)
        var result: [PlayerTrackDescriptor] = [
            PlayerTrackDescriptor(
                kind: .video,
                title: L10n.t("player.track.video"),
                subtitle: nil,
                index: nil,
                isMuted: false,
                isRemoved: false
            )
        ]
        guard !audioTracks.isEmpty else { return result }

        result.append(
            PlayerTrackDescriptor(
                kind: .compositeAudio,
                title: L10n.t("player.track.composite"),
                subtitle: L10n.t("player.track.composite.subtitle"),
                index: 0,
                isMuted: false,
                isRemoved: false
            )
        )

        // ScreenCap's post-processor writes the mixed/composite stream first,
        // followed by the original system-audio and microphone streams. Keeping
        // the physical index on the descriptor prevents the editor from ever
        // confusing a composite row with a raw source row.
        for rawIndex in audioTracks.dropFirst().indices {
            let kind: PlayerTrackKind = rawIndex == 1 ? .systemAudio : .microphone
            let titleKey = rawIndex == 1 ? "player.track.systemAudio" : "player.track.microphone"
            result.append(
                PlayerTrackDescriptor(
                    kind: kind,
                    title: L10n.t(titleKey),
                    subtitle: rawIndex > 2 ? L10n.t("player.track.audio.index", rawIndex) : nil,
                    index: rawIndex,
                    // The composite stream is the ordinary listening mix. Raw
                    // tracks start muted so playback never doubles the audio;
                    // users can unmute one to audition it in the editor.
                    isMuted: true,
                    isRemoved: false
                )
            )
        }
        return result
    }

    static func thumbnails(url: URL, count: Int = 12) async -> [NSImage] {
        let asset = AVURLAsset(url: url)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 140)

        var images: [NSImage] = []
        images.reserveCapacity(count)
        for index in 0..<count {
            let seconds = duration * (Double(index) / Double(max(count - 1, 1)))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                images.append(NSImage(cgImage: image, size: .zero))
            }
        }
        return images
    }
}
