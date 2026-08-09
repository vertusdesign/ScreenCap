import AppKit
import ScreenCaptureKit

/// A frozen still of one display, plus everything needed to map between the
/// image's pixels and Cocoa's global point coordinates.
struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let screen: NSScreen
    /// `NSScreen.frame` — Cocoa global points.
    let cocoaFrame: CGRect
    let image: CGImage

    /// Pixels per point, i.e. 2 on a Retina display.
    var pixelScale: CGFloat {
        cocoaFrame.width > 0 ? CGFloat(image.width) / cocoaFrame.width : 1
    }

    /// Crops the snapshot to a rect given in Cocoa global points.
    func crop(toGlobalRect rect: CGRect) -> CGImage? {
        let local = CGRect(
            x: rect.minX - cocoaFrame.minX,
            // Flip into the image's top-left origin.
            y: cocoaFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let scale = pixelScale
        let pixels = CGRect(
            x: (local.minX * scale).rounded(),
            y: (local.minY * scale).rounded(),
            width: (local.width * scale).rounded(),
            height: (local.height * scale).rounded()
        )
        let bounded = pixels.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard bounded.width >= 1, bounded.height >= 1 else { return nil }
        return image.cropping(to: bounded)
    }

    /// sRGB color of the pixel under a point given in Cocoa global coordinates.
    func color(atGlobalPoint point: CGPoint) -> NSColor? {
        guard let cropped = crop(toGlobalRect: CGRect(x: point.x, y: point.y, width: 1, height: 1)),
              let data = cropped.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data)
        else { return nil }

        let info = cropped.bitmapInfo
        let alphaFirst = info.contains(.byteOrder32Little)
        // ScreenCaptureKit hands back BGRA on little-endian; normalise both orders.
        let b = CGFloat(pointer[alphaFirst ? 0 : 2]) / 255
        let g = CGFloat(pointer[1]) / 255
        let r = CGFloat(pointer[alphaFirst ? 2 : 0]) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// An on-screen window, for the "capture the window under the cursor" mode.
struct WindowTarget {
    let windowID: CGWindowID
    /// Cocoa global points.
    let frame: CGRect
    let title: String
    let appName: String
}

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noDisplays
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return L10n.t("error.permissionDenied")
        case .noDisplays:
            return L10n.t("error.noDisplays")
        case .captureFailed(let reason):
            return L10n.t("error.captureFailed", reason)
        }
    }
}

enum ScreenCapture {
    // MARK: - Permission

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt. Returns immediately; macOS only shows the
    /// prompt once per app signature, afterwards it silently returns false.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Capture

    static func snapshotAllDisplays() async throws -> [DisplaySnapshot] {
        let content = try await shareableContent()
        guard !content.displays.isEmpty else { throw ScreenCaptureError.noDisplays }

        var snapshots: [DisplaySnapshot] = []
        for display in content.displays {
            guard let screen = screen(for: display.displayID) else { continue }
            let scale = screen.backingScaleFactor

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = Int((screen.frame.width * scale).rounded())
            configuration.height = Int((screen.frame.height * scale).rounded())
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.scalesToFit = false
            configuration.colorSpaceName = CGColorSpace.sRGB

            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                snapshots.append(
                    DisplaySnapshot(
                        displayID: display.displayID,
                        screen: screen,
                        cocoaFrame: screen.frame,
                        image: image
                    )
                )
            } catch {
                throw ScreenCaptureError.captureFailed(error.localizedDescription)
            }
        }

        guard !snapshots.isEmpty else { throw ScreenCaptureError.noDisplays }
        return snapshots
    }

    /// On-screen windows, front-most first, filtered down to things a user would
    /// actually want to capture.
    static func onScreenWindows() async throws -> [WindowTarget] {
        let content = try await shareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return content.windows.compactMap { window -> WindowTarget? in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 40, window.frame.height >= 40,
                  let app = window.owningApplication,
                  app.processID != ownPID
            else { return nil }

            return WindowTarget(
                windowID: window.windowID,
                frame: Geometry.cocoaRect(fromCG: window.frame),
                title: window.title ?? "",
                appName: app.applicationName
            )
        }
    }

    // MARK: - Helpers

    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw hasPermission
                ? ScreenCaptureError.captureFailed(error.localizedDescription)
                : ScreenCaptureError.permissionDenied
        }
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }
}
