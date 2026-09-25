import AgentHUDCore
import AppKit

MainActor.assumeIsolated {
    // First, before anything reads or creates ~/.agenthud.
    Migration.run()
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        Snapshot.run(dir: CommandLine.arguments[i + 1])
        exit(0)
    }
    // `AgentHUD --debug-focus <tty>`: run the click-to-focus logic for a tty and print each step.
    if let i = CommandLine.arguments.firstIndex(of: "--debug-focus"), i + 1 < CommandLine.arguments.count {
        var tty = CommandLine.arguments[i + 1]
        if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
        var s = Session(id: "debug", agent: .claude, sessionId: "debug", base: .idle, stateSince: Date(), lastEventAt: Date())
        s.tty = tty
        s.hostKind = CommandLine.arguments.dropFirst(i + 2).first
        Focuser.focus(s)
        Focuser.trace.forEach { print($0) }
        exit(0)
    }
    // `AgentHUD --debug-dots`: the menu bar dots in order, with the session and AeroSpace window each matched.
    if CommandLine.arguments.contains("--debug-dots") {
        let model = AppModel(settings: AppSettings())
        let tailer = EventTailer { events, _ in MainActor.assumeIsolated { model.ingest(events, replay: true) } }
        tailer.start(interval: 3600)
        tailer.stop()
        model.scan()
        let names = model.settings.dotOrder
        print("dot order: \(names)")
        for (i, group) in model.menuBarDotGroups.enumerated() {
            let r = AeroSpace.rank(root: group[0].root, cwd: group[0].cwd, in: names)
            let who = group.map { "\($0.projectName) (\(model.displayState($0).rawValue), \($0.hostLabel ?? "?"))" }.joined(separator: ", ")
            print("  dot \(i + 1): \(r.map { "window \($0 + 1) \(names[$0])" } ?? "no window") ← \(who)")
        }
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
