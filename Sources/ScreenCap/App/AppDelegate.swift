import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var systemObservers: [NSObjectProtocol] = []
    private var workspaceNotificationCenter: NotificationCenter?

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
        SystemNotificationCoordinator.shared.configure()
        Task { @MainActor [weak self] in
            self?.installMainMenu(playerVisible: false)
        }

        if #available(macOS 15.0, *) {
            RecorderRecoveryCoordinator.shared.recoverAtLaunch()
            installRecordingInterruptionObservers()
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
                SystemNotificationCoordinator.shared.configure()
#if SCREENCAP_PRO
                self.installMainMenu(playerVisible: PlayerWindowController.shared.isVisible)
#else
                self.installMainMenu(playerVisible: false)
#endif
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
                self.handle(URL(string: "\(AppInfo.urlScheme)://\(launchWindow)")!)
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
        systemObservers.forEach {
            NotificationCenter.default.removeObserver($0)
            workspaceNotificationCenter?.removeObserver($0)
        }
        systemObservers.removeAll()
        workspaceNotificationCenter = nil
        HotkeyManager.shared.unregisterAll()
    }

    /// `<bundle URL scheme>://area|repeat|window|fullscreen|record|preferences`.
    ///
    /// Gives Shortcuts, Raycast, Automator and plain `open` a way in when a
    /// global shortcut is already taken by another app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == AppInfo.urlScheme {
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
        guard url.scheme == AppInfo.urlScheme else { return }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        Log.debug("url command: \(command)")

        switch command {
        case "area", "": CaptureController.shared.perform(.captureArea)
        case "repeat", "last": CaptureController.shared.perform(.repeatLastArea)
        case "window": CaptureController.shared.perform(.captureWindow)
        case "fullscreen", "screen": CaptureController.shared.perform(.captureFullScreen)
        case "record", "recording": CaptureController.shared.perform(.toggleRecording)
        case "preferences", "settings": PreferencesWindowController.shared.show()
#if SCREENCAP_PRO
        case "player", "playback": DispatchQueue.main.async { PlayerWindowController.shared.show() }
#endif
        case "about": AboutWindowController.shared.show()
        default: NSLog("ScreenCap: unknown URL command — \(command)")
        }
    }

    private func openDocument(_ url: URL) {
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        if contentType?.conforms(to: .movie) == true ||
            ["mov", "mp4", "m4v", "m4a", "avi", "mkv", "webm"].contains(url.pathExtension.lowercased()) {
#if SCREENCAP_PRO
            DispatchQueue.main.async { PlayerWindowController.shared.show(url: url) }
#else
            NSWorkspace.shared.open(url)
#endif
        } else {
            CaptureController.shared.openImage(url)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Switches the process between its normal menu-bar utility role and the
    /// regular application role used while the Player window is open. A regular
    /// activation policy is what makes the Player appear beside Apple in the
    /// menu bar, in Cmd-Tab, and in Mission Control/Fn-F3.
#if SCREENCAP_PRO
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
#endif

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
            withTitle: L10n.t("menu.recoverRecordings"),
            action: #selector(recoverRecordingsFromMainMenu),
            keyEquivalent: ""
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L10n.t("menu.settings"),
            action: #selector(StatusItemController.openPreferences),
            keyEquivalent: ","
        )
        appMenu.addItem(.separator())
#if SCREENCAP_PRO
        let openPlayer = appMenu.addItem(
            withTitle: L10n.t("menu.player"),
            action: #selector(openPlayerFromMainMenu),
            keyEquivalent: ""
        )
        openPlayer.target = self
        if playerVisible {
            openPlayer.isHidden = true
        }
#endif
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: L10n.t("menu.quit", AppInfo.menuName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

#if SCREENCAP_PRO
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
            let exportItem = NSMenuItem(title: L10n.t("menu.player.export"), action: nil, keyEquivalent: "e")
            let exportMenu = NSMenu(title: L10n.t("menu.player.export"))
            let videoPresets: [(PlayerExportPreset, String)] = [
                (.source, L10n.t("player.export.preset.source")),
                (.fourK, L10n.t("player.export.preset.fourK")),
                (.fullHD, L10n.t("player.export.preset.fullHD")),
                (.hd, L10n.t("player.export.preset.hd")),
                (.sd, L10n.t("player.export.preset.sd"))
            ]
            for (preset, title) in videoPresets {
                let presetItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let presetMenu = NSMenu(title: title)
                for format in PlayerExportFormat.allCases {
                    let item = presetMenu.addItem(withTitle: format.title, action: #selector(PlayerWindowController.exportPresetFromMenu(_:)), keyEquivalent: "")
                    item.target = PlayerWindowController.shared
                    item.representedObject = "\(preset.rawValue)|\(format.rawValue)"
                }
                presetItem.submenu = presetMenu
                exportMenu.addItem(presetItem)
            }
            exportMenu.addItem(.separator())
            let audio = exportMenu.addItem(withTitle: L10n.t("player.export.preset.audioOnly"), action: #selector(PlayerWindowController.exportPresetFromMenu(_:)), keyEquivalent: "")
            audio.target = PlayerWindowController.shared
            audio.representedObject = "\(PlayerExportPreset.audioOnly.rawValue)|\(PlayerExportFormat.mov.rawValue)"
            exportItem.submenu = exportMenu
            fileMenu.addItem(exportItem)
            let replace = fileMenu.addItem(
                withTitle: L10n.t("player.export.replace"),
                action: #selector(PlayerWindowController.requestReplaceFromMenu(_:)),
                keyEquivalent: ""
            )
            replace.target = PlayerWindowController.shared
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
        let undo = editMenu.addItem(withTitle: L10n.t("action.undo"), action: #selector(PlayerWindowController.undoFromMenu(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L10n.t("action.redo"), action: #selector(PlayerWindowController.redoFromMenu(_:)), keyEquivalent: "Z")
        if playerVisible {
            undo.target = PlayerWindowController.shared
            redo.target = PlayerWindowController.shared
            undo.isEnabled = PlayerWindowController.shared.canUndo
            redo.isEnabled = PlayerWindowController.shared.canRedo
            let reset = editMenu.addItem(withTitle: L10n.t("menu.player.resetEdits"), action: #selector(PlayerWindowController.resetEditsFromMenu(_:)), keyEquivalent: "")
            reset.target = PlayerWindowController.shared
            reset.isEnabled = PlayerWindowController.shared.canUndo || PlayerWindowController.shared.canRedo
        } else {
            undo.action = Selector(("undo:"))
            redo.action = Selector(("redo:"))
        }
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
            let togglePlaylist = viewMenu.addItem(withTitle: L10n.t("menu.player.playlist"), action: #selector(PlayerWindowController.togglePlaylistFromMenu(_:)), keyEquivalent: "")
            togglePlaylist.target = PlayerWindowController.shared
            let toggleTrackEditor = viewMenu.addItem(withTitle: L10n.t("menu.player.trackEditor"), action: #selector(PlayerWindowController.toggleTrackEditorFromMenu(_:)), keyEquivalent: "")
            toggleTrackEditor.target = PlayerWindowController.shared
            let toggleTranscript = viewMenu.addItem(withTitle: L10n.t("menu.player.transcript"), action: #selector(PlayerWindowController.toggleTranscriptFromMenu(_:)), keyEquivalent: "")
            toggleTranscript.target = PlayerWindowController.shared
            viewMenu.addItem(.separator())
            let zoomMenu = NSMenu(title: L10n.t("menu.player.zoom"))
            let zoomItem = NSMenuItem(title: L10n.t("menu.player.zoom"), action: nil, keyEquivalent: "")
            let zoomValues: [(String, Double)] = [
                (L10n.t("player.zoom.fit"), 0), ("50%", 0.5), ("100%", 1),
                ("150%", 1.5), ("200%", 2), ("300%", 3), ("400%", 4)
            ]
            for (title, value) in zoomValues {
                let item = zoomMenu.addItem(withTitle: title, action: #selector(PlayerWindowController.setZoomFromMenu(_:)), keyEquivalent: "")
                item.target = PlayerWindowController.shared
                item.representedObject = NSNumber(value: value)
            }
            zoomItem.submenu = zoomMenu
            viewMenu.addItem(zoomItem)
            viewMenu.addItem(withTitle: L10n.t("menu.player.fullscreen"), action: #selector(PlayerWindowController.toggleFullscreenFromMenu(_:)), keyEquivalent: "f").target = PlayerWindowController.shared
            viewMenuItem.submenu = viewMenu
            mainMenu.addItem(viewMenuItem)

            let playbackItem = NSMenuItem(title: L10n.t("menu.player.playback"), action: nil, keyEquivalent: "")
            let playbackMenu = NSMenu(title: L10n.t("menu.player.playback"))
            let play = playbackMenu.addItem(withTitle: L10n.t("menu.player.playPause"), action: #selector(PlayerWindowController.togglePlaybackFromMenu(_:)), keyEquivalent: " ")
            play.target = PlayerWindowController.shared
            let previous = playbackMenu.addItem(withTitle: L10n.t("player.navigation.previous"), action: #selector(PlayerWindowController.previousFromMenu(_:)), keyEquivalent: "")
            previous.target = PlayerWindowController.shared
            let next = playbackMenu.addItem(withTitle: L10n.t("player.navigation.next"), action: #selector(PlayerWindowController.nextFromMenu(_:)), keyEquivalent: "")
            next.target = PlayerWindowController.shared
            playbackMenu.addItem(.separator())
            let speedItem = NSMenuItem(title: L10n.t("menu.player.speed"), action: nil, keyEquivalent: "")
            let speedMenu = NSMenu(title: L10n.t("menu.player.speed"))
            for rate in [Float(0.5), 0.75, 1, 1.25, 1.5, 2] {
                let item = speedMenu.addItem(withTitle: String(format: "%.2gx", rate), action: #selector(PlayerWindowController.setPlaybackRateFromMenu(_:)), keyEquivalent: "")
                item.target = PlayerWindowController.shared
                item.representedObject = NSNumber(value: rate)
            }
            speedItem.submenu = speedMenu
            playbackMenu.addItem(speedItem)
            let autoplay = playbackMenu.addItem(withTitle: L10n.t("menu.player.autoplay"), action: #selector(PlayerWindowController.toggleAutoplayFromMenu(_:)), keyEquivalent: "")
            autoplay.target = PlayerWindowController.shared
            autoplay.state = PlayerWindowController.shared.isAutoplayNext ? .on : .off
            playbackItem.submenu = playbackMenu
            mainMenu.addItem(playbackItem)

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
#else
        NSApp.windowsMenu = nil
#endif

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

#if SCREENCAP_PRO
    @MainActor @objc private func openPlayerFromMainMenu() {
        Task { @MainActor in
            PlayerWindowController.shared.show()
        }
    }
#endif

    @MainActor @objc private func recoverRecordingsFromMainMenu() {
        if #available(macOS 15.0, *) {
            RecorderRecoveryCoordinator.shared.scanAndPresent()
        }
    }

    @available(macOS 15.0, *)
    private func installRecordingInterruptionObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceNotificationCenter = workspaceCenter
        systemObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    RecorderController.shared.handleScreenConfigurationChange()
                }
            }
        )
        systemObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    RecorderController.shared.handleSystemSleep()
                }
            }
        )
        systemObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    // Sleep normally stops the session before wake. Recheck
                    // the display graph as a defensive fallback for systems
                    // that deliver display changes only after wake.
                    RecorderController.shared.handleScreenConfigurationChange()
                }
            }
        )
        systemObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    RecorderController.shared.handleSessionInterruption()
                }
            }
        )
        systemObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    RecorderController.shared.handleScreenConfigurationChange()
                }
            }
        )
        systemObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didUnmountNotification,
                object: nil,
                queue: .main
            ) { notification in
                let volumeURL = (notification.object as? URL)
                    ?? (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)
                guard let volumeURL else { return }
                Task { @MainActor in
                    RecorderController.shared.handleUnmountedVolume(volumeURL)
                }
            }
        )
    }

    @objc private func openSupport() {
        NSWorkspace.shared.open(AppInfo.supportURL)
    }

    @objc private func showAbout() {
        AboutWindowController.shared.show()
    }
}
