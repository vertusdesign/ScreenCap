import AppKit
import CoreImage

/// Supplies pixelated / blurred versions of the frozen screenshot so that
/// "redact this" annotations can be drawn by clipping and blitting.
///
/// The whole display is processed once per (style, intensity) pair and cached, so
/// dragging a redaction across the screen costs one clipped draw per frame rather
/// than a filter pass.
final class ObfuscationSource {
    /// Screenshot of the full display, in pixels.
    private let source: CGImage
    /// The display's size in Cocoa points; the rect the source image maps onto.
    private let pointSize: CGSize
    private let pixelScale: CGFloat

    private struct CacheKey: Hashable {
        let style: ObfuscationStyle
        /// Quantised so a slider drag reuses cached passes instead of thrashing.
        let intensityStep: Int
    }

    private var cache: [CacheKey: CGImage] = [:]
    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(source: CGImage, pointSize: CGSize, pixelScale: CGFloat) {
        self.source = source
        self.pointSize = pointSize
        self.pixelScale = max(pixelScale, 1)
    }

    /// Draws redacted screenshot content inside `clip`, which is in the same point
    /// space as the annotations.
    func draw(clip: NSBezierPath, style: ObfuscationStyle, intensity: CGFloat) {
        guard let processed = image(for: style, intensity: intensity),
              let context = NSGraphicsContext.current
        else { return }

        context.saveGraphicsState()
        clip.addClip()
        context.cgContext.interpolationQuality = .none
        context.cgContext.draw(processed, in: CGRect(origin: .zero, size: pointSize))
        context.restoreGraphicsState()
    }

    private func image(for style: ObfuscationStyle, intensity: CGFloat) -> CGImage? {
        let clamped = min(max(intensity, ObfuscationSettings.intensityRange.lowerBound),
                          ObfuscationSettings.intensityRange.upperBound)
        let key = CacheKey(style: style, intensityStep: Int(clamped.rounded()))
        if let cached = cache[key] { return cached }

        let input = CIImage(cgImage: source)
        let extent = input.extent
        let amount = CGFloat(key.intensityStep) * pixelScale
        var output: CIImage?

        switch style {
        case .pixelate:
            let filter = CIFilter(name: "CIPixellate")
            filter?.setValue(input, forKey: kCIInputImageKey)
            filter?.setValue(amount, forKey: kCIInputScaleKey)
            filter?.setValue(CIVector(x: extent.minX, y: extent.minY), forKey: kCIInputCenterKey)
            output = filter?.outputImage

        case .blur:
            // Clamp first, otherwise the Gaussian bleeds transparency in from
            // outside the image and the border of the redaction goes see-through.
            let clampedImage = input.clampedToExtent()
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(clampedImage, forKey: kCIInputImageKey)
            filter?.setValue(amount, forKey: kCIInputRadiusKey)
            output = filter?.outputImage
        }

        guard let output, let rendered = ciContext.createCGImage(output, from: extent) else { return nil }
        cache[key] = rendered
        return rendered
    }
}
