import AppKit
import SwiftUI

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    static let shared = PlayerWindowController()

    private var window: NSWindow?
    private var viewModel: PlayerViewModel?

    func show(url: URL? = nil) {
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
            newWindow.minSize = NSSize(width: 1050, height: 680)
            newWindow.center()
            window = newWindow
        }

        if let url {
            viewModel.select(url: url)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel?.engine.pause()
    }
}
