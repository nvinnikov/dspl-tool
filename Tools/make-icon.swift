// Генератор AppIcon.icns: рисуем символ монитора на скруглённом квадрате.
// Отдельного дизайна у приложения нет, а системная «пустая» иконка выглядит
// как сломанное приложение. Запуск: swift Tools/make-icon.swift <выходной .icns>

import AppKit

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.icns"

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Поле вокруг рисунка — как у системных иконок, иначе в доке выглядит крупнее соседей.
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect,
                                xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.33, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1),
    ])!
    gradient.draw(in: squircle, angle: -90)

    // paletteColors красит сам символ; ручная заливка поверх залила бы и его нутро.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .light)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let glyph = NSRect(
            x: (size - symbol.size.width) / 2,
            y: (size - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height
        )
        symbol.draw(in: glyph, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("DsplBar.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Имена файлов задаёт iconutil, отступать от них нельзя.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try writePNG(drawIcon(size: CGFloat(pixels)), pixels: pixels,
                     to: iconset.appendingPathComponent(name))
    }
}

let output = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil упал\n".data(using: .utf8)!)
    exit(1)
}
print("собрано: \(output.path)")
