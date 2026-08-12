import CoreImage
import ImageIO

enum ImageFileLoader {
    enum LoadError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            L10n.t("error.openImage")
        }
    }

    /// Loads a Finder-selected image and normalizes its EXIF orientation while
    /// keeping the original pixel dimensions for a lossless annotation export.
    static func loadCGImage(from url: URL) throws -> CGImage {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else {
            throw LoadError.unreadable
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = properties?[kCGImagePropertyOrientation] as? NSNumber
        let orientation = rawOrientation.flatMap {
            CGImagePropertyOrientation(rawValue: $0.uint32Value)
        } ?? .up
        guard orientation != .up else { return image }

        let oriented = CIImage(cgImage: image).oriented(orientation)
        guard let normalized = CIContext().createCGImage(oriented, from: oriented.extent) else {
            throw LoadError.unreadable
        }
        return normalized
    }
}
