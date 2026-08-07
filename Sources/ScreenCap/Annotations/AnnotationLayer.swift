import AppKit

/// The user's drawing, composited into one transparent raster layer that floats
/// above the screenshot.
///
/// Annotations stay vector data — that is what undo and crisp Retina export need —
/// but they are *rendered* into a bitmap so the eraser can take away part of a
/// stroke instead of the whole thing. Erasing is `destinationOut` on this layer,
/// exactly like rubbing out pixels on a transparent sheet laid over the screen.
final class AnnotationLayer {
    private let pointSize: CGSize
    private let scale: CGFloat
    private let context: CGContext
    private var cachedImage: CGImage?

    init?(pointSize: CGSize, scale: CGFloat) {
        let width = Int((pointSize.width * scale).rounded())
        let height = Int((pointSize.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        self.pointSize = pointSize
        self.scale = scale
        self.context = context
        context.scaleBy(x: scale, y: scale)
    }

    /// Flattened layer, regenerated only when something actually changed.
    var image: CGImage? {
        if cachedImage == nil { cachedImage = context.makeImage() }
        return cachedImage
    }

    /// Repaints the whole layer from the annotation list, in order — so an erase
    /// stroke only affects what was drawn before it, and anything drawn afterwards
    /// stays intact.
    func rebuild(annotations: [Annotation], obfuscation: ObfuscationSource?) {
        context.saveGState()
        context.setBlendMode(.copy)
        context.clear(CGRect(origin: .zero, size: pointSize))
        context.restoreGState()

        withContext {
            for annotation in annotations {
                AnnotationRenderer.draw(annotation, obfuscation: obfuscation)
            }
        }
        cachedImage = nil
    }

    /// Punches an in-progress eraser stroke straight into the layer, so dragging
    /// the eraser does not mean re-rendering every annotation each frame.
    func erase(points: [CGPoint], width: CGFloat) {
        guard !points.isEmpty else { return }
        withContext {
            AnnotationRenderer.erase(points: points, width: width)
        }
        cachedImage = nil
    }

    private func withContext(_ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body()
        NSGraphicsContext.current = previous
    }
}
