import AppKit

extension NSColor {
    /// Parses `#RRGGBB` / `#RRGGBBAA` (with or without the leading `#`).
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }

        let hasAlpha = text.count == 8
        let r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the color is translucent.
    var hexString: String {
        let color = usingColorSpace(.sRGB) ?? self
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        let a = Int((color.alphaComponent * 255).rounded())
        return a == 255
            ? String(format: "#%02X%02X%02X", r, g, b)
            : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    /// `12, 34, 56` — shown next to the hex readout in the magnifier.
    var rgbString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "%d, %d, %d",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    /// Same as `rgbString`, but each channel is padded to a fixed 3-digit
    /// width. A monospaced label built from `rgbString` still changes width
    /// as the cursor moves — "5, 5, 5" is narrower than "255, 255, 255" — which
    /// in a box sized to fit its own text reads as constant jitter. Used
    /// wherever that stability matters more than the leading spaces looking
    /// slightly odd, like the magnifier's readout box.
    var fixedWidthRgbString: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "%3d, %3d, %3d",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }

    /// Picks black or white for text drawn on top of this color.
    var readableForeground: NSColor {
        let color = usingColorSpace(.sRGB) ?? self
        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return luminance > 0.6 ? .black : .white
    }
}
