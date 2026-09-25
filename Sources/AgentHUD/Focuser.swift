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
        Tmux.select(tty: tty)
        if let c = hit.client {
            if !focusTerminal(tty: c.tty, pid: c.pid) { note("tmux: couldn't bring the client's terminal forward") }
        } else {
            note("tmux: session isn't attached anywhere; run `tmux attach -t \(hit.pane.session)`")
            NSSound.beep()
        }
        return true
    }

    /// Terminal or iTerm2 tab with this tty, else the app that owns the process.
    @discardableResult
    static func focusTerminal(tty: String, pid: Int32?) -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if running.contains("com.apple.Terminal"), runScript(terminalScript(tty: tty)) { note("Terminal tab \(tty)"); return true }
        if running.contains("com.googlecode.iterm2"), runScript(itermScript(tty: tty)) { note("iTerm2 session \(tty)"); return true }
        if let pid, let app = ProcTools.ancestry(from: pid, agent: nil, env: [:]).hostApp,
           FileManager.default.fileExists(atPath: app) {
            note("activating \(app)")
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: .init())
            return true
        }
        note("no terminal found for \(tty)")
        return false
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
