import AgentHUDCore
import AppKit
import SwiftUI

MainActor.assumeIsolated {
    // First, before anything reads or creates ~/.agenthud.
    Migration.run()
    // Exercise the same watched-chat Send path without requiring editor focus or a visible panel.
    // `AgentHUD --coordinator-reply <thread-id> <text>` prints the acknowledged/confirmed receipt.
    if let i = CommandLine.arguments.firstIndex(of: "--coordinator-reply"), i + 2 < CommandLine.arguments.count {
        let thread = CommandLine.arguments[i + 1], text = CommandLine.arguments[i + 2]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel(settings: AppSettings())
        let tailer = EventTailer { events, _ in MainActor.assumeIsolated { model.ingest(events, replay: true) } }
        tailer.start(interval: 3600); tailer.stop(); model.scan()
        let coordinator = model.coordinator!
        let id = "codex:" + thread
        coordinator.select(session: id)
        guard let session = coordinator.session, coordinator.canReplyToExistingCodex(session) else {
            print("That existing Codex conversation isn't available in the coordinator."); exit(1)
        }
        coordinator.drafts[id] = text
        coordinator.sendToExistingCodex(session)
        var last: String?
        let deadline = Date().addingTimeInterval(35)
        _ = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                coordinator.refresh()
                if let receipt = coordinator.editorSends[id] {
                    let state = receipt.delivered ? "delivered" : receipt.bridgeStatus?.rawValue ?? "pending"
                    if state != last { print("reply: \(state)\(receipt.error.map { " · " + $0 } ?? "")"); fflush(stdout); last = state }
                    if receipt.delivered { exit(0) }
                    if receipt.bridgeStatus == .failed || receipt.bridgeStatus == .uncertain { exit(1) }
                }
                if Date() > deadline { print("No transcript confirmation yet. Check the chat before resending."); exit(2) }
            }
        }
        app.run()
    }
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
    // `AgentHUD --snapshot-coordinator <file.png> [project]`: open the Coordinator on the live sessions, save it.
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot-coordinator"), i + 1 < CommandLine.arguments.count {
        let out = CommandLine.arguments[i + 1], project = CommandLine.arguments.dropFirst(i + 2).first
        // A third argument acts first, to exercise the app's path to the broker: allow (the first prompt) or approve (the plan).
        let act = CommandLine.arguments.dropFirst(i + 3).first
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel(settings: AppSettings())
        let tailer = EventTailer { events, _ in MainActor.assumeIsolated { model.ingest(events, replay: true) } }
        tailer.start(interval: 3600)
        tailer.stop()
        model.scan()
        let coordinator = model.coordinator!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: CoordinatorView(model: coordinator) {})
        model.broker.attachIfRunning()
        window.orderFront(nil)
        // Give the broker a moment to send its sessions, then pick what to show.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            coordinator.start()
            if project == "pair", let p = coordinator.pairList.first {
                coordinator.select(pair: p.id)
            } else if let project, let p = coordinator.sections.flatMap(\.projects).first(where: { $0.primary.projectName == project }) {
                coordinator.select(project: p.id)
            }
            if act == "start", let dir = CommandLine.arguments.dropFirst(i + 4).first {
                coordinator.startSession(StartOptions(agent: .claude, cwd: dir, prompt: "Reply with exactly: STARTED-FROM-APP", model: "haiku"))
            }
            if act == "approvals" { coordinator.showingApprovals = true }
            if act == "approve", let p = coordinator.pair { coordinator.pairAction(p, "approvePlan", text: "Use node:assert/strict.") }
            if act == "allow", let s = coordinator.session, let r = coordinator.managed(s)?.pending.first {
                coordinator.answer(s, r, decision: "allow")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (act == nil ? 4 : 25)) {
            let view = window.contentView!
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
            exit(0)
        }
        app.run()
    }
    // `AgentHUD --editor-reply <folder> <session-id> <text>`: send a reply to Claude in VS Code the way
    // the Coordinator does (open the conversation with the text typed in, then press Return), for testing.
    if let i = CommandLine.arguments.firstIndex(of: "--editor-reply"), i + 3 < CommandLine.arguments.count {
        let folder = CommandLine.arguments[i + 1], sid = CommandLine.arguments[i + 2], text = CommandLine.arguments[i + 3]
        var s = Session(id: "debug", agent: .claude, sessionId: sid == "new" ? UUID().uuidString : sid,
                        base: .idle, stateSince: Date(), lastEventAt: Date())
        s.hostKind = "vscode"
        s.hostApp = "/Applications/Visual Studio Code.app"
        s.root = folder; s.cwd = folder
        print("accessibility trusted: \(EditorReply.canPressReturn)")
        EditorReply.deliver(s, text: text, pressReturn: true) { outcome in print("outcome: \(outcome)"); exit(0) }
        NSApplication.shared.run()
    }
    // `AgentHUD --chat <transcript.jsonl> [claude|codex]`: print what the Coordinator's chat shows for a transcript.
    if let i = CommandLine.arguments.firstIndex(of: "--chat"), i + 1 < CommandLine.arguments.count {
        let path = CommandLine.arguments[i + 1]
        let agent = CommandLine.arguments.dropFirst(i + 2).first.flatMap(AgentKind.init(rawValue:))
            ?? (path.contains("/.codex/") ? .codex : .claude)
        let t0 = Date()
        let transcript = ChatTranscript(path: path, agent: agent)
        transcript.update()
        print("\(transcript.items.count) items\(transcript.truncated ? " (older history skipped)" : "") in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        for item in transcript.items {
            let text = item.text.replacingOccurrences(of: "\n", with: " ⏎ ")
            print("[\(item.kind)] \(text.prefix(140))\(item.detail.map { " · " + $0.prefix(80) } ?? "")")
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
