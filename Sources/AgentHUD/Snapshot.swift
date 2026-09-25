import AgentHUDCore
import AppKit
import SwiftUI

/// `AgentHUD --snapshot <dir>`: render the panel from the current event log to PNGs (light + dark),
/// for checking the UI without screen-recording permission.
@MainActor
enum Snapshot {
    static func run(dir: String) {
        let model = AppModel(settings: AppSettings())
        let tailer = EventTailer { events, _ in MainActor.assumeIsolated { model.ingest(events, replay: true) } }
        tailer.start(interval: 3600)
        tailer.stop()
        for s in model.rows { model.refreshContext(s) }
        model.history.loadNow()
        // Two just-finished cards: one fresh, one on its way out.
        let idle = model.rows.filter { model.displayState($0) == .idle && $0.lastMessage != nil }
        if idle.count > 1 {
            model.markFinishedForSnapshot(idle[0].id, ago: 12)
            model.markFinishedForSnapshot(idle[1].id, ago: 85)
        }
        for detailed in [false, true] {
            model.settings.homeDetailed = detailed
            render(ExpandedView(model: model, forSnapshot: true).frame(width: 360, height: 640).padding(12)
                .background(Color(white: 0.12)).environment(\.colorScheme, .dark),
                   to: "\(dir)/home-\(detailed ? "detailed" : "simple").png")
        }
        // The eye on, with one session hidden.
        if let s = idle.last {
            model.hide([s])
            model.showingHidden = true
            render(ExpandedView(model: model, forSnapshot: true).frame(width: 340, height: 640).padding(12)
                .background(Color(white: 0.12)).environment(\.colorScheme, .dark), to: "\(dir)/home-option.png")
            model.showingHidden = false
            model.unhide(s)
        }
        model.settings.homeDetailed = false
        for width in [300.0, 262.0] {
            render(ExpandedView(model: model, forSnapshot: true).frame(width: width, height: 760).padding(12)
                .background(Color(white: 0.12)).environment(\.colorScheme, .dark), to: "\(dir)/home-\(Int(width)).png")
        }
        model.settings.homeDetailed = false
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
        // Grouped by project, collapsed and with the first multi-session project open.
        let wasGrouped = model.settings.groupByProject
        model.settings.groupByProject = true
        render(ExpandedView(model: model, forSnapshot: true).frame(width: 360, height: 520).padding(12)
            .background(Color(white: 0.12)).environment(\.colorScheme, .dark), to: "\(dir)/panel-grouped.png")
        if let u = model.units.first(where: \.isProject) {
            model.expandedProjects = [u.id]
            render(ExpandedView(model: model, forSnapshot: true).frame(width: 360, height: 520).padding(12)
                .background(Color(white: 0.12)).environment(\.colorScheme, .dark), to: "\(dir)/panel-grouped-open.png")
            model.expandedProjects = []
        }
        model.settings.groupByProject = wasGrouped

        // The detail view for the busiest session, and Today, both in dark mode.
        if let s = model.rows.max(by: { $0.timeline.count < $1.timeline.count }) {
            model.detailID = s.id
            model.refreshContext(s)
            render(ExpandedView(model: model, forSnapshot: true).frame(width: 360, height: 620).padding(12)
                .background(Color(white: 0.12)).environment(\.colorScheme, .dark), to: "\(dir)/detail-dark.png")
            model.detailID = nil
        }
        // Today's time, and the palette with a query typed.
        model.mode = .today
        render(ExpandedView(model: model, forSnapshot: true).frame(width: 360, height: 560).padding(12)
            .background(Color(white: 0.12)).environment(\.colorScheme, .dark), to: "\(dir)/today-dark.png")
        render(ExpandedView(model: model, forSnapshot: true).frame(width: 360, height: 560).padding(12)
            .background(Color(white: 0.93)).environment(\.colorScheme, .light), to: "\(dir)/today-light.png")
        model.mode = .list
        let q = ProcessInfo.processInfo.environment["AGENTHUD_SNAPSHOT_QUERY"] ?? "load"
        model.searching = true
        model.query = q
        render(ExpandedView(model: model, forSnapshot: true).frame(width: 360, height: 560).padding(12)
            .background(Color(white: 0.12)).environment(\.colorScheme, .dark), to: "\(dir)/palette-dark.png")
        model.searching = false
        model.query = ""

        let savedRange = model.settings.dashboardRange
        defer { model.settings.dashboardRange = savedRange }
        for range in [DashboardRange.today, .week] {
            model.settings.dashboardRange = range.rawValue
            model.history.loadNow()
            model.mode = .dashboard
            render(ExpandedView(model: model, forSnapshot: true).frame(width: 780, height: 900).padding(12)
                .background(Color(white: 0.12)).environment(\.colorScheme, .dark), to: "\(dir)/dashboard-\(range.rawValue).png")
            model.mode = .list
        }
    }

    /// The menu-bar dots for the given states, on a menu-bar-like strip, light and dark.
    static func renderDots(_ states: [SessionState], to path: String) {
        let dots = AppDelegate.dotsImage(states, withEye: true)
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
