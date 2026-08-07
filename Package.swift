// swift-tools-version: 5.10
import PackageDescription

// Tools version 5.10 rather than 6.0 on purpose. Under 6.0 the default language
// mode is Swift 6, whose strict concurrency checking this AppKit code does not
// satisfy, and asking for mode 5 with `.swiftLanguageMode(.v5)` writes a bare "5"
// into SWIFT_VERSION — which the Xcode build system, used for the universal
// `--arch arm64 --arch x86_64` build, rejects as unsupported. At 5.10 the mode is
// already 5 and no setting is needed.
let package = Package(
    name: "ScreenCap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenCap",
            path: "Sources/ScreenCap"
        )
    ]
)
