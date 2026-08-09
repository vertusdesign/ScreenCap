import UniformTypeIdentifiers

/// The on-disk format a capture is written in. Independent of the clipboard,
/// which always carries both PNG and TIFF for maximum compatibility regardless
/// of this setting.
enum ImageFormat: String, CaseIterable, Codable {
    case png
    case jpeg

    /// A file extension, not a translated word — every language spells it the
    /// same way.
    var title: String { rawValue == "png" ? "PNG" : "JPEG" }

    var fileExtension: String { self == .png ? "png" : "jpg" }

    var contentType: UTType { self == .png ? .png : .jpeg }
}
