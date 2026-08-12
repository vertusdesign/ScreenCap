import AppKit

/// The menu-bar presence: the only permanent UI this app has.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var recorderMicrophoneStatusItem: NSStatusItem?
    private var recorderSystemAudioStatusItem: NSStatusItem?

    override init() {
        super.init()

        if let button = statusItem.button {
            button.image = MenuBarIcon.image()
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = AppInfo.name
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRecorderMicrophoneStatusItem),
            name: .recorderStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRecorderMicrophoneStatusItem),
            name: .recorderMicrophoneChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRecorderSystemAudioStatusItem),
            name: .recorderStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRecorderSystemAudioStatusItem),
            name: .recorderSystemAudioChanged,
            object: nil
        )
        updateRecorderMicrophoneStatusItem()
        updateRecorderSystemAudioStatusItem()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let recorderMicrophoneStatusItem {
            NSStatusBar.system.removeStatusItem(recorderMicrophoneStatusItem)
        }
        if let recorderSystemAudioStatusItem {
            NSStatusBar.system.removeStatusItem(recorderSystemAudioStatusItem)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hotkeys = Settings.shared.hotkeys

        if !ScreenCapture.hasPermission {
            let permission = NSMenuItem(
                title: L10n.t("permission.toast"),
                action: #selector(requestScreenRecordingPermission),
                keyEquivalent: ""
            )
            permission.target = self
            permission.image = symbol("exclamationmark.triangle.fill")
            menu.addItem(permission)
            menu.addItem(.separator())
        }

        for action in HotkeyAction.allCases where action.isAvailable {
            if action == .toggleRecording {
                // Keep screenshot actions and recording actions as two visible
                // groups in the menu. The microphone toggle itself lives in the
                // menu bar while a recording is active.
                menu.addItem(.separator())
            }
            if action == .toggleRecordingMicrophone || action == .toggleRecordingSystemAudio {
                continue
            }
            let item = NSMenuItem(
                title: menuTitle(for: action),
                action: #selector(captureAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action
            item.image = symbol(symbolName(for: action))
            if let hotkey = hotkeys[action] {
                // Shown as a badge: the shortcut is global and handled by Carbon,
                // not by the menu, so a real key equivalent would be a lie.
                item.badge = NSMenuItemBadge(string: hotkey.displayString)
            }
            if action == .repeatLastArea, !CaptureController.shared.hasLastArea {
                item.isEnabled = false
            }
            if action == .toggleRecordingMicrophone, #available(macOS 15.0, *) {
                item.isEnabled = RecorderController.shared.isActive
            }
            menu.addItem(item)
        }

        if #available(macOS 15.0, *) {
            addRecordingAudioPreferences(to: menu)
        }

        menu.addItem(.separator())

        let language = NSMenuItem(title: L10n.t("menu.language"), action: nil, keyEquivalent: "")
        language.image = symbol("globe")
        language.submenu = buildLanguageMenu()
        menu.addItem(language)

        let launch = NSMenuItem(
            title: L10n.t("menu.launchAtLogin"),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = Settings.shared.launchAtLogin ? .on : .off
        menu.addItem(launch)

        let preferences = NSMenuItem(
            title: L10n.t("menu.settings"),
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        preferences.target = self
        preferences.image = symbol("gearshape")
        menu.addItem(preferences)

        menu.addItem(.separator())

        let about = NSMenuItem(
            title: L10n.t("menu.about", AppInfo.name),
            action: #selector(openAbout),
            keyEquivalent: ""
        )
        about.target = self
        about.image = symbol("info.circle")
        menu.addItem(about)

        let updates = NSMenuItem(
            title: L10n.t("menu.checkForUpdates"),
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updates.target = self
        menu.addItem(updates)

        let quit = NSMenuItem(
            title: L10n.t("menu.quit", AppInfo.name),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        quit.image = symbol("power")
        menu.addItem(quit)
    }

    private func menuTitle(for action: HotkeyAction) -> String {
        if #available(macOS 15.0, *) {
            switch action {
            case .toggleRecording:
                return RecorderController.shared.menuTitle
            case .chooseRecordingDisplay:
                return RecorderController.shared.isActive
                    ? L10n.t("recording.stop")
                    : action.title
            case .toggleRecordingMicrophone:
                return RecorderController.shared.microphoneMenuTitle
            case .toggleRecordingSystemAudio:
                return RecorderController.shared.systemAudioMenuTitle
            default:
                break
            }
        }
        return action.title
    }

    private func symbolName(for action: HotkeyAction) -> String {
        if action == .toggleRecordingMicrophone, #available(macOS 15.0, *) {
            return RecorderController.shared.microphoneSymbolName
        }
        if action == .toggleRecordingSystemAudio, #available(macOS 15.0, *) {
            return RecorderController.shared.systemAudioSymbolName
        }
        return action.symbolName
    }

    private func buildLanguageMenu() -> NSMenu {
        let submenu = NSMenu()
        let current = Settings.shared.preferredLanguage

        let system = NSMenuItem(
            title: L10n.t("menu.language.system"),
            action: #selector(selectLanguage(_:)),
            keyEquivalent: ""
        )
        system.target = self
        system.representedObject = nil
        system.state = current == nil ? .on : .off
        submenu.addItem(system)
        submenu.addItem(.separator())

        for language in AppLanguage.menuOrder {
            let item = NSMenuItem(
                title: language.nativeName,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            item.state = current == language ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @available(macOS 15.0, *)
    private func addRecordingAudioPreferences(to menu: NSMenu) {
        let hotkeys = Settings.shared.hotkeys

        let systemAudio = NSMenuItem(
            title: L10n.t("recording.skipSystemAudio"),
            action: #selector(toggleRecordingAudioPreference(_:)),
            keyEquivalent: ""
        )
        systemAudio.target = self
        systemAudio.representedObject = "systemAudio"
        systemAudio.state = Settings.shared.recordingSkipSystemAudio ? .on : .off
        systemAudio.isEnabled = !RecorderController.shared.isActive
        if let hotkey = hotkeys[.toggleRecordingSystemAudio] {
            systemAudio.badge = NSMenuItemBadge(string: hotkey.displayString)
        }
        menu.addItem(systemAudio)

        let microphone = NSMenuItem(
            title: L10n.t("recording.skipMicrophone"),
            action: #selector(toggleRecordingAudioPreference(_:)),
            keyEquivalent: ""
        )
        microphone.target = self
        microphone.representedObject = "microphone"
        microphone.state = Settings.shared.recordingSkipMicrophone ? .on : .off
        microphone.isEnabled = !RecorderController.shared.isActive
        if let hotkey = hotkeys[.toggleRecordingMicrophone] {
            microphone.badge = NSMenuItemBadge(string: hotkey.displayString)
        }
        menu.addItem(microphone)
    }

    private func symbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    @objc private func updateRecorderMicrophoneStatusItem() {
        guard #available(macOS 15.0, *) else { return }

        if RecorderController.shared.isActive {
            let item = recorderMicrophoneStatusItem ?? makeRecorderMicrophoneStatusItem()
            recorderMicrophoneStatusItem = item
            guard let button = item.button else { return }
            button.image = symbol(RecorderController.shared.microphoneSymbolName)
            button.toolTip = RecorderController.shared.microphoneMenuTitle
            button.setAccessibilityLabel(RecorderController.shared.microphoneMenuTitle)
            button.setAccessibilityRoleDescription(L10n.t("recording.microphoneStatusRole"))
        } else if let item = recorderMicrophoneStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            recorderMicrophoneStatusItem = nil
        }
    }

    @objc private func toggleRecorderMicrophoneFromStatusItem() {
        guard #available(macOS 15.0, *) else { return }
        RecorderController.shared.toggleMicrophone()
        updateRecorderMicrophoneStatusItem()
    }

    private func makeRecorderMicrophoneStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(toggleRecorderMicrophoneFromStatusItem)
            button.imageScaling = .scaleProportionallyDown
        }
        return item
    }

    @objc private func updateRecorderSystemAudioStatusItem() {
        guard #available(macOS 15.0, *) else { return }

        if RecorderController.shared.isActive {
            let item = recorderSystemAudioStatusItem ?? makeRecorderSystemAudioStatusItem()
            recorderSystemAudioStatusItem = item
            guard let button = item.button else { return }
            button.image = symbol(RecorderController.shared.systemAudioSymbolName)
            button.toolTip = RecorderController.shared.systemAudioMenuTitle
            button.setAccessibilityLabel(RecorderController.shared.systemAudioMenuTitle)
            button.setAccessibilityRoleDescription(L10n.t("recording.systemAudioStatusRole"))
        } else if let item = recorderSystemAudioStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            recorderSystemAudioStatusItem = nil
        }
    }

    @objc private func toggleRecorderSystemAudioFromStatusItem() {
        guard #available(macOS 15.0, *) else { return }
        RecorderController.shared.toggleSystemAudio()
        updateRecorderSystemAudioStatusItem()
    }

    private func makeRecorderSystemAudioStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(toggleRecorderSystemAudioFromStatusItem)
            button.imageScaling = .scaleProportionallyDown
        }
        return item
    }

    // MARK: - Actions

    @objc private func captureAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? HotkeyAction else { return }
        // Let the menu finish closing so it does not end up in the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CaptureController.shared.perform(action)
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String
        Settings.shared.preferredLanguage = raw.flatMap(AppLanguage.init(rawValue:))
    }

    @objc private func toggleRecordingAudioPreference(_ sender: NSMenuItem) {
        guard #available(macOS 15.0, *) else { return }
        guard !RecorderController.shared.isActive,
              let preference = sender.representedObject as? String
        else { return }

        switch preference {
        case "systemAudio":
            Settings.shared.recordingSkipSystemAudio.toggle()
        case "microphone":
            Settings.shared.recordingSkipMicrophone.toggle()
        default:
            break
        }
    }

    @objc private func toggleLaunchAtLogin() {
        Settings.shared.launchAtLogin.toggle()
    }

    @objc func openPreferences() {
        PreferencesWindowController.shared.show()
    }

    @objc private func openAbout() {
        AboutWindowController.shared.show()
    }

    @objc private func checkForUpdates() {
        // No update server: the releases page is the source of truth, and sending
        // people there beats bundling an updater the project cannot sign.
        NSWorkspace.shared.open(AppInfo.releasesURL)
    }

    @objc private func requestScreenRecordingPermission() {
        // Let the menu close before macOS presents its own permission dialog.
        DispatchQueue.main.async {
            CaptureController.shared.requestScreenRecordingPermission()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
