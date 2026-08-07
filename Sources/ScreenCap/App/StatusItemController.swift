import AppKit

/// The menu-bar presence: the only permanent UI this app has.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    override init() {
        super.init()

        if let button = statusItem.button {
            let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            button.image = NSImage(
                systemSymbolName: "camera.viewfinder",
                accessibilityDescription: AppInfo.name
            )?.withSymbolConfiguration(configuration)
            button.image?.isTemplate = true
            button.toolTip = AppInfo.name
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hotkeys = Settings.shared.hotkeys

        for action in HotkeyAction.allCases {
            let item = NSMenuItem(
                title: action.title,
                action: #selector(captureAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action
            item.image = symbol(action.symbolName)
            if let hotkey = hotkeys[action] {
                // Shown as a badge: the shortcut is global and handled by Carbon,
                // not by the menu, so a real key equivalent would be a lie.
                item.badge = NSMenuItemBadge(string: hotkey.displayString)
            }
            if action == .repeatLastArea, !CaptureController.shared.hasLastArea {
                item.isEnabled = false
            }
            menu.addItem(item)
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

    private func symbol(_ name: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
