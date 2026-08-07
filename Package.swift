// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenCap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScreenCap",
            path: "Sources/ScreenCap",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
