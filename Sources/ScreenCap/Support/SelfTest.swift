import AppKit

/// Headless smoke test: `ScreenCap --selftest [output-directory]`.
///
/// Exercises the annotation renderer and the export path against a synthetic
/// screenshot, then reports whether real screen capture is available. Useful in
/// CI, where there is no display permission and no one to click a button.
enum SelfTest {

    static func run(outputDirectory: URL) -> Int32 {
        var failures: [String] = []

        print("ScreenCap self-test")
        print("- каталог вывода: \(outputDirectory.path)")

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("  ✗ не удалось создать каталог: \(error.localizedDescription)")
            return 1
        }

        // 1. Renderer over a synthetic base image.
        let pointSize = CGSize(width: 600, height: 400)
        let scale: CGFloat = 2
        guard let base = syntheticScreenshot(pointSize: pointSize, scale: scale) else {
            print("  ✗ не удалось создать тестовое изображение")
            return 1
        }

        let obfuscation = ObfuscationSource(source: base, pointSize: pointSize, pixelScale: scale)
        func makeStyle(color: NSColor, filled: Bool, shape: ObfuscationShape = .rectangle) -> ToolStyle {
            ToolStyle(
                color: color,
                lineWidth: 4,
                filled: filled,
                fontSize: 28,
                textBackdrop: .shadow,
                backdropColor: .black,
                obfuscation: ObfuscationSettings(
                    style: .pixelate, shape: shape, brushSize: 40, intensity: 11
                ),
                eraserRadius: 24
            )
        }
        let style = makeStyle(color: .systemRed, filled: false)
        let filled = makeStyle(color: NSColor(srgbRed: 0.2, green: 0.6, blue: 1, alpha: 0.85), filled: true)
        var blurStyle = style
        blurStyle.obfuscation.style = .blur

        let annotations: [Annotation] = [
            Annotation(shape: .rectangle(CGRect(x: 40, y: 260, width: 140, height: 90)), style: style),
            Annotation(shape: .ellipse(CGRect(x: 200, y: 260, width: 140, height: 90)), style: filled),
            Annotation(shape: .arrow(from: CGPoint(x: 360, y: 270), to: CGPoint(x: 520, y: 350)), style: style),
            Annotation(shape: .line(from: CGPoint(x: 40, y: 230), to: CGPoint(x: 560, y: 230)), style: style),
            Annotation(
                shape: .pen(points: (0...40).map { CGPoint(x: 40 + Double($0) * 8, y: 170 + sin(Double($0) / 3) * 24) }),
                style: style
            ),
            Annotation(
                shape: .marker(points: (0...20).map { CGPoint(x: 60 + Double($0) * 20, y: 120) }),
                style: makeStyle(color: .systemYellow, filled: false)
            ),
            Annotation(shape: .obfuscateRect(CGRect(x: 40, y: 40, width: 130, height: 60)), style: style),
            Annotation(shape: .obfuscateEllipse(CGRect(x: 190, y: 40, width: 130, height: 60)), style: blurStyle),
            Annotation(
                shape: .obfuscateBrush(points: (0...12).map { CGPoint(x: 340 + Double($0) * 8, y: 70) }),
                style: blurStyle
            ),
            Annotation(shape: .counter(center: CGPoint(x: 470, y: 70), number: 1), style: style),
            Annotation(shape: .counter(center: CGPoint(x: 530, y: 70), number: 2), style: filled),
            Annotation(shape: .text(origin: CGPoint(x: 40, y: 390), string: "Проверка текста"), style: style)
        ]

        guard let rendered = render(
            base: base,
            pointSize: pointSize,
            scale: scale,
            annotations: annotations,
            obfuscation: obfuscation
        ) else {
            failures.append("рендеринг аннотаций")
            print("  ✗ рендеринг аннотаций")
            return finish(failures)
        }
        print("  ✓ рендеринг аннотаций (\(rendered.cgImage.width)×\(rendered.cgImage.height) px)")

        // 2. PNG encoding and disk write.
        let url = outputDirectory.appendingPathComponent("selftest-annotations.png")
        if let data = ImageOutput.pngData(from: rendered.cgImage) {
            do {
                try data.write(to: url, options: .atomic)
                print("  ✓ PNG записан: \(url.lastPathComponent) (\(data.count / 1024) КБ)")
            } catch {
                failures.append("запись PNG: \(error.localizedDescription)")
                print("  ✗ запись PNG: \(error.localizedDescription)")
            }
        } else {
            failures.append("кодирование PNG")
            print("  ✗ кодирование PNG")
        }

        // 3. Filename template expansion.
        let name = ImageOutput.filename(for: rendered)
        if name.isEmpty || name.contains("{") {
            failures.append("шаблон имени файла: \(name)")
            print("  ✗ шаблон имени файла: \(name)")
        } else {
            print("  ✓ шаблон имени файла: \(name)")
        }

        // 4. Geometry round-trip.
        let cocoa = CGRect(x: 10, y: 20, width: 100, height: 50)
        let roundTripped = Geometry.cocoaRect(fromCG: Geometry.cgRect(fromCocoa: cocoa))
        if abs(roundTripped.minY - cocoa.minY) > 0.001 {
            failures.append("конвертация координат CG↔Cocoa")
            print("  ✗ конвертация координат CG↔Cocoa")
        } else {
            print("  ✓ конвертация координат CG↔Cocoa")
        }

        // 5. Hotkey encoding round-trip.
        let hotkey = Hotkey(keyCode: 120, modifierFlags: [.command, .shift])
        if let data = try? JSONEncoder().encode(hotkey),
           let decoded = try? JSONDecoder().decode(Hotkey.self, from: data),
           decoded == hotkey, hotkey.isValid {
            print("  ✓ горячая клавиша \(hotkey.displayString) сериализуется")
        } else {
            failures.append("сериализация горячей клавиши")
            print("  ✗ сериализация горячей клавиши")
        }

        // 6. Real capture, if the system allows it.
        if ScreenCapture.hasPermission {
            let semaphore = DispatchSemaphore(value: 0)
            var captureError: Error?
            var captured: [DisplaySnapshot] = []
            Task {
                do { captured = try await ScreenCapture.snapshotAllDisplays() } catch { captureError = error }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 15) == .timedOut {
                failures.append("захват экрана: таймаут")
                print("  ✗ захват экрана: таймаут")
            } else if let captureError {
                failures.append("захват экрана: \(captureError.localizedDescription)")
                print("  ✗ захват экрана: \(captureError.localizedDescription)")
            } else {
                for snapshot in captured {
                    print("  ✓ дисплей \(snapshot.displayID): \(snapshot.image.width)×\(snapshot.image.height) px, масштаб \(snapshot.pixelScale)")
                }
                if let first = captured.first {
                    let probe = CGPoint(x: first.cocoaFrame.midX, y: first.cocoaFrame.midY)
                    if let color = first.color(atGlobalPoint: probe) {
                        print("  ✓ цвет пикселя в центре: \(color.hexString)")
                    } else {
                        failures.append("чтение цвета пикселя")
                        print("  ✗ чтение цвета пикселя")
                    }
                    if let crop = first.crop(toGlobalRect: CGRect(
                        x: first.cocoaFrame.minX + 100,
                        y: first.cocoaFrame.minY + 100,
                        width: 200, height: 120
                    )) {
                        print("  ✓ обрезка области: \(crop.width)×\(crop.height) px")
                    } else {
                        failures.append("обрезка области")
                        print("  ✗ обрезка области")
                    }
                }
            }
        } else {
            print("  ⚠︎ нет разрешения на запись экрана — реальный захват пропущен")
        }

        return finish(failures)
    }

    private static func finish(_ failures: [String]) -> Int32 {
        if failures.isEmpty {
            print("Все проверки пройдены.")
            return 0
        }
        print("Провалено: \(failures.count) — \(failures.joined(separator: "; "))")
        return 1
    }

    // MARK: - Helpers

    private static func syntheticScreenshot(pointSize: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        // Colourful checkerboard so blur and pixelate have something to chew on.
        let tile: CGFloat = 25
        var row = 0
        var y: CGFloat = 0
        while y < pointSize.height {
            var column = 0
            var x: CGFloat = 0
            while x < pointSize.width {
                let hue = CGFloat((row * 7 + column * 3) % 36) / 36
                NSColor(hue: hue, saturation: 0.55, brightness: (row + column) % 2 == 0 ? 0.95 : 0.6, alpha: 1).setFill()
                CGRect(x: x, y: y, width: tile, height: tile).fill()
                x += tile
                column += 1
            }
            y += tile
            row += 1
        }

        NSGraphicsContext.current = previous
        return context.makeImage()
    }

    private static func render(
        base: CGImage,
        pointSize: CGSize,
        scale: CGFloat,
        annotations: [Annotation],
        obfuscation: ObfuscationSource
    ) -> CapturedImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(pointSize.width * scale),
            height: Int(pointSize.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.draw(base, in: CGRect(origin: .zero, size: pointSize))
        AnnotationRenderer.draw(
            annotations,
            obfuscation: obfuscation,
            clipTo: CGRect(origin: .zero, size: pointSize)
        )
        NSGraphicsContext.current = previous

        guard let image = context.makeImage() else { return nil }
        return CapturedImage(cgImage: image, pointSize: pointSize)
    }
}
