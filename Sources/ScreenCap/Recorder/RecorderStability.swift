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
    private static let markerExtension = "screencap-recording"

    static func markerURL(for movieURL: URL) -> URL {
        movieURL.appendingPathExtension(markerExtension)
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
        var urls = [movieURL]

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
            return name == "\(stem).composite"
                || name.hasPrefix("\(stem).recovered")
                || name.hasPrefix("\(stem) (") && name.hasSuffix(").recovered")
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
        let markerText =
            "ScreenCap recording in progress\n"
                + "pid=\(ProcessInfo.processInfo.processIdentifier)\n"
                + "started=\(Date().timeIntervalSince1970)\n"
        let contents = Data(markerText.utf8)
        guard FileManager.default.createFile(
            atPath: marker.path,
            contents: contents,
            attributes: nil
        ) else {
            throw RecorderError.writerFailed("could not create recording recovery marker")
        }
    }

    static func clearMarker(for movieURL: URL) {
        try? FileManager.default.removeItem(at: markerURL(for: movieURL))
    }

    /// A fragmented .mov remains readable surprisingly often after a process
    /// crash. On the next launch, preserve such a file under a distinct name
    /// rather than silently overwriting or deleting it.
    static func recoverStaleRecordings(in directory: URL) async {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for marker in entries where marker.pathExtension == markerExtension {
            let movie = marker.deletingPathExtension()
            guard FileManager.default.fileExists(atPath: movie.path) else {
                clearMarker(for: movie)
                continue
            }

            // A second ScreenCap process can start while the first one is
            // recording. Never move a live writer's movie out from under it:
            // the writer keeps its file descriptor, but finalization still
            // needs the original URL. New markers carry the owner PID; old
            // markers use a short modification-time grace period.
            guard !activeOwner(for: marker, movie: movie) else {
                Log.debug("skip recovery for active recording: \(movie.lastPathComponent)")
                continue
            }

            let asset = AVURLAsset(url: movie)
            do {
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration)
                guard playable, duration.isNumeric, duration.seconds > 0 else {
                    Log.error("interrupted recording is not currently playable: \(movie.path)")
                    continue
                }
                let recovered = uniqueRecoveredURL(for: movie)
                try FileManager.default.moveItem(at: movie, to: recovered)
                clearMarker(for: movie)
                Log.error(
                    "recovered interrupted recording: \(recovered.lastPathComponent) "
                        + "duration=\(String(format: "%.1f", duration.seconds))s"
                )
            } catch {
                Log.error("could not preserve interrupted recording: \(error.localizedDescription)")
            }
        }
    }

    private static func uniqueRecoveredURL(for movie: URL) -> URL {
        let base = movie.deletingPathExtension()
        var candidate = base.appendingPathExtension("recovered.mov")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base
                .deletingLastPathComponent()
                .appendingPathComponent(base.lastPathComponent + " (\(counter))")
                .appendingPathExtension("recovered.mov")
            counter += 1
        }
        return candidate
    }

    private static func recoveryRank(for url: URL, stem: String) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        if name == "\(stem).composite" { return 0 }
        if name.hasPrefix("\(stem).recovered") { return 1 }
        return 2
    }

    private static func activeOwner(for marker: URL, movie: URL) -> Bool {
        if let data = try? Data(contentsOf: marker),
           let contents = String(data: data, encoding: .utf8),
           let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("pid=") }),
           let pid = Int32(line.dropFirst(4)),
           pid > 0 {
            // EPERM means the process exists but is not inspectable. Both 0
            // and EPERM therefore mean the marker still belongs to a live
            // writer; only ESRCH is safe to recover.
            return kill(pid, 0) == 0 || errno == EPERM
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
}
