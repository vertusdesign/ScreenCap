import Foundation

/// The languages the app ships with. English is the fallback for every missing
/// key, and the three languages that matter most to this project lead the list.
enum AppLanguage: String, CaseIterable, Codable {
    case en, uk, be, ro
    case ar, cs, de, el, es, fi, fr, hi, hu, id, it, ja, ko, nl, pl
    case ptBR = "pt-BR"
    case sv, tr, vi
    case zhHans = "zh-Hans"

    /// Endonym — a language menu that names languages in their own language is
    /// the only kind that is useful to someone who cannot read the current one.
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .uk: return "Українська"
        case .be: return "Беларуская"
        case .ro: return "Română"
        case .ar: return "العربية"
        case .cs: return "Čeština"
        case .de: return "Deutsch"
        case .el: return "Ελληνικά"
        case .es: return "Español"
        case .fi: return "Suomi"
        case .fr: return "Français"
        case .hi: return "हिन्दी"
        case .hu: return "Magyar"
        case .id: return "Bahasa Indonesia"
        case .it: return "Italiano"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .nl: return "Nederlands"
        case .pl: return "Polski"
        case .ptBR: return "Português (Brasil)"
        case .sv: return "Svenska"
        case .tr: return "Türkçe"
        case .vi: return "Tiếng Việt"
        case .zhHans: return "简体中文"
        }
    }

    /// Menu order: the four required languages first, then the rest alphabetically.
    static var menuOrder: [AppLanguage] {
        let leading: [AppLanguage] = [.en, .uk, .be, .ro]
        let rest = allCases.filter { !leading.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        return leading + rest
    }
}

/// Localised strings, with an explicit English fallback.
///
/// `Bundle.main.localizedString` already falls back to the development region,
/// but only when the whole `.lproj` is missing — a key missing from an otherwise
/// present translation comes back as the key itself. Resolving through English
/// explicitly means a half-finished translation degrades to English rather than
/// to `overlay.hint.area`.
enum L10n {
    private static let sentinel = "\u{0}__missing__"

    private static var overrideBundle: Bundle?

    /// Where the `.lproj` folders live.
    ///
    /// Normally that is the app bundle. `SCREENCAP_STRINGS` points at the
    /// repository's `Resources/l10n` instead, so a plain `swift build` binary —
    /// which has no Resources directory — still shows real text rather than raw
    /// keys during development.
    private static let searchRoot: URL? = {
        if let path = ProcessInfo.processInfo.environment["SCREENCAP_STRINGS"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return Bundle.main.resourceURL
    }()

    private static func bundle(for code: String) -> Bundle? {
        guard let root = searchRoot else { return nil }
        return Bundle(url: root.appendingPathComponent("\(code).lproj"))
    }

    private static let englishBundle: Bundle? = bundle(for: "en")

    /// The bundle matching the user's system language, used when no explicit
    /// override is set. `Bundle.main` handles this on its own, but not when the
    /// strings are being read from `SCREENCAP_STRINGS`.
    private static let systemBundle: Bundle? = {
        for code in Bundle.preferredLocalizations(
            from: AppLanguage.allCases.map(\.rawValue),
            forPreferences: nil
        ) {
            if let match = bundle(for: code) { return match }
        }
        return nil
    }()

    static func reload() {
        overrideBundle = Settings.shared.preferredLanguage.flatMap { bundle(for: $0.rawValue) }
    }

    static func t(_ key: String) -> String {
        for candidate in [overrideBundle, systemBundle, englishBundle] {
            guard let candidate else { continue }
            let value = candidate.localizedString(forKey: key, value: sentinel, table: nil)
            if value != sentinel { return value }
        }
        return key
    }

    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}

extension Notification.Name {
    /// Posted when the UI language changes so open windows can rebuild.
    static let languageChanged = Notification.Name("ScreenCap.languageChanged")
}
