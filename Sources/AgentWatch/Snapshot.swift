import AgentWatchCore
import AppKit
import SwiftUI

/// `AgentWatch --snapshot <dir>`: render the panel from the current event log to PNGs (light + dark),
/// for checking the UI without screen-recording permission.
@MainActor
enum Snapshot {
    static func run(dir: String) {
        let model = AppModel(settings: AppSettings())
        let tailer = EventTailer { events, _ in MainActor.assumeIsolated { model.ingest(events, replay: true) } }
        tailer.start(interval: 3600)
        tailer.stop()
        renderDots(model.menuBarStates, to: "\(dir)/menubar.png")
        renderDots([.needsInput, .needsInput, .running, .running, .stale, .idle, .idle, .unknown, .running, .idle,
                    .idle, .running], to: "\(dir)/menubar-overflow.png")
        for scheme in [ColorScheme.light, .dark] {
            let bg = scheme == .dark ? Color(white: 0.12) : Color(white: 0.93)
            render(ExpandedView(model: model, forSnapshot: true).frame(width: 340, height: 500).padding(12).background(bg)
                .environment(\.colorScheme, scheme), to: "\(dir)/panel-\(scheme).png")
            render(PillView(model: model).padding(12).background(bg).environment(\.colorScheme, scheme),
                   to: "\(dir)/pill-\(scheme).png")
        }
    }

    /// The menu-bar dots for the given states, on a menu-bar-like strip, light and dark.
    static func renderDots(_ states: [SessionState], to path: String) {
        let dots = AppDelegate.dotsImage(states)
        let pad: CGFloat = 10
        let size = NSSize(width: dots.size.width + pad * 2, height: 24 * 2 + 4)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (i, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let y = CGFloat(1 - i) * 28
                (name == .aqua ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: size.width, height: 24).fill()
                dots.draw(in: NSRect(x: pad, y: y + 3, width: dots.size.width, height: dots.size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }

    private static func render(_ view: some View, to path: String) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
