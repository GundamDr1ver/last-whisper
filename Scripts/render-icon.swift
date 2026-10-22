import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
for (input, output, size) in [("Assets/AppIcon.svg", "Assets/AppIcon.png", 1024), ("Sources/VoiceInput/Resources/MenuBarIcon.svg", "Assets/MenuBarIcon-preview.png", 200)] {
    guard let image = NSImage(contentsOf: root.appendingPathComponent(input)),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render icon: " + input) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    assert(bitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.01)
    if size == 1024 {
        assert(bitmap.colorAt(x: 512, y: 200)!.redComponent > 0.99)
        assert(bitmap.colorAt(x: 580, y: 512)!.redComponent < 0.01)
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try data.write(to: root.appendingPathComponent(output))
    print("Rendered " + output)
}
