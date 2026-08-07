import AppKit
import UniformTypeIdentifiers

/// Everything that happens to a finished capture: clipboard, disk, printer.
enum ImageOutput {

    // MARK: - Clipboard

    static func copyToClipboard(_ captured: CapturedImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var items: [NSPasteboardItem] = []
        let item = NSPasteboardItem()
        if let png = pngData(from: captured.cgImage) {
            item.setData(png, forType: .png)
        }
        if let tiff = captured.nsImage.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        items.append(item)
        pasteboard.writeObjects(items.compactMap { $0 as NSPasteboardWriting })
    }

    // MARK: - Saving

    /// Saves using the configured folder and filename template.
    @discardableResult
    static func save(_ captured: CapturedImage, forcePanel: Bool) -> URL? {
        let suggestedName = filename(for: captured)

        if forcePanel || Settings.shared.askWhereToSave {
            return saveWithPanel(captured, suggestedName: suggestedName)
        }

        let directory = Settings.shared.saveDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            presentError(L10n.t("error.createFolder"), error)
            return saveWithPanel(captured, suggestedName: suggestedName)
        }

        let url = uniqueURL(in: directory, name: suggestedName)
        guard write(captured, to: url) else { return nil }
        return url
    }

    private static func saveWithPanel(_ captured: CapturedImage, suggestedName: String) -> URL? {
        // The overlay runs at shielding level; the panel has to be lifted above it.
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName + ".png"
        panel.directoryURL = Settings.shared.saveDirectory
        panel.canCreateDirectories = true
        panel.level = .init(rawValue: Int(CGShieldingWindowLevel()) + 2)

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard write(captured, to: url) else { return nil }
        return url
    }

    @discardableResult
    private static func write(_ captured: CapturedImage, to url: URL) -> Bool {
        guard let data = pngData(from: captured.cgImage) else {
            presentError(L10n.t("error.encodePNG"), nil)
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            presentError(L10n.t("error.saveFile"), error)
            return false
        }
    }

    // MARK: - Printing

    static func print(_ captured: CapturedImage) {
        let image = captured.nsImage
        let imageView = NSImageView(frame: CGRect(origin: .zero, size: captured.pointSize))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true

        let operation = NSPrintOperation(view: imageView, printInfo: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        NSApp.activate(ignoringOtherApps: true)
        operation.run()
    }

    // MARK: - Helpers

    static func pngData(from image: CGImage) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = NSSize(width: image.width, height: image.height)
        return representation.representation(using: .png, properties: [:])
    }

    /// Expands the filename template: `{date}`, `{time}`, `{timestamp}`,
    /// `{width}`, `{height}`.
    static func filename(for captured: CapturedImage) -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH.mm.ss"
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"

        var name = Settings.shared.filenameTemplate
        name = name.replacingOccurrences(of: "{date}", with: dateFormatter.string(from: now))
        name = name.replacingOccurrences(of: "{time}", with: timeFormatter.string(from: now))
        name = name.replacingOccurrences(of: "{timestamp}", with: stampFormatter.string(from: now))
        name = name.replacingOccurrences(of: "{width}", with: "\(captured.cgImage.width)")
        name = name.replacingOccurrences(of: "{height}", with: "\(captured.cgImage.height)")

        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        name = name.components(separatedBy: illegal).joined(separator: "-")
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.t("filename.fallback") : name
    }

    private static func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name).appendingPathExtension("png")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(name) (\(counter))")
                .appendingPathExtension("png")
            counter += 1
        }
        return candidate
    }

    private static func presentError(_ message: String, _ error: Error?) {
        NSLog("ScreenCap: \(message) — \(error?.localizedDescription ?? "")")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error?.localizedDescription ?? ""
        alert.addButton(withTitle: "OK")
        alert.window.level = .init(rawValue: Int(CGShieldingWindowLevel()) + 2)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
