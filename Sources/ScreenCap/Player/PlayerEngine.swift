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
    private var mutedTracks = Set<PlayerTrackID>()
    private var removedTracks = Set<PlayerTrackID>()
    private var trackVolumes: [PlayerTrackID: Double] = [:]
    private var compositeRebuildRequested = false
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
        mutedTracks = Set(descriptors.filter(\.isMuted).map(\.trackID))
        removedTracks = Set(descriptors.filter(\.isRemoved).map(\.trackID))
        trackVolumes = Dictionary(uniqueKeysWithValues: descriptors.map {
            ($0.trackID, min(max($0.volume, 0), 4))
        })
        compositeRebuildRequested = false
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

    func setMuted(_ muted: Bool, for trackID: PlayerTrackID) {
        if muted { mutedTracks.insert(trackID) } else { mutedTracks.remove(trackID) }
        applyAudioMix()
    }

    func setRemoved(_ removed: Bool, for trackID: PlayerTrackID) {
        if removed { removedTracks.insert(trackID) } else { removedTracks.remove(trackID) }
        applyAudioMix()
    }

    func setVolume(_ volume: Double, for trackID: PlayerTrackID) {
        trackVolumes[trackID] = min(max(volume, 0), 4)
        applyAudioMix()
    }

    func volume(for trackID: PlayerTrackID) -> Double {
        trackVolumes[trackID] ?? 1
    }

    /// The preview is rebuilt from raw sources while the original composite
    /// track is silenced. Export uses the same source/gain decision to render a
    /// new physical composite track before trimming.
    func setCompositeRebuildRequested(_ requested: Bool) {
        compositeRebuildRequested = requested
        applyAudioMix()
    }

    var shouldRebuildComposite: Bool { compositeRebuildRequested }

    var currentTrackVolumes: [PlayerTrackID: Double] { trackVolumes }
    var currentMutedTracks: Set<PlayerTrackID> { mutedTracks }
    var currentRemovedTracks: Set<PlayerTrackID> { removedTracks }

    func isMuted(_ trackID: PlayerTrackID) -> Bool {
        mutedTracks.contains(trackID)
    }

    func exportEdited(to destination: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let currentURL else {
            completion(.failure(PlayerEngineError.noMedia))
            return
        }
        guard destination.isFileURL else {
            completion(.failure(PlayerEngineError.destinationUnavailable))
            return
        }
        guard destination.standardizedFileURL != currentURL.standardizedFileURL else {
            completion(.failure(PlayerEngineError.sameAsSource))
            return
        }
        let sourceAsset = AVURLAsset(url: currentURL)
        guard trimStart.isFinite,
              trimEnd.isFinite,
              trimEnd > trimStart + 0.01
        else {
            completion(.failure(PlayerEngineError.emptyTimeRange))
            return
        }
        let range = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            duration: CMTime(seconds: max((trimEnd.isFinite ? trimEnd : duration) - trimStart, 0), preferredTimescale: 600)
        )
        let volumes = trackVolumes
        let muted = mutedTracks
        let removed = removedTracks
        let rebuild = compositeRebuildRequested
        var mutedForExport = muted
        if rebuild {
            for track in descriptors where track.kind == .systemAudio || track.kind == .microphone {
                mutedForExport.insert(track.trackID)
            }
        }
        Task { [weak self] in
            var rebuiltURL: URL?
            defer {
                if let rebuiltURL { try? FileManager.default.removeItem(at: rebuiltURL) }
            }
            do {
                guard let self else {
                    completion(.failure(PlayerEngineError.noMedia))
                    return
                }
                var exportSource = sourceAsset
                if rebuild {
                    let url = try await PlayerCompositeRebuilder.rebuild(
                        sourceURL: currentURL,
                        volumes: volumes,
                        removedTracks: removed
                    )
                    rebuiltURL = url
                    exportSource = AVURLAsset(url: url)
                }
                try await self.export(
                    asset: exportSource,
                    timeRange: range,
                    destination: destination,
                    volumes: volumes,
                    mutedTracks: mutedForExport,
                    removedTracks: removed,
                    completion: completion
                )
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        destination: URL,
        volumes: [PlayerTrackID: Double],
        mutedTracks: Set<PlayerTrackID>,
        removedTracks: Set<PlayerTrackID>,
        completion: @escaping (Result<URL, Error>) -> Void
    ) async throws {
        guard let editedAsset = makeEditedComposition(
            from: asset,
            timeRange: timeRange,
            removedTracks: removedTracks
        ),
              let exporter = AVAssetExportSession(asset: editedAsset.composition, presetName: AVAssetExportPresetHighestQuality)
        else {
            throw PlayerEngineError.exportUnavailable
        }
        let parentDirectory = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw PlayerEngineError.destinationUnavailable
        }
        let staging = parentDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).screencap-exporting-\(UUID().uuidString).mov"
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        exporter.outputURL = staging
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        if let audioMix = buildAudioMix(
            for: editedAsset.composition.tracks(withMediaType: .audio),
            trackIDs: editedAsset.audioTrackIDs,
            volumes: volumes,
            mutedTracks: mutedTracks
        ) {
            exporter.audioMix = audioMix
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: PlayerEngineError.exportCancelled)
                default:
                    continuation.resume(throwing: exporter.error ?? PlayerEngineError.exportFailed)
                }
            }
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        } catch {
            throw PlayerEngineError.exportCommitFailed(error.localizedDescription)
        }
        completion(.success(destination))
    }

    private func applyAudioMix() {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        guard let mix = buildAudioMix(
                  for: asset.tracks(withMediaType: .audio),
                  trackIDs: audioTrackIDs(count: asset.tracks(withMediaType: .audio).count)
              ) else { return }
        item.audioMix = mix
    }

    private func buildAudioMix(for audioTracks: [AVAssetTrack], trackIDs: [PlayerTrackID]) -> AVAudioMix? {
        guard !audioTracks.isEmpty else { return nil }

        let parameters = audioTracks.enumerated().map { index, track in
            let parameter = AVMutableAudioMixInputParameters(track: track)
            let trackID = index < trackIDs.count ? trackIDs[index] : PlayerTrackID.audio(physicalIndex: index)
            let isRebuilding = compositeRebuildRequested && audioTracks.count > 1
            let muted = isRebuilding
                ? (trackID.kind == .compositeAudio || removedTracks.contains(trackID))
                : mutedTracks.contains(trackID) || removedTracks.contains(trackID)
            let masterVolume = trackVolumes[PlayerTrackID.audio(physicalIndex: 0)] ?? 1
            let volume = isRebuilding && trackID.kind != .compositeAudio
                ? (trackVolumes[trackID] ?? 1) * masterVolume
                : (trackVolumes[trackID] ?? 1)
            parameter.setVolume(Float(muted ? 0 : volume), at: .zero)
            return parameter
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private func buildAudioMix(
        for audioTracks: [AVAssetTrack],
        trackIDs: [PlayerTrackID],
        volumes: [PlayerTrackID: Double],
        mutedTracks: Set<PlayerTrackID>
    ) -> AVAudioMix? {
        guard !audioTracks.isEmpty else { return nil }
        let parameters = audioTracks.enumerated().map { index, track in
            let parameter = AVMutableAudioMixInputParameters(track: track)
            let trackID = index < trackIDs.count ? trackIDs[index] : PlayerTrackID.audio(physicalIndex: index)
            let volume = min(max(volumes[trackID] ?? 1, 0), 4)
            parameter.setVolume(Float(mutedTracks.contains(trackID) ? 0 : volume), at: .zero)
            return parameter
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private func audioTrackIDs(count: Int) -> [PlayerTrackID] {
        guard count > 0 else { return [] }
        return (0..<count).map(PlayerTrackID.audio(physicalIndex:))
    }

    private func makeEditedComposition(
        from asset: AVAsset,
        timeRange: CMTimeRange,
        removedTracks: Set<PlayerTrackID>
    ) -> (composition: AVMutableComposition, audioTrackIDs: [PlayerTrackID])? {
        let composition = AVMutableComposition()
        do {
            guard let video = asset.tracks(withMediaType: .video).first,
                  let videoTarget = composition.addMutableTrack(
                      withMediaType: .video,
                      preferredTrackID: kCMPersistentTrackID_Invalid
                  )
            else { return nil }
            try videoTarget.insertTimeRange(timeRange, of: video, at: .zero)
            videoTarget.preferredTransform = video.preferredTransform

            let sourceAudio = asset.tracks(withMediaType: .audio)
            let trackIDs = audioTrackIDs(count: sourceAudio.count)
            var activeTrackIDs: [PlayerTrackID] = []
            for (index, source) in sourceAudio.enumerated() {
                let trackID = index < trackIDs.count ? trackIDs[index] : PlayerTrackID.audio(physicalIndex: index)
                guard !removedTracks.contains(trackID) else { continue }
                guard let target = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else { continue }
                try target.insertTimeRange(timeRange, of: source, at: .zero)
                activeTrackIDs.append(trackID)
            }
            return (composition, activeTrackIDs)
        } catch {
            return nil
        }
    }

}

enum PlayerEngineError: LocalizedError {
    case noMedia
    case destinationUnavailable
    case sameAsSource
    case emptyTimeRange
    case exportUnavailable
    case exportCancelled
    case exportFailed
    case exportCommitFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMedia: return "No video is loaded."
        case .destinationUnavailable: return "The export destination is not available."
        case .sameAsSource: return "Choose a new file name; replacing the original uses the Replace Original action."
        case .emptyTimeRange: return "The selected trim range is empty."
        case .exportUnavailable: return "This video cannot be exported on this Mac."
        case .exportCancelled: return "Export was cancelled."
        case .exportFailed: return "The edited video could not be exported."
        case .exportCommitFailed(let message): return "The export finished, but the destination could not be updated: \(message)"
        }
    }
}
