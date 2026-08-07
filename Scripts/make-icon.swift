#!/usr/bin/env swift
// Renders the app icon set. Run via `make icon`; the output is committed so a
// normal build needs no image tooling.
import AppKit

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: "AppIcon.iconset", isDirectory: true)

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let unit = size / 1024

        // Rounded-square plate with a top-lit gradient.
        let plate = NSBezierPath(
            roundedRect: rect.insetBy(dx: 84 * unit, dy: 84 * unit),
            xRadius: 200 * unit,
            yRadius: 200 * unit
        )
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.36, green: 0.45, blue: 0.98, alpha: 1),
            NSColor(srgbRed: 0.17, green: 0.20, blue: 0.55, alpha: 1)
        ])
        gradient?.draw(in: plate, angle: -90)

        NSColor.white.withAlphaComponent(0.22).setStroke()
        plate.lineWidth = 6 * unit
        plate.stroke()

        // Capture frame: four corner brackets.
        let frame = rect.insetBy(dx: 250 * unit, dy: 250 * unit)
        let arm = 120 * unit
        let bracket = NSBezierPath()
        bracket.lineWidth = 44 * unit
        bracket.lineCapStyle = .round
        bracket.lineJoinStyle = .round

        // Top-left
        bracket.move(to: CGPoint(x: frame.minX, y: frame.maxY - arm))
        bracket.line(to: CGPoint(x: frame.minX, y: frame.maxY))
        bracket.line(to: CGPoint(x: frame.minX + arm, y: frame.maxY))
        // Top-right
        bracket.move(to: CGPoint(x: frame.maxX - arm, y: frame.maxY))
        bracket.line(to: CGPoint(x: frame.maxX, y: frame.maxY))
        bracket.line(to: CGPoint(x: frame.maxX, y: frame.maxY - arm))
        // Bottom-right
        bracket.move(to: CGPoint(x: frame.maxX, y: frame.minY + arm))
        bracket.line(to: CGPoint(x: frame.maxX, y: frame.minY))
        bracket.line(to: CGPoint(x: frame.maxX - arm, y: frame.minY))
        // Bottom-left
        bracket.move(to: CGPoint(x: frame.minX + arm, y: frame.minY))
        bracket.line(to: CGPoint(x: frame.minX, y: frame.minY))
        bracket.line(to: CGPoint(x: frame.minX, y: frame.minY + arm))

        NSColor.white.setStroke()
        bracket.stroke()

        // Lightning bolt in the middle.
        let bolt = NSBezierPath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let boltPoints: [CGPoint] = [
            CGPoint(x: 30, y: 150), CGPoint(x: -70, y: 10),
            CGPoint(x: -6, y: 10), CGPoint(x: -30, y: -150),
            CGPoint(x: 70, y: -6), CGPoint(x: 6, y: -6)
        ]
        bolt.move(to: CGPoint(
            x: center.x + boltPoints[0].x * unit,
            y: center.y + boltPoints[0].y * unit
        ))
        for point in boltPoints.dropFirst() {
            bolt.line(to: CGPoint(x: center.x + point.x * unit, y: center.y + point.y * unit))
        }
        bolt.close()
        NSColor(srgbRed: 1.0, green: 0.83, blue: 0.25, alpha: 1).setFill()
        bolt.fill()

        return true
    }
    return image
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let image = drawIcon(size: CGFloat(variant.pixels))
    guard let tiff = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiff),
          let png = representation.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("не удалось отрисовать \(variant.name)\n".utf8))
        exit(1)
    }
    let url = outputDirectory.appendingPathComponent("\(variant.name).png")
    try png.write(to: url)
}

print("iconset готов: \(outputDirectory.path)")
