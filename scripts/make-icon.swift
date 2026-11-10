// Renders the app icon from the master artwork (docs/assets/logo.svg) into an .iconset directory.
// Usage: swift scripts/make-icon.swift <logo.svg> <output.iconset>
import AppKit

guard CommandLine.arguments.count == 3, let svg = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    print("usage: make-icon.swift <logo.svg> <out.iconset>")
    exit(2)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: dir.appendingPathComponent("icon_\(name).png"))
}
