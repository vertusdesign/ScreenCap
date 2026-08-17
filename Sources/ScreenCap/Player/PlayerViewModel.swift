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
    @Published var isTrackEditorVisible = true
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published private(set) var isDirty = false
    @Published var transcriptionMode: PlayerTranscriptionMode {
        didSet { Settings.shared.playerTranscriptionMode = transcriptionMode }
    }
    @Published var pendingTrackRemoval: PlayerTrackKind?

    private var undoStack: [PlayerEditSnapshot] = []
    private var redoStack: [PlayerEditSnapshot] = []
    private var mutedTracks = Set<PlayerTrackKind>()
    private var baselineMutedTracks = Set<PlayerTrackKind>()
    private var removedTracks = Set<PlayerTrackKind>()
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
        selectedRecording = recording
        let info = PlayerMediaInspector.inspect(url: recording.url)
        tracks = PlayerMediaInspector.tracks(url: recording.url)
        trimStart = 0
        trimEnd = info?.duration ?? 0
        mutedTracks = Set(tracks.filter(\.isMuted).map(\.kind))
        baselineMutedTracks = mutedTracks
        removedTracks = []
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
        if let existing = library.recordings.first(where: { $0.url.standardizedFileURL == canonical }) {
            select(existing)
        } else if let added = library.addVideo(url: canonical) {
            select(added)
        }
    }

    func toggleTrackMute(_ kind: PlayerTrackKind) {
        guard kind.isAudio else { return }
        pushUndoSnapshot()
        let muted = !mutedTracks.contains(kind)
        if muted { mutedTracks.insert(kind) } else { mutedTracks.remove(kind) }
        engine.setMuted(muted, for: kind)
        updateDescriptors()
        markDirty()
    }

    func requestRemoveTrack(_ kind: PlayerTrackKind) {
        guard kind.isAudio, !kind.isDerived else { return }
        pendingTrackRemoval = kind
    }

    func confirmRemoveTrack() {
        guard let kind = pendingTrackRemoval else { return }
        pendingTrackRemoval = nil
        pushUndoSnapshot()
        removedTracks.insert(kind)
        mutedTracks.insert(kind)
        engine.setMuted(true, for: kind)
        engine.setRemoved(true, for: kind)
        updateDescriptors()
        markDirty()
    }

    func cancelRemoveTrack() {
        pendingTrackRemoval = nil
    }

    func setTrim(start: Double, end: Double) {
        let safeStart = min(max(start, 0), max(duration, 0))
        let safeEnd = min(max(end, safeStart), max(duration, 0))
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
        guard let selectedRecording else { return }
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
        apply(PlayerEditSnapshot(trimStart: 0, trimEnd: duration, mutedTracks: baselineMutedTracks, removedTracks: []))
    }

    func markSaved() {
        isDirty = false
        baselineMutedTracks = mutedTracks
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func exportEditedCopy() {
        guard let selectedRecording else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = selectedRecording.url.deletingPathExtension().lastPathComponent + " Edited.mov"
        panel.directoryURL = selectedRecording.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        export(to: destination, replacingOriginal: false)
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

    private func export(to destination: URL, replacingOriginal: Bool) {
        engine.exportEdited(to: destination) { [weak self] result in
            switch result {
            case .success:
                self?.markSaved()
                Feedback.flash(message: replacingOriginal
                    ? L10n.t("player.export.replaced")
                    : L10n.t("player.export.complete"))
            case .failure(let error):
                Feedback.flash(message: L10n.t("player.export.failed"), subtitle: error.localizedDescription)
            }
        }
    }

    private var currentSnapshot: PlayerEditSnapshot {
        PlayerEditSnapshot(
            trimStart: trimStart,
            trimEnd: trimEnd,
            mutedTracks: mutedTracks,
            removedTracks: removedTracks
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
        engine.setTrim(start: trimStart, end: trimEnd)
        for kind in PlayerTrackKind.allCases where kind.isAudio {
            engine.setMuted(mutedTracks.contains(kind) || removedTracks.contains(kind), for: kind)
            engine.setRemoved(removedTracks.contains(kind), for: kind)
        }
        updateDescriptors()
        isDirty = snapshot != PlayerEditSnapshot(
            trimStart: 0,
            trimEnd: duration,
            mutedTracks: baselineMutedTracks,
            removedTracks: []
        )
    }

    private func updateDescriptors() {
        tracks = tracks.map { descriptor in
            var copy = descriptor
            copy.isMuted = mutedTracks.contains(descriptor.kind)
            copy.isRemoved = removedTracks.contains(descriptor.kind)
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
