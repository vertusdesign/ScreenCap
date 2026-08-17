import AppKit
import Combine
import Foundation

@MainActor
final class PlayerViewModel: ObservableObject {
    let library: PlayerLibraryStore
    let engine: PlayerEngine
    let transcription: PlayerTranscriptionCoordinator

    @Published private(set) var selectedRecording: PlayerRecording?
    @Published private(set) var tracks: [PlayerTrackDescriptor] = []
    @Published var isTrackEditorVisible = false
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published private(set) var isDirty = false
    @Published private(set) var compositeRebuildRequested = false
    /// A video opened through Finder, a notification or the after-recording
    /// action. It must wait for the same save/discard decision as a sidebar
    /// switch when the current recording has an unsaved draft.
    @Published private(set) var pendingSelection: PlayerRecording?
    @Published private(set) var pendingPlaylistRemoval: PlayerPlaylistRemoval?
    @Published var transcriptionMode: PlayerTranscriptionMode {
        didSet { Settings.shared.playerTranscriptionMode = transcriptionMode }
    }
    @Published var pendingTrackRemoval: PlayerTrackID?

    private var undoStack: [PlayerEditSnapshot] = []
    private var redoStack: [PlayerEditSnapshot] = []
    private var mutedTracks = Set<PlayerTrackID>()
    private var baselineMutedTracks = Set<PlayerTrackID>()
    private var removedTracks = Set<PlayerTrackID>()
    private var volumes = [PlayerTrackID: Double]()
    private var baselineVolumes = [PlayerTrackID: Double]()
    private var baselineCompositeRebuildRequested = false
    private var cancellables = Set<AnyCancellable>()

    init(library: PlayerLibraryStore, engine: PlayerEngine) {
        self.library = library
        self.engine = engine
        self.transcription = PlayerTranscriptionCoordinator()
        self.transcriptionMode = Settings.shared.playerTranscriptionMode
        library.$recordings
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    convenience init() {
        self.init(library: PlayerLibraryStore.shared, engine: PlayerEngine())
    }

    var currentTime: Double { engine.currentTime }
    var duration: Double { engine.duration }
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var currentTimeText: String { Self.formatTime(currentTime) }
    var durationText: String { Self.formatTime(duration) }

    func select(_ recording: PlayerRecording) {
        guard let info = PlayerMediaInspector.inspect(url: recording.url) else {
            Feedback.flash(message: L10n.t("player.open.failed"))
            library.reload()
            return
        }
        selectedRecording = recording
        tracks = PlayerMediaInspector.tracks(url: recording.url)
        trimStart = 0
        trimEnd = info.duration
        mutedTracks = Set(tracks.filter(\.isMuted).map(\.trackID))
        baselineMutedTracks = mutedTracks
        removedTracks = []
        volumes = Dictionary(uniqueKeysWithValues: tracks.map { ($0.trackID, $0.volume) })
        baselineVolumes = volumes
        compositeRebuildRequested = false
        baselineCompositeRebuildRequested = false
        undoStack.removeAll()
        redoStack.removeAll()
        isDirty = false
        engine.load(url: recording.url, descriptors: tracks)
        scheduleAutomaticTranscription(for: recording)
    }

    func select(url: URL) {
        let canonical = url.standardizedFileURL
        guard PlayerMediaInspector.inspect(url: canonical) != nil else {
            Feedback.flash(message: L10n.t("player.open.failed"))
            return
        }
        let recordingDirectory = Settings.shared.recordingDirectory.standardizedFileURL
        if canonical.path == recordingDirectory.appendingPathComponent(canonical.lastPathComponent).path ||
            canonical.path.hasPrefix(recordingDirectory.path + "/") {
            _ = library.addFolder(url: canonical.deletingLastPathComponent())
        }
        let target: PlayerRecording?
        if let existing = library.recordings.first(where: { $0.url.standardizedFileURL == canonical }) {
            target = existing
        } else {
            target = library.addVideo(url: canonical)
        }
        guard let target else {
            Feedback.flash(message: L10n.t("player.open.failed"))
            return
        }
        guard selectedRecording?.id != target.id else {
            pendingSelection = nil
            return
        }
        guard !isDirty else {
            pendingSelection = target
            return
        }
        select(target)
    }

    func confirmPendingSelectionAfterSave() {
        guard let pendingSelection else { return }
        self.pendingSelection = nil
        select(pendingSelection)
    }

    func discardEditsAndSelectPending() {
        guard let pendingSelection else { return }
        self.pendingSelection = nil
        select(pendingSelection)
    }

    func cancelPendingSelection() {
        pendingSelection = nil
    }

    func toggleTrackMute(_ trackID: PlayerTrackID) {
        guard trackID.kind.isAudio, !removedTracks.contains(trackID) else { return }
        pushUndoSnapshot()
        let muted = !mutedTracks.contains(trackID)
        if muted { mutedTracks.insert(trackID) } else { mutedTracks.remove(trackID) }
        engine.setMuted(muted, for: trackID)
        updateDescriptors()
        markDirty()
    }

    func setTrackVolume(_ volume: Double, for trackID: PlayerTrackID) {
        guard trackID.kind.isAudio, !removedTracks.contains(trackID) else { return }
        let value = min(max(volume, 0), 4)
        guard abs((volumes[trackID] ?? 1) - value) > 0.005 else { return }
        pushUndoSnapshot()
        volumes[trackID] = value
        engine.setVolume(value, for: trackID)
        updateDescriptors()
        markDirty()
    }

    func rebuildComposite() {
        let rawTracks = tracks.filter { $0.kind != .video && !$0.kind.isDerived && !$0.isRemoved }
        guard !rawTracks.isEmpty else {
            Feedback.flash(message: L10n.t("player.composite.unavailable"))
            return
        }
        pushUndoSnapshot()
        if let composite = tracks.first(where: { $0.kind == .compositeAudio }) {
            removedTracks.remove(composite.trackID)
            mutedTracks.remove(composite.trackID)
            engine.setRemoved(false, for: composite.trackID)
            engine.setMuted(false, for: composite.trackID)
        }
        compositeRebuildRequested = true
        engine.setCompositeRebuildRequested(true)
        markDirty()
        Feedback.flash(message: L10n.t("player.composite.rebuild.ready"))
    }

    func requestRemoveTrack(_ trackID: PlayerTrackID) {
        guard trackID.kind.isAudio,
              tracks.contains(where: { $0.trackID == trackID && !$0.isRemoved })
        else { return }
        pendingTrackRemoval = trackID
    }

    func confirmRemoveTrack() {
        guard let trackID = pendingTrackRemoval else { return }
        pendingTrackRemoval = nil
        pushUndoSnapshot()
        removedTracks.insert(trackID)
        mutedTracks.insert(trackID)
        engine.setMuted(true, for: trackID)
        engine.setRemoved(true, for: trackID)
        updateDescriptors()
        markDirty()
    }

    func cancelRemoveTrack() {
        pendingTrackRemoval = nil
    }

    var removingLastAudioTrack: Bool {
        guard pendingTrackRemoval != nil else { return false }
        return tracks.filter { $0.kind.isAudio && !$0.isRemoved }.count <= 1
    }

    func setTrim(start: Double, end: Double) {
        let safeStart = min(max(start, 0), max(duration, 0))
        let safeEnd = min(max(end, safeStart), max(duration, 0))
        guard safeEnd > safeStart + 0.01 else {
            Feedback.flash(message: L10n.t("player.trim.invalid"))
            return
        }
        guard abs(trimStart - safeStart) > 0.01 || abs(trimEnd - safeEnd) > 0.01 else { return }
        pushUndoSnapshot()
        trimStart = safeStart
        trimEnd = safeEnd
        engine.setTrim(start: safeStart, end: safeEnd)
        markDirty()
    }

    func seek(to fraction: Double) {
        engine.seek(to: fraction * duration)
    }

    func transcribeSelected() {
        guard let selectedRecording else {
            Feedback.flash(message: L10n.t("player.transcript.noSelection"))
            return
        }
        guard !transcription.state.isBusy else { return }
        transcription.transcribe(url: selectedRecording.url)
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        apply(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        apply(snapshot)
    }

    func resetEdits() {
        guard isDirty else { return }
        pushUndoSnapshot()
        apply(PlayerEditSnapshot(
            trimStart: 0,
            trimEnd: duration,
            mutedTracks: baselineMutedTracks,
            removedTracks: [],
            volumes: baselineVolumes,
            compositeRebuildRequested: baselineCompositeRebuildRequested
        ))
    }

    func markSaved() {
        isDirty = false
        baselineMutedTracks = mutedTracks
        baselineVolumes = volumes
        baselineCompositeRebuildRequested = compositeRebuildRequested
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func exportEditedCopy(completion: ((Bool) -> Void)? = nil) {
        guard let selectedRecording else {
            completion?(false)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = selectedRecording.url.deletingPathExtension().lastPathComponent + " Edited.mov"
        panel.directoryURL = selectedRecording.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else {
            completion?(false)
            return
        }
        export(to: destination, replacingOriginal: false, completion: completion)
    }

    func replaceOriginal() {
        guard let selectedRecording else { return }
        let original = selectedRecording.url
        engine.pause()
        let temporary = original
            .deletingLastPathComponent()
            .appendingPathComponent(".\(original.deletingPathExtension().lastPathComponent).screencap-editing-\(UUID().uuidString).mov")
        engine.exportEdited(to: temporary) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                do {
                    _ = try FileManager.default.replaceItemAt(
                        original,
                        withItemAt: temporary,
                        backupItemName: nil,
                        options: []
                    )
                    self.library.reload()
                    if let refreshed = self.library.recordings.first(where: {
                        $0.url.standardizedFileURL == original.standardizedFileURL
                    }) {
                        self.select(refreshed)
                    } else {
                        self.markSaved()
                    }
                    Feedback.flash(message: L10n.t("player.export.replaced"))
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    Feedback.flash(message: L10n.t("player.export.failed"), subtitle: error.localizedDescription)
                }
            case .failure(let error):
                try? FileManager.default.removeItem(at: temporary)
                Feedback.flash(message: L10n.t("player.export.failed"), subtitle: error.localizedDescription)
            }
        }
    }

    private func export(
        to destination: URL,
        replacingOriginal: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        engine.exportEdited(to: destination) { [weak self] result in
            switch result {
            case .success:
                self?.markSaved()
                completion?(true)
                Feedback.flash(message: replacingOriginal
                    ? L10n.t("player.export.replaced")
                    : L10n.t("player.export.complete"))
            case .failure(let error):
                completion?(false)
                Feedback.flash(message: L10n.t("player.export.failed"), subtitle: error.localizedDescription)
            }
        }
    }

    func requestRemoveFromPlaylist(_ recording: PlayerRecording) {
        guard selectedRecording?.id == recording.id, isDirty else {
            removeFromPlaylist(recording)
            return
        }
        pendingPlaylistRemoval = .recording(recording)
    }

    func requestRemoveFromPlaylist(_ source: PlayerLibrarySource) {
        guard selectedRecording?.sourceID == source.id, isDirty else {
            removeFromPlaylist(source)
            return
        }
        pendingPlaylistRemoval = .source(source)
    }

    func confirmPlaylistRemoval() {
        guard let pendingPlaylistRemoval else { return }
        self.pendingPlaylistRemoval = nil
        switch pendingPlaylistRemoval {
        case .recording(let recording): removeFromPlaylist(recording)
        case .source(let source): removeFromPlaylist(source)
        }
    }

    func cancelPlaylistRemoval() {
        pendingPlaylistRemoval = nil
    }

    private func removeFromPlaylist(_ recording: PlayerRecording) {
        if selectedRecording?.id == recording.id { clearSelection() }
        library.removeRecording(recording)
    }

    private func removeFromPlaylist(_ source: PlayerLibrarySource) {
        if selectedRecording?.sourceID == source.id { clearSelection() }
        library.removeSource(source)
    }

    private func clearSelection() {
        transcription.cancel()
        engine.clear()
        selectedRecording = nil
        pendingSelection = nil
        tracks = []
        trimStart = 0
        trimEnd = 0
        mutedTracks.removeAll()
        baselineMutedTracks.removeAll()
        removedTracks.removeAll()
        volumes.removeAll()
        baselineVolumes.removeAll()
        compositeRebuildRequested = false
        baselineCompositeRebuildRequested = false
        undoStack.removeAll()
        redoStack.removeAll()
        isDirty = false
    }

    private var currentSnapshot: PlayerEditSnapshot {
        PlayerEditSnapshot(
            trimStart: trimStart,
            trimEnd: trimEnd,
            mutedTracks: mutedTracks,
            removedTracks: removedTracks,
            volumes: volumes,
            compositeRebuildRequested: compositeRebuildRequested
        )
    }

    private func pushUndoSnapshot() {
        undoStack.append(currentSnapshot)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func apply(_ snapshot: PlayerEditSnapshot) {
        trimStart = snapshot.trimStart
        trimEnd = snapshot.trimEnd
        mutedTracks = snapshot.mutedTracks
        removedTracks = snapshot.removedTracks
        volumes = snapshot.volumes
        compositeRebuildRequested = snapshot.compositeRebuildRequested
        engine.setTrim(start: trimStart, end: trimEnd)
        for track in tracks where track.kind.isAudio {
            engine.setMuted(
                mutedTracks.contains(track.trackID) || removedTracks.contains(track.trackID),
                for: track.trackID
            )
            engine.setVolume(volumes[track.trackID] ?? 1, for: track.trackID)
            engine.setRemoved(removedTracks.contains(track.trackID), for: track.trackID)
        }
        engine.setCompositeRebuildRequested(compositeRebuildRequested)
        updateDescriptors()
        isDirty = snapshot != PlayerEditSnapshot(
            trimStart: 0,
            trimEnd: duration,
            mutedTracks: baselineMutedTracks,
            removedTracks: [],
            volumes: baselineVolumes,
            compositeRebuildRequested: baselineCompositeRebuildRequested
        )
    }

    private func updateDescriptors() {
        tracks = tracks.map { descriptor in
            var copy = descriptor
            copy.isMuted = mutedTracks.contains(descriptor.trackID)
            copy.isRemoved = removedTracks.contains(descriptor.trackID)
            copy.volume = volumes[descriptor.trackID] ?? 1
            return copy
        }
    }

    private func markDirty() {
        isDirty = true
    }

    private func scheduleAutomaticTranscription(for recording: PlayerRecording) {
        guard transcriptionMode == .automatic else { return }
        let id = recording.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, self.selectedRecording?.id == id else { return }
            self.transcription.transcribe(url: recording.url)
        }
    }

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = max(Int(seconds.rounded(.down)), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
