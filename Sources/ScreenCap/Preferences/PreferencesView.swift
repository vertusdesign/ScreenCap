import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var selection: Tab = .shortcuts

    enum Tab: Hashable {
        case shortcuts, capture, tools
    }

    var body: some View {
        TabView(selection: $selection) {
            ShortcutsTab()
                .tabItem { Label(L10n.t("prefs.tab.shortcuts"), systemImage: "keyboard") }
                .tag(Tab.shortcuts)
            CaptureTab()
                .tabItem { Label(L10n.t("prefs.tab.capture"), systemImage: "camera") }
                .tag(Tab.capture)
            ToolsTab()
                .tabItem { Label(L10n.t("prefs.tab.tools"), systemImage: "paintbrush") }
                .tag(Tab.tools)
        }
        .frame(width: 500)
        .padding(16)
        .environmentObject(settings)
    }
}

private struct ShortcutsTab: View {
    @EnvironmentObject private var settings: Settings
    @State private var conflicts: Set<HotkeyAction> = HotkeyManager.shared.failedActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(HotkeyAction.allCases, id: \.self) { action in
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

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(height: 340, alignment: .top)
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

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        // A hardcoded height here has twice now fallen behind the row count
        // that grew underneath it and clipped the reset button — let SwiftUI
        // report the tab's actual content height instead of guessing again.
        .fixedSize(horizontal: false, vertical: true)
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

/// Bridges the file-name-template field to token-insertion-at-the-caret, since
/// a plain SwiftUI `TextField` exposes no caret position to insert into.
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

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(height: 320, alignment: .top)
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
