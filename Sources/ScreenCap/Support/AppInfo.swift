import Foundation

/// Static facts about the build, in one place so the About window, the update
/// check and the release notes never disagree.
enum AppInfo {
    static let name = "ScreenCap"
    /// Product label used by the regular macOS application menu. The bundle
    /// executable and URL identifiers intentionally remain ScreenCap for
    /// compatibility with existing installs and permissions.
    static let menuName = "ScreenCap Pro 3"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.vertusdesign.ScreenCap"
    }

    static var urlScheme: String {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = types?.first?["CFBundleURLSchemes"] as? [String]
        return schemes?.first ?? "screencap"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// "alpha", "beta", or empty for a stable build. Kept out of
    /// `CFBundleShortVersionString`, which macOS expects to be purely numeric.
    static var channel: String {
        Bundle.main.object(forInfoDictionaryKey: "SCVersionChannel") as? String ?? ""
    }

    /// A numeric stable version, or e.g. `2.0.0-beta` for a prerelease build.
    static var displayVersion: String {
        channel.isEmpty ? version : "\(version)-\(channel)"
    }

    static var isPrerelease: Bool { !channel.isEmpty }

    static var versionLine: String {
        L10n.t("about.version", displayVersion, build)
    }

    // MARK: - Links

    private static let repository = "https://github.com/vertusdesign/ScreenCap"

    static let repositoryURL = URL(string: repository)!
    /// Opened by "Check for Updates…" — the releases page is the source of truth;
    /// the app never fetches anything itself.
    static let releasesURL = URL(string: "\(repository)/releases/latest")!
    static let licenseURL = URL(string: "\(repository)/blob/main/LICENSE")!
    static let privacyURL = URL(string: "\(repository)/blob/main/PRIVACY.md")!
    static let issuesURL = URL(string: "\(repository)/issues")!
    static let supportURL = URL(string: "https://www.patreon.com/cw/RomanVert/shop")!
}
