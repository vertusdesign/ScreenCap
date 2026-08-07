import Foundation

/// Static facts about the build, in one place so the About window, the update
/// check and the crash-report footer never disagree.
enum AppInfo {
    static let name = "ScreenCap"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var versionLine: String {
        L10n.t("about.version", version, build)
    }

    /// Change these together with the repository the project actually lives in.
    static let repositoryURL = URL(string: "https://github.com/vertusdesign/ScreenCap")!
    static let releasesURL = URL(string: "https://github.com/vertusdesign/ScreenCap/releases")!
    static let licenseURL = URL(string: "https://github.com/vertusdesign/ScreenCap/blob/main/LICENSE")!
    static let issuesURL = URL(string: "https://github.com/vertusdesign/ScreenCap/issues")!
}
