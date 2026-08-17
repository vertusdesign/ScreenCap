import AppKit
import Combine
import Carbon.HIToolbox
import ServiceManagement

enum RecordingVideoCodec: String, CaseIterable, Identifiable {
    case automatic
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return L10n.t("prefs.recording.codec.automatic")
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

enum RecordingAfterCaptureAction {
    /// The absence of a value means that the user has not chosen a post-recording action yet.
    /// It is intentionally different from `nothing`, which is an explicit choice.
    static let notConfigured = "__askAfterFirstRecording__"
    static let nothing = "nothing"
    static let showInFolder = "showInFolder"
    static let openInPlayer = "openInPlayer"
    static let applicationPrefix = "application:"

    static func application(_ bundleIdentifier: String) -> String {
        applicationPrefix + bundleIdentifier
    }

    static func bundleIdentifier(from value: String) -> String? {
        guard value.hasPrefix(applicationPrefix) else { return nil }
        return String(value.dropFirst(applicationPrefix.count))
    }
}

/// User-visible preferences, persisted in `UserDefaults`.
///
/// Everything is a plain value type so the settings object can be observed by
/// SwiftUI and read synchronously from AppKit drawing code.
final class Settings: ObservableObject, @unchecked Sendable {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let hotkeys = "hotkeys"
        static let hotkeyDefaultsVersion = "hotkeyDefaultsVersion"
        static let language = "language"
        static let saveDirectory = "saveDirectory"
        static let filenameTemplate = "filenameTemplate"
        static let askWhereToSave = "askWhereToSave"
        static let copyOnSave = "copyOnSave"
        static let dimOpacity = "dimOpacity"
        static let showMagnifier = "showMagnifier"
        static let showSizeBadge = "showSizeBadge"
        static let downscaleRetina = "downscaleRetina"
        static let playShutterSound = "playShutterSound"
        static let toolColor = "toolColor"
        static let strokeWidth = "strokeWidth"
        static let fontSize = "fontSize"
        static let recentColors = "recentColors"
        static let recentStrokeColors = "recentStrokeColors"
        static let recentBackdropColors = "recentBackdropColors"
        static let textBackdrop = "textBackdrop"
        static let textBackdropColor = "textBackdropColor"
        static let obfuscationStyle = "obfuscationStyle"
        static let obfuscationShape = "obfuscationShape"
        static let obfuscationBrushSize = "obfuscationBrushSize"
        static let obfuscationIntensity = "obfuscationIntensity"
        static let eraserRadius = "eraserRadius"
        static let eraserShape = "eraserShape"
        static let eraserMode = "eraserMode"
        static let counterSize = "counterSize"
        static let counterArrowWidth = "counterArrowWidth"
        static let shapeFilled = "shapeFilled"
        static let arrowDoubleHeaded = "arrowDoubleHeaded"
        static let imageFormat = "imageFormat"
        static let recordingDirectory = "recordingDirectory"
        static let recordingFilenameTemplate = "recordingFilenameTemplate"
        static let recordingAskWhereToSave = "recordingAskWhereToSave"
        static let recordingSkipSystemAudio = "recordingSkipSystemAudio"
        static let recordingSkipMicrophone = "recordingSkipMicrophone"
        static let recordingNoiseSuppression = "recordingNoiseSuppression"
        static let recordingAtLogicalSize = "recordingAtLogicalSize"
        static let recordingVideoCodec = "recordingVideoCodec"
        static let recordingShowMouseClicks = "recordingShowMouseClicks"
        static let recordingAfterCaptureAction = "recordingAfterCaptureAction"
        static let playerTranscriptionMode = "playerTranscriptionMode"
    }

    private static var toolDefaults: [String: Any] {
        [
            Key.toolColor: "#FF3B30",
            Key.strokeWidth: 3.0,
            Key.fontSize: 24.0,
            Key.textBackdrop: TextBackdrop.none.rawValue,
            Key.textBackdropColor: "#000000",
            Key.obfuscationStyle: ObfuscationStyle.pixelate.rawValue,
            Key.obfuscationShape: ObfuscationShape.brush.rawValue,
            Key.obfuscationBrushSize: 40.0,
            Key.obfuscationIntensity: 11.0,
            Key.eraserRadius: 24.0,
            Key.eraserShape: ObfuscationShape.brush.rawValue,
            Key.eraserMode: EraserMode.pixels.rawValue,
            Key.counterSize: 3.0,
            Key.counterArrowWidth: 3.0,
            Key.shapeFilled: false,
            Key.arrowDoubleHeaded: false
        ]
    }

    /// Registered defaults for every value on the Capture tab, used both to seed
    /// `UserDefaults` and to reset that tab. `saveDirectory` is deliberately
    /// absent: it has no fixed default value, only a computed fallback (see its
    /// getter), so resetting it means removing the key, not writing one.
    private static var captureDefaults: [String: Any] {
        [
            Key.filenameTemplate: "Screenshot_{timestamp}",
            Key.askWhereToSave: false,
            Key.copyOnSave: true,
            Key.dimOpacity: 0.45,
            Key.showMagnifier: true,
            Key.showSizeBadge: true,
            Key.downscaleRetina: false,
            Key.playShutterSound: true,
            Key.imageFormat: ImageFormat.png.rawValue
        ]
    }

    private static var recordingDefaults: [String: Any] {
        [
            Key.recordingAskWhereToSave: false,
            Key.recordingSkipSystemAudio: false,
            Key.recordingSkipMicrophone: false,
            Key.recordingNoiseSuppression: false,
            Key.recordingAtLogicalSize: false,
            Key.recordingVideoCodec: RecordingVideoCodec.automatic.rawValue,
            Key.recordingShowMouseClicks: false,
            Key.playerTranscriptionMode: PlayerTranscriptionMode.onDemand.rawValue
        ]
    }

    private init() {
        var registered = Self.captureDefaults
        registered.merge(Self.toolDefaults) { current, _ in current }
        registered.merge(Self.recordingDefaults) { current, _ in current }
        defaults.register(defaults: registered)
        migrateHotkeysIfNeeded()
    }

    // MARK: - Language

    /// `nil` means "follow the system".
    var preferredLanguage: AppLanguage? {
        get {
            guard let raw = defaults.string(forKey: Key.language) else { return nil }
            return AppLanguage(rawValue: raw)
        }
        set {
            defaults.set(newValue?.rawValue, forKey: Key.language)
            objectWillChange.send()
            L10n.reload()
            NotificationCenter.default.post(name: .languageChanged, object: nil)
        }
    }

    // MARK: - Hotkeys

    var hotkeys: [HotkeyAction: Hotkey] {
        get {
            guard let data = defaults.data(forKey: Key.hotkeys),
                  let stored = try? JSONDecoder().decode([String: Hotkey].self, from: data)
            else { return Self.defaultHotkeys }

            // Merge defaults so an existing installation receives new additive
            // actions (such as recording) without losing any saved shortcuts.
            var result = Self.defaultHotkeys
            for (rawAction, hotkey) in stored {
                if let action = HotkeyAction(rawValue: rawAction) { result[action] = hotkey }
            }
            return result
        }
        set {
            let stored = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(stored), forKey: Key.hotkeys)
            objectWillChange.send()
            HotkeyManager.shared.apply(newValue)
        }
    }

    static var defaultHotkeys: [HotkeyAction: Hotkey] {
        var result: [HotkeyAction: Hotkey] = [:]
        for action in HotkeyAction.allCases {
            if let hotkey = action.defaultHotkey { result[action] = hotkey }
        }
        return result
    }

    private func migrateHotkeysIfNeeded() {
        let currentVersion = defaults.integer(forKey: Key.hotkeyDefaultsVersion)
        guard currentVersion < 2 else { return }

        if let data = defaults.data(forKey: Key.hotkeys),
           var stored = try? JSONDecoder().decode([String: Hotkey].self, from: data) {
            // Preserve user customisations, but move an untouched first-stage
            // recording default to the newly agreed instant-recording shortcut.
            let oldDefault = Hotkey(
                keyCode: UInt16(kVK_F2),
                modifierFlags: [.command, .shift]
            )
            if stored[HotkeyAction.toggleRecording.rawValue] == oldDefault,
               let newDefault = HotkeyAction.toggleRecording.defaultHotkey {
                stored[HotkeyAction.toggleRecording.rawValue] = newDefault
                let migrated = Dictionary(uniqueKeysWithValues: stored.map { ($0.key, $0.value) })
                defaults.set(try? JSONEncoder().encode(migrated), forKey: Key.hotkeys)
            }
        }
        defaults.set(2, forKey: Key.hotkeyDefaultsVersion)
    }

    // MARK: - Saving

    var saveDirectory: URL {
        get {
            if let path = defaults.string(forKey: Key.saveDirectory) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default
                .urls(for: .picturesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("ScreenCap", isDirectory: true)
                ?? FileManager.default.homeDirectoryForCurrentUser
        }
        set { set(newValue.path, Key.saveDirectory) }
    }

    /// Supports `{date}`, `{time}`, `{timestamp}`, `{width}`, `{height}`.
    var filenameTemplate: String {
        get { defaults.string(forKey: Key.filenameTemplate) ?? "Screenshot_{timestamp}" }
        set { set(newValue, Key.filenameTemplate) }
    }

    var askWhereToSave: Bool {
        get { defaults.bool(forKey: Key.askWhereToSave) }
        set { set(newValue, Key.askWhereToSave) }
    }

    var copyOnSave: Bool {
        get { defaults.bool(forKey: Key.copyOnSave) }
        set { set(newValue, Key.copyOnSave) }
    }

    var playShutterSound: Bool {
        get { defaults.bool(forKey: Key.playShutterSound) }
        set { set(newValue, Key.playShutterSound) }
    }

    /// When enabled, a Retina capture is written at logical (1×) size.
    var downscaleRetina: Bool {
        get { defaults.bool(forKey: Key.downscaleRetina) }
        set { set(newValue, Key.downscaleRetina) }
    }

    // MARK: - Overlay appearance

    var dimOpacity: Double {
        get { defaults.double(forKey: Key.dimOpacity) }
        set { set(min(max(newValue, 0), 0.9), Key.dimOpacity) }
    }

    var showMagnifier: Bool {
        get { defaults.bool(forKey: Key.showMagnifier) }
        set { set(newValue, Key.showMagnifier) }
    }

    var showSizeBadge: Bool {
        get { defaults.bool(forKey: Key.showSizeBadge) }
        set { set(newValue, Key.showSizeBadge) }
    }

    // MARK: - Tool state
    //
    // These are last-used values rather than preferences: they are edited from the
    // overlay's style popover and simply persist between captures. Preferences only
    // offers a reset.

    var toolColor: NSColor {
        get { NSColor(hex: defaults.string(forKey: Key.toolColor) ?? "#FF3B30") ?? .systemRed }
        set { set(newValue.hexString, Key.toolColor) }
    }

    var strokeWidth: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.strokeWidth)) }
        set { set(Double(newValue), Key.strokeWidth) }
    }

    var fontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.fontSize)) }
        set { set(Double(newValue), Key.fontSize) }
    }

    var textBackdrop: TextBackdrop {
        get { TextBackdrop(rawValue: defaults.string(forKey: Key.textBackdrop) ?? "") ?? .none }
        set { set(newValue.rawValue, Key.textBackdrop) }
    }

    var textBackdropColor: NSColor {
        get { NSColor(hex: defaults.string(forKey: Key.textBackdropColor) ?? "#000000") ?? .black }
        set { set(newValue.hexString, Key.textBackdropColor) }
    }

    var eraserRadius: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.eraserRadius)) }
        set { set(Double(newValue), Key.eraserRadius) }
    }

    var eraserShape: ObfuscationShape {
        get { ObfuscationShape(rawValue: defaults.string(forKey: Key.eraserShape) ?? "") ?? .brush }
        set { set(newValue.rawValue, Key.eraserShape) }
    }

    var eraserMode: EraserMode {
        get { EraserMode(rawValue: defaults.string(forKey: Key.eraserMode) ?? "") ?? .pixels }
        set { set(newValue.rawValue, Key.eraserMode) }
    }

    var counterSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.counterSize)) }
        set { set(Double(newValue), Key.counterSize) }
    }

    var counterArrowWidth: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.counterArrowWidth)) }
        set { set(Double(newValue), Key.counterArrowWidth) }
    }

    /// Persisted default for rectangle/ellipse: filled vs outlined.
    var shapeFilled: Bool {
        get { defaults.bool(forKey: Key.shapeFilled) }
        set { set(newValue, Key.shapeFilled) }
    }

    /// Persisted default for the arrow tool: one head vs two.
    var arrowDoubleHeaded: Bool {
        get { defaults.bool(forKey: Key.arrowDoubleHeaded) }
        set { set(newValue, Key.arrowDoubleHeaded) }
    }

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: Key.imageFormat) ?? "") ?? .png }
        set { set(newValue.rawValue, Key.imageFormat) }
    }

    // MARK: - Recording

    /// Recordings use their own directory so adding the recorder never changes
    /// where existing screenshots are saved.
    var recordingDirectory: URL {
        get {
            if let path = defaults.string(forKey: Key.recordingDirectory) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default
                .urls(for: .moviesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("ScreenCap", isDirectory: true)
                ?? saveDirectory
        }
        set { set(newValue.path, Key.recordingDirectory) }
    }

    var recordingFilenameTemplate: String {
        get { defaults.string(forKey: Key.recordingFilenameTemplate) ?? "Recording_{timestamp}" }
        set { set(newValue, Key.recordingFilenameTemplate) }
    }

    var recordingAskWhereToSave: Bool {
        get { defaults.bool(forKey: Key.recordingAskWhereToSave) }
        set { set(newValue, Key.recordingAskWhereToSave) }
    }

    var recordingSkipSystemAudio: Bool {
        get { defaults.bool(forKey: Key.recordingSkipSystemAudio) }
        set { set(newValue, Key.recordingSkipSystemAudio) }
    }

    var recordingSkipMicrophone: Bool {
        get { defaults.bool(forKey: Key.recordingSkipMicrophone) }
        set { set(newValue, Key.recordingSkipMicrophone) }
    }

    var recordingNoiseSuppression: Bool {
        get { defaults.bool(forKey: Key.recordingNoiseSuppression) }
        set { set(newValue, Key.recordingNoiseSuppression) }
    }

    var recordingAtLogicalSize: Bool {
        get { defaults.bool(forKey: Key.recordingAtLogicalSize) }
        set { set(newValue, Key.recordingAtLogicalSize) }
    }

    var recordingVideoCodec: RecordingVideoCodec {
        get {
            RecordingVideoCodec(
                rawValue: defaults.string(forKey: Key.recordingVideoCodec) ?? ""
            ) ?? .automatic
        }
        set { set(newValue.rawValue, Key.recordingVideoCodec) }
    }

    /// Draws macOS's native click indicator into the recorded display stream.
    /// The setting is independent from cursor visibility and can be overridden
    /// for an individual capture in the display picker.
    var recordingShowMouseClicks: Bool {
        get { defaults.bool(forKey: Key.recordingShowMouseClicks) }
        set { set(newValue, Key.recordingShowMouseClicks) }
    }

    var recordingAfterCaptureAction: String? {
        get { defaults.string(forKey: Key.recordingAfterCaptureAction) }
        set {
            if let newValue {
                set(newValue, Key.recordingAfterCaptureAction)
            } else {
                defaults.removeObject(forKey: Key.recordingAfterCaptureAction)
                objectWillChange.send()
            }
        }
    }

    var playerTranscriptionMode: PlayerTranscriptionMode {
        get {
            PlayerTranscriptionMode(
                rawValue: defaults.string(forKey: Key.playerTranscriptionMode) ?? ""
            ) ?? .onDemand
        }
        set { set(newValue.rawValue, Key.playerTranscriptionMode) }
    }

    var obfuscation: ObfuscationSettings {
        get {
            ObfuscationSettings(
                style: ObfuscationStyle(rawValue: defaults.string(forKey: Key.obfuscationStyle) ?? "") ?? .pixelate,
                shape: ObfuscationShape(rawValue: defaults.string(forKey: Key.obfuscationShape) ?? "") ?? .rectangle,
                brushSize: CGFloat(defaults.double(forKey: Key.obfuscationBrushSize)),
                intensity: CGFloat(defaults.double(forKey: Key.obfuscationIntensity))
            )
        }
        set {
            defaults.set(newValue.style.rawValue, forKey: Key.obfuscationStyle)
            defaults.set(newValue.shape.rawValue, forKey: Key.obfuscationShape)
            defaults.set(Double(newValue.brushSize), forKey: Key.obfuscationBrushSize)
            defaults.set(Double(newValue.intensity), forKey: Key.obfuscationIntensity)
            objectWillChange.send()
        }
    }

    static let maximumRecentColors = 9

    /// Recent stroke colors. The old shared key is used as a one-time
    /// compatibility fallback so existing users do not lose their history.
    var recentStrokeColors: [NSColor] {
        get { recentColors(forKey: Key.recentStrokeColors, fallbackKey: Key.recentColors) }
        set { storeRecentColors(newValue, forKey: Key.recentStrokeColors) }
    }

    /// Recent backdrop colors are intentionally independent from stroke
    /// colors: choosing a text background must not change the main palette.
    var recentBackdropColors: [NSColor] {
        get { recentColors(forKey: Key.recentBackdropColors) }
        set { storeRecentColors(newValue, forKey: Key.recentBackdropColors) }
    }

    /// Compatibility alias for callers that still mean the primary/stroke list.
    var recentColors: [NSColor] {
        get { recentStrokeColors }
        set { recentStrokeColors = newValue }
    }

    func noteStrokeColorUsed(_ color: NSColor) {
        var colors = recentStrokeColors.filter { $0.hexString != color.hexString }
        colors.insert(color, at: 0)
        recentStrokeColors = Array(colors.prefix(Self.maximumRecentColors))
    }

    func noteBackdropColorUsed(_ color: NSColor) {
        var colors = recentBackdropColors.filter { $0.hexString != color.hexString }
        colors.insert(color, at: 0)
        recentBackdropColors = Array(colors.prefix(Self.maximumRecentColors))
    }

    private func recentColors(forKey key: String, fallbackKey: String? = nil) -> [NSColor] {
        let stored = defaults.stringArray(forKey: key)
        let values = stored ?? fallbackKey.flatMap { defaults.stringArray(forKey: $0) } ?? []
        return values.prefix(Self.maximumRecentColors).compactMap { NSColor(hex: $0) }
    }

    private func storeRecentColors(_ colors: [NSColor], forKey key: String) {
        set(colors.prefix(Self.maximumRecentColors).map(\.hexString), key)
    }

    /// Kept for source compatibility with older overlay code.
    func noteColorUsed(_ color: NSColor) {
        noteStrokeColorUsed(color)
    }

    /// Restores every drawing-tool value, leaving capture and shortcut settings alone.
    func resetToolDefaults() {
        for (key, value) in Self.toolDefaults {
            defaults.set(value, forKey: key)
        }
        defaults.removeObject(forKey: Key.recentColors)
        defaults.removeObject(forKey: Key.recentStrokeColors)
        defaults.removeObject(forKey: Key.recentBackdropColors)
        objectWillChange.send()
    }

    /// Restores every value on the Capture tab, leaving drawing tools and
    /// shortcuts alone.
    func resetCaptureDefaults() {
        for (key, value) in Self.captureDefaults {
            defaults.set(value, forKey: key)
        }
        defaults.removeObject(forKey: Key.saveDirectory)
        objectWillChange.send()
    }

    /// Restores recording preferences without changing screenshot settings,
    /// drawing tools, or global shortcuts.
    func resetRecordingDefaults() {
        for (key, value) in Self.recordingDefaults {
            defaults.set(value, forKey: key)
        }
        defaults.removeObject(forKey: Key.recordingAfterCaptureAction)
        defaults.removeObject(forKey: Key.recordingDirectory)
        defaults.removeObject(forKey: Key.recordingFilenameTemplate)
        objectWillChange.send()
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("ScreenCap: could not change login item — \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }

    // MARK: - Helpers

    private func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        objectWillChange.send()
    }
}
