// Renders the app icon: `swift scripts/make-icon.swift <out.iconset>`, then `iconutil -c icns`.
// Drawn in code so it can be tweaked and regenerated; `make icon` does both steps.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws on a 1024-point canvas; the macOS icon grid puts the rounded square at 100…924.
/// Three session rows, like the panel: a status dot and a title bar on a card, working / needs you / idle.
func draw(in ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1E1F23).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Tile: charcoal, a little lighter at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [color(0x34363C).cgColor, color(0x1A1B1F).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Hairline edge highlight.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.12).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // Three rows, top to bottom: working (green), needs you (orange), idle (gray).
    let rows: [(dot: UInt32, glow: CGFloat)] = [(0x30D158, 0.55), (0xFF9F0A, 0.6), (0x8E8E93, 0)]
    let cardW: CGFloat = 604, cardH: CGFloat = 150, gap: CGFloat = 46
    let x0 = 512 - cardW / 2
    let top: CGFloat = 512 + (cardH * 3 + gap * 2) / 2
    for (i, row) in rows.enumerated() {
        let y = top - CGFloat(i + 1) * cardH - CGFloat(i) * gap
        let card = CGRect(x: x0, y: y, width: cardW, height: cardH)
        let cardPath = CGPath(roundedRect: card, cornerWidth: 40, cornerHeight: 40, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.45).cgColor)
        ctx.addPath(cardPath)
        ctx.setFillColor(color(0x2B2D32).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        let face = CGGradient(colorsSpace: nil, colors: [color(0x3A3C42).cgColor, color(0x2A2C31).cgColor] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(face, start: CGPoint(x: 512, y: card.maxY), end: CGPoint(x: 512, y: card.minY), options: [])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: card.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 39, cornerHeight: 39, transform: nil))
        ctx.setStrokeColor(color(0xFFFFFF, 0.10).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()

        // Status dot, with a soft glow for the lit ones.
        let r: CGFloat = 34
        let c = CGPoint(x: card.minX + 86, y: card.midY)
        if row.glow > 0 {
            let glow = CGGradient(colorsSpace: nil, colors: [color(row.dot, row.glow).cgColor, color(row.dot, 0).cgColor] as CFArray,
                                  locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: c, startRadius: r * 0.6, endCenter: c, endRadius: r * 2.1, options: [])
        }
        ctx.setFillColor(color(row.dot).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.setFillColor(color(0xFFFFFF, 0.28).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y + r * 0.1, width: r * 0.7, height: r * 0.55))

        // Title bar.
        let bar = CGRect(x: card.minX + 162, y: card.midY - 17, width: cardW - 162 - 64, height: 34)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 17, cornerHeight: 17, transform: nil))
        ctx.setFillColor(color(0x8A8C94, 0.85).cgColor)
        ctx.fillPath()
    }
}

for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = size * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let ctx = g.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(in: ctx)
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
print("wrote \(out)")
