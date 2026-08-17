// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Swift 6 language mode is intentional: strict concurrency diagnostics are
// part of the product's build contract, not an opt-in warning pass.
let proEnabled = ProcessInfo.processInfo.environment["SCREENCAP_PRO"] == "1"
var screenCapSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6)
]
if proEnabled {
    screenCapSwiftSettings.append(.define("SCREENCAP_PRO"))
}

let package = Package(
    name: "ScreenCap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "RNNoise",
            path: "Sources/RNNoise",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src")
            ]
        ),
        .executableTarget(
            name: "ScreenCap",
            dependencies: ["RNNoise"],
            path: "Sources/ScreenCap",
            exclude: proEnabled ? [] : ["Player"],
            swiftSettings: screenCapSwiftSettings
        )
    ]
)
