// Renders the AustialCast app icon (a TV with cast waves) into an .iconset directory.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit
import CoreGraphics

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded square background with a diagonal gradient.
    let inset = s * 0.06
    let bg = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: bg, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [CGColor(red: 0.42, green: 0.55, blue: 1.0, alpha: 1), CGColor(red: 0.10, green: 0.14, blue: 0.30, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.restoreGState()

    // TV body.
    let tv = CGRect(x: s * 0.2, y: s * 0.3, width: s * 0.6, height: s * 0.4)
    ctx.setFillColor(CGColor(red: 0.04, green: 0.06, blue: 0.12, alpha: 0.9))
    ctx.addPath(CGPath(roundedRect: tv, cornerWidth: s * 0.04, cornerHeight: s * 0.04, transform: nil)); ctx.fillPath()
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
    ctx.fill(CGRect(x: s * 0.38, y: s * 0.22, width: s * 0.24, height: s * 0.025))

    // Cast waves in the bottom-left of the screen.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(s * 0.03)
    ctx.setLineCap(.round)
    let origin = CGPoint(x: tv.minX + s * 0.07, y: tv.minY + s * 0.07)
    for r in [0.07, 0.13, 0.19] as [CGFloat] {
        ctx.addArc(center: origin, radius: s * r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        ctx.strokePath()
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: origin.x - s * 0.015, y: origin.y - s * 0.015, width: s * 0.03, height: s * 0.03))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else { print("usage: make-icon.swift <out.iconset>"); exit(2) }
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(size: px).write(to: dir.appendingPathComponent("icon_\(name).png"))
}
