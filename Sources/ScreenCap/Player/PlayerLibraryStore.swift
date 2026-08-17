import Foundation
import Combine

@MainActor
final class PlayerLibraryStore: ObservableObject {
    static let shared = PlayerLibraryStore()

    @Published private(set) var sources: [PlayerLibrarySource] = []
    @Published private(set) var recordings: [PlayerRecording] = []

    private let defaults = UserDefaults.standard
    private let sourcesKey = "player.library.sources.v1"
    private let hiddenRecordingsKey = "player.library.hiddenRecordings.v1"
    private var hiddenRecordings = Set<String>()
    private var didSeedDefaultFolder = false

    private static let movieExtensions: Set<String> = [
        "mov", "mp4", "m4v", "m4a", "avi", "mkv", "webm"
    ]

    init() {
        if let data = defaults.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([PlayerLibrarySource].self, from: data) {
            sources = decoded
        }
        if let stored = defaults.array(forKey: hiddenRecordingsKey) as? [String] {
            hiddenRecordings = Set(stored)
        }

        // The recordings directory is useful on first launch, but once the user
        // edits the library it must remain an explicit playlist rather than being
        // silently re-added after every restart.
        if sources.isEmpty && defaults.object(forKey: sourcesKey) == nil {
            let directory = Settings.shared.recordingDirectory
            if FileManager.default.fileExists(atPath: directory.path) {
                sources = [PlayerLibrarySource(url: directory, kind: .folder)]
                didSeedDefaultFolder = true
                persistSources()
            }
        }
        reload()
    }

    var groupedRecordings: [(source: PlayerLibrarySource, recordings: [PlayerRecording])] {
        sources.map { source in
            let items = recordings.filter { $0.sourceID == source.id }
            return (source, items)
        }
    }

    @discardableResult
    func addVideo(url: URL) -> PlayerRecording? {
        let canonical = url.standardizedFileURL
        guard isMovie(canonical), FileManager.default.fileExists(atPath: canonical.path) else {
            return nil
        }
        guard PlayerMediaInspector.inspect(url: canonical) != nil else { return nil }
        if let existing = sources.first(where: { $0.kind == .video && $0.resolvedURL.standardizedFileURL == canonical }) {
            hiddenRecordings.remove(canonical.path)
            persistHiddenRecordings()
            reload()
            return recordings.first(where: { $0.sourceID == existing.id })
        }

        let source = PlayerLibrarySource(url: canonical, kind: .video)
        sources.append(source)
        hiddenRecordings.remove(canonical.path)
        persistSources()
        persistHiddenRecordings()
        reload()
        return recordings.first(where: { $0.sourceID == source.id })
    }

    @discardableResult
    func addFolder(url: URL) -> Bool {
        let canonical = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        guard !sources.contains(where: { $0.kind == .folder && $0.resolvedURL.standardizedFileURL == canonical }) else {
            return true
        }
        sources.append(PlayerLibrarySource(url: canonical, kind: .folder))
        persistSources()
        reload()
        return true
    }

    /// Removes only the library entry. The source file and every file beneath a
    /// source folder are intentionally left untouched on disk.
    func removeSource(_ source: PlayerLibrarySource) {
        sources.removeAll { $0.id == source.id }
        persistSources()
        reload()
    }

    /// Hides a recording from a folder-backed playlist without deleting it.
    func removeRecording(_ recording: PlayerRecording) {
        if recording.sourceKind == .video,
           let source = sources.first(where: { $0.id == recording.sourceID }) {
            removeSource(source)
            return
        }
        hiddenRecordings.insert(recording.url.standardizedFileURL.path)
        persistHiddenRecordings()
        reload()
    }

    func restoreRecording(_ recording: PlayerRecording) {
        hiddenRecordings.remove(recording.url.standardizedFileURL.path)
        persistHiddenRecordings()
        reload()
    }

    func reload() {
        var result: [PlayerRecording] = []
        let fileManager = FileManager.default

        for source in sources {
            let url = source.resolvedURL.standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else { continue }

            if source.kind == .video {
                if isPlayableVideo(url), !hiddenRecordings.contains(url.path) {
                    result.append(PlayerRecording(url: url, source: source))
                }
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let candidate as URL in enumerator {
                guard isPlayableVideo(candidate), !hiddenRecordings.contains(candidate.standardizedFileURL.path) else {
                    continue
                }
                if let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]),
                   values.isRegularFile == false {
                    continue
                }
                result.append(PlayerRecording(url: candidate, source: source))
            }
        }

        recordings = result.sorted {
            if $0.folderName.localizedCaseInsensitiveCompare($1.folderName) != .orderedSame {
                return $0.folderName.localizedCaseInsensitiveCompare($1.folderName) == .orderedAscending
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func source(for recording: PlayerRecording) -> PlayerLibrarySource? {
        sources.first { $0.id == recording.sourceID }
    }

    private func isMovie(_ url: URL) -> Bool {
        Self.movieExtensions.contains(url.pathExtension.lowercased())
    }

    private func isPlayableVideo(_ url: URL) -> Bool {
        guard isMovie(url) else { return false }
        return PlayerMediaInspector.inspect(url: url).map { $0.duration > 0.01 } ?? false
    }

    private func persistSources() {
        defaults.set(try? JSONEncoder().encode(sources), forKey: sourcesKey)
    }

    private func persistHiddenRecordings() {
        defaults.set(Array(hiddenRecordings), forKey: hiddenRecordingsKey)
    }
}
