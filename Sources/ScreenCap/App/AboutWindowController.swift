import AppKit
import SwiftUI

final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
        window.title = L10n.t("menu.about", AppInfo.name)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AboutWindow")
        super.init(window: window)

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
        window?.title = L10n.t("menu.about", AppInfo.name)
        window?.contentViewController = NSHostingController(rootView: AboutView())
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.layoutIfNeeded()
        window?.centerOnPointerScreen()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .padding(.bottom, 14)
            }

            Text(AppInfo.name)
                .font(.system(size: 26, weight: .bold))

            Text(AppInfo.versionLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(L10n.t("about.tagline"))
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            if AppInfo.isPrerelease {
                Text(L10n.t("about.alpha"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }

            Divider()
                .padding(.vertical, 16)

            // Four links, generously padded: at 24 languages the widest
            // translations otherwise run flush into the window edges.
            HStack(spacing: 20) {
                Link(L10n.t("about.link.source"), destination: AppInfo.repositoryURL)
                Link(L10n.t("about.link.releases"), destination: AppInfo.releasesURL)
                Link(L10n.t("about.link.privacy"), destination: AppInfo.privacyURL)
                Link(L10n.t("about.link.license"), destination: AppInfo.licenseURL)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .fixedSize(horizontal: false, vertical: true)

            Text(L10n.t("about.copyright"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 22)
        .frame(width: 460)
    }
}
