import AppKit
import UniformTypeIdentifiers

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
        installMainMenu()

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
            self?.installMainMenu()
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

    /// An accessory app has no menu bar of its own, but the standard Edit menu is
    /// still needed for copy/paste inside the text tool and Preferences.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: L10n.t("menu.about", AppInfo.name),
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
        appMenu.addItem(
            withTitle: L10n.t("menu.quit", AppInfo.name),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

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

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        AboutWindowController.shared.show()
    }
}
