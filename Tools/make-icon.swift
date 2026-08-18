// Нарезает Resources/AppIcon.png в Resources/AppIcon.icns.
//
// Не sips: он при уменьшении подмешивает белый фон вместо прозрачности, и по
// краю скруглённого квадрата появляется светлая кайма.
//
// Запуск: swift Tools/make-icon.swift [исходник.png] [результат.icns]

import AppKit

let arguments = CommandLine.arguments
let sourcePath = arguments.count > 1 ? arguments[1] : "Resources/AppIcon.png"
let outputPath = arguments.count > 2 ? arguments[2] : "Resources/AppIcon.icns"

guard let source = NSImage(contentsOfFile: sourcePath) else {
    FileHandle.standardError.write("не читается: \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

func resized(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    // Холст не заливаем ничем: прозрачность исходника должна дойти до файла.
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

// Имена файлов задаёт iconutil, отступать от них нельзя.
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (pixels, name) in sizes {
    try resized(pixels).write(to: iconset.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(1) }
print("собрано: \(outputPath)")
