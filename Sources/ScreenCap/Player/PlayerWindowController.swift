import AppKit
import SwiftUI

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()

    private var window: NSWindow?
    private var viewModel: PlayerViewModel?

    var isVisible: Bool { window?.isVisible == true }

    func show(url: URL? = nil) {
        (NSApp.delegate as? AppDelegate)?.setPlayerWindowVisible(true)
        if viewModel == nil {
            viewModel = PlayerViewModel()
        }
        guard let viewModel else { return }

        if window == nil {
            let hosting = NSHostingController(rootView: PlayerView(viewModel: viewModel))
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = L10n.t("player.window.title")
            newWindow.contentViewController = hosting
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.isRestorable = false
            newWindow.tabbingMode = .disallowed
            newWindow.collectionBehavior = [.managed, .fullScreenPrimary]
            // Keep enough room for the title bar while allowing a compact
            // player window. The SwiftUI content uses a slightly smaller
            // minimum so AppKit's title bar never clips its top or bottom rows.
            newWindow.minSize = NSSize(width: 1050, height: 360)
            newWindow.center()
            window = newWindow
        }

        if let url {
            viewModel.select(url: url)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func closeFromMenu(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc func openVideoFromMenu(_ sender: Any?) {
        show()
        guard let viewModel else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.t("menu.openVideo")
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.compactMap { viewModel.library.addVideo(url: $0) }
            .last
            .map { viewModel.select(url: $0.url) }
    }

    @objc func openFolderFromMenu(_ sender: Any?) {
        show()
        guard let viewModel else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.t("menu.openFolder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = viewModel.library.addFolder(url: url)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel?.engine.pause()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible != true else { return }
            (NSApp.delegate as? AppDelegate)?.setPlayerWindowVisible(false)
        }
    }
}
