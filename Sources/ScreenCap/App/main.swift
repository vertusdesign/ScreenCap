import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    let outputIndex = arguments.firstIndex(of: "--selftest").map { $0 + 1 } ?? arguments.count
    let directory = outputIndex < arguments.count
        ? URL(fileURLWithPath: arguments[outputIndex], isDirectory: true)
        : FileManager.default.temporaryDirectory.appendingPathComponent("screencap-selftest")
    // AppKit drawing needs an initialised NSApplication even without a UI.
    _ = NSApplication.shared
    exit(SelfTest.run(outputDirectory: directory))
}

let application = NSApplication.shared
let delegate = AppDelegate()

// `--capture area|repeat|window|fullscreen|record` fires one action right after launch;
// the same commands are available at runtime through the bundle's URL scheme
// (`screencap://` in ScreenCap 3 and `screencap-pro3://` in the private Pro flavor).
if let flagIndex = arguments.firstIndex(of: "--capture"), flagIndex + 1 < arguments.count {
    switch arguments[flagIndex + 1].lowercased() {
    case "area": delegate.launchAction = .captureArea
    case "repeat", "last": delegate.launchAction = .repeatLastArea
    case "window": delegate.launchAction = .captureWindow
    case "fullscreen", "screen": delegate.launchAction = .captureFullScreen
    case "record", "recording": delegate.launchAction = .toggleRecording
    default: break
    }
}

// `--window about|preferences` opens a panel straight after launch, which is how
// the UI gets exercised without a running instance to send a URL to.
if let flagIndex = arguments.firstIndex(of: "--window"), flagIndex + 1 < arguments.count {
    delegate.launchWindow = arguments[flagIndex + 1].lowercased()
}

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
