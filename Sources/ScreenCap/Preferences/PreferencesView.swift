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
                        var updated = settings.hotkeys
                        if let newValue {
                            updated[action] = newValue
                        } else {
                            updated.removeValue(forKey: action)
                        }
                        settings.hotkeys = updated
                    }
                    .frame(width: 150, height: 24)
                }
            }

            if !conflicts.isEmpty {
                Text(L10n.t("prefs.shortcut.conflict"))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle(L10n.t("prefs.launchAtLogin"), isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }
            ))

            Text(L10n.t("prefs.shortcut.help"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(L10n.t("prefs.shortcut.reset")) {
                settings.hotkeys = Settings.defaultHotkeys
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(height: 320, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: .hotkeyRegistrationChanged)) { _ in
            conflicts = HotkeyManager.shared.failedActions
        }
    }
}

private struct CaptureTab: View {
    @EnvironmentObject private var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("prefs.saveFolder"))
                Spacer()
                Text(settings.saveDirectory.lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(L10n.t("prefs.choose")) { chooseDirectory() }
            }

            HStack {
                Text(L10n.t("prefs.filenameTemplate"))
                TextField("", text: Binding(
                    get: { settings.filenameTemplate },
                    set: { settings.filenameTemplate = $0 }
                ))
            }
            Text(L10n.t("prefs.filenameTokens"))
                .font(.caption)
                .foregroundStyle(.secondary)

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

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(height: 320, alignment: .top)
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
