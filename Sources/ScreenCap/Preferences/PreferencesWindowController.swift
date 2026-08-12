import AppKit
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView()))
        window.title = L10n.t("prefs.title", AppInfo.name)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PreferencesWindow")
        window.setContentSize(Self.preferredContentSize)
        super.init(window: window)

        // SwiftUI caches the strings it rendered, so switching language means a
        // fresh hosting controller rather than a redraw.
        NotificationCenter.default.addObserver(
            forName: .languageChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuild()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func rebuild() {
        window?.title = L10n.t("prefs.title", AppInfo.name)
        window?.contentViewController = NSHostingController(rootView: PreferencesView())
        window?.setContentSize(Self.preferredContentSize)
    }

    private static let preferredContentSize = NSSize(
        width: 500 + 32,
        height: PreferencesView.tabHeight + 32
    )

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.layoutIfNeeded()
        window?.centerOnPointerScreen()
        window?.makeKeyAndOrderFront(nil)
    }
}
