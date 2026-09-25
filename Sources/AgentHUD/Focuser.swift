import AgentHUDCore
import AppKit

/// Brings a session's window to the front, as precisely as the host app allows.
enum Focuser {
    /// Steps taken by the last focus, for `AgentHUD --debug-focus`.
    static var trace: [String] = []
    private static var sentToAutomationSettings = false

    static func note(_ s: String) {
        trace.append(s)
        NSLog("Agent HUD focus: \(s)")
    }

    static func focus(_ s: Session) {
        trace = []
        note("session \(s.projectName) host=\(s.hostKind ?? "none") tty=\(s.tty ?? "none") pid=\(s.pid.map(String.init) ?? "none")")
        // tmux first, whatever the session says its host is: under tmux the agent's tty is a pane, which no
        // terminal tab has, and a host recorded as "Terminal" (tmux passes TERM_PROGRAM through) would
        // just activate Terminal and show nothing new.
        if let tty = s.tty, !s.isDesktop, focusTmux(tty: tty) { return }
        // Claude desktop: open that exact session, not just the app (which may already be in front).
        if let link = s.openURL, let url = URL(string: link) {
            note("opening \(link)")
            NSWorkspace.shared.open(url)
            return
        }
        switch s.hostKind {
        case "terminal":
            if let tty = s.tty, runScript(terminalScript(tty: tty)) { return }
        case "iterm":
            if let tty = s.tty, runScript(itermScript(tty: tty)) { return }
        case "wezterm":
            if let tty = s.tty, weztermTab(tty) { return }
        case "vscode", "cursor", "windsurf":
            // Opening a window's own folder focuses it; opening a subfolder of it would make a new window.
            if let app = s.hostApp, let url = editorTarget(s, app: app) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: app), configuration: config)
                return
            }
        default:
            break
        }
        if let app = s.hostApp, FileManager.default.fileExists(atPath: app) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: .init())
            return
        }
        // No host app on record (started before hooks, or an unusual terminal): try the terminals that
        // can be searched by tty before giving up. Finder is only opened from the context menu.
        if let tty = s.tty, focusTerminal(tty: tty, pid: s.pid) { return }
        NSSound.beep()
    }

    /// The tmux pane with this tty: switch the attached client to it, then bring that terminal forward.
    static func focusTmux(tty: String) -> Bool {
        guard let bin = Tmux.binary else { note("tmux: not installed"); return false }
        let panes = Tmux.panes(), clients = Tmux.clients()
        note("tmux: \(bin), \(panes.count) panes, \(clients.count) clients")
        guard let hit = Tmux.locate(tty: tty, panes: panes, clients: clients) else {
            note("tmux: no pane has \(tty)")
            return false
        }
        note("tmux: pane \(hit.pane.paneID) in session \(hit.pane.session); client \(hit.client.map { "\($0.tty) on \($0.session)" } ?? "none attached")")
        if let c = hit.client, c.session != hit.pane.session {
            note("tmux: switch-client \(c.tty) → \(hit.pane.session): \(Tmux.run(["switch-client", "-c", c.tty, "-t", hit.pane.session]) != nil ? "ok" : "failed")")
        }
        note("tmux: select-window \(hit.pane.windowID): \(Tmux.run(["select-window", "-t", hit.pane.windowID]) != nil ? "ok" : "failed")")
        note("tmux: select-pane \(hit.pane.paneID): \(Tmux.run(["select-pane", "-t", hit.pane.paneID]) != nil ? "ok" : "failed")")
        if let c = hit.client {
            note("tmux: showing it in the terminal on \(c.tty) (client pid \(c.pid))")
            if !focusTerminal(tty: c.tty, pid: c.pid) { note("tmux: couldn't bring the client's terminal forward") }
        } else {
            note("tmux: session isn't attached anywhere; run `tmux attach -t \(hit.pane.session)`")
            NSSound.beep()
        }
        return true
    }

    /// The tab showing `tty`. Which terminal is known from the process (a tmux client's pid), so only that
    /// one is asked; without a pid, WezTerm (no permission needed) and then the scriptable ones are tried.
    @discardableResult
    static func focusTerminal(tty: String, pid: Int32?) -> Bool {
        let host = pid.map { ProcTools.ancestry(from: $0, agent: nil, env: [:]) }
        note("terminal for \(tty): \(host?.hostKind ?? "unknown")")
        switch host?.hostKind {
        case "terminal": return scriptTab(terminalScript(tty: tty), "Terminal", tty) || activate(host?.hostApp)
        case "iterm": return scriptTab(itermScript(tty: tty), "iTerm2", tty) || activate(host?.hostApp)
        case "wezterm": return weztermTab(tty) || activate(host?.hostApp)
        case .some: return activate(host?.hostApp)
        case nil:
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            if running.contains("com.github.wez.wezterm"), weztermTab(tty) { return true }
            if running.contains("com.apple.Terminal"), scriptTab(terminalScript(tty: tty), "Terminal", tty) { return true }
            if running.contains("com.googlecode.iterm2"), scriptTab(itermScript(tty: tty), "iTerm2", tty) { return true }
            note("no terminal found for \(tty)")
            return false
        }
    }

    private static func scriptTab(_ script: String, _ app: String, _ tty: String) -> Bool {
        let ok = runScript(script)
        note("\(app) tab \(tty): \(ok ? "selected" : "not found")")
        return ok
    }

    private static func weztermTab(_ tty: String) -> Bool {
        guard WezTerm.activate(tty: tty) else {
            note("WezTerm: no tab has \(tty)\(WezTerm.binary == nil ? " (wezterm CLI not found)" : " (\(WezTerm.guiSockets().count) windows checked)")")
            return false
        }
        note("WezTerm tab \(tty): selected")
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.github.wez.wezterm").first?.activate()
        return true
    }

    private static func activate(_ app: String?) -> Bool {
        guard let app, FileManager.default.fileExists(atPath: app) else { return false }
        note("activating \(app)")
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: .init())
        return true
    }

    /// The open editor window containing the session, else its project root.
    private static func editorTarget(_ s: Session, app: String) -> URL? {
        let paths = [s.cwd, s.root].compactMap { $0 }.filter { $0 != "/" }
        if let file = EditorWindows.storageFile(appPath: app), let data = try? Data(contentsOf: file) {
            for p in paths {
                if let url = EditorWindows.target(storage: data, containing: p) { return url }
            }
        }
        return (s.root ?? s.cwd).flatMap { $0 == "/" ? nil : URL(fileURLWithPath: $0) }
    }

    static func openFolder(_ s: Session) {
        guard let cwd = s.cwd, cwd != "/" else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            note("AppleScript failed: \(error[NSAppleScript.errorMessage] ?? error)")
            // -1743: the user said no (or hasn't been asked yet) to Automation. Show where to allow it, once.
            if (error[NSAppleScript.errorNumber] as? Int) == -1743, !sentToAutomationSettings {
                sentToAutomationSettings = true
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        }
        return result?.booleanValue ?? false
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }
}
