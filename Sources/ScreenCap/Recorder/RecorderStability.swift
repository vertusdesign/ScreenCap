import AVFoundation
import Darwin
import Foundation

@available(macOS 15.0, *)
struct RecorderEngineMetrics: Sendable {
    let screenSamples: Int
    let systemAudioSamples: Int
    let microphoneSamples: Int
    let skippedNonCompleteFrames: Int
    let streamStopErrors: Int
}

@available(macOS 15.0, *)
struct RecorderWriterMetrics: Sendable {
    let receivedScreenSamples: Int
    let receivedSystemAudioSamples: Int
    let receivedMicrophoneSamples: Int
    let appendedScreenSamples: Int
    let appendedSystemAudioSamples: Int
    let appendedMicrophoneSamples: Int
    let droppedVideoFrames: Int
    let lastVideoEnd: Double?
    let lastSystemAudioEnd: Double?
    let lastMicrophoneEnd: Double?
    let microphoneInputRMS: Float?
    let microphoneOutputRMS: Float?
}

@available(macOS 15.0, *)
struct RecorderRecoveredRecording: Identifiable, Sendable {
    let id: String
    let url: URL
    let originalURL: URL
    let duration: Double
    let recoveredAt: Date

    init(url: URL, originalURL: URL, duration: Double, recoveredAt: Date = Date()) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.originalURL = originalURL
        self.duration = duration
        self.recoveredAt = recoveredAt
    }
}

@available(macOS 15.0, *)
struct RecorderRecoveryJournalEntry: Codable, Identifiable, Sendable {
    let id: String
    let url: String
    let originalURL: String
    let duration: Double
    let recoveredAt: Date
    var discarded: Bool
}

@available(macOS 15.0, *)
enum RecorderDiskSpace {
    /// Keep a safety margin so a long capture cannot exhaust the volume and
    /// damage unrelated applications or the user's home directory.
    static let minimumFreeBytes: Int64 = 512 * 1024 * 1024

    static func freeBytes(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return Int64(important)
            }
            if let available = values.volumeAvailableCapacity {
                return Int64(available)
            }
        } catch {
            Log.debug("recorder could not read free disk space: \(error.localizedDescription)")
        }
        return nil
    }

    static func ensureAvailable(at url: URL) throws {
        guard let available = freeBytes(at: url) else {
            // Do not reject a valid destination when macOS temporarily does
            // not expose volume statistics (network or removable volumes can
            // do this during mount).
            return
        }
        guard available >= minimumFreeBytes else {
            throw RecorderError.diskSpaceLow(available: available)
        }
    }
}

@available(macOS 15.0, *)
enum RecorderRecovery {
    private static let markerExtension = "marker"
    private static let legacyMarkerExtension = "screencap-recording"
    private static let markerSuffix = "_screencap_recording"
    private static let knownDirectoriesKey = "recorder.recovery.knownDirectories.v1"
    private static let journalKey = "recorder.recovery.journal.v1"
    private static let maximumKnownDirectories = 32
    private static let maximumJournalEntries = 100

    private struct Manifest: Codable {
        var schema = 2
        var sessionID: String
        var pid: Int32
        var bootID: String
        var started: Date
        var lastActivity: Date
        var stage: String
        var displayID: UInt32?
        var width: Int?
        var height: Int?
        var ownerStartUptime: Double?
    }

    static func markerURL(for movieURL: URL) -> URL {
        let base = movieURL.deletingPathExtension()
        return base.deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent)\(markerSuffix)")
            .appendingPathExtension(markerExtension)
    }

    static func legacyMarkerURL(for movieURL: URL) -> URL {
        movieURL.appendingPathExtension(legacyMarkerExtension)
    }

    private static func markerURLs(for movieURL: URL) -> [URL] {
        [markerURL(for: movieURL), legacyMarkerURL(for: movieURL)]
    }

    private static func activeMarkerURL(for movieURL: URL) -> URL {
        markerURLs(for: movieURL).first {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? markerURL(for: movieURL)
    }

    static func partialURL(for movieURL: URL) -> URL {
        let base = movieURL.deletingPathExtension()
        return base.deletingLastPathComponent()
            .appendingPathComponent("\(base.lastPathComponent)_partial.mov")
    }

    static func legacyPartialURL(for movieURL: URL) -> URL {
        movieURL.deletingPathExtension().appendingPathExtension("partial.mov")
    }

    static func compositeURLs(for movieURL: URL) -> [URL] {
        let base = movieURL.deletingPathExtension()
        let directory = base.deletingLastPathComponent()
        let stem = base.lastPathComponent
        return [
            directory.appendingPathComponent("\(stem)_composite.mov"),
            directory.appendingPathComponent("\(stem).composite.mov")
        ]
    }

    static func registerDirectory(_ directory: URL) {
        let canonical = directory.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: knownDirectoriesKey) ?? []
        paths.removeAll { $0 == canonical }
        paths.append(canonical)
        if paths.count > maximumKnownDirectories {
            paths = Array(paths.suffix(maximumKnownDirectories))
        }
        UserDefaults.standard.set(paths, forKey: knownDirectoriesKey)
    }

    static func knownDirectories() -> [URL] {
        var paths = UserDefaults.standard.stringArray(forKey: knownDirectoriesKey) ?? []
        let configured = Settings.shared.recordingDirectory.standardizedFileURL.path
        paths.removeAll { $0 == configured }
        paths.insert(configured, at: 0)
        var seen = Set<String>()
        return paths.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    /// Returns the source movie plus temporary/recovered siblings that may
    /// represent the same recording after an interrupted finalization. The
    /// writer keeps its original file descriptor across a rename, so the URL
    /// supplied to the writer is not necessarily the URL that is playable at
    /// stop time. Keep this lookup narrowly scoped to the source basename;
    /// unrelated recordings in the same folder must never be opened instead.
    static func relatedRecordingURLs(for movieURL: URL) -> [URL] {
        let directory = movieURL.deletingLastPathComponent()
        let stem = movieURL.deletingPathExtension().lastPathComponent
        var urls = [movieURL, partialURL(for: movieURL), legacyPartialURL(for: movieURL)]

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return urls
        }

        let siblings = entries.filter { candidate in
            guard candidate.pathExtension.lowercased() == "mov" else { return false }
            let name = candidate.deletingPathExtension().lastPathComponent
            return name == "\(stem)_composite"
                || name == "\(stem).composite" // legacy
                || name.hasPrefix("\(stem)_recovered")
                || name.hasPrefix("\(stem).recovered") // legacy recovery names
                || name.hasPrefix("\(stem)_repaired")
                || name.hasPrefix("\(stem).repaired") // legacy
                || name.hasPrefix("\(stem)_partial_composite")
                || name.hasPrefix("\(stem).partial.composite") // legacy
                || name.hasPrefix("\(stem)_partial_repaired")
                || name.hasPrefix("\(stem).partial.repaired") // legacy
                || name.hasPrefix("\(stem)_partial_recovered")
                || name.hasPrefix("\(stem).partial_recovered") // legacy
                || name.hasPrefix("\(stem).partial.recovered") // legacy
                || name.hasPrefix("\(stem) (") && (
                    name.hasSuffix(")_recovered") || name.hasSuffix(").recovered")
                )
        }
        .sorted { lhs, rhs in
            recoveryRank(for: lhs, stem: stem) < recoveryRank(for: rhs, stem: stem)
        }
        urls.append(contentsOf: siblings)

        var unique: [URL] = []
        var seen = Set<String>()
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted { unique.append(url) }
        }
        return unique
    }

    static func markInProgress(for movieURL: URL) throws {
        let marker = markerURL(for: movieURL)
        let now = Date()
        let manifest = Manifest(
            sessionID: UUID().uuidString,
            pid: ProcessInfo.processInfo.processIdentifier,
            bootID: bootIdentity,
            started: now,
            lastActivity: now,
            stage: "recording",
            displayID: nil,
            width: nil,
            height: nil,
            ownerStartUptime: processStartUptime(for: ProcessInfo.processInfo.processIdentifier)
        )
        try writeNew(manifest, to: marker)
    }

    @discardableResult
    static func markInProgress(
        for movieURL: URL,
        displayID: CGDirectDisplayID?,
        width: Int?,
        height: Int?
    ) throws -> String {
        let marker = markerURL(for: movieURL)
        let now = Date()
        let sessionID = UUID().uuidString
        let manifest = Manifest(
            sessionID: sessionID,
            pid: ProcessInfo.processInfo.processIdentifier,
            bootID: bootIdentity,
            started: now,
            lastActivity: now,
            stage: "recording",
            displayID: displayID,
            width: width,
            height: height,
            ownerStartUptime: processStartUptime(for: ProcessInfo.processInfo.processIdentifier)
        )
        try writeNew(manifest, to: marker)
        return sessionID
    }

    static func updateMarker(for movieURL: URL, stage: RecorderProcessingStage) {
        let marker = activeMarkerURL(for: movieURL)
        guard var manifest = readManifest(from: marker) else { return }
        manifest.lastActivity = Date()
        manifest.stage = stage.rawValue
        try? write(manifest, to: marker)
    }

    static func touchMarker(for movieURL: URL) {
        let marker = activeMarkerURL(for: movieURL)
        guard var manifest = readManifest(from: marker) else { return }
        manifest.lastActivity = Date()
        try? write(manifest, to: marker)
    }

    static func clearMarker(for movieURL: URL) {
        for marker in markerURLs(for: movieURL) {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    /// A fragmented .mov remains readable surprisingly often after a process
    /// crash. On the next launch, preserve such a file under a distinct name
    /// rather than silently overwriting or deleting it.
    static func recoverStaleRecordings(in directory: URL) async -> [RecorderRecoveredRecording] {
        await recoverStaleRecordings(in: [directory])
    }

    static func recoverStaleRecordings(in directories: [URL]) async -> [RecorderRecoveredRecording] {
        var recovered: [RecorderRecoveredRecording] = []
        var seenMarkers = Set<String>()
        for directory in directories {
            let results = await recoverStaleRecordings(inSingleDirectory: directory)
            for result in results where seenMarkers.insert(result.originalURL.standardizedFileURL.path).inserted {
                recovered.append(result)
            }
        }
        return recovered
    }

    private static func recoverStaleRecordings(
        inSingleDirectory directory: URL
    ) async -> [RecorderRecoveredRecording] {
        var recoveredResults: [RecorderRecoveredRecording] = []
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return recoveredResults }

        for marker in entries where marker.pathExtension == markerExtension
            || marker.pathExtension == legacyMarkerExtension {
            guard let movie = movieURL(forMarker: marker) else { continue }
            let candidates = relatedRecordingURLs(for: movie)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !candidates.isEmpty else {
                // Keep the marker when the volume is temporarily unavailable
                // or the process disappeared between marker creation and the
                // first movie fragment. A later launch/manual scan can then
                // recover it after the volume is mounted again.
                Log.debug("recovery marker has no visible media yet: \(marker.path)")
                continue
            }

            // A second ScreenCap process can start while the first one is
            // recording. Never move a live writer's movie out from under it:
            // the writer keeps its file descriptor, but finalization still
            // needs the original URL. New markers carry the owner PID; old
            // markers use a short modification-time grace period.
            guard !activeOwner(for: marker, movie: candidates[0]) else {
                Log.debug("skip recovery for active recording: \(movie.lastPathComponent)")
                continue
            }

            if let result = await recoverPlayableCandidate(candidates, original: movie) {
                recoveredResults.append(result)
                appendJournal(result)
                clearMarker(for: movie)
                Log.error(
                    "recovered interrupted recording: \(result.url.lastPathComponent) "
                        + "duration=\(String(format: "%.1f", result.duration))s"
                )
            } else {
                Log.error("interrupted recording candidates are not currently playable: \(movie.path)")
            }
        }
        return recoveredResults
    }

    private static func recoverPlayableCandidate(
        _ candidates: [URL],
        original: URL
    ) async -> RecorderRecoveredRecording? {
        for candidate in candidates {
            let asset = AVURLAsset(url: candidate)
            do {
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration)
                guard playable, duration.isNumeric, duration.seconds > 0 else { continue }
                let recovered = uniqueRecoveredURL(for: original)
                try FileManager.default.moveItem(at: candidate, to: recovered)
                return RecorderRecoveredRecording(
                    url: recovered,
                    originalURL: original,
                    duration: duration.seconds
                )
            } catch {
                Log.error("could not inspect recovery candidate \(candidate.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // If the media is present but the fragmented MOV index is incomplete,
        // rebuild a passthrough container before giving up. The repaired file
        // is moved into the normal recovered name so it cannot be mistaken for
        // an ordinary recording by the Player library.
        for candidate in candidates {
            guard let repaired = await RecorderRepairService.repair(candidate) else { continue }
            let recovered = uniqueRecoveredURL(for: original)
            do {
                try FileManager.default.moveItem(at: repaired, to: recovered)
                let asset = AVURLAsset(url: recovered)
                let duration = try await asset.load(.duration)
                guard duration.isNumeric, duration.seconds > 0 else {
                    try? FileManager.default.removeItem(at: recovered)
                    continue
                }
                return RecorderRecoveredRecording(
                    url: recovered,
                    originalURL: original,
                    duration: duration.seconds
                )
            } catch {
                try? FileManager.default.removeItem(at: repaired)
                Log.error("could not preserve repaired recovery candidate: \(error.localizedDescription)")
            }
        }
        return nil
    }

    private static func uniqueRecoveredURL(for movie: URL) -> URL {
        let base = movie.deletingPathExtension()
        let directory = base.deletingLastPathComponent()
        let stem = base.lastPathComponent
        var candidate = directory
            .appendingPathComponent("\(stem)_recovered")
            .appendingPathExtension("mov")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(stem)_recovered_\(counter)")
                .appendingPathExtension("mov")
            counter += 1
        }
        return candidate
    }

    private static func recoveryRank(for url: URL, stem: String) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        if name == "\(stem)_composite"
            || name == "\(stem).composite"
            || name.hasPrefix("\(stem)_partial_composite")
            || name.hasPrefix("\(stem).partial.composite") { return 0 }
        if name.hasPrefix("\(stem)_repaired")
            || name.hasPrefix("\(stem).repaired")
            || name.hasPrefix("\(stem)_partial_repaired")
            || name.hasPrefix("\(stem).partial.repaired") { return 1 }
        if name.hasPrefix("\(stem)_recovered")
            || name.hasPrefix("\(stem).recovered")
            || name.hasPrefix("\(stem)_partial_recovered")
            || name.hasPrefix("\(stem).partial_recovered")
            || name.hasPrefix("\(stem).partial.recovered") { return 2 }
        return 3
    }

    private static func movieURL(forMarker marker: URL) -> URL? {
        guard marker.pathExtension == markerExtension else {
            guard marker.pathExtension == legacyMarkerExtension else { return nil }
            return marker.deletingPathExtension()
        }
        let base = marker.deletingPathExtension()
        let name = base.lastPathComponent
        guard name.hasSuffix(markerSuffix) else { return nil }
        let movieStem = String(name.dropLast(markerSuffix.count))
        guard !movieStem.isEmpty else { return nil }
        return base.deletingLastPathComponent()
            .appendingPathComponent(movieStem)
            .appendingPathExtension("mov")
    }

    private static func activeOwner(for marker: URL, movie: URL) -> Bool {
        if let manifest = readManifest(from: marker),
           manifest.pid > 0,
           manifest.bootID == bootIdentity {
            // EPERM means the process exists but is not inspectable. Both 0
            // and EPERM therefore mean the marker still belongs to a live
            // writer; only ESRCH is safe to recover.
            guard kill(manifest.pid, 0) == 0 || errno == EPERM else { return false }
            // PID reuse within one boot is possible. When the marker has a
            // process start identity, require it to match before treating the
            // process as the live owner. Older manifests fall back to PID +
            // boot identity and the conservative liveness check above.
            if let ownerStart = manifest.ownerStartUptime,
               let currentStart = processStartUptime(for: manifest.pid) {
                return abs(ownerStart - currentStart) < 0.001
            }
            return true
        }

        // Markers written by older builds have no owner. A file modified very
        // recently is more likely to be an active recording than a stale
        // crash; defer recovery until a later launch instead of risking a
        // move underneath the writer.
        guard let modified = try? movie.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              modified.timeIntervalSinceNow > -120
        else { return false }
        return true
    }

    static func journal() -> [RecorderRecoveryJournalEntry] {
        guard let data = UserDefaults.standard.data(forKey: journalKey),
              let entries = try? JSONDecoder().decode([RecorderRecoveryJournalEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func markDiscarded(_ recording: RecorderRecoveredRecording) {
        var entries = journal()
        if let index = entries.firstIndex(where: { $0.id == recording.id }) {
            entries[index].discarded = true
            persistJournal(entries)
        }
    }

    private static func appendJournal(_ recording: RecorderRecoveredRecording) {
        var entries = journal().filter { $0.id != recording.id }
        entries.append(
            RecorderRecoveryJournalEntry(
                id: recording.id,
                url: recording.url.path,
                originalURL: recording.originalURL.path,
                duration: recording.duration,
                recoveredAt: recording.recoveredAt,
                discarded: false
            )
        )
        persistJournal(Array(entries.suffix(maximumJournalEntries)))
    }

    private static func persistJournal(_ entries: [RecorderRecoveryJournalEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: journalKey)
    }

    private static func write(_ manifest: Manifest, to url: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func writeNew(_ manifest: Manifest, to url: URL) throws {
        let data = try JSONEncoder().encode(manifest)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            throw RecorderError.writerFailed("could not create recording recovery marker: \(reason)")
        }
        defer { close(descriptor) }
        do {
            try data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        buffer.count - offset
                    )
                    guard written > 0 else {
                        let reason = String(cString: strerror(errno))
                        throw RecorderError.writerFailed("could not write recording recovery marker: \(reason)")
                    }
                    offset += written
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func readManifest(from url: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        return manifest
    }

    private static var bootIdentity: String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return "\(bootTime.tv_sec)-\(bootTime.tv_usec)"
    }

    private static func processStartUptime(for pid: Int32) -> Double? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }
}
