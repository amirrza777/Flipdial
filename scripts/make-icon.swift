// Draws the Flipdial app icon and packs it into an .icns.
//   swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

func render(_ side: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = side / 1024
    let ctx = NSGraphicsContext.current!.cgContext

    // Tile with the standard macOS icon margins.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 1.00, green: 0.66, blue: 0.20, alpha: 1).cgColor,
        NSColor(red: 0.98, green: 0.36, blue: 0.16, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    let c = CGPoint(x: tile.midX, y: tile.midY)
    // Dial ring with eight segments, one highlighted.
    let outer = 300 * s, inner = 190 * s
    for i in 0..<8 {
        let start = CGFloat(i) * .pi / 4 + .pi / 2 - .pi / 8 + 0.06
        let end = start + .pi / 4 - 0.12
        let segment = CGMutablePath()
        segment.addArc(center: c, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        segment.addArc(center: c, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        segment.closeSubpath()
        ctx.addPath(segment)
        ctx.setFillColor(NSColor.white.withAlphaComponent(i == 0 ? 1 : 0.32).cgColor)
        ctx.fillPath()
    }
    // Hub with a flip arrow.
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - 132 * s, y: c.y - 132 * s, width: 264 * s, height: 264 * s))
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 150 * s, weight: .bold)) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor(red: 0.98, green: 0.42, blue: 0.16, alpha: 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: CGRect(x: c.x - symbol.size.width / 2, y: c.y - symbol.size.height / 2,
                               width: symbol.size.width, height: symbol.size.height))
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try render(CGFloat(size * scale)).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
try render(1024).representation(using: .png, properties: [:])!.write(to: out.deletingPathExtension().appendingPathExtension("png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out.path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print("Wrote \(out.path)")
