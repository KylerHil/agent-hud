import AppKit

MainActor.assumeIsolated {
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        Snapshot.run(dir: CommandLine.arguments[i + 1])
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // no Dock icon (LSUIElement in the bundle does the same)
    app.run()
}
