import AppKit

// A code-drawn icon keeps the project self-contained and produces all Retina sizes.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(red: 0.11, green: 0.57, blue: 0.48, alpha: 1),
                   ending: NSColor(red: 0.05, green: 0.28, blue: 0.30, alpha: 1))!.draw(in: background, angle: -55)
        let tiles: [(NSRect, CGFloat)] = [
            (NSRect(x: 207, y: 253, width: 260, height: 510), 0.97),
            (NSRect(x: 499, y: 489, width: 318, height: 274), 0.83),
            (NSRect(x: 499, y: 253, width: 140, height: 204), 0.56),
            (NSRect(x: 671, y: 253, width: 146, height: 204), 0.35)
        ]
        for (rect, opacity) in tiles {
            NSColor.white.withAlphaComponent(opacity).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
