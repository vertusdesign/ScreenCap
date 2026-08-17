@preconcurrency import AVFoundation
import Foundation

/// Best-effort repair for a fragmented or otherwise incomplete MOV.
///
/// AVAssetWriter can leave a file which has enough media data to decode but
/// whose container index was not closed. A passthrough export asks AVFoundation
/// to rebuild the container without re-encoding the screen stream. It is only
/// used after normal validation fails; the original candidate is never deleted
/// unless the caller explicitly replaces it.
@available(macOS 15.0, *)
enum RecorderRepairService {
    private final class ExporterBox: @unchecked Sendable {
        let exporter: AVAssetExportSession

        init(_ exporter: AVAssetExportSession) {
            self.exporter = exporter
        }
    }

    static func repair(_ sourceURL: URL) async -> URL? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        let asset = AVURLAsset(url: sourceURL)
        do {
            let tracks = try await asset.load(.tracks)
            guard tracks.contains(where: { $0.mediaType == .video }) else { return nil }
        } catch {
            Log.debug(
                "repair could not load tracks for \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            )
            return nil
        }

        let destination = uniqueDestination(for: sourceURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            return nil
        }
        exporter.outputURL = destination
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false
        let exporterBox = ExporterBox(exporter)

        let completed = await withCheckedContinuation { continuation in
            exporterBox.exporter.exportAsynchronously {
                continuation.resume(returning: exporterBox.exporter.status == .completed)
            }
        }
        guard completed,
              FileManager.default.fileExists(atPath: destination.path)
        else {
            if let error = exporterBox.exporter.error {
                Log.debug(
                    "repair export failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
            try? FileManager.default.removeItem(at: destination)
            return nil
        }

        let repairedAsset = AVURLAsset(url: destination)
        do {
            let playable = try await repairedAsset.load(.isPlayable)
            let duration = try await repairedAsset.load(.duration)
            guard playable, duration.isNumeric, duration.seconds > 0 else {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            Log.debug("repaired candidate did not validate: \(error.localizedDescription)")
            return nil
        }
        Log.error("repaired interrupted recording container: \(sourceURL.lastPathComponent)")
        return destination
    }

    private static func uniqueDestination(for sourceURL: URL) -> URL {
        let base = sourceURL.deletingPathExtension()
        var candidate = base.appendingPathExtension("repaired.mov")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base
                .deletingLastPathComponent()
                .appendingPathComponent(base.lastPathComponent + " (\(counter))")
                .appendingPathExtension("repaired.mov")
            counter += 1
        }
        return candidate
    }
}
