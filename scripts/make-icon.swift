// Draws the app icon from the same mark as the sidebar BrandRow (black rounded square,
// five white bars 5/10/14/8/4 on a 25 pt tile) and writes an .iconset for iconutil.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: 824 pt tile centered on a 1024 canvas, ~185 pt corner radius.
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSColor(red: 0x1A / 255.0, green: 0x1A / 255.0, blue: 0x1A / 255.0, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s).fill()

    // BrandRow: 25 pt tile, bars 2 pt wide with 1.5 pt spacing -> scale 824/25.
    let k = tile.width / 25
    let heights: [CGFloat] = [5, 10, 14, 8, 4]
    let barW = 2 * k, gap = 1.5 * k
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = tile.midX - total / 2
    NSColor(red: 0xFC / 255.0, green: 0xFC / 255.0, blue: 0xFB / 255.0, alpha: 1).setFill()
    for h in heights {
        let r = NSRect(x: x, y: tile.midY - h * k / 2, width: barW, height: h * k)
        NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
