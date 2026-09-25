import AgentHUDCore
import AppKit

/// Brings a session's window to the front, as precisely as the host app allows.
enum Focuser {
    static func focus(_ s: Session) {
        // tmux: select the pane, then bring forward whichever terminal is attached to it.
        if let tty = s.tty, s.hostKind == "tmux" || s.hostKind == nil, case .some(let client) = Tmux.select(tty: tty) {
            if let client { focusTerminal(tty: client.tty, pid: client.pid) }
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

    /// Terminal or iTerm2 tab with this tty, else the app that owns the process.
    @discardableResult
    static func focusTerminal(tty: String, pid: Int32?) -> Bool {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if running.contains("com.apple.Terminal"), runScript(terminalScript(tty: tty)) { return true }
        if running.contains("com.googlecode.iterm2"), runScript(itermScript(tty: tty)) { return true }
        if let pid, let app = ProcTools.ancestry(from: pid, agent: nil, env: [:]).hostApp,
           FileManager.default.fileExists(atPath: app) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: .init())
            return true
        }
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
        if let error { NSLog("Agent HUD focus script failed: \(error)") }
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
