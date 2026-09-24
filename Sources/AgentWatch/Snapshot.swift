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
        for scheme in [ColorScheme.light, .dark] {
            let bg = scheme == .dark ? Color(white: 0.12) : Color(white: 0.93)
            render(ExpandedView(model: model, forSnapshot: true).frame(width: 340, height: 500).padding(12).background(bg)
                .environment(\.colorScheme, scheme), to: "\(dir)/panel-\(scheme).png")
            render(PillView(model: model).padding(12).background(bg).environment(\.colorScheme, scheme),
                   to: "\(dir)/pill-\(scheme).png")
        }
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
