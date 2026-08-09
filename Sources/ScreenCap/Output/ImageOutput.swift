import AppKit
import UniformTypeIdentifiers

/// Everything that happens to a finished capture: clipboard, disk, printer.
enum ImageOutput {

    // MARK: - Clipboard

    static func copyToClipboard(_ captured: CapturedImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Always PNG + TIFF regardless of the disk save format: the clipboard
        // is read by arbitrary other apps, and those two are what every image
        // consumer on macOS understands. The chosen save format only affects
        // what lands on disk.
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

    /// Saves using the configured folder, filename template and image format.
    @discardableResult
    static func save(_ captured: CapturedImage, forcePanel: Bool) -> URL? {
        let format = Settings.shared.imageFormat
        let suggestedName = filename(for: captured)

        if forcePanel || Settings.shared.askWhereToSave {
            return saveWithPanel(captured, suggestedName: suggestedName, format: format)
        }

        let directory = Settings.shared.saveDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            presentError(L10n.t("error.createFolder"), error)
            return saveWithPanel(captured, suggestedName: suggestedName, format: format)
        }

        let url = uniqueURL(in: directory, name: suggestedName, extension: format.fileExtension)
        guard write(captured, to: url, format: format) else { return nil }
        return url
    }

    private static func saveWithPanel(
        _ captured: CapturedImage,
        suggestedName: String,
        format: ImageFormat
    ) -> URL? {
        // The overlay runs at shielding level; the panel has to be lifted above it.
        let panel = NSSavePanel()
        var selectedFormat = format
        panel.allowedContentTypes = [selectedFormat.contentType]
        panel.nameFieldStringValue = suggestedName + "." + selectedFormat.fileExtension
        panel.directoryURL = Settings.shared.saveDirectory
        panel.canCreateDirectories = true
        panel.level = .init(rawValue: Int(CGShieldingWindowLevel()) + 2)

        // A format switcher in the panel itself, the way Preview's own save
        // sheet offers one — changing it updates both the allowed type and the
        // suggested extension, without touching the app-wide default.
        let accessory = SaveFormatAccessoryView(initial: selectedFormat) { newFormat in
            selectedFormat = newFormat
            panel.allowedContentTypes = [newFormat.contentType]
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "." + newFormat.fileExtension
        }
        panel.accessoryView = accessory

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard write(captured, to: url, format: selectedFormat) else { return nil }
        return url
    }

    @discardableResult
    private static func write(_ captured: CapturedImage, to url: URL, format: ImageFormat) -> Bool {
        guard let data = encode(captured, as: format) else {
            presentError(L10n.t(format == .png ? "error.encodePNG" : "error.encodeJPEG"), nil)
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

    // MARK: - Encoding

    static func pngData(from image: CGImage) -> Data? {
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = NSSize(width: image.width, height: image.height)
        return representation.representation(using: .png, properties: [:])
    }

    static func encode(_ captured: CapturedImage, as format: ImageFormat) -> Data? {
        switch format {
        case .png:
            return pngData(from: captured.cgImage)
        case .jpeg:
            let representation = NSBitmapImageRep(cgImage: captured.cgImage)
            representation.size = NSSize(width: captured.cgImage.width, height: captured.cgImage.height)
            // JPEG has no alpha channel — a screenshot's own pixels are always
            // opaque, so nothing is lost by dropping it, only the format's own
            // lossy compression at a quality high enough that it is not
            // noticeable for on-screen content.
            return representation.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        }
    }

    // MARK: - Filename

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

    private static func uniqueURL(in directory: URL, name: String, extension fileExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(name) (\(counter))")
                .appendingPathExtension(fileExtension)
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

/// Format chooser shown as the save panel's accessory view, the same way
/// Preview's own save sheet offers one. Changing it updates both the panel's
/// allowed type and the suggested extension.
private final class SaveFormatAccessoryView: NSView {
    private let onChange: (ImageFormat) -> Void
    private var popup: NSPopUpButton?

    init(initial: ImageFormat, onChange: @escaping (ImageFormat) -> Void) {
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 44))

        let label = NSTextField(labelWithString: L10n.t("save.format"))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in ImageFormat.allCases {
            popup.addItem(withTitle: format.title)
        }
        popup.selectItem(at: ImageFormat.allCases.firstIndex(of: initial) ?? 0)
        popup.target = self
        popup.action = #selector(changed(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false
        self.popup = popup

        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(equalToConstant: 90)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func changed(_ sender: NSPopUpButton) {
        onChange(ImageFormat.allCases[sender.indexOfSelectedItem])
    }
}
