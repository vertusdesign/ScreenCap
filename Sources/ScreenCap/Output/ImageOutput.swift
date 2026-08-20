import AppKit
import UniformTypeIdentifiers

/// Everything that happens to a finished capture: clipboard, disk, printer.
enum ImageOutput {
    enum PlayerFrameSaveError: Error {
        case encodingFailed
    }

    // MARK: - Clipboard

    @MainActor
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

    /// Copies a player frame in the formats expected by native macOS image
    /// consumers. When `fileURL` is supplied, the same pasteboard item also
    /// advertises the PNG as a file. Apps such as Figma then use the file's
    /// basename for the imported layer instead of a generic "Image" name.
    @MainActor
    @discardableResult
    static func copyPlayerFrameToClipboard(_ image: CGImage, fileURL: URL? = nil) -> Bool {
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = NSSize(width: image.width, height: image.height)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else {
            return false
        }
        if let tiff = representation.tiffRepresentation {
            _ = pasteboard.setData(tiff, forType: .tiff)
        }
        if let fileURL {
            // `public.file-url` is what Finder places on the pasteboard when a
            // file is copied. Keep it on the same item as the image data so
            // bitmap-only consumers continue to work without special cases.
            _ = pasteboard.setString(fileURL.absoluteString, forType: .fileURL)
        }

        return true
    }

    /// Persists a player frame next to its source video. The folder is named
    /// after the video (without its extension), and the file name is stable,
    /// space-free and based on the frame timestamp. Existing files are never
    /// overwritten; a numeric suffix is used only for a same-millisecond copy.
    static func savePlayerFrame(
        _ image: CGImage,
        sourceURL: URL,
        seconds: Double
    ) throws -> URL {
        guard let data = pngData(from: image) else {
            throw PlayerFrameSaveError.encodingFailed
        }

        let sourceBaseName = sourceURL.deletingPathExtension().lastPathComponent
        let folderName = spaceFreeFilenameComponent(sourceBaseName.isEmpty ? "ScreenCap" : sourceBaseName)
        let folder = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let fileStem = spaceFreeFilenameComponent(sourceBaseName.isEmpty ? "ScreenCap" : sourceBaseName)
        let timestamp = playerFrameTimestamp(seconds)
        let requestedName = "\(fileStem)-\(timestamp)"
        let url = uniquePlayerFrameURL(in: folder, name: requestedName)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Saving

    /// Saves using the configured folder, filename template and image format.
    /// A caller may provide a preferred directory/name for document editing;
    /// ordinary screenshot saves continue to use the user preferences.
    @discardableResult
    @MainActor
    static func save(
        _ captured: CapturedImage,
        forcePanel: Bool,
        preferredDirectory: URL? = nil,
        suggestedName: String? = nil
    ) -> URL? {
        let format = Settings.shared.imageFormat
        let suggestedName = suggestedName ?? filename(for: captured)
        let directory = preferredDirectory ?? Settings.shared.saveDirectory

        if forcePanel || Settings.shared.askWhereToSave {
            return saveWithPanel(
                captured,
                suggestedName: suggestedName,
                format: format,
                directory: directory
            )
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            if preferredDirectory == nil {
                presentError(L10n.t("error.createFolder"), error)
            }
            return saveWithPanel(
                captured,
                suggestedName: suggestedName,
                format: format,
                directory: directory
            )
        }

        let url = uniqueURL(in: directory, name: suggestedName, extension: format.fileExtension)
        guard write(captured, to: url, format: format, showError: preferredDirectory == nil) else {
            // Finder may open a file from a location that is readable but not
            // writable. Keep the user's work recoverable by falling back to a
            // normal save panel instead of ending the save attempt silently.
            if preferredDirectory != nil {
                return saveWithPanel(
                    captured,
                    suggestedName: suggestedName,
                    format: format,
                    directory: directory
                )
            }
            return nil
        }
        return url
    }

    @MainActor
    private static func saveWithPanel(
        _ captured: CapturedImage,
        suggestedName: String,
        format: ImageFormat,
        directory: URL
    ) -> URL? {
        // The overlay runs at shielding level; the panel has to be lifted above it.
        let panel = NSSavePanel()
        var selectedFormat = format
        panel.allowedContentTypes = [selectedFormat.contentType]
        panel.nameFieldStringValue = suggestedName + "." + selectedFormat.fileExtension
        panel.directoryURL = directory
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
    @MainActor
    private static func write(
        _ captured: CapturedImage,
        to url: URL,
        format: ImageFormat,
        showError: Bool = true
    ) -> Bool {
        guard let data = encode(captured, as: format) else {
            if showError {
                presentError(L10n.t(format == .png ? "error.encodePNG" : "error.encodeJPEG"), nil)
            }
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            if showError {
                presentError(L10n.t("error.saveFile"), error)
            }
            return false
        }
    }

    // MARK: - Printing

    @MainActor
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

    private static func spaceFreeFilenameComponent(_ value: String) -> String {
        var result = value.replacingOccurrences(
            of: "\\s+",
            with: "-",
            options: .regularExpression
        )
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        result = result.components(separatedBy: illegal).joined(separator: "-")
        result = result.replacingOccurrences(of: ".", with: "_")
        result = result.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return result.isEmpty ? "ScreenCap" : result
    }

    private static func playerFrameTimestamp(_ seconds: Double) -> String {
        let safeSeconds = seconds.isFinite ? max(seconds, 0) : 0
        let totalMilliseconds = max(Int((safeSeconds * 1_000).rounded()), 0)
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let seconds = (totalMilliseconds / 1_000) % 60
        let milliseconds = totalMilliseconds % 1_000
        return String(format: "%02d-%02d-%02d-%03d", hours, minutes, seconds, milliseconds)
    }

    private static func uniquePlayerFrameURL(in directory: URL, name: String) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(name).appendingPathExtension("png")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(name)-\(counter)")
                .appendingPathExtension("png")
            counter += 1
        }
        return candidate
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

    /// Suggested name for an edited Finder image. The source extension is not
    /// reused because the configured output format controls the actual export.
    static func openedImageFilename(for sourceURL: URL) -> String {
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let sanitized = base
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>") )
            .joined(separator: "-")
            .replacingOccurrences(of: ".", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (sanitized.isEmpty ? L10n.t("filename.fallback") : sanitized) + "_ScreenCap"
    }

    /// Expands the filename template: `{date}`, `{time}`, `{timestamp}`,
    /// `{width}`, `{height}`.
    static func filename(for captured: CapturedImage) -> String {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"
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
        name = name.replacingOccurrences(of: ".", with: "_")
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

    @MainActor
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
@MainActor
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
