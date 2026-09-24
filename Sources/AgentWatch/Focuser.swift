import AgentWatchCore
import AppKit

/// Brings a session's window to the front, as precisely as the host app allows.
enum Focuser {
    static func focus(_ s: Session) {
        switch s.hostKind {
        case "terminal":
            if let tty = s.tty, runScript(terminalScript(tty: tty)) { return }
        case "iterm":
            if let tty = s.tty, runScript(itermScript(tty: tty)) { return }
        case "vscode", "cursor", "windsurf":
            // Opening the folder with the editor focuses the window that already has it open.
            if let app = s.hostApp, let cwd = s.cwd, cwd != "/" {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: URL(fileURLWithPath: app),
                                        configuration: config)
                return
            }
        default:
            break
        }
        if let app = s.hostApp, FileManager.default.fileExists(atPath: app) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: .init())
            return
        }
        openFolder(s)
    }

    static func openFolder(_ s: Session) {
        guard let cwd = s.cwd, cwd != "/" else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    private static func runScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("AgentWatch focus script failed: \(error)") }
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
