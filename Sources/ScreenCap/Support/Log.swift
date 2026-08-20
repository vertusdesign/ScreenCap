import Foundation

/// Opt-in tracing: `SCREENCAP_DEBUG=1` in the environment turns it on.
/// Off by default so the app writes nothing to the system log in normal use.
enum Log {
    private static let enabled = ProcessInfo.processInfo.environment["SCREENCAP_DEBUG"] == "1"
    private static let errorLock = NSLock()
    private static let maximumFileBytes = 512 * 1024
    private static let maximumArchivedFiles = 3

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[SL] \(message())\n".utf8))
    }

    /// Persistent, low-volume diagnostics for recorder configuration and
    /// lifecycle events. Unlike `error`, this is not mirrored to the unified
    /// log; it exists to make a later recording failure explainable.
    static func diagnostic(_ message: @autoclosure () -> String) {
        appendFileLine(message(), prefix: "diagnostic")
    }

    /// Errors are always sent to the unified log. Recorder failures otherwise
    /// collapse into the same short HUD message and leave no useful evidence
    /// when the app was launched from Finder.
    static func error(_ message: @autoclosure () -> String) {
        let text = message()
        NSLog("ScreenCap: %@", text)

        appendFileLine(text, prefix: "error")
    }

    private static func appendFileLine(_ text: String, prefix: String) {

        // Finder-launched accessory apps do not reliably expose stderr, and
        // some macOS configurations make short-lived unified-log entries hard
        // to retrieve. Keep a small diagnostic trail for recorder failures so
        // the HUD's generic "Recording failed" can be investigated without
        // asking the user to reproduce the issue under a debugger.
        guard let library = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first else { return }
        let directory = library.appendingPathComponent("Logs/ScreenCap", isDirectory: true)
        let file = directory.appendingPathComponent("recorder.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) pid=\(ProcessInfo.processInfo.processIdentifier) \(prefix)=\(text)\n"

        errorLock.lock()
        defer { errorLock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(
                    atPath: file.path,
                    contents: nil,
                    attributes: nil
                )
            }
            rotateIfNeeded(file: file, directory: directory, incomingBytes: line.utf8.count)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            // Diagnostics must never affect recording itself.
        }
    }

    private static func rotateIfNeeded(file: URL, directory: URL, incomingBytes: Int) {
        let fileManager = FileManager.default
        let currentBytes = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)
            .map { $0.intValue } ?? 0
        guard currentBytes + incomingBytes > maximumFileBytes else { return }

        // Keep recorder.log plus three bounded archives. Rotation is deliberately
        // best-effort: diagnostics must never become a reason to lose a recording.
        if maximumArchivedFiles > 1 {
            for index in stride(from: maximumArchivedFiles - 1, through: 1, by: -1) {
                let source = directory.appendingPathComponent("recorder_log_\(index)")
                let legacySource = directory.appendingPathComponent("recorder.log.\(index)")
                let destination = directory.appendingPathComponent("recorder_log_\(index + 1)")
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                if fileManager.fileExists(atPath: source.path) {
                    try? fileManager.moveItem(at: source, to: destination)
                } else if fileManager.fileExists(atPath: legacySource.path) {
                    try? fileManager.moveItem(at: legacySource, to: destination)
                }
            }
        }

        let firstArchive = directory.appendingPathComponent("recorder_log_1")
        if fileManager.fileExists(atPath: firstArchive.path) {
            try? fileManager.removeItem(at: firstArchive)
        }
        let legacyFirstArchive = directory.appendingPathComponent("recorder.log.1")
        if fileManager.fileExists(atPath: legacyFirstArchive.path) {
            try? fileManager.removeItem(at: legacyFirstArchive)
        }
        try? fileManager.moveItem(at: file, to: firstArchive)
        fileManager.createFile(atPath: file.path, contents: nil, attributes: nil)
    }
}
