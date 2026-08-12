import AVFoundation
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

    static func markInProgress(for movieURL: URL) throws {
        let marker = markerURL(for: movieURL)
        let contents = Data("ScreenCap recording in progress\n".utf8)
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
}
