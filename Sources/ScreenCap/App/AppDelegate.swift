import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    /// Set from `--capture <mode>` so the app can be driven from a script.
    var launchAction: HotkeyAction?
    /// Set from `--window <name>`; see `main.swift`.
    var launchWindow: String?

    /// AppKit only wires `application(_:open:)` to the GetURL Apple Event under
    /// conditions an accessory app with no nib does not reliably meet, so the
    /// handler is installed by hand — and before launch finishes, or a URL that
    /// arrives during startup is dropped.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string)
        else { return }
        handle(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        L10n.reload()
        Task { @MainActor [weak self] in
            self?.installMainMenu(playerVisible: false)
        }

        if #available(macOS 15.0, *) {
            Task {
                await RecorderRecovery.recoverStaleRecordings(
                    in: Settings.shared.recordingDirectory
                )
            }
        }

        statusItem = StatusItemController()

        HotkeyManager.shared.handler = { action in
            CaptureController.shared.perform(action)
        }
        HotkeyManager.shared.apply(Settings.shared.hotkeys)

        NotificationCenter.default.addObserver(
            forName: .languageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installMainMenu(playerVisible: PlayerWindowController.shared.isVisible)
            }
        }

        // Ask through macOS itself when access is missing. The app-owned fallback
        // alert is shown only after this native request has completed without access.
        if !ScreenCapture.hasPermission {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // The first launch must show only Apple's native prompt. If it
                // has already been answered and a later event still lacks
                // access, CaptureController presents the fallback alert.
                CaptureController.shared.requestScreenRecordingPermission(showFallback: false)
            }
        }

        if let launchAction {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                CaptureController.shared.perform(launchAction)
            }
        }
        if let launchWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.handle(URL(string: "screencap://\(launchWindow)")!)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if #available(macOS 15.0, *), RecorderController.shared.isActive {
            RecorderController.shared.stopForTermination {
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotkeyManager.shared.unregisterAll()
    }

    /// `screencap://area|repeat|window|fullscreen|record|preferences`.
    ///
    /// Gives Shortcuts, Raycast, Automator and plain `open` a way in when a
    /// global shortcut is already taken by another app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "screencap" {
                handle(url)
            } else if url.isFileURL {
                openDocument(url)
            }
        }
    }

    /// Finder may deliver a document through the legacy open-files event when
    /// the app is registered as an image handler. Keep it as a compatibility
    /// path alongside `application(_:open:)`.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames.forEach { openDocument(URL(fileURLWithPath: $0)) }
        sender.reply(toOpenOrPrint: .success)
    }

    private func handle(_ url: URL) {
        guard url.scheme == "screencap" else { return }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        Log.debug("url command: \(command)")

        switch command {
        case "area", "": CaptureController.shared.perform(.captureArea)
        case "repeat", "last": CaptureController.shared.perform(.repeatLastArea)
        case "window": CaptureController.shared.perform(.captureWindow)
        case "fullscreen", "screen": CaptureController.shared.perform(.captureFullScreen)
        case "record", "recording": CaptureController.shared.perform(.toggleRecording)
        case "preferences", "settings": PreferencesWindowController.shared.show()
        case "player", "playback": DispatchQueue.main.async { PlayerWindowController.shared.show() }
        case "about": AboutWindowController.shared.show()
        default: NSLog("ScreenCap: unknown URL command — \(command)")
        }
    }

    private func openDocument(_ url: URL) {
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        if contentType?.conforms(to: .movie) == true ||
            ["mov", "mp4", "m4v", "m4a", "avi", "mkv", "webm"].contains(url.pathExtension.lowercased()) {
            DispatchQueue.main.async { PlayerWindowController.shared.show(url: url) }
        } else {
            CaptureController.shared.openImage(url)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Switches the process between its normal menu-bar utility role and the
    /// regular application role used while the Player window is open. A regular
    /// activation policy is what makes the Player appear beside Apple in the
    /// menu bar, in Cmd-Tab, and in Mission Control/Fn-F3.
    @MainActor
    func setPlayerWindowVisible(_ visible: Bool) {
        if visible {
            _ = NSApp.setActivationPolicy(.regular)
            installMainMenu(playerVisible: true)
        } else {
            installMainMenu(playerVisible: false)
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    /// The permanent status item remains the entry point while ScreenCap is an
    /// accessory app. When Player is visible this becomes a conventional macOS
    /// application menu with File/Edit/View/Window/Help sections.
    @MainActor
    private func installMainMenu(playerVisible: Bool) {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: AppInfo.menuName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: L10n.t("menu.about", AppInfo.menuName),
            action: #selector(showAbout),
            keyEquivalent: ""
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L10n.t("menu.settings"),
            action: #selector(StatusItemController.openPreferences),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
        let openPlayer = appMenu.addItem(
            withTitle: L10n.t("menu.player"),
            action: #selector(openPlayerFromMainMenu),
            keyEquivalent: ""
        )
        openPlayer.target = self
        if playerVisible {
            openPlayer.isHidden = true
        }
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L10n.t("menu.quit", AppInfo.menuName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        if playerVisible {
            let fileMenuItem = NSMenuItem(title: L10n.t("menu.file"), action: nil, keyEquivalent: "")
            let fileMenu = NSMenu(title: L10n.t("menu.file"))
            let openVideo = fileMenu.addItem(
                withTitle: L10n.t("menu.openVideo"),
                action: #selector(PlayerWindowController.openVideoFromMenu(_:)),
                keyEquivalent: "o"
            )
            openVideo.target = PlayerWindowController.shared
            let openFolder = fileMenu.addItem(
                withTitle: L10n.t("menu.openFolder"),
                action: #selector(PlayerWindowController.openFolderFromMenu(_:)),
                keyEquivalent: ""
            )
            openFolder.target = PlayerWindowController.shared
            fileMenu.addItem(.separator())
            fileMenu.addItem(
                withTitle: L10n.t("menu.closeWindow"),
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
            fileMenuItem.submenu = fileMenu
            mainMenu.addItem(fileMenuItem)
        }

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.t("menu.edit"))
        editMenu.addItem(withTitle: L10n.t("action.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.t("action.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.t("action.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t("action.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t("action.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.t("action.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        if playerVisible {
            let viewMenuItem = NSMenuItem(title: L10n.t("menu.view"), action: nil, keyEquivalent: "")
            let viewMenu = NSMenu(title: L10n.t("menu.view"))
            let showPlayer = viewMenu.addItem(
                withTitle: L10n.t("menu.player"),
                action: #selector(openPlayerFromMainMenu),
                keyEquivalent: ""
            )
            showPlayer.target = self
            viewMenuItem.submenu = viewMenu
            mainMenu.addItem(viewMenuItem)

            let windowMenuItem = NSMenuItem(title: L10n.t("menu.window"), action: nil, keyEquivalent: "")
            let windowMenu = NSMenu(title: L10n.t("menu.window"))
            windowMenu.addItem(
                withTitle: L10n.t("menu.minimize"),
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
            windowMenu.addItem(
                withTitle: L10n.t("menu.zoom"),
                action: #selector(NSWindow.performZoom(_:)),
                keyEquivalent: ""
            )
            windowMenu.addItem(.separator())
            windowMenu.addItem(
                withTitle: L10n.t("menu.bringAllToFront"),
                action: #selector(NSApplication.arrangeInFront(_:)),
                keyEquivalent: ""
            )
            windowMenuItem.submenu = windowMenu
            mainMenu.addItem(windowMenuItem)
            NSApp.windowsMenu = windowMenu
        } else {
            NSApp.windowsMenu = nil
        }

        let helpMenuItem = NSMenuItem(title: L10n.t("menu.help"), action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: L10n.t("menu.help"))
        let support = helpMenu.addItem(
            withTitle: L10n.t("menu.support"),
            action: #selector(openSupport),
            keyEquivalent: ""
        )
        support.target = self
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @MainActor @objc private func openPlayerFromMainMenu() {
        Task { @MainActor in
            PlayerWindowController.shared.show()
        }
    }

    @objc private func openSupport() {
        NSWorkspace.shared.open(AppInfo.supportURL)
    }

    @objc private func showAbout() {
        AboutWindowController.shared.show()
    }
}
