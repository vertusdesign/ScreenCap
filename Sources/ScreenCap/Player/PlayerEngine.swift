import AVFoundation
import Combine
import Foundation

@MainActor
final class PlayerEngine: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentURL: URL?
    @Published private(set) var duration: Double = 0
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var trimStart: Double = 0
    private var trimEnd: Double = .infinity
    private var mutedTracks = Set<PlayerTrackKind>()
    private var removedTracks = Set<PlayerTrackKind>()
    private var descriptors: [PlayerTrackDescriptor] = []

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = max(time.seconds.isFinite ? time.seconds : 0, 0)
                self.isPlaying = self.player.timeControlStatus == .playing
                if self.currentTime >= self.trimEnd - 0.02, self.trimEnd.isFinite, self.isPlaying {
                    self.player.pause()
                    self.currentTime = self.trimEnd
                }
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(url: URL, descriptors: [PlayerTrackDescriptor]) {
        currentURL = url
        errorMessage = nil
        self.descriptors = descriptors
        mutedTracks = Set(descriptors.filter(\.isMuted).map(\.kind))
        removedTracks = Set(descriptors.filter(\.isRemoved).map(\.kind))
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        duration = max(item.asset.duration.seconds.isFinite ? item.asset.duration.seconds : 0, 0)
        trimEnd = duration
        trimStart = 0
        currentTime = 0
        applyAudioMix()

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isPlaying = false }
        }
    }

    func playPause() {
        guard currentURL != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= trimEnd - 0.02 {
                seek(to: trimStart)
            }
            player.play()
        }
        isPlaying = !isPlaying
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), max(trimEnd, duration))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
    }

    func setTrim(start: Double, end: Double) {
        let clampedStart = min(max(0, start), max(duration, 0))
        let clampedEnd = min(max(clampedStart, end), max(duration, 0))
        trimEnd = clampedEnd
        trimStart = clampedStart
        if currentTime < clampedStart || currentTime > clampedEnd {
            seek(to: clampedStart)
        }
    }

    func setMuted(_ muted: Bool, for kind: PlayerTrackKind) {
        if muted { mutedTracks.insert(kind) } else { mutedTracks.remove(kind) }
        applyAudioMix()
    }

    func setRemoved(_ removed: Bool, for kind: PlayerTrackKind) {
        if removed { removedTracks.insert(kind) } else { removedTracks.remove(kind) }
    }

    func isMuted(_ kind: PlayerTrackKind) -> Bool {
        mutedTracks.contains(kind)
    }

    func exportEdited(to destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let currentURL else {
            completion(.failure(PlayerEngineError.noMedia))
            return
        }
        let sourceAsset = AVURLAsset(url: currentURL)
        let range = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            duration: CMTime(seconds: max((trimEnd.isFinite ? trimEnd : duration) - trimStart, 0), preferredTimescale: 600)
        )
        guard let editedAsset = makeEditedComposition(from: sourceAsset, timeRange: range),
              let exporter = AVAssetExportSession(asset: editedAsset.composition, presetName: AVAssetExportPresetHighestQuality)
        else {
            completion(.failure(PlayerEngineError.exportUnavailable))
            return
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        exporter.outputURL = destination
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        if let audioMix = buildAudioMix(for: editedAsset.composition.tracks(withMediaType: .audio), kinds: editedAsset.audioKinds) {
            exporter.audioMix = audioMix
        }
        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    completion(.success(destination))
                case .cancelled:
                    completion(.failure(PlayerEngineError.exportCancelled))
                default:
                    completion(.failure(exporter.error ?? PlayerEngineError.exportFailed))
                }
            }
        }
    }

    private func applyAudioMix() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        guard let mix = buildAudioMix(
                  for: asset.tracks(withMediaType: .audio),
                  kinds: audioKinds(count: asset.tracks(withMediaType: .audio).count)
              ) else { return }
        item.audioMix = mix
    }

    private func buildAudioMix(for audioTracks: [AVAssetTrack], kinds: [PlayerTrackKind]) -> AVAudioMix? {
        guard !audioTracks.isEmpty else { return nil }

        let compositeMuted = mutedTracks.contains(.compositeAudio)
        let parameters = audioTracks.enumerated().map { index, track in
            let parameter = AVMutableAudioMixInputParameters(track: track)
            let kind = index < kinds.count ? kinds[index] : .systemAudio
            let muted = compositeMuted || mutedTracks.contains(kind)
            parameter.setVolume(muted ? 0 : 1, at: .zero)
            return parameter
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private func audioKinds(count: Int) -> [PlayerTrackKind] {
        guard count > 0 else { return [] }
        return (0..<count).map {
            if $0 == 0 { return .compositeAudio }
            return $0 == 1 ? .systemAudio : .microphone
        }
    }

    private func makeEditedComposition(
        from asset: AVAsset,
        timeRange: CMTimeRange
    ) -> (composition: AVMutableComposition, audioKinds: [PlayerTrackKind])? {
        let composition = AVMutableComposition()
        do {
            if let video = asset.tracks(withMediaType: .video).first,
               let target = composition.addMutableTrack(
                   withMediaType: .video,
                   preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try target.insertTimeRange(timeRange, of: video, at: .zero)
                target.preferredTransform = video.preferredTransform
            }

            let sourceAudio = asset.tracks(withMediaType: .audio)
            let kinds = audioKinds(count: sourceAudio.count)
            var activeKinds: [PlayerTrackKind] = []
            for (index, source) in sourceAudio.enumerated() {
                let kind = index < kinds.count ? kinds[index] : .systemAudio
                guard !removedTracks.contains(kind) else { continue }
                guard let target = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                try target.insertTimeRange(timeRange, of: source, at: .zero)
                activeKinds.append(kind)
            }
            return (composition, activeKinds)
        } catch {
            return nil
        }
    }

}

enum PlayerEngineError: LocalizedError {
    case noMedia
    case exportUnavailable
    case exportCancelled
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noMedia: return "No video is loaded."
        case .exportUnavailable: return "This video cannot be exported on this Mac."
        case .exportCancelled: return "Export was cancelled."
        case .exportFailed: return "The edited video could not be exported."
        }
    }
}
