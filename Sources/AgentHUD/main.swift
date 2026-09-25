import AgentHUDCore
import AppKit

MainActor.assumeIsolated {
    // First, before anything reads or creates ~/.agenthud.
    Migration.run()
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        Snapshot.run(dir: CommandLine.arguments[i + 1])
        exit(0)
    }
    // `AgentHUD --history [days]`: index transcripts and print the report, for checking numbers by hand.
    if let i = CommandLine.arguments.firstIndex(of: "--history") {
        let days = i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) ?? 7 : 7
        let index = HistoryIndex()
        let t0 = Date()
        index.refresh()
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: end))!
        let r = index.report(from: start, to: end, idleGap: 5 * 60)
        print("indexed \(index.fileCount) files in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        print("last \(days) days: active \(longDuration(r.active)), tokens \(r.tokens.total) (in \(r.tokens.input), out \(r.tokens.output), cache write \(r.tokens.cacheWrite), cache read \(r.tokens.cacheRead)), \(r.sessions.count) sessions")
        for p in r.projects.prefix(12) {
            print("  \(p.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(longDuration(p.active).padding(toLength: 9, withPad: " ", startingAt: 0)) \(p.sessions) sessions  \(p.tokens.total) tokens")
        }
        for d in r.days { print("  \(d.day.formatted(date: .abbreviated, time: .omitted))  \(longDuration(d.active))") }
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon (LSUIElement in the bundle does the same)
    app.run()
}
