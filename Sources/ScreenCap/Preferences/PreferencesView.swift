import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var selection: Tab = .shortcuts

    /// Recording is currently the tallest tab. Keeping one stable tab height
    /// avoids the preferences window jumping when the user changes tabs.
    static let tabHeight: CGFloat = 560

    enum Tab: Hashable {
        case shortcuts, capture, recording, tools

        var title: String {
            switch self {
            case .shortcuts: return L10n.t("prefs.tab.shortcuts")
            case .capture: return L10n.t("prefs.tab.capture")
            case .recording: return L10n.t("prefs.tab.recording")
            case .tools: return L10n.t("prefs.tab.captureTools")
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array(availableTabs.enumerated()), id: \.element) { index, tab in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(width: 1, height: 15)
                    }

                    Button {
                        selection = tab
                    } label: {
                        Text(tab.title)
                            .lineLimit(1)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == tab ? Color.white : Color.primary)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor)
                        }
                    }
                    .focusable(false)
                    .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .fixedSize()

            Group {
                switch selection {
                case .shortcuts:
                    ShortcutsTab()
                case .capture:
                    CaptureTab()
                case .tools:
                    ToolsTab()
                case .recording:
                    if #available(macOS 15.0, *) {
                        RecordingTab()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 500, height: Self.tabHeight, alignment: .topLeading)
        .padding(16)
        .environmentObject(settings)
    }

    private var availableTabs: [Tab] {
        if #available(macOS 15.0, *) {
            return [.shortcuts, .capture, .tools, .recording]
        }
        return [.shortcuts, .capture, .tools]
    }
}

private struct RecordingVideoApplication: Identifiable, Hashable {
    let url: URL
    let bundleIdentifier: String
    let name: String

    var id: String { bundleIdentifier }
}

private struct ShortcutsTab: View {
    @EnvironmentObject private var settings: Settings
    @State private var conflicts: Set<HotkeyAction> = HotkeyManager.shared.failedActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(HotkeyAction.allCases.filter(\.isAvailable), id: \.self) { action in
                HStack {
                    Label(action.title, systemImage: action.symbolName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if conflicts.contains(action) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(L10n.t("prefs.shortcut.conflict.help"))
                    }
                    HotkeyRecorder(hotkey: settings.hotkeys[action]) { newValue in
                        setHotkey(newValue, for: action)
                    }
                    .frame(width: 150, height: 24)

                    // A dedicated clear button: recording-then-Delete already
                    // works, but it makes you enter recording mode first for
                    // something that should be a single click.
                    Button {
                        setHotkey(nil, for: action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(settings.hotkeys[action] == nil ? 0 : 1)
                    .disabled(settings.hotkeys[action] == nil)
                    .help(L10n.t("prefs.shortcut.clear"))
                }
            }

            if !conflicts.isEmpty {
                Text(L10n.t("prefs.shortcut.conflict"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The hint and the reset button both belong to the list above —
            // keeping them on this side of the divider is what makes the
            // divider mean something (shortcuts vs. the unrelated login toggle
            // below it) rather than being an arbitrary line through one section.
            Text(L10n.t("prefs.shortcut.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(L10n.t("prefs.shortcut.reset")) {
                settings.hotkeys = Settings.defaultHotkeys
            }
            .help(L10n.t("prefs.shortcut.reset"))

            Divider()

            Toggle(L10n.t("prefs.launchAtLogin"), isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }
            ))
            .help(L10n.t("prefs.launchAtLogin"))

        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: .hotkeyRegistrationChanged)) { _ in
            conflicts = HotkeyManager.shared.failedActions
        }
    }

    private func setHotkey(_ newValue: Hotkey?, for action: HotkeyAction) {
        var updated = settings.hotkeys
        if let newValue {
            updated[action] = newValue
        } else {
            updated.removeValue(forKey: action)
        }
        settings.hotkeys = updated
    }
}

private struct CaptureTab: View {
    @EnvironmentObject private var settings: Settings
    @StateObject private var filenameBridge = FilenameFieldBridge()

    private static let filenameTokens = ["{date}", "{time}", "{timestamp}", "{width}", "{height}"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("prefs.saveFolder"))
                Spacer()
                Text(settings.saveDirectory.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(L10n.t("prefs.choose")) { chooseDirectory() }
                    .help(L10n.t("prefs.choose"))
            }

            HStack {
                Text(L10n.t("prefs.filenameTemplate"))
                FilenameField(text: filenameTemplateBinding, bridge: filenameBridge)
                    .help(L10n.t("prefs.filenameTemplate"))
            }
            HStack(spacing: 4) {
                Text(L10n.t("prefs.filenameTokens"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Self.filenameTokens, id: \.self) { token in
                    Button(token) {
                        filenameBridge.insert(token, into: filenameTemplateBinding)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(token)
                }
            }

            Toggle(L10n.t("prefs.askWhereToSave"), isOn: Binding(
                get: { settings.askWhereToSave },
                set: { settings.askWhereToSave = $0 }
            ))
            Toggle(L10n.t("prefs.copyOnSave"), isOn: Binding(
                get: { settings.copyOnSave },
                set: { settings.copyOnSave = $0 }
            ))
            Toggle(L10n.t("prefs.downscaleRetina"), isOn: Binding(
                get: { settings.downscaleRetina },
                set: { settings.downscaleRetina = $0 }
            ))
            Toggle(L10n.t("prefs.shutterSound"), isOn: Binding(
                get: { settings.playShutterSound },
                set: { settings.playShutterSound = $0 }
            ))

            HStack {
                Text(L10n.t("prefs.imageFormat"))
                Picker("", selection: Binding(
                    get: { settings.imageFormat },
                    set: { settings.imageFormat = $0 }
                )) {
                    ForEach(ImageFormat.allCases, id: \.self) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .labelsHidden()
                .help(L10n.t("prefs.imageFormat"))
            }

            Divider()

            Toggle(L10n.t("prefs.showMagnifier"), isOn: Binding(
                get: { settings.showMagnifier },
                set: { settings.showMagnifier = $0 }
            ))
            Toggle(L10n.t("prefs.showSizeBadge"), isOn: Binding(
                get: { settings.showSizeBadge },
                set: { settings.showSizeBadge = $0 }
            ))

            HStack {
                Text(L10n.t("prefs.dimming"))
                Slider(
                    value: Binding(
                        get: { settings.dimOpacity },
                        set: { settings.dimOpacity = $0 }
                    ),
                    in: 0...0.9
                )
                Text("\(Int(settings.dimOpacity * 100))%")
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }

            Divider()

            Button(L10n.t("prefs.resetCapture")) {
                settings.resetCaptureDefaults()
            }
            .help(L10n.t("prefs.resetCapture"))

        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filenameTemplateBinding: Binding<String> {
        Binding(get: { settings.filenameTemplate }, set: { settings.filenameTemplate = $0 })
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
        }
    }
}

private struct RecordingTab: View {
    @EnvironmentObject private var settings: Settings
    @StateObject private var filenameBridge = FilenameFieldBridge()
    @State private var videoApplications: [RecordingVideoApplication] = []

    private static let filenameTokens = ["{date}", "{time}", "{timestamp}", "{width}", "{height}"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("prefs.saveFolder"))
                Spacer()
                Text(settings.recordingDirectory.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(L10n.t("prefs.choose")) { chooseDirectory() }
                    .help(L10n.t("prefs.choose"))
            }

            HStack {
                Text(L10n.t("prefs.filenameTemplate"))
                FilenameField(text: filenameTemplateBinding, bridge: filenameBridge)
                    .help(L10n.t("prefs.filenameTemplate"))
            }
            HStack(spacing: 4) {
                Text(L10n.t("prefs.filenameTokens"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Self.filenameTokens, id: \.self) { token in
                    Button(token) {
                        filenameBridge.insert(token, into: filenameTemplateBinding)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help(token)
                }
            }

            Toggle(L10n.t("prefs.askWhereToSave"), isOn: Binding(
                get: { settings.recordingAskWhereToSave },
                set: { settings.recordingAskWhereToSave = $0 }
            ))

            Toggle(L10n.t("prefs.recording.skipSystemAudio"), isOn: Binding(
                get: { settings.recordingSkipSystemAudio },
                set: { settings.recordingSkipSystemAudio = $0 }
            ))
            Toggle(L10n.t("prefs.recording.skipMicrophone"), isOn: Binding(
                get: { settings.recordingSkipMicrophone },
                set: { settings.recordingSkipMicrophone = $0 }
            ))

            Divider()

            Toggle(L10n.t("prefs.recording.noiseSuppression"), isOn: Binding(
                get: { settings.recordingNoiseSuppression },
                set: { settings.recordingNoiseSuppression = $0 }
            ))
            Text(.init(L10n.t("prefs.recording.noiseSuppression.help")))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle(L10n.t("prefs.recording.logicalSize"), isOn: Binding(
                get: { settings.recordingAtLogicalSize },
                set: { settings.recordingAtLogicalSize = $0 }
            ))
            Text(L10n.t("prefs.recording.logicalSize.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.t("prefs.recording.showMouseClicks"), isOn: Binding(
                get: { settings.recordingShowMouseClicks },
                set: { settings.recordingShowMouseClicks = $0 }
            ))
            Text(L10n.t("prefs.recording.showMouseClicks.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(L10n.t("prefs.recording.codec"))
                Spacer()
                Picker("", selection: Binding(
                    get: { settings.recordingVideoCodec },
                    set: { settings.recordingVideoCodec = $0 }
                )) {
                    ForEach(RecordingVideoCodec.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                .labelsHidden()
                .frame(width: 270, alignment: .trailing)
                .help(L10n.t("prefs.recording.codec.help"))
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text(L10n.t("prefs.recording.afterCapture"))
                Spacer()
                Picker("", selection: afterCaptureBinding) {
                    Text(L10n.t("prefs.recording.afterCapture.ask"))
                        .tag(RecordingAfterCaptureAction.notConfigured)
                    Text(L10n.t("prefs.recording.afterCapture.nothing"))
                        .tag(RecordingAfterCaptureAction.nothing)
                    Text(L10n.t("prefs.recording.afterCapture.showInFolder"))
                        .tag(RecordingAfterCaptureAction.showInFolder)
                    Text(L10n.t("prefs.recording.afterCapture.openInPlayer"))
                        .tag(RecordingAfterCaptureAction.openInPlayer)
                    ForEach(videoApplications) { application in
                        Text(L10n.t("prefs.recording.afterCapture.openWith", application.name))
                            .tag(RecordingAfterCaptureAction.application(application.bundleIdentifier))
                    }
                }
                .labelsHidden()
                .frame(width: 270, alignment: .trailing)
            }
            Text(L10n.t("prefs.recording.afterCapture.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button(L10n.t("prefs.recording.reset")) {
                settings.resetRecordingDefaults()
            }
            .help(L10n.t("prefs.recording.reset"))

        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            refreshVideoApplications()
        }
    }

    private var filenameTemplateBinding: Binding<String> {
        Binding(
            get: { settings.recordingFilenameTemplate },
            set: { settings.recordingFilenameTemplate = $0 }
        )
    }

    private var afterCaptureBinding: Binding<String> {
        Binding(
            get: { settings.recordingAfterCaptureAction ?? RecordingAfterCaptureAction.notConfigured },
            set: {
                settings.recordingAfterCaptureAction = $0 == RecordingAfterCaptureAction.notConfigured
                    ? nil
                    : $0
            }
        )
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.recordingDirectory
        if panel.runModal() == .OK, let url = panel.url {
            settings.recordingDirectory = url
        }
    }

    private func refreshVideoApplications() {
        let applications = NSWorkspace.shared
            // ScreenCap writes QuickTime movie containers. Querying the
            // umbrella `public.movie` type misses apps such as VLC that
            // register the concrete QuickTime movie UTI instead.
            .urlsForApplications(toOpen: .quickTimeMovie)
            .compactMap { url -> RecordingVideoApplication? in
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier
                else { return nil }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                return RecordingVideoApplication(
                    url: url,
                    bundleIdentifier: bundleIdentifier,
                    name: name
                )
            }
            .reduce(into: [RecordingVideoApplication]()) { result, application in
                guard !result.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) else {
                    return
                }
                result.append(application)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        videoApplications = applications
        if let selected = RecordingAfterCaptureAction.bundleIdentifier(
            from: settings.recordingAfterCaptureAction ?? RecordingAfterCaptureAction.notConfigured
        ), !applications.contains(where: { $0.bundleIdentifier == selected }) {
            settings.recordingAfterCaptureAction = RecordingAfterCaptureAction.nothing
        }
    }
}

/// Bridges the file-name-template field to token-insertion-at-the-caret, since
/// a plain SwiftUI `TextField` exposes no caret position to insert into.
@MainActor
final class FilenameFieldBridge: ObservableObject {
    fileprivate weak var textField: NSTextField?

    func insert(_ token: String, into binding: Binding<String>) {
        guard let textField, let editor = textField.currentEditor() else {
            binding.wrappedValue += token
            return
        }
        editor.replaceCharacters(in: editor.selectedRange, with: token)
        binding.wrappedValue = textField.stringValue
    }
}

private struct FilenameField: NSViewRepresentable {
    @Binding var text: String
    let bridge: FilenameFieldBridge

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        bridge.textField = field
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// Drawing options live in the overlay's own popover, next to the drawing. All
/// that is left here is the escape hatch when they have been fiddled into a mess.
private struct ToolsTab: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("prefs.tools.explainer"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(L10n.t("prefs.tools.reset")) {
                settings.resetToolDefaults()
            }
            .help(L10n.t("prefs.tools.reset"))

            Divider()

            Text(L10n.t("prefs.overlayShortcuts"))
                .font(.headline)

            Text(toolShortcuts)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(actionShortcuts)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(modifierShortcuts)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolShortcuts: String {
        ToolStrip.tools
            .map { "\($0.shortcutKey) — \($0.title.lowercased())" }
            .joined(separator: " · ")
    }

    private var actionShortcuts: String {
        L10n.t("prefs.shortcuts.actions")
    }

    private var modifierShortcuts: String {
        L10n.t("prefs.shortcuts.modifiers")
    }
}
