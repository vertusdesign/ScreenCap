// swift-tools-version: 6.0
import PackageDescription

// Swift 6 language mode is intentional: strict concurrency diagnostics are
// part of the product's build contract, not an opt-in warning pass.
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
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
