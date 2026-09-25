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
func draw(in ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1C1D24).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Tile: deep slate, lighter at the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [color(0x3A3E52).cgColor, color(0x16171E).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A faint glow behind the eye.
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xFF9F0A, 0.20).cgColor, color(0xFF9F0A, 0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 380, options: [])
    ctx.restoreGState()

    // Hairline edge highlight.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(color(0xFFFFFF, 0.10).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // The eye: an almond from two arcs.
    let c = CGPoint(x: 512, y: 560)
    let halfW: CGFloat = 290, halfH: CGFloat = 170
    let eye = CGMutablePath()
    eye.move(to: CGPoint(x: c.x - halfW, y: c.y))
    eye.addQuadCurve(to: CGPoint(x: c.x + halfW, y: c.y), control: CGPoint(x: c.x, y: c.y + halfH * 2))
    eye.addQuadCurve(to: CGPoint(x: c.x - halfW, y: c.y), control: CGPoint(x: c.x, y: c.y - halfH * 2))
    eye.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x000000, 0.35).cgColor)
    ctx.addPath(eye)
    ctx.setFillColor(color(0xF2F2F5).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(eye)
    ctx.clip()
    let white = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF).cgColor, color(0xCFD1DA).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(white, start: CGPoint(x: c.x, y: c.y + halfH), end: CGPoint(x: c.x, y: c.y - halfH), options: [])

    // Iris: AgentHUD's "needs you" orange.
    let irisR: CGFloat = 122
    let iris = CGGradient(colorsSpace: nil, colors: [color(0xFFC04D).cgColor, color(0xFF9F0A).cgColor, color(0xE0620B).cgColor] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.addEllipse(in: CGRect(x: c.x - irisR, y: c.y - irisR, width: irisR * 2, height: irisR * 2))
    ctx.clip()
    ctx.drawRadialGradient(iris, startCenter: CGPoint(x: c.x - 30, y: c.y + 40), startRadius: 0,
                           endCenter: c, endRadius: irisR, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // Iris ring, pupil, catchlight.
    ctx.setStrokeColor(color(0x8A3A05, 0.55).cgColor)
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: CGRect(x: c.x - irisR, y: c.y - irisR, width: irisR * 2, height: irisR * 2))
    let pupilR: CGFloat = 54
    ctx.setFillColor(color(0x14151B).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - pupilR, y: c.y - pupilR, width: pupilR * 2, height: pupilR * 2))
    ctx.setFillColor(color(0xFFFFFF, 0.92).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - 64, y: c.y + 26, width: 40, height: 40))

    // The menu bar's session dots: working, needs you, idle.
    let dots: [(UInt32, CGFloat)] = [(0x30D158, 1), (0xFF9F0A, 1), (0x8E8E93, 1)]
    let r: CGFloat = 30, gap: CGFloat = 38
    let total = CGFloat(dots.count) * r * 2 + CGFloat(dots.count - 1) * gap
    for (i, d) in dots.enumerated() {
        let x = 512 - total / 2 + CGFloat(i) * (r * 2 + gap)
        ctx.setFillColor(color(d.0, d.1).cgColor)
        ctx.fillEllipse(in: CGRect(x: x, y: 235, width: r * 2, height: r * 2))
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
