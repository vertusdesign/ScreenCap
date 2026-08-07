import Foundation

/// Opt-in tracing: `SCREENCAP_DEBUG=1` in the environment turns it on.
/// Off by default so the app writes nothing to the system log in normal use.
enum Log {
    private static let enabled = ProcessInfo.processInfo.environment["SCREENCAP_DEBUG"] == "1"

    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data("[SL] \(message())\n".utf8))
    }
}
